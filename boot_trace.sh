#!/bin/bash
# 内核启动函数调用追踪脚本
# 使用 ftrace 追踪内核启动过程

set -e

LROOT="/home/doula/project/runninglinuxkernel_5.0"

run_with_trace() {
    local tracer="${1:-function_graph}"
    local filter="${2:-}"
    local buf_size="${3:-4M}"
    
    echo "========================================"
    echo "启动带追踪的 QEMU"
    echo "========================================"
    echo "追踪器: $tracer"
    echo "过滤器: ${filter:-所有函数}"
    echo "缓冲区: $buf_size"
    echo
    
    local append_params="rdinit=/linuxrc console=ttyAMA0 ftrace=$tracer trace_buf_size=$buf_size"
    
    if [ -n "$filter" ]; then
        append_params="$append_params ftrace_filter=$filter"
    fi
    
    qemu-system-aarch64 -machine virt -cpu cortex-a57 -machine type=virt \
        -m 512 -smp 2 -kernel $LROOT/arch/arm64/boot/Image \
        --append "$append_params" -nographic \
        --fsdev local,id=kmod_dev,path=$LROOT/kmodules,security_model=none \
        -device virtio-9p-device,fsdev=kmod_dev,mount_tag=kmod_mount
}

run_with_gdb() {
    echo "========================================"
    echo "启动带 GDB 调试的 QEMU"
    echo "========================================"
    echo
    echo "QEMU 将在端口 1234 等待 GDB 连接"
    echo
    echo "在另一个终端运行："
    echo "  aarch64-linux-gnu-gdb $LROOT/vmlinux"
    echo "  (gdb) target remote :1234"
    echo "  (gdb) break start_kernel"
    echo "  (gdb) continue"
    echo
    
    qemu-system-aarch64 -machine virt -cpu cortex-a57 -machine type=virt \
        -m 512 -smp 2 -kernel $LROOT/arch/arm64/boot/Image \
        --append "rdinit=/linuxrc console=ttyAMA0" -nographic \
        --fsdev local,id=kmod_dev,path=$LROOT/kmodules,security_model=none \
        -device virtio-9p-device,fsdev=kmod_dev,mount_tag=kmod_mount \
        -s -S
}

show_boot_functions() {
    echo "========================================"
    echo "关键启动函数列表"
    echo "========================================"
    echo
    echo "早期启动 (head.S):"
    echo "  primary_entry          - 入口点"
    echo "  __primary_switched     - 切换到虚拟地址"
    echo
    echo "主要初始化 (init/main.c):"
    echo "  start_kernel           - 主初始化入口"
    echo "  setup_arch             - 架构相关设置"
    echo "  mm_init                - 内存管理初始化"
    echo "  sched_init             - 调度器初始化"
    echo "  init_IRQ               - 中断初始化"
    echo "  time_init              - 时间初始化"
    echo "  rest_init              - 其余初始化"
    echo "  kernel_init            - 内核线程"
    echo "  kernel_init_freeable   - 可释放的初始化"
    echo
    echo "设备初始化:"
    echo "  do_basic_setup         - 基础设置"
    echo "  do_initcalls           - 执行 initcall"
    echo "  do_one_initcall        - 单个 initcall"
    echo
    echo "ARM64 特定:"
    echo "  __cpu_setup            - CPU 设置"
    echo "  __enable_mmu           - 启用 MMU"
    echo "  paging_init            - 分页初始化"
    echo
}

show_gdb_commands() {
    echo "========================================"
    echo "GDB 调试命令参考"
    echo "========================================"
    echo
    echo "# 连接 QEMU"
    echo "target remote :1234"
    echo
    echo "# 设置断点"
    echo "break start_kernel"
    echo "break kernel_init"
    echo "break do_initcalls"
    echo
    echo "# 追踪执行"
    echo "display/i \$pc          # 显示当前指令"
    echo "step                     # 单步进入函数"
    echo "next                     # 单步跳过函数"
    echo "continue                 # 继续执行"
    echo
    echo "# 查看调用栈"
    echo "backtrace               # 显示调用栈"
    echo "backtrace full          # 显示调用栈和局部变量"
    echo
    echo "# 查看变量"
    echo "print init_task         # 打印变量"
    echo "print/x \$pc            # 打印寄存器（十六进制）"
    echo "info registers          # 显示所有寄存器"
    echo
    echo "# 追踪所有函数调用（需要脚本）"
    echo "define trace_step"
    echo "  step"
    echo "  backtrace"
    echo "  trace_step"
    echo "end"
    echo
}

case "${1:-help}" in
    run)
        run_with_trace "${2:-function_graph}" "$3" "$4"
        ;;
    gdb)
        run_with_gdb
        ;;
    functions)
        show_boot_functions
        ;;
    gdb-cmds)
        show_gdb_commands
        ;;
    quick)
        echo "快速追踪内核启动："
        echo
        echo "1. 函数图追踪："
        echo "   $0 run function_graph"
        echo
        echo "2. 追踪特定函数："
        echo "   $0 run function 'start_kernel,kernel_init,do_initcalls'"
        echo
        echo "3. GDB 调试："
        echo "   $0 gdb"
        echo
        echo "启动后在 QEMU 中保存追踪结果："
        echo "   cat /sys/kernel/tracing/trace > boot_trace.txt"
        ;;
    *)
        echo "内核启动追踪工具"
        echo
        echo "用法: $0 <command> [options]"
        echo
        echo "命令:"
        echo "  run [tracer] [filter] [buf_size]  - 启动带追踪的 QEMU"
        echo "  gdb                               - 启动带 GDB 调试的 QEMU"
        echo "  functions                         - 显示关键启动函数"
        echo "  gdb-cmds                          - 显示 GDB 命令参考"
        echo "  quick                             - 快速开始指南"
        echo
        echo "示例:"
        echo "  $0 run                              # 使用 function_graph 追踪所有函数"
        echo "  $0 run function_graph               # 同上"
        echo "  $0 run function 'start_kernel,*'    # 只追踪 start_kernel"
        echo "  $0 gdb                              # GDB 调试模式"
        echo
        echo "追踪器类型:"
        echo "  function         - 函数追踪"
        echo "  function_graph   - 函数图追踪（推荐）"
        echo "  blk              - 块设备追踪"
        ;;
esac
