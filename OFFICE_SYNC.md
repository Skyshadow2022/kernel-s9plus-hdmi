# Office sync

Remote (public): https://github.com/Skyshadow2022/kernel-s9plus-hdmi

```bash
git clone git@github.com:Skyshadow2022/kernel-s9plus-hdmi.git
cd kernel-s9plus-hdmi
```

SSH key used on the bring-up machine: `~/.ssh/id_ed25519_github`  
(or whatever account key you registered at https://github.com/settings/keys).

## Build

```bash
export PATH="/path/to/clang/bin:/path/to/gcc-arm64/bin:$PATH"
./build_gkilike.sh
```

Or trigger **Actions → Kernel Build** on GitHub (manual workflow).

## Continue Phase A

1. Flash new zip only when ready (keep STABLE `#29` for daily).
2. Follow [`docs/HWC_PHASE_A.md`](docs/HWC_PHASE_A.md).
3. Pull debug: `scripts/dp_hdmi_debug.sh` on device after hub plug.
