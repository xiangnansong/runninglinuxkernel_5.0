// SPDX-License-Identifier: GPL-2.0
/*
 * pcie_ep_demo.c - 一个最小可用的 PCIe Endpoint(EP) 侧功能驱动
 *
 * 该驱动演示了在 Linux PCI Endpoint Framework 之下，EP 侧需要做的
 * 三件最核心的事情：
 *   1. 配置自身的 Vendor ID / Device ID（写 PCIe 配置空间头）
 *   2. 申请一段内存空间，并将其映射到 EP 自身的 BAR 上，让 RC
 *      (Root Complex/Host) 能够通过 BAR 访问到这段内存
 *   3. 通过 EPC 提供的接口主动向 Host 触发 MSI 中断
 *
 * 工作原理（简要）：
 *   - 本驱动注册一个 pci_epf_driver；
 *   - 通过 configfs 把它绑定到一个 EPC 控制器后，框架会回调 ->bind()；
 *   - 在 ->bind() 中我们写配置头（VID/PID）、分配 DMA 一致内存、设置 BAR、
 *     设置 MSI 中断个数；
 *   - 之后通过一个 sysfs 节点 /sys/kernel/pcie_ep_demo/raise_msi 主动触发
 *     一次 MSI 中断到 Host。
 *
 * 在 QEMU/真机上的使用流程（host 端 configfs）大致如下：
 *   mount -t configfs none /sys/kernel/config
 *   cd /sys/kernel/config/pci_ep
 *   mkdir functions/pcie_ep_demo/func0
 *   # 上面 mkdir 之后内核会通过 configfs 调用本驱动 probe
 *   echo 0x104c > functions/pcie_ep_demo/func0/vendorid   # 可被 configfs 覆盖
 *   echo 0xb500 > functions/pcie_ep_demo/func0/deviceid
 *   echo 1      > functions/pcie_ep_demo/func0/msi_interrupts
 *   ln -s functions/pcie_ep_demo/func0 controllers/<epc_name>/
 *   echo 1 > controllers/<epc_name>/start
 */

#include <linux/delay.h>
#include <linux/io.h>
#include <linux/kernel.h>
#include <linux/kobject.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/sysfs.h>

#include <linux/pci-epc.h>
#include <linux/pci-epf.h>
#include <linux/pci_ids.h>
#include <linux/pci_regs.h>

#define DRV_NAME		"pcie_ep_demo"

/* 默认的 VID/PID —— 既可在驱动里写死，也可被 configfs 修改 */
#define DEMO_VENDOR_ID		0x104c	/* TI, 仅作演示 */
#define DEMO_DEVICE_ID		0xb500
#define DEMO_SUBVENDOR_ID	0x104c
#define DEMO_SUBDEVICE_ID	0x0001

/* 我们暴露给 Host 的 BAR 大小：4KB 即可，足够放下我们的寄存器/数据区 */
#define DEMO_BAR_SIZE		(4 * 1024)

/* 本驱动期望的 MSI 向量个数（实际 host 协商出来可能更少） */
#define DEMO_MSI_NR		1

/*
 * 这块内存的前若干字节作为 "EP <-> Host" 之间的共享寄存器区，
 * Host 端通过 ioread32/iowrite32(BAR0 + offset) 访问；
 * EP 端就是普通的内存访问 epf_demo->reg_base->xxx。
 */
struct pcie_ep_demo_reg {
	u32 magic;		/* 0x00: EP 启动后填一个 magic 给 Host 检测 */
	u32 host_doorbell;	/* 0x04: Host 写这里，相当于踢一下 EP */
	u32 ep_status;		/* 0x08: EP 把状态写在这里给 Host 读 */
	u32 irq_count;		/* 0x0c: EP 已经触发过的 MSI 次数 */
} __packed;

#define DEMO_MAGIC		0x5043494eU	/* 'PCIN' */

struct pcie_ep_demo {
	struct pci_epf		*epf;
	enum pci_barno		bar;		/* 我们使用哪一根 BAR */
	struct pcie_ep_demo_reg	*reg_base;	/* 分配出的内存（虚拟地址） */
	bool			bound;
};

/* 全局指针，sysfs 入口需要它来触发中断（仅演示，多实例需要改造） */
static struct pcie_ep_demo *g_demo;

