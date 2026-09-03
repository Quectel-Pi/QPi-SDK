#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/init.h>
#include <linux/device.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/types.h>
#include <linux/slab.h>
#include <asm/uaccess.h>
#include <linux/version.h>
#include <linux/fs.h>
#include <linux/log2.h>
#define QDEVINFO_CMD
#ifdef QDEVINFO_CMD

#define EMMC_NAME_STR_LEN   32
#define DDR_STR_LEN         64
#define EXT_CSD_STR_LEN     1025
#define MMC_NAME            "/sys/class/mmc_host/mmc0/mmc0:0001/name"
#define MMC_EXT_CSD         "/sys/kernel/debug/mmc0/mmc0:0001/ext_csd"
#define MEMINFO             "/proc/meminfo"

/* read file */
/* read file */
/* read file */

static u32 round_to_nearest_pow2(u32 val)
{
    u32 lower, upper;

    if (val < 2)
        return 1;

    lower = 1U << ilog2(val);   /* largest 2^n <= val */
    upper = lower << 1;         /* smallest 2^n >= val */

    if ((val - lower) < (upper - val))
        return lower;
    else
        return upper;
}
int get_buf(const char *filename, char *buf, int size)
{
    int length;
    struct file *fp;
    loff_t pos;

    fp = filp_open(filename, O_RDONLY, 0);
    if (IS_ERR(fp)) {
        printk(KERN_ERR "open file error: %s\n", filename);
        return -1;
    }

    pos = 0;
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)
    length = kernel_read(fp, buf, size, &pos);
#else
    {
        mm_segment_t fs;
        fs = get_fs();
        set_fs(KERNEL_DS);
        length = vfs_read(fp, buf, size, &pos);
        set_fs(fs);
    }
#endif
    filp_close(fp, NULL);

    return length;
}

static int emmc_ext_csd_proc_show(struct seq_file *m, void *v)
{
    char *kbuf;

    kbuf = kmalloc(EXT_CSD_STR_LEN + 1, GFP_KERNEL);
    memset(kbuf, 0, EXT_CSD_STR_LEN + 1);
    get_buf(MMC_EXT_CSD, kbuf, EXT_CSD_STR_LEN);
    seq_printf(m, "%s", kbuf);
    kfree(kbuf);

    return 0;
}

static int emmc_ext_csd_proc_open(struct inode *inode, struct file *filp)
{
    return single_open(filp, emmc_ext_csd_proc_show, inode->i_private);
}

static const struct proc_ops emmc_ext_csd_proc_fops = {
    .proc_open       = emmc_ext_csd_proc_open,
    .proc_read       = seq_read,
    .proc_lseek     = seq_lseek,
    .proc_release    = single_release,
};

char change_char_hex(char c)
{
    if ((c >= '0') && (c <= '9'))
        return (c - '0');
    else if ((c >= 'a') && (c <= 'f'))
        return (c - 'a' + 10);
    else if ((c >= 'A') && (c <= 'F'))
        return (c - 'A' + 10);

    return 0;
}

char change_char_excsd(char c1, char c2)
{
    printk(KERN_DEBUG "%s:%d c1=0x%x, c2=0x%x\n", __func__, __LINE__, c1, c2);

    return change_char_hex(c1) * 16 +change_char_hex(c2);
}

static u32 get_emmc_size_mb(void)
{
    char *kbuf;
    char mmc_size[4];
    u32 capacity = 0;

    kbuf = kmalloc(EXT_CSD_STR_LEN + 1, GFP_KERNEL);
    memset(kbuf, 0, EXT_CSD_STR_LEN + 1);
    get_buf(MMC_EXT_CSD, kbuf, EXT_CSD_STR_LEN);
    mmc_size[0] = change_char_excsd(kbuf[424], kbuf[425]);
    mmc_size[1] = change_char_excsd(kbuf[426], kbuf[427]);
    mmc_size[2] = change_char_excsd(kbuf[428], kbuf[429]);
    mmc_size[3] = change_char_excsd(kbuf[430], kbuf[431]);
    memcpy(&capacity, mmc_size, 4);
    kfree(kbuf);
    return capacity/2048;
}
static int emmc_size_proc_show(struct seq_file *m, void *v)
{
    u32 capacity = 0;
    capacity = get_emmc_size_mb();
    seq_printf(m, "%uM\n", capacity);
    return 0;
}

