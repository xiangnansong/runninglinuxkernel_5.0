# 第 6 站:任务入队、出队、唤醒、迁移

## 学习目标

- 跟踪一个任务从被唤醒到挂上红黑树的完整流程
- 理解 `place_entity()` 对新任务和被唤醒任务做的"vruntime 补偿"
- 看懂 `enqueue_entity()` 中 `renorm` 标志的含义
- 知道任务在 CPU 间迁移时 vruntime 如何"折算"

## 源码定位

| 函数 | 文件 | 行号 |
| --- | --- | --- |
| `enqueue_task_fair()` | `kernel/sched/fair.c` | 5110 |
| `enqueue_entity()` | `kernel/sched/fair.c` | 3870 |
| `place_entity()` | `kernel/sched/fair.c` | 3785 |
| `dequeue_task_fair()` | `kernel/sched/fair.c` | 5192 |
| `dequeue_entity()` | `kernel/sched/fair.c` | grep `^dequeue_entity` |
| `migrate_task_rq_fair()` | `kernel/sched/fair.c` | grep |
| `task_fork_fair()` | `kernel/sched/fair.c` | grep `task_fork_fair` |
| 迁移注释 | `kernel/sched/fair.c` | 3839-3867 |

## 原理图解

### 1. 一图看懂调用层次

```
sys_clone / fork             用户主动让出/睡眠           中断/信号唤醒
       │                              │                          │
       ▼                              ▼                          ▼
wake_up_new_task              schedule() → deactivate     try_to_wake_up
       │                              │                          │
       ▼                              ▼                          ▼
activate_task               dequeue_task_fair          activate_task
       │                              │                          │
       ▼                              ▼                          ▼
enqueue_task_fair  ────────────► dequeue_entity ◄──────  enqueue_task_fair
       │                              │                          │
       ▼                              ▼                          ▼
enqueue_entity                  __dequeue_entity            enqueue_entity
       │                                                         │
       ├─ update_curr()                                           ├─ update_curr()
       ├─ place_entity()  ← 关键: 根据 flags 调整 vruntime         ├─ place_entity()
       └─ __enqueue_entity()  ← 插入红黑树                         └─ __enqueue_entity()
```

### 2. `enqueue_task_fair()` 顶层

`fair.c:5110`(精简):

```c
static void enqueue_task_fair(struct rq *rq, struct task_struct *p, int flags)
{
    struct sched_entity *se = &p->se;
    ...
    for_each_sched_entity(se) {           /* 沿组层级向上 */
        if (se->on_rq) break;             /* 已经在某层在队列上,无需再处理 */
        cfs_rq = cfs_rq_of(se);
        enqueue_entity(cfs_rq, se, flags);
        ...
        cfs_rq->h_nr_running++;
        flags = ENQUEUE_WAKEUP;
    }

    for_each_sched_entity(se) {           /* 第二轮:更新负载与权重 */
        cfs_rq = cfs_rq_of(se);
        cfs_rq->h_nr_running++;
        update_load_avg(cfs_rq, se, UPDATE_TG);
        update_cfs_group(se);
    }
    ...
    add_nr_running(rq, 1);
    hrtick_update(rq);
}
```

**`for_each_sched_entity(se)`** 在没开组调度时是一次循环;开了组调度后会
从最内层 cfs_rq 一直向上走到根 cfs_rq,把每一层的统计都更新一遍。这是
"层级化记账"的体现。

### 3. `enqueue_entity()` 的 `renorm` 标志

`fair.c:3870`:

```c
static void enqueue_entity(struct cfs_rq *cfs_rq, struct sched_entity *se, int flags)
{
    bool renorm = !(flags & ENQUEUE_WAKEUP) || (flags & ENQUEUE_MIGRATED);
    bool curr = cfs_rq->curr == se;

    if (renorm && curr)
        se->vruntime += cfs_rq->min_vruntime;

    update_curr(cfs_rq);

    if (renorm && !curr)
        se->vruntime += cfs_rq->min_vruntime;

    update_load_avg(cfs_rq, se, UPDATE_TG | DO_ATTACH);
    ...
    if (flags & ENQUEUE_WAKEUP)
        place_entity(cfs_rq, se, 0);     /* 唤醒补偿 */

    if (!curr)
        __enqueue_entity(cfs_rq, se);    /* 插入红黑树 */
    se->on_rq = 1;
    ...
}
```

