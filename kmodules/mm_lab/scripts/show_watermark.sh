#!/bin/sh
# show_watermark.sh - 打印各 zone 的水位线和当前空闲页,理解 kswapd 的唤醒条件
#
# 页面回收的触发点全部围绕三条水位线:
#   free < low  -> 唤醒 kswapd,后台回收
#   free < min  -> 分配路径进入直接回收(direct reclaim),申请者自己同步回收
#   free > high -> kswapd 认为任务完成,回去睡觉
# 单位是"页",本机 4KB 一页。

echo "page size = $(getconf PAGE_SIZE 2>/dev/null || echo 4096) bytes"
echo
awk '
/^Node/ { node=$2; zone=$4 }
/pages free/ { free=$3 }
/^ *min +[0-9]+$/  { min=$2 }
/^ *low +[0-9]+$/  { low=$2 }
/^ *high +[0-9]+$/ {                    # 注意: pagesets 里的 "high:" 带冒号,不会匹配到这里
	high=$2;
	if (free == 0 && min == 0) next;   # 跳过本机没有实际内存的 zone
	printf "Node %s zone %-8s free=%-8d min=%-7d low=%-7d high=%-7d", node, zone, free, min, low, high;
	if (free < min)       printf "  <== 低于 min,分配会走直接回收\n";
	else if (free < low)  printf "  <== 低于 low,kswapd 应该在跑\n";
	else if (free < high) printf "  <== 在 low 和 high 之间\n";
	else                  printf "  (充足)\n";
}
' /proc/zoneinfo

echo
echo "--- /proc/meminfo 关键项 ---"
grep -E "^(MemTotal|MemFree|MemAvailable|Cached|Active\(anon\)|Inactive\(anon\)|Active\(file\)|Inactive\(file\)|Dirty|Writeback|SwapTotal|SwapFree)" /proc/meminfo

echo
echo "--- kswapd 状态 ---"
for p in /proc/[0-9]*; do
	if [ "$(cat $p/comm 2>/dev/null)" = "kswapd0" ]; then
		echo "pid=${p##*/} state=$(awk '{print $3}' $p/stat)  (S=睡眠 R=运行 D=不可中断)"
	fi
done