static int emmc_size_proc_open(struct inode *inode, struct file *filp)
{
    return single_open(filp, emmc_size_proc_show, inode->i_private);
}

static const struct proc_ops emmc_size_proc_fops = {
    .proc_open       = emmc_size_proc_open,
    .proc_read       = seq_read,
    .proc_lseek     = seq_lseek,
    .proc_release    = single_release,
};

static int emmc_eol_proc_show(struct seq_file *m, void *v)
{
    char *kbuf;
    char mmc_eol;

    kbuf = kmalloc(EXT_CSD_STR_LEN + 1, GFP_KERNEL);
    memset(kbuf, 0, EXT_CSD_STR_LEN + 1);
    get_buf(MMC_EXT_CSD, kbuf, EXT_CSD_STR_LEN);
    mmc_eol = change_char_excsd(kbuf[534], kbuf[535]);
    seq_printf(m, "emmc_eol[%04d]\n", mmc_eol);
    kfree(kbuf);
    return 0;
}

static int emmc_eol_proc_open(struct inode *inode, struct file *filp)
{
    return single_open(filp, emmc_eol_proc_show, inode->i_private);
}

static const struct proc_ops emmc_eol_proc_fops = {
    .proc_open       = emmc_eol_proc_open,
    .proc_read       = seq_read,
    .proc_lseek     = seq_lseek,
    .proc_release    = single_release,
};

static int emmc_life_proc_show(struct seq_file *m, void *v)
{
    char *kbuf;
    char mmc_life[2];

    kbuf = kmalloc(EXT_CSD_STR_LEN + 1, GFP_KERNEL);
    memset(kbuf, 0, EXT_CSD_STR_LEN + 1);
    get_buf(MMC_EXT_CSD, kbuf, EXT_CSD_STR_LEN);
    mmc_life[0] = change_char_excsd(kbuf[536], kbuf[537]);
    mmc_life[1] = change_char_excsd(kbuf[538], kbuf[539]);
    seq_printf(m, "emmc_life_time[%04x%04x]\n", mmc_life[0], mmc_life[1]);
    kfree(kbuf);

    return 0;
}

static int emmc_life_proc_open(struct inode *inode, struct file *filp)
{
    return single_open(filp, emmc_life_proc_show, inode->i_private);
}

static const struct proc_ops emmc_life_proc_fops = {
    .proc_open       = emmc_life_proc_open,
    .proc_read       = seq_read,
    .proc_lseek     = seq_lseek,
    .proc_release    = single_release,
};

static int emmc_health_proc_show(struct seq_file *m, void *v)
{
    char *kbuf;
    int i;
    char mmc_health;

    kbuf = kmalloc(EXT_CSD_STR_LEN +1, GFP_KERNEL);
    memset(kbuf, 0, EXT_CSD_STR_LEN + 1);
    get_buf(MMC_EXT_CSD, kbuf, EXT_CSD_STR_LEN);
    seq_printf(m, "mmc_health_factory[");
    for (i = 540; i < 572; i++) {
       // j = i + 1;
        mmc_health = change_char_excsd(kbuf[i], kbuf[i+1]);
		i++;
        seq_printf(m, "%2x", mmc_health);
        //i++;
    }

    seq_printf(m, "]\n");
    seq_printf(m, "mmc_health_runtime[");
    for (i = 572; i < 604; i++) {
        //j = i + 1;
        mmc_health = change_char_excsd(kbuf[i], kbuf[i+1]);
		i++;
        seq_printf(m, "%02x", mmc_health);
       // i++;
    }

    seq_printf(m, "]\n");
    kfree(kbuf);

    return 0;
}

static int emmc_health_proc_open(struct inode *inode, struct file *filp)
{
    return single_open(filp, emmc_health_proc_show, inode->i_private);
}

static const struct proc_ops emmc_health_proc_fops = {
    .proc_open       = emmc_health_proc_open,
    .proc_read       = seq_read,
    .proc_lseek     = seq_lseek,
    .proc_release    = single_release,
};
static u32 get_emmc_size_gb(void)
{
    struct file *filp;
    loff_t pos = 0;
    char buf[32];
    long long sectors;
    u64 bytes;
    u32 real_gb;
    int ret;

    filp = filp_open("/sys/block/mmcblk0/size", O_RDONLY, 0);
    if (IS_ERR(filp))
        return 0;

    ret = kernel_read(filp, buf, sizeof(buf) - 1, &pos);
    filp_close(filp, NULL);

    if (ret <= 0)
        return 0;

    buf[ret] = '\0';

    ret = kstrtoll(buf, 10, &sectors);
    if (ret)
        return 0;
    bytes = (u64)sectors << 9;
    real_gb = bytes / 1000000000ULL;
    if (!real_gb)
        return 0;
    return round_to_nearest_pow2(real_gb);
}


