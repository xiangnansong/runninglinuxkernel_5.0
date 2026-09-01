# lab7: 一个典型的 PCI 设备驱动样板

本实验给出一个尽量"典型"的 PCI/PCIe 设备驱动 (`pci_driver`)，覆盖：

| 步骤 | 调用 |
|------|------|
| 注册到 PCI 总线 | `pci_register_driver()` (由 `module_pci_driver()` 包) |
| 描述要匹配的设备 | `pci_device_id` 表 + `MODULE_DEVICE_TABLE(pci,...)` |
| 上电 | `pci_enable_device()` |
| 占用 BAR 资源 | `pci_request_regions()` |
| 使能总线主控（DMA 必需） | `pci_set_master()` |
| 把 BAR 映射进内核 | `pci_iomap()` / `pci_iounmap()` |
| 设置 DMA 寻址范围 | `dma_set_mask_and_coherent()` |
| 申请 DMA 一致缓冲 | `dma_alloc_coherent()` |
| 申请 MSI 中断 | `pci_alloc_irq_vectors(... PCI_IRQ_MSI)` |
| 注册中断处理 | `request_irq()` |
| 暴露用户接口 | `misc_register()` (`/dev/pci_dev_demo`) |
| 反向清理 | `remove()` |
| 电源管理（可选） | `pci_save_state()` / `pci_restore_state()` |

代码：`pci_dev_demo.c`，模块名 `pci_dev_demo`。

默认匹配 `VID=0x104c DID=0xb500`，与 `lab6_pcie_ep_demo` 的默认值一致；如果你的板卡上有这个 EP 起来了，host 这边一加载就会 probe。要给其他 PCI 设备用，改 `demo_id_table[]` 里的 VID/PID 即可。

---

## 1. 编译

直接在 host 上交叉编译，或者在 QEMU VM 内部编译都行。VM 内编译：

```bash
cd /mnt/pci_lab/lab7_pci_dev_demo
make
ls *.ko          # pci_dev_demo.ko
```

> 模块依赖：标准内核 `pci`、`misc` 子系统都默认是 builtin，没有特殊 CONFIG 要求。

## 2. 加载/卸载

```bash
insmod pci_dev_demo.ko
dmesg | tail
# pci_dev_demo 0000:00:01.0: probe 104c:b500 (rev 01)
# pci_dev_demo 0000:00:01.0: BAR0: phys=0x10000000 len=0x1000 -> ffffXXXX (magic=0x5043494e)
# pci_dev_demo 0000:00:01.0: DMA buf: va=... pa=0x... size=65536
# pci_dev_demo 0000:00:01.0: MSI ok, virq=33
# pci_dev_demo 0000:00:01.0: ready, /dev/pci_dev_demo

ls -l /dev/pci_dev_demo

rmmod pci_dev_demo
```

## 3. 用户态接口

`/dev/pci_dev_demo` 暴露了几个最常见的 PCI 驱动操作：

```bash
# 读 BAR0+0x00 上的 magic（EP 启动时填的 'PCIN' = 0x5043494e）
python3 -c '
import fcntl, struct, ctypes
DEMO_IOC_GET_MAGIC = (2 << 30) | (4 << 16) | (ord("D") << 8) | 0
f = open("/dev/pci_dev_demo", "rb")
buf = ctypes.c_uint32(0)
fcntl.ioctl(f, DEMO_IOC_GET_MAGIC, buf)
print(hex(buf.value))
'

# 给 EP 写一个 doorbell（写到 BAR0+0x04）
echo 0x12345678 > /dev/pci_dev_demo

# 阻塞等 MSI；EP 那边触发后这条会立刻返回
cat /dev/pci_dev_demo        # 输出 "irq=N"
```

`poll()` / `epoll()` 也支持，所以也可以用 select/epoll 监听这个 fd。

## 4. lspci 视角

```bash
lspci -v -s 00:01.0
# 04:00.0 ...: Texas Instruments Device b500
#         Subsystem: Texas Instruments Device 0001
#         Flags: bus master, fast devsel, ...
#         Memory at 10000000 (32-bit, non-prefetchable) [size=4K]
#         Capabilities: [50] MSI: Enable+ Count=1/1 Maskable- 64bit+
#         Kernel driver in use: pci_dev_demo
```

## 5. 文件清单

```
lab7_pci_dev_demo/
├── Makefile
├── pci_dev_demo.c
└── README.md
```

## 6. 想改成"驱动我自己的某块板子"

只需要改两处：

1. `demo_id_table[]`：把 `PCI_DEVICE(0x104c, 0xb500)` 改成你板卡的 VID/PID。如果板卡是某厂商的成熟系列，也可以用 `PCI_DEVICE_SUB(...)`、`PCI_DEVICE_CLASS(...)`、或 `PCI_DEVICE_DATA(...)` 形式。
2. `REG_*` 偏移：按你板子手册里 BAR0 上真实寄存器地图调整；中断处理函数 `demo_msi_handler()` 里读的状态/确认寄存器也要改成实际寄存器。

其它模板代码（probe 顺序、错误回滚、remove 顺序、PM、misc 字符设备）都可以照搬。
