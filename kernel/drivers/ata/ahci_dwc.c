// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * DWC AHCI SATA Platform driver
 *
 * Copyright (C) 2021 BAIKAL ELECTRONICS, JSC
 */

#include <linux/ahci_platform.h>
#include <linux/bitfield.h>
#include <linux/bits.h>
#include <linux/clk.h>
#include <linux/device.h>
#include <linux/kernel.h>
#include <linux/libata.h>
#include <linux/log2.h>
#include <linux/mfd/syscon.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_device.h>
#include <linux/platform_device.h>
#include <linux/pm.h>
#include <linux/regmap.h>

#include "ahci.h"

/* Exported by drivers/misc/rk3576-usb-pcie-mux.c */
int rk3576_usb_pcie_mux_get_mode(struct device_node *np);

#define DRV_NAME "ahci-dwc"

#define AHCI_DWC_FBS_PMPN_MAX		15

/* DWC AHCI SATA controller specific registers */
#define AHCI_DWC_HOST_OOBR		0xbc
#define AHCI_DWC_HOST_OOB_WE		BIT(31)
#define AHCI_DWC_HOST_CWMIN_MASK	GENMASK(30, 24)
#define AHCI_DWC_HOST_CWMAX_MASK	GENMASK(23, 16)
#define AHCI_DWC_HOST_CIMIN_MASK	GENMASK(15, 8)
#define AHCI_DWC_HOST_CIMAX_MASK	GENMASK(7, 0)

#define AHCI_DWC_HOST_GPCR		0xd0
#define AHCI_DWC_HOST_GPSR		0xd4

#define AHCI_DWC_HOST_TIMER1MS		0xe0
#define AHCI_DWC_HOST_TIMV_MASK		GENMASK(19, 0)

#define AHCI_DWC_HOST_GPARAM1R		0xe8
#define AHCI_DWC_HOST_ALIGN_M		BIT(31)
#define AHCI_DWC_HOST_RX_BUFFER		BIT(30)
#define AHCI_DWC_HOST_PHY_DATA_MASK	GENMASK(29, 28)
#define AHCI_DWC_HOST_PHY_RST		BIT(27)
#define AHCI_DWC_HOST_PHY_CTRL_MASK	GENMASK(26, 21)
#define AHCI_DWC_HOST_PHY_STAT_MASK	GENMASK(20, 15)
#define AHCI_DWC_HOST_LATCH_M		BIT(14)
#define AHCI_DWC_HOST_PHY_TYPE_MASK	GENMASK(13, 11)
#define AHCI_DWC_HOST_RET_ERR		BIT(10)
#define AHCI_DWC_HOST_AHB_ENDIAN_MASK	GENMASK(9, 8)
#define AHCI_DWC_HOST_S_HADDR		BIT(7)
#define AHCI_DWC_HOST_M_HADDR		BIT(6)
#define AHCI_DWC_HOST_S_HDATA_MASK	GENMASK(5, 3)
#define AHCI_DWC_HOST_M_HDATA_MASK	GENMASK(2, 0)

#define AHCI_DWC_HOST_GPARAM2R		0xec
#define AHCI_DWC_HOST_FBS_MEM_S		BIT(19)
#define AHCI_DWC_HOST_FBS_PMPN_MASK	GENMASK(17, 16)
#define AHCI_DWC_HOST_FBS_SUP		BIT(15)
#define AHCI_DWC_HOST_DEV_CP		BIT(14)
#define AHCI_DWC_HOST_DEV_MP		BIT(13)
#define AHCI_DWC_HOST_ENCODE_M		BIT(12)
#define AHCI_DWC_HOST_RXOOB_CLK_M	BIT(11)
#define AHCI_DWC_HOST_RXOOB_M		BIT(10)
#define AHCI_DWC_HOST_TXOOB_M		BIT(9)
#define AHCI_DWC_HOST_RXOOB_M		BIT(10)
#define AHCI_DWC_HOST_RXOOB_CLK_MASK	GENMASK(8, 0)

