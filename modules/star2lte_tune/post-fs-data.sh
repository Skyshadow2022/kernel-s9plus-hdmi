#!/system/bin/sh
MODDIR=${0%/*}
sh "$MODDIR/tune.sh"

# Early fingerprint sync (helps Clash + reduces partition mismatch noise).
# Manufacturer dialog on PE13 was VINTF/GKI-uname — fixed in kernelsu.fragment.
FP='samsung/star2lte/star2lte:13/TQ3A.230901.001.B1/1557:user/release-keys'
DESC='aosp_star2lte-user 13 TQ3A.230901.001.B1 1702742245 release-keys'
RP=
[ -x /data/adb/ksu/bin/resetprop ] && RP=/data/adb/ksu/bin/resetprop
[ -z "$RP" ] && [ -x /data/adb/magisk/resetprop ] && RP=/data/adb/magisk/resetprop
if [ -n "$RP" ]; then
  "$RP" -n ro.build.fingerprint "$FP"
  "$RP" -n ro.build.description "$DESC"
  "$RP" -n ro.system.build.fingerprint "$FP"
  "$RP" -n ro.bootimage.build.fingerprint "$FP"
  "$RP" -n ro.vendor.build.fingerprint "$FP"
  "$RP" -n ro.odm.build.fingerprint "$FP"
  "$RP" -n ro.system_ext.build.fingerprint "$FP"
  "$RP" -n ro.vendor_dlkm.build.fingerprint "$FP"
  "$RP" -n ro.vendor_dlkm.build.type user
fi
