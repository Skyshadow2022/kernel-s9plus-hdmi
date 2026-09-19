#!/system/bin/sh
# Nothing this module did survives it, so there is nothing to undo. It only
# read files and wrote a report to /sdcard.
rm -rf /data/adb/star2lte-audit
rm -f /sdcard/star2lte-overlay-audit.txt
