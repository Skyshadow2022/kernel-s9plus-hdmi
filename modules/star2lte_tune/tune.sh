#!/system/bin/sh
# star2lte-tune - runtime tuning for Exynos 9810 / kernel 4.9.337
# Every write is guarded: a missing or read-only node is skipped, never fatal.

LOG=/data/adb/star2lte_tune.log
CONF=/data/adb/star2lte_tune.conf

# --- defaults (override in $CONF) ---
# PROFILE=gaming|balanced|battery
#   gaming   : unlock big cluster, faster schedutil ramp, higher GPU floor
#   balanced : partial unlock (2.1GHz), mild GPU bump
#   battery  : leave thermal HAL caps alone
PROFILE=gaming
# Profile-independent defaults
LITTLE_MIN_FREQ=598000
BIG_MIN_FREQ=741000
PAGE_CLUSTER=0
MIN_FREE_KB=""
EXTRA_FREE_KB=""
WATERMARK_SCALE=""
VFS_CACHE_PRESSURE=50
TUNE_NET=1
IO_SCHED=cfq
# schedutil: lower = snappier frequency ramp for games (us)
SCHEDUTIL_DOWN_RATE=20000
# Mali-G72 Interactive floor (kHz). Table: 260 299 338 455 546 572
GPU_GOVERNOR=Interactive
GPU_POWEROFF_DELAY=5

# Pass 1: read CONF only to learn which PROFILE was chosen.
[ -f "$CONF" ] && . "$CONF"

# Profile presets, assigned unconditionally.
#
# The previous form was BIG_MAX_FREQ=${BIG_MAX_FREQ:-2106000}. ${VAR:-x} only
# substitutes x when VAR is empty, and every one of these was already set a
# few lines up - so PROFILE=balanced and PROFILE=battery silently kept the
# gaming numbers (2314000 / swappiness 60). Tested: all three profiles
# produced identical values except UNLOCK_BIG_CORES.
PROFILE_UNKNOWN=""
case "$PROFILE" in
  gaming)   UNLOCK_BIG_CORES=1; BIG_MAX_FREQ=2314000; SWAPPINESS=60; SCHEDUTIL_UP_RATE=1000; GPU_MIN_CLOCK=338000 ;;
  balanced) UNLOCK_BIG_CORES=1; BIG_MAX_FREQ=2106000; SWAPPINESS=70; SCHEDUTIL_UP_RATE=2000; GPU_MIN_CLOCK=299000 ;;
  battery)  UNLOCK_BIG_CORES=0; BIG_MAX_FREQ="";      SWAPPINESS=80; SCHEDUTIL_UP_RATE=5000; GPU_MIN_CLOCK=260000 ;;
  *)        PROFILE_UNKNOWN="$PROFILE"; PROFILE=gaming
            UNLOCK_BIG_CORES=1; BIG_MAX_FREQ=2314000; SWAPPINESS=60; SCHEDUTIL_UP_RATE=1000; GPU_MIN_CLOCK=338000 ;;
esac

# Pass 2: explicit values in CONF win over the preset.
[ -f "$CONF" ] && . "$CONF"
# Pass 2 re-reads the typo too; keep the label honest about what ran.
[ -n "$PROFILE_UNKNOWN" ] && PROFILE=gaming

log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }

# write <value> <path>  -- verifies the value actually stuck
w() {
  [ -w "$2" ] || { log "SKIP (not writable): $2"; return 1; }
  echo "$1" > "$2" 2>/dev/null
  new=$(cat "$2" 2>/dev/null)
  case "$new" in
    "$1"|*"[$1]"*) log "OK   $2 = $1"; return 0 ;;
    *)             log "WARN $2 -> wanted $1, got $new"; return 1 ;;
  esac
}

: > "$LOG"
log "=== star2lte-tune start ==="
log "kernel: $(uname -r) profile=$PROFILE"
[ -n "$PROFILE_UNKNOWN" ] && log "WARN unknown PROFILE=$PROFILE_UNKNOWN - fell back to gaming"

# ---------------------------------------------------------------
# 1. Memory reclaim
# ---------------------------------------------------------------
[ -n "$MIN_FREE_KB" ]     && w "$MIN_FREE_KB"     /proc/sys/vm/min_free_kbytes
[ -n "$EXTRA_FREE_KB" ]   && w "$EXTRA_FREE_KB"   /proc/sys/vm/extra_free_kbytes
[ -n "$WATERMARK_SCALE" ] && w "$WATERMARK_SCALE" /proc/sys/vm/watermark_scale_factor
[ -z "$MIN_FREE_KB$EXTRA_FREE_KB$WATERMARK_SCALE" ] && log "watermarks: left at kernel defaults"
w 1 /proc/sys/vm/compact_unevictable_allowed

