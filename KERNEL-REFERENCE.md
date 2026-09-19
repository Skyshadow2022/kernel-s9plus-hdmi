# star2lte kernel reference

Everything learned about this kernel, its build chain, its module ecosystem and
its failure modes — written so the next piece of work is a build, not an
experiment.

Compiled 2026-09-18 from web research plus first-hand checks against this
machine's kernel tree and Magisk's source. Claims are marked:

- **[V]** verified first-hand — read from source, from this repo's files, or
  from the device
- **[R]** reported by a reliable secondary source, consistent with the evidence
- **[?]** uncertain — verify before relying on it

---

## 1. What this kernel actually is

| | |
|---|---|
| Device | Galaxy S9+ SM-G965F, `star2lte`, SoC `universal9810` |
| SoC | Exynos 9810: 4× Mongoose M3 + 4× Cortex-A55, Mali-G72 MP18 |
| Kernel | **4.9.337** — the final 4.9 stable release |
| Android | 13 (AOSP-based) |
| Root | KernelSU-Next, manual-hook driver |

4.9 predates GKI entirely, so none of the GKI machinery applies. This is a
"legacy" kernel in every tooling sense, and that single fact drives most of the
compatibility notes below.

### Where the source comes from

Samsung's Open Source Release for the S9 stops at **Android 10** (4.9.118 /
4.9.219, trees named `G96xFXX…`). The same SoC shipped again in the **Note10
Lite (SM-N770F, "r7")**, which Samsung took all the way to **Android 13 / One
UI 5.1** on **4.9.191** with defconfig `exynos9810-r7_defconfig`. Every modern
Exynos 9810 tree is that base upmerged to 4.9.337. **[R]**

| Tree | Base | Why it matters |
|---|---|---|
| `opensource.samsung.com` | SOR | the legal origin; JS-only site, tarballs not directly fetchable |
| `exynos-linux-stable/*` | SOR + linux-stable | the classic merge repo (`starlte`, `crownlte`, `N770F_Galaxy-Note10-Lite`) |
| `gussi362/android_kernel_samsung_n770f` | 4.9.191 stock A13 | the Android-13 SOR dump that modern trees derive from |
| `Redminote11tech/exynos9810-kernel` (DS-ACK) | 4.9.337 | most feature-complete live tree: KernelSU-Next + SUSFS + EROFS + BPF backports |
| `ExyHyperBrick/android_kernel_samsung_exynos9810` | 4.9.337 | LOS 20→24 branches, DTBH v2 packer, HDMI test branch |
| `duhansysl/exynos9810-kernel` | 4.9.118/191/337 | upstream of DS-ACK |
| `krazey/android_kernel_samsung_exynos9810` | 4.9.330 / 4.11-testing | still building unofficial LOS 20 for star2lte |
| `LineageOS/android_kernel_samsung_exynos9810` | 4.9.118 | the official LOS 20 tree; useful as the AOSP-contract reference |

**Use these for diffing.** When something behaves oddly, the fastest answer is
usually `git diff` against ExyHyperBrick's `lineage-20` or DS-ACK — those two
carry the same device and the same Android version.

### The classic kernels, and their status

Endurance (Eamo5, stopped 2019), White Wolf (yarpiin, 2022), MoRoKernel
(2020), ElementalX (flar2 — yes, it existed for Exynos S9, branches up to
`3.00` in Dec 2020), TGP, RZ/Phoenix — all dead. **xxTR**
(`xxmustafacooTR/exynos-linux-stable`) is the historically important one: it
exposed the ASV table, per-rail undervolt and the CPU hotplug switches,
releases to v45.4 (2022). It is dead now but its ideas live on in DS-ACK.

**Cruel Kernel, A2N and Quantum never existed for 9810.** CruelKernel only ever
did exynos9820; A2N is 8895/dreamlte. Don't go looking. **[R]**

### SoC quirks that matter for tuning

The DVFS stack is Samsung's own, not `cpufreq`-as-usual:

- `drivers/cpufreq/exynos-acme.c` — "A Cpufreq that Meets Every chipset"
- `drivers/cpufreq/exynos-ufc.c` — "User Frequency Control", the user-facing
  per-domain frequency/voltage interface
- `drivers/soc/samsung/cal-if/` + `asv_exynos9810.h` — the ASV tables
- `drivers/soc/samsung/exynos-hotplug_governor.c`, gated by
  `CONFIG_EXYNOS_HOTPLUG_GOVERNOR=y` **[V]**

That hotplug governor is what offlines big cores and is what the community
blames for jank and for "benchmark-only" clocks. Andrei Frumusanu's AnandTech
piece on the 9810's scheduler/DVFS behaviour is the origin of that whole line
of work — note the article is **no longer archived anywhere reliable**, so
don't cite it, just know the conclusion. **[R]**

