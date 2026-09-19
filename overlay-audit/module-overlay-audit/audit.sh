#!/system/bin/sh
# overlay-audit - work out who owns every file in this device's hand-built
# overlay, and what conflicts exist between modules.
#
# Why this exists: /vendor is served by a hand-built overlayfs whose upper dir
# (/cache/overlay/vendor/upper) is shared by everything that wants to add a
# vendor file. Nothing tracked ownership, so when an audio module wrote its
# libraries there the audio HAL broke, and clearing the upper to fix it also
# deleted the touchscreen firmware and caused a boot loop.
#
#   audit.sh                 full report
#   audit.sh owner <path>    who provides a specific overlay file
#   audit.sh remove <id>     remove ONLY that module's files from the overlay
#   audit.sh webui           the report as one line, for the KernelSU WebUI
#
# Overlay sources are found from /proc/mounts, so this adapts if the layout
# changes. Ownership is decided by per-module system/ trees, by content hash
# first and by relative path second.

MODULES=/data/adb/modules
MOUNTIFY_DIR=/data/adb/mountify
LOG=${AUDIT_LOG:-/sdcard/overlay-audit.txt}

say() { echo "$*"; if [ -n "$LOG" ]; then echo "$*" >> "$LOG"; fi; }
hr()  { say ""; }

# Every overlay mount whose upperdir lives outside a tmpfs is one of ours.
overlay_uppers() {
  # /proc/mounts fields: dev mountpoint fstype options dump pass
  grep -E ' overlay ' /proc/mounts 2>/dev/null | while read -r dev mp fstype opts rest; do
    up=$(echo "$opts" | tr ',' '\n' | sed -n 's/^upperdir=//p')
    [ -n "$up" ] || continue
    case "$up" in /mnt/*|/dev/*) continue ;; esac   # tmpfs-backed = mountify runtime
    echo "$mp $up"
  done
}

module_ids() {
  for d in $MODULES/*/; do
    [ -d "$d/system" ] || continue
    [ -f "$d/disable" ] && continue
    [ -f "$d/remove" ] && continue
    basename "$d"
  done
}

# owner_of <abs-path-in-overlay> -> prints "id identical" / "id DIFFERS" / ""
# owner_of <abs-overlay-file> <mountpoint> <overlay-relative-path>
# An overlay file at /vendor/firmware/x comes from a module as
# system/vendor/firmware/x - the mountpoint is the missing piece.
owner_of() {
  f=$1; mp=$2; rel=$3
  h=$(sha256sum "$f" 2>/dev/null | awk '{print $1}')
  for id in $(module_ids); do
    cand="$MODULES/$id/system${mp}${rel}"
    [ -f "$cand" ] || continue
    ch=$(sha256sum "$cand" 2>/dev/null | awk '{print $1}')
    if [ "$h" = "$ch" ]; then echo "$id identical"; else echo "$id DIFFERS"; fi
    return
  done
  for id in $(module_ids); do
    if [ -e "$MODULES/$id/system${mp}${rel}" ]; then echo "$id path-only"; return; fi
  done
  echo ""
}

cmd_report() {
  if [ -n "$LOG" ]; then : > "$LOG" 2>/dev/null; fi
  say "=== star2lte overlay audit - $(date) ==="
  say "kernel: $(uname -r)"

  hr; say "--- overlay mounts ---"
  overlay_uppers | while read -r mp up; do say "  $mp   upper=$up"; done
  if ! overlay_uppers | grep -q .; then say "  (none)"; fi

  hr; say "--- mountify ---"
  if [ -f "$MOUNTIFY_DIR/config.sh" ]; then
    mode=$(sed -n 's/^mountify_mounts=//p' "$MOUNTIFY_DIR/config.sh" | head -1)
    case "$mode" in
      1) say "  mode: MANUAL (mountify_mounts=1) - mounts only ids in modules.txt" ;;
      2) say "  mode: AUTO (mountify_mounts=2) - mounts every module with system/" ;;
      0) say "  mode: disabled" ;;
      *) say "  mode: ? ($mode)" ;;
    esac
    if [ "$mode" = "1" ]; then
      if grep -qv '#' "$MOUNTIFY_DIR/modules.txt" 2>/dev/null; then
        say "  modules.txt: $(grep -v '^#' "$MOUNTIFY_DIR/modules.txt" | tr '\n' ' ')"
      else
        say "  [!] modules.txt has no active line"
        say "      mountify will silently switch to AUTO mode and mount every module."
      fi
    fi
  else
    say "  mountify not installed"
  fi

  hr; say "--- module system/ trees ---"
  for id in $(module_ids); do
    n=$(find "$MODULES/$id/system" -type f 2>/dev/null | wc -l | tr -d ' ')
    say "  $id: $n file(s)"
  done

  hr; say "--- overlay inventory + ownership ---"
  total=0; owned=0; orphan=0; differ=0
  while read -r mp up; do
    [ -n "$up" ] || continue
    [ -d "$up" ] || continue
    for f in $(find "$up" -type f 2>/dev/null); do
      rel=${f#$up}
      total=$((total + 1))
      o=$(owner_of "$f" "$mp" "$rel")
      set -- $o
      case "$2" in
        identical) owned=$((owned + 1)); say "  ${rel}  <- $1" ;;
        DIFFERS)   differ=$((differ + 1)); say "  ${rel}  <- $1  [STALE: module ships a different copy]" ;;
        path-only) orphan=$((orphan + 1)); say "  ${rel}  <- $1  [path matches, content differs]" ;;
        *)         orphan=$((orphan + 1)); say "  ${rel}  [ORPHAN - no module provides this]" ;;
      esac
    done
  done <<EOF
