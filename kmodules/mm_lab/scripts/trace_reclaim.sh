#!/bin/sh
# trace_reclaim.sh - 打开 vmscan tracepoint,跑一段负载,把回收过程记录下来
#
# 用法:
#   sh trace_reclaim.sh "<要执行的命令>" [输出文件]
# 例:
#   sh trace_reclaim.sh "cat /data/bigfile > /dev/null"        # 文件页回收
#   sh trace_reclaim.sh "/mnt/mm_lab/memhog 200 3 16"          # 匿名页回收/换出
#
# 输出:
#   /tmp/reclaim.trace  原始 trace
#   屏幕上打印 vmstat 差值 + 事件统计摘要

TRACE=/sys/kernel/debug/tracing
CMD="$1"
OUT="${2:-/tmp/reclaim.trace}"

[ -z "$CMD" ] && { echo "usage: $0 \"<command>\" [outfile]"; exit 1; }

vmstat_snap() {
	grep -E "^(pgscan_kswapd|pgscan_direct|pgsteal_kswapd|pgsteal_direct|pgrefill|pswpout|pswpin|pgpgout|pgactivate|pgdeactivate|allocstall_normal|allocstall_dma32|kswapd_low_wmark_hit_quickly|kswapd_high_wmark_hit_quickly|nr_vmscan_write|slabs_scanned)" /proc/vmstat > "$1"
}

# 1. 复位 ftrace
echo nop            > $TRACE/current_tracer
echo 0              > $TRACE/tracing_on
echo                > $TRACE/trace
echo 4096           > $TRACE/buffer_size_kb 2>/dev/null
echo 0              > $TRACE/events/enable

# 2. 只打开内存回收相关事件
echo 1 > $TRACE/events/vmscan/enable
# 回写(把脏页刷盘)也属于回收链路的一部分
[ -d $TRACE/events/writeback ] && echo 1 > $TRACE/events/writeback/writeback_pages_written/enable

vmstat_snap /tmp/vmstat.before

# 3. 开始记录并执行负载
echo 1 > $TRACE/tracing_on
echo "=== run: $CMD ==="
eval "$CMD"
RC=$?
echo 0 > $TRACE/tracing_on
vmstat_snap /tmp/vmstat.after

cp $TRACE/trace "$OUT"
echo 0 > $TRACE/events/enable

# 4. 摘要
echo
echo "=== ftrace 事件统计 ($OUT) ==="
awk '/: mm_/ {
	# 形如  "  memhog-131 [001] .... 177.5: mm_vmscan_wakeup_kswapd: nid=0 ..."
	for (i = 1; i <= NF; i++) {
		if ($i ~ /^mm_.*:$/) { ev = substr($i, 1, length($i)-1); cnt[ev]++; break }
	}
	} END { for (e in cnt) printf "%-34s %8d\n", e, cnt[e] }' "$OUT" | sort

echo
echo "=== 回收统计口径 (/proc/vmstat 差值) ==="
awk 'NR==FNR { before[$1] = $2; next }
     { d = $2 - before[$1]; if (d != 0) printf "%-34s %+10d\n", $1, d }' \
	/tmp/vmstat.before /tmp/vmstat.after

echo
echo "原始 trace: $OUT  (共 $(grep -c ': mm_' "$OUT") 条回收事件)"
exit $RC
