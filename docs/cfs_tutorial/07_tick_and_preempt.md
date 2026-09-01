# 第 7 站:周期调度、抢占决策与挑选下一个任务

## 学习目标

- 理解 scheduler tick 在 CFS 中的作用与触发链路
- 看懂 `sched_slice()` 如何按权重切分时间片
- 区分"tick 抢占"和"唤醒抢占"两种触发路径
- 走通 `pick_next_task_fair()` 的快速路径和层级路径

## 源码定位

| 函数 / 变量 | 文件 | 行号 |
| --- | --- | --- |
| `__sched_period()` | `kernel/sched/fair.c` | 643 |
| `sched_slice()` | `kernel/sched/fair.c` | 657 |
| `sched_vslice()` | `kernel/sched/fair.c` | 684 |
| `check_preempt_tick()` | `kernel/sched/fair.c` | 4025 |
| `entity_tick()` | `kernel/sched/fair.c` | grep `^entity_tick` |
| `task_tick_fair()` | `kernel/sched/fair.c` | 10032 |
| `wakeup_preempt_entity()` | `kernel/sched/fair.c` | 6769 |
| `check_preempt_wakeup()` | `kernel/sched/fair.c` | 6816 |
| `pick_next_entity()` | `kernel/sched/fair.c` | 4104 |
| `pick_next_task_fair()` | `kernel/sched/fair.c` | 6900 |
| `set_next_entity()` / `put_prev_entity()` | `kernel/sched/fair.c` | 4062, grep |

## 原理图解

### 1. 周期 tick 的链路

```
硬件定时器中断
       │
       ▼
tick_handle_periodic / hrtimer
       │
       ▼
update_process_times()              ← kernel/time/timer.c
       │
       ▼
scheduler_tick()                    ← kernel/sched/core.c
       │
       ├─ update_rq_clock(rq)
       ├─ curr->sched_class->task_tick(rq, curr, 0)
       │       │
       │       ▼
       │   task_tick_fair()         ← fair.c:10032
       │       │
       │       ▼
       │   entity_tick(cfs_rq, curr->se, 0)
       │       │
       │       ├─ update_curr(cfs_rq)
       │       └─ check_preempt_tick(cfs_rq, curr)   ← fair.c:4025
       │
       └─ trigger_load_balance(rq)  /* SMP 负载均衡 */
```

`scheduler_tick()` 不亲自做调度决定,它只是**记账 + 设置 `TIF_NEED_RESCHED` 标志**。
真正的 `schedule()` 在中断返回或抢占点才被调用。

### 2. `__sched_period()` 与 `sched_slice()`

**调度周期 P 的目标**:让所有就绪任务在一个 P 内至少跑一次。

`fair.c:643`:

```c
static u64 __sched_period(unsigned long nr_running)
{
    if (unlikely(nr_running > sched_nr_latency))
        return nr_running * sysctl_sched_min_granularity;
    else
        return sysctl_sched_latency;     /* 默认 6ms */
}
```

`sched_nr_latency = sysctl_sched_latency / sysctl_sched_min_granularity = 8`(默认)。
也就是说:

- 任务数 ≤ 8 时,P = 6ms(让每个任务在 6ms 内至少调度一次)
- 任务数 > 8 时,P = N × 0.75ms(防止每个时间片小于 min_granularity)

`fair.c:657`:

```c
static u64 sched_slice(struct cfs_rq *cfs_rq, struct sched_entity *se)
{
    u64 slice = __sched_period(cfs_rq->nr_running + !se->on_rq);
    for_each_sched_entity(se) {
        struct load_weight *load = &cfs_rq->load;
        ...
        slice = __calc_delta(slice, se->load.weight, load);
    }
    return slice;
}
```

含义:`slice = P × se->load.weight / cfs_rq->load.weight`。这就是"权重越大、
slice 越长"的具体实现。**组调度下要沿层级累乘**(向上每一层都乘以"本组在
父组中的权重份额")。

### 3. `check_preempt_tick()`:周期抢占决策

`fair.c:4025`:

