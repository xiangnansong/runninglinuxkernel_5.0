# PCIe 驱动学习实验 (pci_lab)

本目录提供了一套循序渐进的 **PCIe 驱动** 实验，配合本仓库的 busybox ARM64 环境使用。
全部代码都是可编译、可加载、可调试的内核模块，目标是帮助你系统地理解：

1. PCI/PCIe 体系结构（Root Complex / Root Port / Endpoint、配置空间、BAR、Capability）
2. Linux 内核 PCI 子系统的核心数据结构 (`struct pci_dev` / `struct pci_driver`)
3. 设备枚举与匹配机制（`pci_device_id` 表、`probe/remove` 生命周期）
4. BAR 区域的 request/ioremap/iomap 及 MMIO 读写（`ioread32/iowrite32`）
5. 中断模型：legacy INTx、MSI、MSI-X
6. DMA：一致性 DMA (`dma_alloc_coherent`)、流式 DMA (`dma_map_single`)

## 0. 准备工作（只做一次）

### 0.1 确保内核编译好
```bash
cd <kernel_root>
./run_busybox.sh arm64          # 先确认普通 busybox 能起来，按 Ctrl+A X 退出
```

### 0.2 启动带 PCIe 设备的 QEMU
```bash
./run_busybox.sh arm64_pci
# 或者：./run_busybox.sh arm64 pci
```

启动后 QEMU 会额外挂载：
- `edu` 设备 —— QEMU 专门为教学设计的 PCI 设备（vendor:device = `1234:11e8`）
- `nvme` 设备 —— 真实的 PCIe NVMe 控制器，挂在一个 `pcie-root-port` 下，模拟真实层级

> 注：busybox 内核默认没开 `CONFIG_BLK_DEV_NVME`，所以 NVMe 只能让你 **观察** PCIe 层级、读它的配置空间，不能直接做块 IO。
> 如果想读写 NVMe 盘，请改用 `./run_debian_arm64.sh run`（Debian rootfs，内核也需自行打开 NVMe 选项）。

### 0.3 进入 VM 后挂载 9P 共享目录
```sh
# 在 QEMU 内
mkdir -p /mnt
mount -t 9p -o trans=virtio kmod_mount /mnt
cd /mnt/pci_lab
ls
```

### 0.4 查看 PCI 总线
```sh
cat /proc/bus/pci/devices      # 内核打印的所有 PCI 设备
ls /sys/bus/pci/devices/       # sysfs 下的设备
ls /sys/bus/pci/devices/0000:00:01.0/      # 随便进入一个设备目录
# 也可以用仓库里预编译好的静态 lspci:
/mnt/rlk_lab/lspci -vv
```

---

## 1. edu 设备寄存器速查（QEMU 源码：`hw/misc/edu.c`）

edu 设备只有一个 **MMIO BAR0**，大小 1 MiB。寄存器都在 BAR0 偏移上（小端，32/64 位访问）：

| 偏移      | 位宽 | 访问 | 含义                                                            |
|-----------|------|------|-----------------------------------------------------------------|
| 0x00      | 32   | RO   | Identification: 读回 `0x010000edU` 之类的 magic（含版本号）     |
| 0x04      | 32   | RW   | Liveness check：写 x，再读回得到 `~x` （按位取反），判活最佳用例 |
| 0x08      | 32   | RW   | Factorial 输入 / 结果（写入触发计算，轮询 status 位 0 查完成）  |
| 0x20      | 32   | RW   | Status：bit0=计算中，bit7=raise IRQ on factorial completion     |
| 0x24      | 32   | RO   | Interrupt status（位图，`[4:0]` 表示中断号）                    |
| 0x60      | 32   | WO   | Interrupt raise（写入位图触发对应中断）                         |
| 0x64      | 32   | WO   | Interrupt ack （写入位图清除对应中断）                          |
| 0x80      | 64   | RW   | DMA source address                                              |
| 0x88      | 64   | RW   | DMA destination address                                         |
| 0x90      | 64   | RW   | DMA transfer count                                              |
| 0x98      | 32   | RW   | DMA command（bit0=start，bit1=from-device，bit2=IRQ）           |

设备内置 4096 字节 DMA 缓冲区，物理地址范围 `[0x40000, 0x41000)`。
主机侧 `src/dst` 使用 CPU 物理地址（DMA 地址），设备侧用这段 `0x40000+` 的区段。

---

## 2. 实验列表

| 目录              | 目的                                                           | 依赖     |
|-------------------|----------------------------------------------------------------|----------|
| `lab1_pci_scan`   | 遍历 `pci_bus` 链表，打印每个 PCI 设备的 BDF / 厂商ID / class  | 无       |
| `lab2_edu_basic`  | 写一个真正的 `struct pci_driver`，probe 时 enable + ioremap    | Lab1     |
| `lab3_edu_mmio`   | 通过 debugfs/procfs 读 identification、做 liveness、算阶乘     | Lab2     |
| `lab4_edu_irq`    | 把 factorial 做成 **异步** —— 用中断完成通知                   | Lab3     |
| `lab5_edu_dma`    | 用 edu 的 DMA 引擎在 host 内存 ↔ 设备内存之间搬数据            | Lab4     |

每个 Lab 都带自己的 `Makefile`、一份 `README.md`（实验目的/步骤/思考题）。

## 3. 建议的学习路径

1. 先看 `lab1_pci_scan`，配合 `/sys/bus/pci` 理解枚举；
2. 进入 `lab2_edu_basic`，重点看 `pci_register_driver / id_table / probe`；
3. 在 `lab3_edu_mmio` 中体会 `ioread32/iowrite32` 和字节序；
4. `lab4_edu_irq` 里理解 **顶/底半部** 与 MSI 的开启；
5. `lab5_edu_dma` 对比一致性 DMA 与流式 DMA，观察 `dma-ranges`。

## 4. 在 QEMU 内编译内核模块

本 busybox 环境太精简，**没有** gcc、make 等工具。推荐做法：
在 **宿主机** 交叉编译好 `.ko`，通过 9P 共享进 VM。

宿主机执行（每个 lab 目录下都一样）：
```bash
cd <kernel_root>
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
make -C $PWD M=$PWD/kmodules/pci_lab/lab1_pci_scan modules
```

然后进入 QEMU：
```sh
mount -t 9p -o trans=virtio kmod_mount /mnt
cd /mnt/pci_lab/lab1_pci_scan
insmod pci_scan.ko
dmesg | tail -40
rmmod pci_scan
```

> 为了方便，我在仓库根目录提供了 `build_pci_labs.sh`（一键编译所有 lab）。

---

祝学习愉快！
