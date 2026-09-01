// SPDX-License-Identifier: GPL-2.0
/*
 * pci_dev_demo.c - 一个典型的 PCI 设备驱动样板（Host/RC 侧）
 *
 * 它演示了一个 Linux PCI 驱动里"该做的事"基本都做一遍：
 *   1. 用 id_table 描述自己关心哪些 VID/PID, 注册到 PCI 总线
 *   2. probe 时:
 *        pci_enable_device           上电
 *        pci_request_regions         占用 BAR 资源
 *        pci_set_master              使能 bus master (做 DMA 用)
 *        pci_iomap(BAR0)             把 BAR0 ioremap 进内核虚地址
 *        dma_set_mask_and_coherent   声明可寻址范围
 *        pci_alloc_irq_vectors       申请 MSI 中断向量
 *        request_irq                 注册中断处理函数
 *        dma_alloc_coherent          申请一段一致 DMA 缓冲, 给设备用
 *        misc_register               暴露 /dev/pci_dev_demo 给用户态
 *   3. 中断处理: 唤醒等待队列, 计数, 让用户态 read() 能拿到事件
 *   4. 用户态接口（misc 字符设备）:
 *        read    : 阻塞等待 MSI, 返回累计触发次数
 *        write   : 把一个 32bit 值写到 BAR0+0x04 (作为 EP 的 doorbell)
 *        ioctl   : 读 BAR0+0x00 的 magic
 *   5. remove 时反向清理
 *
 * 默认匹配 VID=0x104c DID=0xb500, 与 lab6_pcie_ep_demo 里 EP 端默认值
 * 一致, 在带 EPC 硬件的平台上两侧能对上。如果你要驱动其他 PCI 设备,
 * 改 id_table 即可。
 */

#include <linux/cdev.h>
#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/pci.h>
#include <linux/poll.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/wait.h>

#define DRV_NAME		"pci_dev_demo"

/* 与 lab6 里 EP demo 的默认 VID/PID 保持一致 */
#define DEMO_VENDOR_ID		0x104c
#define DEMO_DEVICE_ID		0xb500

/* BAR0 上的几个寄存器（与 EP 端 struct pcie_ep_demo_reg 对齐） */
#define REG_MAGIC		0x00	/* RO, EP 写一个 magic 进来 */
#define REG_HOST_DOORBELL	0x04	/* WO, host 写这里通知 EP */
#define REG_EP_STATUS		0x08	/* RO */
#define REG_IRQ_COUNT		0x0c	/* RO, EP 已经发过的 MSI 次数 */

#define DEMO_DMA_BUF_SIZE	(64 * 1024)

/* 自定义 ioctl */
#define DEMO_IOC_MAGIC		'D'
#define DEMO_IOC_GET_MAGIC	_IOR(DEMO_IOC_MAGIC, 0, __u32)
#define DEMO_IOC_GET_DMA_PA	_IOR(DEMO_IOC_MAGIC, 1, __u64)

struct pci_dev_demo {
	struct pci_dev		*pdev;
	void __iomem		*bar0;
	resource_size_t		bar0_phys;
	resource_size_t		bar0_len;

	/* MSI */
	int			irq;	/* virq */
	atomic_t		irq_count;
	wait_queue_head_t	wq;

	/* DMA buffer (设备可访问) */
	void			*dma_va;
	dma_addr_t		dma_pa;
	size_t			dma_size;

	struct miscdevice	miscdev;
	struct mutex		lock;

	/* user-side read 端的"已读到的中断序号"，用来判断是否有新事件 */
};

/* 因为 misc 设备 file->private_data 默认放 miscdev，自己塞一下方便 */
static inline struct pci_dev_demo *file_to_demo(struct file *f)
{
	return container_of(f->private_data, struct pci_dev_demo, miscdev);
}

/* ----- 中断处理 -------------------------------------------------------- */

static irqreturn_t demo_msi_handler(int irq, void *data)
{
	struct pci_dev_demo *demo = data;
	u32 ep_irq_cnt;

	/*
	 * 真实驱动会读设备中断状态寄存器决定是不是自己, 这里 BAR0+0x0c
	 * 是 EP 端累积已经发过的中断次数, 仅作演示。
	 */
	ep_irq_cnt = ioread32(demo->bar0 + REG_IRQ_COUNT);

	atomic_inc(&demo->irq_count);
	wake_up_interruptible(&demo->wq);

	dev_info(&demo->pdev->dev,
		 "MSI fired (host_count=%d, ep_count=%u)\n",
		 atomic_read(&demo->irq_count), ep_irq_cnt);

	return IRQ_HANDLED;
}

/* ----- file_operations: 给用户态一个可玩的字符设备 --------------------- */

