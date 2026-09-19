#!/system/bin/sh
# Runs as root when ACTION is tapped in the KernelSU manager.
#
# This module is READ-ONLY on purpose. The module it replaces
# (star2lte_audiofix) had an ACTION button that moved the whole /vendor overlay
# upper aside; that directory also held the touchscreen firmware, so tapping it
# left the device in a boot loop. Nothing here moves, renames or deletes
# anything - it only reads and prints.

MODDIR=${0%/*}
SH=/data/adb/star2lte-audit/audit.sh
[ -f "$SH" ] || SH="$MODDIR/audit.sh"

echo "==============================================="
echo " star2lte overlay audit"
echo " read-only: nothing is moved, renamed or deleted"
echo "==============================================="
echo ""
sh "$SH" report
echo ""
echo "-----------------------------------------------"
echo "To remove one module's overlay files (terminal"
echo "only, never from this button):"
echo "  su -c 'sh $SH remove <module-id>'"
echo "==============================================="
