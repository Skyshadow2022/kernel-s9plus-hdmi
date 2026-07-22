# HDMI / DisplayPort — S9+ PE (no DeX)

## Stable rollback (proven BIST red)

| File | Build |
|------|--------|
| **`Kernel-star2lte-gkilike-STABLE.zip`** | `20260723-0117` / **`#29`** |

## Current experiment

| File | Build |
|------|--------|
| **`Kernel-star2lte-gkilike-NEXT.zip`** | `20260723-0233` / **`#35`** |
| Module | `out_modules/hdmi-mirror-v1.3.zip` |

### What works on #35
- HPD → **BIST** (no auto live-kick; `#31` killed the sink)
- `prefer_live=1` + `bist=0` → **live winmap red**, `FIFO_UNDER` ≈ 0
- Solid red BIST (`bist=4`) recovery

### Blocker for real UI
- First `FBIOPAN_DISPLAY` on fb1 returns OK, then continuous **VIDEO FIFO_UNDER_FLOW** + DECON2 timeout
- Tried: VGF1 → VG1, single-pan mirror, MIF boost, live_trig on/off — DMA scanout still starves
- Winmap (no DRAM) is fine; VGF/VG DMA path is not

### Safe sysfs
```bash
echo 0 >/sys/class/dp_sec/prefer_live
echo 1 >/sys/class/dp_sec/bist    # bars
echo 4 >/sys/class/dp_sec/bist    # solid red BIST
echo 1 >/sys/class/dp_sec/prefer_live; echo 0 >/sys/class/dp_sec/bist  # live winmap red
```