`renorm` 决定是否需要把 vruntime 加回 `min_vruntime`。两种触发场景:

- **非唤醒入队**(比如 fork 后新任务):vruntime 是裸值,需要加上当前队列的
  `min_vruntime` 才能放在合理位置
- **跨 CPU 迁移**:出队时(在源 CPU)被减掉了源 CPU 的 `min_vruntime`,
  入队时(在目标 CPU)需要加上目标 CPU 的 `min_vruntime`

`fair.c:3839-3867` 的注释明确写出了这个"减→加"协议:

```c
/*
 *  MIGRATION
 *      dequeue → vruntime -= min_vruntime
 *      enqueue → vruntime += min_vruntime
 *
 *  this way the vruntime transition between RQs is done when both
 *  min_vruntime are up-to-date.
 */
```

### 4. `place_entity()`:vruntime 的"补偿魔法"

`fair.c:3785`:

```c
static void place_entity(struct cfs_rq *cfs_rq, struct sched_entity *se, int initial)
{
    u64 vruntime = cfs_rq->min_vruntime;

    /* 新任务:推迟到当前周期末尾,免得插队 */
    if (initial && sched_feat(START_DEBIT))
        vruntime += sched_vslice(cfs_rq, se);

    /* 唤醒任务:奖励一个 sched_latency 的"免费补偿" */
    if (!initial) {
        unsigned long thresh = sysctl_sched_latency;
        if (sched_feat(GENTLE_FAIR_SLEEPERS))
            thresh >>= 1;          /* 减半,温和模式 */
        vruntime -= thresh;
    }

    /* ensure we never gain time by being placed backwards. */
    se->vruntime = max_vruntime(se->vruntime, vruntime);
}
```

两条规则:

| 场景 | 调整 | 用意 |
| --- | --- | --- |
| `initial=1`(新任务) | vruntime ← `min_vruntime + sched_vslice` | "罚款":让新任务排到当前周期末尾,不能挤掉老任务 |
| `initial=0`(唤醒) | vruntime ← `max(自己的, min_vruntime - sched_latency/2)` | "奖励":刚醒来的交互任务可以稍微往前蹭一点,提升响应性 |

这是 CFS 把"完全公平"和"交互响应"调和的关键代码。最后那行 `max_vruntime` 防止
vruntime 倒退,保证已经累积过 vruntime 的睡眠任务不会"白嫖"太多。

### 5. `dequeue_task_fair()` 关键路径

`fair.c:5192`:

```c
static void dequeue_task_fair(struct rq *rq, struct task_struct *p, int flags)
{
    struct sched_entity *se = &p->se;
    int task_sleep = flags & DEQUEUE_SLEEP;

    for_each_sched_entity(se) {
        cfs_rq = cfs_rq_of(se);
        dequeue_entity(cfs_rq, se, flags);
        ...
        if (cfs_rq->load.weight) {
            /* 父 cfs_rq 还有别的实体,不必整组出队 */
            se = parent_entity(se);
            ...
        }
    }
    ...
}
```

`dequeue_entity()` 内部会:

1. `update_curr()` 把账记清
2. `__dequeue_entity()` 从红黑树摘掉
3. `update_min_vruntime()` 更新基准

`task_sleep` 标志区分"用户主动 sleep"和"被抢占";前者还会设置 `next` buddy
提示,鼓励下次唤醒时再次选中,提升缓存局部性。

### 6. 跨 CPU 迁移的 vruntime 折算

源码在 `migrate_task_rq_fair()`(自行 grep)。流程:

