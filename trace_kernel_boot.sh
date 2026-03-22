#!/bin/bash
# 内核启动函数调用追踪完整解决方案
# 自动追踪 run_busybox.sh arm64 启动过程中的所有函数调用流程和调用栈

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LROOT="$SCRIPT_DIR"
TRACE_OUTPUT_DIR="$LROOT/boot_trace_output"
ROOTFS_ARM64="$LROOT/_install_arm64"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# 检查必要的工具
check_prerequisites() {
    log_step "检查必要工具..."

    local missing_tools=()

    if ! command -v qemu-system-aarch64 &> /dev/null; then
        missing_tools+=("qemu-system-aarch64")
    fi

    if ! command -v aarch64-linux-gnu-gdb &> /dev/null; then
        log_warn "aarch64-linux-gnu-gdb 未安装 (GDB 调试功能将不可用)"
    fi

    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_error "缺少必要工具: ${missing_tools[*]}"
        log_info "请安装: sudo apt-get install qemu-system-arm"
        exit 1
    fi

    if [ ! -f "$LROOT/arch/arm64/boot/Image" ]; then
        log_error "内核镜像不存在: $LROOT/arch/arm64/boot/Image"
        log_info "请先编译内核: make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j\$(nproc)"
        exit 1
    fi

    if [ ! -d "$ROOTFS_ARM64" ]; then
        log_error "根文件系统不存在: $ROOTFS_ARM64"
        exit 1
    fi

    log_info "所有必要工具检查通过"
}

# 创建追踪脚本到 rootfs
create_trace_init_script() {
    log_step "创建内核启动追踪脚本..."

    local init_script="$ROOTFS_ARM64/trace_boot_init.sh"

    cat > "$init_script" << 'TRACE_SCRIPT_EOF'
#!/bin/sh
# 内核启动追踪脚本 - 在内核启动后自动执行

TRACE_DIR="/sys/kernel/tracing"
OUTPUT_DIR="/tmp"

echo "=========================================="
echo "内核启动追踪开始"
echo "=========================================="

# 等待 tracefs 挂载
sleep 1

# 检查 tracefs
if [ ! -d "$TRACE_DIR" ]; then
    echo "挂载 tracefs..."
    mount -t tracefs none /sys/kernel/tracing 2>/dev/null || mount -t debugfs none /sys/kernel/debug 2>/dev/null
    TRACE_DIR="/sys/kernel/debug/tracing"
fi

if [ ! -d "$TRACE_DIR" ]; then
    echo "错误: 无法访问 tracing 系统"
    exit 1
fi

echo "Tracing 目录: $TRACE_DIR"

# 停止当前追踪
echo 0 > $TRACE_DIR/tracing_on 2>/dev/null

# 保存启动追踪数据
echo "保存函数调用追踪..."
if [ -f "$TRACE_DIR/trace" ]; then
    cat $TRACE_DIR/trace > $OUTPUT_DIR/boot_trace_full.txt 2>/dev/null
    echo "已保存: $OUTPUT_DIR/boot_trace_full.txt"
    wc -l $OUTPUT_DIR/boot_trace_full.txt
fi

# 保存函数统计
echo "保存函数统计..."
if [ -f "$TRACE_DIR/trace_stat/function0" ]; then
    cat $TRACE_DIR/trace_stat/function0 > $OUTPUT_DIR/boot_trace_stat.txt 2>/dev/null
    echo "已保存: $OUTPUT_DIR/boot_trace_stat.txt"
fi

# 保存当前追踪器信息
echo "保存追踪器信息..."
cat $TRACE_DIR/current_tracer > $OUTPUT_DIR/current_tracer.txt 2>/dev/null
cat $TRACE_DIR/trace_options > $OUTPUT_DIR/trace_options.txt 2>/dev/null

# 生成调用栈摘要
echo "生成调用栈摘要..."
if [ -f "$OUTPUT_DIR/boot_trace_full.txt" ]; then
    # 提取关键函数调用
    grep -E "start_kernel|kernel_init|do_initcalls|rest_init|setup_arch" \
        $OUTPUT_DIR/boot_trace_full.txt > $OUTPUT_DIR/boot_trace_key_functions.txt 2>/dev/null || true

    # 统计函数调用次数
    grep -oE '[a-zA-Z_][a-zA-Z0-9_]*\(\)' $OUTPUT_DIR/boot_trace_full.txt | \
        sort | uniq -c | sort -rn > $OUTPUT_DIR/boot_trace_function_count.txt 2>/dev/null || true
fi

echo "=========================================="
echo "追踪数据已保存到 $OUTPUT_DIR"
echo "=========================================="
echo "文件列表:"
ls -lh $OUTPUT_DIR/boot_trace*.txt $OUTPUT_DIR/current_tracer.txt 2>/dev/null || true
echo ""
echo "查看追踪结果:"
echo "  cat $OUTPUT_DIR/boot_trace_full.txt | less"
echo "  cat $OUTPUT_DIR/boot_trace_key_functions.txt"
echo "  cat $OUTPUT_DIR/boot_trace_stat.txt"
echo ""
TRACE_SCRIPT_EOF

    chmod +x "$init_script"
    log_info "追踪脚本已创建: $init_script"
}

