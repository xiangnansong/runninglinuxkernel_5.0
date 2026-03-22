# 内核启动函数调用追踪工具使用说明

## 概述

本工具用于追踪 Linux 内核（ARM64架构）在 QEMU 中启动过程的所有函数调用流程和函数调用栈。

## 功能特性

- ✅ 自动化追踪内核启动过程
- ✅ 支持多种追踪方法（ftrace、GDB）
- ✅ 自动生成函数调用图和调用栈
- ✅ 统计函数调用次数
- ✅ 提取关键启动函数
- ✅ 支持自定义过滤器

## 前置要求

### 必需工具
```bash
# QEMU ARM64 模拟器
sudo apt-get install qemu-system-arm

# GDB 调试器（可选，用于 GDB 调试模式）
sudo apt-get install gdb-multiarch
# 或
sudo apt-get install gdb-aarch64-linux-gnu
```

### 内核配置要求

确保内核已启用以下配置选项：
```
CONFIG_FTRACE=y
CONFIG_FUNCTION_TRACER=y
CONFIG_FUNCTION_GRAPH_TRACER=y
CONFIG_DYNAMIC_FTRACE=y
CONFIG_TRACE_IRQFLAGS=y
CONFIG_STACKTRACE=y
CONFIG_DEBUG_INFO=y
```

检查配置：
```bash
grep -E "CONFIG_FTRACE|CONFIG_FUNCTION_TRACER|CONFIG_FUNCTION_GRAPH_TRACER" .config
```

如果未启用，需要重新配置并编译内核：
```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- menuconfig
# 在菜单中启用:
# Kernel hacking -> Tracers -> Kernel Function Tracer
# Kernel hacking -> Tracers -> Kernel Function Graph Tracer

make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc)
```

## 快速开始

### 1. 设置环境（首次使用）

```bash
./trace_kernel_boot.sh setup
```

这将：
- 检查必要的工具
- 创建追踪初始化脚本
- 创建 GDB 追踪脚本
- 创建输出目录

### 2. 运行追踪

**方法 A：使用 ftrace（推荐）**

```bash
./trace_kernel_boot.sh ftrace
```

启动后，在 QEMU 控制台中执行：
```bash
/trace_boot_init.sh
```

这将自动保存追踪数据到 `/tmp/boot_trace_*.txt`

**方法 B：使用 GDB 调试**

终端 1：
```bash
./trace_kernel_boot.sh gdb
```

终端 2：
```bash
cd /home/doula/project/runninglinuxkernel_5.0
aarch64-linux-gnu-gdb vmlinux
(gdb) target remote :1234
(gdb) source gdb_trace_boot.py
(gdb) trace-boot
```

### 3. 分析结果

```bash
./trace_kernel_boot.sh analyze
```

## 详细使用说明

### 命令列表

```bash
./trace_kernel_boot.sh <command> [options]
```

| 命令 | 说明 |
|------|------|
| `setup` | 设置追踪环境（创建必要的脚本） |
| `ftrace [tracer]` | 使用 ftrace 追踪（推荐） |
| `gdb` | 使用 GDB 调试追踪 |
| `modified` | 使用修改后的 run_busybox.sh |
| `analyze` | 分析追踪结果 |
| `clean` | 清理追踪输出 |
| `help` | 显示帮助信息 |

### 追踪器类型

| 追踪器 | 说明 | 优点 | 缺点 |
|--------|------|------|------|
| `function_graph` | 函数图追踪（默认） | 显示函数调用关系和耗时 | 输出较大 |
| `function` | 函数追踪 | 输出简洁 | 不显示调用关系 |

### 使用示例

#### 示例 1：基本追踪

```bash
# 1. 设置环境
./trace_kernel_boot.sh setup

# 2. 启动追踪
./trace_kernel_boot.sh ftrace

# 3. 在 QEMU 中执行
/trace_boot_init.sh

# 4. 查看结果
cat /tmp/boot_trace_full.txt | less
```

#### 示例 2：追踪特定函数

```bash
# 只追踪 start_kernel 和相关函数
./trace_kernel_boot.sh ftrace function_graph "start_kernel,kernel_init,do_initcalls"
```

#### 示例 3：使用 GDB 详细调试

