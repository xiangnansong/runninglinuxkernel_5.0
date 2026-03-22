# 内核启动追踪工具 - 项目总结

## 已创建的文件

### 1. trace_kernel_boot.sh（主工具脚本）
**路径：** `/home/doula/project/runninglinuxkernel_5.0/trace_kernel_boot.sh`

**功能：**
- 自动化追踪内核启动过程
- 支持 ftrace 和 GDB 两种追踪方式
- 自动生成追踪初始化脚本
- 分析追踪结果

**主要命令：**
```bash
./trace_kernel_boot.sh setup      # 设置环境
./trace_kernel_boot.sh ftrace     # 使用 ftrace 追踪
./trace_kernel_boot.sh gdb        # 使用 GDB 调试
./trace_kernel_boot.sh analyze    # 分析结果
./trace_kernel_boot.sh clean      # 清理输出
```

### 2. TRACE_KERNEL_BOOT_README.md（详细文档）
**路径：** `/home/doula/project/runninglinuxkernel_5.0/TRACE_KERNEL_BOOT_README.md`

**内容：**
- 完整的使用说明
- 前置要求和配置
- 详细的命令参考
- 输出文件说明
- 关键启动函数列表
- 常见问题解答
- 高级用法示例

### 3. demo_trace.sh（演示脚本）
**路径：** `/home/doula/project/runninglinuxkernel_5.0/demo_trace.sh`

**功能：**
- 交互式演示工具使用流程
- 逐步引导用户完成追踪

## 快速使用指南

### 方法一：使用 ftrace（推荐）

```bash
# 1. 设置环境
./trace_kernel_boot.sh setup

# 2. 启动追踪
./trace_kernel_boot.sh ftrace

# 3. 在 QEMU 控制台中执行
/trace_boot_init.sh

# 4. 查看结果（在 QEMU 中）
cat /tmp/boot_trace_full.txt | less
cat /tmp/boot_trace_key_functions.txt
cat /tmp/boot_trace_stat.txt
```

### 方法二：使用 GDB 调试

```bash
# 终端 1：启动 QEMU
./trace_kernel_boot.sh gdb

# 终端 2：启动 GDB
cd /home/doula/project/runninglinuxkernel_5.0
aarch64-linux-gnu-gdb vmlinux
(gdb) target remote :1234
(gdb) break start_kernel
(gdb) continue
(gdb) backtrace
(gdb) step
```

### 方法三：交互式演示

```bash
./demo_trace.sh
```

## 追踪原理

### ftrace 追踪流程

1. **内核启动参数配置**
   - 在 QEMU 启动时添加 `ftrace=function_graph` 参数
   - 内核启动时自动启用 ftrace
   - 所有函数调用被记录到内核缓冲区

2. **数据收集**
   - 内核启动完成后，执行 `/trace_boot_init.sh`
   - 脚本从 `/sys/kernel/tracing/trace` 读取数据
   - 保存到 `/tmp/boot_trace_*.txt` 文件

3. **数据分析**
   - 提取关键函数调用
   - 统计函数调用次数
   - 生成调用关系图

### GDB 调试流程

1. **QEMU 调试模式**
   - 使用 `-s -S` 参数启动 QEMU
   - QEMU 在端口 1234 等待 GDB 连接

2. **GDB 连接**
   - 使用 `aarch64-linux-gnu-gdb` 连接
   - 设置断点在关键函数
   - 单步执行并记录调用栈

3. **追踪记录**
   - 使用 GDB Python 脚本自动记录
   - 保存函数调用和调用栈信息

## 输出文件说明

### QEMU 内部文件（/tmp/）

| 文件名 | 说明 | 大小估计 |
|--------|------|----------|
| boot_trace_full.txt | 完整函数调用追踪 | 10-100 MB |
| boot_trace_stat.txt | 函数调用统计 | 100-500 KB |
| boot_trace_key_functions.txt | 关键启动函数 | 10-50 KB |
| boot_trace_function_count.txt | 函数调用次数 | 50-200 KB |
| current_tracer.txt | 当前追踪器 | < 1 KB |
| trace_options.txt | 追踪选项 | < 1 KB |

### 主机文件（boot_trace_output/）

| 文件名 | 说明 |
|--------|------|
| key_functions.txt | 提取的关键函数 |
| boot_trace_first_1000.txt | 前1000行追踪 |
| top_50_functions.txt | 调用最多的50个函数 |

## 关键启动函数调用流程