/*
 * 配置空间头：framework 会拿这个结构体调用 epc->ops->write_header()，
 * 进而把 VID/PID/Class 等字段写入 EP 控制器的 PCIe 配置空间。
 */
static struct pci_epf_header demo_header = {
	.vendorid	  = DEMO_VENDOR_ID,
	.deviceid	  = DEMO_DEVICE_ID,
	.revid		  = 0x01,
	.baseclass_code	  = PCI_CLASS_OTHERS >> 8,
	.subclass_code	  = PCI_CLASS_OTHERS & 0xff,
	.subsys_vendor_id = DEMO_SUBVENDOR_ID,
	.subsys_id	  = DEMO_SUBDEVICE_ID,
	.interrupt_pin	  = PCI_INTERRUPT_INTA,
};

/*
 * 申请一段内核内存（dma_alloc_coherent），并把它登记到 epf->bar[]，
 * 然后调用 pci_epc_set_bar() 让 EP 控制器把这块内存暴露到 BAR 上。
 *
 * 这一步完成后，Host 端枚举到此 EP，读它的 BAR0 时拿到的物理地址 +
 * size，就可以 ioremap 后直接读写到我们这里 dma_alloc_coherent 出来
 * 的同一块内存。
 */
static int pcie_ep_demo_alloc_and_set_bar(struct pcie_ep_demo *demo)
{
	struct pci_epf *epf = demo->epf;
	struct pci_epc *epc = epf->epc;
	struct device *dev = &epf->dev;
	struct pci_epf_bar *epf_bar;
	void *base;
	int ret;

	base = pci_epf_alloc_space(epf, sizeof(*demo->reg_base) > DEMO_BAR_SIZE ?
				   sizeof(*demo->reg_base) : DEMO_BAR_SIZE,
				   demo->bar);
	if (!base) {
		dev_err(dev, "failed to allocate BAR%d backing memory\n",
			demo->bar);
		return -ENOMEM;
	}
	demo->reg_base = base;

	/* 提前把寄存器填好，让 Host 一上来就能读到一个有效 magic */
	demo->reg_base->magic        = DEMO_MAGIC;
	demo->reg_base->host_doorbell = 0;
	demo->reg_base->ep_status     = 0;
	demo->reg_base->irq_count     = 0;

	epf_bar = &epf->bar[demo->bar];

	/*
	 * 是否要 64-bit BAR 由 size 是否 >4G 决定；这里 4K 用 32-bit 即可。
	 * pci_epf_alloc_space() 已经写好了 size/phys_addr，并把 flags
	 * 设为 PCI_BASE_ADDRESS_SPACE_MEMORY；这里再补上 32/64bit 类型。
	 */
	epf_bar->flags |= upper_32_bits(epf_bar->size) ?
				PCI_BASE_ADDRESS_MEM_TYPE_64 :
				PCI_BASE_ADDRESS_MEM_TYPE_32;

	ret = pci_epc_set_bar(epc, epf->func_no, epf_bar);
	if (ret) {
		dev_err(dev, "failed to set BAR%d (ret=%d)\n", demo->bar, ret);
		pci_epf_free_space(epf, demo->reg_base, demo->bar);
		demo->reg_base = NULL;
		return ret;
	}

	dev_info(dev,
		 "BAR%d configured: phys=%pad size=%zu virt=%p\n",
		 demo->bar, &epf_bar->phys_addr, epf_bar->size, base);
	return 0;
}

static void pcie_ep_demo_clear_bar(struct pcie_ep_demo *demo)
{
	struct pci_epf *epf = demo->epf;
	struct pci_epc *epc = epf->epc;
	struct pci_epf_bar *epf_bar = &epf->bar[demo->bar];

	if (!demo->reg_base)
		return;

	pci_epc_clear_bar(epc, epf->func_no, epf_bar);
	pci_epf_free_space(epf, demo->reg_base, demo->bar);
	demo->reg_base = NULL;
}

/*
 * 主动向 Host 触发一次 MSI 中断。中断号 0 表示该 EP 申请到的第一根
 * MSI 向量。底层最终是 EPC 控制器构造一笔 “写 MSI 地址 + MSI data”
 * 的 PCIe 内存写 TLP 发到 Host。
 */
