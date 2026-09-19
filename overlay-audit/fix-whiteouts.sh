#!/system/bin/sh
# Rewrite mountify's whiteout list with only app-level debloat entries.
W=/data/adb/mountify/whiteouts.txt

cat > "$W" <<'WOEOF'
# mountify whiteout list - star2lte
#
# Only app-level debloat belongs here. Anything under a bin/ directory is off
# limits: /system/bin/servicemanager is binder itself, and hiding it leaves the
# device with no binder at boot.
#
# Removed 2026-09-18 because they are boot-critical or pointless:
#   /system/bin/servicemanager
#   /system/bin/install-recovery.sh
#   /system/vendor/bin/install-recovery.sh
#   /system/vendor/bin/msm_irqbalance
#   /system/odm/etc/NOTICE.xml.gz
#
# Note: no mountify_whiteouts module has been generated, so this list is not
# applied today. It is fixed now so that generating it later is safe.
/system/system_ext/app/MatLog
/system/system_ext/priv-app/AudioFX
/system/product/app/PowerOffAlarm
/system/product/app/Twelve
/system/etc/nikgapps_logs_archive
/system/etc/nikgapps_logs
WOEOF

echo "=== active lines now ==="
grep -v '^#' "$W" | grep -n .
echo "  servicemanager path entries: $(grep -c '^/system/bin/servicemanager' "$W")"

rmdir /data/adb/modules/ak3-helper/system/lib 2>/dev/null && \
  echo "removed empty system/lib from ak3-helper"
