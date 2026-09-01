#!/bin/sh
# trace_oom.sh - 关掉 swap,让回收彻底失败,观察 "回收 -> 失败 -> OOM" 的全过程
#
# 用法: sh trace_oom.sh [申请MB]
#
# 原理:
#   没有 swap 时匿名页无处可去,不可回收;文件页被回收干净后,
#   __alloc_pages_slowpath 里 direct reclaim 反复重试仍拿不到页,
#   最终调用 out_of_memory() 选一个"分数最高"的进程杀掉。
#   dmesg 里的 "all_unreclaimable? yes" 就是"实在没得回收了"的标志。
#
# 注意: 跑完 swap 是关闭的,要继续做别的实验请重新 swapon。

MB=${1:-400}
TRACE=/sys/kernel/debug/tracing

echo "=== 关闭 swap ==="
swapoff -a
free | head -3

echo "=== 灌满 page cache ==="
dd if=/data/bigfile of=/dev/null bs=1M >/dev/null 2>&1

echo nop > $TRACE/current_tracer
echo 0   > $TRACE/events/enable
echo     > $TRACE/trace
echo 1   > $TRACE/events/vmscan/enable
echo 1   > $TRACE/tracing_on

echo "=== 申请 ${MB}MB(必然失败)==="
/mnt/mm_lab/memhog $MB 2 32

echo 0 > $TRACE/tracing_on
echo 0 > $TRACE/events/enable
cp $TRACE/trace /tmp/oom.trace

echo
echo "=== 回收统计 ==="
grep -E "^(pgsteal_direct|pgsteal_kswapd|allocstall_normal|allocstall_movable)" /proc/vmstat
echo "回收事件条数: $(grep -c mm_vmscan /tmp/oom.trace)"
echo
echo "=== dmesg 里的 OOM 报告(重点看 all_unreclaimable 和 Killed process)==="
dmesg | grep -E "Out of memory|Killed process|all_unreclaimable|oom-kill" | tail -6
echo
echo "提示: swap 现在是关闭的,恢复请执行"
echo "  for d in /sys/block/vd*; do [ \"\$(cat \$d/serial)\" = mmswap ] && swapon /dev/\$(basename \$d); done"
