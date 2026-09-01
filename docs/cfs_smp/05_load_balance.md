## 5.4 主角：`load_balance()` 框架 (fair.c:8911)

整个函数 ~300 行，骨架其实只有这些：

```c
static int load_balance(int this_cpu, struct rq *this_rq,
                        struct sched_domain *sd, enum cpu_idle_type idle,
                        int *continue_balancing)
{
    struct lb_env env = { ... };

redo:
    if (!should_we_balance(&env)) {              // ① "该不该轮我做？"
        *continue_balancing = 0;
        goto out_balanced;
    }

    group = find_busiest_group(&env);            // ② 挑最忙 group
    if (!group) goto out_balanced;

    busiest = find_busiest_queue(&env, group);   // ③ group 内挑最忙 CPU
    if (!busiest) goto out_balanced;

    env.src_cpu = busiest->cpu;
    env.src_rq  = busiest;

    if (busiest->nr_running > 1) {
more_balance:
        rq_lock_irqsave(busiest, &rf);
        cur_ld_moved = detach_tasks(&env);       // ④ 摘任务
        rq_unlock(busiest, &rf);

        if (cur_ld_moved) {
            attach_tasks(&env);                  // ⑤ 挂任务
            ld_moved += cur_ld_moved;
        }

        if (env.flags & LBF_NEED_BREAK) {        // 一次最多搬 32 个
            env.flags &= ~LBF_NEED_BREAK;
            goto more_balance;
        }
        ...
    }

    if (!ld_moved) {
        sd->nr_balance_failed++;
        if (need_active_balance(&env)) {         // ⑥ 累计失败 → 升级为 active balance
            stop_one_cpu_nowait(busiest_cpu,
                                active_load_balance_cpu_stop, ...);
        }
    } else {
        sd->nr_balance_failed = 0;
    }
    ...
}
```

**6 个步骤，每步可独立失败 → goto out_balanced**。下面挨个剖析。

### 5.4.1 `lb_env` —— 一次均衡的"上下文"(fair.c:7238)

```c
struct lb_env {
    struct sched_domain *sd;
    struct rq           *src_rq;     int src_cpu;
    int                  dst_cpu;    struct rq *dst_rq;
    struct cpumask      *dst_grpmask;     // 本地 group 的 cpumask
    int                  new_dst_cpu;     // dst_cpu 不行时，备选目标
    enum cpu_idle_type   idle;            // CPU_IDLE / CPU_NOT_IDLE / CPU_NEWLY_IDLE
    long                 imbalance;       // ★算出来的"该搬多少负载"
    struct cpumask      *cpus;            // 本次均衡考察的 CPU 集合
    unsigned int         flags;           // LBF_* 状态标志
    unsigned int         loop, loop_break, loop_max;  // 节奏控制
    struct list_head     tasks;           // ★临时持有：detach 出来等待 attach 的任务
};
```

`LBF_*` 标志（fair.c:7231）：

| Flag | 含义 |
|---|---|
| `LBF_ALL_PINNED` | 所有任务都被 cpus_allowed 钉住，没人能搬 |
| `LBF_NEED_BREAK` | 一批 32 个任务搬完了，先放 lock 喘口气 |
| `LBF_DST_PINNED` | dst_cpu 不在某些任务的 cpus_allowed 里 |
| `LBF_SOME_PINNED` | 有任务因 cpus_allowed 拒绝迁移 |
| `LBF_NOHZ_STATS/AGAIN` | NO_HZ 替身均衡时刷一遍 idle CPU 的 PELT |

---

## 5.5 第 ① 步：`should_we_balance()` (fair.c:8869)

```c
static int should_we_balance(struct lb_env *env)
{
    struct sched_group *sg = env->sd->groups;
    int cpu, balance_cpu = -1;

    if (!cpumask_test_cpu(env->dst_cpu, env->cpus))
        return 0;

    if (env->idle == CPU_NEWLY_IDLE)              // 即将 idle，谁先到谁做
        return 1;

    /* 从本地 group 找第一个 idle CPU */
    for_each_cpu_and(cpu, group_balance_mask(sg), env->cpus) {
        if (!idle_cpu(cpu))
            continue;
        balance_cpu = cpu;
        break;
    }
    if (balance_cpu == -1)
        balance_cpu = group_balance_cpu(sg);      // 没有 idle，就 group 里 cpumask 第一个

    return balance_cpu == env->dst_cpu;
}
```

