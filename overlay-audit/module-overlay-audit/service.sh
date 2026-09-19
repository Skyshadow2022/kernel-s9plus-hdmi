#!/system/bin/sh
# Publishes audit.sh at a stable path outside the module directory, so the
# WebUI and the ACTION button keep working across module updates, and writes a
# report once per boot to /sdcard where it can be read without root.
#
# Read-only. Nothing here modifies the overlay, any module, or mountify.

MODDIR=${0%/*}
RUNDIR=/data/adb/star2lte-audit

mkdir -p "$RUNDIR" 2>/dev/null
cp -f "$MODDIR/audit.sh" "$RUNDIR/audit.sh" 2>/dev/null
chmod 755 "$RUNDIR/audit.sh" 2>/dev/null

until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 3; done
sleep 40

AUDIT_LOG=/dev/null sh "$RUNDIR/audit.sh" report > /sdcard/star2lte-overlay-audit.txt 2>&1
