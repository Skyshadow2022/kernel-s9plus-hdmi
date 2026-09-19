#!/system/bin/sh
# Log the audio-related state on every boot so it can be read over adb
# (/sdcard is readable without root). Does not change anything.
MODDIR=${0%/*}
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 45

L=/sdcard/audio-bootstate.txt
{
  echo "=== boot $(date) ==="
  uname -r
  echo "--- overlay mounts ---"
  grep overlay /proc/mounts
  echo "--- audio HAL result at boot ---"
  logcat -d 2>/dev/null | grep -E "adev_open|Mixer|loadHwModule|audio_hw_primary" | head -20
  echo "--- vendor overlay upper ---"
  ls /cache/overlay/vendor/upper/lib64/hw/ 2>&1 | head
  ls /cache/overlay/vendor/upper/lib64/soundfx/ 2>&1 | head
} > "$L" 2>&1