static int pcie_ep_demo_raise_msi(struct pcie_ep_demo *demo, u16 vec)
{
	struct pci_epf *epf = demo->epf;
	struct pci_epc *epc = epf->epc;
	struct device *dev = &epf->dev;
	int nr;
	int ret;

	if (!demo->bound) {
		dev_warn(dev, "EP not bound yet, cannot raise MSI\n");
		return -ENODEV;
	}

	/* 先看看 Host 实际给我们留了多少根 MSI 向量 */
	nr = pci_epc_get_msi(epc, epf->func_no);
	if (nr <= 0) {
		dev_err(dev, "MSI not enabled by host (nr=%d)\n", nr);
		return -EINVAL;
	}
	if (vec >= nr) {
		dev_err(dev, "MSI vec %u out of range (max %d)\n", vec, nr);
		return -EINVAL;
	}

	ret = pci_epc_raise_irq(epc, epf->func_no, PCI_EPC_IRQ_MSI, vec + 1);
	if (ret) {
		dev_err(dev, "raise MSI failed: %d\n", ret);
		return ret;
	}

	if (demo->reg_base)
		demo->reg_base->irq_count++;

	dev_info(dev, "raised MSI vec=%u (total=%u)\n",
		 vec, demo->reg_base ? demo->reg_base->irq_count : 0);
	return 0;
}

/*
 * sysfs 入口： echo 0 > /sys/kernel/pcie_ep_demo/raise_msi
 * 用来手动触发一次 MSI，方便在 EP 端命令行做实验。
 */
static struct kobject *demo_kobj;

static ssize_t raise_msi_store(struct kobject *kobj,
			       struct kobj_attribute *attr,
			       const char *buf, size_t count)
{
	unsigned int vec;
	int ret;

	if (!g_demo)
		return -ENODEV;

	if (kstrtouint(buf, 0, &vec))
		return -EINVAL;

	ret = pcie_ep_demo_raise_msi(g_demo, vec);
	return ret ? ret : count;
}

static ssize_t raise_msi_show(struct kobject *kobj,
			      struct kobj_attribute *attr, char *buf)
{
	if (!g_demo || !g_demo->reg_base)
		return scnprintf(buf, PAGE_SIZE, "not-ready\n");

	return scnprintf(buf, PAGE_SIZE,
			 "irq_count=%u host_doorbell=0x%08x\n",
			 g_demo->reg_base->irq_count,
			 g_demo->reg_base->host_doorbell);
}

static struct kobj_attribute raise_msi_attr =
	__ATTR(raise_msi, 0644, raise_msi_show, raise_msi_store);

/* ----- pci_epf_driver 回调 ---------------------------------------------- */

static int pcie_ep_demo_bind(struct pci_epf *epf)
{
	struct pcie_ep_demo *demo = epf_get_drvdata(epf);
	struct pci_epc *epc = epf->epc;
	struct device *dev = &epf->dev;
	int ret;

	if (WARN_ON_ONCE(!epc))
		return -EINVAL;

	/* 选择哪一根 BAR：尊重 EPC 控制器对 BAR 的固定要求 */
	demo->bar = EPC_FEATURE_GET_BAR(epc->features);

	/* 1) 把 VID/PID/Class 等写进 EP 的 PCIe 配置空间头 */
	ret = pci_epc_write_header(epc, epf->func_no, epf->header);
	if (ret) {
		dev_err(dev, "write_header failed: %d\n", ret);
		return ret;
	}

	/* 2) 申请一段内存并映射到 BAR 上，供 Host 通过 BAR 访问 */
	ret = pcie_ep_demo_alloc_and_set_bar(demo);
	if (ret)
		return ret;

	/* 3) 配置 MSI 中断个数（容量字段，host 协商时会读到） */
	ret = pci_epc_set_msi(epc, epf->func_no, epf->msi_interrupts);
	if (ret) {
		dev_err(dev, "set_msi failed: %d\n", ret);
		pcie_ep_demo_clear_bar(demo);
		return ret;
	}

	demo->bound = true;
	g_demo = demo;

	dev_info(dev, "bind ok: VID=0x%04x DID=0x%04x bar=BAR%d msi=%u\n",
		 epf->header->vendorid, epf->header->deviceid,
		 demo->bar, epf->msi_interrupts);
	return 0;
}

