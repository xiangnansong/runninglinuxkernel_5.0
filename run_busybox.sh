#!/bin/bash

LROOT=$PWD
ROOTFS_X86=_install_x86
ROOTFS_ARM32=_install_arm32
ROOTFS_ARM64=_install_arm64
CONSOLE_DEV_NODE=dev/console

# --- PCIe 实验相关的磁盘镜像 ---
PCI_NVME_IMG=$LROOT/nvme_disk.img
PCI_NVME_SIZE=64M

# --- 内存回收(page reclaim)实验相关的磁盘镜像 ---
MM_DATA_IMG=$LROOT/mm_data.img
MM_DATA_SIZE=512M
MM_SWAP_IMG=$LROOT/mm_swap.img
MM_SWAP_SIZE=256M
MM_MEM=256

usage() {
	cat <<EOF
Usage: $0 <arch> [debug|pci]

arch:
    x86_64        run busybox on x86_64
    x86           run busybox on i386
    arm32         run busybox on ARM vexpress-a9
    arm64         run busybox on ARM64 virt (default)
    arm64_pci     run busybox on ARM64 virt with PCIe devices (edu + NVMe)
                  for the PCI/PCIe driver lab
    arm64_mm      run busybox on ARM64 virt with ${MM_MEM}M RAM + one data disk
                  + one swap disk, for the memory reclaim (ftrace) lab

extras:
    debug         enable GDB stub (-s -S), listen on :1234
    pci           alias of arm64_pci
    mm            alias of arm64_mm

MM lab devices (when using arm64_mm):
    * /dev/vda    $MM_DATA_SIZE data disk  ($MM_DATA_IMG)
                  格式化成 ext4 后用来产生 page cache / 脏页 / 回写
    * /dev/vdb    $MM_SWAP_SIZE swap disk  ($MM_SWAP_IMG)
                  mkswap + swapon 之后匿名页才可以被换出
    内存故意压到 ${MM_MEM}MB,方便快速触发 kswapd 与直接回收。

PCI lab devices (when using arm64_pci):
    * QEMU "edu"   : teaching PCI device (vendor:device = 1234:11e8)
                     exposes MMIO BAR0 with identification / liveness /
                     factorial / IRQ / DMA registers, very good for
                     learning PCIe driver model.
    * QEMU "nvme"  : real PCIe NVMe controller, backed by $PCI_NVME_IMG
                     (auto-created at first run, size=$PCI_NVME_SIZE).

Examples:
    $0 arm64
    $0 arm64 debug
    $0 arm64_pci
    $0 arm64_pci debug
EOF
}

