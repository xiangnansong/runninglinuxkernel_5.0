# 负载均衡核心函数讲解：find_busiest_group 与 update_sd_lb_stats

> 文件位置：`kernel/sched/fair.c`
> 讲解方式：先剥离所有特殊情况，抓住最核心的骨架，再一步步把分支扩展回去。

---

## 一、find_busiest_group()

### 这个函数是干什么的

它是周期性负载均衡 `load_balance()` 的"第一步"：在一个调度域（sched_domain）内，扫描所有调度组（sched_group），判断**当前 CPU 所在的本地组（local）和其他组之间是否存在不均衡**。如果存在，就返回那个最繁忙的组（busiest），并把"需要迁移多少负载"算出来填到 `env->imbalance`；如果均衡，返回 `NULL`。

后续 `load_balance()` 会拿到这个 busiest 组，再调用 `find_busiest_queue()` 找出组里最忙的 rq，从那里往本地 CPU 拉任务。

几个贯穿全文的角色：

- `local`（`sds.local_stat`）：dst_cpu 所在的组，也就是"我自己这组，准备往这里拉任务"。
- `busiest`（`sds.busiest_stat`）：统计出来的最忙的组，"准备从这里拉任务"。
- `env->imbalance`：最终算出的、需要搬移的负载量。

---

### 第一步：最核心的骨架

把所有特殊情况（能效、ASYM、misfit、imbalanced、idle 细分）全部剥掉，函数的本质只有 4 步：

```c
static struct sched_group *find_busiest_group(struct lb_env *env)
{
	struct sg_lb_stats *local, *busiest;
	struct sd_lb_stats sds;

	init_sd_lb_stats(&sds);          // 1. 清零统计结构

	update_sd_lb_stats(env, &sds);   // 2. 遍历所有 group,采集每组负载,选出 busiest

	local   = &sds.local_stat;
	busiest = &sds.busiest_stat;

	/* 3. 一系列判断:到底要不要均衡 */
	if (没有 busiest 或 busiest 里没有任务)
		goto out_balanced;

	if (local 比 busiest 还忙)
		goto out_balanced;

	/* ... 还不够忙,不值得搬 ... */
		goto out_balanced;

force_balance:
	/* 4. 确实不均衡,算出要搬多少 */
	calculate_imbalance(env, &sds);
	return env->imbalance ? sds.busiest : NULL;

out_balanced:
	env->imbalance = 0;
	return NULL;
}
```

记住这个主线就够了：**采集 → 选忙 → 一连串"要不要搬"的否决判断 → 算 imbalance**。下面的所有代码，都是往第 3 步里塞各种判断条件。

核心的两个否决判断（`fair.c:8687` 和 `8694`）：

```c
/* 本地组比最忙组还忙,没必要拉 */
if (local->avg_load >= busiest->avg_load)
	goto out_balanced;

/* 本地组已经高于全域平均,也别拉了 */
if (local->avg_load >= sds.avg_load)
	goto out_balanced;
```

这里的 `avg_load` 不是简单算术平均，而是**按算力归一化**的负载：

```c
/* fair.c:8660 */
sds.avg_load = (SCHED_CAPACITY_SCALE * sds.total_load) / sds.total_capacity;
```

乘以 `SCHED_CAPACITY_SCALE`（1024）再除以总算力，这样大小核（算力不同）之间才能公平比较——比较的是"负载/算力"的比率，而不是绝对负载。

---

### 第二步：扩展 group_type —— 给"忙"分级

`update_sd_lb_stats` 给每个组打了一个 `group_type` 标签（`fair.c:7224`），严重程度递增：

```c
enum group_type {
	group_other = 0,      // 正常
	group_misfit_task,    // 有个大任务跑在小核上,算力不匹配
	group_imbalanced,     // 因 cpus_allowed 等约束导致的"假"不均衡
	group_overloaded,     // 真正过载
};
```

函数里有三个分支专门处理"严重情况"，直接跳过常规的 avg_load 比较去强制均衡：