static ssize_t demo_read(struct file *file, char __user *ubuf,
			 size_t len, loff_t *ppos)
{
	struct pci_dev_demo *demo = file_to_demo(file);
	int count;
	char tmp[64];
	int n;

	if (file->f_flags & O_NONBLOCK) {
		if (atomic_read(&demo->irq_count) == 0)
			return -EAGAIN;
	} else {
		if (wait_event_interruptible(demo->wq,
					     atomic_read(&demo->irq_count) > 0))
			return -ERESTARTSYS;
	}

	count = atomic_xchg(&demo->irq_count, 0);
	n = scnprintf(tmp, sizeof(tmp), "irq=%d\n", count);
	if (len < n)
		n = len;
	if (copy_to_user(ubuf, tmp, n))
		return -EFAULT;
	return n;
}

static ssize_t demo_write(struct file *file, const char __user *ubuf,
			  size_t len, loff_t *ppos)
{
	struct pci_dev_demo *demo = file_to_demo(file);
	char tmp[16] = {};
	u32 val;
	int ret;

	if (len == 0 || len >= sizeof(tmp))
		return -EINVAL;
	if (copy_from_user(tmp, ubuf, len))
		return -EFAULT;

	ret = kstrtou32(tmp, 0, &val);
	if (ret)
		return ret;

	iowrite32(val, demo->bar0 + REG_HOST_DOORBELL);
	dev_info(&demo->pdev->dev, "host doorbell <- 0x%08x\n", val);
	return len;
}

static __poll_t demo_poll(struct file *file, poll_table *wait)
{
	struct pci_dev_demo *demo = file_to_demo(file);
	__poll_t mask = 0;

	poll_wait(file, &demo->wq, wait);
	if (atomic_read(&demo->irq_count) > 0)
		mask |= EPOLLIN | EPOLLRDNORM;
	return mask;
}

static long demo_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
	struct pci_dev_demo *demo = file_to_demo(file);

	switch (cmd) {
	case DEMO_IOC_GET_MAGIC: {
		u32 magic = ioread32(demo->bar0 + REG_MAGIC);

		if (copy_to_user((void __user *)arg, &magic, sizeof(magic)))
			return -EFAULT;
		return 0;
	}
	case DEMO_IOC_GET_DMA_PA: {
		u64 pa = (u64)demo->dma_pa;

		if (copy_to_user((void __user *)arg, &pa, sizeof(pa)))
			return -EFAULT;
		return 0;
	}
	default:
		return -ENOTTY;
	}
}

static const struct file_operations demo_fops = {
	.owner		= THIS_MODULE,
	.read		= demo_read,
	.write		= demo_write,
	.poll		= demo_poll,
	.unlocked_ioctl	= demo_ioctl,
	.llseek		= no_llseek,
};

/* ----- probe / remove --------------------------------------------------- */

static int demo_setup_bar(struct pci_dev_demo *demo)
{
	struct pci_dev *pdev = demo->pdev;
	int ret;

	ret = pci_request_regions(pdev, DRV_NAME);
	if (ret) {
		dev_err(&pdev->dev, "request regions failed: %d\n", ret);
		return ret;
	}

	demo->bar0_phys = pci_resource_start(pdev, 0);
	demo->bar0_len  = pci_resource_len(pdev, 0);

	demo->bar0 = pci_iomap(pdev, 0, 0);
	if (!demo->bar0) {
		dev_err(&pdev->dev, "ioremap BAR0 failed\n");
		pci_release_regions(pdev);
		return -ENOMEM;
	}

	dev_info(&pdev->dev,
		 "BAR0: phys=0x%llx len=0x%llx -> %p (magic=0x%08x)\n",
		 (u64)demo->bar0_phys, (u64)demo->bar0_len, demo->bar0,
		 ioread32(demo->bar0 + REG_MAGIC));
	return 0;
}

static void demo_cleanup_bar(struct pci_dev_demo *demo)
{
	if (demo->bar0)
		pci_iounmap(demo->pdev, demo->bar0);
	pci_release_regions(demo->pdev);
}

static int demo_setup_msi(struct pci_dev_demo *demo)
{
	struct pci_dev *pdev = demo->pdev;
	int nvec;
	int ret;

	nvec = pci_alloc_irq_vectors(pdev, 1, 1, PCI_IRQ_MSI);
	if (nvec < 0) {
		dev_err(&pdev->dev, "alloc MSI failed: %d\n", nvec);
		return nvec;
	}

	demo->irq = pci_irq_vector(pdev, 0);
	ret = request_irq(demo->irq, demo_msi_handler, 0, DRV_NAME, demo);
	if (ret) {
		dev_err(&pdev->dev, "request_irq(%d) failed: %d\n",
			demo->irq, ret);
		pci_free_irq_vectors(pdev);
		return ret;
	}
	dev_info(&pdev->dev, "MSI ok, virq=%d\n", demo->irq);
	return 0;
}

static void demo_cleanup_msi(struct pci_dev_demo *demo)
{
	if (demo->irq) {
		free_irq(demo->irq, demo);
		demo->irq = 0;
	}
	pci_free_irq_vectors(demo->pdev);
}

