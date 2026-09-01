# 第 1 站:CFS 的设计哲学与发展脉络

## 学习目标

- 理解 CFS 名字中"完全公平"四个字的精确含义
- 知道 CFS 解决了 O(1) 调度器的哪些问题
- 建立"理想多任务 CPU"这一思维模型
- 在源码中找到 CFS 的版权信息和入口

## 源码定位

- 文件头注释:`kernel/sched/fair.c:1-22`
- 关键可调参数:`kernel/sched/fair.c:27-87`
- 调度类注册:`kernel/sched/fair.c:10500` 附近的 `fair_sched_class`

打开 `kernel/sched/fair.c`,前 22 行就是这套调度器的"出生证":

```c
// SPDX-License-Identifier: GPL-2.0
/*
 * Completely Fair Scheduling (CFS) Class (SCHED_NORMAL/SCHED_BATCH)
 *
 *  Copyright (C) 2007 Red Hat, Inc., Ingo Molnar <mingo@redhat.com>
 *  ...
 */
```

CFS 由 **Ingo Molnar** 在 2007 年合并入主线(Linux 2.6.23),取代了 Con Kolivas
提出的 RSDL 以及更早的 O(1) 调度器。

## 原理图解

### 1. "理想多任务 CPU" 模型

设想一台拥有 N 个任务的"理想 CPU":每一个时刻都给 N 个任务**各 1/N** 的算力,
没有切换、没有缓存抖动。这台 CPU 显然是物理上不存在的,因为单核 CPU 同一时刻
只能跑一个任务。

CFS 的核心思想:**让真实 CPU 的行为尽可能逼近这台理想 CPU**。它通过两个手段实现:

1. 给每个任务维护一个 `vruntime`(虚拟运行时间),记录"它已经获得了多少
   归一化后的 CPU 时间"。
2. 永远挑选 `vruntime` 最小的任务运行 —— 也就是"目前最被亏欠"的那个。

### 2. 与 O(1) 调度器的对比

| 维度 | O(1)(2.6.23 之前) | CFS(2.6.23 之后) |
| --- | --- | --- |
| 数据结构 | 140 个优先级数组(active/expired) | 红黑树,按 `vruntime` 排序 |
| 时间片 | 静态计算,与 nice 值离散映射 | 动态推导,`sched_period × weight/total_weight` |
| 公平性证明 | 启发式、需要复杂的交互性侦测 | 数学上由 vruntime 单调性自然保证 |
| 复杂度 | 入队/出队 O(1),但调优复杂 | 入队/出队 O(log N),实现简洁 |
| 优先级反转 | 需要专门的"交互性奖励" | nice → 权重 → vruntime 流速,无需特判 |

CFS 用 O(log N) 的复杂度换来了**算法上可证明的公平性**和**简洁的代码**,这是当
年合入主线的最大理由。

### 3. CFS 处理的调度类

`SCHED_NORMAL`(普通任务,绝大多数用户进程)、`SCHED_BATCH`(批处理任务,
对延迟不敏感)、`SCHED_IDLE`(极低优先级)都由 CFS 处理。
而 `SCHED_FIFO`、`SCHED_RR`、`SCHED_DEADLINE` 由其他调度类处理,优先级高于 CFS。

调度类优先级链(`kernel/sched/sched.h`):

```
stop_sched_class → dl_sched_class → rt_sched_class → fair_sched_class → idle_sched_class
```

`pick_next_task()` 按这个顺序逐类挑选,只有前面的类没有可运行任务时才轮到 CFS。

### 4. 关键可调参数

`kernel/sched/fair.c:40-87` 定义了几个理解 CFS 行为必备的 sysctl 参数:

| 变量 | 默认值 | 含义 |
| --- | --- | --- |
| `sysctl_sched_latency` | 6 ms | 调度周期 P(一轮内每个任务至少运行一次的目标时间) |
| `sysctl_sched_min_granularity` | 0.75 ms | 单次运行的最小粒度,防止过度切换 |
| `sysctl_sched_wakeup_granularity` | 1 ms | 唤醒抢占的"门槛",见第 7 站 |
| `sysctl_sched_migration_cost` | 0.5 ms | 迁移到其他 CPU 的成本估计 |

这些参数在运行时可以通过 `/proc/sys/kernel/sched_*` 查看和修改(本仓库内核已开启
`CONFIG_SCHED_DEBUG`)。

## 思考题

1. **公平 vs 响应**:CFS 追求的是"完全公平",但桌面用户更在乎 GUI 进程的响应
   性。请阅读 `place_entity()`(`kernel/sched/fair.c:3785`),解释 CFS 如何
   通过对**唤醒任务**的 vruntime 做"补偿"来兼顾这两个目标。

2. **理想模型与现实**:理想多任务 CPU 不需要时间片,但 CFS 仍然定义了
   `sysctl_sched_min_granularity = 0.75ms`。如果把这个值设成 1ns,会发生什么?
   如果设成 1s 呢?试着用 `/proc/sys/kernel/sched_min_granularity_ns` 改一下,
   并用 `vmstat 1` 观察 `cs`(context switch)字段。

3. **调度类顺序**:`SCHED_FIFO` 任务永远比 CFS 任务优先。如果一个 `SCHED_FIFO`
   任务死循环,CFS 任务还会被调度吗?查看 `kernel/sched/core.c` 中 `__schedule()`
   是如何遍历调度类的。

4. **历史回顾**:简述从 O(1) 调度器到 CFS 的演进,Con Kolivas 的 RSDL 提出了什么
   关键洞察?(可阅读 `Documentation/scheduler/sched-design-CFS.txt`)

5. **极端场景**:如果系统中只有 1 个 CFS 任务,CFS 还需要红黑树和 vruntime 吗?
   阅读 `pick_next_task_fair()`(`kernel/sched/fair.c:6900`)中的 fast-path,
   看看内核怎么对单任务情况做优化。

---

➡️ 下一站:[第 2 站 — 核心数据结构](02_data_structures.md)
