#!/system/bin/sh
# Safe DP/HDMI helper — logging/dex only. Never touch prefer_live/bist/dp_drm.
LOG=/data/local/tmp/dp-hdmi-helper.log
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

[ -e /sys/class/dp_sec/dex ] && echo 0 > /sys/class/dp_sec/dex 2>/dev/null
[ -e /sys/class/dp_sec/log_level ] && echo 7 > /sys/class/dp_sec/log_level 2>/dev/null

log "mon=$(cat /sys/class/dp_sec/monitor_info 2>/dev/null) ext=$(cat /sys/class/extcon/extcon0/state 2>/dev/null) prefer=$(cat /sys/class/dp_sec/prefer_live 2>/dev/null) bist=$(cat /sys/class/dp_sec/bist 2>/dev/null)"