# ---------------------------------------------------------------
# 2. zram / VM — gaming prefers less aggressive swap-out of anon
# ---------------------------------------------------------------
w "$PAGE_CLUSTER"       /proc/sys/vm/page-cluster
w "$SWAPPINESS"         /proc/sys/vm/swappiness
w "$VFS_CACHE_PRESSURE" /proc/sys/vm/vfs_cache_pressure

# ---------------------------------------------------------------
# 3. Storage queue
# ---------------------------------------------------------------
for q in /sys/block/sd?/queue; do
  [ -d "$q" ] || continue
  [ -f "$q/scheduler" ] && w "$IO_SCHED" "$q/scheduler"
  w 0 "$q/add_random"
  w 0 "$q/iostats"
done
if [ -d /sys/block/zram0/queue ]; then
  w 2 /sys/block/zram0/queue/nomerges
  w 0 /sys/block/zram0/queue/iostats
fi

# ---------------------------------------------------------------
# 3b. Network — BBR + fq already preferred; gaming extras
# ---------------------------------------------------------------
if [ "$TUNE_NET" = "1" ]; then
  w fq  /proc/sys/net/core/default_qdisc
  w 0   /proc/sys/net/ipv4/tcp_slow_start_after_idle
  w 3   /proc/sys/net/ipv4/tcp_fastopen
  w bbr /proc/sys/net/ipv4/tcp_congestion_control
  # Larger TCP buffers help COD / UDP-heavy sessions on Wi-Fi
  w 16777216 /proc/sys/net/core/rmem_max
  w 16777216 /proc/sys/net/core/wmem_max
  w "4096 87380 16777216" /proc/sys/net/ipv4/tcp_rmem
  w "4096 65536 16777216" /proc/sys/net/ipv4/tcp_wmem
  # Prefer low latency over bulk throughput fairness for interactive sockets
  [ -w /proc/sys/net/ipv4/tcp_low_latency ] && w 1 /proc/sys/net/ipv4/tcp_low_latency
else
  log "network tuning skipped (TUNE_NET=0)"
fi

# ---------------------------------------------------------------
# 4. CPU — schedutil ramp + optional big unlock
#    Thermal HAL re-caps scaling_max_freq after boot; service.sh re-applies.
# ---------------------------------------------------------------
for pol in /sys/devices/system/cpu/cpufreq/policy0 /sys/devices/system/cpu/cpufreq/policy4; do
  [ -d "$pol/schedutil" ] || continue
  w "$SCHEDUTIL_UP_RATE"   "$pol/schedutil/up_rate_limit_us"
  w "$SCHEDUTIL_DOWN_RATE" "$pol/schedutil/down_rate_limit_us"
done

[ -n "$LITTLE_MIN_FREQ" ] && w "$LITTLE_MIN_FREQ" /sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq
[ -n "$BIG_MIN_FREQ" ] && w "$BIG_MIN_FREQ" /sys/devices/system/cpu/cpufreq/policy4/scaling_min_freq

if [ "$UNLOCK_BIG_CORES" = "1" ]; then
  hw=$(cat /sys/devices/system/cpu/cpu4/cpufreq/cpuinfo_max_freq 2>/dev/null)
  target="$BIG_MAX_FREQ"
  [ -z "$target" ] && target=$hw
  # Clamp to silicon max
  if [ -n "$hw" ] && [ -n "$target" ] && [ "$target" -gt "$hw" ] 2>/dev/null; then
    target=$hw
  fi
  [ -n "$target" ] && w "$target" /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq
  log "big cluster target max=$target (hw_max=$hw)"
else
  log "big cluster cap left to thermal HAL (battery profile)"
fi

# ---------------------------------------------------------------
# 5. Mali-G72 — raise interactive floor, shorten power-off delay
# ---------------------------------------------------------------
if [ -d /sys/kernel/gpu ]; then
  [ -n "$GPU_GOVERNOR" ] && w "$GPU_GOVERNOR" /sys/kernel/gpu/gpu_governor
  [ -n "$GPU_MIN_CLOCK" ] && w "$GPU_MIN_CLOCK" /sys/kernel/gpu/gpu_min_clock
  [ -n "$GPU_MIN_CLOCK" ] && w "$GPU_MIN_CLOCK" /sys/kernel/gpu/gpu_mm_min_clock
  [ -n "$GPU_POWEROFF_DELAY" ] && w "$GPU_POWEROFF_DELAY" /sys/kernel/gpu/gpu_poweroff_delay
fi

log "=== done ==="