```c
/* fair.c:8668 — imbalanced:任务被 affinity 绑死了,常规公式假设"人人平等"会失效 */
if (busiest->group_type == group_imbalanced)
	goto force_balance;

/* fair.c:8675 — 我空闲、我有余力,而对方满了,赶紧拉过来 */
if (env->idle != CPU_NOT_IDLE && group_has_capacity(env, local) &&
    busiest->group_no_capacity)
	goto force_balance;

/* fair.c:8680 — misfit:大任务困在小核,无视平均负载也要处理 */
if (busiest->group_type == group_misfit_task)
	goto force_balance;
```

为什么要"无视 avg_load"？因为 avg_load 的比较隐含"所有 CPU 都能跑所有任务"的假设。一旦有 affinity 约束、大小核算力差异、或大任务卡在小核上，这个假设就破了，常规判断会误判为"均衡"，所以这些场景要短路掉常规逻辑、强制搬。

---

### 第三步：扩展 idle 的细分判断

到了 `fair.c:8697`，常规否决判断的最后一关会根据"本 CPU 当前是什么空闲状态"分两种策略：

```c
if (env->idle == CPU_IDLE) {
	/* 我本来就空闲。如果对方没过载,而且双方空闲 CPU 数差距 <= 1,
	 * 那这点差异不值得搬(搬了可能只是把不均衡转移给别人) */
	if ((busiest->group_type != group_overloaded) &&
	    (local->idle_cpus <= (busiest->idle_cpus + 1)))
		goto out_balanced;
} else {
	/* CPU_NEWLY_IDLE / CPU_NOT_IDLE:用 imbalance_pct 设一个门槛,
	 * busiest 必须忙到超过 local 的 imbalance_pct 倍,才认为值得搬 */
	if (100 * busiest->avg_load <=
	    env->sd->imbalance_pct * local->avg_load)
		goto out_balanced;
}
```

`imbalance_pct` 通常是 117~125 之类的值（每个 domain 层级不同）。这是一个**迟滞带（hysteresis）**：差距不够大就不动，避免任务在 CPU 间来回弹跳（ping-pong），那种抖动反而伤性能。

`CPU_IDLE` 这一支用"空闲 CPU 数"而不是 avg_load 做判断，逻辑更直接：我有空闲核，你也有空闲核，差不超过 1 个，各自安好，不用折腾。

---

### 第四步：开头的两个"特殊入口"

回到函数最前面，还有两个没讲的分支，它们在常规判断**之前**就介入：

```c
/* fair.c:8641 — EAS 能效感知调度 */
if (static_branch_unlikely(&sched_energy_present)) {
	struct root_domain *rd = env->dst_rq->rd;

	if (rcu_dereference(rd->pd) && !READ_ONCE(rd->overutilized))
		goto out_balanced;
}
```

当系统开启了 EAS（常见于手机大小核），且整个 root domain **没有过度使用（not overutilized）**时，直接判定为"均衡、不搬"。因为 EAS 模式下任务放置由能效模型决定，而不是靠"摊平负载"——只有真正过载时才退回到传统的负载均衡。

```c
/* fair.c:8652 — ASYM packing */
if (check_asym_packing(env, &sds))
	return sds.busiest;
```

ASYM_PACKING（比如 SMT、或 ITMT 这类有"优先核"的架构）倾向于把任务往编号靠前/性能更高的核上"打包"。这是一个独立于负载多少的策略，所以它**绕过所有 nice/负载检查**，直接返回 busiest。

---

### 第五步：收尾 —— 算 imbalance

所有否决都没触发，说明确实该搬：

```c
/* fair.c:8718 */
force_balance:
	env->src_grp_type = busiest->group_type;   // 记下来源组类型,find_busiest_queue 会用
	calculate_imbalance(env, &sds);             // 算出该搬多少负载
	return env->imbalance ? sds.busiest : NULL; // 算下来真有量才返回 busiest
```

注意最后 `env->imbalance ? sds.busiest : NULL`：即使走到了 force_balance，`calculate_imbalance` 也可能算出 imbalance 为 0（比如该搬的量太小被抹平），这时仍然返回 `NULL`，表示"算下来没东西可搬"。

---

### 整体串起来的决策流

