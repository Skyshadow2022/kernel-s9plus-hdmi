# Phase A — HWC ExternalDisplay on PE (office checklist)

Goal: get Pixel Experience to call `openExternalDisplay()` and feed decon2 via
`S3CFB_WIN_CONFIG` (stock Mirror path). Kernel host patches in this tree:

| Knob / hook | Path | Purpose |
|-------------|------|---------|
| `hpd_wait_ms` (default **12000**) | `/sys/class/dp_sec/hpd_wait_ms` | Wait for HWC before BIST fallback |
| `displayport_hwc_takeover()` | decon2 first BUFFER `WIN_CONFIG` | Cut BIST → live when HWC owns frames |
| `default_idma = VG1` | star2lte DT + runtime remap | Match HWC `DPP_VG1` |
| Reserve win/VG1 from primary | `decon_core.c` | Keep phone UI while DP on |

## On-device probe (root, hub plugged)

```bash
# 1) collect
sh /data/local/tmp/dp_hdmi_debug.sh   # or scripts/dp_hdmi_debug.sh via adb

# 2) live watch
logcat -b all | grep -iE 'ExternalDisplay|openExternalDisplay|Failed to open|hotplug|HPD|displayport'

# 3) expect after plug
cat /sys/class/extcon/extcon0/state          # DP=1
ls -l /dev/graphics/fb1
ls /sys/devices/platform/16050000.decon_t/vsync
dumpsys display | grep -iE 'external|hdmi|displayport'
```

### Pass criteria
- logcat shows `handleHotplugEvent` / `openExternalDisplay` **without** `Failed to openExternalDisplay`
- `dumpsys display` lists an external display
- dmesg may show `HWC takeover: BIST → live for WIN_CONFIG`
- TV shows phone UI (or mirrored layers), not color bars

### Fail → next checks
| Symptom | Likely cause |
|---------|----------------|
| No hotplug log at all | uevent path ≠ `11090000.displayport` / extcon0; HWC built without External |
| `Failed to openExternalDisplay` | fb1 perms / SELinux / vsync node / DP ioctl |
| Hotplug OK, still BIST forever | HWC never issues BUFFER WIN_CONFIG; takeover never runs |
| Open OK, black / FIFO under | BTS / LH / format; compare stock OSS decon |

## PE userspace (outside this kernel repo)

Reference clones under `reference/`:

- HWC: `android_hardware_samsung_slsi-linaro_graphics` → `ExynosHWCModule.h`
  - `DP_LINK_NAME "11090000.displayport"`
  - External: `/dev/graphics/fb1`, vsync `16050000.decon_t/vsync`
  - External DPP: **VG1**, **VGFS0 (VGF0)**, G2D
- Device: `device_samsung_exynos9810-common`
  - `hal_graphics_composer_default.te` needs uevent + `sysfs_displayport_writable`
  - Ensure `ueventd` allows composer on `fb1` / `g2d`

Kernel alone cannot invent SurfaceFlinger external layers — if PE HWC never opens, fix the PE tree next.

## Safe kernel defaults (daily)
```bash
echo 0 >/sys/class/dp_sec/prefer_live
# leave hpd_wait_ms at 12000 unless debugging
# do NOT set prefer_live=1 as default (#31 killed some sinks)
```