```bash
# 终端 1
./trace_kernel_boot.sh gdb

# 终端 2
aarch64-linux-gnu-gdb vmlinux
(gdb) target remote :1234
(gdb) break start_kernel
(gdb) continue
(gdb) backtrace
(gdb) step
```

#### 示例 4：自定义缓冲区大小

```bash
# 使用 20MB 缓冲区
./trace_kernel_boot.sh ftrace function_graph "" 20M
```

## 输出文件说明

追踪完成后，会在以下位置生成文件：

### QEMU 内部（/tmp/）

| 文件 | 说明 |
|------|------|
| `boot_trace_full.txt` | 完整的函数调用追踪 |
| `boot_trace_stat.txt` | 函数调用统计信息 |
| `boot_trace_key_functions.txt` | 关键启动函数 |
| `boot_trace_function_count.txt` | 函数调用次数统计 |
| `current_tracer.txt` | 当前使用的追踪器 |
| `trace_options.txt` | 追踪选项配置 |

### 主机（boot_trace_output/）

| 文件 | 说明 |
|------|------|
| `key_functions.txt` | 提取的关键函数 |
| `boot_trace_first_1000.txt` | 前1000行追踪 |
| `top_50_functions.txt` | 调用最多的50个函数 |

## 追踪数据格式

### function_graph 追踪器输出格式

```
 CPU  DURATION                  FUNCTION CALLS
 |     |   |                     |   |   |   |
 0)               |  start_kernel() {
 0)               |    set_task_stack_end_magic() {
 0)   0.123 us    |      __set_task_stack_end_magic();
 0)   0.456 us    |    }
 0)               |    setup_arch() {
 0)               |      setup_machine_fdt() {
 0)   1.234 us    |        early_init_dt_scan();
 0)   2.345 us    |      }
 0)   3.456 us    |    }
 0) + 10.123 us   |  }
```

说明：
- `CPU`: CPU 编号
- `DURATION`: 函数执行时间
- `FUNCTION CALLS`: 函数调用层次结构

### function 追踪器输出格式

```
# tracer: function
#
#           TASK-PID    CPU#    TIMESTAMP  FUNCTION
#              | |       |          |         |
            init-1     [000]   123.456789: start_kernel <-0xffff000008080000
            init-1     [000]   123.456790: setup_arch <-start_kernel
```

## 关键启动函数

### 早期启动（汇编）

```
arch/arm64/kernel/head.S:
  primary_entry          - 内核入口点
  __primary_switched     - 切换到虚拟地址空间
  __enable_mmu           - 启用 MMU
```

### 主初始化流程

```
init/main.c:
  start_kernel()         - 主初始化入口
    ├─ set_task_stack_end_magic()
    ├─ smp_setup_processor_id()
    ├─ cgroup_init_early()
    ├─ local_irq_disable()
    ├─ boot_cpu_init()
    ├─ setup_arch()      - 架构相关初始化
    ├─ setup_command_line()
    ├─ setup_per_cpu_areas()
    ├─ build_all_zonelists()
    ├─ page_alloc_init()
    ├─ parse_early_param()
    ├─ setup_log_buf()
    ├─ vfs_caches_init_early()
    ├─ sort_main_extable()
    ├─ trap_init()
    ├─ mm_init()         - 内存管理初始化
    ├─ sched_init()      - 调度器初始化
    ├─ init_IRQ()        - 中断初始化
    ├─ tick_init()
    ├─ init_timers()
    ├─ hrtimers_init()
    ├─ softirq_init()
    ├─ timekeeping_init()
    ├─ time_init()       - 时间初始化
    ├─ console_init()
    ├─ rest_init()       - 其余初始化
        └─ kernel_thread(kernel_init)
```

### 内核线程初始化

```
init/main.c:
  kernel_init()
    └─ kernel_init_freeable()
        ├─ do_basic_setup()
        │   └─ do_initcalls()
        │       ├─ do_initcall_level(0)  - early_initcall
        │       ├─ do_initcall_level(1)  - pure_initcall
        │       ├─ do_initcall_level(2)  - core_initcall
        │       ├─ do_initcall_level(3)  - postcore_initcall
        │       ├─ do_initcall_level(4)  - arch_initcall
        │       ├─ do_initcall_level(5)  - subsys_initcall
        │       ├─ do_initcall_level(6)  - fs_initcall
        │       ├─ do_initcall_level(7)  - device_initcall
        │       └─ do_initcall_level(8)  - late_initcall
        └─ run_init_process()
```

