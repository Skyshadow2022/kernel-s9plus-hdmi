#!/system/bin/sh
# Late: relabel DP cable after driver creates sysfs nodes
MODDIR=${0%/*}
CABLE=/sys/devices/platform/11090000.displayport/extcon/extcon0/cable.0/state
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 20 25 30; do
  if [ -e "$CABLE" ]; then
    chcon u:object_r:sysfs_displayport_writable:s0 "$CABLE" 2>/dev/null
    chcon u:object_r:sysfs_displayport_writable:s0 \
      /sys/devices/platform/11090000.displayport/extcon/extcon0/cable.0 2>/dev/null
    log -t dp-hwc-selinux "labeled $CABLE"
    break
  fi
  sleep 1
done