```c
static void check_preempt_tick(struct cfs_rq *cfs_rq, struct sched_entity *curr)
{
    unsigned long ideal_runtime, delta_exec;
    struct sched_entity *se;
    s64 delta;

    ideal_runtime = sched_slice(cfs_rq, curr);
    delta_exec = curr->sum_exec_runtime - curr->prev_sum_exec_runtime;

    /* 用满了时间片:必须让出 */
    if (delta_exec > ideal_runtime) {
        resched_curr(rq_of(cfs_rq));
        clear_buddies(cfs_rq, curr);
        return;
    }

    /* 没跑够最小粒度,不抢占,防止颠簸 */
    if (delta_exec < sysctl_sched_min_granularity)
        return;

    /* 跑够了最小粒度,看看红黑树最左节点亏欠多少 */
    se = __pick_first_entity(cfs_rq);
    delta = curr->vruntime - se->vruntime;
    if (delta < 0)
        return;
    if (delta > ideal_runtime)
        resched_curr(rq_of(cfs_rq));
}
```

三段决策非常优雅:

1. **超时**:`delta_exec > sched_slice`,直接挂上抢占标志
2. **欠跑保护**:`delta_exec < min_granularity`,不允许打扰,避免高频切换
3. **最小亏欠**:超过最小粒度但未超总时间,如果队首任务比 curr 的 vruntime 落后
   太多(差距大于 `ideal_runtime`),也触发抢占

`resched_curr()` 只是设置 `TIF_NEED_RESCHED`,真正的切换发生在中断返回时。

### 4. `check_preempt_wakeup()`:唤醒抢占

`fair.c:6816`(精简):

```c
static void check_preempt_wakeup(struct rq *rq, struct task_struct *p, int wake_flags)
{
    struct sched_entity *se = &curr->se, *pse = &p->se;
    ...
    if (sched_feat(NEXT_BUDDY) && scale && !(wake_flags & WF_FORK)) {
        set_next_buddy(pse);     /* 提示下次倾向选 pse */
    }
    if (test_tsk_need_resched(curr))
        return;
    if (task_has_idle_policy(curr) && !task_has_idle_policy(p))
        goto preempt;
    if (p->policy != SCHED_NORMAL || !sched_feat(WAKEUP_PREEMPTION))
        return;

    find_matching_se(&se, &pse);          /* 组调度下找到同层祖先 */
    update_curr(cfs_rq_of(se));

    if (wakeup_preempt_entity(se, pse) == 1) {
        goto preempt;
    }
    return;
preempt:
    resched_curr(rq);
    ...
}
```

**唤醒抢占**(wakeup preemption):一个任务被唤醒入队后,内核问一句"它要不要
立刻顶替正在跑的 curr?"。判定函数就是 `wakeup_preempt_entity()`。

### 5. `wakeup_preempt_entity()`:三态返回

`fair.c:6769`:

```c
static int wakeup_preempt_entity(struct sched_entity *curr, struct sched_entity *se)
{
    s64 gran, vdiff = curr->vruntime - se->vruntime;

    if (vdiff <= 0)
        return -1;            /* curr 反而 vruntime 更小,不该抢 */

    gran = wakeup_gran(se);   /* 与 sysctl_sched_wakeup_granularity 相关 */
    if (vdiff > gran)
        return 1;             /* 差距超过门槛,允许抢占 */

    return 0;                 /* 在门槛内,不抢 */
}
```

`wakeup_gran` 通过 `calc_delta_fair` 把 `sysctl_sched_wakeup_granularity`(默认 1ms)
按 nice 转换成 vruntime 形式的"最小抢占门槛"。这个门槛防止"短促的唤醒"对正在
高效运行的任务造成抖动。

### 6. `pick_next_task_fair()` 整体流程

`fair.c:6900`(简版):

```c
static struct task_struct *
pick_next_task_fair(struct rq *rq, struct task_struct *prev, struct rq_flags *rf)
{
again:
    if (!cfs_rq->nr_running) goto idle;

#ifdef CONFIG_FAIR_GROUP_SCHED
    if (prev->sched_class != &fair_sched_class) goto simple;

    do {                                  /* 沿组层级向下挑选 */
        if (curr && curr->on_rq) update_curr(cfs_rq);
        se = pick_next_entity(cfs_rq, curr);
        cfs_rq = group_cfs_rq(se);        /* 进入子 cfs_rq */
    } while (cfs_rq);
    p = task_of(se);

    if (prev != p) {                      /* 只更新必要的层级,优化缓存 */
        ... put_prev_entity / set_next_entity ...
    }
    goto done;

simple:
#endif
    put_prev_task(rq, prev);
    do {
        se = pick_next_entity(cfs_rq, NULL);
        set_next_entity(cfs_rq, se);
        cfs_rq = group_cfs_rq(se);
    } while (cfs_rq);
    p = task_of(se);
done:
    ...
    return p;

idle:
    new_tasks = idle_balance(rq, rf);
    if (new_tasks > 0) goto again;
    return NULL;
}
```

