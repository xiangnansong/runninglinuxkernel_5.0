# Linux CFS 调度器学习教程(基于本仓库 Linux 5.0 源码)

> 本教程基于 `runninglinuxkernel_5.0` 仓库的 Linux 5.0 内核源码,带你从零理解
> CFS(Completely Fair Scheduler,完全公平调度器)的设计哲学、数据结构、
> 关键算法,以及在 ARM64 + QEMU 环境下的实操技巧。
>
> 每一站包含:**学习目标 → 源码精确定位 → 原理图解 → 思考题**。
> 思考题答案不直接给出,鼓励你自己阅读源码、设计实验并在 QEMU 中验证。

## 适用读者

- 熟悉 C 语言、了解操作系统进程调度基本概念
- 想深入阅读 Linux 内核 `kernel/sched/` 源码
- 计划在本仓库的 QEMU + GDB 环境中做调度相关实验

## 学习路线图(8 站)

| 站 | 主题 | 主要源文件 |
| --- | --- | --- |
| [第 1 站](01_concepts.md) | CFS 的设计哲学与发展脉络 | `kernel/sched/fair.c` 头部注释 |
| [第 2 站](02_data_structures.md) | 核心数据结构:`sched_entity` / `cfs_rq` / `load_weight` | `include/linux/sched.h`, `kernel/sched/sched.h` |
| [第 3 站](03_weight_and_load.md) | nice 值、权重表与负载计算 | `kernel/sched/core.c:7044`, `kernel/sched/fair.c:218` |
| [第 4 站](04_vruntime.md) | vruntime 的计算与 `min_vruntime` 推进 | `kernel/sched/fair.c:495,627,802` |
| [第 5 站](05_rbtree.md) | 红黑树与就绪队列管理 | `kernel/sched/fair.c:530,560,565` |
| [第 6 站](06_enqueue_dequeue.md) | 任务入队、出队、唤醒、迁移 | `kernel/sched/fair.c:3785,5110,5192` |
| [第 7 站](07_tick_and_preempt.md) | 周期调度、抢占决策与挑选下一个任务 | `kernel/sched/fair.c:643,657,4025,6900` |
| [第 8 站](08_pelt_and_group.md) | PELT 负载追踪与组调度(cgroup) | `kernel/sched/pelt.c`, `kernel/sched/fair.c:250-404` |
| [实验篇](09_labs.md) | 5 个动手实验(GDB / ftrace / 修改参数) | 综合 |

## 使用建议

1. **先粗读后精读**:每一站先看"原理图解"建立直觉,再翻到引用的源码行号逐行阅读。
2. **配合 GDB**:本仓库的内核以 `-O0` 编译,GDB 中变量不会显示 `<optimized out>`。
   ```bash
   ./run_debian_arm64.sh run debug          # 终端 1
   aarch64-linux-gnu-gdb vmlinux            # 终端 2
   (gdb) target remote :1234
   (gdb) b update_curr
   ```
3. **用 ftrace 验证**:见 `TRACE_KERNEL_BOOT_README.md`,可以跟踪 `pick_next_task_fair`、
   `enqueue_task_fair` 等关键函数的真实调用流。
4. **修改参数做对比**:`sysctl_sched_latency`、`sysctl_sched_min_granularity`
   都是可调参数(`/proc/sys/kernel/`),改完观察实际行为变化是最好的学习方式。

## 阅读约定

- 行号格式:`kernel/sched/fair.c:802` 表示该文件的第 802 行。
- 所有行号基于本仓库当前 commit;若你已修改源码,请用 `grep -n` 自行核对。
- 中文术语后括号给出英文原词,便于检索源码注释。
