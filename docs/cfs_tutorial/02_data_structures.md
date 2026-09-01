# 第 2 站:核心数据结构

## 学习目标

- 掌握 `sched_entity`、`cfs_rq`、`load_weight` 三个最核心结构体的字段含义
- 理解"任务(`task_struct`)"和"调度实体(`sched_entity`)"的区别
- 看懂红黑树字段如何嵌入调度实体

## 源码定位

| 结构体 | 文件 | 行号 |
| --- | --- | --- |
| `struct load_weight` | `include/linux/sched.h` | 314 |
| `struct sched_avg` | `include/linux/sched.h` | 399 |
| `struct sched_entity` | `include/linux/sched.h` | 447 |
| `struct task_struct` 中嵌入的 `se` | `include/linux/sched.h` | 644 |
| `struct cfs_rq` | `kernel/sched/sched.h` | 488 |
| `struct rq` 中的 `cfs` | `kernel/sched/sched.h` | (搜 `struct cfs_rq cfs;`) |

## 原理图解

### 1. 三层结构概览

```
┌─────────────────────── struct rq (per-CPU) ───────────────────────┐
│                                                                    │
│   struct cfs_rq cfs;   ← 本 CPU 的 CFS 就绪队列                    │
│   struct rt_rq  rt;                                                │
│   struct dl_rq  dl;                                                │
│                                                                    │
│  ┌──────────────── struct cfs_rq ────────────────┐                │
│  │  load        : 队列总权重                       │                │
│  │  nr_running  : 任务数                           │                │
│  │  min_vruntime: 最小 vruntime(单调递增)         │                │
│  │  tasks_timeline: rb_root_cached(红黑树根)       │                │
│  │  curr / next / last / skip                      │                │
│  │     ↓                                            │                │
│  │   红黑树(每个节点是一个 sched_entity)          │                │
│  │           ┌─ se ─┐                               │                │
│  │          /        \                              │                │
│  │       ┌─ se ─┐  ┌─ se ─┐                         │                │
│  └──────────────────────────────────────────────────┘                │
└────────────────────────────────────────────────────────────────────┘

每个 task_struct 内嵌:
  struct sched_entity se;  ← 调度的最小单位
```

### 2. `struct load_weight`(权重)

`include/linux/sched.h:314`:

```c
struct load_weight {
    unsigned long  weight;        /* 该实体的权重(由 nice 决定) */
    u32            inv_weight;    /* 2^32 / weight,预先算好以将除法变乘法 */
};
```

只有两个字段,但渗透在 CFS 的几乎所有计算中。`inv_weight` 是性能优化:在 32 位
和 64 位平台上,运行时除法都比乘法贵得多,内核用 "乘 inv_weight 再右移 32 位"
代替除以 weight。详见 `__calc_delta()`(`kernel/sched/fair.c:218`)。

### 3. `struct sched_entity`(调度实体)

`include/linux/sched.h:447`(节选关键字段):

```c
struct sched_entity {
    struct load_weight  load;          /* 权重 */
    unsigned long       runnable_weight;
    struct rb_node      run_node;      /* 红黑树节点(嵌入式) */
    struct list_head    group_node;
    unsigned int        on_rq;         /* 是否在就绪队列上 */

    u64  exec_start;           /* 上次开始执行的时间(物理) */
    u64  sum_exec_runtime;     /* 累计实际运行时间 */
    u64  vruntime;             /* 累计虚拟运行时间 ← CFS 的核心! */
    u64  prev_sum_exec_runtime;

#ifdef CONFIG_FAIR_GROUP_SCHED
    int                  depth;
    struct sched_entity *parent;
    struct cfs_rq       *cfs_rq;       /* 自己挂在哪个 cfs_rq 上 */
    struct cfs_rq       *my_q;         /* 自己拥有的 cfs_rq(组实体) */
#endif

#ifdef CONFIG_SMP
    struct sched_avg    avg;           /* PELT 负载追踪,见第 8 站 */
#endif
};
```

为什么不直接把这些字段塞进 `task_struct`?**因为开启了 cgroup 组调度后,
"调度实体"既可以是一个进程,也可以是一个进程组**(任务组)。统一抽象为
`sched_entity` 后,红黑树的节点既可能是真实任务,也可能是另一棵子红黑树
的"代表"。详见第 8 站。

### 4. `struct cfs_rq`(CFS 就绪队列)

`kernel/sched/sched.h:488`(节选):