```
init + 采集统计 (update_sd_lb_stats)
        │
        ├─ EAS 且未过载?         ──► 均衡 (NULL)
        ├─ ASYM packing?         ──► 直接返回 busiest
        ├─ 没有 busiest / 全空?  ──► 均衡 (NULL)
        │
   ┌────┴──── 强制均衡的特殊场景 (跳过 avg_load 比较) ────┐
   │  group_imbalanced / 我有余力对方满 / misfit         │──► force_balance
   └─────────────────────────────────────────────────────┘
        │
        ├─ local 比 busiest 忙?      ──► 均衡 (NULL)
        ├─ local 高于全域平均?       ──► 均衡 (NULL)
        ├─ idle 细分门槛 (差距太小)?  ──► 均衡 (NULL)
        │
force_balance:
   calculate_imbalance → 返回 busiest(或 imbalance=0 时返回 NULL)
```

**一句话总结**：这个函数的骨架就是"采集 → 选最忙的组 → 用一连串由特殊到一般的条件去否决搬迁，任何一条触发就判定均衡；全部通过则计算并返回该搬多少"。所有看起来复杂的分支，本质都是在回答同一个问题——"这点差异到底值不值得搬任务"——只是针对 EAS、大小核、affinity、SMT 这些破坏了"CPU 人人平等"假设的场景，各打了一个补丁而已。

---

## 二、update_sd_lb_stats()

### 这个函数是干什么的

它是上一个函数 `find_busiest_group()` 的"数据采集器"。`find_busiest_group` 负责**判断**要不要搬，而真正的**采集和选出最忙组**这件脏活，全在这里完成。

它的产出全部写进 `sds`（`struct sd_lb_stats`），关键字段：

- `sds->local` / `sds->local_stat`：本地组（dst_cpu 所在组）是哪个、它的统计。
- `sds->busiest` / `sds->busiest_stat`：最忙的组是哪个、它的统计。
- `sds->total_load` / `total_capacity` / `total_running`：整个调度域的汇总，用来后面算 `sds.avg_load`。

一句话：**遍历调度域里的每一个 sched_group，给每组算一份统计，顺手挑出"本地组"和"最忙组"，并累加全域总量。**

---

### 第一步：最核心的骨架

把 NUMA、NO_HZ、prefer_sibling、overload 标志全部剥掉，本质就是一个"遍历所有组"的循环：

```c
static inline void update_sd_lb_stats(struct lb_env *env, struct sd_lb_stats *sds)
{
	struct sched_group *sg = env->sd->groups;   // 从域的第一个组开始
	struct sg_lb_stats *local = &sds->local_stat;
	struct sg_lb_stats tmp_sgs;

	do {
		struct sg_lb_stats *sgs = &tmp_sgs;   // 默认用临时缓冲区
		int local_group;

		/* 1. 这个组是不是"我自己"所在的组? */
		local_group = cpumask_test_cpu(env->dst_cpu, sched_group_span(sg));
		if (local_group) {
			sds->local = sg;
			sgs = local;          // 是的话,统计直接写进 local_stat
		}

		/* 2. 采集这个组的负载统计 */
		update_sg_lb_stats(env, sg, sgs, &sg_status);

		if (local_group)
			goto next_group;      // 本地组不参与"选最忙",跳过

		/* 3. 这个组比当前记录的 busiest 还忙吗? */
		if (update_sd_pick_busiest(env, sds, sg, sgs)) {
			sds->busiest = sg;
			sds->busiest_stat = *sgs;   // 是的话,记下它
		}

next_group:
		/* 4. 累加全域总量 */
		sds->total_running  += sgs->sum_nr_running;
		sds->total_load     += sgs->group_load;
		sds->total_capacity += sgs->group_capacity;

		sg = sg->next;
	} while (sg != env->sd->groups);   // 环形链表,回到起点结束
}
```

记住这个主线：**对每个组 → 判断是不是本地组 → 采集统计（`update_sg_lb_stats`） → 如果不是本地组就比一比谁更忙（`update_sd_pick_busiest`） → 累加全域总和**。循环走完，`sds` 里就有了 local、busiest 和全域汇总三样东西，正好喂给 `find_busiest_group` 去做判断。

