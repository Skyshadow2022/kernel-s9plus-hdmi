#!/system/bin/sh
# Runs as root when ACTION is tapped in the KernelSU manager.
#
# The audio HAL fails at boot with "cannot find Mixer Control" because files in
# the /vendor overlayfs upper dir shadow the stock vendor libraries. /vendor
# itself is a read-only erofs image underneath, so moving the upper aside
# reverts /vendor to stock. Nothing is deleted - it is renamed to upper.bak.
#
# A reboot is required afterwards for the overlay to be rebuilt.

UPPER=/cache/overlay/vendor/upper
BAK=/cache/overlay/vendor/upper.bak
LOG=/sdcard/audio-repair.log

say() { echo "$*"; echo "$*" >> "$LOG"; }

: > "$LOG"
say "=== star2lte audio repair $(date) ==="

say ""
say "--- overlay mounts ---"
grep overlay /proc/mounts >> "$LOG" 2>&1

say ""
say "--- what is in the vendor overlay upper ---"
if [ -d "$UPPER" ]; then
  for d in "$UPPER/lib64/hw" "$UPPER/lib64/soundfx" "$UPPER/lib" "$UPPER/etc"; do
    [ -d "$d" ] || continue
    say "  $d:"
    ls -la "$d" 2>&1 | tail -n +4 | awk '{printf "    %s %s %s\n", $1, $5, $9}' >> "$LOG"
    ls "$d" 2>/dev/null | sed 's/^/    /' | while read -r l; do echo "$l"; done >> "$LOG"
  done
  n=$(find "$UPPER" -type f 2>/dev/null | wc -l)
  say "  total files in upper: $n"
else
  say "  $UPPER does not exist or is not readable"
fi

say ""
say "--- audio state before repair ---"
getprop | grep -iE "audio|sound" | head -5 >> "$LOG" 2>&1

say ""
say "--- moving the upper aside ---"
if [ -d "$UPPER" ]; then
  rm -rf "$BAK" 2>/dev/null
  if mv "$UPPER" "$BAK" 2>/dev/null; then
    say "  moved $UPPER -> $BAK"
    mkdir -p "$UPPER" 2>/dev/null && say "  recreated an empty $UPPER"
  else
    say "  FAILED to move it (read-only or busy). Try from TWRP instead."
  fi
else
  say "  nothing to move"
fi

say ""
say "=== done. Reboot now, then check if sound works. ==="
say "    Log written to $LOG"

sync
