#include <linux/configfs.h>
#include <linux/firmware.h>
#include <linux/limits.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/slab.h>
#include <linux/sizes.h>
#include <linux/string.h>

struct cfs_overlay_item {
	struct config_item item;
	struct mutex lock;
	char path[PATH_MAX];
	const struct firmware *fw;
	void *dtbo;
	size_t dtbo_size;
	int ov_id;
	bool applied;
};

static inline struct cfs_overlay_item *to_cfs_overlay_item(struct config_item *item)
{
	return container_of(item, struct cfs_overlay_item, item);
}

static ssize_t cfs_overlay_item_path_show(struct config_item *item, char *page)
{
	struct cfs_overlay_item *overlay = to_cfs_overlay_item(item);
	ssize_t ret;

	mutex_lock(&overlay->lock);
	ret = sysfs_emit(page, "%s\n", overlay->path);
	mutex_unlock(&overlay->lock);
	return ret;
}

static ssize_t cfs_overlay_item_path_store_locked(struct config_item *item,
					 const char *page, size_t count)
{
	struct cfs_overlay_item *overlay = to_cfs_overlay_item(item);
	int ret;

	if (overlay->ov_id || overlay->dtbo_size || overlay->path[0])
		return -EPERM;
	if (!count || count >= sizeof(overlay->path))
		return -EINVAL;

	memcpy(overlay->path, page, count);
	overlay->path[count] = '\0';
	strim(overlay->path);
	ret = request_firmware(&overlay->fw, overlay->path, NULL);
	if (ret)
		goto clear_path;
	ret = of_overlay_fdt_apply(overlay->fw->data, overlay->fw->size,
				   &overlay->ov_id);
	if (!ret) {
		overlay->applied = true;
		return count;
	}
	release_firmware(overlay->fw);
	overlay->fw = NULL;
clear_path:
	overlay->path[0] = '\0';
	return ret;
}

static ssize_t cfs_overlay_item_path_store(struct config_item *item,
					 const char *page, size_t count)
{
	struct cfs_overlay_item *overlay = to_cfs_overlay_item(item);
	ssize_t ret;

	mutex_lock(&overlay->lock);
	ret = cfs_overlay_item_path_store_locked(item, page, count);
	mutex_unlock(&overlay->lock);
	return ret;
}

static ssize_t cfs_overlay_item_status_show(struct config_item *item, char *page)
{
	struct cfs_overlay_item *overlay = to_cfs_overlay_item(item);
	ssize_t ret;

	mutex_lock(&overlay->lock);
	ret = sysfs_emit(page, "%s\n", overlay->applied ? "applied" : "unapplied");
	mutex_unlock(&overlay->lock);
	return ret;
}

static ssize_t cfs_overlay_item_remove_store(struct config_item *item,
					   const char *page, size_t count)
{
	struct cfs_overlay_item *overlay = to_cfs_overlay_item(item);
	bool remove;
	int ret;

	ret = kstrtobool(page, &remove);
	if (ret || !remove)
		return -EINVAL;
	mutex_lock(&overlay->lock);
	ret = overlay->ov_id > 0 ? of_overlay_remove(&overlay->ov_id) : 0;
	if (!overlay->ov_id)
		overlay->applied = false;
	mutex_unlock(&overlay->lock);
	return ret ? ret : count;
}

CONFIGFS_ATTR(cfs_overlay_item_, path);
CONFIGFS_ATTR_RO(cfs_overlay_item_, status);
CONFIGFS_ATTR_WO(cfs_overlay_item_, remove);

static struct configfs_attribute *cfs_overlay_attrs[] = {
	&cfs_overlay_item_attr_path,
	&cfs_overlay_item_attr_status,
	&cfs_overlay_item_attr_remove,
	NULL,
};

static ssize_t cfs_overlay_item_dtbo_read(struct config_item *item,
					void *buf, size_t count)
{
	struct cfs_overlay_item *overlay = to_cfs_overlay_item(item);
	ssize_t ret;

	mutex_lock(&overlay->lock);
	ret = overlay->dtbo_size;
	if (buf) {
		if (count < overlay->dtbo_size)
			ret = -ENOSPC;
		else if (overlay->dtbo_size)
			memcpy(buf, overlay->dtbo, overlay->dtbo_size);
	}
	mutex_unlock(&overlay->lock);
	return ret;
}