#define AHCI_DWC_HOST_PPARAMR		0xf0
#define AHCI_DWC_HOST_TX_MEM_M		BIT(11)
#define AHCI_DWC_HOST_TX_MEM_S		BIT(10)
#define AHCI_DWC_HOST_RX_MEM_M		BIT(9)
#define AHCI_DWC_HOST_RX_MEM_S		BIT(8)
#define AHCI_DWC_HOST_TXFIFO_DEPTH	GENMASK(7, 4)
#define AHCI_DWC_HOST_RXFIFO_DEPTH	GENMASK(3, 0)

#define AHCI_DWC_HOST_TESTR		0xf4
#define AHCI_DWC_HOST_PSEL_MASK		GENMASK(18, 16)
#define AHCI_DWC_HOST_TEST_IF		BIT(0)

#define AHCI_DWC_HOST_VERSIONR		0xf8
#define AHCI_DWC_HOST_IDR		0xfc

#define AHCI_DWC_PORT_DMACR		0x70
#define AHCI_DWC_PORT_RXABL_MASK	GENMASK(15, 12)
#define AHCI_DWC_PORT_TXABL_MASK	GENMASK(11, 8)
#define AHCI_DWC_PORT_RXTS_MASK		GENMASK(7, 4)
#define AHCI_DWC_PORT_TXTS_MASK		GENMASK(3, 0)
#define AHCI_DWC_PORT_PHYCR		0x74
#define AHCI_DWC_PORT_PHYSR		0x78

/* Baikal-T1 AHCI SATA specific registers */
#define AHCI_BT1_HOST_PHYCR		AHCI_DWC_HOST_GPCR
#define AHCI_BT1_HOST_MPLM_MASK		GENMASK(29, 23)
#define AHCI_BT1_HOST_LOSDT_MASK	GENMASK(22, 20)
#define AHCI_BT1_HOST_CRR		BIT(19)
#define AHCI_BT1_HOST_CRW		BIT(18)
#define AHCI_BT1_HOST_CRCD		BIT(17)
#define AHCI_BT1_HOST_CRCA		BIT(16)
#define AHCI_BT1_HOST_CRDI_MASK		GENMASK(15, 0)

#define AHCI_BT1_HOST_PHYSR		AHCI_DWC_HOST_GPSR
#define AHCI_BT1_HOST_CRA		BIT(16)
#define AHCI_BT1_HOST_CRDO_MASK		GENMASK(15, 0)

struct ahci_dwc_plat_data {
	unsigned int pflags;
	unsigned int hflags;
	int (*init)(struct ahci_host_priv *hpriv);
	int (*reinit)(struct ahci_host_priv *hpriv);
	void (*clear)(struct ahci_host_priv *hpriv);
};

struct ahci_dwc_host_priv {
	const struct ahci_dwc_plat_data *pdata;
	struct platform_device *pdev;

	u32 timv;
	u32 dmacr[AHCI_MAX_PORTS];
};

static int ahci_bt1_init(struct ahci_host_priv *hpriv)
{
	struct ahci_dwc_host_priv *dpriv = hpriv->plat_data;
	int ret;

	/* APB, application and reference clocks are required */
	if (!ahci_platform_find_clk(hpriv, "pclk") ||
	    !ahci_platform_find_clk(hpriv, "aclk") ||
	    !ahci_platform_find_clk(hpriv, "ref")) {
		dev_err(&dpriv->pdev->dev, "No system clocks specified\n");
		return -EINVAL;
	}

	/*
	 * Fully reset the SATA AXI and ref clocks domain to ensure the state
	 * machine is working from scratch especially if the reference clocks
	 * source has been changed.
	 */
	ret = ahci_platform_assert_rsts(hpriv);
	if (ret) {
		dev_err(&dpriv->pdev->dev, "Couldn't assert the resets\n");
		return ret;
	}

	ret = ahci_platform_deassert_rsts(hpriv);
	if (ret) {
		dev_err(&dpriv->pdev->dev, "Couldn't de-assert the resets\n");
		return ret;
	}

	return 0;
}