The accepted undervolt method (xxTR's guide, still the reference): read the ASV
bin (0–15, higher is better silicon), then step CPU big/little, GPU, MIF and CP
down in −25 mV → −10 mV steps, **with CPU hotplug disabled** (turbo bins cap the
voltage floor), and load-test each step. Failure signatures: MIF → freeze or
colour corruption; CP → no data/Wi-Fi; little cores → shutdown. **[R]**

---

## 2. Building and packaging — and a real bug in the DTB path

### Boot image format

Header **v0** (`ANDROID!`), **no vendor_boot**, **no dtbo partition**, no
dynamic partitions / no `super`. Samsung's own packer, not AOSP's.

```
ANDROID! header (page 2048) → Image → ramdisk (gzip) → second(0) → extra (DTBH)
```

On Samsung this device, the header field at **offset 40** is not
`header_version` — it is the **DTBH size**, pointing at the appended Device Tree
Table blob. That `extra` region is:

```
+0     2048-byte DTBH header page (ASCII "DTBH", platform 0x50a6, subtype 0x217584da)
+2048  raw FDT (d00dfeed)
```

**[V — measured from `out_flash_boot/boot_cur.img`]**

`SEANDROIDENFORCE` is a 16-byte bootloader trailer that suppresses the boot
warning. **Our flashed images don't have it and boot fine** — once Knox is
tripped the marker isn't required. **[V]**

### The DTB bug

`AnyKernel3/` ships `Image` and `dtb`. The AK3 flow is:

1. `split_boot` → `magiskboot unpack` extracts `kernel`, `ramdisk.cpio` and
   `extra` (the DTBH blob) from the device's **current** boot image.
2. AK3 then looks for a device-tree file. `ak3-core.sh:285` resolves a variable
   `dt` from `dt`, `dt.img`, `$SPLITIMG/dt` — **not** from `dtb`. Line 319 is
   `[ "$dt" -a -f extra ] && cp -f $dt extra`, so **with `dt` empty this never
   runs**.
3. `ak3-core.sh:320` copies our `dtb` into SPLITIMG as a file named `dtb`.
4. `magiskboot repack` writes `dtb` as its own region — but **on a header-v0
   image there is no `dtb_size` field**.

That last point is the whole problem. In Magisk's `bootimg.hpp`, `dtb_size` is
implemented only in `dyn_img_v2`, `dyn_img_vnd_v3` and `dyn_img_vnd_v4`.
`dyn_img_v0` has `extra_size` and nothing for `dtb`. **[V — read from
`bootimg.hpp`]**

So the repacked image contains our DTB bytes, appended after the `extra` region,
with **no header field pointing at them**. The bootloader keeps reading the DTBH
blob inherited from the device's previous boot image.

**Consequence: Device Tree changes made in this project have never taken
effect.** That includes the `default_idma = VG1` override in the HDMI work and
anything else done in the `.dts` files. **[V for the mechanism, ? for whether
the bootloader has some fallback that reads the trailing region — worth one
empirical check]**

An independent experiment confirmed the mechanism: repacking with
`kernel + ramdisk.cpio + extra + dtb` leaves `EXTRA_SZ` at its original 303104
and places the new DTB bytes at exactly `extra_end`, unreferenced. **[R]**

#### How to confirm it on the device

After any AK3 flash:

```sh
# on the device, as root
dd if=/dev/block/platform/11120000.ufs/by-name/BOOT of=/data/local/tmp/boot.img bs=4096
# then, on the host, run the parser in this repo
python3 tools/bootimg_dtb.py /data/local/tmp/boot.img AnyKernel3/dtb
```

If it says the `extra` region does not contain your DTB, the bug is live.

#### How to actually ship a DTB

The bootloader reads the **`extra`** region, so that is what has to change. The
region is a DTBH v2 table, and it is now fully decoded:

```
+0    "DTBH"
+4    version (2)
+8    number of entries (1)
+12   SoC marker (9810)
+16   platform  (0x50A6)
+20   subtype   (0x217584DA)
+24   entry: board id / hardware revision (26 = eur_open_26)
+28   entry: unknown, preserved verbatim (255 here)
+32   entry: FDT offset within the region (2048)
+36   entry: FDT footprint, page aligned (301056 for a 300964-byte FDT)
```

**[V — decoded from the real blob; `build_extra()` reproduces the header page
and the FDT byte-for-byte. Only the 92 bytes of trailing padding differ, and the
original's are uninitialised garbage, not meaningful data.]**

Everything except the footprint size is device identity, so the safe procedure
is to keep the header page from the boot image already on the device and swap
only the FDT after it. `tools/bootimg_dtb.py` does exactly that:

```sh
# on the device, save the boot image that is known to work
su -c 'dd if=/dev/block/platform/11120000.ufs/by-name/BOOT of=/sdcard/boot-good.img bs=4096'

# on the host, build the replacement extra region
python3 tools/bootimg_dtb.py --make-extra boot-good.img AnyKernel3/dtb extra.build

# then ship extra.build as 'extra' in the AnyKernel3 staging dir
```

The last step is the one AK3 makes awkward: `split_boot` extracts the device's
`extra` into `$SPLITIMG`, so a shipped `extra` is not automatically in the right
place. Two ways around it:

1. **Add a `customize.sh`** to the AK3 zip that copies `extra.build` into
   `$AKHOME` and have the flash step `cp -f $AKHOME/extra.build $SPLITIMG/extra`
   after `split_boot` and before `flash_boot`.
2. **Name the payload `dt`** instead of `dtb`. `ak3-core.sh:319` is
   `[ "$dt" -a -f extra ] && cp -f $dt extra`, so a file named `dt` is copied
   over `extra` automatically. **But** that copies the raw FDT, not the DTBH
   table — so pair it with option 1's output (i.e. name the *blob* `dt`, not the
   raw `.dtb`). That is the least-effort correct route: one rename plus one
   `--make-extra` run per build.

Never just rename the raw `.dtb` to `dt`: that hands the bootloader a bare FDT
where it expects a DTBH table, which is untested territory on this bootloader.

#### Verify after every flash

```sh
su -c 'dd if=/dev/block/platform/11120000.ufs/by-name/BOOT of=/sdcard/boot-now.img bs=4096'
# pull it, then:
python3 tools/bootimg_dtb.py boot-now.img AnyKernel3/dtb
```

`MATCH` means the DT you built is the DT the bootloader is reading.

---

## 3. KernelSU-Next on 4.9 — and what "Unsupported" really means

### The manager card is an identity check, not a version check

The manager shows **"Unsupported | Not integrated"** and the tooltip says
"Non-GKI kernels are not supported. Integrate KernelSU-Next legacy driver in
your kernel!". That card appears when `Natives.isManager == false`, i.e. when
the **kernel does not recognise the installed APK as its manager**.

The kernel identifies the manager by two things: the APK's signing certificate
(compiled in as `KSU_NEXT_MANAGER_HASH` / `_SIZE` in `kernel/Kbuild`) and the
UID it finds by scanning `/data/system/packages.list` in `track_throne()`. It
then logs `Crowning manager: <pkg>(uid=…)` and remembers that appid.

**Raising the kernel version number does not fix this.** The version gates that
do exist are softer and separate: the manager warns when
`kernel version < 33188`, and when the kernel's UAPI version differs from the
manager's. 33193 and 33250 are both above 33188 and both report UAPI 2. **[V]**

### On this device the problem is already resolved — verified 2026-09-18

```
KernelSU: Found new base.apk at …/com.rifsxd.ksunext-…/base.apk, is_manager: 1
KernelSU: manager pkg: com.rifsxd.ksunext
KernelSU: Crowning manager: com.rifsxd.ksunext(uid=10256)
```

and `ksud debug version` reports `Kernel Version: 33250`, above the installed
manager's versionCode 33214, with UAPI 2 on both sides. **[V]**

One trap found while checking this: the first attempt to grep for those lines
returned **zero** because the dmesg ring buffer had already rotated the boot
messages out. Grep for crowning early, or read it out of a saved `dmesg` taken
right after boot. A zero result late in uptime means nothing.

### If it does come back, look here

```sh
dmesg | grep -iE "Crowning|manager pkg|throne"
```

- **No `Crowning` line at all** → the kernel never matched the APK. Almost
  always because the installed manager APK is **not the official build** — a
  repacked or re-signed APK fails the signature check. Renaming the package is
  fine; re-signing it is fatal.
- **Crowned, but still Unsupported** → the manager is running under a different
  uid than the one crowned (work profile / multi-user). Reinstall in user 0.
- **Escape hatch**: `CONFIG_KSU_DISABLE_MANAGER=y` makes `is_manager()` simply
  `uid == 0` and skips the whole APK-identity mechanism. Legitimate fallback for
  a legacy build. **[V]**

### The version arithmetic

**This tree's** vendored KernelSU-Next uses a formula with a +200 offset on top
of upstream's:

```make
$(eval KSU_VERSION=$(shell expr 30000 + $(KSU_GIT_VERSION) + 200))
```

so `KSU_GIT_VERSION=3050` yields **33250** — which is what `build_gkilike.sh`
predicts and what the device actually reports. Upstream's own Kbuild is
`30000 + <commit count>` with no offset; do not assume the two agree. **[V —
read from `kernel_source/KernelSU-Next/kernel/Kbuild`, and confirmed by
`ksud debug version` reporting 33250 on the device]**

Worth knowing: `KSU_GIT_VERSION` only has an effect when Kbuild's git detection
*succeeded*. If KernelSU is a plain vendored directory inside the kernel git
repo, Kbuild takes the fallback path and reports version **1** regardless of the
variable. `build_gkilike.sh` sidesteps that by passing `KSU_GIT_VERSION_VALID=1`
on the command line. **[V]**

### Required configuration on this kernel

| Symbol | Value | Why |
|---|---|---|
| `CONFIG_KSU` | y | the driver |
| `CONFIG_KSU_MANUAL_HOOK` | **y** | the correct hook strategy below 5.10 |
| `CONFIG_KSU_KPROBES_HOOK` | n | its own Kconfig help says "should not be used on kernel below 5.10" |
| `CONFIG_KPROBES` | y | **`CONFIG_KSU` depends on it in 3.x** — with it off, KSU silently vanishes from `.config` |
| `CONFIG_EXT4_FS` | y | likewise a hard dependency in 3.x (`ext4_unregister_sysfs`) |
| `CONFIG_UH`, `CONFIG_KDP`, `CONFIG_RKP` | **n** | the KernelSU-Next legacy driver hard-errors on these: `#error "CONFIG_UH, CONFIG_KDP and CONFIG_RKP is enabled!"` |

**Our build already satisfies all of these** — `CONFIG_KSU=y`,
`CONFIG_KSU_MANUAL_HOOK=y`, no KPROBES_HOOK, `CONFIG_EXT4_FS=y`. **[V —
`out/.config`]**

The manual-hook build gate is worth knowing: `kernel/reboot.c` must contain a
`ksu_handle_sys_reboot` call or the build dies with "No hooks were defined,
please integrate manual hooks in your kernel". If you ever re-import KernelSU
source, that is the first thing to check. **[V]**

### What 4.9 actually lacks

These are the real backports, and they are all already handled by the driver's
compat layer:

| Missing on 4.9 | Consequence |
|---|---|
| `kernel_read` takes `offset` by value (4.14+ takes `loff_t *`) | the `ksu_kernel_read_compat` wrapper; used by throne tracking and allowlist parsing |
| `path_umount` / `ksym_umount` | "Umount modules" silently no-ops without the polyfill |
| `TWA_RESUME` enum (5.7+) | `task_work_add` takes a bool on 4.9 |
| `copy_from_kernel_nofault` (5.8+) | polyfilled with `set_fs` + `pagefault_disable` |
| `struct seccomp` has no `filter_count` | the filter-release path falls back to `disable_seccomp()` |
| no `CONFIG_LSM`, no `selinux_inode()`/`selinux_cred()` helpers | direct `inode->i_security` / `cred->security` access; no static-call LSM |
| `security_hook_heads` is a plain array, not hlist/static calls | anything written for 5.x LSM layout will not compile |
| fsnotify API is the oldest era (`<4.12`, `void *data`, no `iter_info`) | the package observer takes the oldest code path |

**[V — read from the compat layer]**

---

## 4. SUSFS — status: v2.2.0 ported and BUILT (see HANDOFF 2026-09-19)

Update: the fix below was executed. The working source proved to be the DS-ACK
tree's own v2.2.0 non-GKI backport (official susfs4ksu kernel-4.9 froze at
v1.5.5), applied with 3 hand-fixed hunks, and the KernelSU-Next side ported
from Redminote11tech's `v2.2.0-legacy-susfs` branch. Kernel built with all 10
SUSFS symbols. Details and gotchas in HANDOFF.md — the section below is the
original diagnosis, still accurate.

