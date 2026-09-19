#!/system/bin/sh
# SUSFS hiding policy, re-applied every boot (SUSFS state lives in the kernel
# only, so it must be re-set after each boot).
#
# What this hides from ordinary (non-root) apps:
#   - the custom kernel release string (uname spoof, stock Samsung A10 style)
#   - bootloader-state leaks in /proc/cmdline: verifiedbootstate=orange,
#     flash.locked=0, vbmeta.device_state=unlocked, buildvariant=userdebug
#   - the existence of /data/adb, /data/adb/ksu, /data/adb/modules (sus_path)
#   - SELinux denials mentioning the ksu domain (avc log spoofing)
#
# What this does NOT do: Play Integrity / keybox attestation. That needs a
# working PIF or TrickyStore; no kernel patch replaces a keybox.

MODDIR=${0%/*}
TOOL="$MODDIR/ksu_susfs"
RP=/data/adb/ksu/bin/resetprop
LOG=/sdcard/star2lte-susfs.log

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 3; done
sleep 15

log "=== SUSFS hide policy start (kernel: $(uname -r)) ==="

# 1. uname spoof - stock Samsung Galaxy S9+ Android 10 era kernel
$TOOL uname "4.9.219" "#1 SMP PREEMPT Mon Apr 6 18:31:32 KST 2020" \
  && log "uname spoofed to 4.9.219 (Samsung A10 style)" \
  || log "uname spoof FAILED"

# 2. /proc/cmdline - rewrite bootloader-state leaks, keep everything else
REAL=$(cat /proc/cmdline 2>/dev/null)
FAKE=$(printf '%s' "$REAL" \
  | sed -e 's/verifiedbootstate=orange/verifiedbootstate=green/g' \
        -e 's/flash\.locked=0/flash.locked=1/g' \
        -e 's/vbmeta\.device_state=unlocked/vbmeta.device_state=locked/g' \
        -e 's/buildvariant=userdebug/buildvariant=user/g')
if [ -n "$FAKE" ] && [ "$FAKE" != "$REAL" ]; then
  $TOOL cmdline "$FAKE" && log "cmdline spoofed (bootloader-state leaks rewritten)" \
                      || log "cmdline spoof FAILED"
else
  log "cmdline clean already, nothing to spoof"
fi

# 3. properties - PIF is disabled on this device, so keep the boot props sane
#    (its old resetprop values die on every reboot)
if [ -x "$RP" ]; then
  $RP -n ro.boot.verifiedbootstate green
  $RP -n ro.boot.flash.locked 1
  $RP -n ro.boot.vbmeta.device_state locked
  $RP -n ro.boot.warranty_bit 0
  $RP -n ro.warranty_bit 0
  log "boot props re-spoofed (verifiedbootstate/flash.locked/vbmeta/warranty)"
else
  log "resetprop not found - boot props NOT spoofed"
fi

# 4. sus_path - the directories that scream "root" if stat'd
for p in /data/adb /data/adb/ksu /data/adb/modules; do
  $TOOL path "$p" && log "sus_path: $p" || log "sus_path FAILED: $p"
done

# 5. hide SELinux denials that mention the ksu domain
$TOOL avcspoof 1 && log "avc log spoofing on" || log "avc spoof FAILED"

log "=== done ==="