/*
 * ahci_dwc_stop_engine - 停 DMA 引擎的适配版
 *
 * 默认的 ahci_stop_engine() 会写 PORT_CMD 清除 PORT_CMD_START 后等待
 * PORT_CMD_LIST_ON 清零（最长 500ms）。实测在 SATA0/PCIE0 热切换场景下，
 * 盘状态异常时对 AHCI 控制器 PORT_CMD 的 MMIO 读会触发总线 stall，
 * CPU 卡死在 readl 屏障（RCU stall, queued_spin_lock_slowpath）。
 *
 * 热切换本来就要整体释放/复位 PHY 和控制器，因此这里不做任何
 * AHCI MMIO 访问，直接返回成功，由后续的 host shutdown 完成清理。
 */
static int ahci_dwc_stop_engine(struct ata_port *ap)
{
	return 0;
}

static struct ahci_host_priv *ahci_dwc_get_resources(struct platform_device *pdev)
{
	struct ahci_dwc_host_priv *dpriv;
	struct ahci_host_priv *hpriv;

	dpriv = devm_kzalloc(&pdev->dev, sizeof(*dpriv), GFP_KERNEL);
	if (!dpriv)
		return ERR_PTR(-ENOMEM);

	dpriv->pdev = pdev;
	dpriv->pdata = device_get_match_data(&pdev->dev);
	if (!dpriv->pdata)
		return ERR_PTR(-EINVAL);

	hpriv = ahci_platform_get_resources(pdev, dpriv->pdata->pflags);
	if (IS_ERR(hpriv))
		return hpriv;

	hpriv->flags |= dpriv->pdata->hflags;
	hpriv->plat_data = (void *)dpriv;

	/*
	 * SATA0/PCIE0 热切换：默认 ahci_stop_engine() 在链路断开/盘下线
	 * 时会卡死在等待 PORT_CMD_LIST_ON 清零（RT 内核自旋锁死锁），
	 * 换成不等待 DMA 停止的适配版。
	 */
	hpriv->stop_engine = ahci_dwc_stop_engine;

	return hpriv;
}

static void ahci_dwc_check_cap(struct ahci_host_priv *hpriv)
{
	unsigned long port_map = hpriv->saved_port_map | hpriv->mask_port_map;
	struct ahci_dwc_host_priv *dpriv = hpriv->plat_data;
	bool dev_mp, dev_cp, fbs_sup;
	unsigned int fbs_pmp;
	u32 param;
	int i;

	param = readl(hpriv->mmio + AHCI_DWC_HOST_GPARAM2R);
	dev_mp = !!(param & AHCI_DWC_HOST_DEV_MP);
	dev_cp = !!(param & AHCI_DWC_HOST_DEV_CP);
	fbs_sup = !!(param & AHCI_DWC_HOST_FBS_SUP);
	fbs_pmp = 5 * FIELD_GET(AHCI_DWC_HOST_FBS_PMPN_MASK, param);

	if (!dev_mp && hpriv->saved_cap & HOST_CAP_MPS) {
		dev_warn(&dpriv->pdev->dev, "MPS is unsupported\n");
		hpriv->saved_cap &= ~HOST_CAP_MPS;
	}


	if (fbs_sup && fbs_pmp < AHCI_DWC_FBS_PMPN_MAX) {
		dev_warn(&dpriv->pdev->dev, "PMPn is limited up to %u ports\n",
			 fbs_pmp);
	}

	for_each_set_bit(i, &port_map, AHCI_MAX_PORTS) {
		if (!dev_mp && hpriv->saved_port_cap[i] & PORT_CMD_MPSP) {
			dev_warn(&dpriv->pdev->dev, "MPS incapable port %d\n", i);
			hpriv->saved_port_cap[i] &= ~PORT_CMD_MPSP;
		}

		if (!dev_cp && hpriv->saved_port_cap[i] & PORT_CMD_CPD) {
			dev_warn(&dpriv->pdev->dev, "CPD incapable port %d\n", i);
			hpriv->saved_port_cap[i] &= ~PORT_CMD_CPD;
		}

		if (!fbs_sup && hpriv->saved_port_cap[i] & PORT_CMD_FBSCP) {
			dev_warn(&dpriv->pdev->dev, "FBS incapable port %d\n", i);
			hpriv->saved_port_cap[i] &= ~PORT_CMD_FBSCP;
		}
	}
}