### Original diagnosis: why the v1.5.5 patch rejects happened

SUSFS is a kernel patch that adds hiding (sus paths, sus mounts, kstat,
uname/cmdline spoofing, open redirect) on top of KernelSU. Kernel-side repo:
`gitlab.com/simonpunk/susfs4ksu`, branch **`kernel-4.9`** (SUSFS v1.5.5,
last commit 2025-02-23 — a real, maintained-ish 4.9 port). Userspace:
`github.com/sidex15/susfs4ksu-module`.

**The rejects in `kernel/rejects/` are explained.** `fs/namespace.c.rej` wants
`alloc_vfsmnt(old->mnt_devname, true, 0)`, `mnt->mnt.susfs_mnt_id_backup` and
IDA allocators for `DEFAULT_SUS_MNT_ID`/`DEFAULT_SUS_MNT_GROUP_ID`. That is the
**4.14/4.19 implementation**, which needs the 5.6+ `mnt_id`/`mnt_group_id`
infrastructure in `struct mount`. The official **`kernel-4.9` patch does not
touch `fs/namespace.c` at all** — it spoofs through `fs/proc_namespace.c`
instead. Files the 4.9 patch does touch: `fs/Makefile`, `fs/internal.h`,
`fs/namei.c`, `fs/open.c`, `fs/proc/base.c`, `fs/proc/task_mmu.c`,
`fs/proc_namespace.c`, `fs/readdir.c`, `fs/stat.c`, `kernel/sys.c`,
`mm/shmem.c`. **[R, and the rejects match exactly]**