# 方法1: 使用 ftrace 内核参数追踪
run_with_ftrace() {
    log_step "方法1: 使用 ftrace 追踪内核启动"

    mkdir -p "$TRACE_OUTPUT_DIR"

    local tracer="${1:-function_graph}"
    local filter="${2:-}"
    local buf_size="${3:-10M}"

    log_info "追踪器: $tracer"
    log_info "过滤器: ${filter:-所有函数}"
    log_info "缓冲区: $buf_size"
    log_info ""

    local append_params="rdinit=/linuxrc console=ttyAMA0 loglevel=8"
    append_params="$append_params ftrace=$tracer"
    append_params="$append_params trace_buf_size=$buf_size"
    append_params="$append_params trace_event=initcall:*,sched:*"

    if [ -n "$filter" ]; then
        append_params="$append_params ftrace_filter=$filter"
    fi

    log_info "启动参数: $append_params"
    log_info ""
    log_info "QEMU 启动中..."
    log_info "启动后执行以下命令保存追踪数据:"
    log_info "  /trace_boot_init.sh"
    log_info ""

    qemu-system-aarch64 -machine virt -cpu cortex-a57 -machine type=virt \
        -m 512 -smp 2 -kernel "$LROOT/arch/arm64/boot/Image" \
        --append "$append_params" -nographic \
        --fsdev local,id=kmod_dev,path="$LROOT/kmodules",security_model=none \
        -device virtio-9p-device,fsdev=kmod_dev,mount_tag=kmod_mount
}

# 方法2: 使用 GDB 调试追踪
run_with_gdb() {
    log_step "方法2: 使用 GDB 调试追踪内核启动"

    log_info "QEMU 将在端口 1234 等待 GDB 连接"
    log_info ""
    log_info "在另一个终端运行以下命令:"
    log_info "  cd $LROOT"
    log_info "  aarch64-linux-gnu-gdb vmlinux"
    log_info ""
    log_info "GDB 命令:"
    log_info "  (gdb) target remote :1234"
    log_info "  (gdb) source $LROOT/gdb_trace_boot.py"
    log_info "  (gdb) trace-boot"
    log_info ""

    # 创建 GDB Python 脚本
    create_gdb_trace_script

    qemu-system-aarch64 -machine virt -cpu cortex-a57 -machine type=virt \
        -m 512 -smp 2 -kernel "$LROOT/arch/arm64/boot/Image" \
        --append "rdinit=/linuxrc console=ttyAMA0" -nographic \
        --fsdev local,id=kmod_dev,path="$LROOT/kmodules",security_model=none \
        -device virtio-9p-device,fsdev=kmod_dev,mount_tag=kmod_mount \
        -s -S
}

