#include <linux/err.h>
#include <linux/fs.h>
#include <linux/namei.h>
#include <linux/printk.h>
#include <linux/version.h>

#include "policy/allowlist.h"
#include "klog.h" // IWYU pragma: keep
#include "runtime/ksud_boot.h"
#include "runtime/ksud.h"
#include "manager/manager_observer.h"
#include "manager/throne_tracker.h"
#include "selinux/selinux.h"

bool ksu_module_mounted __read_mostly = false;
bool ksu_boot_completed __read_mostly = false;
extern void stop_input_hook();

extern void ksu_avc_spoof_late_init();

void on_post_fs_data(void)
{
	static bool done = false;
	if (done) {
		pr_info("on_post_fs_data already done\n");
		return;
	}
	done = true;
	pr_info("on_post_fs_data!\n");

	ksu_load_allow_list();
	ksu_observer_init();
	// sanity check, this may influence the performance
	stop_input_hook();
}

extern void ext4_unregister_sysfs(struct super_block *sb);

int nuke_ext4_sysfs(const char *mnt)
{
	struct path path;
	int err = kern_path(mnt, 0, &path);
	if (err) {
		pr_err("nuke path err: %d\n", err);
		return err;
	}

	struct super_block *sb = path.dentry->d_inode->i_sb;
	const char *name = sb->s_type->name;
	if (strcmp(name, "ext4") != 0) {
		pr_info("nuke but module aren't mounted\n");
		path_put(&path);
		return -EINVAL;
	}

	ext4_unregister_sysfs(sb);
	path_put(&path);
	return 0;
}

void on_module_mounted(void)
{
	pr_info("on_module_mounted!\n");
	ksu_module_mounted = true;
}

void on_boot_completed(void)
{
    ksu_boot_completed = true;
    pr_info("on_boot_completed!\n");
    // On kernels < 5.9 the packages.list fsnotify observer is a no-op, so the
    // manager is never re-scanned after boot unless we do a full track_throne
    // here. prune_only=true left Manager permanently "Unsupported" on 4.9.
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)
    track_throne(false);
#else
    track_throne(true);
#endif
    ksu_avc_spoof_late_init();
}