static int demo_setup_dma(struct pci_dev_demo *demo)
{
	struct pci_dev *pdev = demo->pdev;
	int ret;

	/*
	 * 先尝试 64-bit, 不行再退回 32-bit, 这是 PCI 驱动的标准做法。
	 */
	ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(64));
	if (ret) {
		ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(32));
		if (ret) {
			dev_err(&pdev->dev, "no suitable DMA mask\n");
			return ret;
		}
		dev_info(&pdev->dev, "using 32-bit DMA mask\n");
	}

	demo->dma_size = DEMO_DMA_BUF_SIZE;
	demo->dma_va = dma_alloc_coherent(&pdev->dev, demo->dma_size,
					  &demo->dma_pa, GFP_KERNEL);
	if (!demo->dma_va) {
		dev_err(&pdev->dev, "dma_alloc_coherent failed\n");
		return -ENOMEM;
	}

	dev_info(&pdev->dev, "DMA buf: va=%p pa=0x%llx size=%zu\n",
		 demo->dma_va, (u64)demo->dma_pa, demo->dma_size);
	return 0;
}

static void demo_cleanup_dma(struct pci_dev_demo *demo)
{
	if (demo->dma_va) {
		dma_free_coherent(&demo->pdev->dev, demo->dma_size,
				  demo->dma_va, demo->dma_pa);
		demo->dma_va = NULL;
	}
}

static int demo_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
	struct pci_dev_demo *demo;
	int ret;

	dev_info(&pdev->dev, "probe %04x:%04x (rev %02x)\n",
		 pdev->vendor, pdev->device, pdev->revision);

	demo = devm_kzalloc(&pdev->dev, sizeof(*demo), GFP_KERNEL);
	if (!demo)
		return -ENOMEM;

	demo->pdev = pdev;
	mutex_init(&demo->lock);
	atomic_set(&demo->irq_count, 0);
	init_waitqueue_head(&demo->wq);
	pci_set_drvdata(pdev, demo);

	ret = pci_enable_device(pdev);
	if (ret) {
		dev_err(&pdev->dev, "enable failed: %d\n", ret);
		return ret;
	}

	ret = demo_setup_bar(demo);
	if (ret)
		goto err_disable;

	pci_set_master(pdev);

	ret = demo_setup_dma(demo);
	if (ret)
		goto err_clear_master;

	ret = demo_setup_msi(demo);
	if (ret)
		goto err_dma;

	demo->miscdev.minor = MISC_DYNAMIC_MINOR;
	demo->miscdev.name  = DRV_NAME;
	demo->miscdev.fops  = &demo_fops;
	ret = misc_register(&demo->miscdev);
	if (ret) {
		dev_err(&pdev->dev, "misc_register failed: %d\n", ret);
		goto err_msi;
	}

	dev_info(&pdev->dev, "ready, /dev/%s\n", DRV_NAME);
	return 0;

err_msi:
	demo_cleanup_msi(demo);
err_dma:
	demo_cleanup_dma(demo);
err_clear_master:
	pci_clear_master(pdev);
	demo_cleanup_bar(demo);
err_disable:
	pci_disable_device(pdev);
	return ret;
}

static void demo_remove(struct pci_dev *pdev)
{
	struct pci_dev_demo *demo = pci_get_drvdata(pdev);

	if (!demo)
		return;

	misc_deregister(&demo->miscdev);
	demo_cleanup_msi(demo);
	demo_cleanup_dma(demo);
	pci_clear_master(pdev);
	demo_cleanup_bar(demo);
	pci_disable_device(pdev);

	dev_info(&pdev->dev, "removed\n");
}

/* ----- suspend / resume （可选, 这里给一对最简实现） ------------------- */

static int __maybe_unused demo_suspend(struct device *dev)
{
	struct pci_dev *pdev = to_pci_dev(dev);

	dev_info(dev, "suspend\n");
	pci_save_state(pdev);
	pci_disable_device(pdev);
	pci_set_power_state(pdev, PCI_D3hot);
	return 0;
}

static int __maybe_unused demo_resume(struct device *dev)
{
	struct pci_dev *pdev = to_pci_dev(dev);
	int ret;

	dev_info(dev, "resume\n");
	pci_set_power_state(pdev, PCI_D0);
	pci_restore_state(pdev);
	ret = pci_enable_device(pdev);
	if (ret)
		return ret;
	pci_set_master(pdev);
	return 0;
}

static SIMPLE_DEV_PM_OPS(demo_pm_ops, demo_suspend, demo_resume);

/* ----- ID 表 + driver 注册 --------------------------------------------- */

static const struct pci_device_id demo_id_table[] = {
	{ PCI_DEVICE(DEMO_VENDOR_ID, DEMO_DEVICE_ID) },
	{ }
};
MODULE_DEVICE_TABLE(pci, demo_id_table);

static struct pci_driver demo_driver = {
	.name		= DRV_NAME,
	.id_table	= demo_id_table,
	.probe		= demo_probe,
	.remove		= demo_remove,
	.driver.pm	= &demo_pm_ops,
};

module_pci_driver(demo_driver);

MODULE_DESCRIPTION("A typical PCI device driver template (BAR + MSI + DMA)");
MODULE_AUTHOR("RLK lab");
MODULE_LICENSE("GPL v2");
