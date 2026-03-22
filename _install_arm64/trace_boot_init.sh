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
