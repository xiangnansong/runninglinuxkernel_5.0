#!/bin/sh
# trace_func.sh - 用 function tracer 观察回收路径上的函数调用顺序
#
# 用法:
#   sh trace_func.sh "<负载命令>" [输出文件]
# 例:
#   sh trace_func.sh "/mnt/mm_lab/memhog 180 1 16" /tmp/reclaim.func
#
# !!! 关于 function_graph 的重要提醒 !!!
#   本内核是 -O0 编译的(见顶层 Makefile 里强制加的 -O0),
#   1) 不加过滤直接 `echo function_graph > current_tracer`,会因为插桩点太多
#      把 QEMU(TCG 软件模拟)拖到几乎卡死;
#   2) 即使用 set_ftrace_filter 限定范围,只要回收路径真的被跑到,
#      arm64 上的 function_graph 返回钩子仍会踩崩内核
#      (pc/lr = null 的 Oops,"Fixing recursive fault but reboot is needed")。
#   所以这里用只挂函数入口、不改返回地址的 function tracer,配合
#   "<-调用者" 信息一样能看清调用关系,而且是安全的。

TRACE=/sys/kernel/debug/tracing
CMD="$1"
OUT="${2:-/tmp/reclaim.func}"

[ -z "$CMD" ] && { echo "usage: $0 \"<command>\" [outfile]"; exit 1; }

# 回收路径上关心的函数
FUNCS="
balance_pgdat
kswapd_shrink_node
shrink_node
shrink_node_memcg
get_scan_count
shrink_list
shrink_active_list
shrink_inactive_list
shrink_page_list
pageout
__remove_mapping
shrink_slab
__perform_reclaim
try_to_free_pages
do_try_to_free_pages
shrink_zones
wakeup_kswapd
"

echo nop  > $TRACE/current_tracer
echo 0    > $TRACE/tracing_on
echo      > $TRACE/trace
echo 8192 > $TRACE/buffer_size_kb 2>/dev/null
echo 0    > $TRACE/events/enable
echo      > $TRACE/set_ftrace_filter

# 关键:先缩小插桩范围,再切 tracer
for f in $FUNCS; do
	echo "$f" >> $TRACE/set_ftrace_filter 2>/dev/null
done
echo "filter functions: $(wc -l < $TRACE/set_ftrace_filter)"

echo function > $TRACE/current_tracer
echo 1 > $TRACE/tracing_on
echo "=== run: $CMD ==="
eval "$CMD"
echo 0 > $TRACE/tracing_on
cp $TRACE/trace "$OUT"

echo nop > $TRACE/current_tracer
echo     > $TRACE/set_ftrace_filter

echo
echo "=== 调用片段 ==="
sed -n '12,32p' "$OUT"
echo
echo "=== 各函数调用次数 ==="
awk '/: [a-z_]+ <-/ { for (i=1;i<=NF;i++) if ($i ~ /^<-/) { fn=$(i-1); cnt[fn]++ } }
     END { for (f in cnt) printf "%-28s %8d\n", f, cnt[f] }' "$OUT" | sort -k2 -n -r

echo
echo "=== 调用关系(被调用者 <- 调用者)==="
awk '/: [a-z_]+ <-/ { for (i=1;i<=NF;i++) if ($i ~ /^<-/) { printf "%s %s\n", $(i-1), $i } }' \
	"$OUT" | sort | uniq -c | sort -rn | head -20

echo
echo "完整结果: $OUT"
