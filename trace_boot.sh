#!/bin/bash
# Kernel Boot Tracing Script
# 用于追踪内核启动过程的函数调用流程

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LROOT="/home/doula/project/runninglinuxkernel_5.0"

trace_boot_with_ftrace() {
    echo "========================================"
    echo "方案一：使用 ftrace 追踪启动过程"
    echo "========================================"
    echo
    echo "1. 在内核启动参数中添加 ftrace 配置"
    echo
    echo "修改 run_busybox.sh 中的 arm64 部分，添加以下启动参数："
    echo
    echo '  --append "rdinit=/linuxrc console=ttyAMA0 ftrace=function_graph ftrace_filter=* trace_buf_size=1M"'
    echo
    echo "参数说明："
    echo "  ftrace=function_graph  - 使用函数图追踪器"
    echo "  ftrace_filter=*        - 追踪所有函数（可指定具体函数）"
    echo "  trace_buf_size=1M      - 追踪缓冲区大小"
    echo
    echo "2. 启动后获取追踪结果："
    echo "   cat /sys/kernel/tracing/trace > /tmp/boot_trace.txt"
    echo
}

trace_boot_with_cmdline() {
    echo "========================================"
    echo "方案二：内核命令行参数追踪（推荐）"
    echo "========================================"
    echo
    echo "在内核启动参数中添加："
    echo
    echo "  ftrace=function_graph"
    echo "  ftrace_filter=kernel_init,do_initcalls,*"
    echo "  trace_printk=on"
    echo "  ftrace_dump_on_oops"
    echo
    echo "完整示例："
    echo '  qemu-system-aarch64 -machine virt -cpu cortex-a57 -machine type=virt \'
    echo '      -m 512 -smp 2 -kernel arch/arm64/boot/Image \'
    echo '      --append "rdinit=/linuxrc console=ttyAMA0 ftrace=function_graph trace_buf_size=4M" \'
    echo '      -nographic'
    echo
}

trace_with_gdb() {
    echo "========================================"
    echo "方案三：使用 GDB + QEMU 调试"
    echo "========================================"
    echo
    echo "1. 启动 QEMU（带调试端口）："
    echo "   ./run_busybox.sh arm64 debug"
    echo
    echo "2. 在另一个终端启动 GDB："
    echo "   aarch64-linux-gnu-gdb vmlinux"
    echo
    echo "3. GDB 命令："
    echo "   (gdb) target remote :1234"
    echo "   (gdb) break start_kernel"
    echo "   (gdb) continue"
    echo
    echo "4. 追踪函数调用："
    echo "   (gdb) display/i \$pc"
    echo "   (gdb) step  # 单步执行"
    echo "   (gdb) backtrace  # 查看调用栈"
    echo
}

trace_with_ftrace_script() {
    echo "========================================"
    echo "方案四：使用 ftrace 脚本追踪"
    echo "========================================"
    echo
    echo "创建一个 init 脚本在启动时自动开始追踪："
    echo
    cat << 'EOF'
#!/bin/sh
# 保存为 _install_arm64/init.d/trace_boot.sh

# 挂载 tracefs
mount -t tracefs none /sys/kernel/tracing

# 清空之前的追踪
echo > /sys/kernel/tracing/trace

# 设置追踪器
echo function_graph > /sys/kernel/tracing/current_tracer

# 可选：只追踪特定函数
# echo "kernel_init,do_initcalls,do_one_initcall" > /sys/kernel/tracing/set_ftrace_filter

# 开始追踪
echo 1 > /sys/kernel/tracing/tracing_on

# ... 等待系统启动 ...

# 停止追踪
echo 0 > /sys/kernel/tracing/tracing_on

# 保存结果
cat /sys/kernel/tracing/trace > /tmp/boot_trace.txt
EOF
    echo
}

