# Why the modules conflicted, and what was done about it

2026-09-18. Written after the audio/video/lag incident and the boot loop that
followed the attempted repair.

The user asked: find what caused this, and find the solution across all the
modules so they stop interfering and each one does its own job. This is that
answer.

---

## The short version

There was no single guilty module. There were **three independent delivery
mechanisms** all writing to the same places, and **nothing owned anything**.

`/vendor` on this device is not the stock partition. It is a hand-built
overlayfs:

```
overlay /vendor lowerdir=/vendor,upperdir=/cache/overlay/vendor/upper
```

The upper directory is a shared, unowned scratch space. Anything that wants to
add a file under `/vendor` just writes there. Nothing records who wrote what, so
nothing can clean up after a module is uninstalled.

That is the whole disease. The three mechanisms are its symptoms.

---

## Mechanism 1 — the shared overlay upper, with no ownership

**What it did:** ViPER wrote three files into
`/cache/overlay/vendor/upper`:

```
lib64/soundfx/libv4a_re.so
lib/soundfx/libv4a_re.so
etc/audio_effects.xml
```

**Why that killed the sound:** those paths shadowed the stock vendor audio
libraries. The audio HAL then could not find its mixer controls:

```
audio_hw_proxy_9810: cannot find Mixer Control
failed to open Primary Audio HW Device
AudioFlinger: loadHwModule() error -22
```

With no output thread, every app that tried to play anything got `-19 ENODEV`.
`AudioService` retried every two seconds forever, which is where the severe lag
came from. Telegram video was a symptom of the same fault, not a separate
problem — `MediaCodecAudioRenderer2: AudioTrack init failed`, while the video
stream itself decoded fine (`format_supported=YES`).

**Why uninstalling ViPER did not fix it:** the module was gone; its files were
not. Nothing connected the two, because nothing recorded the connection. This
is the single most important property of the design, and it is what made the
failure so confusing to diagnose.

**Why clearing the upper caused a boot loop:** the upper also held the
touchscreen firmware:

```
firmware/tsp_sec/y761_star1.fw
firmware/tsp_sec/y761_star2.fw
```

