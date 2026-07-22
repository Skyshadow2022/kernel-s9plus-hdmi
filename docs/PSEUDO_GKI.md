# Pseudo-GKI (GKI-like) for star2lte

This tree is **not** Google GKI / Android Common Kernel KMI.

## What it is

A **GKI-like packaging** on the existing Linux **4.9.337** Exynos9810 vendor kernel:

- **Core** stays inside `Image` (clocks, UFS, USB/ADB, DECON display, S6E3HA8 panel, binder, …)
- **Vendor modules** are built as `.ko` and packaged for load after boot

## Modules

| Driver | Status | Notes |
|--------|--------|-------|
| Touch `sec_ts` | `=m` (`sec_ts_drv.ko`) | Loaded by `ak3-helper` |
| Wi-Fi `BCM4361` / `dhd` | optional `=m` | `ENABLE_WIFI_MODULE=1 ./build_gkilike.sh` — validate WLAN before daily use |
| Camera / DECON | built-in | Not modularized (deep ISP/DECON coupling) |

Touch firmware `tsp_sec/y761_star2.fw` is packaged under AnyKernel `modules/system/vendor/firmware/`.

After flash, if FBE blocks Magisk helper in recovery, restore helpers:

```bash
./scripts/install_persist_helpers.sh
```

## KernelSU-Next (legacy)

Uses **KernelSU-Next legacy** (not official tiann v3 on 4.9). Manager: `com.rifsxd.ksunext`.

Manual hooks: `fs/exec.c`, `fs/open.c`, `fs/read_write.c`, `fs/stat.c`, `kernel/reboot.c`, `drivers/input/input.c`, `path_umount` in `fs/namespace.c`, SELinux `is_ksu_transition`.

**SuSFS:** not integrated — known fragile on 4.9 with recent KSUN legacy. Rely on built-in `selinux_hide` / `kernel_umount` / Zygisk+HMA instead.

## DisplayPort / USB-C HDMI

Kernel DP stack is enabled (`CONFIG_EXYNOS_DISPLAYPORT`, CCIC alt-mode, HDCP2). Helper module `dp-hdmi-helper` pokes `/sys/class/dp_sec`. After plugging a hub:

```bash
adb root
adb shell sh /data/local/tmp/dp_hdmi_debug.sh
```

## LOCALVERSION

`-decon-gkilike-ksun-dp` (see `configs/kernelsu.fragment`).

## Perf / net fragments

- `configs/perf_net.fragment` — BBR + fq/fq_codel
- `configs/perf_batt.fragment` — schedutil default, EAS, CFQ, thermal/ACPM
- `configs/displayport.fragment` — DP logger + deps

## Rollback

`Kernel-star2lte-20260626-2356.zip` (monolithic `4.9.337-decon-custom`)

## Build

```bash
./build_gkilike.sh
# optional Wi-Fi module pilot:
ENABLE_WIFI_MODULE=1 ./build_gkilike.sh
```

## Non-goals

- No ACK 5.10/5.15/6.1 port
- No `vendor_boot` / official `libgki`
- No full camera modularization without a dedicated milestone