static int get_ddr_size_mb(void)
{
    char *kbuf;
    int i, result = 0;

    kbuf = kmalloc(DDR_STR_LEN, GFP_KERNEL);
    memset(kbuf, 0, DDR_STR_LEN);
    get_buf(MEMINFO, kbuf, DDR_STR_LEN);

    for (i = 0; kbuf[i] != '\n'; i++) {
        if((kbuf[i] > '/') && (kbuf[i] < ':'))
            result = result * 10 + kbuf[i] - '0';
    }

    kfree(kbuf);
    return result/1024;
}

static int emcp_info_proc_show(struct seq_file *m, void *v)
{
    char *kbuf;
    int ddr_size = 0;
    int i = 0;

    kbuf = kmalloc(EMMC_NAME_STR_LEN, GFP_KERNEL);
    memset(kbuf, 0, EMMC_NAME_STR_LEN);
    ddr_size = get_ddr_size_mb();
    get_buf(MMC_NAME, kbuf, EMMC_NAME_STR_LEN);
    for (i = 0; i < EMMC_NAME_STR_LEN; i++) {
        if (kbuf[i] == '\n') {
            kbuf[i] = '\0';
            break;
        }
    }

    if (ddr_size <= 512)
        seq_printf(m, "%s,%dG,512M\n", kbuf, get_emmc_size_gb());
    else {
        ddr_size = ddr_size / 1024 + 1;
        seq_printf(m, "%s,%dG,%dG\n", kbuf, get_emmc_size_gb(), ddr_size);
    }

    kfree(kbuf);

    return 0;
}

static int emcp_info_proc_open(struct inode *inode, struct file *filp)
{
    return single_open(filp, emcp_info_proc_show, inode->i_private);
}

static const struct proc_ops emcp_info_proc_fops = {
    .proc_open       = emcp_info_proc_open,
    .proc_read       = seq_read,
    .proc_lseek     = seq_lseek,
    .proc_release    = single_release,
};

extern void get_pmic_info(char *buf);

static int pmu_info_proc_show(struct seq_file *m, void *v)
{
    char pmu_info[64] = {'\0'};

    get_pmic_info(pmu_info);
    seq_printf(m, "%s\n", pmu_info);
    return 0;
}

static int pmu_info_proc_open(struct inode *inode, struct file *filp)
{
    return single_open(filp, pmu_info_proc_show, inode->i_private);
}

static const struct proc_ops pmu_info_proc_fops = {
    .proc_open       = pmu_info_proc_open,
    .proc_read       = seq_read,
    .proc_lseek     = seq_lseek,
    .proc_release    = single_release,
};

static int qdevinfo_proc_create(void)
{
    printk(KERN_INFO "proc create\n");
    proc_create("emmc_ext_csd", 0444, NULL, &emmc_ext_csd_proc_fops);
    proc_create("emmc_size", 0444, NULL, &emmc_size_proc_fops);
    proc_create("emmc_eol", 0444, NULL, &emmc_eol_proc_fops);
    proc_create("emmc_life", 0444, NULL, &emmc_life_proc_fops);
    proc_create("emmc_health", 0444, NULL, &emmc_health_proc_fops);
    proc_create("emcp_info", 0444, NULL, &emcp_info_proc_fops);
    proc_create("pmu_info", 0444, NULL, &pmu_info_proc_fops);
    return 0;
}

static int __init devinfo_init(void)
{
    if (qdevinfo_proc_create())
        printk(KERN_ERR "devinfo init failed!\n");
    else
        printk(KERN_INFO "devinfo init success!\n");

    pr_info("fulinux I am here\n");

    return 0;
}

static void __exit devinfo_exit(void)
{
    printk(KERN_DEBUG "devinfo exit!");
}

module_init(devinfo_init);
module_exit(devinfo_exit);

MODULE_AUTHOR("geoff.liu");
MODULE_LICENSE("GPL");

#endif /* QDEVINFO_CMD */