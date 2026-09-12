# Office sync

Remote (public): https://github.com/Skyshadow2022/kernel-s9plus-hdmi

```bash
git clone git@github.com:Skyshadow2022/kernel-s9plus-hdmi.git
cd kernel-s9plus-hdmi
git checkout tune-2026-09-12
```

SSH key used on the bring-up machine: `~/.ssh/id_ed25519_github`  
(or whatever account key you registered at https://github.com/settings/keys).

## Read first

- **[docs/TUNE_HANDOFF_2026-09-13.md](docs/TUNE_HANDOFF_2026-09-13.md)** — VINTF dialog root cause, gaming tune, flash/verify, tomorrow steps
- `SOLID_ANALYSIS.md` / `DEBUG_STATE.md` — HDMI/DP remaining blocker (unchanged)

Companion runtime module: `/home/mehran/star2lte-tune` → on device `/data/adb/modules/star2lte_tune/`

## Build

```bash
export PATH="/path/to/clang/bin:/path/to/gcc-arm64/bin:$PATH"
./build_gkilike.sh
cp -av Kernel-star2lte-gkilike-$(ls -1t Kernel-star2lte-gkilike-2*.zip | head -1 | xargs basename) \
       Kernel-star2lte-gkilike-NEXT.zip
```

Or trigger **Actions → Kernel Build** on GitHub (manual workflow).

## Continue Phase A (HDMI)

1. Flash new zip only when ready (keep STABLE for daily if needed).
2. Follow [`docs/HWC_PHASE_A.md`](docs/HWC_PHASE_A.md).
3. Pull debug: `scripts/dp_hdmi_debug.sh` on device after hub plug.
