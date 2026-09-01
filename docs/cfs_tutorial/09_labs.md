# 实验篇:5 个 CFS 动手实验

这一篇所有实验都在本仓库提供的 ARM64 + QEMU 环境中完成。
内核已经以 `-O0` 编译,GDB 不会有 `<optimized out>`,sched_debug 也已开启。

## 准备工作

```bash
# 编译内核(只需做一次)
./run_debian_arm64.sh build_kernel

# 更新 rootfs(只需做一次)
sudo ./run_debian_arm64.sh update_rootfs

# 后续每次实验只要启动 QEMU 即可
./run_debian_arm64.sh run            # 普通运行
./run_debian_arm64.sh run debug      # GDB 调试运行
```

QEMU 登录:`benshushu` / `123`。

`kmodules/` 目录会自动挂到 QEMU 内的 `/mnt/`,所以**自定义工具放到 `kmodules/`
就能直接进 QEMU 用**。

---

## 实验 1:观察 nice 值对 CPU 占比的影响

**目标**:实际验证 `sched_prio_to_weight[]` 表与 1.25 公比的设计。

### 步骤

QEMU 启动后:

```bash
# 关闭多核以排除负载均衡干扰,仅用 1 个 vCPU
# (本仓库默认 -smp 4,实验时可改 run_debian_arm64.sh 暂时改成 -smp 1)

# 跑两个 yes,nice 分别为 0 和 5
nice -n 0 yes > /dev/null &
PID1=$!
nice -n 5 yes > /dev/null &
PID2=$!

# 等 5 秒后采样
sleep 5
ps -o pid,ni,pcpu,comm -p $PID1,$PID2

kill $PID1 $PID2
```

### 预期与思考

- nice=0 权重 1024,nice=5 权重 335,比例约 **3.06 : 1**
- 即 nice=0 拿到约 75.4%,nice=5 拿到约 24.6%
- 如果误差较大,可能是 SMP 负载均衡把两个任务搬到了不同 CPU(各占满一个核)。
  尝试 `taskset -c 0 -p $PID1 && taskset -c 0 -p $PID2` 钉到同一核再观察。

**思考题**:换成 nice=-5 vs nice=5(权重比 3121:335 ≈ 9.3),预测占比后实测。

---

## 实验 2:用 GDB 单步跟踪 `update_curr`

**目标**:亲眼看见一次 vruntime 累加。

### 步骤

终端 1:
```bash
./run_debian_arm64.sh run debug      # QEMU 启动后会停在 -S 状态
```

终端 2:
```bash
cd /home/doula/project/runninglinuxkernel_5.0
aarch64-linux-gnu-gdb vmlinux
```

GDB 内:
```gdb
target remote :1234
b update_curr
c                       # 让内核跑起来,登录到 shell

# QEMU 内运行:
#   yes > /dev/null &
# 然后会立刻触发断点

(gdb) p curr->load.weight
(gdb) p curr->vruntime
(gdb) p delta_exec
(gdb) n
(gdb) p curr->vruntime  # 比较前后差值是否 ≈ delta_exec × 1024 / weight
```

### 预期

`Δvruntime ≈ delta_exec × NICE_0_LOAD / curr->load.weight`。
NICE_0_LOAD 在 64 位上是 `1024 << 10 = 1048576`,所以记得乘上 1024。

---

## 实验 3:用 ftrace 跟踪调度热点函数

**目标**:统计 `pick_next_task_fair`、`enqueue_task_fair` 的调用频率与耗时。

### 步骤(QEMU 内)

```bash
mount -t tracefs none /sys/kernel/tracing 2>/dev/null
cd /sys/kernel/tracing

# 选择 function_graph 追踪器
echo function_graph > current_tracer

# 只过滤我们关心的函数
echo 'pick_next_task_fair' > set_ftrace_filter
echo 'enqueue_task_fair' >> set_ftrace_filter
echo 'dequeue_task_fair' >> set_ftrace_filter
echo 'check_preempt_tick' >> set_ftrace_filter
echo 'update_curr' >> set_ftrace_filter

# 清空 buffer 并开启
echo > trace
echo 1 > tracing_on

# 制造一些负载
for i in 1 2 3 4; do yes > /dev/null & done
sleep 2
killall yes

echo 0 > tracing_on

# 看结果(只截前 50 行)
head -200 trace
```

### 预期

输出会形如:
```
 1)               |  pick_next_task_fair() {
 1)   0.500 us    |    update_curr();
 1)   0.250 us    |    __pick_first_entity();
 1)   2.100 us    |  }
```

**思考题**:看看 `update_curr` 的耗时和 `pick_next_task_fair` 的耗时差几个数量级?
为什么前者会更频繁?

可以用本仓库的封装脚本一键完成:
```bash
./trace_kernel_boot.sh ftrace function_graph "pick_next_task_fair,update_curr"
```

---

## 实验 4:修改 `sysctl_sched_latency` 观察影响

**目标**:体会调度周期 P 对吞吐和延迟的折中。

### 步骤(QEMU 内)

