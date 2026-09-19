#!/system/bin/sh
# ak3-helper v2.1 - touch firmware owner
#
# The touch driver is built into this kernel: sec_ts 4-0048 is alive in dmesg
# while /proc/modules is completely empty, and /sys/module/sec_ts does not even
# exist because Samsung's builtin driver registers no module entry.
#
# The .ko that used to sit in this module was therefore never loadable here.
# insmod on it fails with "disagrees about version of symbol module_layout",
# i.e. it was built against a different kernel. Loading it could only ever
# replace a working builtin driver with a stale one, so it now lives in
# ko-archive/ where no mount can reach it.
#
# That leaves one job: the y761 touch firmware must exist under
# /vendor/firmware/tsp_sec/. It reaches /vendor through the hand-built overlayfs
# upper dir, not through mountify, so if the upper is ever cleared - which is
# exactly what happened on 2026-09-17 and caused the boot loop - this puts it
# back.
#
# ADDITIVE ONLY. This script never deletes and never overwrites a file that is
# already present.

MODDIR=${0%/*}
UPPER=/cache/overlay/vendor/upper/firmware/tsp_sec
SRC="$MODDIR/system/vendor/firmware/tsp_sec"
LOG=/sdcard/ak3-helper.log

until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 3; done
sleep 20

restored=0
for f in y761_star1.fw y761_star2.fw; do
  [ -f "$SRC/$f" ] || continue
  [ -f "$UPPER/$f" ] && continue
  mkdir -p "$UPPER" 2>/dev/null
  if cp -a "$SRC/$f" "$UPPER/$f" 2>/dev/null; then
    echo "$(date '+%F %T') restored $f into the overlay upper" >> "$LOG"
    restored=$((restored + 1))
  else
    echo "$(date '+%F %T') FAILED to restore $f" >> "$LOG"
  fi
done

if [ "$restored" -gt 0 ]; then
  echo "$(date '+%F %T') $restored firmware file(s) were missing and are back." >> "$LOG"
  echo "Reboot for the touch driver to pick them up." >> "$LOG"
fi

exit 0
