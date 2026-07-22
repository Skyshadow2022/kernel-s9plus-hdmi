#!/system/bin/sh
MODDIR=${0%/*}
# Prefer magic-mounted firmware path; fall back to direct insmod.
insmod "$MODDIR/system/lib/modules/sec_ts_drv.ko" 2>/dev/null || \
  insmod /system/lib/modules/sec_ts_drv.ko 2>/dev/null
