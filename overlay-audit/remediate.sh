#!/system/bin/sh
# star2lte conflict remediation - 2026-09-18
#
# Removes the three mechanisms that let modules fight each other on this device:
#   1. a module whose ACTION button moved the whole /vendor overlay aside
#   2. a touch module that shadows a driver the kernel already has built in
#   3. a whiteout list containing system-critical binaries
#
# Every step is guarded and logged. Nothing is deleted that is not named here.

LOG=/sdcard/star2lte-fixes-20260918.log
U=/cache/overlay/vendor/upper
A=/data/adb/modules/ak3-helper

say() { echo "$*"; echo "$*" >> "$LOG"; }

: > "$LOG"
say "=== star2lte conflict remediation $(date) ==="
say "kernel: $(uname -r)"

# ---------------------------------------------------------------
# 1. star2lte_audiofix - the boot loop
#    Its action.sh did `mv /cache/overlay/vendor/upper upper.bak`. That dir
#    also held the touch firmware, so moving it took touch with it and the
#    device never finished booting. The module has no other purpose.
# ---------------------------------------------------------------
say ""
say "--- 1. retire star2lte_audiofix ---"
if [ -d /data/adb/modules/star2lte_audiofix ]; then
  mv /data/adb/modules/star2lte_audiofix /data/adb/star2lte_audiofix.retired-20260918 2>/dev/null \
    && say "  moved out of modules/ -> /data/adb/star2lte_audiofix.retired-20260918 (kept for reference)" \
    || say "  FAILED to move"
else
  say "  not installed, nothing to do"
fi