要点:

- **快速路径**:没开组调度走 `simple` 分支,只在叶子 cfs_rq 上选一次
- **组调度路径**:沿树深逐层挑选,每层选 vruntime 最小的实体进入子 cfs_rq
- **空队列时**:`idle_balance()` 尝试从别的 CPU 偷任务,失败就返回 NULL,
  调用方继续向后查 `idle_sched_class`

### 7. `pick_next_entity()`:不只是"最左节点"

`fair.c:4104`(精简):

```c
static struct sched_entity *
pick_next_entity(struct cfs_rq *cfs_rq, struct sched_entity *curr)
{
    struct sched_entity *left = __pick_first_entity(cfs_rq);
    struct sched_entity *se;

    if (!left || (curr && entity_before(curr, left)))
        left = curr;                  /* curr 比树上的还更靠左 */

    se = left;                        /* 默认选最左 */

    if (cfs_rq->skip == se) {         /* yield 想跳过 */
        struct sched_entity *second;
        if (se == curr) second = __pick_first_entity(cfs_rq);
        else            second = __pick_next_entity(se);

        if (second && wakeup_preempt_entity(second, left) < 1)
            se = second;
    }

    /* last/next buddy 提示,提升缓存局部性 */
    if (cfs_rq->last && wakeup_preempt_entity(cfs_rq->last, left) < 1)
        se = cfs_rq->last;
    if (cfs_rq->next && wakeup_preempt_entity(cfs_rq->next, left) < 1)
        se = cfs_rq->next;

    clear_buddies(cfs_rq, se);
    return se;
}
```

四级优先(后写覆盖前写):

1. 默认:红黑树最左节点 `left`(或 curr,如果比 left 还左)
2. `skip`(`sched_yield` 提示):如果 `left == skip`,挑第二左的
3. `last`(上一次被抢的任务):若与 `left` 的 vruntime 差距未超门槛,优先它
4. `next`(唤醒时的"下一个"提示):同上,但优先级最高

这样既保证公平(默认最左),又能利用 buddy 提示提升缓存命中。

## 思考题

1. **`sched_period` 的边界**:任务数从 8 增到 9 的瞬间,`__sched_period` 的返回值
   从 6ms 跳到 6.75ms。这是不连续的,会不会引入"切换抖动"?为什么内核接受
   这种设计?

2. **三段决策的顺序**:`check_preempt_tick()` 中,如果调换"min_granularity 保护"
   和"slice 超时"两段的顺序,会有什么后果?用极端例子(slice 比 min_granularity
   还小)说明。

3. **唤醒抢占门槛**:为什么 `wakeup_preempt_entity` 要把 `wakeup_granularity`
   先用 `calc_delta_fair` 转成虚拟时间?如果直接用 1ms 实际时间作为门槛,nice=-20
   的任务会被 nice=0 的唤醒任务轻易抢占吗?

4. **GDB 验证三段决策**:在 `check_preempt_tick` 上下断点,跑 `stress -c 4`,
   打印 `ideal_runtime`、`delta_exec`、`delta`,看实际进入哪个分支的频率最高。
   ```gdb
   (gdb) b check_preempt_tick
   (gdb) commands
   > silent
   > printf "ideal=%lu delta_exec=%llu\n", ideal_runtime, delta_exec
   > c
   > end
   ```

5. **ftrace 验证 pick_next**:用本仓库的 ftrace 工具跟踪 `pick_next_task_fair`:
   ```bash
   ./trace_kernel_boot.sh ftrace function_graph "pick_next_task_fair,pick_next_entity"
   ```
   QEMU 启动后看 `/sys/kernel/tracing/trace`,统计 buddy 命中(`last`/`next`)的
   比例。

6. **`set_next_buddy` 的副作用**:`dequeue_task_fair()` 会在睡眠时调用
   `set_next_buddy(parent)`(自行 grep 这处调用),为什么是 parent 而不是
   被出队的实体本身?(提示:被出队的实体不在树上了,标记它没意义。)

7. **WAKE_AFFINE**:`fair.c` 还有 `wake_affine` 一族函数(grep),它解决了什么
   问题?和 `check_preempt_wakeup` 是什么关系?(提示:前者决定唤醒到哪个 CPU,
   后者决定唤醒后是否抢占。)

---

⬅️ [上一站:入队、出队](06_enqueue_dequeue.md) ｜ ➡️ [下一站:PELT 与组调度](08_pelt_and_group.md)