### 为什么要这个函数？

每个 tick，**4 个 CPU 都会各自抛 SCHED_SOFTIRQ**——如果都跑 `load_balance`，会做 4 次重复工作、抢 4 次 rq lock。
`should_we_balance` 把"做这次均衡的权力"裁剪到 group 内**唯一一个 CPU**。

### 在 ARM64 4 核 2 cluster 上的具体效果

CPU0 在 MC 层（span={0,1}）做 `should_we_balance`：
- 本地 group = {0}（MC 层 CPU0 自己一个 group）
- group 内第一个 idle CPU = ... 看运行时
- 多数情况下 `balance_cpu == 0 == env->dst_cpu` → 返回 1，CPU0 主导

CPU1 同时也在 MC 层做：
- 本地 group = {1}
- `balance_cpu == 1`，返回 1

**注意 MC 层每个 group 只有 1 个 CPU，所以 CPU0 和 CPU1 各自都会做 MC 均衡**——只是 dst 不同（CPU0 看到 group α={0} β={1}，CPU1 看到 β={1} α={0}），各自试图把对方拉过来，结果由 `find_busiest_group` 决定方向。

DIE 层（span={0,1,2,3}）：
- CPU0 看到的 groups = `{0,1}`（local）, `{2,3}`（remote）
- 本地 group = {0,1}，`group_balance_mask` 也是 {0,1}
- 找第一个 idle，没有 idle 就用 cpumask_first({0,1}) = 0
- 只有当 `balance_cpu == env->dst_cpu == 0` 时 CPU0 才主导

→ **DIE 层默认只由 CPU0 主导**（如果 0,1 都忙），CPU1 在 DIE 层会 `should_we_balance == 0` 而退出。这就是把 4 个 CPU 的并发裁剪到"每层每 group 一个代表"。

### `continue_balancing = 0` 的连锁效应

回 `rebalance_domains`：

```c
if (!continue_balancing) break;
```

CPU1 在 MC 层 `should_we_balance == 1`（自己 group），但在 DIE 层就被裁掉。一旦在 DIE 层裁掉，**整个上层循环就 break**——节省遍历。

---

## 5.6 第 ② 步：`find_busiest_group()` (fair.c:8628)

挑选最忙的 group。先建立全 sd 的统计画像，再做几道筛子。

### 5.6.1 `update_sd_lb_stats` → `update_sg_lb_stats`

每个 group 算一个 `sg_lb_stats`（fair.c:7784）：

```c
struct sg_lb_stats {
    unsigned long avg_load;              // ★ group 平均负载（按 capacity 归一）
    unsigned long group_load;            // ★ group 负载总和
    unsigned long sum_weighted_load;     // weighted_cpuload 之和
    unsigned long load_per_task;         // 平均每任务负载
    unsigned long group_capacity;        // group 总算力
    unsigned long group_util;            // util_avg 总和
    unsigned int  sum_nr_running;        // CFS 任务总数
    unsigned int  idle_cpus;             // 该 group 内 idle CPU 数
    enum group_type group_type;          // ★ 分类：other/misfit/imbalanced/overloaded
    int           group_no_capacity;     // 是否过载
    unsigned long group_misfit_task_load;// 大小核：放不下的任务负载
};
```

`update_sg_lb_stats` 关键计算（fair.c:8152-8198）：