## 常见问题

### Q1: 追踪数据为空或很少

**原因：**
- 内核未启用 ftrace 配置
- 缓冲区太小
- 追踪器未正确启动

**解决方法：**
```bash
# 检查内核配置
grep CONFIG_FTRACE .config

# 增加缓冲区大小
./trace_kernel_boot.sh ftrace function_graph "" 20M

# 手动启动追踪
mount -t tracefs none /sys/kernel/tracing
echo function_graph > /sys/kernel/tracing/current_tracer
echo 1 > /sys/kernel/tracing/tracing_on
```

### Q2: QEMU 启动失败

**原因：**
- 内核镜像不存在
- 根文件系统问题
- QEMU 参数错误

**解决方法：**
```bash
# 检查内核镜像
ls -lh arch/arm64/boot/Image

# 检查根文件系统
ls -lh _install_arm64/

# 重新编译内核
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc)
```

### Q3: GDB 无法连接

**原因：**
- GDB 版本不匹配
- 端口被占用
- QEMU 未启动调试模式

**解决方法：**
```bash
# 检查 GDB
aarch64-linux-gnu-gdb --version

# 检查端口
netstat -tuln | grep 1234

# 确保使用 debug 参数
./run_busybox.sh arm64 debug
```

### Q4: 追踪数据太大

**解决方法：**
```bash
# 使用过滤器只追踪关键函数
./trace_kernel_boot.sh ftrace function_graph "start_kernel,kernel_init,do_*"

# 使用 function 追踪器代替 function_graph
./trace_kernel_boot.sh ftrace function

# 减小缓冲区
./trace_kernel_boot.sh ftrace function_graph "" 2M
```

## 高级用法

### 1. 自定义追踪过滤器

```bash
# 只追踪内存管理相关函数
./trace_kernel_boot.sh ftrace function_graph "mm_*,*alloc*,*free*"

# 只追踪调度器相关函数
./trace_kernel_boot.sh ftrace function_graph "sched_*,*schedule*"

# 只追踪中断相关函数
./trace_kernel_boot.sh ftrace function_graph "irq_*,*interrupt*"
```

### 2. 结合 trace-cmd 工具

```bash
# 在 QEMU 中使用 trace-cmd
trace-cmd record -e sched -e irq -e syscalls
trace-cmd report > trace_report.txt
```

### 3. 使用 perf 工具

```bash
# 记录内核启动性能数据
perf record -a -g -- ./run_busybox.sh arm64
perf report
```

### 4. 导出调用图

```bash
# 使用 gprof2dot 生成调用图
cat boot_trace_full.txt | gprof2dot -f perf | dot -Tpng -o callgraph.png
```

## 性能优化建议

1. **减少追踪开销**
   - 使用过滤器只追踪关键函数
   - 适当调整缓冲区大小
   - 使用 function 而非 function_graph

2. **提高追踪精度**
   - 增加缓冲区大小
   - 启用更多追踪选项
   - 使用 GDB 进行详细调试

3. **数据分析优化**
   - 使用脚本自动提取关键信息
   - 结合多种工具分析
   - 生成可视化图表

## 参考资料

- [Linux Kernel Ftrace Documentation](https://www.kernel.org/doc/Documentation/trace/ftrace.txt)
- [QEMU Documentation](https://www.qemu.org/docs/master/)
- [GDB Debugging Guide](https://sourceware.org/gdb/documentation/)
- [Linux Kernel Boot Process](https://0xax.gitbooks.io/linux-insides/content/Booting/)

## 故障排除

如果遇到问题，请按以下步骤排查：

1. 检查内核配置
2. 验证工具安装
3. 查看 QEMU 输出
4. 检查追踪文件权限
5. 查看系统日志

## 联系与支持

如有问题或建议，请查看项目文档或提交 issue。

---

**版本：** 1.0
**更新日期：** 2026-03-21
**作者：** Kernel Boot Tracer
