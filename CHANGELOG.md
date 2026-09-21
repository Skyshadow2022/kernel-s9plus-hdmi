# Changelog — star2lte kernel (kernel-s9plus)

All notable kernel builds and source changes, newest first. Every entry states
what changed, whether it was flashed, and how it was verified.

Legend: ✅ verified on device · ⚠️ flashed, problem found · ❌ never flash

---

## [20260921-1200] — 2026-09-21 — AUDIO BOOT-RACE FIXED ✅ CURRENT ON DEVICE

`Kernel-star2lte-gkilike-20260921-1200.zip` (CI run 35596618387, commit
`shotgun recovery in madera_dev_init`) · flashed 2026-09-21, verified
2026-09-21/22.

- **Root cause caught by the instrumented builds**: on losing boots
  `madera_dev_init`'s first ID read returns `hwid=0xffff` (chip unresponsive)
  → `probe of spi2.0 failed with error -22` → no Star-Madera card for the
  whole boot. PMIC/DCVDD was NEVER the problem (readback proved
  `is_enabled=1`); the reset line state was.
- **Fix**: on an unresponsive chip, the driver now recycles supplies+reset,
  probes the chip with the reset line HIGH (the DT's ACTIVE_HIGH flag vs the
  board's real /RESET polarity disagree) and keeps whatever state makes the
  chip answer. Evidence: three boots in the verification hunt engaged the
  recovery (`hwid=0xffff try=0` → `hwid=0x6371 line=HIGH` → `boot wait
  ret=0`) and came up WITH sound — those boots were losers before.
- **Verification: 12/12 consecutive winning boots** (CI runs 35519276485 →
  35596618387 lineage, hunt v5+v6). Historical loser rate was ~50%.
- Also shipped in this line: 2MB printk ring (`LOG_BUF_SHIFT=21`) so early
  boot `[audio-dbg]` chains survive to adb capture; forensics.fragment.
- Note: userspace SPI rebind (`audio-rescue.sh`) is impossible —
  `s3c64xx-spi` ships with `suppress_bind_attrs` (no bind/unbind in sysfs).

---

## [20260919-2314] — 2026-09-19 — GOLDEN BUILD ✅ (superseded on device by 20260921-1200)

`Kernel-star2lte-gkilike-20260919-2314-SUSFS-golden.zip` · sha256 `3973a663…` ·
artifact branch `releases/sound-verified/`.

- **The new reproducible lineage.** Incremental build from the current `out/`
  (inherited from the 0842 clean state) + SUSFS source (susfs branch merged
  with tune-2026-09-12: their DTS big-cluster ceiling 2314, smoke.sh, remote
  fixes) + touch BUILTIN + SUSFS config.
- Smoke PASS: Star-Madera card, cs47l92 codecs, DTB VG1, KSU 33250 crowned,
  SUSFS policy live (uname 4.9.219, cmdline green, sus_path, avc spoof), zero
  audio HAL errors, pstore present.
- **`out/` archived as the golden lineage**:
  `out-golden-20260919-2314.tar.zst` (135 MB) — restore with
  `tar --zstd -xf` (or gzip variant) before ANY future kernel build; never
  `make clean`.
- SUSFS is now on the MAIN line (branch susfs-v2-experiment = master going
  forward); the old 0206 backup kept at `/cache/BOOT-backup-0206sound.img`.

---

## [20260919-0206] — 2026-09-19 — SUSFS v2.2.0 release ✅ CURRENT ON DEVICE

`Kernel-star2lte-gkilike-20260919-0206.zip` · sha256 `a85133e2…` · branch
`susfs-v2-experiment`, tag `susfs-v2-sound-verified-20260919` · artifact copy on
the `artifacts` branch.

Kernel source (new, on top of 5ea9a5085):
- **SUSFS v2.2.0 kernel-side** (DS-ACK non-GKI backport, 19 files): sus_path,
  sus_mount, sus_kstat, uname/cmdline spoof, open_redirect, sus_map, kallsyms
  hiding. 3 hunks hand-fixed for the vanilla 4.9 base.
- **KernelSU-Next driver side**: SUSFS command dispatcher on the sys_reboot
  channel (`SUSFS_MAGIC 0xFAFAFAFA`), `susfs_init()`, umount marking,
  boot-completed sdcard monitor, SELinux predicates + SID globals resolved at
  policy load, Kconfig SUSFS menu.
- `configs/susfs.fragment`: 10 v2 symbols (v1.x symbols dropped), ENABLE_LOG off.

Verification: full smoke PASS — StarMadera ALSA card present, cs47l92 codec
children, touch via module, KernelSU 33250 crowned, zero audio HAL errors,
DTB `default_idma=3` (VG1). SUSFS policy module live: uname spoofed to 4.9.219,
`/proc/cmdline` bootloader-state rewritten, sus_path on `/data/adb*`, avc log
spoofing. Userspace tool `tools/susfs/ksu_susfs` proven live.

**CRITICAL build rule discovered with this build:** it works because it was
built INCREMENTALLY. See the 0255/0842 entries — a `make clean` rebuild of this
exact tree loses the sound card. NEVER `make clean` on this tree; archive
`out/` instead.

---

## [20260919-0842] — 2026-09-19 — clean rebuild, no SUSFS ❌ DO NOT FLASH

`Kernel-star2lte-gkilike-20260919-0842.zip` · sha256 `c62f70b9…`

- Built after `make clean` (full rebuild) with SUSFS source REMOVED (reverted to
  5ea9a5085 lineage) and touch forced BUILTIN (`CONFIG_TOUCHSCREEN_SEC_TS=y`,
  no `.ko` shipped at all).
- Intended as the "clean sound-verified" release. Flashed: **audio broken** —
  no Star-Madera card, madera MFD/codec never probes, silent failure.
- Purpose served: proved the audio regression is NOT SUSFS and NOT the DTB —
  it is the `make clean` rebuild itself (link-layout-sensitive bug in the
  Samsung audio probe path). The smoke gate (`tools/smoke.sh`) caught it
  pre-emptively this time.
- Packaging improvements introduced here and kept: `.ko` dropped from the zip
  (builtin build ships no modules), `modules.load` entry commented, stale
  `sec_ts_drv.ko` archived under `AnyKernel3/modules-ko-archive/`.

## [20260919-0255] — 2026-09-19 — clean rebuild with SUSFS ❌ DO NOT FLASH

`Kernel-star2lte-gkilike-20260919-0255.zip`

- `make clean` + full rebuild of the SUSFS tree (the 0206 source). Flashed:
  **audio broken** (same signature: no Star-Madera card).
- Together with 0842 this isolated `make clean` as the audio killer and fully
  acquitted SUSFS.

## [in-place patch] — 2026-09-18 — DTB delivery fix ✅ (boot image, not a build)

`BOOT-sound-verified` / `faf07bc6…` (= `/cache/BOOT-backup-presusfs.img`)

- **Discovery**: the Device Tree shipped in `AnyKernel3/dtb` never reached the
  bootloader. A header-v0 image has no `dtb_size` field, and `ak3-core.sh` only
  resolves its `dt` variable from a file literally named `dt`/`dt.img` — so
  every DT change ever made (including the HDMI `default_idma=VG1`) had been
  silently inert. The July boot image still carried the original DTB
  (`8abd9f5e…`) across two kernel flashes.
- **Fix**: replaced the 300964-byte DTB inside the DTBH blob in-place with the
  freshly built one. Boot image sha `50a95198…` → `faf07bc6…`.
- **Verified end-to-end**: `/proc/device-tree/decon_t@0x16050000/default_idma`
  = `00000003` (VG1) live; sound, touch, camera all healthy.
- Tooling added: `tools/bootimg_dtb.py` (verify a boot image / rebuild the DTBH
  blob), `tools/fdt_diff.py` (structural DT diff without dtc).
- **Build packaging fix** (so future builds deliver correctly): the build now
  assembles `AnyKernel3/dt` — a real DTBH table (2048-byte header page
  `AnyKernel3/dtbh-header.bin` + size-patched footprint + the fresh DTB) —
  which `ak3-core.sh:319` copies over `extra`, the region the bootloader reads.
- Also this day: the ViPER/overlay incident aftermath (overlay upper cleaned,
  ownership established — see star2lte-tune repo `overlay-audit/`), mountify
  removed, whiteout landmine defused.

## [20260913-0140] — 2026-09-13 — VINTF fix + gaming tune ✅

`Kernel-star2lte-gkilike-20260913-0140.zip` (= `NEXT.zip`, commit 5ea9a5085).
Flashed 2026-09-13 through 09-18; sound OK, gaming stable.

Source changes:
- **VINTF manufacturer dialog fixed**: `CONFIG_LOCALVERSION` from
  `-android13-8-…` (matches the GKI release regex `w.x.y-androidZ-K` → libvintf
  derives FCM level 7 vs manifest level 3 → "internal problem" every boot) to
  `-aosp13-8-g0123456789ab` (no GKI match).
- **Gaming tune fragment**: HZ 250→300, SCHED_AUTOGROUP.
- KSU version pin: `KSU_GIT_VERSION=3050` → kernel reports **33250** (this
  tree's Kbuild formula is `30000 + commits + 200`), above the manager's 33214;
  "Unsupported" resolved.
- Touch as a MODULE (`CONFIG_TOUCHSCREEN_SEC_TS=m`, the "Pseudo-GKI touch
  pilot"): `modules.load` + matching `sec_ts_drv.ko` shipped and loaded.
- ION/RBIN drop kept (−440 MB MemTotal; accepted trade).

## [202607xx] — July era — pseudo-GKI foundation ✅

Builds `20260722-0148` … `20260728-0355` (flashed: the July kernel, Image sha
`3f1ccdd3…`, still the base of the faf07bc6 fallback). Established:
- gkilike fragment build system with verified fragments
- KernelSU-Next legacy integration, manual hooks, touch as pilot module
- Pseudo-GKI module delivery (`modules/` in the AK3 zip + ak3-helper)
- AnyKernel3 packaging with Samsung DTBH handling quirks noted
- HDMI/DP investigation (branch `session-2026-07-25-dp-fifo`; `HDMI-READY.zip`
  and `STABLE.zip` are copies of `20260723-1546`)

## [20260626-2356] — 2026-06-26 — first build

First local kernel build for the project.

---

## Standing rules (learned the hard way)

1. **NEVER `make clean`** — clean rebuilds lose the Star-Madera sound card
   (link-layout-sensitive audio probe bug). Archive `out/` instead.
2. **Gate every flash on `tools/smoke.sh`** — first check is the StarMadera
   card; audio breakage is otherwise silent.
3. The DT must ship as a DTBH blob named `dt` (`ak3-core.sh:319` copies it over
   `extra`); a file named `dtb` lands in an unreferenced region on header-v0.
4. `CONFIG_LOCALVERSION` must never match `w.x.y-androidZ-K` (GKI regex) —
   libvintf parses it and breaks the boot dialog. It is also every module's
   vermagic.
5. `/proc/config.gz` shows `exynos9810_defconfig` by design (stock-config
   spoof) — the real config is `out/.config`, and `out/kernel/config_data.gz`
   must be regenerated every build.
6. A `.ko` only loads if built from the exact same tree/config/compiler
   (`module_layout` CRC); deliver it from `ak3-helper` when the touch pilot is
   `=m`.