这里有三个关键设计细节：

**(1) 为什么本地组用 `local`、其他组用 `tmp_sgs`？**
本地组的统计要长期保留（后面比较要用），所以直接写进 `sds->local_stat`。其他组只是"路过比一比"，用一个临时变量 `tmp_sgs` 反复覆盖即可，只有当某个组被选为 busiest 时，才用 `sds->busiest_stat = *sgs` 把它**拷贝**进 busiest_stat 保存下来。

**(2) 为什么本地组 `goto next_group` 跳过选忙？**
因为本地组是"要往里拉任务的目的地"，它自己不可能是"被拉的源头"。busiest 只在其他组里选。但本地组的负载仍然要参与第 4 步的全域累加。

**(3) 环形链表遍历**
`sched_group` 是一个环形链表，所以用 `do...while (sg != env->sd->groups)`，从第一个开始，绕一圈回到起点为止。

---

### 第二步：扩展 local_group 里的 capacity 更新

本地组分支里还有一段（`fair.c:8351`）：

```c
if (local_group) {
	sds->local = sg;
	sgs = local;

	if (env->idle != CPU_NEWLY_IDLE ||
	    time_after_eq(jiffies, sg->sgc->next_update))
		update_group_capacity(env->sd, env->dst_cpu);
}
```

`update_group_capacity` 重新计算这个组的"算力"（group_capacity）——也就是扣掉被 RT 任务、中断、thermal 压制后，还能给 CFS 用多少。这个计算有点重，所以：

- 普通均衡（周期性）：每次都更新，保证数据新鲜。
- `CPU_NEWLY_IDLE`（CPU 刚变空闲，触发得非常频繁）：加一个 `next_update` 时间戳节流，没到点就不重算，避免热路径上反复做昂贵计算。

为什么只在本地组算？因为算力更新是按组打表缓存的（存在 `sg->sgc` 里），每个 CPU 做均衡时只负责刷新自己这一组，其他组由它们各自的 CPU 负责，分摊开销。

---

### 第三步：扩展 prefer_sibling —— 主动"贬低"其他组

```c
/* fair.c:8334 */
bool prefer_sibling = child && child->flags & SD_PREFER_SIBLING;

/* fair.c:8371 */
if (prefer_sibling && sds->local &&
    group_has_capacity(env, local) &&
    (sgs->sum_nr_running > local->sum_nr_running + 1)) {
	sgs->group_no_capacity = 1;
	sgs->group_type = group_classify(sg, sgs);
}
```

`SD_PREFER_SIBLING` 的含义是：**任务应该尽量铺开到不同的兄弟组，而不是挤在一组里。** 典型场景是 SMT——两个超线程挤在一个物理核上，不如分到两个物理核，各自独享资源更快。

这段代码的手法是：当某个非本地组的任务数明显多于本地组（`> local + 1`），并且本地组确实还装得下时，就**人为地把这个组标记成"没余量"（`group_no_capacity = 1`）并重新分类**。

为什么要"造假"？这相当于人为放大不均衡信号，促使后面的 `find_busiest_group` 把这个组选成 busiest 并触发搬迁，从而把堆积的任务"摊"到本地组去。两个附加条件（本地组有余量、对方任务数确实更多）是防止误判：避免本地组明明也满了还硬拉，或者只差一两个任务就来回折腾。

---

### 第四步：扩展全域标志 —— overload / overutilized

循环结束后，函数还要在"根调度域"这一层更新两个全局指示器（`fair.c:8404`）：

```c
if (!env->sd->parent) {          // 只在最顶层 root domain 做
	struct root_domain *rd = env->dst_rq->rd;

	/* 是否有组过载(有任务在排队等 CPU) */
	WRITE_ONCE(rd->overload, sg_status & SG_OVERLOAD);

	/* 是否过度使用(利用率逼近算力上限),EAS 的"临界点" */
	WRITE_ONCE(rd->overutilized, sg_status & SG_OVERUTILIZED);
} else if (sg_status & SG_OVERUTILIZED) {
	WRITE_ONCE(env->dst_rq->rd->overutilized, SG_OVERUTILIZED);
}
```