$(overlay_uppers)
EOF
  say "  $total file(s): $owned from a module, $orphan orphan/differing, $differ stale"

  hr; say "--- conflicts ---"
  # Counted in a file, not a variable: most of these checks run in pipelines.
  TMP=/data/local/tmp/.audit-conflicts.$$
  : > "$TMP"
  issue() { echo "$*" >> "$TMP"; }

  # 1. whiteouts that remove something the system needs in order to boot.
  #    /system/bin/servicemanager is binder itself; hiding it is unrecoverable.
  if [ -f "$MOUNTIFY_DIR/whiteouts.txt" ]; then
    while read -r w; do
      case "$w" in ''|\#*) continue ;; esac
      case "$w" in
        */bin/*|*/bin)
          issue "  [CRITICAL] whiteout hides $w - a system binary; this is a boot risk" ;;
        *)
          issue "  [info] whiteout hides $w" ;;
      esac
    done <<EOF
$(sed '/^#/d' "$MOUNTIFY_DIR/whiteouts.txt" 2>/dev/null)
EOF
  fi

  # 2. modules shipping kernel drivers. Touch is built into the running kernel,
  #    so a .ko overlay can only replace a working driver with a stale one.
  for id in $(module_ids); do
    for k in "$MODULES/$id"/system/lib/modules/*.ko; do
      [ -f "$k" ] || continue
      b=$(basename "$k"); live=/system/lib/modules/$b
      if [ -f "$live" ]; then
        if [ "$(sha256sum "$k" | awk '{print $1}')" = "$(sha256sum "$live" | awk '{print $1}')" ]; then
          issue "  [info] $id ships $b (identical to the live driver)"
        else
          issue "  [CRITICAL] $id ships $b, which DIFFERS from $live - mounting it replaces a working driver"
        fi
      else
        issue "  [info] $id ships $b (no live counterpart)"
      fi
    done
  done

  # 3. overlay files nothing owns, or whose owner ships a different copy
  [ "${orphan:-0}" -gt 0 ] && issue "  [HIGH] $orphan overlay file(s) with no owning module - see the inventory above"
  [ "${differ:-0}" -gt 0 ] && issue "  [HIGH] $differ overlay file(s) are stale: the owning module ships a different copy"

  # 4. two modules claiming the same path - the winner depends on mount order
  for id in $(module_ids); do
    find "$MODULES/$id/system" -type f 2>/dev/null | sed "s|$MODULES/$id/system||;s|^|$id |"
  done | sort -k2 | awk '{c[$2]=c[$2]" "$1} END{for(k in c){n=split(c[k],a," ");if(n>1)print "  [HIGH] "k" claimed by"c[k]}}' >> "$TMP"

  # 5. modules.txt entries pointing at modules that are gone
  if [ -f "$MOUNTIFY_DIR/modules.txt" ]; then
    while read -r line; do
      case "$line" in ''|\#*|__none__) continue ;; esac
      [ -d "$MODULES/$line" ] || issue "  [HIGH] modules.txt lists '$line' but it is not installed"
    done <<EOF
$(sed '/^#/d' "$MOUNTIFY_DIR/modules.txt" 2>/dev/null)
EOF
  fi

  hr
  if [ -s "$TMP" ]; then
    cat "$TMP"
    crit=$(grep -c CRITICAL "$TMP"); hi=$(grep -c 'HIGH' "$TMP")
    say ""
    if [ "$crit" -gt 0 ]; then
      say "  $crit CRITICAL, $hi to review."
    else
      say "  no critical conflicts; $hi item(s) to review."
    fi
  else
    say "  none - no orphan files, no overlapping paths, no stale entries."
  fi
  rm -f "$TMP"
  say ""
  say "to remove one module's files from the overlay without touching anyone"
  say "else's:   sh $0 remove <module-id>"
}

cmd_remove() {
  id=$1
  [ -n "$id" ] || { echo "usage: $0 remove <module-id>"; exit 2; }
  [ -d "$MODULES/$id/system" ] || { echo "no such module: $id"; exit 2; }
  n=0
  overlay_uppers | while read -r mp up; do
    [ -d "$up" ] || continue
    for f in $(find "$up" -type f 2>/dev/null); do
      rel=${f#$up}
      if [ -e "$MODULES/$id/system/$rel" ]; then
        rm -f "$f" && { echo "removed $f"; n=$((n + 1)); }
      fi
    done
    find "$up" -type d -empty -delete 2>/dev/null
  done
  echo "$n file(s) removed for '$id'. Nothing else was touched."
  echo "Reboot for the overlay to rebuild."
}

# The KernelSU WebUI bridge returns only the last line of stdout, so the whole
# report has to arrive as one line. Lines are joined with ';;'.
cmd_webui() {
  LOG=""
  cmd_report 2>&1 | awk '{ gsub(/\r/, ""); printf "%s;;", $0 }'
  echo ""
}

case "$1" in
  owner)  shift; owner_of "$1" ;;
  remove) shift; cmd_remove "$1" ;;
  webui)  cmd_webui ;;
  report) cmd_report ;;
  *)      cmd_report ;;
esac
