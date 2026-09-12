#!/system/bin/sh
# Re-apply late: Android init and the vendor thermal HAL reset several
# of these nodes after post-fs-data, so the late pass is the one that sticks.
MODDIR=${0%/*}
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 5
sh "$MODDIR/tune.sh"

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

# Keep real carrier APNs preferred. Fake "Speedtest/Speedup" APNs leave
# mobile data registered on LTE but never bring up rmnet (no internet icon).
# MCI (43211) -> mcinet ; Irancell (43235) -> mtnirancell
(
  MCI_ID=$(content query --uri content://telephony/carriers \
    --where "numeric='43211' AND apn='mcinet'" --projection _id 2>/dev/null \
    | sed -n 's/.*_id=\([0-9]*\).*/\1/p' | head -1)
  IR_ID=$(content query --uri content://telephony/carriers \
    --where "numeric='43235' AND apn='mtnirancell'" --projection _id 2>/dev/null \
    | sed -n 's/.*_id=\([0-9]*\).*/\1/p' | head -1)
  [ -n "$MCI_ID" ] && content insert --uri content://telephony/carriers/preferapn/subId/2 --bind apn_id:i:"$MCI_ID" 2>/dev/null
  [ -n "$IR_ID" ] && content insert --uri content://telephony/carriers/preferapn/subId/1 --bind apn_id:i:"$IR_ID" 2>/dev/null
  for apn in Speedtest Speedup Speednet speednet .net google.com Speedup; do
    content update --uri content://telephony/carriers --bind carrier_enabled:i:0 \
      --where "apn='$apn'" 2>/dev/null
  done
) >/dev/null 2>&1 &

# Primary VINTF dialog fix is kernel LOCALVERSION (no GKI-looking uname).
# Fallback only: dismiss manufacturer dialog if it still appears.
(
  for _ in $(seq 1 20); do
    sleep 2
    uiautomator dump /data/local/tmp/ksu_ui.xml >/dev/null 2>&1 || continue
    if grep -qiE "internal problem|manufacturer for details|Contact your manufacturer" \
         /data/local/tmp/ksu_ui.xml 2>/dev/null; then
      OK=$(grep -oE 'text="OK"[^>]*bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' \
            /data/local/tmp/ksu_ui.xml 2>/dev/null | head -1)
      if [ -n "$OK" ]; then
        eval "$(echo "$OK" | sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/x1=\1;y1=\2;x2=\3;y2=\4/p')"
        input tap $(( (x1+x2)/2 )) $(( (y1+y2)/2 ))
      else
        input keyevent KEYCODE_ENTER
        input keyevent KEYCODE_DPAD_CENTER
      fi
      break
    fi
  done
) >/dev/null 2>&1 &

# Thermal HAL re-clamps big-cluster max / GPU min. Re-apply periodically.
(
  for i in $(seq 1 20); do
    sleep 30
    sh "$MODDIR/tune.sh"
  done
  while true; do
    sleep 300
    sh "$MODDIR/tune.sh"
  done
) >/dev/null 2>&1 &