So: **a 4.14-class patch set was applied to a 4.9 tree.** Re-derive from the
`kernel-4.9` branch and the rejects disappear. `fs/namei.c.rej` and
`fs/proc/task_mmu.c.rej` are only include-block hunks — cosmetic either way.

The config symbols already in `kernel/fragments/susfs.fragment` all exist in the
official 4.9 patch, so that fragment is fine as written. **[R]**

Practical advice: keep `SUS_PATH`, `SUS_KSTAT`, `SPOOF_UNAME`,
`SPOOF_CMDLINE_OR_BOOTCONFIG`, `OPEN_REDIRECT` — they carry most of the hiding
value. Treat `SUS_MOUNT` + `AUTO_ADD_*` as the risky ones on 4.9, since they
depend on magic-mount behaviour and KernelSU's `source="KSU"` mount
identification. And note SUSFS must be re-applied after **every** KernelSU
source bump — that is the recurring cost. **[R]**

---

## 5. Samsung config landscape

### Protection mechanisms

| Mechanism | Status on this device | Action |
|---|---|---|
| **Knox e-fuse** | already tripped (bootloader unlocked, custom kernel). Permanently loses Knox container, Samsung Pay/Pass, Secure Folder. Not recoverable by any flash. | nothing to do |
| **RKP** (`CONFIG_RKP_*`, `UH_RKP`, `RKP_KDP`, `RKP_NS_PROT`) | enforcement lives outside the OS; our build has none of the symbols **[V]** | leave off |
| **DEFEX** (`CONFIG_SECURITY_DEFEX`) | the `#ifdef` hooks exist all over `fs/exec.c`, `fs/open.c`, `kernel/fork.c`… but **this source drop contains no DEFEX implementation and no Kconfig symbol**, so it is inert **[V]** | leave off |
| **PROCA / FIVE** | `security/proca/`, `security/samsung/five/` — per-process integrity certificates; both compiled out of our build **[V]** | leave off |
| **SDP, TIMA, MST** | present in the tree, off in our build | leave off |
| **DM-Verity** | `CONFIG_DM_VERITY=y` and `_FEC=y` are set, but the fstab mounts `/system` and `/vendor` `ro` with **no verify/AVB flags**, so it is inactive by policy **[V]** | keep the symbols |
| **`CONFIG_SEC_FACTORY`** | off **[V]** | **keep it off** — it gates drivers all over the tree (nfc, usb gadget, muic, gpio, hdcp, dpu dp_logger) |

