# PCIe 系列学习教程（Task 驱动）

> 基础资料：
> - 博客：Felix「PCIe 扫盲」第一阶段目录  <http://blog.chinaaet.com/justlxy/p/5100053251>
> - 书：MindShare 《PCI Express Technology 3.0》（本仓库根目录 PDF）
> - PCIe Base Spec v2.0 / v3.0（搜 `PCI_Express_Base_Specification_Revision_3.0`）
> - 环境：本仓库 `run_busybox.sh arm64_pci` 启动的 QEMU，带 `edu` + `nvme` 两个设备
> - 实验代码：本目录 `lab1_pci_scan` ~ `lab5_edu_dma`

本教程把第一阶段 19 篇博文的知识点拆成 10 个 **Task**，每个 Task 都要求：
**读 → 看 → 写 → 想**（读理论、看硬件、写代码、想问题）。

---

## Task 0：搭建环境 & 第一次 `lspci`

**目标**：在 QEMU 里能看到至少两个 PCI 设备（`edu`、`nvme`）。

**动手**：
```bash
# 宿主机
./run_busybox.sh arm64_pci          # 启动带 PCIe 设备的 QEMU

# QEMU 内
mkdir -p /mnt && mount -t 9p -o trans=virtio kmod_mount /mnt
cat /proc/bus/pci/devices
/mnt/rlk_lab/lspci -vv
ls /sys/bus/pci/devices/
```

**交付物**：记下每个设备的 BDF（Bus:Device.Function）、Vendor:Device ID、Class Code、BAR 大小。

**思考**：
1. `edu` 的 Vendor:Device 为什么是 `1234:11e8`？（提示：QEMU `hw/misc/edu.c`）
2. `nvme` 为什么挂在 `01:00.0` 而不是 `00:xx.x`？（提示：它在 `pcie-root-port` 下）

---

## Task 1：PCI 总线基本概念（回顾并行总线时代）

**对应博文**：2、3、4、5
- PCIe 扫盲——PCI 总线基本概念
- 一个典型的 PCI 总线周期
- Reflected-Wave Signaling
- PCI 总线的三种传输模式

**要点笔记**：

| 概念 | 关键记忆点 |
|------|----------|
| **共享总线** | PCI 是多 master 共享总线，需要 `REQ#`/`GNT#` 仲裁 |
| **并行传输** | 32bit AD 线复用地址/数据，`FRAME#`/`IRDY#`/`TRDY#` 握手 |
| **Reflected-Wave** | 不加终端电阻，靠反射波达到有效电平（解释为什么 PCI 限 33/66MHz） |
| **三种传输模式** | ① Memory / IO / Config Read/Write ② Single vs Burst ③ DAC（64-bit 地址） |

**动手**：纸上画一次「CPU 对 PCI 设备做一次 32-bit MemRead」的时序图，标出 `FRAME#`、`AD`、`IRDY#`、`TRDY#` 的变化。

**思考**：PCIe 为什么不再需要仲裁？（答：点对点，不是共享介质）

---

## Task 2：配置空间 & BDF & 地址空间分配

**对应博文**：6、7、8、9
- PCI 总线的中断和错误处理
- PCI 总线的地址空间分配
- PCI 总线配置周期产生和配置寄存器
- 66MHz PCI 与技术瓶颈

**核心**：配置空间（256B Type 0 / Type 1） → BAR → 地址空间映射。

**动手 A（sysfs 观察）**：
```sh
cd /sys/bus/pci/devices/0000:00:01.0      # edu 设备，具体 BDF 以实际为准
hexdump -C config | head                  # 读 256 字节配置空间
cat resource                              # 打印每个 BAR 的起止物理地址
ls -l resource0                           # BAR0 对应的 MMIO 窗口
```

