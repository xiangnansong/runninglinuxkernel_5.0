#!/bin/sh
# mm_setup.sh - 在 VM 内准备内存回收实验环境
#   1) 挂载 tracefs
#   2) 把 /dev/vda 格式化成 ext4 并挂到 /data,生成一个大文件用于制造 page cache
#   3) 把 /dev/vdb 做成 swap 并 swapon,让匿名页可以被换出
# 只需要在每次开机后执行一次。

TRACE=/sys/kernel/debug/tracing
DATA_MNT=/data

# QEMU 给两块盘设了 serial(mmdata/mmswap),按 serial 认盘,避免依赖 vda/vdb 的枚举顺序
DATA_DEV=
SWAP_DEV=
for d in /sys/block/vd*; do
	[ -e "$d/serial" ] || continue
	case "$(cat $d/serial 2>/dev/null)" in
	mmdata*) DATA_DEV=/dev/$(basename $d) ;;
	mmswap*) SWAP_DEV=/dev/$(basename $d) ;;
	esac
done
[ -z "$DATA_DEV" ] && DATA_DEV=/dev/vda
[ -z "$SWAP_DEV" ] && SWAP_DEV=/dev/vdb
echo "data disk = $DATA_DEV , swap disk = $SWAP_DEV"
BIGFILE=$DATA_MNT/bigfile
BIGFILE_MB=${BIGFILE_MB:-192}

echo "=== [1/3] mount tracefs ==="
if [ ! -d $TRACE ]; then
	mount -t debugfs none /sys/kernel/debug 2>/dev/null
fi
[ -d $TRACE ] && echo "tracefs ready: $TRACE" || { echo "no tracefs!"; exit 1; }

echo "=== [2/3] prepare data disk ($DATA_DEV -> $DATA_MNT) ==="
if [ ! -b $DATA_DEV ]; then
	echo "$DATA_DEV not found, 请用 ./run_busybox.sh arm64_mm 启动"
	exit 1
fi
mkdir -p $DATA_MNT
if ! mount -t ext4 $DATA_DEV $DATA_MNT 2>/dev/null; then
	echo "格式化 $DATA_DEV ..."
	mke2fs -q -F $DATA_DEV
	mount -t ext4 $DATA_DEV $DATA_MNT || exit 1
fi
if [ ! -f $BIGFILE ]; then
	echo "生成 ${BIGFILE_MB}MB 测试文件 $BIGFILE ..."
	dd if=/dev/zero of=$BIGFILE bs=1M count=$BIGFILE_MB 2>&1 | tail -1
	sync
fi
ls -l $BIGFILE

echo "=== [3/3] prepare swap ($SWAP_DEV) ==="
if ! grep -q "^$SWAP_DEV " /proc/swaps; then
	mkswap $SWAP_DEV >/dev/null 2>&1
	swapon $SWAP_DEV || echo "swapon 失败"
fi
cat /proc/swaps

echo
echo "=== 环境就绪 ==="
free
echo
echo "可用脚本(都在 /mnt/mm_lab/scripts/ 下):"
echo "  show_watermark.sh    # 看 zone 水位线和 kswapd 状态"
echo "  drop_caches.sh       # 清空 page cache,回到干净起点"
echo "  fill_cache.sh        # 用大文件灌满 page cache,制造内存紧张"
echo "  trace_reclaim.sh     # 打开 vmscan tracepoint 观察一次回收(主力脚本)"
echo "  trace_stack.sh       # 给某个回收事件挂 stacktrace,看谁触发了回收"
echo "  trace_func.sh        # function tracer 看回收路径的函数调用关系"
echo "  swappiness_test.sh   # 对比 swappiness 对 匿名页/文件页 取舍的影响"
echo "  trace_oom.sh         # 关掉 swap,观察回收失败到 OOM 的全过程"
