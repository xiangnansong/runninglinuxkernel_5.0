# 第 8 站:PELT 负载追踪与组调度

## 学习目标

- 理解为什么 nr_running 不足以衡量 CPU 负载,需要 PELT
- 看懂 PELT 的"几何级数衰减"模型与 1024us 周期
- 弄清楚 task_group / 组 sched_entity / 组 cfs_rq 的三层关系
- 知道 cgroup `cpu.shares` 是如何转换成 sched_entity 权重的

## 源码定位

| 内容 | 文件 | 行号 |
| --- | --- | --- |
| PELT 主体 | `kernel/sched/pelt.c` | 全文(393 行) |
| `decay_load()` 衰减计算 | `kernel/sched/pelt.c` | 36 |
| `accumulate_sum()` / `__update_load_avg_*` | `kernel/sched/pelt.c` | grep |
| `update_load_avg()` 调用入口 | `kernel/sched/fair.c` | grep `^update_load_avg` |
| `struct sched_avg` | `include/linux/sched.h` | 399 |
| `struct task_group` | `kernel/sched/sched.h` | 363 |
| 组调度宏与辅助函数 | `kernel/sched/fair.c` | 250-404 |
| `update_cfs_group()` 计算组权重 | `kernel/sched/fair.c` | grep `update_cfs_group` |
| 自动组(autogroup) | `kernel/sched/autogroup.c` | 全文 |

## 原理图解

### 1. 为什么需要 PELT

只看 `nr_running` 决策有两个问题:

- **不能区分活跃度**:一个 nr_running=2 的 CPU,可能两个任务都在跑满,也可能两个
  任务大部分时间在 sleep。负载差异巨大,但 nr_running 一样。
- **无法预测**:CPU 频率调整(`schedutil`)和负载均衡(`load_balance`)需要的是
  "未来一段时间会有多少负载",而不只是"现在有几个任务"。

PELT(Per-Entity Load Tracking)解决方案:**为每个调度实体追踪一个指数衰减的
"历史平均负载"**,既反映瞬时活动,又平滑短期抖动。

### 2. PELT 的核心数学

时间被分割成 1024us(约 1ms)的"周期"。任务在每个周期里被采样一次:

- 在该周期是否处于 runnable 状态(0 或 1024us 中的占比)
- 是否真的占着 CPU(running 状态)

历史样本随时间几何衰减,衰减比为:

```
y ≈ 0.97857206  ⇒  y^32 ≈ 0.5
```

也就是说,32 个周期(约 32ms)前的样本权重减半。`runnable_load_sum` 与
`util_sum` 都按这个规则演化:

```
load_sum_new = load_sum_old * y^Δ + new_contribution
```

`kernel/sched/pelt.c:36` 的 `decay_load()` 用查表 + 移位实现这个衰减,
保持 O(1) 复杂度:

```c
static u64 decay_load(u64 val, u64 n)
{
    ...
    if (unlikely(local_n >= LOAD_AVG_PERIOD)) {
        val >>= local_n / LOAD_AVG_PERIOD;     /* 每 32 个周期减半 */
        local_n %= LOAD_AVG_PERIOD;
    }
    val = mul_u64_u32_shr(val, runnable_avg_yN_inv[local_n], 32);
    return val;
}
```

### 3. `sched_avg` 字段含义

`include/linux/sched.h:399`:

```c
struct sched_avg {
    u64  last_update_time;        /* 上次更新的时间戳 */
    u64  load_sum;                /* 几何累加和 */
    u64  runnable_load_sum;
    u32  util_sum;
    u32  period_contrib;          /* 当前周期已累计的 us 数 (0..1024) */

    unsigned long load_avg;        /* 平均负载,0..weight */
    unsigned long runnable_load_avg;
    unsigned long util_avg;        /* 利用率,0..1024 */
    struct util_est util_est;
} ____cacheline_aligned;
```

- `load_avg`:**含 weight**,体现"对调度的影响力"
- `runnable_load_avg`:可运行(在队列上 + 在跑)时间占比 × weight
- `util_avg`:仅 running 时间占比,**不含 weight**,主要给频率调节器使用

### 4. PELT 在 CFS 中的注入点

每次以下时间点都会调用 `update_load_avg(cfs_rq, se, flags)`(`fair.c` 内多处):

- 实体入队前(`enqueue_entity`)
- 实体出队前(`dequeue_entity`)
- tick 中(`task_tick_fair`)
- 选 next 时(`set_next_entity`)
- yield、迁移、attach/detach 等场景

它内部调用 `__update_load_avg_se()`、`__update_load_avg_cfs_rq()`(`pelt.c`),
按当前时间戳与 `last_update_time` 的差,把若干个 1024us 周期的衰减一次性算完。

### 5. 组调度:三层结构

开启 `CONFIG_FAIR_GROUP_SCHED`(本仓库已启用)后,引入"任务组"概念:

```
                          根 cfs_rq (rq->cfs)
                          /                 \
                  组实体 G1.se          普通任务 T1.se
                       │
                  G1.cfs_rq (G1->my_q)
                  /            \
            组实体 G2.se     任务 T2.se
                  │
            G2.cfs_rq
                  │
              任务 T3.se
```

涉及三类对象:

| 类型 | 作用 |
| --- | --- |
| `struct task_group` | cgroup 视角下的"组"对象,每 CPU 都有一对 `se[cpu]` 和 `cfs_rq[cpu]` |
| 组的 `sched_entity`(在父 cfs_rq 上) | 在父 cfs_rq 红黑树里**代表整个组** |
| 组的 `cfs_rq`(组自己拥有) | 装着**组内的所有子实体**的红黑树 |