**动手 B（跑 lab1）**：
```bash
# 宿主机交叉编译
cd <kernel_root>
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
make -C $PWD M=$PWD/kmodules/pci_lab/lab1_pci_scan modules

# QEMU 内
cd /mnt/pci_lab/lab1_pci_scan
insmod pci_scan.ko
dmesg | tail -40
```
阅读 `pci_scan.c`，理解：
- `for_each_pci_dev()` 遍历
- `pci_read_config_dword(dev, PCI_VENDOR_ID, &v)` 读配置
- `pci_resource_start/end/len/flags` 获取 BAR

**交付物**：手写一张表，把 edu 设备的 256B 配置空间中「VendorID / DeviceID / Command / Status / Class Code / BAR0 / Capabilities Pointer / Interrupt Line/Pin」的偏移和值都填出来。

**思考**：
1. Type 0 和 Type 1 配置头的区别？（EP vs Bridge）
2. 为什么 BAR 最低几位不是地址？（low bits 存放 Type、Prefetchable、32/64 位标志）

---

## Task 3：PCI-X → PCIe 演进 & 软件兼容性

**对应博文**：10、11、12
- PCI-X 总线基本概念
- PCIe 总线基本概念
- PCIe 怎样做到在软件上兼容 PCI

**要点**：
- PCIe 物理层串行、差分、嵌入式时钟（8b/10b 或 128b/130b 恢复时钟）。
- **软件兼容**：配置空间头（256B）保持不变，OS 枚举/驱动加载流程完全复用 PCI。
- **扩展配置空间**：PCIe 从 256B 扩到 4KiB，后面的 3840B 放 Extended Capability（AER、DPC、ACS、SR-IOV…）。

**动手**：
```sh
# 读完整 4KiB 扩展配置空间
hexdump -C /sys/bus/pci/devices/0000:00:<edu>/config | wc -l
# 对比 edu (legacy)  vs nvme (Native PCIe EP)：NVMe 通常能看到 MSI-X、PM、PCIe Cap
```
读 `lspci -vv` 输出里 `Capabilities:` 一段，认识：
- `[50] Power Management`
- `[60] MSI: Enable+ Count=1/1 Maskable-`
- `[7c] Express Endpoint, MSI 00`

**思考**：为什么博客里说 Legacy Endpoint 允许 IO Space / Locked Request，Native Endpoint 必须 MMIO？

---

## Task 4：PCIe 体系结构 —— RC / Switch / Endpoint

**对应博文**：13（PCIe 总线体系结构入门）+ MindShare Ch.1–3

**核心图**（自己画一遍）：
```
     CPU
      |
   [Root Complex]
     /     \
  RP0      RP1
   |        |
  EP      Switch
          /  |  \
         EP  EP  Bridge→PCI
```

**动手**：
```sh
# 看完整拓扑
/mnt/rlk_lab/lspci -tvv
# 读 Root Port / Switch 的 Type 1 头
hexdump -C /sys/bus/pci/devices/0000:00:01.0/config | head
```
重点关注 Type 1 头里的：
- Primary / Secondary / Subordinate Bus Number
- Memory Base / Limit、Prefetchable Memory Base / Limit

**思考**：Switch 为什么内部看起来是「一上 N 下」的多个虚拟 PCI-PCI Bridge？

---

## Task 5：事务层（TLP）三部曲

**对应博文**：14、15、16

**三大主题**：
1. **TLP 格式**：Header（3DW / 4DW） + Data Payload + ECRC
   - Fmt/Type 字段区分 MRd / MWr / CfgRd0/1 / CplD / Msg
2. **路由方式**：Address Routing（Mem/IO）、ID Routing（Cfg/Cpl）、Implicit Routing（Msg）
3. **排序 & 流控**：Strong Ordering / Relaxed Ordering、Posted vs Non-Posted、Credit-based FC

**动手（lab2_edu_basic）**：
```bash
make -C <kernel_root> M=$PWD/kmodules/pci_lab/lab2_edu_basic modules
# QEMU:
cd /mnt/pci_lab/lab2_edu_basic
insmod edu_basic.ko
dmesg | tail
```
读 `edu_basic.c`，对照出每个 API 在 TLP 视角做了什么：

