// SPDX-License-Identifier: GPL-2.0
/*
 * pci_scan.c - 枚举系统里所有的 PCI/PCIe 设备
 *
 * 学习目标:
 *   1. 掌握 for_each_pci_dev() / pci_get_device() 等遍历接口。
 *   2. 理解 struct pci_dev 最关键的字段：bus/devfn/vendor/device/class/BAR。
 *   3. 学会读 PCI 配置空间 (pci_read_config_*)，观察 header type。
 *   4. 熟悉 PCIe Capability 链表 (pci_find_capability)。
 *
 * 加载后，通过 `dmesg` 查看输出。也会在 /proc/pci_scan 提供简要列表。
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/pci.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>

#define DRV_NAME "pci_scan"

static const char *class_name(u32 class)
{
	u32 base = class >> 16;
	switch (base) {
	case 0x01: return "Mass storage";
	case 0x02: return "Network";
	case 0x03: return "Display";
	case 0x04: return "Multimedia";
	case 0x06: return "Bridge";
	case 0x0c: return "Serial bus";
	case 0x08: return "System peripheral";
	case 0x11: return "Signal processing";
	case 0xff: return "Unassigned";
	default:   return "Other";
	}
}

static void dump_bars(struct pci_dev *pdev)
{
	int i;

	for (i = 0; i < PCI_STD_NUM_BARS; i++) {
		resource_size_t start = pci_resource_start(pdev, i);
		resource_size_t len   = pci_resource_len(pdev, i);
		unsigned long   flags = pci_resource_flags(pdev, i);

		if (!len)
			continue;

		pr_info(DRV_NAME ":   BAR%d: %pa-%pa (len=%pa) %s%s%s\n",
			i, &start,
			&(resource_size_t){start + len - 1},
			&len,
			(flags & IORESOURCE_MEM) ? "MEM" : "",
			(flags & IORESOURCE_IO)  ? "IO"  : "",
			(flags & IORESOURCE_PREFETCH) ? " PREF" : "");
	}
}

static void dump_capabilities(struct pci_dev *pdev)
{
	static const struct {
		int cap;
		const char *name;
	} caps[] = {
		{ PCI_CAP_ID_PM,    "Power Management" },
		{ PCI_CAP_ID_MSI,   "MSI" },
		{ PCI_CAP_ID_EXP,   "PCI Express" },
		{ PCI_CAP_ID_MSIX,  "MSI-X" },
		{ PCI_CAP_ID_VNDR,  "Vendor Specific" },
	};
	int i, pos;

	for (i = 0; i < ARRAY_SIZE(caps); i++) {
		pos = pci_find_capability(pdev, caps[i].cap);
		if (pos)
			pr_info(DRV_NAME ":   cap: %-18s @ 0x%02x\n",
				caps[i].name, pos);
	}
}

static int pci_scan_show(struct seq_file *m, void *v)
{
	struct pci_dev *pdev = NULL;

	seq_printf(m, "BDF\tVEN:DEV\tCLASS\tNAME\n");
	for_each_pci_dev(pdev) {
		seq_printf(m, "%04x:%02x:%02x.%x\t%04x:%04x\t%06x\t%s\n",
			   pci_domain_nr(pdev->bus),
			   pdev->bus->number,
			   PCI_SLOT(pdev->devfn),
			   PCI_FUNC(pdev->devfn),
			   pdev->vendor, pdev->device,
			   pdev->class,
			   class_name(pdev->class));
	}
	return 0;
}

static int pci_scan_open(struct inode *inode, struct file *file)
{
	return single_open(file, pci_scan_show, NULL);
}

static const struct file_operations pci_scan_fops = {
	.owner   = THIS_MODULE,
	.open    = pci_scan_open,
	.read    = seq_read,
	.llseek  = seq_lseek,
	.release = single_release,
};

static int __init pci_scan_init(void)
{
	struct pci_dev *pdev = NULL;
	int nr = 0;

	pr_info(DRV_NAME ": ==== PCI/PCIe device enumeration ====\n");

	for_each_pci_dev(pdev) {
		u8 hdr_type, irq_line;
		u16 cmd, status;

		pci_read_config_byte(pdev, PCI_HEADER_TYPE, &hdr_type);
		pci_read_config_word(pdev, PCI_COMMAND,  &cmd);
		pci_read_config_word(pdev, PCI_STATUS,   &status);
		pci_read_config_byte(pdev, PCI_INTERRUPT_LINE, &irq_line);

		pr_info(DRV_NAME ": [%d] %04x:%02x:%02x.%x  %04x:%04x  class=%06x (%s)\n",
			nr++,
			pci_domain_nr(pdev->bus), pdev->bus->number,
			PCI_SLOT(pdev->devfn), PCI_FUNC(pdev->devfn),
			pdev->vendor, pdev->device,
			pdev->class, class_name(pdev->class));
		pr_info(DRV_NAME ":   hdr=0x%02x cmd=0x%04x status=0x%04x irq_line=%u irq=%u\n",
			hdr_type & 0x7f, cmd, status, irq_line, pdev->irq);
		dump_bars(pdev);
		dump_capabilities(pdev);
	}

	pr_info(DRV_NAME ": total %d device(s)\n", nr);

	proc_create(DRV_NAME, 0, NULL, &pci_scan_fops);
	return 0;
}

static void __exit pci_scan_exit(void)
{
	remove_proc_entry(DRV_NAME, NULL);
	pr_info(DRV_NAME ": unloaded\n");
}

module_init(pci_scan_init);
module_exit(pci_scan_exit);

MODULE_AUTHOR("rlk_pci_lab");
MODULE_DESCRIPTION("Lab1: enumerate all PCI/PCIe devices");
MODULE_LICENSE("GPL v2");