# ---------------------------------------------------------------
# 2. ak3-helper - two problems
#    a) it ships sec_ts_drv.ko, but the running kernel has the touch driver
#       built in (/proc/modules is empty, sec_ts 4-0048 is alive). Its copy
#       hashes differently from the live one, so any mount that wins would
#       load a mismatched driver and kill touch.
#    b) its y761_star2.fw shadows the copy in the vendor overlay upper, and
#       y761_star1.fw exists only in the overlay with no owner at all.
#    Fix: keep the firmware, archive the .ko out of the mount path, and give
#    the orphan firmware an owner so it survives an overlay wipe.
# ---------------------------------------------------------------
say ""
say "--- 2. ak3-helper: firmware-only, stop shadowing the builtin driver ---"
if [ -d "$A" ]; then
  mkdir -p "$A/ko-archive"
  for k in "$A"/system/lib/modules/*; do
    [ -f "$k" ] || continue
    n=$(basename "$k")
    mv "$k" "$A/ko-archive/$n" && say "  archived $n (out of the mount path)"
  done
  rmdir "$A/system/lib/modules" 2>/dev/null && say "  removed empty system/lib/modules"

  mkdir -p "$A/system/vendor/firmware/tsp_sec"
  for f in y761_star1.fw y761_star2.fw; do
    if [ -f "$U/firmware/tsp_sec/$f" ]; then
      if [ -f "$A/system/vendor/firmware/tsp_sec/$f" ]; then
        a=$(sha256sum "$U/firmware/tsp_sec/$f" | awk '{print $1}')
        b=$(sha256sum "$A/system/vendor/firmware/tsp_sec/$f" | awk '{print $1}')
        if [ "$a" = "$b" ]; then
          say "  $f already owned by ak3-helper"
        else
          cp -a "$U/firmware/tsp_sec/$f" "$A/system/vendor/firmware/tsp_sec/$f"
          say "  $f refreshed in ak3-helper (overlay copy won)"
        fi
      else
        cp -a "$U/firmware/tsp_sec/$f" "$A/system/vendor/firmware/tsp_sec/$f"
        say "  adopted $f from the overlay - it now has an owner"
      fi
    fi
  done
  say "  ak3-helper system/ tree now:"
  find "$A/system" -type f 2>/dev/null | sed "s|$A|    |"

  # The old post-fs-data.sh insmod'd unconditionally. On this kernel that
  # either fails silently or loads a second copy on top of the builtin one.
  # Only load it when the driver is genuinely missing.
  if [ -f "$A/post-fs-data.sh" ]; then
    cp -a "$A/post-fs-data.sh" "$A/post-fs-data.sh.pre-20260918"
    cat > "$A/post-fs-data.sh" <<'PFEOF'
#!/system/bin/sh
MODDIR=${0%/*}
# The touch driver is built into this kernel. insmod'ing a .ko on top of a
# builtin driver is how touch dies, so only load it if it is really absent.
[ -d /sys/module/sec_ts ] && exit 0
[ -f "$MODDIR/ko-archive/sec_ts_drv.ko" ] || exit 0
insmod "$MODDIR/ko-archive/sec_ts_drv.ko" 2>/dev/null
PFEOF
    chmod 755 "$A/post-fs-data.sh"
    say "  rewrote post-fs-data.sh (guarded insmod; old one kept as .pre-20260918)"
  fi

  cat > "$A/module.prop" <<'MPEOF'
id=ak3-helper
name=AK3 Helper (touch firmware)
version=v2.0
versionCode=20
author=local
description=Sole owner of the y761 touch firmware (star1+star2). The touch driver itself is built into the kernel, so the .ko copies live in ko-archive/ and are deliberately outside the mount path - mounting them over the builtin driver is what kills touch.
MPEOF
  say "  module.prop -> v2.0 (firmware owner, no driver shadowing)"
else
  say "  ak3-helper not installed"
fi

# ---------------------------------------------------------------
# 3. the vendor overlay upper
#    ViPER wrote lib/soundfx, lib64/soundfx and etc here. The files are gone
#    (deleted by hand during the repair) but the empty directories stayed.
#    They are the scar that makes the same breakage easy to repeat: they make
#    /vendor/lib/soundfx and /vendor/etc look writable to the next audio mod.
#    rmdir only succeeds on an empty dir, so anything real is left alone.
# ---------------------------------------------------------------
say ""
say "--- 3. clear the ViPER leftovers from the vendor overlay upper ---"
for d in lib64/soundfx lib/soundfx lib64 lib etc; do
  p="$U/$d"
  [ -d "$p" ] || continue
  if rmdir "$p" 2>/dev/null; then
    say "  removed empty $p"
  else
    say "  kept $p (not empty - inspect with: find $p)"
  fi
done
say "  what is left in the upper:"
find "$U" 2>/dev/null | sed "s|$U|    |"

# ---------------------------------------------------------------
# 4. mountify whiteouts
#    /system/bin/servicemanager is the binder context manager. Whiteing it
#    out would leave the device with no binder at all. install-recovery.sh,
#    msm_irqbalance and NOTICE.xml.gz are the same class of mistake.
#    Only app-level debloat belongs in this list.
#    (Currently inert: the mountify_whiteouts module was never generated.
#     That is exactly why this is worth fixing before someone generates it.)
# ---------------------------------------------------------------
say ""
say "--- 4. rewrite mountify whiteouts ---"
W=/data/adb/mountify/whiteouts.txt
if [ -f "$W" ]; then
  cp -a "$W" "$W.pre-20260918"
  cat > "$W" <<'WOEOF'
# mountify whiteout list - star2lte
# Only app-level debloat here. Anything under /system/bin is off limits:
# /system/bin/servicemanager is binder itself and hiding it bricks boot.
# Removed 2026-09-18: /system/bin/servicemanager, /system/bin/install-recovery.sh,
# /system/vendor/bin/install-recovery.sh, /system/vendor/bin/msm_irqbalance,
# /system/odm/etc/NOTICE.xml.gz
/system/system_ext/app/MatLog
/system/system_ext/priv-app/AudioFX
/system/product/app/PowerOffAlarm
/system/product/app/Twelve
/system/etc/nikgapps_logs_archive
/system/etc/nikgapps_logs
WOEOF
  say "  saved old list as whiteouts.txt.pre-20260918"
  say "  new list:"
  sed 's/^/    /' "$W"
else
  say "  no whiteouts.txt"
fi

say ""
say "=== done ==="