static void ahci_dwc_init_timer(struct ahci_host_priv *hpriv)
{
	struct ahci_dwc_host_priv *dpriv = hpriv->plat_data;
	unsigned long rate;
	struct clk *aclk;
	u32 cap, cap2;

	/* 1ms tick is generated only for the CCC or DevSleep features */
	cap = readl(hpriv->mmio + HOST_CAP);
	cap2 = readl(hpriv->mmio + HOST_CAP2);
	if (!(cap & HOST_CAP_CCC) && !(cap2 & HOST_CAP2_SDS))
		return;

	/*
	 * Tick is generated based on the AXI/AHB application clocks signal
	 * so we need to be sure in the clock we are going to use.
	 */
	aclk = ahci_platform_find_clk(hpriv, "aclk");
	if (!aclk)
		return;

	/* 1ms timer interval is set as TIMV = AMBA_FREQ[MHZ] * 1000 */
	dpriv->timv = readl(hpriv->mmio + AHCI_DWC_HOST_TIMER1MS);
	dpriv->timv = FIELD_GET(AHCI_DWC_HOST_TIMV_MASK, dpriv->timv);
	rate = clk_get_rate(aclk) / 1000UL;
	if (rate == dpriv->timv)
		return;

	dev_info(&dpriv->pdev->dev, "Update CCC/DevSlp timer for Fapp %lu MHz\n",
		 rate / 1000UL);
	dpriv->timv = FIELD_PREP(AHCI_DWC_HOST_TIMV_MASK, rate);
	writel(dpriv->timv, hpriv->mmio + AHCI_DWC_HOST_TIMER1MS);
}

static int ahci_dwc_init_dmacr(struct ahci_host_priv *hpriv)
{
	struct ahci_dwc_host_priv *dpriv = hpriv->plat_data;
	struct device_node *child;
	void __iomem *port_mmio;
	u32 port, dmacr, ts;

	/*
	 * Update the DMA Tx/Rx transaction sizes in accordance with the
	 * platform setup. Note values exceeding maximal or minimal limits will
	 * be automatically clamped. Also note the register isn't affected by
	 * the HBA global reset so we can freely initialize it once until the
	 * next system reset.
	 */
	for_each_child_of_node(dpriv->pdev->dev.of_node, child) {
		if (!of_device_is_available(child))
			continue;

		if (of_property_read_u32(child, "reg", &port)) {
			of_node_put(child);
			return -EINVAL;
		}

		port_mmio = __ahci_port_base(hpriv, port);
		dmacr = readl(port_mmio + AHCI_DWC_PORT_DMACR);

		if (!of_property_read_u32(child, "snps,tx-ts-max", &ts)) {
			ts = ilog2(ts);
			dmacr &= ~AHCI_DWC_PORT_TXTS_MASK;
			dmacr |= FIELD_PREP(AHCI_DWC_PORT_TXTS_MASK, ts);
		}

		if (!of_property_read_u32(child, "snps,rx-ts-max", &ts)) {
			ts = ilog2(ts);
			dmacr &= ~AHCI_DWC_PORT_RXTS_MASK;
			dmacr |= FIELD_PREP(AHCI_DWC_PORT_RXTS_MASK, ts);
		}

		writel(dmacr, port_mmio + AHCI_DWC_PORT_DMACR);
		dpriv->dmacr[port] = dmacr;
	}

	return 0;
}

