#!/system/bin/sh
# Install helper link + keep ADB-over-TCP available when hub/ethernet is used
MODDIR=${0%/*}
mkdir -p "$MODDIR"
chmod 755 "$MODDIR/hdmi_mirror" "$MODDIR/service.sh" "$MODDIR/action.sh" 2>/dev/null
mkdir -p /data/adb/hdmi-mirror
ln -sf "$MODDIR/hdmi_mirror" /data/adb/hdmi-mirror/hdmi_mirror 2>/dev/null
ln -sf "$MODDIR/action.sh" /data/adb/hdmi-mirror/toggle.sh 2>/dev/null

# Persist TCP ADB so hub+ethernet debugging works after reboot
setprop persist.adb.tcp.port 5555
setprop service.adb.tcp.port 5555