### The `CONFIG_SEC_*` family

Our build has 55 `CONFIG_SEC*` symbols. Rule of thumb: these are "Samsung BSP
glue that userspace expects".

- **Safe to disable** — the debugging/logging ones (`SEC_DEBUG_*`, `SEC_UPLOAD`,
  `SEC_DUMP_SUMMARY`, `*_BIGDATA`, `*_LOGGER`). But `SEC_DEBUG_LAST_KMSG` is what
  gives you `last_kmsg` after a crash; disabling it makes boot-loop debugging
  harder.
- **Keep** — `SEC_PARAM`, `SEC_SYSFS`, `SEC_REBOOT`, `SEC_EXT`, `SEC_PM*`,
  `SEC_NAD*` (Samsung's boost logic, interacts with the thermal HAL that
  re-clamps your CPU/GPU max), `SEC_SIPC_MODEM_IF`, `SEC_MODEM_SS310AP`,
  `SEC_NFC`, `SEC_HAPTIC`, `SEC_ABC*`, `SEC_DISPLAYPORT_LOGGER` (your HDMI
  work), `SEC_SND_ADAPTATION`.

**[V — from `out/.config` and the Kconfigs]**

### `CONFIG_LOCALVERSION`, VINTF, and the dialog

This one is fully traced and worth writing down, because it is subtle.

Android 13's `libvintf` reads `/proc/version`, then tries
`android::kver::KernelRelease::Parse(..., allow_suffix=true)`. That parser is
literally:

```c
#define KERNEL_RELEASE_PRINT_FORMAT "%" PRIu64 ".%" PRIu64 ".%" PRIu64 "-android%" PRIu64 "-%" PRIu64
```

i.e. it matches **`w.x.y-androidZ-K`** — GKI's release format. If it matches,
libvintf maps `Z` to an FCM level (`androidRelease - 12 + Level::S`, so Android
13 → `Level::T` = **7**) and checks that against the device manifest's
target-level. Ours is 3. Mismatch → `INCOMPATIBLE` — which is literally
`error=1` in `VintfObject.h`. **[V — AOSP source]**

`4.9.337-android13-8-g0123456789ab` matches, so the kernel declared itself a GKI
Android 13 and failed the check every boot. `4.9.337-aosp13-8-g0123456789ab`
does not match, so the kernel level is `UNSPECIFIED` and libvintf falls back to
the manifest. **The fix already in `configs/kernelsu.fragment` is correct.**

Two corollaries: anything with `-android<Z>-<K>` where Z ≥ 12 will be read as
GKI, and `CONFIG_LOCALVERSION` also becomes every module's `vermagic`, so
changing it invalidates every out-of-tree `.ko`. **[V]**

---

## 6. The module ecosystem

### KernelSU-Next v3 does not mount anything by itself

This is the single most important fact about the current module system. Since
KernelSU v3.0 (and KernelSU-Next v3.x) mounting is **delegated to a
metamodule**. Without one installed, modules are installed, listed, and never
mounted. Exactly one metamodule may be active; `ksud` refuses a second. It is
identifiable by `/data/adb/metamodule` → the module dir. **[V]**

We run **mountify v2.0.4** (backslashxx), in manual mode. That is a deliberate
choice and the reasoning is in `CONFLICT-ANALYSIS.md`.

### mountify — the config keys that matter

Config lives at `/data/adb/mountify/config.sh`. **[V]**