static int ahci_dwc_init_host(struct ahci_host_priv *hpriv)
{
	struct ahci_dwc_host_priv *dpriv = hpriv->plat_data;
	int rc;

	rc = ahci_platform_enable_resources(hpriv);
	if (rc)
		return rc;

	if (dpriv->pdata->init) {
		rc = dpriv->pdata->init(hpriv);
		if (rc)
			goto err_disable_resources;
	}

	ahci_dwc_check_cap(hpriv);

	ahci_dwc_init_timer(hpriv);

	rc = ahci_dwc_init_dmacr(hpriv);
	if (rc)
		goto err_clear_platform;

	return 0;

err_clear_platform:
	if (dpriv->pdata->clear)
		dpriv->pdata->clear(hpriv);

err_disable_resources:
	ahci_platform_disable_resources(hpriv);

	return rc;
}

static int ahci_dwc_reinit_host(struct ahci_host_priv *hpriv)
{
	struct ahci_dwc_host_priv *dpriv = hpriv->plat_data;
	unsigned long port_map = hpriv->port_map;
	void __iomem *port_mmio;
	int i, rc;

	rc = ahci_platform_enable_resources(hpriv);
	if (rc)
		return rc;

	if (dpriv->pdata->reinit) {
		rc = dpriv->pdata->reinit(hpriv);
		if (rc)
			goto err_disable_resources;
	}

	writel(dpriv->timv, hpriv->mmio + AHCI_DWC_HOST_TIMER1MS);

	for_each_set_bit(i, &port_map, AHCI_MAX_PORTS) {
		port_mmio = __ahci_port_base(hpriv, i);
		writel(dpriv->dmacr[i], port_mmio + AHCI_DWC_PORT_DMACR);
	}

	return 0;

err_disable_resources:
	ahci_platform_disable_resources(hpriv);

	return rc;
}

static void ahci_dwc_clear_host(struct ahci_host_priv *hpriv)
{
	struct ahci_dwc_host_priv *dpriv = hpriv->plat_data;

	if (dpriv->pdata->clear)
		dpriv->pdata->clear(hpriv);

	ahci_platform_disable_resources(hpriv);
}

static void ahci_dwc_stop_host(struct ata_host *host)
{
	struct ahci_host_priv *hpriv = host->private_data;

	ahci_dwc_clear_host(hpriv);
}

/*
 * ahci_dwc_port_stop - 热切换安全的端口停止
 *
 * 默认 ahci_port_stop() 在 ahci_deinit_port() 之后还会做
 * pm_runtime_put(ap->dev)，在 PREEMPT_RT 内核 + 热切换场景下
 * 会触发 runtime suspend（ahci_dwc_suspend → ahci_dwc_clear_host），
 * 与正在进行的 unbind（devres 释放）锁竞争死锁。
 * 这里不做任何 AHCI MMIO 访问（盘状态异常时读会总线挂死），
 * 也不做 pm_runtime，直接返回，由 host_stop 完成资源清理。
 */
static void ahci_dwc_port_stop(struct ata_port *ap)
{
}

static struct ata_port_operations ahci_dwc_port_ops = {
	.inherits	= &ahci_platform_ops,
	.port_stop	= ahci_dwc_port_stop,
	.host_stop	= ahci_dwc_stop_host,
};

static const struct ata_port_info ahci_dwc_port_info = {
	.flags		= AHCI_FLAG_COMMON,
	.pio_mask	= ATA_PIO4,
	.udma_mask	= ATA_UDMA6,
	.port_ops	= &ahci_dwc_port_ops,
};

static struct scsi_host_template ahci_dwc_scsi_info = {
	AHCI_SHT(DRV_NAME),
};

