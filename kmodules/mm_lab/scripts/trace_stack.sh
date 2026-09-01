#!/bin/sh
# trace_stack.sh - 给某个 vmscan tracepoint 挂 stacktrace 触发器,抓"谁触发了回收"
#
# 用法:
#   sh trace_stack.sh <事件名> "<负载命令>" [输出文件]
# 例:
#   sh trace_stack.sh mm_vmscan_direct_reclaim_begin "/mnt/mm_lab/memhog 180 1 16"
#   sh trace_stack.sh mm_vmscan_writepage "/mnt/mm_lab/memhog 180 1 16"
#   sh trace_stack.sh mm_vmscan_kswapd_wake "cat /data/bigfile > /dev/null"
#
# 原理:
#   events/<sys>/<event>/trigger 里写 "stacktrace",事件每次命中时
#   ftrace 会顺带把当前内核栈打进 ring buffer。
#   相比 function_graph,这个方法开销小得多,而且在本 -O0 内核上是安全的。

TRACE=/sys/kernel/debug/tracing
EV="$1"
CMD="$2"
OUT="${3:-/tmp/$EV.stack}"

[ -z "$CMD" ] && { echo "usage: $0 <event> \"<command>\" [outfile]"; exit 1; }
EVDIR=$TRACE/events/vmscan/$EV
[ -d "$EVDIR" ] || { echo "没有这个事件: $EV"; ls $TRACE/events/vmscan; exit 1; }

echo nop > $TRACE/current_tracer
echo 0   > $TRACE/tracing_on
echo     > $TRACE/trace
echo 0   > $TRACE/events/enable

echo stacktrace > $EVDIR/trigger
echo 1          > $EVDIR/enable

echo 1 > $TRACE/tracing_on
echo "=== run: $CMD ==="
eval "$CMD"
echo 0 > $TRACE/tracing_on

cp $TRACE/trace "$OUT"
echo '!stacktrace' > $EVDIR/trigger
echo 0 > $TRACE/events/enable

echo
echo "=== 第一条 $EV 的调用栈 ==="
awk '/<stack trace>/ {p=1; next} p && /^ =>/ {print} p && !/^ =>/ {exit}' "$OUT"
echo
echo "=== 命中次数: $(grep -c ": $EV:" "$OUT")  完整结果: $OUT ==="
