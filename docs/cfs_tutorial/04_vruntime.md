# 第 4 站:vruntime 与时间记账

## 学习目标

- 理解 vruntime 的精确定义和单位
- 掌握 `update_curr()` 在何时被调用、做了什么
- 看懂 `min_vruntime` 为什么必须单调递增
- 学会用 `entity_before()` 比较两个 vruntime(注意溢出!)

## 源码定位

| 函数 / 变量 | 文件 | 行号 |
| --- | --- | --- |
| `update_curr()` | `kernel/sched/fair.c` | 802 |
| `calc_delta_fair()` | `kernel/sched/fair.c` | 627 |
| `__calc_delta()` | `kernel/sched/fair.c` | 218 |
| `update_min_vruntime()` | `kernel/sched/fair.c` | 495 |
| `min_vruntime()` / `max_vruntime()` | `kernel/sched/fair.c` | 471, 480 |
| `entity_before()` | `kernel/sched/fair.c` | 489 |

## 原理图解

### 1. vruntime 的定义

设任务 i 在最近一段时间 Δt 内实际占用了 CPU,其权重为 `w_i`,则:

```
Δvruntime_i = Δt × NICE_0_LOAD / w_i
```

直观理解:**vruntime 是"按 nice=0 标准化"后的运行时间**。

- 对 nice=0 的任务,vruntime 增长率 = 实际运行时间增长率(系数为 1)
- 对 nice<0(权重大)的任务,vruntime 增长**慢**,因此在红黑树上停留靠左、
  容易被选中,获得更多 CPU
- 对 nice>0(权重小)的任务,vruntime 增长**快**,被选中频率低

CFS 的调度规则用一句话总结:**永远选 vruntime 最小的实体运行**。

### 2. `calc_delta_fair()`:实际时间 → 虚拟时间

`kernel/sched/fair.c:627`:

```c
static inline u64 calc_delta_fair(u64 delta, struct sched_entity *se)
{
    if (unlikely(se->load.weight != NICE_0_LOAD))
        delta = __calc_delta(delta, NICE_0_LOAD, &se->load);
    return delta;
}
```

只有当 weight 不等于 NICE_0_LOAD 时才走通用乘除路径。**绝大多数普通进程
nice=0,这是一条快速路径**(直接返回 delta,跳过 `__calc_delta`)。
代入 `__calc_delta()` 的语义:

```
返回值 = delta × NICE_0_LOAD / se->load.weight
```

正是上面那个公式。

### 3. `update_curr()`:CFS 的"心跳"

`kernel/sched/fair.c:802`:

```c
static void update_curr(struct cfs_rq *cfs_rq)
{
    struct sched_entity *curr = cfs_rq->curr;
    u64 now = rq_clock_task(rq_of(cfs_rq));
    u64 delta_exec;

    if (unlikely(!curr))
        return;

    delta_exec = now - curr->exec_start;
    if (unlikely((s64)delta_exec <= 0))
        return;

    curr->exec_start = now;
    ...
    curr->sum_exec_runtime += delta_exec;
    ...
    curr->vruntime += calc_delta_fair(delta_exec, curr);
    update_min_vruntime(cfs_rq);
    ...
    account_cfs_rq_runtime(cfs_rq, delta_exec);
}
```

**做了 4 件事**:

1. 计算上一次记账以来当前任务实际运行了多久(`delta_exec`)
2. 累加到任务的 `sum_exec_runtime`(物理时间)
3. **累加 `vruntime`**(虚拟时间,经 `calc_delta_fair` 转换)
4. 更新 `cfs_rq->min_vruntime` 并记账 cgroup 配额

### 4. `update_curr()` 的调用时机

它**不是**周期触发的!CFS 在以下任意时刻"按需"调用它:

- `task_tick_fair()`:每次 scheduler tick(周期定时器中断)
- `enqueue_entity()`、`dequeue_entity()`:任务入队/出队前先记账
- `pick_next_task_fair()`:挑选下一个任务前
- `yield_task_fair()`、`set_user_nice()`:用户修改优先级时
- 修改 cgroup 配额时

这种"懒记账"避免了高频定时器更新,只在状态变化时一次性把账算清。

### 5. `min_vruntime` 推进规则

`kernel/sched/fair.c:495`:

```c
static void update_min_vruntime(struct cfs_rq *cfs_rq)
{
    struct sched_entity *curr = cfs_rq->curr;
    struct rb_node *leftmost = rb_first_cached(&cfs_rq->tasks_timeline);
    u64 vruntime = cfs_rq->min_vruntime;

    if (curr) {
        if (curr->on_rq)
            vruntime = curr->vruntime;
        else
            curr = NULL;
    }

    if (leftmost) {                       /* 树非空 */
        struct sched_entity *se = rb_entry(leftmost, struct sched_entity, run_node);
        if (!curr)
            vruntime = se->vruntime;
        else
            vruntime = min_vruntime(vruntime, se->vruntime);
    }

    /* ensure we never gain time by being placed backwards. */
    cfs_rq->min_vruntime = max_vruntime(cfs_rq->min_vruntime, vruntime);
    ...
}
```