static int ahci_dwc_probe(struct platform_device *pdev)
{
	struct ahci_host_priv *hpriv;
	struct device_node *mux_np;
	int rc, mux_val;

	/*
	 * MUX gating (SATA0/PCIE0 shared combphy0_ps):
	 *  - sata-pcie-mux: low = PCIE, high = SATA
	 *  - skip probe when the mux is not routed to SATA (mode "pcie")
	 *
	 * We query the mux driver's software mode instead of requesting the
	 * mux GPIO directly: NONEXCLUSIVE gpiod consumers would kill the
	 * mux driver's GPIO request on unbind (via devm), breaking later
	 * re-probe.
	 */
	mux_val = -ENODEV;
	mux_np = of_parse_phandle(pdev->dev.of_node, "rockchip,mux-node", 0);
	if (mux_np) {
		mux_val = rk3576_usb_pcie_mux_get_mode(mux_np);
		of_node_put(mux_np);
		if (mux_val < 0)
			return dev_err_probe(&pdev->dev, mux_val,
					     "SATA/PCIE mux is not ready\n");
	}
	if (mux_val == 0) {
		dev_info(&pdev->dev, "skip probe: SATA/PCIE mux is in PCIE mode\n");
		return -ENODEV;
	}

	hpriv = ahci_dwc_get_resources(pdev);
	if (IS_ERR(hpriv))
		return PTR_ERR(hpriv);

	rc = ahci_dwc_init_host(hpriv);
	if (rc)
		return rc;

	rc = ahci_platform_init_host(pdev, hpriv, &ahci_dwc_port_info,
				     &ahci_dwc_scsi_info);
	if (rc)
		goto err_clear_host;

	return 0;

err_clear_host:
	ahci_dwc_clear_host(hpriv);

	return rc;
}

static int ahci_dwc_suspend(struct device *dev)
{
	struct ata_host *host = dev_get_drvdata(dev);
	struct ahci_host_priv *hpriv = host->private_data;
	int rc;

	rc = ahci_platform_suspend_host(dev);
	if (rc)
		return rc;

	ahci_dwc_clear_host(hpriv);

	return 0;
}

static int ahci_dwc_resume(struct device *dev)
{
	struct ata_host *host = dev_get_drvdata(dev);
	struct ahci_host_priv *hpriv = host->private_data;
	int rc;

	rc = ahci_dwc_reinit_host(hpriv);
	if (rc)
		return rc;

	return ahci_platform_resume_host(dev);
}

static DEFINE_SIMPLE_DEV_PM_OPS(ahci_dwc_pm_ops, ahci_dwc_suspend,
				ahci_dwc_resume);

static struct ahci_dwc_plat_data ahci_dwc_plat = {
	.pflags = AHCI_PLATFORM_GET_RESETS,
};

static struct ahci_dwc_plat_data ahci_bt1_plat = {
	.pflags = AHCI_PLATFORM_GET_RESETS | AHCI_PLATFORM_RST_TRIGGER,
	.init = ahci_bt1_init,
};

static const struct of_device_id ahci_dwc_of_match[] = {
	{ .compatible = "snps,dwc-ahci", &ahci_dwc_plat },
	{ .compatible = "snps,spear-ahci", &ahci_dwc_plat },
	{ .compatible = "baikal,bt1-ahci", &ahci_bt1_plat },
	{},
};
MODULE_DEVICE_TABLE(of, ahci_dwc_of_match);

static struct platform_driver ahci_dwc_driver = {
	.probe = ahci_dwc_probe,
	.remove = ata_platform_remove_one,
	.shutdown = ahci_platform_shutdown,
	.driver = {
		.name = DRV_NAME,
		.of_match_table = ahci_dwc_of_match,
		.pm = &ahci_dwc_pm_ops,
	},
};
module_platform_driver(ahci_dwc_driver);

MODULE_DESCRIPTION("DWC AHCI SATA platform driver");
MODULE_AUTHOR("Serge Semin <Sergey.Semin@baikalelectronics.ru>");
MODULE_LICENSE("GPL");
