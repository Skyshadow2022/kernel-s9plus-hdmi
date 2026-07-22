#!/system/bin/sh
# Do NOT auto-clear BIST — that blacks the TV until live fb1 path works.
# Mirror is started only when /data/adb/hdmi_mirror.auto exists (Action/toggle).
MODDIR=${0%/*}
LOG=/data/local/tmp/hdmi_mirror.log
FLAG=/data/adb/hdmi_mirror.auto

[ -x "$MODDIR/hdmi_mirror" ] || exit 0
[ -f "$FLAG" ] || exit 0

(
  sleep 8
  if grep -q 'DP=1' /sys/class/extcon/extcon0/state 2>/dev/null; then
    echo "$(date) service auto-start (flag present)" >> "$LOG"
    "$MODDIR/hdmi_mirror" run >> "$LOG" 2>&1 &
  fi
) &