| Key | Meaning |
|---|---|
| `mountify_mounts` | **0** = disabled, **1** = manual (only ids in `modules.txt`), **2** = auto (every module with `system/`) |
| `MOUNT_DEVICE_NAME` | defaults to `overlay`; **set it to `KSU`** if you want kernel-side or Zygisk-provider unmount to find the mounts |
| `mountify_custom_umount` | 0 off, 1 `ksu_susfs add_try_umount` per mount, 2 `ksud kernel umount add` |
| `use_ext4_sparse` / `enable_lkm_nuke` | ext4-image mode; **there is no prebuilt nuke `.ko` for 4.9** (the set starts at 4.14), so don't enable nuke here |

**The trap we already hit, confirmed in source:** `post-fs-data.sh` guards the
manual branch with `grep -qv "#" modules.txt`. A file containing only comments
(or nothing) makes that grep fail, and the code **silently falls through to AUTO
with no log line**. A file with a blank line counts as "has contents" and stays
manual. Our `__none__` placeholder line is exactly the right workaround. **[V]**

**Multi-lowerdir: tested, and it works — but with a strange quirk. [V]**

mountify's main mode mounts `lowerdir=<staging>:<realpath>`, which needs two
lower layers. Tested on this device:

```
mount -t overlay -o lowerdir=a:b  overlay m   ->  OK      (both files visible)
mount -t overlay -o lowerdir=a    overlay m   ->  EINVAL
```

Two lower layers work. **A single `lowerdir` fails with `Invalid argument`** —
reproduced three times with freshly created directories, so it is not a stale
mountpoint artifact. This Samsung 4.9 overlayfs appears to require at least two
lower layers in the option string.

The practical reading: mountify's primary mode is viable here, and our choice of
manual mode stays a policy decision rather than a hard limit. But note the
quirk — any hand-written overlay mount on this kernel must pass two lowerdirs,
so a "simplify it to one lowerdir" edit will fail confusingly.

### The alternative metamodules

| Metamodule | Engine | Notes |
|---|---|---|
| **mountify** | OverlayFS, tmpfs or ext4 staging | what we run |
| **Hybrid Mount** | OverlayFS **and** magic mount, per module and per path | config `/data/adb/hybrid-mount/config.toml`; fails fast on same-path conflicts; **use this if you ever need magic mount for specific paths only** |
| meta-overlayfs | OverlayFS + ext4 image | the official reference implementation — **its repo (`KernelSU-Modules-Repo`) is 404 as of 2026-09**, despite being the link in KernelSU's own docs |
| meta-mm | magic mount | same 404 org |
| meta-magic_mount-rs | magic mount in Rust | archived |
| ZeroMount / NoMount | VFS redirection via LKM | no mounts at all; needs kernel integration on <5.10 |

**The overlay-vs-magic-mount distinction is the one that matters for us.** An
OverlayFS metamodule *stacks on top of* the live path, so our hand-built
`/vendor` overlay remains a lower layer and stays visible. A magic-mount
implementation clones the directory into tmpfs and binds it back, which
**replaces the directory mount** — our overlay stops being a mount. Do not let a
magic-mount backend take over `/vendor`.

### Module packaging — much simpler than you'd think

- **`META-INF/com/google/android/update-binary` is not needed.** KernelSU
  explicitly excludes `META-INF/*` when extracting, and no ksud code path looks
  for it. "The simplest KernelSU module installer is just a KernelSU module
  packed as a ZIP file." Our plain zips are correct. **[V]**
- `module.prop` keys: `id`, `name`, `version`, `versionCode`, `author`,
  `description`, plus `updateJson`, `actionIcon`, `webuiIcon`, and the markers
  `metamodule=1` and `managedFeatures=`. KernelSU-Next relaxes the `id` regex to
  allow a leading digit. **[V]**
