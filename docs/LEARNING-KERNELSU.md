# KernelSU / KernelSU-Next Development Deep Dive

**Audience:** a developer who already ships a 4.9.337 non-GKI kernel with KernelSU-Next manual hooks (`CONFIG_KSU_MANUAL_HOOK=y`), has ported the SUSFS v2.2.0 sys_reboot dispatcher into `kernel/supercall/supercall.c`, and now wants to *extend KernelSU itself*.

**Sources & method:** this document is based on reading the actual trees: KernelSU-Next `main` @ `f9a6995` (v3.3.0-dev, Sept 2026), the `v3.2.0-legacy` / `v3.1.0-legacy` / `v3.0.x-legacy` tags (the non-GKI/manual-hook line), the official docs at [kernelsu.org](https://kernelsu.org) and the [KernelSU-Next webpage repo](https://github.com/KernelSU-Next/webpage), the [SUSFS v2 kernel patch](https://gitlab.com/simonpunk/susfs4ksu) (gki-android15-6.6-dev branch, SUSFS v2.3.0), [SukiSU-Ultra](https://github.com/ShirkNeko/SukiSU-Ultra) (incl. `repack_apk.py` and KPM), the [KernelSU JS bridge](https://github.com/tiann/KernelSU/tree/main/js), and web research on APatch / mountify / the Samsung non-GKI lineage. Paths below are relative to the repo root of each project unless stated otherwise. Anything I could not confirm from source is flagged **[uncertain]**.

---

## 1. Architecture deep dive (KernelSU-Next v3.x kernel driver)

### 1.1 Subsystem layout

Since v3.0, `kernel/` in [KernelSU-Next/KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) is split into subsystem directories (`kernel/Kbuild` lists them; the shared UAPI lives at the **repo top level** in `uapi/`, not inside `kernel/`):

| Dir | Files | Role |
|---|---|---|
| `kernel/core/` | `init.c` | `kernelsu_init()`/`kernelsu_exit()` — init ordering, `ksu_cred` (root creds template), `ksu_late_loaded` (LKM loaded after boot), the A12-5.10 stack-protector workaround, module hiding via `kobject_del(THIS_MODULE->mkobj.kobj)` |
| `kernel/feature/` | `sucompat.c`, `kernel_umount.c`, `sulog.c`, `adb_root.c`, `selinux_hide.c` | User-visible features, each registering a *feature handler* (see §4) |
| `kernel/hook/` | `syscall_hook_manager.c`, `syscall_hook.c` (+`arm64/`, `x86_64/`), `syscall_event_bridge.c`, `setuid_hook.c`, `lsm_hook.c`, `tp_marker.c`, `patch_memory.h` | Everything that intercepts kernel execution paths |
| `kernel/infra/` | `symbol_resolver.c`, `file_wrapper.c`, `event_queue.c`, `seccomp_cache.c`, `su_mount_ns.c` | Runtime plumbing: kallsyms lookup, fd-wrapper (`/proc` spoofing via file ops proxy), sulog event queue, seccomp-bpf cache manipulation, per-su mount namespace (task_work) |
| `kernel/manager/` | `apk_sign.c`, `manager_identity.h`, `pkg_observer.c`, `throne_tracker.c` | Manager identity (v2 signing-block hash), fsnotify watcher on `/data/app`, "throne tracker" (persistent root app list). Compiled out entirely by `CONFIG_KSU_DISABLE_MANAGER` (`kernel/Kbuild` lines 27–31) |
| `kernel/policy/` | `allowlist.c`, `app_profile.c`, `feature.c` | Per-UID allow/deny list (RCU, persisted through a task_work write), root/non-root profiles (`uapi/app_profile.h`), the feature registry |
| `kernel/runtime/` | `ksud_integration.c`, `boot_event.c` | ksud bootstrap: init.rc read-proxy injection, safe-mode (volume keys), event reporting |
| `kernel/selinux/` | `rules.c`, `sepolicy.c`, `selinux.c` | Runtime sepolicy injection (`ksu_handle_sepolicy`), domain management, `ksu_file_sid` |
| `kernel/supercall/` | `supercall.c`, `dispatch.c`, `perm.c`, `internal.h` | The userspace→kernel entry points (fd-ioctl table + sys_reboot channel) |
| `kernel/sulog/` | `event.c`, `fd.c` | "sulog" audit log; kernel event ring exposed via a dedicated anon fd (`KSU_IOCTL_GET_SULOG_FD`) |
| `uapi/` (top level) | `supercall.h`, `app_profile.h`, `feature.h`, `selinux.h`, `sulog.h`, `ksu.h` | The single source of truth for the UAPI, consumed by kernel, ksud (as `ksu_uapi.h`) and the manager's C++ layer. `static const __u32 KERNEL_SU_UAPI_VERSION = 4;` |

### 1.2 The spine: end-to-end root request flow

```
app (uid 10xxx) execve("/system/bin/su")
   │
   ▼
fs/exec.c manual hook  (or sys_enter tracepoint redirect → dispatcher syscall on GKI)
   │  ksu_handle_execveat()  ← kernel/core/init.c (legacy) / syscall_event_bridge (v3.3)
   ▼
ksu_handle_execveat_sucompat()  ← kernel/feature/sucompat.c
   │  path == "/system/bin/su" ?
   │  ksu_is_allow_uid_for_current(uid) ?     ← kernel/policy/allowlist.c (RCU)
   │  override_creds(ksu_cred); filp_open(KSUD_PATH, O_PATH); fd_install(tmp_fd)
   │  rewrite pt_regs:  execveat(tmp_fd, "", argv, envp, AT_EMPTY_PATH)
   │  escape_with_root_profile()               ← kernel/policy/app_profile.c
   │  call original syscall via ksu_syscall_table[__NR_execveat](regs)
   │  ksu_install_su_fd()                      ← [ksu_driver_su] anon fd, post-exec
   ▼
ksud (now root, SELinux u:r:ksu:s0) serves the shell
   │  talks to the driver with ioctl() on the inherited anon fd  ← userspace/ksud/src/ksucalls.rs
   ▼
allowlist/profiles/sepolicy/features all mutate via KSU_IOCTL_* supercalls
```

The load-bearing snippet — `kernel/feature/sucompat.c` (v3.3-dev, same logic in legacy):

```c
static long ksu_handle_execve_sucompat_common(const char __user **filename_user, ...)
{
        if (!ksu_is_allow_uid_for_current(current_uid().val))
                goto do_orig_execve;
        ...
        if (likely(memcmp(path, su_path, sizeof(su_path))))
                goto do_orig_execve;                    /* "/system/bin/su" */

        tmp_fd = get_unused_fd_flags(O_CLOEXEC);
        old_cred = override_creds(ksu_cred);
        ksud_file = filp_open(KSUD_PATH, O_PATH, 0);
        revert_creds(old_cred);
        fd_install(tmp_fd, ksud_file);

        /* rewrite execve(file, argv, envp) -> execveat(tmp_fd, "", argv, envp, AT_EMPTY_PATH) */
        regs->__PT_PARM5_REG = AT_EMPTY_PATH;
        regs->__PT_SYSCALL_PARM4_REG = envp;
        regs->__PT_PARM2_REG = empty_user_path();       /* "" written just below the user stack ptr */
        regs->__PT_PARM1_REG = tmp_fd;

        ret = escape_with_root_profile();
        ret = ksu_syscall_table[__NR_execveat](regs);   /* replay the syscall */
        ...
        su_fd = ksu_install_su_fd();                    /* scoped driver fd after exec */
}
```

`empty_user_path()` / `ksud_user_path()` use `userspace_stack_buffer()` — the string is written *below the user stack pointer* so no mmap is needed.

### 1.3 The supercall UAPI and its three transport channels

All commands are defined once in `uapi/supercall.h`. `KERNEL_SU_UAPI_VERSION = 4` (comment history: 2 = root-profile flags, 3 = su-session fd, 4 = `KSU_GET_INFO_FLAG_BUNDLED`). ksud enforces the match at boot: `ensure_uapi_version_matched()` in `userspace/ksud/src/ksucalls.rs`.

**Channel A — anon-inode fd + ioctl (the primary v3 channel).** `ksu_install_fd()` (`kernel/supercall/supercall.c`) creates:

```c
filp = anon_inode_getfile(name, &anon_ksu_fops, context, O_RDWR);
/* name = "[ksu_driver]", or "[ksu_driver_su]" when
   context->permissions & KSU_DRIVER_PERMISSION_SU_SESSION */
```

Every `ioctl()` lands in `ksu_supercall_handle_ioctl()` (`kernel/supercall/dispatch.c`), which walks a static table:

```c
static const struct ksu_ioctl_cmd_map ksu_ioctl_handlers[] = {
    { .cmd = KSU_IOCTL_GRANT_ROOT,  .name = "GRANT_ROOT",  .handler = do_grant_root,
      .perm_check = allowed_for_su },
    { .cmd = KSU_IOCTL_GET_INFO,    .name = "GET_INFO",    .handler = do_get_info,
      .perm_check = always_allow },
    ...
    { .cmd = KSU_IOCTL_GET_WRAPPER_FD, .perm_check = manager_or_root, .allow_su_session = true },
    ...
    { .cmd = 0, ... }  // sentinel
};
```

Permission classes (`kernel/supercall/perm.c`): `only_manager()` (`current_uid() % 100000 == ksu_manager_appid`), `only_root()`, `manager_or_root()`, `allowed_for_su()` (manager or allowlisted uid), `always_allow()`. `.allow_su_session = true` lets a *scoped* su session (the `[ksu_driver_su]` fd installed right after exec into ksud) call select commands even though it isn't uid 0/manager. Command numbers are `_IOC('K', …)` — see `uapi/supercall.h` lines 171–199 (`KSU_IOCTL_GRANT_ROOT` … `KSU_IOCTL_GET_VERSION_TAG`, plus 98/99 for hook-mode and version-tag).

**Channel B — the `sys_reboot` channel (bootstrap + extensions).** Before any fd exists, the only way in is a hooked syscall. KernelSU uses `reboot()`:

```c
static const __u32 KSU_INSTALL_MAGIC1 = 0xDEADBEEF;
static const __u32 KSU_INSTALL_MAGIC2 = 0xCAFEBABE;

/* legacy manual-hook path (v3.2.0-legacy), called from kernel/reboot.c: */
int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg)
{
    if (magic1 != KSU_INSTALL_MAGIC1) return 0;
    if (magic2 == KSU_INSTALL_MAGIC2) {        /* install driver fd */
        int fd = ksu_install_fd();
        copy_to_user((void __user *)*arg, &fd, sizeof(fd));
        ...
    }
    if (magic2 == CHANGE_MANAGER_UID)  { ... ksu_set_manager_appid(cmd); reply ... }   /* 10006 */
    if (magic2 == GET_SULOG_DUMP_V2)   { ... }                                          /* 10010 */
    if (magic2 == CHANGE_KSUVER)       { ... }                                          /* 10011 */
    if (magic2 == CHANGE_SPOOF_UNAME)  { ... triple-pointer uname spoof ... }           /* 10012 */
}
```

In the v3.3-dev (GKI/kprobe) line the same logic moved into a kprobe pre-handler on `REBOOT_SYMBOL` (`kernel/supercall/supercall.c:122`, `reboot_handler_pre`), and the fd install is deferred through **task_work** (below). Note this channel is *root-gated by the kernel itself* for reboot (`ns_capable(..., CAP_SYS_BOOT)` happens after the hook in `SYSCALL_DEFINE4(reboot)`), which is why the KSU commands additionally check `current_uid().val != 0`.

The extension commands (`CHANGE_MANAGER_UID=10006`, `KSU_UMOUNT_GETSIZE=107`, `KSU_UMOUNT_GETLIST=108`, `GET_SULOG_DUMP_V2=10010`, `CHANGE_KSUVER=10011`, `CHANGE_SPOOF_UNAME=10012`) are exactly the "third-party toolkit" pattern you already use for SUSFS.

**Channel C — `prctl` (upstream tiann/KernelSU only).** Upstream KernelSU dispatches supercalls through a hooked `prctl` (`ksu_handle_prctl`, `OPTION_*` commands) on GKI via kprobe. **KernelSU-Next v3 has removed the prctl channel entirely** — I found no `ksu_handle_prctl` anywhere in either `main` or `v3.2.0-legacy`; both use fd-ioctl + sys_reboot. Don't port anything that relies on prctl.

### 1.4 `ksu_install_fd` and the manager-fd mechanism (task_work)

Three ways a `[ksu_driver]` fd appears in a process:

1. **Manager crowning via setresuid** — `kernel/hook/setuid_hook.c`:

```c
int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid)
{
    // we rely on the fact that zygote always call setresuid(3) with same uids
    uid_t new_uid = ruid;
    uid_t old_uid = current_uid().val;
    if (unlikely(is_uid_manager(new_uid))) {
        ksu_seccomp_allow_cache(current->seccomp.filter, __NR_reboot);  /* or disable_seccomp() <5.10 */
        /* task_work: install [ksu_driver] fd after the syscall returns */
    }
}
```

2. **Explicit request via sys_reboot magic pair** — the `reboot(0xDEADBEEF, 0xCAFEBABE, ...)` path.
3. **Inheritance** — children inherit the fd (`O_CLOEXEC` prevents leaking into exec'd processes; ksud instead re-scans `/proc/self/fd` for `anon_inode:[ksu_driver]`, `ksucalls.rs::scan_driver_fd`).

The task_work indirection is mandatory and worth internalizing — `fd_install()` must run when the syscall returns to userspace, not from kprobe/hook context. From `kernel/supercall/supercall.c`:

```c
struct ksu_install_fd_tw { struct callback_head cb; int __user *outp; };

static void ksu_install_fd_tw_func(struct callback_head *cb)
{
    struct ksu_install_fd_tw *tw = container_of(cb, struct ksu_install_fd_tw, cb);
    int fd = ksu_install_fd();
    if (copy_to_user(tw->outp, &fd, sizeof(fd)))
        ksu_close_fd(fd);
    kfree(tw);
}

static int reboot_handler_pre(struct kprobe *p, struct pt_regs *regs)
{
    ...
    tw = kzalloc(sizeof(*tw), GFP_ATOMIC);
    tw->outp = (int __user *)arg4;
    tw->cb.func = ksu_install_fd_tw_func;
    task_work_add(current, &tw->cb, TWA_RESUME);   /* runs just before return-to-userspace */
}
```

The same pattern appears in `kernel/infra/su_mount_ns.c` (`struct ksu_mns_tw`) for switching the su process into its own mount namespace.

### 1.5 Manager identity ("crowning")

- `kernel/manager/manager_identity.h`: `is_manager()` is `ksu_manager_appid == current_uid().val % KSU_PER_USER_RANGE` (100000). The appid is *learned*, not fixed.
- Learning paths: (a) `pkg_observer.c` registers an fsnotify group on `/data/app` — when an APK is installed/renamed, `is_manager_apk(path)` (`kernel/manager/apk_sign.c`) runs `check_v2_signature()` against the compiled-in hash and, on match, `ksu_set_manager_appid()` ("crowning"); (b) the root-only `CHANGE_MANAGER_UID` reboot command; (c) `throne_tracker.c` scans `track_throne(prune_only)` for already-installed packages at boot/post-fs-data.
- `check_v2_signature()` parses the ZIP EOCD (with ZIP64 rejection), the `APK Sig Block 42`, and walks length-prefixed pairs looking for id `0x7109871a` (v2 signing block), then SHA-256s the first certificate and compares with `EXPECTED_MANAGER_HASH` / `EXPECTED_MANAGER_SIZE` (defaults in `kernel/Kbuild`: size `0x3e6` = 998 bytes, hash `79e590113c4c4c0c222978e413a5faa801666957b1212a328e46c00c69821bf7`).
- `CONFIG_KSU_DISABLE_MANAGER=y` compiles the whole manager/ dir out and hardcodes `is_manager() == (uid == 0)` — useful for "headless" kernels.

### 1.6 Hook transport on GKI (v3.3-dev) — for contrast with your manual hooks

`kernel/hook/syscall_hook_manager.c` registers handlers for `setresuid`, `execve`, `execveat`, `newfstatat`, `faccessat` and, when `CONFIG_HAVE_SYSCALL_TRACEPOINTS`, uses the `sys_enter` tracepoint at priority `INT_MIN` to **rewrite the guest syscall number** of marked tasks, redirecting them into a dedicated kernel-space dispatcher syscall:

```c
static void ksu_sys_enter_handler(void *data, struct pt_regs *regs, long id)
{
    if (ksu_dispatcher_nr < 0) return;
    if (ksu_has_syscall_hook(id)) {
        struct pt_regs *current_regs = task_pt_regs(current);
        /* aarch64: */
        PT_REGS_ORIG_SYSCALL(current_regs) = id;         /* remember original */
        current_regs->syscallno = ksu_dispatcher_nr;     /* route to KSU dispatcher */
    }
}
```

`kernel/hook/arm64/syscall_hook.c` provides `ksu_syscall_table_hook()` (fixmap + `stop_machine` direct syscall-table overwrite, used for the ksud boot-time `execve/read` hooks) and `ksu_register_syscall_hook()` (routing-table entry in the shared dispatcher slot). `kernel/hook/lsm_hook.c` additionally locates `struct security_hook_list` entries in `security_hook_heads` at runtime and injects KSU handlers (dynamic LSM hooking, replacing kprobes for some hooks). Process marking (which tasks are traced) is managed by `kernel/hook/tp_marker.c` plus kretprobes on `syscall_regfunc`/`syscall_unregfunc` so KSU coexists with other tracepoint users. None of this machinery applies to your 4.9 manual-hook build — legacy `CONFIG_KSU_MANUAL_HOOK` compiles all of `hook_manager.c`/tracepoint code out (`#ifdef KSU_KPROBES_HOOK` in the legacy tree).

---

## 2. Manual hooks on non-GKI kernels (what you have)

### 2.1 The exact hook set and call sites

The official integration guide is [KernelSU-Next "Integrate for non-GKI devices"](https://github.com/KernelSU-Next/webpage/blob/main/docs/pages/how-to-integrate-for-non-gki.md) (rendered on the [KernelSU-Next webpage](https://kernelsu-next.github.io/webpage/)); upstream's older variant is [kernelsu.org — how-to-integrate-for-non-gki](https://kernelsu.org/guide/how-to-integrate-for-non-gki.html). For KernelSU-Next `legacy`, five call sites are *required* (these are also what the build checks): 

| # | Kernel file | Call site | Hook invoked (legacy names) | Purpose / what breaks without it |
|---|---|---|---|---|
| 1 | `fs/exec.c` | `do_execve()` **and** `compat_do_execve()` (32-on-64 support) | `ksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0)` | The root of everything: su→ksud redirect and ksud/zygote tracking. In legacy, `ksu_handle_execveat` is a thin dispatcher in `kernel/core/init.c`: it calls `ksu_handle_execveat_ksud()` (init/zygote exec tracking, throne) then `ksu_handle_execveat_sucompat()` (the su redirect). Without it: no su binary support, no ksud boot, no manager tracking |
| 2 | `fs/open.c` | `SYSCALL_DEFINE3(faccessat)` (pre-4.17: at the syscall definition) | `ksu_handle_faccessat(&dfd, &filename, &mode, NULL)` | `access()`-based `su` detection used by some shells/apps (`sucompat` faccessat→ksud redirect). Mostly redundant with execve but part of the compat contract |
| 3 | `fs/read_write.c` | `SYSCALL_DEFINE3(read)` before `vfs_read` | `if (unlikely(ksu_vfs_read_hook)) ksu_handle_sys_read(fd, &buf, &count);` | **ksud bootstrap**: when init reads `/system/etc/init/init.rc`, KSU swaps `file->f_op` for a proxy (`read_proxy`/`read_iter_proxy` in `kernel/runtime/ksud_integration.c`) that appends `KERNEL_SU_RC` — the `service` definition that starts ksud. Without it, ksud never starts in built-in mode |
| 4 | `fs/stat.c` | `SYSCALL_DEFINE4(newfstatat)` (or `vfs_fstatat`/`vfs_statx` on other kernels) | `ksu_handle_stat(&dfd, &filename, &flag)` | `stat`-based su probe redirect (faccessat/stat pair) |
| 5 | `kernel/reboot.c` | `SYSCALL_DEFINE4(reboot)`, before the `ns_capable` check | `ksu_handle_sys_reboot(magic1, magic2, cmd, &arg)` | The whole supercall bootstrap channel: driver fd install (manager fallback path), manager-uid set, ksuver override, uname spoof — **and your SUSFS dispatcher**. Without it: manager can still work via setresuid fd-push, but ksud has no fallback and no extensions |

From the official diff (verbatim, `reboot.c` hunk):

```diff
+#ifdef CONFIG_KSU
+extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
+#endif
 SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,
 		void __user *, arg)
 {
 	struct pid_namespace *pid_ns = task_active_pid_ns(current);
 	char buffer[256];
 	int ret = 0;
 
+#ifdef CONFIG_KSU 
+	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
+#endif
 	/* We only trust the superuser with rebooting the system. */
```

Note the signature difference between generations: legacy manual hook passes `void __user **arg` (the address of the syscall's `arg` slot on the kernel stack, so KSU can *replace* it — needed for the fd reply); the v3.3 kprobe path recovers it via `PT_REGS_SYSCALL_PARM4` and defers the install to task_work. The SUSFS patch (both [upstream](https://gitlab.com/simonpunk/susfs4ksu) and your port) uses exactly the same 4-arg manual signature, which is why the two compose in one `kernel/reboot.c` — but see §4.3 about *ordering* between KSU's and SUSFS's handlers.

**Additional (optional but recommended) hooks in the legacy tree:**

| Kernel file | Hook | Purpose | Breakage if absent |
|---|---|---|---|
| `kernel/sys.c` — `SYSCALL_DEFINE3(setresuid)` | `ksu_handle_setresuid(ruid, euid, suid)` (`kernel/hook/setuid_hook.c`) | Detects the manager being forked/unpacked by zygote and pushes the `[ksu_driver]` fd via task_work; triggers `ksu_handle_umount()` (`kernel/feature/kernel_umount.c`) for module umount on app start; seeds the seccomp cache | Manager loses its silent fd (falls back to the reboot-magic path); kernel umount for app processes never fires |
| `drivers/input/input.c` — `input_handle_event()` | `if (unlikely(ksu_input_hook)) ksu_handle_input_handle_event(&type, &code, &value);` (`kernel/runtime/ksud_integration.c`) | Safe mode: 3× volume-down at boot | No safe-mode rescue (upstream docs warn: with manual integration keep `CONFIG_KPROBES` off, or users can trigger safe mode at will) |
| `fs/devpts/inode.c` — `devpts_get_priv()` | `__ksu_handle_devpts(inode)` (`kernel/hook/lsm_hooks.c` legacy; `extern int ksu_handle_devpts(struct inode*)` per upstream docs) | sucompat: flags untrusted-app ptys so `su` sessions keep a proper terminal context (and sulog can attribute them) | su from terminal emulators can misbehave/detect; purely quality-of-life **[uncertain on exact failure mode in v3 — the v3.3 `lsm_hook.c` covers this via LSM instead]** |
| `kernel/sys.c` rename path (upstream) / `renameat` hook | throne tracker kick (`atomic_xchg(&first_time, …)` → `track_throne(true)`) | Re-scan for the manager APK on package installs | Crowning delays until next full scan; fsnotify observer usually covers this in v3 |

### 2.2 What the build-time gate does

In `v3.2.0-legacy/kernel/Kbuild`:

```make
# RKSU: checks for available hook
HAVE_KSU_HOOK ?= 1

ifeq ($(CONFIG_KSU_KPROBES_HOOK), y)
ccflags-y += -DKSU_KPROBES_HOOK
HAVE_KSU_HOOK := 0
endif

ifeq ($(CONFIG_KSU_MANUAL_HOOK), y)
HAVE_KSU_HOOK := $(shell grep -q "ksu_handle_sys_reboot" $(srctree)/kernel/reboot.c && echo 0 || echo 1)
ifeq ($(HAVE_KSU_HOOK),0)
$(info -- KernelSU-Next: Hook mode: Manual)
endif
endif

ifneq ($(HAVE_KSU_HOOK),0)
$(error -- KernelSU-Next: No hooks were defined, please integrate manual hooks in your kernel!)
endif
```

So: the *only* machine-checked requirement is the literal string `ksu_handle_sys_reboot` inside `$(srctree)/kernel/reboot.c`. That's why the user-facing docs say "kernel/reboot.c must contain ksu_handle_sys_reboot" — the Kbuild greps for it. It does **not** verify exec.c/open.c/read_write.c/stat.c at all; a missing execve hook builds fine and fails at runtime (no su, no ksud). Also note in the same legacy Kbuild a `can_umount()` auto-backport into `fs/namespace.c` via `sed -i` when missing (kernel <5.9), i.e. the build *mutates kernel sources* for the umount feature — read it before running builds on a precious tree.

`CONFIG_KSU_MANUAL_HOOK` itself (`kernel/Kconfig`): `depends on KSU && KSU != m` (manual hooks can't work in an LKM — the symbols must exist in vmlinux), `default y if !KPROBES`.

---

## 3. Building KernelSU-Next

### 3.1 Vendored-driver build model

`kernel/setup.sh` clones the KernelSU-Next repo to `$GKI_ROOT/KernelSU-Next/` and symlinks it into `drivers/`:

```sh
curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s legacy
# creates: common/drivers/kernelsu -> ../../../KernelSU-Next/kernel
# appends to drivers/Makefile:  obj-$(CONFIG_KSU) += kernelsu/
# appends to drivers/Kconfig:   source "drivers/kernelsu/Kconfig"
```

The `legacy` argument checks out the `legacy` branch (the non-GKI/manual-hook line — the branch the `v3.2.0-legacy` tag sits on; the default branch is `next`). `kernel/Makefile` in the Next repo is the *external-module* (LKM) build entry (`M=`; with a `check_symbol` step that verifies required ksyms exist in `vmlinux`), while `kernel/Kbuild` serves both in-tree and `KBUILD_EXTMOD` builds (`ifdef KBUILD_EXTMOD` block maps Kconfig symbols to `-D` flags).

### 3.2 Version math and the fallback trap

```make
KSU_GIT_VERSION := $(shell cd $(GIT_ROOT) && git rev-list --count HEAD 2>/dev/null)
KSU_GIT_TAG     := $(shell cd $(GIT_ROOT) && git describe --tags --abbrev=0 2>/dev/null)
...
# v3.3-dev (main):
$(eval KSU_VERSION=$(shell expr 30000 + $(KSU_GIT_VERSION)))
# v3.2.0-legacy:
$(eval KSU_VERSION=$(shell expr 30000 + $(KSU_GIT_VERSION) + 150))
# v3.1.0-legacy: + 119      v3.0.1-legacy: + 77
```

So the Next scheme is `30000 + <commit count> (+ tag-era offset)`; the offset exists so that a tagged legacy snapshot reports *higher* than the plain count of the same tree would on main (manager uses this to compare kernel vs manager versions). **Watch out:** the offset changes per tag, so "30000+commits+200" from some vendored snapshot is plausible but not universal — compute what *your* tree actually reports and hard-pin it if the manager complains. The trap:

```make
$(warning "KSU_GIT_VERSION not defined! It is better to make KernelSU-Next a git repository!")
KSU_VERSION_FALLBACK := 1
ccflags-y += -DKSU_VERSION=$(KSU_VERSION_FALLBACK)
```

If the KSU directory is not a git repo (e.g., you copied files, or the shallow-clone unshallow step fails: `[ -f .git/shallow ] && git fetch --unshallow`), `KERNEL_SU_VERSION` becomes **1**, and the manager will refuse/never match (`ksu_handle_prctl`-era managers required kernel ≥ manager version; today GET_INFO just reports a bogus version and `KERNEL_SU_VERSION_TAG` becomes `v0.0.1`). Always verify at boot: `dmesg | grep -i "KernelSU-Next version"`. If you vendor by copying, add `-DKSU_VERSION=<n>` yourself via your defconfig/Makefile append.

### 3.3 Manager signature hash and package rename

```make
ifndef KSU_NEXT_MANAGER_SIZE
KSU_NEXT_MANAGER_SIZE := 0x3e6          # 998-byte X509 cert
endif
ifndef KSU_NEXT_MANAGER_HASH
KSU_NEXT_MANAGER_HASH := 79e590113c4c4c0c222978e413a5faa801666957b1212a328e46c00c69821bf7
endif

ifdef KSU_MANAGER_PACKAGE
ccflags-y += -DKSU_MANAGER_PACKAGE=\"$(KSU_MANAGER_PACKAGE)\"
endif
ccflags-y += -DEXPECTED_MANAGER_SIZE=$(KSU_NEXT_MANAGER_SIZE)
ccflags-y += -DEXPECTED_MANAGER_HASH=\"$(KSU_NEXT_MANAGER_HASH)\"
```

- `is_manager_apk()` (`kernel/manager/apk_sign.c`) first (if `KSU_MANAGER_PACKAGE` set) matches the package name parsed from the APK path (`get_pkg_from_apk_path()` — second-to-last path segment up to `-<split>`), then verifies the v2 cert hash. With `CONFIG_KSU_DEBUG=y` you get `module_param` `ksu_debug_manager_appid` to force-crown for testing.
- To ship a **renamed manager** (different package name, same official key) you build with `KSU_MANAGER_PACKAGE=com.your.pkg` — this is exactly what SukiSU-Ultra automates with `repack_apk.py` + `repack-config.example.json` (repo root; it re-signs the APK with your keystore and regenerates a config that the CI passes to the kernel build as `KSU_MANAGER_PACKAGE` and the new cert hash/size). KernelSU-Next exposes the same two knobs; there is no `repack_apk.py` in the Next repo itself — its CI (`.github/workflows/build-manager.yml`) builds with official keys only.
- Re-signing with your own key ⇒ you **must** change `KSU_NEXT_MANAGER_HASH`/`SIZE` at kernel build time, or the kernel will never crown your APK. This is the “re-signing breaks the compiled-in hash” coupling.
- `CONFIG_KSU_DISABLE_MANAGER` (Kconfig) removes the check entirely (`is_manager() == root`).

### 3.4 Bumping/vendor-updating a newer Next into a 4.9 tree — checklist

1. **Stay on the legacy line** unless you have GKI-style tooling: `setup.sh … bash -s legacy`, or pin a tag (`v3.2.0-legacy`, `v3.1.0-legacy`, `v3.0.1-legacy`). The `legacy` branch differs from `next` in: manual-hook plumbing (`#ifndef KSU_KPROBES_HOOK` gates everywhere instead of the syscall dispatcher), `kernel/compat/` dir (4.x backports: `close_fd`, `strscpy`, `task_work` shims), `tiny_sulog.c` (heap-buffer sulog instead of the event-queue sulog fd), no `ksuinit`/late-load LKM bootstrapping, and the `KSU_VERSION` offset above.
2. **Re-apply your local deltas** after a bump: the SUSFS dispatcher body inside `kernel/supercall/supercall.c` (your `0xFAFAFAFA` arm), any `KSUD_PATH` changes, your extra commands (§4.4), and any 4.9-specific fixes (e.g. `strlcpy` vs `strscpy`, `get_task_cred` usage).
3. **Re-check the five kernel call sites** still match the hook signatures of the new tree (`ksu_handle_execveat`, `ksu_handle_faccessat`, `ksu_handle_sys_read`, `ksu_handle_stat`, `ksu_handle_sys_reboot` + optional setresuid/input/devpts). Signature drift happens between tags (e.g. upstream added `ksu_handle_stat(int*, const char __user**, int*)` variants; execveat gained the compat `do_execve` call).
4. **Verify the Kbuild gate passes** (`grep -q ksu_handle_sys_reboot kernel/reboot.c`) and grep your defconfig: `CONFIG_KSU=y`, `CONFIG_KSU_MANUAL_HOOK=y`, no `CONFIG_KSU_KPROBES_HOOK`.
5. **Manager compatibility**: UAPI version (`KERNEL_SU_UAPI_VERSION`) must be ≤ the manager's; the manager also gates on kernel version via `KSU_IOCTL_GET_INFO`. When moving v3.0→v3.1→v3.2, `ksu_new_get_allow_list_cmd` / su-session fd appeared (UAPI 3/4) — pair kernel and manager updates.
6. **Only touch, in the kernel tree**: `kernel/reboot.c`, `fs/exec.c`, `fs/open.c`, `fs/read_write.c`, `fs/stat.c`, `kernel/sys.c` (setresuid), `drivers/input/input.c`, `fs/devpts/inode.c`, `fs/namespace.c` (auto `can_umount` backport), plus `drivers/kernelsu` symlink + drivers `Makefile`/`Kconfig`, and your defconfig.

---

## 4. Writing your own kernel-side extensions

### 4.1 Two sanctioned extension surfaces

1. **Feature registry** (`kernel/policy/feature.c` + `uapi/feature.h`) — a feature is a `(id, name, get_handler, set_handler)` registered at init:

```c
/* uapi/feature.h */
enum ksu_feature_id {
    KSU_FEATURE_SU_COMPAT = 0,
    KSU_FEATURE_KERNEL_UMOUNT = 1,
    KSU_FEATURE_SULOG = 2,
    KSU_FEATURE_ADB_ROOT = 3,
    KSU_FEATURE_SELINUX_HIDE = 4,
    /* custom extensions */
    KSU_FEATURE_AVC_SPOOF = 10003,
    KSU_FEATURE_MAX
};

/* kernel/feature/sucompat.c — the template */
static int su_compat_feature_get(u64 *value)  { *value = ksu_su_compat_enabled ? 1 : 0; return 0; }
static int su_compat_feature_set(u64 value)   { ksu_su_compat_enabled = value != 0; return 0; }
static const struct ksu_feature_handler su_compat_handler = {
    .feature_id = KSU_FEATURE_SU_COMPAT, .name = "su_compat",
    .get_handler = su_compat_feature_get, .set_handler = su_compat_feature_set,
};
void __init ksu_sucompat_init(void) { ksu_register_feature_handler(&su_compat_handler); }
```

Registration = the manager automatically gets a Settings toggle (JNI `isSuEnabled/setSuEnabled` → `KSU_IOCTL_GET_FEATURE/SET_FEATURE`), persistence (ksud stores features in `/data/adb/ksu/.feature_config` binary config and re-applies on boot, `userspace/ksud/src/feature.rs`), and the `features` field of `GET_INFO` (`cmd.features = KSU_FEATURE_MAX`). IDs ≥ 10000 are the "custom extension" range (AVC_SPOOF=10003 lives in `kernel/extras.c`).

2. **New ioctl commands** — add `struct ksu_xxx_cmd` + `KSU_IOCTL_XXX = _IOC(...)` in `uapi/supercall.h`, a `do_xxx()` handler in `kernel/supercall/dispatch.c`, an entry in `ksu_ioctl_handlers[]` with the right `perm_check`, and (bump) `KERNEL_SU_UAPI_VERSION` if the change is breaking. Then expose it in ksud (`userspace/ksud/src/ksucalls.rs` + regenerated `ksu_uapi.h`) and/or the manager (`manager/app/src/main/cpp/ksu.cc` + `Natives.kt`).

### 4.2 The reply contract (copy_from_user/copy_to_user discipline)

Follow the existing handlers exactly (`kernel/supercall/dispatch.c`):

- `copy_from_user(&cmd, arg, sizeof(cmd))` first; return `-EFAULT` on failure.
- Outputs are written *back into the same struct* then `copy_to_user(arg, &cmd, sizeof(cmd))`.
- Variable-size outputs use a two-call or pointer-walking protocol — see `ADD_TRY_UMOUNT`: `KSU_UMOUNT_GETSIZE` returns a `size_t` total; `KSU_UMOUNT_GETLIST` pointer-walks NUL-separated strings into one user buffer (`copy_to_user` per entry, "pointerwalking" as the comment says). For allowlists, the caller passes `count` in and the kernel writes `count`/`total_count` back and then copies into `((struct ksu_new_get_allow_list_cmd __user *)arg)->uids`.
- Return `int`/`long` errno; `-ENOTTY` for unknown commands; negative errnos propagate to Rust `bail!`/`ioctl` result and JNI.
- Anything that must not run in atomic context (file I/O for persistence) is deferred via task_work — e.g. `ksu_persistent_allow_list()` uses a `callback_head` (`kernel/policy/allowlist.c:do_persistent_allow_list`).

### 4.3 SUSFS as the reference template for "another project riding the channel"

SUSFS (v2.x, [susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu)) shows the full add-on anatomy you've already mirrored:

- **One hook, many owners:** the SUSFS kernel patch adds to `kernel/reboot.c` `extern int ksu_handle_sys_reboot(...)` and calls it pre-`ns_capable` — the *same symbol* KernelSU defines. When built together, one function handles both magic spaces: `magic1==0xDEADBEEF` (KSU_INSTALL_MAGIC1, shared) and `magic2` selects the sub-protocol: `0xCAFEBABE` = KSU fd-install, `10006/10010/10011/10012` = KSU extensions, `0xFAFAFAFA` = SUSFS (`SUSFS_MAGIC`), whose commands include `CMD_SUSFS_SHOW_VERSION=0x555e1`, `CMD_SUSFS_SHOW_ENABLED_FEATURES=0x555e2`, `CMD_SUSFS_SHOW_VARIANT=0x555e3` (constants verbatim from KernelSU-Next's own client, `userspace/ksud/src/susfsd.rs`).
- **Ordering matters:** the reboot syscall hook returns void-ish (`ret = ksu_handle_sys_reboot(...); if (ret) goto orig_flow; return ret;` in SUSFS's patch). If you keep KSU's and SUSFS's handlers as separate functions, chain them explicitly (KSU handler should fall through on unknown `magic2` — it already `return 0`s, which SUSFS's patch tolerates; be careful if you add your own magic2 to *return nonzero* to signal "handled, skip orig flow" only when you mean to suppress the real reboot). **[Flag: exact precedence between KSU and SUSFS handling of the same magic1 is implementation-defined by whoever compiled `ksu_handle_sys_reboot`; in your tree that is the merged function you maintain.]**
- **Userspace client pattern** (`susfsd.rs`): plain `syscall(SYS_reboot, 0xDEADBEEF, 0xFAFAFAFA, cmd, &mut struct)`, with an `err` field inside the returned struct (`ERR_CMD_NOT_SUPPORTED = 126`) — i.e., **status is returned in the payload, not the syscall return value**, because `reboot()` normally returns whatever the hook leaves in place.
- **Per-feature Kconfig + static keys:** SUSFS gates each feature with `CONFIG_KSU_SUSFS_*` and `#ifdef`s in the VFS paths (`sus_path`, `sus_mount`, opens_by_symlink etc.), plus its own Kconfig menu — same idea as KSU's `CONFIG_KSU_DISABLE_*` + `static_key`-like `__read_mostly` booleans (`ksu_su_compat_enabled`, `ksu_vfs_read_hook`, `ksu_input_hook`, `ksu_execveat_hook`). For a 4.9 tree, prefer `bool __read_mostly` + `unlikely()` guards (what KSU legacy does) over real static keys — the legacy kernels have them but KSU code doesn't use them there.

### 4.4 Adding a new sys_reboot command end-to-end (worked recipe)

1. `uapi/supercall.h`: `static const __u32 MY_CMD = 10020;` (avoid 10006/10010/10011/10012 and 0xCAFEBABE/0xFAFAFAFA).
2. `kernel/supercall/supercall.c` (your merged handler): add an arm like `CHANGE_KSUVER` — root check, do the work, `copy_to_user((void __user *)arg, &reply, sizeof(reply))`.
3. If it needs state, follow the module-state pattern (`ksuver_override` global + `ksu_supercall_cleanup_state()`).
4. Client: a small C tool or Rust `syscall(SYS_reboot, KSU_INSTALL_MAGIC1, MY_CMD, arg, &out)`; remember the caller must be uid 0.
5. Document the magic in your tree's README — the magic2 space is first-come-first-served across the whole ecosystem (KSU, SUSFS, kernels like DS-ACK add their own — **[uncertain: some vendor kernels ride the same channel; grep your kernel's reboot.c before choosing a value]**).

### 4.5 Exposing features to userspace properly

- Kernel-side: prefer the **feature registry** over bespoke magic so the manager UI, persistence (`/data/adb/ksu/.feature_config`), and `ksud` feature checks all work for free. `ksud` applies config at post-fs-data (`feature::init_features()`, `init_event.rs`) and warns per-feature on failure.
- ksud-side: modules can *declare* which features they manage via the module config system: `manage.<feature>=true` entries produce the `managedFeatures` key in `module.prop`-maps (`userspace/ksud/src/module.rs:980`), consumed by `installer.sh` (`grep_prop managedFeatures`) and the manager UI. The canonical `module.prop` string people refer to (`managedFeatures=`) is *generated* from those config entries, but you can also read/parse it in your own tooling.
- Manager-side: `manager/app/src/main/cpp/ksu.cc` (thin `ksuctl()` over the driver fd) + `Natives.kt` external functions; new toggles need a JNI pair + Kotlin UI.

---

## 5. The userspace / manager side

### 5.1 ksud (Rust workspace, `userspace/ksud/`)

- Cargo workspace with per-target builds (aarch64/x86_64 android, plus desktop targets for debugging — `.github/workflows/ksud.yml`). Notable modules: `ksucalls.rs` (driver fd acquisition + all `KSU_IOCTL_*` wrappers, incl. the seccomp-SIGSYS-safe `with_svc_call` wrapper for the reboot install call), `module.rs` (install/uninstall/`list_module` JSON, `managedFeatures` extraction), `metamodule.rs`, `init_event.rs` (boot stages), `feature.rs`, `sepolicy.rs`, `sulog.rs`, `susfsd.rs`, `late_load.rs` (LKM late-load support), `lkm_image.rs` + `lkm_image_bootstrap.S` (GKI ramdisk LKM loading), `resetprop.rs` (prop_rs_android).
- Bootstrap into userspace: kernel injects a `service` line into init's read of `init.rc` (`ksu_handle_sys_read` → `f_op` proxy → `KERNEL_SU_RC` appended, `kernel/runtime/ksud_integration.c`), so `init` starts ksud as a daemon; ksud then reports `EVENT_POST_FS_DATA`/`EVENT_BOOT_COMPLETED`/`EVENT_MODULE_MOUNTED` back into the kernel via ioctls (`do_report_event` → `on_post_fs_data()` / `on_boot_completed()` in the kernel, which flips `ksu_boot_completed` and unmarks hooks). Alternative GKI path: hooking `execve` of init + ksuinit binary (`userspace/ksuinit/`, a `no_main` Rust shim that preps and `execve("/init")`).
- ksud as su server: after the exec redirect, ksud checks allowlist/`root profile` (via `profile.rs` + `KSU_IOCTL_SET_APP_PROFILE`), spawns the shell in the requested mount namespace (`infra/su_mount_ns.c`), and enforces `KSU_IOCTL_DISABLE_ESCAPE_TO_ROOT` (sets `TIF_KSU_DISABLE_ESCAPE_WITH_ROOT`) for scoped sessions.

### 5.2 Manager app (Gradle, `manager/`)

- Kotlin + Compose app (`manager/app/`), package `com.rifsxd.ksunext`. Kernel access is JNI: `manager/app/src/main/cpp/ksu.cc` does `scan_driver_fd()` (readdir `/proc/self/fd`, match link target `[ksu_driver]`) then `ksuctl(KSU_IOCTL_*)`; `Natives.kt` exposes `external fun` for everything (getVersion, allowList, app profiles, feature toggles incl. `isAvcSpoofEnabled`, `getHookMode`, `getVersionTag`, `isZygiskEnabled`, ...). The manager *is* identified by uid-remainder (`is_manager()`), so it needs no fd to be crowned — but it needs the fd to talk.
- Rebuild flow: `./gradlew` (JDK 17) with `manager/sign.example.properties` for signing config. **Signing implications:** a self-built APK signed with anything other than the official key will not be crowned by a stock kernel — you must rebuild the kernel with your cert's SHA-256 (`KSU_NEXT_MANAGER_HASH`/`_SIZE`) and optionally `KSU_MANAGER_PACKAGE`. There is no sanctioned in-repo "reskin" path in KernelSU-Next; the sanctioned customizations are (a) the two Kbuild knobs + your own signing, (b) `CONFIG_KSU_DISABLE_MANAGER` + external control via ksud, (c) SukiSU-Ultra's `repack_apk.py` model if you want a ready pipeline. (Upstream tiann/KernelSU additionally hashes the manager APK path/package at build time — same idea.)

### 5.3 The v3 metamodule architecture

`userspace/ksud/src/metamodule.rs` + `website/docs/guide/metamodule.md`:

- A metamodule is any module with `metamodule=1` in `module.prop`; exactly one active, tracked by symlink `/data/adb/metamodule -> /data/adb/modules/<id>`.
- Hooks it can provide: `metainstall.sh` (replaces the default module installer flow), stage scripts (`post-fs-data`, `service`, `boot-completed`, `post-mount` — run *before* regular modules), and a mount script (`exec_mount_script(module_dir)`) that replaces KernelSU's built-in mounting entirely. **Without a metamodule, modules are not mounted** on fresh v3 installs (the official reference is `meta-overlayfs`; community: Magic Mount-rs, mountify-as-metamodule).
- Regular module uninstall additionally calls `metauninstall.sh` for cleanup. `check_install_safety()` blocks installing regular modules while the metamodule is disabled/odd state.

---

## 6. Module development best practices

Canonical reference: [kernelsu.org module guide](https://kernelsu.org/guide/module.html) (upstream, still accurate for Next) + KernelSU-Next webpage.

- **Stages** (all executed by ksud, `init_event.rs::run_stage` — metamodule script first, then modules):
  - `post-fs-data.sh` — blocking (boot waits, ~10s budget), before mounts/Zygote. **No `setprop` here** (deadlock) — use `resetprop -n`.
  - `post-mount.sh` — after mounting (metamodule ran).
  - `service.sh` — non-blocking, parallel with boot; the default choice for daemons/prop changes.
  - `boot-completed.sh` — after `sys.boot_completed`.
  - `action.sh` — runs on the manager's Action button (`action` flag auto-populated into the module list JSON; `actionIcon=` for the icon).
  - `uninstall.sh`, and installer-time `customize.sh` (`SKIPUNZIP=1`, `ui_print`, `set_perm`, env: `KSU`, `KSU_VER`, `KSU_VER_CODE`, `KSU_KERNEL_VER_CODE`, `KSU_UAPI_VER`, `KSU_RUNTIME_MODE` = `built-in|lkm|late-load`, `KSU_LATE_LOAD`, `MODPATH`, `ZIPFILE`, `ARCH`, `API`, `IS64BIT`; Magisk env is faked at v25.2/25200 for compat).
  - Common dirs: `/data/adb/post-fs-data.d/`, `service.d/`, `post-mount.d/`, `boot-completed.d/` (don't install into these from a module).
- **`system/` tree + `skip_mount`/`disable`/`remove` flag files**; system files removal via `mknod f c 0 0` (or `REMOVE` list), dir replacement via `trusted.overlay.opaque` xattr (or `REPLACE` list); `system.prop` via resetprop; `sepolicy.rule` per line.
- **WebUI**: `webroot/index.html` served by the manager WebView. JS bridge (verified from [KernelSU js/index.js](https://github.com/tiann/KernelSU/blob/main/js/index.js) and Next's `manager/.../webui/WebViewInterface.kt`):
  - `ksu.exec(cmd)` (1-arg, `@JavascriptInterface fun exec(cmd: String): String`) → `ShellUtils.fastCmd` under a fresh root shell → **returns the last line of stdout only** (libsu `fastCmd` semantics).
  - `ksu.exec(cmd, optionsJson, callbackName)` → async; the manager evaluates `callbackName(result.code, stdout, stderr)` — i.e. the callback receives **(errno, stdout, stderr)**; `options` supports `cwd` and `env` (spliced as `cd ...; export K=V;` prefixes).
  - The npm `kernelsu` package wraps this: `exec(command, options) → Promise<{errno, stdout, stderr}>`, plus `spawn()` (streamed), `toast()`, `fullScreen()`, `enableEdgeToEdge()`, `moduleInfo()`, `listPackages()/getPackagesInfo()`, `exit()`. MMKV key-value (`ksu.mmkv`) exists in newer manager builds — **[uncertain: not in the Next WebViewInterface I read; treat as upstream/MMRL-only]**.
- **Kernel-umount vs metamodule mounts:** modules that only run scripts/props/sepolicy need no metamodule; anything touching `/system` needs one.
- **Ecosystem worth reading as code:**
  - [backslashxx/mountify](https://github.com/backslashxx/mountify) — "globally mounted modules via hybrid mount" (overlayfs+tmpfs staging, whitelist/blacklist, `skip_mount` respected, zygisk-provider-aware umount).
  - `meta-overlayfs` (official metamodule), Magic Mount-rs (metamodule implementing Magisk-style mount), [MMRL overlayfs metamodule](https://mmrl.dev).
  - Zygisk providers: [ZygiskNext](https://github.com/Dr-TSNG/ZygiskNext) and [ReZygisk](https://github.com/PerformanC/ReZygisk) — inject into Zygote via root, then provide the Zygisk API; module "zygisk" dirs are consumed by *them*, not by KSU. Their umount behavior is the reference mountify defers to.
  - [sidex15/susfs4ksu-module](https://github.com/sidex15/susfs4ksu-module) — the `ksu_susfs`/`sus_su` userspace addon; also a good example of a module talking to a kernel dispatcher.

---

## 7. Related projects worth studying

- **[tiann/KernelSU](https://github.com/tiann/KernelSU)** — upstream. Different supercall transport (prctl+reboot), different hook stack (kprobe/eBPF-free, syscall-tracepoint), same manager lineage. Read for: the `js/` WebUI library, docs site, and how the reference manager negotiates UAPI.
- **[KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next)** — your base. `legacy` branch = manual-hook line; `next` = dispatcher/tracpoint line. Watch `uapi/supercall.h` and `KERNEL_SU_UAPI_VERSION` — that's the API you extend.
- **[SukiSU-Ultra](https://github.com/ShirkNeko/SukiSU-Ultra)** — aggressive fork with **KPM (Kernel Patch Modules)**: `kernel/kpm/` loads ARM64 ELF kernel modules at runtime (own ELF loader/relocations, `kpm.c`), exposed through extra supercall control codes (`kernel/kpm/kpm.h`, `CMD_KPM_CONTROL`, plus `super_access.c`); also `kernel_compat` for syscall-table patching, and `repack_apk.py` for renamed/re-signed manager distribution. KPM is the closest thing to "loadable kernel-side extensions without rebuilding the kernel" in this ecosystem (SukiSU's KPM is *the* reference; APatch's KPM is the other — **[uncertain on exact cross-compatibility between SukiSU KPM and APatch KPM formats]**).
- **[APatch](https://github.com/bmax121/APatch) / [apatch.dev](https://apatch.dev)** — patches the stock `boot.img` kernel image (no kernel source needed; ARM64-only): KernelPatch adds a new supercall gated by a SuperKey, with inline hooks + syscall-table hooks + KPM; APM modules are Magisk-style. Study for: credential-arcana (SuperKey → root), thread/process hiding (shadow-pid-style stealth), and their kernel-patch format.
- **Magisk** — for contrast: pure userspace, magic mount, `resetprop`, no kernel help; KSU's `installer.sh`/BusyBox "ASH Standalone Mode" and env faking (`MAGISK_VER_CODE=25200`) exist to keep module scripts portable.
- **[susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) (simonpunk)** — the root-hiding kernel patch. Branches per kernel (`kernel-4.9` is the non-GKI line you built against, SUSFS v1.5.x there; `gki-android15-6.6-dev` etc. carry v2.3.0 with the sys_reboot supercall dispatcher). The `50_add_susfs_in_gki-android15-6.6.patch` shows every VFS touchpoint (`sus_path`, `sus_mount`, kstat spoofing, uname spoof via the same `kernel/sys.c`/`reboot.c` seams). Community port for non-GKI 4.14/4.9: [Mafiadan6/SUSFS-NonGKI-Patches](https://github.com/Mafiadan6/SUSFS-NonGKI-Patches).
- **[devnoname120/kernelsu-coccinelle](https://github.com/devnoname120/kernelsu-coccinelle)** — semantic (Coccinelle) patches that auto-insert manual hooks across many old kernels; the standard tool when hand-porting the five call sites is error-prone.
- **The Samsung non-GKI lineage** — DS-ACK kernels (XDA: "[Kernel][G960F/G965F/N960F] DS-ACK", KernelSU-Next reporting version ~33214 + SUSFS v2 on Android 15/16) and the [ExyHyperBrick](https://github.com/ExyHyperBrick) SLSI hardware repos behind Exynos 9810/9820 LineageOS work; also [duhansysl/exynos9810-kernel](https://github.com/duhansysl/exynos9810-kernel) (Linux 4.9.337 + clang). These are the closest public peers to your 4.9.337 setup — their manual-hook diffs and SUSFS dispatcher ports are directly comparable to yours. **[uncertain: DS-ACK's exact KernelSU-Next fork/hook additions are only visible from their XDA threads/source drops]**

---

### Appendix A — cheat sheet: magic numbers and commands (verified from source)

| Constant | Value | Where | Meaning |
|---|---|---|---|
| `KSU_INSTALL_MAGIC1` | `0xDEADBEEF` | `uapi/supercall.h` | reboot-channel selector (shared with SUSFS) |
| `KSU_INSTALL_MAGIC2` | `0xCAFEBABE` | `uapi/supercall.h` | "install driver fd" sub-command |
| `SUSFS_MAGIC` | `0xFAFAFAFA` | `userspace/ksud/src/susfsd.rs` | SUSFS dispatcher sub-protocol |
| `CHANGE_MANAGER_UID` | `10006` | `uapi/supercall.h` | crown appid (root only) |
| `GET_SULOG_DUMP_V2` | `10010` | `uapi/supercall.h` | sulog compat dump |
| `CHANGE_KSUVER` | `10011` | `uapi/supercall.h` | override reported kernel version |
| `CHANGE_SPOOF_UNAME` | `10012` | `uapi/supercall.h` | utsname release/version spoof (3-star pointer protocol) |
| `CMD_SUSFS_SHOW_VERSION/FEATURES/VARIANT` | `0x555e1/2/3` | `susfsd.rs` | SUSFS info commands |
| `KERNEL_SU_UAPI_VERSION` | `4` | `uapi/supercall.h` | must match ksud/manager |
| Manager cert | size `0x3e6`, SHA-256 `79e5…1bf7` | `kernel/Kbuild` | `check_v2_signature` target |
| `KSU_PER_USER_RANGE` | `100000` | `manager_identity.h` | appid = uid % 100000 |

### Appendix B — primary URLs

- KernelSU-Next: https://github.com/KernelSU-Next/KernelSU-Next (releases incl. `v3.2.0-legacy`), webpage docs: https://kernelsu-next.github.io/webpage/ and https://github.com/KernelSU-Next/webpage (`docs/pages/how-to-integrate-for-non-gki.md`)
- Upstream: https://github.com/tiann/KernelSU , docs https://kernelsu.org (`/guide/module.html`, `/guide/how-to-integrate-for-non-gki.html`, `/guide/module-webui.html`), JS bridge https://github.com/tiann/KernelSU/blob/main/js/index.js
- SUSFS: https://gitlab.com/simonpunk/susfs4ksu , module https://github.com/sidex15/susfs4ksu-module
- SukiSU-Ultra: https://github.com/ShirkNeko/SukiSU-Ultra ; APatch: https://github.com/bmax121/APatch , https://apatch.dev
- Ecosystem: https://github.com/backslashxx/mountify , https://github.com/Dr-TSNG/ZygiskNext , https://github.com/PerformanC/ReZygisk , https://modules.kernelsu.org , https://github.com/devnoname120/kernelsu-coccinelle , https://github.com/Mafiadan6/SUSFS-NonGKI-Patches

### Appendix C — flagged uncertainties (summary)

1. The exact `+N` offset in the `KSU_VERSION` formula differs per tag (+77/+119/+150 observed); your "+200" vendored snapshot may be real but is not the current formula.
2. Ordering/precedence between KSU and SUSFS handling inside a merged `ksu_handle_sys_reboot` is undefined-by-construction; it is whatever your merged function does. Keep KSU arms falling through on unknown magic2, and return "handled" deliberately.
3. The `devpts` hook's exact failure mode and its v3.3 status (LSM-based now) — legacy code shows the gate (`__ksu_handle_devpts`, `ksu_su_compat_enabled`), upstream docs show the call site, but the observable breakage without it is anecdotal.
4. `ksu.mmkv` in WebUI — present in upstream/MMRL manager builds; not found in KernelSU-Next's `WebViewInterface.kt` at the commit studied.
5. SukiSU KPM vs APatch KPM module-format compatibility, and the full internals of SukiSU's KPM loading (ELF loader details) are only partially verified (I read `kernel/kpm/kpm.{h,c}` structure, not a full trace).
6. DS-ACK/ExyHyperBrick specifics (which Next fork, which hook set, version 33214) come from XDA/community sources, not from a verified tree.