analyze_trace() {
    echo "========================================"
    echo "分析追踪结果"
    echo "========================================"
    echo
    echo "1. 查看函数调用图："
    echo "   cat /sys/kernel/tracing/trace"
    echo
    echo "2. 查看调用栈深度："
    echo "   cat /sys/kernel/tracing/trace | grep -v '^#' | head -100"
    echo
    echo "3. 统计函数调用次数："
    echo "   cat /sys/kernel/tracing/trace_stat/function0"
    echo
    echo "4. 使用 trace-cmd 分析："
    echo "   trace-cmd report trace.dat"
    echo
    echo "5. 使用 KernelShark 可视化："
    echo "   kernelshark trace.dat"
    echo
}

create_boot_trace_init() {
    echo "========================================"
    echo "创建启动追踪 init 脚本"
    echo "========================================"
    
    INIT_DIR="$LROOT/_install_arm64/etc/init.d"
    mkdir -p "$INIT_DIR"
    
    cat > "$INIT_DIR/S00trace_boot" << 'EOF'
#!/bin/sh
# Boot tracing script

TRACE_DIR="/sys/kernel/tracing"
TRACE_OUTPUT="/boot_trace.txt"

# 检查 tracefs 是否已挂载
if [ ! -d "$TRACE_DIR" ]; then
    mount -t tracefs none /sys/kernel/tracing 2>/dev/null || true
fi

if [ -d "$TRACE_DIR" ]; then
    echo "Saving boot trace..."
    
    # 停止追踪
    echo 0 > $TRACE_DIR/tracing_on 2>/dev/null
    
    # 保存追踪结果
    cat $TRACE_DIR/trace > $TRACE_OUTPUT 2>/dev/null
    
    # 保存函数统计
    cat $TRACE_DIR/trace_stat/function0 > /boot_trace_stat.txt 2>/dev/null
    
    echo "Boot trace saved to $TRACE_OUTPUT"
fi
EOF
    chmod +x "$INIT_DIR/S00trace_boot"
    
    echo "已创建: $INIT_DIR/S00trace_boot"
    echo
    echo "需要重新编译内核以包含此脚本："
    echo "  cd $LROOT"
    echo "  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j\$(nproc)"
    echo
}

show_quick_start() {
    echo "========================================"
    echo "快速开始 - 追踪内核启动"
    echo "========================================"
    echo
    echo "方法 A：修改启动参数（最简单）"
    echo "--------------------------------------"
    echo "1. 编辑 run_busybox.sh，在 arm64 的 --append 中添加："
    echo '   ftrace=function_graph trace_buf_size=4M'
    echo
    echo "2. 运行 QEMU："
    echo "   ./run_busybox.sh arm64"
    echo
    echo "3. 启动后在 QEMU 中执行："
    echo "   cat /sys/kernel/tracing/trace > boot_trace.txt"
    echo
    echo
    echo "方法 B：使用 GDB 调试（最详细）"
    echo "--------------------------------------"
    echo "1. 终端1：./run_busybox.sh arm64 debug"
    echo "2. 终端2：aarch64-linux-gnu-gdb vmlinux"
    echo "         (gdb) target remote :1234"
    echo "         (gdb) break start_kernel"
    echo "         (gdb) continue"
    echo
}

case "${1:-help}" in
    ftrace)
        trace_boot_with_ftrace
        ;;
    cmdline)
        trace_boot_with_cmdline
        ;;
    gdb)
        trace_with_gdb
        ;;
    script)
        trace_with_ftrace_script
        ;;
    analyze)
        analyze_trace
        ;;
    create-init)
        create_boot_trace_init
        ;;
    quick)
        show_quick_start
        ;;
    all)
        show_quick_start
        echo
        trace_boot_with_ftrace
        trace_with_gdb
        ;;
    *)
        echo "内核启动追踪工具"
        echo
        echo "用法: $0 <command>"
        echo
        echo "命令:"
        echo "  quick       - 快速开始指南"
        echo "  ftrace      - 使用 ftrace 追踪"
        echo "  cmdline     - 内核命令行参数追踪"
        echo "  gdb         - 使用 GDB 调试"
        echo "  script      - 使用脚本追踪"
        echo "  analyze     - 分析追踪结果"
        echo "  create-init - 创建启动追踪 init 脚本"
        echo "  all         - 显示所有方法"
        ;;
esac