if [ $# -lt 1 ]; then
	usage
	exit 1
fi

if [ $# -eq 2 ] && [ $2 == "debug" ]; then
	echo "Enable GDB debug mode (listen on tcp::1234)"
	DBG="-s -S"
fi

# 对 arm64 加一个 "pci" 简写
if [ "$1" == "arm64" ] && [ "$2" == "pci" ]; then
	set -- arm64_pci
fi

# 对 arm64 加一个 "mm" 简写
if [ "$1" == "arm64" ] && [ "${2:-}" == "mm" ]; then
	set -- arm64_mm
fi

# 准备 NVMe 后端镜像
prepare_nvme_img() {
	if [ ! -f "$PCI_NVME_IMG" ]; then
		echo "[pci_lab] create NVMe backing image: $PCI_NVME_IMG ($PCI_NVME_SIZE)"
		qemu-img create -f raw "$PCI_NVME_IMG" "$PCI_NVME_SIZE" >/dev/null
	fi
}

# 准备内存回收实验用的数据盘与 swap 盘
prepare_mm_img() {
	if [ ! -f "$MM_DATA_IMG" ]; then
		echo "[mm_lab] create data disk: $MM_DATA_IMG ($MM_DATA_SIZE)"
		qemu-img create -f raw "$MM_DATA_IMG" "$MM_DATA_SIZE" >/dev/null
	fi
	if [ ! -f "$MM_SWAP_IMG" ]; then
		echo "[mm_lab] create swap disk: $MM_SWAP_IMG ($MM_SWAP_SIZE)"
		qemu-img create -f raw "$MM_SWAP_IMG" "$MM_SWAP_SIZE" >/dev/null
	fi
}

case $1 in
	x86_64)
		if [ ! -c $LROOT/$ROOTFS_X86/$CONSOLE_DEV_NODE ]; then
			echo "please create console device node first, and recompile kernel"
			exit 1
		fi
		qemu-system-x86_64 -kernel arch/x86/boot/bzImage \
				   -append "rdinit=/linuxrc console=ttyS0" -nographic \
				   --virtfs local,id=kmod_dev,path=$PWD/kmodules,security_model=none,mount_tag=kmod_mount \
				   $DBG ;;
	x86)
		if [ ! -c $LROOT/$ROOTFS_X86/$CONSOLE_DEV_NODE ]; then
			echo "please create console device node first, and recompile kernel"
			exit 1
		fi
		qemu-system-i386 -kernel arch/x86/boot/bzImage \
				 -append "rdinit=/linuxrc console=ttyS0" -nographic \
				 --virtfs local,id=kmod_dev,path=$PWD/kmodules,security_model=none,mount_tag=kmod_mount \
				 $DBG ;;
	arm32)
		if [ ! -c $LROOT/$ROOTFS_ARM32/$CONSOLE_DEV_NODE ]; then
			echo "please create console device node first, and recompile kernel"
			exit 1
		fi
		qemu-system-arm -M vexpress-a9 -smp 4 -m 100M -kernel arch/arm/boot/zImage \
				-dtb arch/arm/boot/dts/vexpress-v2p-ca9.dtb -nographic \
				-append "rdinit=/linuxrc console=ttyAMA0 loglevel=8 slub_debug kmemleak=on" \
				--fsdev local,id=kmod_dev,path=$PWD/kmodules,security_model=none -device virtio-9p-device,fsdev=kmod_dev,mount_tag=kmod_mount \
				$DBG ;;
	arm64)
		if [ ! -c $LROOT/$ROOTFS_ARM64/$CONSOLE_DEV_NODE ]; then
			echo "please create console device node first, and recompile kernel"
			exit 1
		fi
		qemu-system-aarch64 -machine virt -cpu cortex-a57 -machine type=virt \
				    -m 100 -smp 2 -kernel arch/arm64/boot/Image \
				    --append "rdinit=/linuxrc console=ttyAMA0" -nographic \
				    --fsdev local,id=kmod_dev,path=$PWD/kmodules,security_model=none -device virtio-9p-device,fsdev=kmod_dev,mount_tag=kmod_mount \
				    $DBG ;;

	arm64_pci|pci)
		# ------------------------------------------------------------------
		# PCIe 驱动实验环境
		#
		# QEMU 的 "virt" 机器自带 GPEX (Generic PCI Express) 主桥，
		# 为了能用 MSI/MSI-X 中断，这里强制启用 GICv3。
		#
		# 拓扑:
		#   pcie.0 (root complex, 由 virt 机器自动创建)
		#     ├── edu        (BDF 自动分配，挂在 pcie.0)
		#     └── rp1 (pcie-root-port)
		#             └── nvme  (作为标准 PCIe endpoint 挂在 rp1 下)
		#
		# 这样你既能看到直接挂在 root complex 下的设备，
		# 也能看到 "root port -> endpoint" 这种真实 PCIe 层级。
		# ------------------------------------------------------------------
		if [ ! -c $LROOT/$ROOTFS_ARM64/$CONSOLE_DEV_NODE ]; then
			echo "please create console device node first, and recompile kernel"
			exit 1
		fi
		prepare_nvme_img

		qemu-system-aarch64 \
		    -machine virt,gic-version=3 -cpu cortex-a57 \
		    -m 512 -smp 2 \
		    -kernel arch/arm64/boot/Image \
		    --append "rdinit=/linuxrc console=ttyAMA0 loglevel=8" \
		    -nographic \
		    --fsdev local,id=kmod_dev,path=$PWD/kmodules,security_model=none \
		    -device virtio-9p-device,fsdev=kmod_dev,mount_tag=kmod_mount \
		    -device edu \
		    -device pcie-root-port,id=rp1,bus=pcie.0,chassis=1,slot=1 \
		    -drive file=$PCI_NVME_IMG,if=none,id=nvme0,format=raw \
		    -device nvme,drive=nvme0,bus=rp1,serial=nvme-rlk-001 \
		    $DBG ;;

	arm64_mm|mm)
		# ------------------------------------------------------------------
		# 内存回收(page reclaim)实验环境
		#
		#   -m $MM_MEM        : 内存刻意调小,几十 MB 的负载就能压到水位线
		#   /dev/vda          : 数据盘,格式化成 ext4 后用于制造 page cache
		#                       (干净页 / 脏页 / 回写),观察文件页回收
		#   /dev/vdb          : swap 盘,mkswap+swapon 后匿名页才能被换出,
		#                       否则 kswapd 扫一圈发现无页可回收就直接退出
		#
		# 进 VM 后先执行: sh /mnt/mm_lab/scripts/mm_setup.sh
		# ------------------------------------------------------------------
		if [ ! -c $LROOT/$ROOTFS_ARM64/$CONSOLE_DEV_NODE ]; then
			echo "please create console device node first, and recompile kernel"
			exit 1
		fi
		prepare_mm_img

		qemu-system-aarch64 -machine virt -cpu cortex-a57 -machine type=virt \
				    -m $MM_MEM -smp 2 -kernel arch/arm64/boot/Image \
				    --append "rdinit=/linuxrc console=ttyAMA0" -nographic \
				    --fsdev local,id=kmod_dev,path=$PWD/kmodules,security_model=none \
				    -device virtio-9p-device,fsdev=kmod_dev,mount_tag=kmod_mount \
				    -drive file=$MM_SWAP_IMG,if=none,id=mmswap,format=raw \
				    -device virtio-blk-device,drive=mmswap,serial=mmswap \
				    -drive file=$MM_DATA_IMG,if=none,id=mmdata,format=raw \
				    -device virtio-blk-device,drive=mmdata,serial=mmdata \
				    $DBG ;;

	*)
		usage
		exit 1 ;;
esac