```
内核入口
  └─ primary_entry (arch/arm64/kernel/head.S)
      └─ __primary_switched
          └─ start_kernel (init/main.c)
              ├─ setup_arch()
              │   ├─ setup_machine_fdt()
              │   ├─ paging_init()
              │   └─ bootmem_init()
              ├─ mm_init()
              │   ├─ mem_init()
              │   ├─ kmem_cache_init()
              │   └─ vmalloc_init()
              ├─ sched_init()
              ├─ init_IRQ()
              ├─ time_init()
              ├─ console_init()
              └─ rest_init()
                  └─ kernel_thread(kernel_init)
                      └─ kernel_init()
                          └─ kernel_init_freeable()
                              ├─ do_basic_setup()
                              │   └─ do_initcalls()
                              │       ├─ early_initcall
                              │       ├─ core_initcall
                              │       ├─ arch_initcall
                              │       ├─ subsys_initcall
                              │       ├─ fs_initcall
                              │       ├─ device_initcall
                              │       └─ late_initcall
                              └─ run_init_process("/linuxrc")
```

## 内核配置验证

已验证以下配置已启用：
```
CONFIG_FTRACE=y
CONFIG_FUNCTION_TRACER=y
CONFIG_FUNCTION_GRAPH_TRACER=y
CONFIG_DYNAMIC_FTRACE=y
CONFIG_STACKTRACE=y
```

## 使用场景

### 1. 学习内核启动流程
```bash
./trace_kernel_boot.sh ftrace
# 在 QEMU 中执行 /trace_boot_init.sh
# 查看 boot_trace_full.txt 了解完整流程
```

### 2. 调试启动问题
```bash
./trace_kernel_boot.sh gdb
# 使用 GDB 单步调试
# 定位启动失败的具体位置
```

### 3. 性能分析
```bash
./trace_kernel_boot.sh ftrace function_graph
# 查看 boot_trace_stat.txt
# 分析函数执行时间
```

### 4. 研究特定子系统
```bash
# 只追踪内存管理
./trace_kernel_boot.sh ftrace function_graph "mm_*,*alloc*"

# 只追踪调度器
./trace_kernel_boot.sh ftrace function_graph "sched_*"
```

## 注意事项

1. **缓冲区大小**
   - 默认 10MB，可能不够记录所有函数
   - 可以增加：`./trace_kernel_boot.sh ftrace function_graph "" 20M`

2. **性能影响**
   - ftrace 会显著降低启动速度
   - function_graph 比 function 开销更大

3. **数据量**
   - 完整追踪可能产生数百 MB 数据
   - 建议使用过滤器减少数据量

4. **QEMU 退出**
   - 按 Ctrl+A 然后按 X 退出 QEMU
   - 或在控制台输入 `poweroff`

## 故障排除

### 问题：追踪数据为空
**解决：**
```bash
# 检查内核配置
grep CONFIG_FTRACE .config

# 手动启动追踪
mount -t tracefs none /sys/kernel/tracing
echo function_graph > /sys/kernel/tracing/current_tracer
echo 1 > /sys/kernel/tracing/tracing_on
```

### 问题：QEMU 无法启动
**解决：**
```bash
# 检查内核镜像
ls -lh arch/arm64/boot/Image

# 检查根文件系统
ls -lh _install_arm64/
```

### 问题：GDB 无法连接
**解决：**
```bash
# 确保使用正确的 GDB
which aarch64-linux-gnu-gdb

# 检查端口
netstat -tuln | grep 1234
```

## 扩展功能

### 1. 可视化调用图
```bash
# 安装工具
sudo apt-get install graphviz

# 生成调用图
cat boot_trace_full.txt | gprof2dot -f perf | dot -Tpng -o callgraph.png
```

### 2. 使用 trace-cmd
```bash
# 在 QEMU 中
trace-cmd record -e sched -e irq
trace-cmd report > trace_report.txt
```

### 3. 结合 perf 工具
```bash
perf record -a -g -- ./run_busybox.sh arm64
perf report
```

## 总结

本工具提供了完整的内核启动追踪解决方案：

✅ 自动化追踪流程
✅ 支持多种追踪方式
✅ 详细的文档和示例
✅ 易于使用和扩展

通过本工具，你可以：
- 深入了解 Linux 内核启动过程
- 追踪所有函数调用和调用栈
- 分析启动性能
- 调试启动问题

## 下一步

1. 运行演示：`./demo_trace.sh`
2. 阅读文档：`cat TRACE_KERNEL_BOOT_README.md`
3. 开始追踪：`./trace_kernel_boot.sh setup && ./trace_kernel_boot.sh ftrace`

---

**创建日期：** 2026-03-21
**项目路径：** /home/doula/project/runninglinuxkernel_5.0
