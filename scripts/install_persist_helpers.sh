#!/usr/bin/env bash
# Push/reinstall touch + DP helpers that should survive day-to-day use.
# Kernel zip flash does not always restore /data/adb modules (FBE in recovery).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB="${ADB:-$ROOT/.tools/platform-tools/adb}"

$ADB wait-for-device
$ADB root >/dev/null 2>&1 || true
sleep 1

$ADB shell 'mkdir -p /data/adb/modules/ak3-helper/system/lib/modules /data/adb/modules/ak3-helper/system/vendor/firmware/tsp_sec /data/adb/modules/dp-hdmi-helper'
$ADB push "$ROOT/vendor_modules/ak3-helper/." /data/adb/modules/ak3-helper/
$ADB push "$ROOT/vendor_modules/dp-hdmi-helper/." /data/adb/modules/dp-hdmi-helper/
if [[ -f "$ROOT/out_gkilike/modules/sec_ts_drv.ko" ]]; then
  $ADB push "$ROOT/out_gkilike/modules/sec_ts_drv.ko" /data/adb/modules/ak3-helper/system/lib/modules/sec_ts_drv.ko
fi
if [[ -f "$ROOT/out_gkilike/modinst/lib/firmware/tsp_sec/y761_star2.fw" ]]; then
  $ADB push "$ROOT/out_gkilike/modinst/lib/firmware/tsp_sec/y761_star2.fw" \
    /data/adb/modules/ak3-helper/system/vendor/firmware/tsp_sec/y761_star2.fw
fi
$ADB push "$ROOT/scripts/dp_hdmi_debug.sh" /data/local/tmp/dp_hdmi_debug.sh
$ADB shell 'chmod 755 /data/adb/modules/ak3-helper/post-fs-data.sh /data/adb/modules/dp-hdmi-helper/*.sh /data/local/tmp/dp_hdmi_debug.sh; ls /data/adb/modules'
echo 'Helpers installed. Reboot recommended if modules_update pending.'