| C 调用 | 实际 TLP |
|--------|---------|
| `pci_enable_device()` | 写 Command.IO/MEM/BM_EN（CfgWr0） |
| `pci_request_regions()` | 纯 Linux 资源管理，无总线行为 |
| `pci_iomap(dev, 0, 0)` | 建 MMIO 映射，无 TLP |
| `ioread32(base + 0x00)` | 发 32-bit MRd TLP，得 CplD |
| `iowrite32(v, base+4)` | 发 32-bit MWr TLP（Posted，无返回） |

**思考**：
1. 为什么 MemWrite 是 Posted 而 MemRead 是 Non-Posted？
2. Completion TLP 如何找到请求发起者？（Requester ID + Tag）

---

## Task 6：数据链路层（DLL）

**对应博文**：17（数据链路层入门）+ MindShare Ch.9

**要点**：
- 把事务层送来的 TLP 加上 **Sequence Number + LCRC**，封装成链路帧。
- 用 **DLLP（Ack/Nak、FC Init/Update、PM）** 做可靠性和流控。
- **重传机制**：收到 Nak 或超时未收到 Ack，重发缓冲区里的 TLP。

**动手**：
QEMU 本身不模拟真正的串行链路，所以 DLL 无法抓波形。但我们能间接观察：
```sh
# 看 AER（Advanced Error Reporting）计数器
setpci -s 01:00.0 ECAP_AER+10.l    # Uncorrectable Error Status
setpci -s 01:00.0 ECAP_AER+14.l    # Correctable Error Status
```
另外在物理硬件上，DLL 的行为主要通过链路训练 + 性能计数器 + 示波器/协议分析仪观察。

**思考**：若 Requester 发出 MRd 后迟迟收不到 Completion，是 DLL 的问题还是 TL 的问题？

---

## Task 7：物理层 & 链路训练

**对应博文**：18（物理层入门）+ MindShare Ch.12–14

**要点**：
- **物理层分两个子层**：逻辑子层（8b/10b 或 128b/130b 编解码、扰码、Byte Striping）+ 电气子层（差分、均衡、AC coupling）。
- **LTSSM**：Detect → Polling → Configuration → L0 → L0s / L1 / L2。
- **Lane Reversal、Polarity Inversion、Link Width Negotiation**。

**动手**：
```sh
# 读 PCIe Capability 里的 Link Control / Status
/mnt/rlk_lab/lspci -vvs 00:01.0 | grep -E 'LnkCap|LnkSta|LnkCtl'
# 典型输出：
#   LnkCap: Port #0, Speed 16GT/s, Width x16, ASPM ...
#   LnkSta: Speed 16GT/s (ok), Width x16 (ok)
```

**交付物**：对 NVMe 和它的 Root Port，分别记录 Speed/Width 的「能力」和「实际协商结果」，解释两者为什么可能不一致（降速、降位宽、训练失败）。

---

## Task 8：一个 Memory Read 的完整旅程（串起全栈）

**对应博文**：19（一个 Memory Read 操作的例子）

**目标**：把 CPU 上一条 `ioread32()` 在 TL/DLL/PHY 三层都画出来。

**动手（lab3_edu_mmio）**：
```bash
make -C <kernel_root> M=$PWD/kmodules/pci_lab/lab3_edu_mmio modules
# QEMU
cd /mnt/pci_lab/lab3_edu_mmio
insmod edu_mmio.ko
# 通过 debugfs/procfs 读 edu 设备 identification / liveness / factorial
cat /proc/edu/ident          # 触发 MRd TLP
echo 7 > /proc/edu/factorial # 触发 MWr + 后续轮询
cat /proc/edu/factorial      # 读回结果
```

**要求**：画一张大图，把下面每一步列出来：

