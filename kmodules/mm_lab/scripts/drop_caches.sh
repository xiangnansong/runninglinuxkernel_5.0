#!/bin/sh
# 清空 page cache / dentry / inode 缓存,让每次实验从同一个起点开始
sync
echo 3 > /proc/sys/vm/drop_caches
sleep 1
echo "--- after drop_caches ---"
free
grep -E "^(Cached|Active\(file\)|Inactive\(file\)|AnonPages|SwapCached)" /proc/meminfo
