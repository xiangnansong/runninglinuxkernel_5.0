#!/bin/sh
# fill_cache.sh - 用大文件把 page cache 灌满,制造"内存紧张"的初始状态
#
# 很多同学第一次做实验会发现"什么都没抓到",原因几乎都是:
# 空闲内存还很多,压根没到水位线,内核当然不用回收。
# 所以匿名页/直接回收类实验之前,先用这个脚本把 page cache 填满。

FILE=${1:-/data/bigfile}
echo "--- before ---"
free | head -2
dd if=$FILE of=/dev/null bs=1M 2>&1 | tail -1
echo "--- after ---"
free | head -2
grep -E "^(Cached|Active\(file\)|Inactive\(file\))" /proc/meminfo