```
源 CPU 上 dequeue_entity():
    vruntime -= source->min_vruntime    (变成"相对值")

任务被搬到目标 CPU,期间 vruntime 保持相对值

目标 CPU 上 enqueue_entity():
    vruntime += target->min_vruntime    (重新基准化)
```

为什么要这样?**两个 CPU 的 `min_vruntime` 各自演化、可能差距很大**。如果一个
任务在 CPU0 累积了 vruntime=10^9,直接搬到 `min_vruntime=10^7` 的 CPU1,
它会被永远排到末尾;反过来则会插到队首饿死本地任务。先减后加保证迁移前后
"相对位置"不变。

### 7. fork 流程小结

`task_fork_fair()`(自行 grep,通常在 `fair.c:10060` 附近):

```c
static void task_fork_fair(struct task_struct *p)
{
    struct sched_entity *se = &p->se, *curr;
    ...
    update_curr(cfs_rq);
    if (curr)
        se->vruntime = curr->vruntime;
    place_entity(cfs_rq, se, 1);    /* initial=1, 新任务罚款 */

    if (sysctl_sched_child_runs_first && curr && entity_before(curr, se)) {
        /* 让子进程先跑:交换 vruntime */
        swap(curr->vruntime, se->vruntime);
        resched_curr(rq);
    }

    se->vruntime -= cfs_rq->min_vruntime;   /* 出队时再减,为后续 enqueue 做准备 */
    ...
}
```

注意最后一句 `vruntime -= min_vruntime`,这是为了配合后面 `wake_up_new_task` →
`enqueue_task_fair` 中的 `+= min_vruntime`,保持上面"减→加"对称。

## 思考题

1. **新任务的"罚款"**:`place_entity(initial=1)` 给新任务的 vruntime 加上一个
   `sched_vslice` 的偏移。如果不加这个偏移,fork 出 1000 个新任务会发生什么?
   它们会不会"插队"挤垮已有任务?在 QEMU 中跑 `for i in $(seq 1000); do (yes>/dev/null &); done`,
   观察老任务的响应。

2. **`renorm` 的逻辑**:仔细分析 `enqueue_entity()` 第一句
   `bool renorm = !(flags & ENQUEUE_WAKEUP) || (flags & ENQUEUE_MIGRATED);`
   列出 `(WAKEUP, MIGRATED)` 四种组合下 `renorm` 的取值,各自代表什么场景。

3. **为什么 `renorm && curr` 要特殊对待?**:进入 `enqueue_entity` 时如果该实体
   就是 `cfs_rq->curr`(意味着它现在还在跑),为什么要在 `update_curr()` **之前**
   先把 vruntime 加上 `min_vruntime`?(提示:`update_curr` 自己也会改 vruntime,
   顺序影响结果。)

4. **`GENTLE_FAIR_SLEEPERS`**:如果关闭这个特性(`echo NO_GENTLE_FAIR_SLEEPERS >
   /sys/kernel/debug/sched_features`),交互式任务(比如 vim)的响应会变好还是变坏?
   理论分析后到 QEMU 里实测。

5. **跨 CPU 迁移的边角**:假设 CPU0 和 CPU1 的 `min_vruntime` 差距非常大(比如一个
   是新启动 CPU)。一个任务从 CPU0 迁移到 CPU1 后,它的"相对位置"还是公平的吗?
   阅读 `migrate_task_rq_fair()` 上方注释。

6. **`hrtick_update`**:每次入队结束都会调用 `hrtick_update`,它做什么?
   什么情况下会启用 hrtimer 而不是普通 tick?(提示:`sched_feat(HRTICK)`)

7. **`sched_child_runs_first`**:这个 sysctl 让子进程先跑。在 QEMU 中
   `echo 1 > /proc/sys/kernel/sched_child_runs_first`,然后用一段 fork 测试
   程序观察 stdout 顺序是否改变。

---

⬅️ [上一站:红黑树](05_rbtree.md) ｜ ➡️ [下一站:周期调度与抢占](07_tick_and_preempt.md)