static ssize_t cfs_overlay_item_dtbo_write_locked(struct config_item *item,
					 const void *buf, size_t count)
{
	struct cfs_overlay_item *overlay = to_cfs_overlay_item(item);
	int ret;

	if (overlay->ov_id || overlay->dtbo_size || overlay->path[0])
		return -EPERM;
	if (!count)
		return -EINVAL;
	overlay->dtbo = kmemdup(buf, count, GFP_KERNEL);
	if (!overlay->dtbo)
		return -ENOMEM;
	overlay->dtbo_size = count;
	ret = of_overlay_fdt_apply(overlay->dtbo, count, &overlay->ov_id);
	if (!ret) {
		overlay->applied = true;
		return count;
	}
	kfree(overlay->dtbo);
	overlay->dtbo = NULL;
	overlay->dtbo_size = 0;
	return ret;
}

static ssize_t cfs_overlay_item_dtbo_write(struct config_item *item,
					 const void *buf, size_t count)
{
	struct cfs_overlay_item *overlay = to_cfs_overlay_item(item);
	ssize_t ret;

	mutex_lock(&overlay->lock);
	ret = cfs_overlay_item_dtbo_write_locked(item, buf, count);
	mutex_unlock(&overlay->lock);
	return ret;
}

CONFIGFS_BIN_ATTR(cfs_overlay_item_, dtbo, NULL, SZ_1M);

static struct configfs_bin_attribute *cfs_overlay_bin_attrs[] = {
	&cfs_overlay_item_attr_dtbo,
	NULL,
};

static void cfs_overlay_release(struct config_item *item)
{
	struct cfs_overlay_item *overlay = to_cfs_overlay_item(item);
	int ret;

	if (overlay->ov_id > 0) {
		ret = of_overlay_remove(&overlay->ov_id);
		if (ret)
			pr_err("OF configfs: overlay removal failed: %d\n", ret);
	}
	release_firmware(overlay->fw);
	kfree(overlay->dtbo);
	kfree(overlay);
}

static struct configfs_item_operations cfs_overlay_item_ops = {
	.release = cfs_overlay_release,
};

static const struct config_item_type cfs_overlay_type = {
	.ct_item_ops = &cfs_overlay_item_ops,
	.ct_attrs = cfs_overlay_attrs,
	.ct_bin_attrs = cfs_overlay_bin_attrs,
	.ct_owner = THIS_MODULE,
};

static struct config_item *cfs_overlay_group_make_item(struct config_group *group,
						      const char *name)
{
	struct cfs_overlay_item *overlay;

	overlay = kzalloc(sizeof(*overlay), GFP_KERNEL);
	if (!overlay)
		return ERR_PTR(-ENOMEM);
	mutex_init(&overlay->lock);
	config_item_init_type_name(&overlay->item, name, &cfs_overlay_type);
	return &overlay->item;
}

static struct configfs_group_operations overlays_ops = {
	.make_item = cfs_overlay_group_make_item,
};

static const struct config_item_type overlays_type = {
	.ct_group_ops = &overlays_ops,
	.ct_owner = THIS_MODULE,
};

static const struct config_item_type of_cfs_type = {
	.ct_owner = THIS_MODULE,
};

static struct config_group of_cfs_overlay_group;

static struct configfs_subsystem of_cfs_subsys = {
	.su_group = {
		.cg_item = {
			.ci_namebuf = "device-tree",
			.ci_type = &of_cfs_type,
		},
	},
	.su_mutex = __MUTEX_INITIALIZER(of_cfs_subsys.su_mutex),
};

static int __init of_cfs_init(void)
{
	config_group_init(&of_cfs_subsys.su_group);
	config_group_init_type_name(&of_cfs_overlay_group, "overlays", &overlays_type);
	configfs_add_default_group(&of_cfs_overlay_group, &of_cfs_subsys.su_group);
	return configfs_register_subsystem(&of_cfs_subsys);
}
late_initcall(of_cfs_init);