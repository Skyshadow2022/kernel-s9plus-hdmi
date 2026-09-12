# Tune / gaming handoff — 2026-09-13

Continue from another machine: clone branch **`tune-2026-09-12`**, read this file first.

Remote: https://github.com/Skyshadow2022/kernel-s9plus-hdmi  
Companion module: https://github.com/Skyshadow2022/star2lte-tune (or local `/home/mehran/star2lte-tune`)

---

## Currently flashed (after this session)

| Item | Value |
|------|--------|
| Zip | `Kernel-star2lte-gkilike-NEXT.zip` (copy of dated gaming build) |
| uname | `4.9.337-aosp13-8-g0123456789ab` |
| Build | `#68+` (HZ=300 gaming fragment) |
| KSU | version **33250** (`KSU_GIT_VERSION=3050`) |
| VINTF dialog | **fixed** (see below) |
| Module | `star2lte_tune` PROFILE=**gaming** |

Flash on device (rooted adb):

```bash
adb push Kernel-star2lte-gkilike-NEXT.zip /data/local/tmp/ksu_flash.zip
adb shell 'mount -t tmpfs tmpfs /tmp; cd /data/local/tmp && rm -rf ak3 && mkdir ak3 && cd ak3 && unzip -o ../ksu_flash.zip >/dev/null && BOOTMODE=true sh META-INF/com/google/android/update-binary 3 0 /data/local/tmp/ksu_flash.zip'
adb reboot
```

After reboot: physically unplug/replug USB-C hub if testing HDMI/DP.

---

## Root-cause fixes this session

### 1. Manufacturer dialog (`Vendor interface is incompatible, error=1`)

**Cause:** `CONFIG_LOCALVERSION=-android13-8-g0123456789ab` made `uname -r` look like a **GKI** release (`w.x.y-androidZ-K`). `libvintf`/`libkver` parsed Android 13 → FCM level 7 while device manifest is `target-level=3` on legacy 4.9 → `Build.isBuildConsistent()` failed every boot.

**Fix:** `configs/kernelsu.fragment` → `LOCALVERSION=-aosp13-8-g0123456789ab` (does not match GKI regex). Verified: `vintf_err=0`, `DIALOG=ABSENT`.

FCM Magisk overlay under `star2lte_tune/system/etc/vintf/` does **not** mount on KernelSU without Magic Mount — keep as optional, not required.

### 2. KernelSU Manager Unsupported

- Pin `KSU_GIT_VERSION=3050` → kernel reports **33250** (≥ manager 33214).
- Always build with `./build_gkilike.sh` (plain `make` falls back to version 1).
- 4.9 APK crown: `ksu_kernel_read_compat`, EOCD via `i_size_read`, `track_throne(false)` on `<5.9` in `boot_event.c` / `lsm_hooks.c`.

### 3. Mobile data / no internet icon

Fake APNs (`Speedtest`/`Speedup`) left LTE registered but `rmnet` down. Prefer `mcinet` / `mtnirancell` in `service.sh`.

### 4. Clash Royale

Anti-tamper (`oynorr.aI: 16`). Needed `user` fingerprints + temporarily disable noisy Zygisk modules; keep fingerprints synced in module scripts.

---

## Gaming / speed tune (new)

### Kernel fragment `configs/perf_gaming.fragment`

- `HZ=300` (was 250) — tighter timers for touch/UI/games loops
- `CONFIG_SCHED_AUTOGROUP=y` — foreground vs background separation

Already present and kept: schedutil default, BBR+fq, ION/RBIN drop, zram writeback.

### Runtime module (`star2lte-tune`) PROFILE=gaming

| Knob | Gaming default | Why |
|------|----------------|-----|
| Big cluster max | **2314 MHz** (silicon 2704, HAL was 1794) | COD needs Mongoose headroom; full 2704 thermal-throttles hard |
| schedutil up_rate | **1000 µs** | Faster DVFS ramp on burst frames |
| GPU min | **338 MHz** Mali-G72 | Avoid clock-from-zero stutter |
| GPU poweroff_delay | **5** | Less cold-start hitch |
| swappiness | **60** | Less anon thrash mid-match |
| TCP | BBR + fq + larger rmem/wmem + TFO | Online COD / Wi-Fi |

Thermal HAL re-clamps max freq — `service.sh` re-runs `tune.sh` every 30s then every 5 min.

Override without rebuild: edit `/data/adb/star2lte_tune.conf`:

```sh
PROFILE=balanced          # or battery
BIG_MAX_FREQ=2106000
GPU_MIN_CLOCK=299000
UNLOCK_BIG_CORES=0
```

---

## Research notes (Exynos 9810 kernels)

| Tree | Focus | Applied? |
|------|--------|----------|
| AndreiLux / AnandTech 9810 | Hotplug murdered perf; keep cores online + sane DVFS | Partial — we unlock big max; do not port full power-limiter patches yet |
| DS-ACK / Redminote11tech | KSU-Next + SuSFS, OneUI7, permissive | No SuSFS/permissive (PE + Clash risk) |
| xxTR / galaxybuild | OC/UV, Clang20, OneUI | No OC tables (stability on PE) |
| AOSP android-4.9 base | OWNER=y, QTAGUID=n, BPF | `vintf_aosp.fragment` |

**Known remaining risk:** device RAM ~5.2 GB with ~100 MB free under load — COD will still pressure zram. Closing background apps helps more than further governor tweaks.

**HDMI/DP:** still blocked on DECON2 blender/OUTFIFO handshake (`SOLID_ANALYSIS.md`). Gaming tune does not address that.

---

## Build

```bash
export PATH="/home/mehran/toolchains/clang/bin:/home/mehran/toolchains/gcc-arm64/bin:$PATH"
cd /home/mehran/kernel-s9plus
./build_gkilike.sh
# produces Kernel-star2lte-gkilike-YYYYMMDD-HHMM.zip
cp -av Kernel-star2lte-gkilike-*.zip Kernel-star2lte-gkilike-NEXT.zip  # last one
```

Fragments applied in order (later wins): touch → ksu → dp → net → batt → **gaming** → mem_ion → vintf.

---

## Verify checklist after flash

```bash
adb shell uname -r                    # must be *-aosp13-8-* NOT *-android13-8-*
adb shell 'logcat -d | grep -c "Vendor interface is incompatible"'   # 0
adb shell 'cat /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq'  # ~2314000 with gaming
adb shell 'cat /sys/kernel/gpu/gpu_min_clock'   # 338000
adb shell 'cat /proc/sys/net/ipv4/tcp_congestion_control'  # bbr
adb shell 'getprop | grep fingerprint' | head   # all user/release-keys
```

---

## Tomorrow — suggested next steps

1. Play COD Mobile 10–15 min; note thermal (`/sys/kernel/gpu/gpu_tmu`) and frame hitching.
2. If too hot: `PROFILE=balanced` or `BIG_MAX_FREQ=2106000` in conf.
3. If still stutter: try `BIG_MAX_FREQ=2496000` briefly; watch throttle.
4. Optional: Magic Mount so FCM overlays work (not needed for dialog anymore).
5. HDMI path: resume `SOLID_ANALYSIS.md` / DECON2 frame-done — separate from gaming tune.