static void pcie_ep_demo_unbind(struct pci_epf *epf)
{
	struct pcie_ep_demo *demo = epf_get_drvdata(epf);
	struct pci_epc *epc = epf->epc;

	if (g_demo == demo)
		g_demo = NULL;

	demo->bound = false;
	pci_epc_stop(epc);
	pcie_ep_demo_clear_bar(demo);
}

static void pcie_ep_demo_linkup(struct pci_epf *epf)
{
	struct pcie_ep_demo *demo = epf_get_drvdata(epf);
	struct device *dev = &epf->dev;

	dev_info(dev, "PCIe link up, ready to serve host\n");

	/*
	 * 链路 UP 之后立刻给 Host 主动打一发 MSI，模拟 “EP 已就绪” 通知。
	 * 真实驱动通常不会一上来就发，这里只是为了让流程闭环、便于观察。
	 */
	if (demo && demo->bound)
		pcie_ep_demo_raise_msi(demo, 0);
}

/* ----- 注册 ------------------------------------------------------------- */

static const struct pci_epf_device_id pcie_ep_demo_ids[] = {
	{ .name = DRV_NAME },
	{ },
};

static int pcie_ep_demo_probe(struct pci_epf *epf)
{
	struct pcie_ep_demo *demo;
	struct device *dev = &epf->dev;

	demo = devm_kzalloc(dev, sizeof(*demo), GFP_KERNEL);
	if (!demo)
		return -ENOMEM;

	demo->epf = epf;
	demo->bar = BAR_0;	/* bind 时如果 EPC 有强制 BAR 还会被覆盖 */

	/*
	 * 让 framework 知道我们的 “出厂 VID/PID/Class”。
	 * 用户也可以在 configfs 里再写 vendorid/deviceid 把它覆盖掉，
	 * 这里给一个合法的默认值就行。
	 */
	epf->header = &demo_header;

	if (epf->msi_interrupts == 0)
		epf->msi_interrupts = DEMO_MSI_NR;

	epf_set_drvdata(epf, demo);
	dev_info(dev, "%s probed\n", DRV_NAME);
	return 0;
}

static struct pci_epf_ops pcie_ep_demo_ops = {
	.bind	= pcie_ep_demo_bind,
	.unbind	= pcie_ep_demo_unbind,
	.linkup	= pcie_ep_demo_linkup,
};

static struct pci_epf_driver pcie_ep_demo_driver = {
	.driver.name	= DRV_NAME,
	.probe		= pcie_ep_demo_probe,
	.id_table	= pcie_ep_demo_ids,
	.ops		= &pcie_ep_demo_ops,
	.owner		= THIS_MODULE,
};

static int __init pcie_ep_demo_init(void)
{
	int ret;

	ret = pci_epf_register_driver(&pcie_ep_demo_driver);
	if (ret) {
		pr_err("%s: register epf driver failed: %d\n", DRV_NAME, ret);
		return ret;
	}

	demo_kobj = kobject_create_and_add(DRV_NAME, kernel_kobj);
	if (!demo_kobj) {
		pci_epf_unregister_driver(&pcie_ep_demo_driver);
		return -ENOMEM;
	}
	ret = sysfs_create_file(demo_kobj, &raise_msi_attr.attr);
	if (ret) {
		kobject_put(demo_kobj);
		demo_kobj = NULL;
		pci_epf_unregister_driver(&pcie_ep_demo_driver);
		return ret;
	}

	pr_info("%s: loaded (default VID=0x%04x DID=0x%04x)\n",
		DRV_NAME, DEMO_VENDOR_ID, DEMO_DEVICE_ID);
	return 0;
}
module_init(pcie_ep_demo_init);

static void __exit pcie_ep_demo_exit(void)
{
	if (demo_kobj) {
		sysfs_remove_file(demo_kobj, &raise_msi_attr.attr);
		kobject_put(demo_kobj);
		demo_kobj = NULL;
	}
	pci_epf_unregister_driver(&pcie_ep_demo_driver);
	pr_info("%s: unloaded\n", DRV_NAME);
}
module_exit(pcie_ep_demo_exit);

MODULE_DESCRIPTION("Minimal PCIe Endpoint demo: VID/PID + BAR + MSI");
MODULE_AUTHOR("RLK lab");
MODULE_LICENSE("GPL v2");