`struct task_group`(`kernel/sched/sched.h:363`):

```c
struct task_group {
    struct cgroup_subsys_state css;
    struct sched_entity **se;       /* per-CPU 数组 */
    struct cfs_rq      **cfs_rq;    /* per-CPU 数组 */
    unsigned long       shares;     /* 用户配置的 cpu.shares */
#ifdef CONFIG_SMP
    atomic_long_t       load_avg ____cacheline_aligned;
#endif
    ...
    struct task_group  *parent;
    struct list_head    siblings;
    struct list_head    children;
    struct cfs_bandwidth cfs_bandwidth;
};
```

### 6. 组实体的"权重"如何计算

用户在 cgroup v1 通过 `cpu.shares` 写入,在 v2 通过 `cpu.weight` 写入,最终都
被翻译成 `task_group->shares`(取值 `[2, 2^18]`,见 `MIN_SHARES`/`MAX_SHARES`,
`sched.h:415`)。

但是不同 CPU 上"组的实际负载"差异很大,如果直接用 shares 当组实体权重,
就会出现"轻量 CPU 上的组反而能抢更多资源"。所以内核动态调整:

```
组实体_se->load.weight ≈ shares × (本 CPU 上组负载) / (全局组负载)
```

具体算法叫 **proportional shares**,实现在 `update_cfs_group()`(`fair.c` grep)
中。每次 `update_load_avg` 后会调用它重新分摊。

### 7. 调度时的层级 vruntime

调度时,`pick_next_task_fair()` 沿组层级**向下**逐层挑选:

```
1. 在 rq->cfs 红黑树里选 vruntime 最小的实体 → G1.se
2. 进入 G1.cfs_rq,在它的红黑树里选 vruntime 最小的 → G2.se
3. 进入 G2.cfs_rq,选 vruntime 最小的 → T3
4. T3 是任务实体(my_q == NULL),返回它
```

每一层都有自己独立的 `min_vruntime`、自己的红黑树、自己的权重总和。
**层与层之间的 vruntime 不能直接比较**,因为它们属于不同的"基准时空"。
这是组调度公平性的来源。

### 8. autogroup:per-tty 自动组

`kernel/sched/autogroup.c` 实现了一个轻量级特性:**给每个 tty session 自动建一个
任务组**。这样在终端 A 跑 `make -j32` 不会让终端 B 的 vim 卡顿,因为编译进程
和 vim 进程不在同一个组。

通过 `/proc/sys/kernel/sched_autogroup_enabled` 开关。

## 思考题

1. **为什么是 1024us?** PELT 周期取 1024us 而不是 1ms,是为了什么?
   (提示:1024 是 2 的幂,移位代替除法。)

2. **衰减比 y ≈ 0.978**:精确值是 `y = (1/2)^(1/32)`。验证 `y^32 ≈ 0.5`。
   把 `LOAD_AVG_PERIOD` 改成 64 会有什么效果?(更看重历史还是更看重当前?)

3. **`load_avg` 与 `util_avg` 的差异**:同一个任务,`load_avg` 和 `util_avg`
   的关系是什么?用一个 nice=-20 的 CPU-bound 任务、一个 nice=19 的 CPU-bound
   任务,分别预测它们的两个值。

4. **GDB 看 PELT**:本仓库启用了 `CONFIG_SCHED_DEBUG`,在 QEMU 中:
   ```bash
   cat /proc/sched_debug
   ```
   找到一个 cfs_rq,观察 `.load_avg`、`.util_avg`、`.runnable_load_avg` 字段
   随负载变化的趋势。

5. **组调度的"穿透"**:阅读 `enqueue_task_fair()` 中的 `for_each_sched_entity`
   循环(`fair.c:5131`),解释为什么任务入队时要沿层级"逐级 enqueue"?如果
   只 enqueue 叶子层任务会有什么后果?

6. **shares 和 weight 的换算**:在 QEMU 中创建两个 cgroup,分别设置
   `cpu.shares = 1024` 和 `cpu.shares = 4096`,把两个 yes 进程分别放进去,
   用 `top` 观察 CPU 占比。实际值与你预期的 1:4 吻合吗?
   ```bash
   mkdir /sys/fs/cgroup/cpu/A /sys/fs/cgroup/cpu/B
   echo 1024 > /sys/fs/cgroup/cpu/A/cpu.shares
   echo 4096 > /sys/fs/cgroup/cpu/B/cpu.shares
   yes > /dev/null & echo $! > /sys/fs/cgroup/cpu/A/tasks
   yes > /dev/null & echo $! > /sys/fs/cgroup/cpu/B/tasks
   ```

7. **autogroup 的副作用**:开启 autogroup 后,启动一个 ssh 会话和一个本地 tty,
   分别跑 `stress -c 1`,二者会各占 50% CPU 还是某一方占 100%?为什么?
   (提示:autogroup 把它们放进了不同的隐式组,组级权重相等。)

8. **CFS bandwidth**:`struct task_group` 内嵌 `cfs_bandwidth`,允许设置
   `cpu.cfs_quota_us`、`cpu.cfs_period_us` 实现"每秒最多用 X ms CPU"的硬限制。
   它和 PELT 的"软"权重控制如何协同?(查阅 `account_cfs_rq_runtime()`、
   `throttle_cfs_rq()`。)

---

⬅️ [上一站:周期调度与抢占](07_tick_and_preempt.md) ｜ ➡️ [实验篇](09_labs.md)