# 创建 GDB 追踪脚本
create_gdb_trace_script() {
    local gdb_script="$LROOT/gdb_trace_boot.py"

    cat > "$gdb_script" << 'GDB_SCRIPT_EOF'
import gdb
import sys

class BootTracer:
    def __init__(self):
        self.trace_file = open("boot_trace_gdb.txt", "w")
        self.call_depth = 0
        self.max_depth = 50

    def trace_function(self, event):
        if isinstance(event, gdb.BreakpointEvent):
            frame = gdb.selected_frame()
            func_name = frame.name()

            indent = "  " * self.call_depth
            self.trace_file.write(f"{indent}{func_name}()\n")
            self.trace_file.flush()

            # 打印调用栈
            if self.call_depth < 5:
                try:
                    bt = gdb.execute("backtrace 10", to_string=True)
                    self.trace_file.write(f"{indent}  Backtrace:\n")
                    for line in bt.split('\n')[:10]:
                        self.trace_file.write(f"{indent}    {line}\n")
                except:
                    pass

            self.call_depth += 1

            if self.call_depth < self.max_depth:
                gdb.execute("finish", to_string=True)
                self.call_depth -= 1
                gdb.execute("step", to_string=True)

    def close(self):
        self.trace_file.close()

class TraceBootCommand(gdb.Command):
    """追踪内核启动过程"""

    def __init__(self):
        super(TraceBootCommand, self).__init__("trace-boot", gdb.COMMAND_USER)

    def invoke(self, arg, from_tty):
        print("开始追踪内核启动...")

        # 设置关键断点
        breakpoints = [
            "start_kernel",
            "rest_init",
            "kernel_init",
            "kernel_init_freeable",
            "do_basic_setup",
            "do_initcalls",
            "do_one_initcall"
        ]

        for bp in breakpoints:
            try:
                gdb.execute(f"break {bp}")
                print(f"设置断点: {bp}")
            except:
                print(f"无法设置断点: {bp}")

        # 继续执行
        print("\n开始执行...")
        gdb.execute("continue")

# 注册命令
TraceBootCommand()

print("GDB 追踪脚本已加载")
print("使用 'trace-boot' 命令开始追踪")
GDB_SCRIPT_EOF

    log_info "GDB 追踪脚本已创建: $gdb_script"
}

# 方法3: 使用修改后的 run_busybox.sh
run_with_modified_script() {
    log_step "方法3: 使用修改后的启动脚本"

    local modified_script="$LROOT/run_busybox_trace.sh"

    # 创建修改后的脚本
    cp "$LROOT/run_busybox.sh" "$modified_script"

    # 修改 arm64 部分添加 ftrace 参数
    sed -i '/arm64)/,/;;/ s/--append "rdinit=\/linuxrc console=ttyAMA0"/--append "rdinit=\/linuxrc console=ttyAMA0 ftrace=function_graph trace_buf_size=10M trace_event=initcall:*,sched:*"/' "$modified_script"

    chmod +x "$modified_script"

    log_info "已创建修改后的启动脚本: $modified_script"
    log_info "运行: $modified_script arm64"
    log_info ""

    # 运行修改后的脚本
    "$modified_script" arm64
}