- Lifecycle: `ksud module install <zip>` always extracts to
  `/data/adb/modules_update/<id>` and creates an `update` marker; **the module
  only becomes live after a reboot**, when `modules_update` is promoted over
  `modules`. Markers are `disable`, `remove`, `update`, `skip_mount` (plus
  mountify's `skip_mountify`). **[V]**
- Script order: `post-fs-data.d` → metamodule `post-fs-data.sh` → module
  `post-fs-data.sh` → `system.prop` → **metamodule `metamount.sh` (mounts happen
  here)** → `post-mount.d` → `service.sh` → `boot-completed.sh`. Anything that
  must influence mounting has to be in `post-fs-data.sh`; anything that needs to
  *see* mounted files must be in `post-mount.sh` or later. **[V]**
- Scripts run in KernelSU's busybox ash with `MODDIR=${0%/*}` and `KSU=true`.
  `MAGISK_VER_CODE` is hardcoded to 25200 — never use it for detection.

### The WebUI bridge — and a better way to do what we did

The manager injects a JS object named **`ksu`**. Three relevant forms: **[V]**

```js
ksu.exec(cmd)                                  // sync, returns String
ksu.exec(cmd, optionsJson, callbackName)       // async
ksu.spawn(command, argsJson, optionsJson, cb)  // streaming
```

**`ksu.exec(cmd)` with one argument is libsu's `ShellUtils.fastCmd`, documented
as returning the *last line* of output with no exit code.** That is exactly the
limitation that forced the `;;`-joined single-line format in our modules'
output.

**The async form has no such limit.** The manager runs the command and injects
`callback(errno, stdout, stderr)` where stdout is the **full output joined by
newlines** and `errno` is the real exit code:

```js
ksu.exec('sh /path/audit.sh report', '{}', 'onDone');
function onDone(errno, stdout, stderr) { /* full multi-line stdout */ }
```

So the `;;` trick is a workaround for the wrong API. New WebUIs should use the
callback form and get proper multi-line output plus exit codes. The `kernelsu`
npm package (v3.0.2) wraps this as `const {errno, stdout} = await exec(cmd)`.

KernelSU-Next also adds file helpers that upstream lacks: `writeFile(path,
content)`, `readFile`, `listFile`, `removeFile`, `moveFile`, `copyFile`,
`moduleInfo()`, `toast()`, `createShortcut()`. Feature-detect before using them.
And **`localStorage` is lost if the manager is uninstalled** — persist to the
module dir. **[V]**

---

## 7. Ready-made modules worth knowing

### The repository problem

The KernelSU-Next manager's built-in browser is the live one, fed by
`KernelSU-Next/KernelSU-Next-Modules-Repo` (`modules.json`,
`non_free_modules.json`, `meta_modules.json`). The "official" modules.kernelsu.org
is currently a 404 GitHub Pages site. **[V]**

### The ones that matter for this device

| Module | What it is | Note |
|---|---|---|
| **PlayIntegrityFork** (osm0sis) v18 | PIF for <A13 integrity | what we already have; needs a Zygisk provider |
| **PlayIntegrityFix [INJECT]** (KOWX712) v4.7 | maintained continuation of chiteroman's PIF | chiteroman's original repo is 404 |
| **TrickyStore** (5ec1cff) v1.4.1 | keystore/keybox spoofer | pairs with Tricky Addon's target list |
| **Zygisk Next** | the Zygisk provider | **repo is 404 as of 2026-09-17**; our installed 1.4.3 keeps working but there is no update channel |
| **ReZygisk** (PerformanC) v1.0.0 | GPL-3.0 Zygisk implementation | the safe replacement for Zygisk Next |
| **NeoZygisk** (JingMatrix) v2.4 | ptrace-based zygote injection | alternative |
| **LSPosed** | ART hooking | last official v1.9.2; the active line is now **JingMatrix/LSPosed → "Vector" v2.2** |
| **HMA-OSS** (frknkrc44) | Hide My Applist, maintained fork | Dr-TSNG's original is 404; we run `hma_oss_zygisk` |
| **Shamiko** v1.2.5 | deny-list/unmount helper | **not Magisk-only** — supports KernelSU 11903+ |
| **Zygisk Assistant** v2.1.4 | alternative to Shamiko | |
| **System App Nuker** | debloater that emits **proper whiteouts** | the one mountify recommends |
| **De-Bloater** | debloater that writes dummy text files | **breaks under overlayfs metamodules** — mountify blacklists its module id |
| **KnoxPatch** (salvogiangri) v0.8.3 | LSPosed module reviving Samsung apps on rooted devices | Secure Folder, Samsung Health, SmartThings, Auto Blocker. Not Samsung Pay/Pass |
| **susfs4ksu-module** (sidex15) | userspace side of SUSFS | only if the kernel is patched |

**Rule: exactly one Zygisk provider, one Play Integrity fix, one hosts module,
one metamodule.** Most "module conflicts" people hit are just two modules doing
the same job.

---

## 8. The conflict taxonomy

Written up fully in `overlay-audit/CONFLICT-ANALYSIS.md`; the short version, now
with the general mechanism behind each:

1. **Two modules shipping the same path.** With mountify, all modules are copied
   into one shared staging dir in a loop, so **the alphabetically last module id
   wins, silently**. Hybrid Mount, by contrast, fails the planning stage.
2. **Magic mount vs OverlayFS layering.** OverlayFS stacks; magic mount
   replaces the directory mount. A magic-mount metamodule touching `/vendor`
   would flatten our hand-built overlay.
3. **Whiteouts.** A real whiteout is `mknod <path> c 0 0` (optionally plus
   `trusted.overlay.whiteout`); replacing a directory needs
   `trusted.overlay.opaque`. Dummy text files are not whiteouts. Magisk's
   `.replace` is a third, different thing.
4. **Metamodule ordering.** Exactly one metamodule; mounts happen in
   `metamount.sh`, which is after every `post-fs-data.sh` and before
   `post-mount.sh`.
5. **Read-only erofs partitions.** `/vendor` is **erofs** (note: `/system` on
   this device is **ext4**). erofs has no write support at all, so the only
   options are overlay/bind. The upper layer must live on a writable fs — and
   never in `/data` as the overlay source, because f2fs casefolding makes
   overlayfs reject it (`ovl_dentry_weird`).
6. **Kernel `.ko` files in modules.** Version-specific, vermagic-specific, and
   there is no 4.9 build of the common ones.
7. **Feature conflicts.** KernelSU-Next supports `managedFeatures=` in
   `module.prop`; the installer runs `ksud feature check` and reports "already
   MANAGED by another module".

---

## 9. Device-specific breakages

### Touch (`sec_ts`)

Firmware name comes from the device tree:

```
star2lte: sec,firmware_name = "tsp_sec/y761_star2.fw", "tsp_sec/y761_star2.fw";
starlte:  sec,firmware_name = "tsp_sec/y761_star1.fw", "tsp_sec/y761_star1.fw";
```

**[V — local `.dts` files]**

This resolves the orphan we found in the overlay: **`y761_star1.fw` is the S9
(SM-G960F) firmware, not the S9+'s.** It is not needed on star2lte at all. It is
harmless, so it stays — but now it is understood rather than mysterious.

If the firmware file is missing when the driver probes, touch never comes up.

**The driver is built as a module in the current tree** — `out/.config` has
`CONFIG_TOUCHSCREEN_SEC_TS=m` — **but the running kernel has no loaded modules
at all** (`/proc/modules` empty) while `sec_ts 4-0048` is alive in dmesg. So the
kernel actually running has touch built in, and the config in `out/` is for a
build that would ship it as a module. **[V for both facts; ? for which build is
which]**

That is a live hazard worth stating plainly: **if you flash a kernel built with
`CONFIG_TOUCHSCREEN_SEC_TS=m`, touch will only work if a `sec_ts_drv.ko`
matching that exact build is present at `/system/lib/modules/`.** This is the
"touch module rename trap" in `HANDOFF.md`, now with its cause.

### The `module_layout` mismatch

`CONFIG_MODVERSIONS=y`, so a module carries a CRC for `module_layout` derived
from `struct module`'s layout. A module built from a different tree or config
fails with:

```
sec_ts_drv: disagrees about version of symbol module_layout
insmod: failed to load …: Exec format error
```

Note this is the **CRC** check, not the vermagic string check — a vermagic
mismatch says `version magic … should be …` instead. `CONFIG_MODULE_FORCE_LOAD`
is off, so there is no `insmod -f`. The only fixes are: rebuild from the same
tree/config/compiler, or make the driver builtin. **[V]**

### Audio

`audio_hw_proxy_9810` is **not a kernel driver** — it is the userspace HAL
(`libaudioproxy`). The kernel side is `sound/soc/samsung/abox/`. The failure we
hit (`cannot find Mixer Control` → `loadHwModule() error -22` → `-19 ENODEV` per
app → 2-second `AudioService` retry loop → the lag) was caused entirely by
shadowed files under `/vendor`. **[V, and the engine search confirms there is no
such kernel driver]**

### Display

`drivers/video/fbdev/exynos/dpu_9810/` — the legacy fbdev + DPU stack, **no
DRM/KMS**. DisplayPort lives at `decon_displayport.c` / `displayport_drv.c`.
Given §2, **any DT change for the HDMI work has not been reaching the
bootloader** — fix the DTB path before spending more time on DECON2.

---

## 10. What to do next, in order

1. ~~Verify the DTB path~~ — **done 2026-09-18, and it was broken.** The live
   boot image carried the same DTB across at least two kernel flashes, and a
   structural diff against the freshly built DTB showed exactly one functional
   difference: `/decon_t@0x16050000:default_idma` 1 → 3 (VG1). A corrected boot
   image was built and flashed, and `/proc/device-tree/…/default_idma` now reads
   `00000003` on the running device. The build now assembles `AnyKernel3/dt` as
   a proper DTBH blob so this cannot silently regress. See §2.
2. **Fix the SUSFS patch source** (§4) — switch to `kernel-4.9` v1.5.5 and the
   `fs/namespace.c` rejects disappear. Now the largest remaining known-broken
   item.
3. **Set `MOUNT_DEVICE_NAME="KSU"`** in `/data/adb/mountify/config.sh` if any
   unmount/hiding story is ever built on these mounts.
4. **Replace Zygisk Next** with ReZygisk when convenient; its upstream is gone.
5. **Consider KnoxPatch** if Samsung apps matter.
6. **Use the callback form of `ksu.exec`** in any new WebUI (§6) instead of the
   `;;` workaround.

Already resolved and no longer on the list: the KernelSU manager identity issue
(§3) and the multi-lowerdir question (§6).

---

## Sources

Kernel trees and repos are listed in §1. Key primary sources read while
compiling this:

```
AOSP libkver/kernel_release.cpp, libvintf/RuntimeInfo.cpp, Level.h, VintfObject.h
Magisk native/src/boot/bootimg.cpp, bootimg.hpp
KernelSU-Next kernel/Kbuild, kernel/Kconfig, kernel/manager/*, userspace/ksud/src/module.rs
KernelSU docs: non-GKI integration, difference-with-magisk, metamodule
gitlab.com/simonpunk/susfs4ksu branch kernel-4.9
github.com/backslashxx/mountify (v2.0.4)
Local: kernel-s9plus/out/.config, AnyKernel3/, out_flash_boot/boot_cur.img,
       kernel_source/arch/arm64/configs/*, dts/exynos/exynos9810-star2lte_*.dts
```