`star2lte_audiofix`'s ACTION button did `mv /cache/overlay/vendor/upper
upper.bak`. That is a reasonable-looking way to revert `/vendor` to stock, and
it took the touch firmware with it. The device could not finish booting.

So the same missing ownership caused both failures: first it made the audio
breakage impossible to attribute, then it made the "fix" catastrophic.

### What was done

- **Rebuilt the upper by hand** during the repair: ViPER's three files deleted,
  the two firmware files kept. Sound and video came back.
- **`ak3-helper` now owns the firmware.** `y761_star1.fw` existed only in the
  overlay with no owner at all — an orphan that would have survived every
  uninstall and could never have been restored. It is now in the module
  alongside `y761_star2.fw`, so wiping the overlay is recoverable.
- **The empty directories ViPER left behind are gone** (`lib/`, `lib64/`,
  `etc/`, `lib/soundfx/`, `lib64/soundfx/`). They held no files, but their
  presence is what makes `/vendor/lib/soundfx` look writable to the next audio
  module that comes along. The scar tissue is removed, not just the wound.
- **`ak3-helper` restores the firmware if it ever goes missing**, additively.
  Its `service.sh` checks the two paths after boot and copies them back from the
  module if they are absent. It never deletes and never overwrites.
- **An auditor exists now** — `star2lte_audit`, see below.

---

## Mechanism 2 — two systems delivering the same files

`ak3-helper` shipped `system/vendor/firmware/tsp_sec/y761_star2.fw`, which
mountify would mount at `/vendor/firmware/tsp_sec/y761_star2.fw` — the same
path the hand-built overlay already provides from the upper. Two mechanisms,
one path, and which one wins depends on an unrelated config value,
`mountify_mounts`, in `/data/adb/mountify/modules.txt`.

Worse, the module also shipped `system/lib/modules/sec_ts_drv.ko`. The kernel
that is *running* has the touch driver built in — `sec_ts 4-0048` is alive in
dmesg while `/proc/modules` is completely empty — but the tree in
`kernel-s9plus` is configured with `CONFIG_TOUCHSCREEN_SEC_TS=m`, so a kernel
built from it ships the driver as a **module** instead. See the correction at
the end of this file.

The shipped `.ko` is not the same build as the live one:

```
6ed68bd3…  /system/lib/modules/sec_ts_drv.ko        (live)
a4f1cbc6…  ak3-helper's copy                        (different)
```

and it cannot load at all:

```
insmod: failed to load sec_ts_drv.ko: Exec format error
kernel: sec_ts_drv: disagrees about version of symbol module_layout
```

So the old `post-fs-data.sh` ran `insmod` on every boot, and it always failed
silently (`2>/dev/null`). Had mountify ever been switched to auto mode, that
same file would have been mounted over the working driver. Nothing good was
possible from it.

### What was done

- **The `.ko` files are out of the mount path**, in `ko-archive/`, which
  mountify does not mount. Whatever driver is live cannot be shadowed by this
  module any more, structurally rather than by convention.
- **The boot-time `insmod` is deleted entirely**, not guarded. It provably
  cannot succeed: the archived `.ko` fails with `disagrees about version of
  symbol module_layout`.
- **`ak3-helper` is now a firmware owner and nothing else.** One job, stated in
  its `module.prop`.
- **mountify stays in manual mode** with `modules.txt` holding only `__none__`.
  That is deliberate: it preserves manual mode (comment-only files silently fall
  back to AUTO) while mounting nothing. The hand-built overlay is the delivery
  path, and now that is written down instead of being an accident.

---

## Mechanism 3 — a loaded whiteout list with boot-critical entries

`/data/adb/mountify/whiteouts.txt` hid eleven files. Six were ordinary
app-level debloat. Five were not:

| Entry | What hiding it would do |
|---|---|
| `/system/bin/servicemanager` | **binder itself.** No binder, no boot. |
| `/system/bin/install-recovery.sh` | recovery-install hook |
| `/system/vendor/bin/install-recovery.sh` | same |
| `/system/vendor/bin/msm_irqbalance` | the IRQ balancer, a performance component |
| `/system/odm/etc/NOTICE.xml.gz` | pointless |

This is currently **inert** — `whiteout_gen.sh` was never run, so the
`mountify_whiteouts` module does not exist and nothing is being hidden. That is
luck, not safety. `servicemanager` is in that list, and generating it would
leave the device unable to boot.

### What was done

The list now contains only the six app-level debloat entries, with a comment
block explaining why the others were removed so nobody adds them back.

---

## The auditor

`star2lte_audit` — installed, active, and read-only by design.

| Command | What it does |
|---|---|
| `sh /data/adb/star2lte-audit/audit.sh report` | full report, also written to `/sdcard/star2lte-overlay-audit.txt` at every boot |
| `... owner <path>` | which module provides a given overlay file |
| `... remove <module-id>` | delete **only** that module's overlay files |
| `... webui` | the report as one line, for the KernelSU WebUI |

It reads the overlay upper dirs from `/proc/mounts` rather than hardcoding paths,
resolves ownership by content hash first and relative path second, and ranks
findings:

- **CRITICAL** — a whiteout hiding anything under a `bin/` directory, or a
  module shipping a `.ko` that differs from the live driver.
- **HIGH** — orphan overlay files, stale copies (the module ships a different
  version than what is mounted), one path claimed by two modules, `modules.txt`
  entries for modules that are gone.
- **info** — intentional shadows and app-level whiteouts.

Its ACTION button prints the report and nothing else. That is deliberate: the
last ACTION button in this project caused a boot loop. The `remove` subcommand
is terminal-only for the same reason.

### The trap that was found while testing it

Worth recording, because it nearly corrupted the fix. A test command failed
with `no closing quote` on the device — and **still executed its first two
lines**, because `sh` parses and runs a script incrementally rather than
validating the whole thing first. That appended an entry to `whiteouts.txt`
before erroring out. The test's own backup had already been taken after the
partial write, so restoring from it restored the corruption.

Hence: verify the result, not the exit code. `grep -c '^/system/bin/servicemanager'`
now returns 0 and the file was rewritten from known-good content rather than
from a backup of unknown provenance.

---

## Verified state

After the reboot that activated the audit module:

| Check | Result |
|---|---|
| boot | completed, ~20 s |
| touch | `sec_ts 4-0048` alive, 88 lines in dmesg |
| audio HAL | `loadHwModule() error` / `failed to open Primary Audio HW Device`: **0** |
| overlay upper | exactly two files, both firmware |
| ownership | 2 of 2 owned by `ak3-helper`, 0 orphan, 0 stale |
| conflicts | no critical, 0 to review |
| whiteouts | 6 app-level entries, `servicemanager` count 0 |

Modules installed: `ak3-helper` (firmware owner), `mountify` (manual, mounts
nothing), `star2lte_audit`, `star2lte_bandwatch`, `star2lte_tune`,
`hma_oss_zygisk`, `zygisk_lsposed`, `zygisksu`. `playintegrityfix` is
deliberately disabled. `star2lte_audiofix` is retired to
`/data/adb/star2lte_audiofix.retired-20260918`.

`star2lte_bandwatch` shows as enabled although it was disabled before the
reboot. No `disable` marker exists for it now, its watcher is not running (no
pidfile), and it writes only under `/data/adb/bandwatch*`, so it conflicts with
nothing — but if it was disabled on purpose, disable it again in the manager.

---

## Rules this device now follows

1. **Every file in the overlay has an owner.** If the auditor reports an
   orphan, either the file is junk and should go, or a module should adopt it.
2. **One delivery path per file.** The hand-built overlay upper is the path.
   mountify stays in manual mode and mounts nothing.
3. **No module ships a kernel driver.** The drivers are builtin; a `.ko` can
   only shadow a working one.
4. **Nothing under a `bin/` directory goes in `whiteouts.txt`.**
5. **No ACTION button moves or deletes a directory that it does not
   exclusively own.** That is the boot loop, exactly.
6. **Run the auditor after installing or removing any module** that writes
   under `/vendor`, `/system`, `/odm` or `/product`.

---

## Files

| Path | What |
|---|---|
| `kernel-s9plus/overlay-audit/audit.sh` | the auditor |
| `kernel-s9plus/overlay-audit/remediate.sh` | the four fixes, as applied |
| `kernel-s9plus/overlay-audit/module-overlay-audit/` | the packaged module |
| `kernel-s9plus/overlay-audit/ak3-helper-fix/service.sh` | firmware restore |
| `kernel-s9plus/overlay-audit/backup-20260918/` | device state before the fixes |
| `/data/local/tmp/pre-fix-20260918/` on device | pre-fix whiteouts, modules.txt, ak3-helper |
| `/sdcard/star2lte-fixes-20260918.log` on device | the remediation log |

---

## Corrections, 2026-09-18 (after further research)

Two claims made above turned out to be imprecise. They are corrected here
rather than edited away, because the reasoning is worth keeping.

**1. "The touch driver is built into this kernel."** Half right, and the half
that is wrong matters. `/proc/modules` is empty and `/sys/module/sec_ts` is
absent — but the module name would be `sec_ts_drv`, not `sec_ts`, so that
second check was looking in the wrong place and proved nothing. What the
evidence does support is that the *running* kernel has touch built in. The tree
in `kernel-s9plus` has `CONFIG_TOUCHSCREEN_SEC_TS=m`, so **the next kernel built
from this source ships the driver as a loadable module.** If such a kernel is
flashed without a matching `sec_ts_drv.ko` at `/system/lib/modules/`, touch will
not come up at all.

That is the real "touch module rename trap" from `HANDOFF.md`, and it is now
explained rather than folklore. The archiving of `ak3-helper`'s `.ko` remains
correct either way — it cannot load, so it could only ever be a shadowing
hazard.

**2. "The touch firmware files must both exist."** `y761_star1.fw` is the
**S9 (SM-G960F / starlte)** firmware; star2lte's device tree names
`y761_star2.fw` for both of its entries. So star1.fw is a foreign file that has
no role on this device. It is harmless and it stays, but it is understood now:
see `KERNEL-REFERENCE.md` section 9.

**A third finding, unrelated to ownership.** The Device Tree shipped in
`AnyKernel3/dtb` never reaches the bootloader — a header-v0 image has no
`dtb_size` field to point at it, and AK3's `dt` variable does not resolve to a
file named `dtb`. Every DT change made in this project has therefore been inert.
Full mechanism, proof and fix: `KERNEL-REFERENCE.md` section 2.
