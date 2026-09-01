# Lab1: PCI 设备枚举

## 实验目的
- 理解 `struct pci_dev` / `struct pci_bus` 在内核里的组织方式
- 学会通过 `for_each_pci_dev()` 遍历所有 PCI 设备
- 读取并解释 BAR、Command/Status、Capability 链表
- 对比 sysfs（`/sys/bus/pci/devices/*`）和内核打印

## 实验步骤
1. 在宿主机编译：
   ```bash
   cd <kernel_root>
   export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
   make -C $PWD M=$PWD/kmodules/pci_lab/lab1_pci_scan modules
   ```
2. 启动带 PCIe 设备的 QEMU：
   ```bash
   ./run_busybox.sh arm64_pci
   ```
3. 在 VM 内：
   ```sh
   mount -t 9p -o trans=virtio kmod_mount /mnt
   cd /mnt/pci_lab/lab1_pci_scan
   insmod pci_scan.ko
   dmesg | grep pci_scan
   cat /proc/pci_scan
   rmmod pci_scan
   ```

## 你应该能看到
- PCI host bridge (vendor=0x1b36 Red Hat)
- edu 设备 (`1234:11e8`, class=0xff0000 Unassigned)
- pcie-root-port (class=0x060400 Bridge)
- NVMe controller (`1b36:0010`, class=0x010802 Mass storage / NVM)
- 以及 edu 的 **BAR0 MEM**、NVMe 的 **BAR0 64-bit MEM**
- NVMe 和 Root Port 应具备 **PCI Express Capability**

## 思考题
1. 为什么 edu 设备在 `/sys/bus/pci/devices` 下的 BDF 不带域 (domain)？实际是 0 域。
2. pcie-root-port 的 "header type" 是几？含义是什么？（提示：type 1 = PCI-to-PCI Bridge）
3. 用 `setpci -s <BDF> COMMAND.w` 读回 command 寄存器和模块打印是否一致？
4. 修改代码：打印每个设备的 Subsystem Vendor/Device ID（`PCI_SUBSYSTEM_VENDOR_ID`）。
