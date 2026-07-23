# HDMI / DisplayPort — S9+ PE (no DeX)

## Stable rollback (proven BIST red)

| File | Build |
|------|--------|
| **`Kernel-star2lte-gkilike-STABLE.zip`** | `20260723-0117` / **`#29`** |

## Current experiment

| File | Build |
|------|--------|
| **`Kernel-star2lte-gkilike-NEXT.zip`** | `20260723-1546` / **`#36`** (HWC host) |
| Module | `out_modules/hdmi-mirror-v1.3.zip` |

### What works on #35/#36
- HPD → **BIST** (no auto live-kick; `#31` killed the sink)
- `prefer_live=1` + `bist=0` → **live winmap red**, `FIFO_UNDER` ≈ 0
- Solid red BIST (`bist=4`) recovery
- **#36 only:** HPD waits **12s** for HWC; first BUFFER `WIN_CONFIG` cuts BIST via `displayport_hwc_takeover`; DP `default_idma=VG1`
### Blocker for real UI
- First `FBIOPAN_DISPLAY` on fb1 returns OK, then continuous **VIDEO FIFO_UNDER_FLOW** + DECON2 timeout
- Tried: VGF1 → VG1, single-pan mirror, MIF boost, live_trig on/off — DMA scanout still starves
- Winmap (no DRAM) is fine; pan path is **not** how stock DeX/Mirror feeds frames

**Pivot:** follow stock HWC ExternalDisplay — see [`docs/DEX_PATTERN.md`](docs/DEX_PATTERN.md), [`docs/HWC_PHASE_A.md`](docs/HWC_PHASE_A.md), and `reference/`.

### Kernel host for HWC (unreleased until next flash zip)
- HPD wait for HWC: `/sys/class/dp_sec/hpd_wait_ms` (default **12000**)
- First decon2 BUFFER `WIN_CONFIG` → `displayport_hwc_takeover()` cuts BIST → live
- star2lte DT `default_idma = VG1` (matches HWC `DPP_VG1`)

### Safe sysfs
```bash
echo 0 >/sys/class/dp_sec/prefer_live
echo 1 >/sys/class/dp_sec/bist    # bars
echo 4 >/sys/class/dp_sec/bist    # solid red BIST
echo 1 >/sys/class/dp_sec/prefer_live; echo 0 >/sys/class/dp_sec/bist  # live winmap red
# optional: echo 15000 >/sys/class/dp_sec/hpd_wait_ms
```
