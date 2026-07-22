# kernel-s9plus-hdmi

Galaxy S9+ (`star2lte` / SM-G965F, Exynos 9810) — Pixel Experience / AOSP 13  
USB-C hub HDMI (VIA Labs) → Sony TV. **No DeX** — PE/kernel path only.

## Status (2026-07-23)

| Item | State |
|------|--------|
| Hardware link / EDID | OK (Sony TV) |
| BIST color bars / solid red | OK |
| Live DECON **winmap** red | OK on `#35` (`prefer_live=1` + `bist=0`) |
| Real phone UI on TV (fb1 DMA / mirror) | **Blocked** — first pan OK, then `VIDEO FIFO_UNDER_FLOW` + DECON2 timeout |
| Phone UI with hub | OK (do not steal G1; DP uses VG1) |

### Flash zips in this repo
- `Kernel-star2lte-gkilike-STABLE.zip` — **`#29`** proven daily (BIST red)
- `Kernel-star2lte-gkilike-NEXT.zip` — **`#35`** experiment (safe HPD→BIST, winmap live, DMA still broken)
- `out_modules/hdmi-mirror-v1.3.zip` — single-pan + mmap updates (needs working DMA)

Details: [`HDMI_READY.md`](HDMI_READY.md)

## Office setup (clone & continue)

```bash
git clone git@github.com:Skyshadow2022/kernel-s9plus-hdmi.git
# or: gh repo clone Skyshadow2022/kernel-s9plus-hdmi
cd kernel-s9plus-hdmi

# Toolchain (adjust paths)
export PATH="/path/to/clang/bin:/path/to/gcc-arm64/bin:$PATH"

# Build
./build_gkilike.sh
# → Kernel-star2lte-gkilike-YYYYMMDD-HHMM.zip
```

ADB: platform-tools + ethernet/`adb tcpip` while hub owns USB-C.

### Safe sysfs on device (root)
```bash
echo 0 >/sys/class/dp_sec/prefer_live
echo 1 >/sys/class/dp_sec/bist    # color bars
echo 4 >/sys/class/dp_sec/bist    # solid red BIST (no DECON)
echo 1 >/sys/class/dp_sec/prefer_live
echo 0 >/sys/class/dp_sec/bist    # live winmap red
```

### Next engineering focus (DeX-pattern)
See **[`docs/DEX_PATTERN.md`](docs/DEX_PATTERN.md)** — stop relying on `hdmi_mirror` pan; follow stock HWC ExternalDisplay (`openExternalDisplay` + `S3CFB_WIN_CONFIG`). Reference trees under `reference/`.

## Layout
```
kernel_source/     Exynos9810 kernel (PE thirteen base + local HDMI patches)
AnyKernel3/        flash packaging
vendor_modules/    hdmi-mirror, dp-hdmi-helper
configs/           gkilike / DP fragments
build_gkilike.sh   build + zip
HDMI_READY.md      test notes
```

Upstream kernel base: [PixelExperience-Devices/kernel_samsung_exynos9810](https://github.com/PixelExperience-Devices/kernel_samsung_exynos9810) (`thirteen`).
