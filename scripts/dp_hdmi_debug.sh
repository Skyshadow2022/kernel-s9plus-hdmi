#!/system/bin/sh
# Collect USB-C DP / HDMI-hub + HWC diagnostics (run as root after plugging hub).
OUT=${1:-/sdcard/Download/dp-hdmi-debug-$(date +%Y%m%d-%H%M%S).txt}
{
  echo "=== uname ==="; uname -a
  echo "=== props ==="; getprop | grep -iE 'dex|hdmi|displayport|hdcp|desktop|hwc' || true
  echo "=== dp_sec ==="
  for f in /sys/class/dp_sec/*; do
    [ -f "$f" ] || continue
    echo -n "$(basename "$f")="; cat "$f" 2>/dev/null; echo
  done
  echo "=== fb1 ==="
  ls -l /dev/graphics/fb1 2>/dev/null || echo "no /dev/graphics/fb1"
  for f in /sys/class/graphics/fb1/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in bits_per_pixel|stride|virtual_size|screen_info|mode|name|blank)
      echo -n "$(basename "$f")="; cat "$f" 2>/dev/null; echo ;;
    esac
  done
  echo "=== decon_t vsync ==="
  ls -l /sys/devices/platform/16050000.decon_t/vsync 2>/dev/null || echo "no decon_t vsync"
  echo "=== extcon ==="
  for e in /sys/class/extcon/*; do
    echo -n "$(cat "$e/name" 2>/dev/null): "; cat "$e/state" 2>/dev/null; echo
  done
  echo "=== platform displayport extcon cables ==="
  for c in /sys/devices/platform/11090000.displayport/extcon/extcon*/cable.*/state; do
    [ -e "$c" ] && echo "$c=$(cat "$c" 2>/dev/null)"
  done
  echo "=== dumpsys display (external-ish) ==="
  dumpsys display 2>/dev/null | grep -iE 'display |external|hdmi|displayport|uniqueid|type=' | head -80
  echo "=== dumpsys display (head) ==="
  dumpsys display 2>/dev/null | head -120
  echo "=== logcat HWC/External (last) ==="
  logcat -d -t 400 2>/dev/null | grep -iE 'ExynosExternal|ExternalDisplay|openExternalDisplay|Failed to open|hotplug|fb1|displayport|HwComposer|HPD' | tail -120
  echo "=== dmesg dp/decon / HWC takeover ==="
  dmesg | grep -iE 'displayport|decon2|bist|prefer_live|hpd_owner|HWC takeover|kick_decon|solid color|timeout of updating|WIN_RSC|DMA_CH|CCIC_NOTIFY|hpd|FIFO_UNDER' | tail -250
} > "$OUT" 2>&1
echo "Wrote $OUT"