`sg_status` 是在每次 `update_sg_lb_stats` 里用 `|=` 累积起来的标志位。这两个标志正是上一个函数 `find_busiest_group` 用到的：

- `rd->overload`：有没有 CPU 真的在排队，影响是否值得做均衡。
- `rd->overutilized`：就是 `find_busiest_group` 开头那个 EAS 分支读的字段——

```c
/* find_busiest_group, fair.c:8644 */
if (rcu_dereference(rd->pd) && !READ_ONCE(rd->overutilized))
	goto out_balanced;
```

也就是说，**这里写 overutilized，那里读 overutilized**，两个函数通过 root_domain 这块共享状态对接起来：系统没"过度使用"时，EAS 完全接管任务放置，传统负载均衡直接让路。

---

### 第五步：NUMA 与 NO_HZ 的边角

剩下两块是特定配置下的补充，不影响主线：

```c
/* fair.c:8401 — NUMA 域:给 busiest 组分类(regular/remote/all),
 * 供 find_busiest_queue 避开"已经在正确节点上"的 NUMA 任务 */
if (env->sd->flags & SD_NUMA)
	env->fbq_type = fbq_classify_group(&sds->busiest_stat);
```

```c
/* fair.c:8337, 8392 — NO_HZ:tickless 模式下,
 * 顺带刷新那些进入空闲、负载已"blocked"的 CPU 的统计,
 * 避免它们的陈旧负载干扰均衡决策 */
```

这两块可以先当背景知识，理解主线时可以略过。

---

### 整体串起来

```
遍历 sd 里每个 sched_group:
        │
        ├─ 是本地组(含 dst_cpu)?
        │     ├─ 记 sds->local,统计写进 local_stat
        │     └─ (按需)刷新本组 group_capacity
        │     └─ goto 累加  ← 本地组不参选 busiest
        │
        ├─ 采集本组统计 update_sg_lb_stats
        ├─ (prefer_sibling) 任务堆积且本地有余量 → 人为标记无余量,放大信号
        ├─ update_sd_pick_busiest:比当前 busiest 更忙 → 更新 sds->busiest
        │
        └─ 累加 total_running / total_load / total_capacity
        │
循环结束:
   ├─ (NUMA) 给 busiest 分类 fbq_type
   ├─ (NO_HZ) 刷新 blocked CPU 的下次更新时间
   └─ (root domain) 写 rd->overload / rd->overutilized  ──► find_busiest_group 读取
```

**一句话总结**：`update_sd_lb_stats` 就是把"判断"所需的全部原料备齐——它绕调度组环形链表走一圈，给每组算一份 `sg_lb_stats`，分出 local 和 busiest 两个主角，累加出全域总量好让上层算平均负载，再把 overload/overutilized 这些全局信号写进 root_domain。它和 `find_busiest_group` 的分工很清晰：**这里只采集、不决策；那里只决策、不采集。**

---

## 三、两个函数的协作关系

```
load_balance()
   │
   └─ find_busiest_group(env)          ← 决策:要不要搬?搬哪个组?搬多少?
        │
        ├─ update_sd_lb_stats(env,&sds)  ← 采集:遍历所有组,算统计,选 busiest
        │     │
        │     ├─ update_sg_lb_stats()        (单个组怎么算统计 / 打 group_type)
        │     └─ update_sd_pick_busiest()    (两个组之间怎么比谁更忙)
        │
        └─ calculate_imbalance()         ← 算出要搬移的负载量 env->imbalance
```

- **采集与决策分离**：`update_sd_lb_stats` 只负责把数据备齐，`find_busiest_group` 只负责拿数据做判断。
- **共享状态对接**：两者通过 `sds`（本次局部）和 `root_domain`（跨调用全局，如 overutilized）传递信息。
- **还可继续往下展开的黑盒**：`update_sg_lb_stats`（单组统计与 group_type 分类）、`update_sd_pick_busiest`（组间比较规则）、`calculate_imbalance`（搬移量计算）。