```bash
# 查看默认值(应该是 6ms)
cat /proc/sys/kernel/sched_latency_ns
cat /proc/sys/kernel/sched_min_granularity_ns

# 备份并改成 60ms(变"懒")
echo 60000000   > /proc/sys/kernel/sched_latency_ns
echo 7500000    > /proc/sys/kernel/sched_min_granularity_ns

# 跑 CPU-bound 任务,统计上下文切换率
( yes > /dev/null & ) ; ( yes > /dev/null & )
vmstat 1 5 | awk 'NR>2 {print "cs=" $12}'
killall yes

# 改成 1ms(变"急")
echo 1000000  > /proc/sys/kernel/sched_latency_ns
echo 125000   > /proc/sys/kernel/sched_min_granularity_ns

( yes > /dev/null & ) ; ( yes > /dev/null & )
vmstat 1 5 | awk 'NR>2 {print "cs=" $12}'
killall yes

# 恢复默认
echo 6000000 > /proc/sys/kernel/sched_latency_ns
echo 750000  > /proc/sys/kernel/sched_min_granularity_ns
```

### 预期与思考

- `sched_latency=60ms` 时切换稀疏,CPU 利用率高,但单任务的最坏响应延迟变大
- `sched_latency=1ms` 时切换频繁,响应快但 cache 失效多
- **延迟敏感型(数据库、桌面)** 倾向小 latency;**吞吐型(批处理)** 倾向大 latency

---

## 实验 5:用 `/proc/sched_debug` 看红黑树与 PELT

**目标**:直接读取内核暴露的调度器状态。

### 步骤(QEMU 内)

```bash
# 启动一些负载
for i in 1 2 3; do
    nice -n $((i*5)) yes > /dev/null &
done

# 在另一个终端(或 tmux 窗口)
cat /proc/sched_debug | less
```

### 看点

- `cfs_rq[N]:/` 段下的 `.load`、`.runnable_load_avg`、`.util_avg` 显示队列总负载
- `runnable tasks` 段下的每个任务:
  - `tree-key`:就是 vruntime
  - `switches`、`prio`:切换次数与优先级
- 多核机器上比较各 CPU 的 `.load_avg` 看负载均衡是否均匀

**思考题**:用上面命令跑 3 个 nice 不同的 yes 后,`tree-key` 的相对差值
是否反映了 1.25 公比?

---

## 实验 6(挑战):写一个内核模块打印 cfs_rq 状态

**目标**:综合前面所有知识,定制一个观测工具。

把以下文件放到 `kmodules/cfs_inspect/`:

```c
// cfs_inspect.c
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/sched.h>
#include <linux/cpumask.h>
#include "../../kernel/sched/sched.h"   /* 仅供学习,生产代码不要这样做 */

static int __init cfs_inspect_init(void)
{
    int cpu;
    for_each_online_cpu(cpu) {
        struct rq *rq = cpu_rq(cpu);
        struct cfs_rq *cfs = &rq->cfs;
        pr_info("CPU%d: nr=%u h_nr=%u min_vruntime=%llu load.weight=%lu\n",
            cpu, cfs->nr_running, cfs->h_nr_running,
            cfs->min_vruntime, cfs->load.weight);
    }
    return 0;
}

static void __exit cfs_inspect_exit(void) { }
module_init(cfs_inspect_init);
module_exit(cfs_inspect_exit);
MODULE_LICENSE("GPL");
```

Makefile:

```makefile
obj-m += cfs_inspect.o
BASEINCLUDE ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(BASEINCLUDE) M=$(PWD) modules
clean:
	$(MAKE) -C $(BASEINCLUDE) M=$(PWD) clean
```

在 QEMU 中:

```bash
cd /mnt/cfs_inspect
make
insmod cfs_inspect.ko
dmesg | tail
rmmod cfs_inspect
```

### 注意

- `cpu_rq()` 和 `struct cfs_rq` 都不是导出 API,必须直接 `#include` 内核内部头
- 这只适合学习,**生产代码请用 `tracepoint`**(`trace_sched_*`)或 `ftrace`
  来获取信息,不要直接挖内部结构

### 思考题

1. 把上面的 init 改成创建一个 procfs 文件,每次 `cat` 时打印当前快照,
   避免 `insmod` / `rmmod` 来回切换。
2. 用 `rb_first_cached` + `rb_next` 遍历红黑树,打印每个任务的 vruntime 和 comm。
3. 模块加载时机会影响输出 —— 此时 `kthreadd`、`init` 之类的内核线程都在跑。
   能不能让它在某个用户进程被调度时再打印?(提示:`tracepoint`、`kprobe`)

---

## 综合复盘题

1. 一句话总结:**vruntime 为什么是 CFS 公平性的"度量衡"?**
2. 一句话总结:**`min_vruntime` 单调递增对哪些场景至关重要?**
3. 一句话总结:**PELT 弥补了 `nr_running` 的哪些缺陷?**
4. CFS 不能保证"实时性"。哪些场景下你必须用 `SCHED_FIFO`/`SCHED_DEADLINE`
   而不是调整 nice?
5. 如果你要给内核提一个 patch:把 `sysctl_sched_min_granularity` 从全局参数
   改成 per-cgroup 参数,需要改哪些数据结构和函数?

---

## 进一步阅读

- `Documentation/scheduler/sched-design-CFS.txt` —— Ingo Molnar 亲笔
- `Documentation/scheduler/sched-bwc.txt` —— CFS bandwidth control
- `Documentation/scheduler/sched-stats.txt` —— `/proc/schedstat` 字段
- 论文:*CFS Scheduler*, Wong et al., 2008
- 书籍:《奔跑吧 Linux 内核》(本仓库配套)

---

⬅️ [上一站:PELT 与组调度](08_pelt_and_group.md) ｜ [返回总目录](README.md)