候选 vruntime 是:`curr->vruntime` 与"红黑树最左节点的 vruntime"的较小值。
然后 **`min_vruntime` 只能向前(增大)**,绝不能后退。最后一行 `max_vruntime`
就是这个保险丝。

为什么单调?第 6 站会看到,新任务和唤醒任务的 vruntime 都以 `min_vruntime`
为基准做"补偿"。如果 `min_vruntime` 后退,这些补偿就会失效,导致老任务被
长时间饿死。

### 6. 64 位 vruntime 的溢出处理

`vruntime` 是 `u64`,但即便 1 GHz 计数,2^64 ns 也要 584 年才溢出 —— 看似
不用担心。可是组调度引入后,vruntime 增长率被压缩,某些场景下确实可能"看起来"
回绕。所以 CFS **永远不直接比较两个 vruntime 的大小**,而是用差值的符号:

```c
/* fair.c:489 */
static inline int entity_before(struct sched_entity *a, struct sched_entity *b)
{
    return (s64)(a->vruntime - b->vruntime) < 0;
}
```

把无符号差转换成有符号比较,就像 TCP 序号一样能容忍回绕,只要两个值的距离
小于 2^63。`min_vruntime()`、`max_vruntime()`(`fair.c:471,480`)同理,
都是先做差再看符号。

### 7. 物理时间 vs 虚拟时间 一图流

```
任务 A(nice=0, weight=1024)  跑 6ms:  Δvruntime = 6ms × 1024/1024 = 6ms
任务 B(nice=-5,weight=3121) 跑 6ms:  Δvruntime = 6ms × 1024/3121 ≈ 1.97ms
任务 C(nice=+5,weight=335)  跑 6ms:  Δvruntime = 6ms × 1024/335  ≈ 18.3ms

跑同样的 6ms 物理时间,B 的 vruntime 涨得最慢,所以下次调度它会再次胜出。
```

## 思考题

1. **快速路径条件**:`calc_delta_fair()` 只有 `weight != NICE_0_LOAD` 时才调用
   `__calc_delta`。如果系统中所有任务都是 nice=0,vruntime 与 `sum_exec_runtime`
   的关系是什么?这条快速路径每秒能省多少次乘除?

2. **`min_vruntime` 必须单调**:假设我们去掉 `update_min_vruntime()` 末尾的
   `max_vruntime` 保险丝。构造一个会导致"任务被饿死"的场景。
   (提示:让一个任务睡眠很久,期间所有就绪任务跑满,看 `place_entity` 中
   `vruntime -= thresh` 这一行的后果。)

3. **`entity_before` 与回绕**:写一个表格,展示当 `a->vruntime = 0xFFFF_FFF0`、
   `b->vruntime = 0x0000_0010` 时,`(s64)(a->vruntime - b->vruntime)` 的值。
   解释为什么这个结果让 CFS 认为 a 在 b 之前(就是希望 a 先跑)。

4. **GDB 实操**:启动 `./run_debian_arm64.sh run debug`,在 `update_curr` 上设
   断点,打印当前任务的 `comm`、`weight`、`delta_exec`、`vruntime`。在 QEMU 内
   跑 `stress -c 2` 后多次 continue,观察 vruntime 是否符合 `Δvruntime = Δt × 1024/w`。
   ```gdb
   (gdb) b update_curr
   (gdb) commands
   > silent
   > printf "comm=%s w=%lu vruntime=%llu\n", \
        ((struct task_struct*)container_of(curr,struct task_struct,se))->comm, \
        curr->load.weight, curr->vruntime
   > c
   > end
   ```

5. **vruntime 重置?**:如果一个任务被 fork 出来,它的 vruntime 应该是多少?
   阅读 `task_fork_fair()`(`fair.c` 中 grep)和 `place_entity(initial=1)`
   (`fair.c:3785`),解释为什么新任务的 vruntime 不是 0,而是
   `min_vruntime + sched_vslice(...)`。

6. **rq_clock_task vs rq_clock**:`update_curr` 用的是 `rq_clock_task` 而不是
   `rq_clock`,二者差别在哪里?(提示:`rq_clock_task` 扣除了被 IRQ/steal time
   占去的时间,搜索 `update_rq_clock_task()`。)

---

⬅️ [上一站:权重与负载](03_weight_and_load.md) ｜ ➡️ [下一站:红黑树](05_rbtree.md)
