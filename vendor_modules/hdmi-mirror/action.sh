#!/system/bin/sh
MODDIR=${0%/*}
BIN="$MODDIR/hdmi_mirror"
FLAG=/data/adb/hdmi_mirror.auto
LOG=/data/local/tmp/hdmi_mirror.log

toast() {
  am broadcast -a net.dinglisch.android.tasker.ACTION_TASK 2>/dev/null
  # Fallback toast via cmd
  cmd notification post -S bigtext -t "HDMI Mirror" hdmi_mirror "$1" >/dev/null 2>&1 || true
}

if [ ! -x "$BIN" ]; then
  toast "hdmi_mirror binary missing"
  exit 1
fi

PIDFILE=/data/local/tmp/hdmi_mirror.pid
RUNNING=0
if [ -f "$PIDFILE" ]; then
  PID=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    RUNNING=1
  fi
fi

if [ "$RUNNING" = 1 ]; then
  "$BIN" stop
  rm -f "$FLAG"
  toast "Mirror STOPPED (TV stays live/red)"
  echo "$(date) action stop" >> "$LOG"
else
  if ! grep -q 'DP=1' /sys/class/extcon/extcon0/state 2>/dev/null; then
    toast "HDMI/DP not connected — plug hub first"
    exit 2
  fi
  touch "$FLAG"
  "$BIN" run >> "$LOG" 2>&1 &
  toast "Mirror STARTED — check TV"
  echo "$(date) action start" >> "$LOG"
fi
