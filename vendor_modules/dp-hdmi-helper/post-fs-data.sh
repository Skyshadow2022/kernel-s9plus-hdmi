#!/system/bin/sh
# Early poke so CCIC DP notifier path is ready before first hub plug.
[ -e /sys/class/dp_sec/dex ] && echo 0 > /sys/class/dp_sec/dex 2>/dev/null
[ -e /sys/class/dp_sec/log_level ] && echo 7 > /sys/class/dp_sec/log_level 2>/dev/null
