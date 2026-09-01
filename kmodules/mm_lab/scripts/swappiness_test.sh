#!/bin/sh
# swappiness_test.sh - 对比不同 vm.swappiness 下"回收文件页 vs 换出匿名页"的比例
#
# 用法: sh swappiness_test.sh [匿名页MB]
#
# 原理:
#   get_scan_count() 根据 swappiness 计算 anon/file 两条 LRU 的扫描比例:
#     swappiness=0   尽量不换匿名页,优先丢文件页
#     swappiness=100 匿名页和文件页等价对待
#
# 负载设计(关键):
#   光跑 memhog 是看不出差别的 —— 只要文件页还够回收,内核根本不需要动匿名页。
#   必须制造"匿名页常驻 + 同时还有文件页需求"的竞争场面:
#     后台 memhog 长时间持有一大块匿名内存,前台反复读大文件抢内存。
#   这时内核才必须在"丢文件页"和"换匿名页"之间做选择,swappiness 才起作用。
#
# 观察指标:
#   pswpout      换出到 swap 的页数(匿名页被回收的直接证据)
#   pgsteal_*    总共回收了多少页

MB=${1:-160}
BIGFILE=/data/bigfile

for s in 0 100; do
	echo "=========== vm.swappiness = $s ==========="
	echo $s > /proc/sys/vm/swappiness

	# 回到同一起点
	sync; echo 3 > /proc/sys/vm/drop_caches; sleep 1
	swapoff -a 2>/dev/null; swapon -a 2>/dev/null
	for d in /sys/block/vd*; do
		[ "$(cat $d/serial 2>/dev/null)" = "mmswap" ] && swapon /dev/$(basename $d) 2>/dev/null
	done

	B_SWPOUT=$(awk '/^pswpout/{print $2}' /proc/vmstat)
	B_KSW=$(awk '/^pgsteal_kswapd/{print $2}' /proc/vmstat)
	B_DIR=$(awk '/^pgsteal_direct/{print $2}' /proc/vmstat)

	# 后台占住匿名内存,前台反复读文件
	/mnt/mm_lab/memhog $MB 60 16 >/dev/null &
	HOG=$!
	sleep 12
	for i in 1 2 3; do
		dd if=$BIGFILE of=/dev/null bs=1M >/dev/null 2>&1
	done
	wait $HOG

	A_SWPOUT=$(awk '/^pswpout/{print $2}' /proc/vmstat)
	A_KSW=$(awk '/^pgsteal_kswapd/{print $2}' /proc/vmstat)
	A_DIR=$(awk '/^pgsteal_direct/{print $2}' /proc/vmstat)

	echo "  pswpout        (换出匿名页) : $((A_SWPOUT - B_SWPOUT)) 页"
	echo "  pgsteal_kswapd (后台回收)   : $((A_KSW - B_KSW)) 页"
	echo "  pgsteal_direct (直接回收)   : $((A_DIR - B_DIR)) 页"
	echo
done

echo 60 > /proc/sys/vm/swappiness
echo "已恢复 vm.swappiness = 60"