1. 驱动调用 `ioread32(base + 0x00)`。
2. ARM64 上 LDR 指令访问到 MMIO 物理地址。
3. Root Complex 把它翻译成一个 **MRd TLP**（3DW Header，Fmt/Type=00000、Length=1、Address=BAR0+0）。
4. DLL 给 TLP 加 Seq Num + LCRC。
5. 物理层：8b/10b 编码（或 128b/130b），串行化，差分驱动。
6. edu 设备侧：反向解码，剥 LCRC，送到 TL。
7. edu 内部命中 identification 寄存器，返回 **CplD TLP**（含 4 字节 data）。
8. 走回路：TL → DLL → PHY → PHY → DLL → TL。
9. RC 把 data 交还给 CPU 的 LDR。
10. 整个过程需要 Ack DLLP 保证可靠传输；若失败则重传。

---

## Task 9：MSI/MSI-X + DMA 实战（博客第二阶段预热）

**目标**：理解「中断」「DMA」在 PCIe 语义下本质都是 **Memory Write TLP**。

**动手 A（lab4_edu_irq，MSI）**：
```bash
make -C <kernel_root> M=$PWD/kmodules/pci_lab/lab4_edu_irq modules
cd /mnt/pci_lab/lab4_edu_irq
insmod edu_irq.ko
echo 10 > /proc/edu/factorial_async
dmesg | tail       # 观察 MSI 中断回调打印
cat /proc/interrupts | grep edu
```
关键 API：`pci_alloc_irq_vectors(pdev, 1, 1, PCI_IRQ_MSI)` → `pci_irq_vector()` → `request_irq()`。
**要点**：MSI 的本质是 EP 发一个 **写 TLP** 到 RC 指定地址（`MSI Address` cap），该地址被 RC 解释为一次中断。

**动手 B（lab5_edu_dma）**：
```bash
make -C <kernel_root> M=$PWD/kmodules/pci_lab/lab5_edu_dma modules
cd /mnt/pci_lab/lab5_edu_dma
insmod edu_dma.ko
# 通过 /proc/edu/dma_test 触发 host → device / device → host 的拷贝
```
对比两种 DMA：
- **一致性 DMA**：`dma_alloc_coherent()` —— 驱动 + 设备都直接看一致内存，适合命令/描述符环。
- **流式 DMA**：`dma_map_single()` —— 临时 mapping，适合 bulk 数据包（有方向、有生命周期）。

**思考**：
1. `dma_map_single(..., DMA_TO_DEVICE)` 后 CPU 为什么不能再写这块 buffer？
2. IOMMU（`smmu-v3`）开启后，DMA 地址和物理地址的关系是什么？

---

## 结业综合题

做完 T0–T9 后，尝试独立完成：

1. **写一篇长文**（≥3000 字）：以「一次 `read(fd, buf, 4096)` 从 NVMe 盘读 4KiB」为线索，自底向上串起 PCIe 配置空间枚举 → BAR 映射 → NVMe Admin Queue → IO Queue → MSI-X 完成中断 → DMA 写回 buf 的全链路。
2. **魔改一个 lab**：例如把 `lab5_edu_dma` 改成支持 scatter-gather（多段流式 DMA），并在 `dmesg` 里打印每段的设备端 DMA 地址。
3. **读一份真实 PCIe 驱动**：建议 `drivers/nvme/host/pci.c` 或 `drivers/net/ethernet/intel/e1000e/`，画出它的 `probe()` 调用链。

---

## 推荐的阅读节奏

| 周 | 任务 | 博文 | MindShare 章节 |
|----|------|------|---------------|
| 第 1 周 | T0–T2 | 1–9 | Ch.1–2 |
| 第 2 周 | T3–T5 | 10–16 | Ch.3–8 |
| 第 3 周 | T6–T8 | 17–19 | Ch.9–14 |
| 第 4 周 | T9 + 综合题 | 第二阶段博客 | Ch.15+（MSI/MSI-X、DMA、AER） |

学完第一阶段，可以接着刷 Felix 第二/三/四/五阶段目录：
- 第二阶段 <http://blog.chinaaet.com/justlxy/p/5100053328>
- 第三阶段 <http://blog.chinaaet.com/justlxy/p/5100053481>
- 第四阶段 <http://blog.chinaaet.com/justlxy/p/5100057779>
- 第五阶段 <http://blog.chinaaet.com/justlxy/p/5100061871>

祝你一路打到 PCIe Gen5！