# 分析追踪结果
analyze_trace_results() {
    log_step "分析追踪结果"

    if [ ! -d "$TRACE_OUTPUT_DIR" ]; then
        log_error "追踪输出目录不存在: $TRACE_OUTPUT_DIR"
        return 1
    fi

    local trace_file="$TRACE_OUTPUT_DIR/boot_trace_full.txt"

    if [ ! -f "$trace_file" ]; then
        log_warn "追踪文件不存在: $trace_file"
        log_info "请先运行追踪命令"
        return 1
    fi

    log_info "分析追踪文件: $trace_file"
    log_info ""

    # 统计信息
    local total_lines=$(wc -l < "$trace_file")
    log_info "总行数: $total_lines"

    # 提取关键函数
    log_info "提取关键启动函数..."
    grep -E "start_kernel|rest_init|kernel_init|do_initcalls|setup_arch|mm_init|sched_init" \
        "$trace_file" > "$TRACE_OUTPUT_DIR/key_functions.txt" 2>/dev/null || true

    # 生成函数调用树
    log_info "生成函数调用树..."
    head -1000 "$trace_file" > "$TRACE_OUTPUT_DIR/boot_trace_first_1000.txt"

    # 统计函数调用次数
    log_info "统计函数调用次数..."
    grep -oE '[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$trace_file" | \
        sort | uniq -c | sort -rn | head -50 > "$TRACE_OUTPUT_DIR/top_50_functions.txt"

    log_info ""
    log_info "分析完成! 结果保存在: $TRACE_OUTPUT_DIR"
    log_info "  - key_functions.txt: 关键启动函数"
    log_info "  - boot_trace_first_1000.txt: 前1000行追踪"
    log_info "  - top_50_functions.txt: 调用次数最多的50个函数"
}

# 显示使用说明
show_usage() {
    cat << EOF
内核启动函数调用追踪工具
========================================

用法: $0 <command> [options]

命令:
  setup              - 设置追踪环境（创建必要的脚本）
  ftrace [tracer]    - 使用 ftrace 追踪（推荐）
  gdb                - 使用 GDB 调试追踪
  modified           - 使用修改后的 run_busybox.sh
  analyze            - 分析追踪结果
  clean              - 清理追踪输出
  help               - 显示此帮助信息

追踪器类型（用于 ftrace 命令）:
  function           - 函数追踪
  function_graph     - 函数图追踪（默认，推荐）

示例:
  $0 setup                    # 首次使用，设置环境
  $0 ftrace                   # 使用默认 function_graph 追踪
  $0 ftrace function          # 使用 function 追踪器
  $0 gdb                      # GDB 调试模式
  $0 analyze                  # 分析追踪结果

快速开始:
  1. $0 setup                 # 设置环境
  2. $0 ftrace                # 启动追踪
  3. 在 QEMU 中执行: /trace_boot_init.sh
  4. 退出 QEMU 后: $0 analyze

输出目录: $TRACE_OUTPUT_DIR
EOF
}

# 设置追踪环境
setup_trace_environment() {
    log_step "设置追踪环境"

    check_prerequisites
    create_trace_init_script
    create_gdb_trace_script

    mkdir -p "$TRACE_OUTPUT_DIR"

    log_info ""
    log_info "环境设置完成!"
    log_info "现在可以运行: $0 ftrace"
}

# 清理追踪输出
clean_trace_output() {
    log_step "清理追踪输出"

    if [ -d "$TRACE_OUTPUT_DIR" ]; then
        rm -rf "$TRACE_OUTPUT_DIR"
        log_info "已删除: $TRACE_OUTPUT_DIR"
    fi

    if [ -f "$LROOT/run_busybox_trace.sh" ]; then
        rm -f "$LROOT/run_busybox_trace.sh"
        log_info "已删除: run_busybox_trace.sh"
    fi

    if [ -f "$LROOT/boot_trace_gdb.txt" ]; then
        rm -f "$LROOT/boot_trace_gdb.txt"
        log_info "已删除: boot_trace_gdb.txt"
    fi

    log_info "清理完成"
}

# 主函数
main() {
    case "${1:-help}" in
        setup)
            setup_trace_environment
            ;;
        ftrace)
            check_prerequisites
            create_trace_init_script
            run_with_ftrace "${2:-function_graph}" "$3" "$4"
            ;;
        gdb)
            check_prerequisites
            run_with_gdb
            ;;
        modified)
            check_prerequisites
            create_trace_init_script
            run_with_modified_script
            ;;
        analyze)
            analyze_trace_results
            ;;
        clean)
            clean_trace_output
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            log_error "未知命令: $1"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