```c
struct cfs_rq {
    struct load_weight    load;            /* 队列总权重 */
    unsigned long         runnable_weight;
    unsigned int          nr_running;      /* 队列上的实体数 */
    unsigned int          h_nr_running;    /* 含子组的总任务数 */

    u64  exec_clock;
    u64  min_vruntime;       /* 队列基准 vruntime,单调递增 */

    struct rb_root_cached tasks_timeline;  /* 红黑树根,缓存了最左节点 */

    struct sched_entity *curr;   /* 当前运行的实体(不在树上!) */
    struct sched_entity *next;   /* 唤醒抢占时的"下一个"提示 */
    struct sched_entity *last;   /* 上次抢占的任务,提示局部性 */
    struct sched_entity *skip;   /* sched_yield 想跳过的实体 */

#ifdef CONFIG_SMP
    struct sched_avg  avg;       /* PELT 队列级负载 */
    ...
#endif
#ifdef CONFIG_FAIR_GROUP_SCHED
    struct rq          *rq;
    struct task_group  *tg;      /* 反向指回所属任务组 */
    ...
#endif
};
```

**关键事实(易错!)**:`cfs_rq->curr` 不会同时挂在红黑树上。任务被选中执行时
会从红黑树中"摘"出来,赋值给 `curr`;被抢占或时间片用尽时再放回去。所以
"红黑树最左节点"严格说是"未在跑且 vruntime 最小的实体"。`pick_next_entity()`
对此有专门处理(`fair.c:4104`)。

### 5. `rb_root_cached` 的妙用

红黑树本身查找最小值是 O(log N);但 CFS 每次调度都要拿最小 vruntime,
所以用 `rb_root_cached` 缓存了 leftmost 指针,变成 O(1)。
插入/删除时由 `rb_insert_color_cached()` / `rb_erase_cached()` 自动维护。

```c
/* fair.c:565 */
struct sched_entity *__pick_first_entity(struct cfs_rq *cfs_rq)
{
    struct rb_node *left = rb_first_cached(&cfs_rq->tasks_timeline);
    if (!left) return NULL;
    return rb_entry(left, struct sched_entity, run_node);
}
```

### 6. 从 `task_struct` 到 `cfs_rq` 的反向定位

```c
/* fair.c:408,427 (非组调度版) */
static inline struct task_struct *task_of(struct sched_entity *se)
{
    return container_of(se, struct task_struct, se);
}

static inline struct cfs_rq *cfs_rq_of(struct sched_entity *se)
{
    struct task_struct *p = task_of(se);
    return &task_rq(p)->cfs;
}
```

`container_of` 是内核常用宏:从被嵌入的成员指针反推宿主结构体地址。
理解 `sched_entity` 与 `task_struct` 关系的最直接方法。

## 思考题

1. **为什么需要 `sched_entity`?** 如果 CFS 不支持组调度,直接把 vruntime、
   load 等字段放进 `task_struct` 是不是更简单?请阅读 `fair.c:250-404`
   的 `CONFIG_FAIR_GROUP_SCHED` 段,说明在组调度下 `sched_entity` 充当了
   什么"中间层"。

2. **`curr` 不在树上**:写一段伪代码模拟"任务 A 正在运行,任务 B、C 在树上,
   时间片到达,B 被选中执行"的全过程,标注哪些时刻 A、B 分别在/不在
   `tasks_timeline` 上。可对照 `set_next_entity()`(`fair.c:4062`)和
   `put_prev_entity()`(自行 grep)。

3. **`min_vruntime` 单调递增**:阅读 `update_min_vruntime()`(`fair.c:495`)
   并解释最后一句 `cfs_rq->min_vruntime = max_vruntime(...)` 为什么用 `max`?
   如果改成 `min`,会出什么问题?

4. **`inv_weight` 的精度**:`load_weight.inv_weight` 是 32 位无符号整数,
   对应 `2^32 / weight`。当 weight 很小(比如 nice=19 时 weight=15)时
   `inv_weight` 接近 2^28,精度损失大吗?对比 `sched_prio_to_wmult` 表
   (`kernel/sched/core.c:7062`)中的精确值估算误差。

5. **next/last/skip 的用途**:`cfs_rq` 有三个"提示"指针,分别在什么场景被设置?
   `last` 在 `wakeup_preempt_entity()` 中如何参与决策?(`fair.c:4140`)

---

⬅️ [上一站:CFS 设计哲学](01_concepts.md) ｜ ➡️ [下一站:权重与负载](03_weight_and_load.md)
