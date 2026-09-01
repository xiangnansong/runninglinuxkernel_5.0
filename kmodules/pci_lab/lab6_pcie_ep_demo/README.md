# lab6: 一个最小的 PCIe Endpoint(EP) 侧驱动

本实验演示了在 Linux PCI Endpoint Framework 下，如何编写一个 EP 侧
功能驱动 (`pci_epf_driver`)，并完成三件事：

1. **配置自身的 VID/PID**：在 `pci_epf_header` 中设置 `vendorid`、
   `deviceid`、`subclass_code` 等字段，由框架经 EPC 控制器写入 EP
   的 PCIe 配置空间头。
2. **申请内存并映射到 BAR**：使用 `pci_epf_alloc_space()` 申请一段
   DMA 一致内存，再通过 `pci_epc_set_bar()` 把它暴露到 BAR0，Host
   枚举到本设备后即可通过 BAR 直接读写这段内存。
3. **触发 MSI 中断**：调用 `pci_epc_raise_irq(..., PCI_EPC_IRQ_MSI, ...)`
   让 EP 控制器构造一笔 MSI 写 TLP 发到 Host。

代码位置：`pcie_ep_demo.c`，模块名 `pcie_ep_demo`。

---

## 1. 内核需要打开的 CONFIG

PCI Endpoint Framework 默认不会被 `debian_defconfig` 打开，所以编译
内核之前需要确认下面这些选项已开：

```
CONFIG_PCI_ENDPOINT=y
CONFIG_PCI_ENDPOINT_CONFIGFS=y
# 你的板子使用什么 EPC 控制器就再开对应的，例如 DesignWare:
# CONFIG_PCIE_DW_EP=y
# CONFIG_PCI_DRA7XX_EP=y / CONFIG_PCIE_CADENCE_EP=y / ...
```

可以通过 `./run_debian_arm64.sh menuconfig` 进入：

```
Bus support  --->
  PCI support  --->
    PCI Endpoint  --->
      [*] PCI Endpoint Support
      [*]   PCI Endpoint Configfs Support
```

修改完之后重新编译并更新 rootfs：

```bash
./run_debian_arm64.sh build_kernel
sudo ./run_debian_arm64.sh update_rootfs
```

> 说明：`debian_defconfig` 默认没有真正的 EPC 硬件控制器，本驱动主要
> 用于阅读、走通 EP 框架流程，以及在带有 EPC 硬件（如 DesignWare EP、
> Cadence EP、TI K2G EP 等）的板卡 / QEMU 仿真平台上做实验。

## 2. 在 QEMU 里编译模块

QEMU 启动后（`./run_debian_arm64.sh run`），在 VM 内：

```bash
cd /mnt/pci_lab/lab6_pcie_ep_demo
make
ls *.ko          # 应看到 pcie_ep_demo.ko
insmod pcie_ep_demo.ko
dmesg | tail
```

加载成功后会看到：

```
pcie_ep_demo: loaded (default VID=0x104c DID=0xb500)
```

并出现一个 sysfs 入口：

```
/sys/kernel/pcie_ep_demo/raise_msi
```

## 3. 通过 configfs 把驱动绑到 EPC 控制器

下面是 PCI Endpoint Framework 标准用法，假设你的 EPC 控制器名字
（`ls /sys/kernel/config/pci_ep/controllers/` 能看到）叫
`<epc_name>`：

```bash
mount -t configfs none /sys/kernel/config 2>/dev/null
cd /sys/kernel/config/pci_ep

# 1) 创建本驱动的一个 function 实例（func0）
mkdir functions/pcie_ep_demo/func0

# 2) （可选）覆盖默认的 VID/PID
echo 0x104c > functions/pcie_ep_demo/func0/vendorid
echo 0xb500 > functions/pcie_ep_demo/func0/deviceid
echo 1      > functions/pcie_ep_demo/func0/msi_interrupts

# 3) 把这个 function 绑到具体的 EPC 控制器上
ln -s functions/pcie_ep_demo/func0 controllers/<epc_name>/

# 4) 启动链路
echo 1 > controllers/<epc_name>/start
```

绑定成功后，本驱动里的 `bind()` 就会被调用，`dmesg` 看到：

```
pci_epf pcie_ep_demo.0: bind ok: VID=0x104c DID=0xb500 bar=BAR0 msi=1
pci_epf pcie_ep_demo.0: BAR0 configured: phys=0x... size=4096 virt=...
pci_epf pcie_ep_demo.0: PCIe link up, ready to serve host
pci_epf pcie_ep_demo.0: raised MSI vec=0 (total=1)
```

## 4. 主动触发 MSI 中断

```bash
# 触发第 0 号 MSI
echo 0 > /sys/kernel/pcie_ep_demo/raise_msi

# 查看 EP 已经触发过的 MSI 次数 / Host 写入 doorbell 的值
cat /sys/kernel/pcie_ep_demo/raise_msi
```

`dmesg` 上会看到：

```
pci_epf pcie_ep_demo.0: raised MSI vec=0 (total=2)
```

Host 端使用 `lspci -v` 应该能看到本设备：VID `104c`、DID `b500`，并且
有一个 4KB 大小的 Memory BAR0；如果 Host 上有匹配的 RC 测试驱动
(例如 `pci-epf-test` + 内核 `tools/pci/pcitest.c`)，就能完整验证读
/写/中断回环。

## 5. 文件清单

```
lab6_pcie_ep_demo/
├── Makefile          # 标准 out-of-tree 模块 Makefile
├── pcie_ep_demo.c    # EP 功能驱动主体
└── README.md         # 本文档
```