```c
for_each_cpu_and(i, sched_group_span(group), env->cpus) {
    struct rq *rq = cpu_rq(i);

    /* 偏向本地：本地用 target_load (取 max)，远端用 source_load (取 min) */
    if (local_group)
        load = target_load(i, load_idx);          // ★ 本地夸大
    else
        load = source_load(i, load_idx);          // ★ 远端缩小

    sgs->group_load     += load;
    sgs->group_util     += cpu_util(i);
    sgs->sum_nr_running += rq->cfs.h_nr_running;
    sgs->sum_weighted_load += weighted_cpuload(rq);
    if (!nr_running && idle_cpu(i))
        sgs->idle_cpus++;
    ...
}

sgs->group_capacity = group->sgc->capacity;
sgs->avg_load = (sgs->group_load * SCHED_CAPACITY_SCALE) / sgs->group_capacity;
```

**`target_load` vs `source_load` 的滞回设计**（防抖）：

- `target_load(cpu, idx) = max(rq->cpu_load[idx], weighted_cpuload(rq))`：本地负载**估高**
- `source_load(cpu, idx) = min(rq->cpu_load[idx], weighted_cpuload(rq))`：远端负载**估低**

→ 提高了"决定从远端往本地拉"的门槛——除非远端**显著**更忙，否则不动。这是防止 ping-pong 迁移的关键工程技巧。

### 5.6.2 `group_type` 四级分类 (fair.c:7224)

```c
enum group_type {
    group_other = 0,
    group_misfit_task,    // 大小核：小核上有"装不下"的大任务
    group_imbalanced,     // 因 cpus_allowed 失衡（pin 的副作用）
    group_overloaded,     // group_no_capacity == 1，过载
};
```

判定优先级：**overloaded > imbalanced > misfit > other**。group_type 越高，优先成为 busiest。

我们 ARM64 4 核（无大小核、无 cpus_allowed pin）一般只在 `group_other` ↔ `group_overloaded` 之间切换。

`group_classify` 用一个简单规则：
```c
if (sgs->group_no_capacity) return group_overloaded;
if (sg_imbalanced(group))   return group_imbalanced;
if (group_smaller_min_cpu_capacity(...))  return group_misfit_task;
return group_other;
```

### 5.6.3 `find_busiest_group` 的决策流（fair.c:8628）

```c
update_sd_lb_stats(env, &sds);                    // 收集所有 group 数据

local   = &sds.local_stat;
busiest = &sds.busiest_stat;

if (!sds.busiest || busiest->sum_nr_running == 0)  goto out_balanced;
sds.avg_load = SCHED_CAPACITY_SCALE * sds.total_load / sds.total_capacity;

/* 一系列短路 */
if (busiest->group_type == group_imbalanced)       goto force_balance;

if (env->idle != CPU_NOT_IDLE && group_has_capacity(env, local)
    && busiest->group_no_capacity)                  goto force_balance;

if (busiest->group_type == group_misfit_task)       goto force_balance;

if (local->avg_load >= busiest->avg_load)           goto out_balanced;
if (local->avg_load >= sds.avg_load)                goto out_balanced;

if (env->idle == CPU_IDLE) {
    /* 本地是 idle CPU，busiest 不过载 + idle 数差不多 → 不平 */
    if ((busiest->group_type != group_overloaded) &&
            (local->idle_cpus <= (busiest->idle_cpus + 1)))
        goto out_balanced;
} else {
    /* 本地非 idle，用 imbalance_pct 防抖 */
    if (100 * busiest->avg_load <=
            env->sd->imbalance_pct * local->avg_load)
        goto out_balanced;
}

force_balance:
    calculate_imbalance(env, &sds);
    return env->imbalance ? sds.busiest : NULL;
```

**`imbalance_pct` 在这里出场**：

- MC 层：117 → busiest_avg > local_avg × 1.17 才出手
- DIE 层：125 → busiest_avg > local_avg × 1.25 才出手

例：DIE 层 cluster 0（local）avg_load=600，cluster 1（busiest）avg_load=720
- `100 × 720 = 72000`
- `125 × 600 = 75000`
- 72000 ≤ 75000 → **不出手**（差距不够大）

把 cluster 1 改到 800：
- `100 × 800 = 80000 > 75000` → 出手

→ DIE 层"差 25% 才动"，MC 层"差 17% 就动"。**便宜的层更敏感**——和拓扑代价匹配。

---
