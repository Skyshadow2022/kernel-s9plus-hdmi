# Branch status — susfs-v2-experiment

**This branch is the current best kernel for star2lte.** The 20260919-0206
build from this tree was verified on-device with:
- working sound (StarMadera ALSA card, smoke PASS)
- SUSFS v2.2.0 kernel side + policy module active (uname/cmdline/sus_path/avc)
- KernelSU-Next 33250, touch via module, DTB VG1

The original "breaks audio" warning in the big commit message was WRONG — the
audio loss came from `make clean`, not from SUSFS (see tag
`susfs-v2-sound-verified-20260919`, the artifacts branch, and HANDOFF.md in
star2lte-tune for the full bisect matrix).

## Rules
- NEVER `make clean` on this tree. Archive `out/` before risky operations.
- Gate every flash on `tools/smoke.sh` (on tune-2026-09-12 and later here too).
