# star2lte Overlay Auditor

A read-only tool that answers one question: **which module put this file in the
overlay, and is anything here dangerous?**

It exists because of a specific failure. `/vendor` on this device is served by a
hand-built overlayfs whose upper directory,
`/cache/overlay/vendor/upper`, is shared by everything that wants to add a
vendor file. Nothing tracked who owned what. An audio module (ViPER) wrote three
files there, the audio HAL stopped finding its mixer controls, and every app in
turn got `ENODEV` from `AudioTrack`. Clearing that directory to fix it also
deleted the touchscreen firmware, and the device went into a boot loop.

## What it reports

| Section | What it tells you |
|---|---|
| overlay mounts | every hand-built overlay and its upper dir, found from `/proc/mounts` |
| mountify | whether mountify is in manual or auto mode, and which module ids it mounts |
| module `system/` trees | which installed modules ship files at all |
| inventory + ownership | every file in the upper, next to the module that provides it |
| conflicts | everything below, ranked by how badly it can hurt |

Ownership is decided by content hash first, then by relative path. A file whose
hash matches a module's copy is that module's. A file no module provides is an
**orphan** — it will survive uninstalling whatever put it there, which is
exactly how the ViPER files outlived their own module.

`conflicts` ranks findings:

- **CRITICAL** — a whiteout that hides a binary under a `bin/` directory.
  `/system/bin/servicemanager` is binder itself; hiding it leaves the device
  with no binder and no boot.
- **CRITICAL** — a module shipping a `.ko` that differs from the live driver in
  `/system/lib/modules`. The touch driver is built into this kernel, so such a
  mount can only replace a working driver with a stale one.
- **HIGH** — orphan overlay files, stale overlay copies (the module ships a
  different version than what is actually mounted), the same path claimed by two
  modules, or a `mountify/modules.txt` entry for a module that is gone.
- **info** — intentional, harmless shadows and app-level whiteouts.

## The ACTION button

Prints the report. That is all it does. This is deliberate: the module it
replaces had an ACTION that moved the whole overlay upper aside, and that is
what caused the boot loop.

## Terminal use

```sh
SH=/data/adb/star2lte-audit/audit.sh

su -c "sh $SH report"              # full report, also at /sdcard/star2lte-overlay-audit.txt
su -c "sh $SH owner /vendor/firmware/tsp_sec/y761_star1.fw"
su -c "sh $SH remove <module-id>"  # see below
```

`remove <module-id>` deletes **only** the overlay files that module provides,
and leaves every other module's files alone. This is the operation that was
performed by hand — and performed wrong — during the incident. It is
intentionally not reachable from the WebUI.

After a `remove`, reboot so the overlay rebuilds.

## What it does not do

It never creates, moves or deletes anything on its own. It only reads
`/proc/mounts`, the module directories, and the overlay upper; the only thing it
writes is its own report.

`service.sh` copies `audit.sh` to `/data/adb/star2lte-audit/audit.sh` at boot so
the stable path survives module updates, then writes one report per boot to
`/sdcard/star2lte-overlay-audit.txt` (readable without root).

## Reading a clean report

```
--- overlay inventory + ownership ---
  /firmware/tsp_sec/y761_star2.fw  <- ak3-helper
  /firmware/tsp_sec/y761_star1.fw  <- ak3-helper
  2 file(s): 2 from a module, 0 orphan/differing, 0 stale

--- conflicts ---
  [info] whiteout hides /system/system_ext/app/MatLog
  ...
  no critical conflicts; 0 item(s) to review.
```

Both the touch firmwares are owned by `ak3-helper`, nothing is orphaned, and the
only whiteouts left are app-level debloat.
