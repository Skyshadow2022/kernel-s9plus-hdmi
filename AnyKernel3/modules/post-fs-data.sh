#!/system/bin/sh
# Magisk/KernelSU post-fs-data helper: load Pseudo-GKI vendor modules.
# Invoked as post-fs-data.2.sh from ak3-helper module root
MODDIR=${0%/*}
MODPATH="$MODDIR"
KVER=$(uname -r)
CANDIDATES="
$MODPATH/system/lib/modules
$MODPATH/system/lib/modules/$KVER
/system/lib/modules
/system/lib/modules/$KVER
"

# Ensure touch firmware is visible before sec_ts_drv probes
if [ -d "$MODPATH/system/vendor/firmware/tsp_sec" ] && [ ! -e /vendor/firmware/tsp_sec/y761_star2.fw ]; then
  mkdir -p /vendor/firmware/tsp_sec 2>/dev/null
  cp -f "$MODPATH/system/vendor/firmware/tsp_sec/"* /vendor/firmware/tsp_sec/ 2>/dev/null
fi

load_one() {
  name="$1"
  for d in $CANDIDATES; do
    if [ -f "$d/$name.ko" ]; then
      insmod "$d/$name.ko" 2>/dev/null && return 0
      # Already loaded / soft fail
      lsmod 2>/dev/null | grep -q "^$name " && return 0
    fi
  done
  return 1
}

LIST=""
for d in $CANDIDATES; do
  if [ -f "$d/modules.load" ]; then
    LIST="$d/modules.load"
    break
  fi
done

if [ -n "$LIST" ]; then
  while read -r mod || [ -n "$mod" ]; do
    case "$mod" in
      ""|\#*) continue ;;
    esac
    load_one "$mod"
  done < "$LIST"
else
  load_one sec_ts_drv
fi

exit 0
