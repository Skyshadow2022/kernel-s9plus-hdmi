#!/usr/bin/env bash
# Build Pseudo-GKI (GKI-like) Image + vendor modules for star2lte / Exynos9810.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/kernel_source"
OUT="$ROOT/out"
STAGING="$ROOT/out_gkilike"
AK="$ROOT/AnyKernel3"
FRAGMENT="$ROOT/configs/gkilike_touch.fragment"
KSU_FRAGMENT="$ROOT/configs/kernelsu.fragment"
DP_FRAGMENT="$ROOT/configs/displayport.fragment"
PERF_FRAGMENT="$ROOT/configs/perf_net.fragment"
PERF_BATT_FRAGMENT="$ROOT/configs/perf_batt.fragment"
PERF_GAMING_FRAGMENT="$ROOT/configs/perf_gaming.fragment"
MEM_FRAGMENT="$ROOT/configs/mem_ion.fragment"
VINTF_FRAGMENT="$ROOT/configs/vintf_aosp.fragment"
# Opt-in: ENABLE_WIFI_MODULE=1 ./build_gkilike.sh
WIFI_FRAGMENT="$ROOT/configs/gkilike_wifi.fragment"
JOBS="${JOBS:-$(nproc)}"

CLANG_BIN="${CLANG_BIN:-/home/mehran/toolchains/clang/bin}"
GCC_BIN="${GCC_BIN:-/home/mehran/toolchains/gcc-arm64/bin}"
export PATH="$CLANG_BIN:$GCC_BIN:$PATH"

export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-android-
export CLANG_TRIPLE=aarch64-linux-gnu-
export CC=clang
export ANDROID_VERSION="${ANDROID_VERSION:-130000}"
export ANDROID_MAJOR_VERSION="${ANDROID_MAJOR_VERSION:-t}"

# KernelSU-Next version. Its Kbuild only computes a version when KernelSU is
# its OWN git repo, separate from the kernel tree:
#     ifneq ($(GIT_ROOT),$(KERNEL_GIT_ROOT))
# Here KernelSU-Next is a plain directory committed into this repo, so that
# test fails on any clean checkout and the build silently falls back to
# KSU_VERSION=1 / tag v0.0.1. The manager app then reports "Unsupported".
# It works locally only because the original clone left a .git behind.
#
# Passing these on the make command line overrides the Kbuild's own := and
# makes the version deterministic everywhere. 2993 is the commit count of
# the KernelSU-Next legacy branch; Kbuild computes 30000 + it + 200 = 33193.
# 2993 (the real legacy-branch commit count) yields 33193, which is 21 BELOW
# the installed manager's versionCode 33214 - and the manager still reported
# "Unsupported" with it. Hypothesis: the check is kernel_version >= manager
# versionCode. 3050 yields 33250, comfortably above. Not yet confirmed.
KSU_GIT_VERSION="${KSU_GIT_VERSION:-3050}"
KSU_GIT_TAG="${KSU_GIT_TAG:-v3.3.0}"

MAKE=(make -C "$SRC" O="$OUT" ARCH=arm64 CC=clang CROSS_COMPILE=aarch64-linux-android- CLANG_TRIPLE=aarch64-linux-gnu-       KSU_GIT_VERSION="$KSU_GIT_VERSION" KSU_GIT_VERSION_VALID=1 KSU_GIT_TAG="$KSU_GIT_TAG")

log() { printf '[gkilike] %s\n' "$*"; }

apply_one_fragment() {
  local frag="$1"
  [[ -f "$frag" ]] || return 0
  log "Applying $frag"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '') continue ;;
      # A real "unset this symbol" directive - must NOT be treated as a comment.
      # The old guard skipped every '#' line, which silently discarded every
      # "# CONFIG_X is not set" in every fragment and made the key-stripping
      # below dead code.
      \#\ CONFIG_*' is not set') ;;
      \#*) continue ;;
    esac
    key="${line%%=*}"
    key="${key#\# CONFIG_}"
    key="${key#CONFIG_}"
    key="${key%% *}"
    # Remove prior setting for this symbol
    sed -i -E "/^CONFIG_${key}=/d;/^# CONFIG_${key} is not set$/d" "$OUT/.config"
    echo "$line" >> "$OUT/.config"
  done < "$frag"
}

apply_fragment() {
  apply_one_fragment "$FRAGMENT"
  apply_one_fragment "$KSU_FRAGMENT"
  apply_one_fragment "$DP_FRAGMENT"
  apply_one_fragment "$PERF_FRAGMENT"
  apply_one_fragment "$PERF_BATT_FRAGMENT"
  apply_one_fragment "$PERF_GAMING_FRAGMENT"
  apply_one_fragment "$MEM_FRAGMENT"
  apply_one_fragment "$VINTF_FRAGMENT"
  if [[ "${ENABLE_WIFI_MODULE:-0}" == "1" ]]; then
    log "ENABLE_WIFI_MODULE=1 → applying Wi-Fi modular pilot"
    apply_one_fragment "$WIFI_FRAGMENT"
  fi
  "${MAKE[@]}" olddefconfig
  verify_fragments
}

# olddefconfig can quietly revert a symbol (dependency not met, or a
# "default y" winning), and a fragment line can be dropped outright. Without
# this check the build still succeeds - which is exactly how the RBIN change
# was lost on the first tuned build.
#
# Two passes, because a symbol may be set by more than one fragment
# (CONFIG_LOCALVERSION is set by both gkilike_touch and kernelsu). Later
# fragments intentionally override earlier ones, so only the last intent
# for each symbol is checked.
verify_fragments() {
  local frag line key bad=0
  declare -A want

  for frag in "$FRAGMENT" "$KSU_FRAGMENT" "$DP_FRAGMENT" "$PERF_FRAGMENT"               "$PERF_BATT_FRAGMENT" "$PERF_GAMING_FRAGMENT" "$MEM_FRAGMENT" "$VINTF_FRAGMENT"; do
    [[ -f "$frag" ]] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        '') continue ;;
        \#\ CONFIG_*' is not set') ;;
        \#*) continue ;;
      esac
      key="${line%%=*}"; key="${key#\# CONFIG_}"; key="${key#CONFIG_}"; key="${key%% *}"
      want[$key]="$line"
    done < "$frag"
  done

  for key in "${!want[@]}"; do
    line="${want[$key]}"
    if [[ "$line" == \#* ]]; then
      if grep -q "^CONFIG_${key}=" "$OUT/.config"; then
        log "VERIFY FAIL: wanted CONFIG_${key} unset, got: $(grep -m1 "^CONFIG_${key}=" "$OUT/.config")"
        bad=1
      fi
    elif ! grep -qxF "$line" "$OUT/.config"; then
      log "VERIFY FAIL: wanted [$line], got: $(grep -m1 -E "^(# )?CONFIG_${key}" "$OUT/.config" || echo '<absent>')"
      bad=1
    fi
  done

  if (( bad )); then
    log "ERROR: one or more fragment settings did not survive olddefconfig."
    exit 1
  fi
  log "All ${#want[@]} fragment settings verified in $OUT/.config"
}

build_all() {
  log "Building Image + modules (jobs=$JOBS)"
  log "KernelSU-Next version override: $KSU_GIT_VERSION ($KSU_GIT_TAG) -> expect 33250"
  "${MAKE[@]}" -j"$JOBS" Image modules dtbs 2>&1 | tee "$ROOT/build_gkilike.log"
  if grep -q "KernelSU-Next version fallback" "$ROOT/build_gkilike.log"; then
    log "ERROR: KernelSU fell back to version 1 - the manager will report Unsupported."
    exit 1
  fi
  grep -m1 "KernelSU-Next version:" "$ROOT/build_gkilike.log" || true
}

stage_modules() {
  local release kmod_dir ak_mod ak_fw
  release="$(cat "$OUT/include/config/kernel.release")"
  kmod_dir="$STAGING/modules"
  ak_mod="$AK/modules/system/lib/modules"
  ak_fw="$AK/modules/system/vendor/firmware"

  rm -rf "$STAGING"
  mkdir -p "$kmod_dir" "$ak_mod" "$ak_fw"

  log "modules_install → $kmod_dir"
  "${MAKE[@]}" INSTALL_MOD_PATH="$STAGING/modinst" modules_install
  # Flatten .ko next to modules.load for AnyKernel / Magisk helper
  find "$STAGING/modinst" -type f -name '*.ko' -exec cp -av {} "$kmod_dir/" \;
  cp -av "$ROOT/vendor_modules/modules.load" "$kmod_dir/modules.load"
  # Also keep versioned tree if present
  if [ -d "$STAGING/modinst/lib/modules/$release" ]; then
    cp -av "$STAGING/modinst/lib/modules/$release/modules.dep" "$kmod_dir/" 2>/dev/null || true
    cp -av "$STAGING/modinst/lib/modules/$release/modules.alias" "$kmod_dir/" 2>/dev/null || true
  fi

  # Touch firmware required when sec_ts is modular (not EXTRA_FIRMWARE in Image)
  if [ -d "$STAGING/modinst/lib/firmware" ]; then
    cp -a "$STAGING/modinst/lib/firmware/." "$ak_fw/"
  fi

  rm -rf "$ak_mod"
  mkdir -p "$ak_mod"
  cp -av "$kmod_dir/." "$ak_mod/"
  # Ensure Magisk helper script present
  if [ ! -f "$AK/modules/post-fs-data.sh" ]; then
    log "WARNING: missing AnyKernel3/modules/post-fs-data.sh"
  fi
}

package_zip() {
  local ts zipname img dtb
  ts="$(date +%Y%m%d-%H%M)"
  zipname="Kernel-star2lte-gkilike-$ts.zip"
  img="$OUT/arch/arm64/boot/Image"
  dtb="$OUT/arch/arm64/boot/dts/exynos/exynos9810-star2lte_eur_open_26.dtb"

  [[ -f "$img" ]] || { log "ERROR: missing $img"; exit 1; }
  [[ -f "$dtb" ]] || { log "ERROR: missing $dtb"; exit 1; }

  cp -av "$img" "$AK/Image"
  cp -av "$dtb" "$AK/dtb"

  (
    cd "$AK"
    rm -f "$ROOT/$zipname"
    zip -r9 "$ROOT/$zipname" \
      META-INF anykernel.sh Image dtb tools modules patch ramdisk \
      -x '*/.git/*' '*/placeholder' 2>/dev/null || \
    zip -r9 "$ROOT/$zipname" META-INF anykernel.sh Image dtb tools modules
  )
  log "Packaged $ROOT/$zipname"
  ls -lh "$ROOT/$zipname"
}

main() {
  [[ -f "$OUT/.config" ]] || { log "ERROR: $OUT/.config missing — run a base config first"; exit 1; }
  [[ -x "$CLANG_BIN/clang" ]] || { log "ERROR: clang not found at $CLANG_BIN"; exit 1; }
  apply_fragment
  build_all
  stage_modules
  package_zip
  log "Done. Rollback zip remains: Kernel-star2lte-20260626-2356.zip"
}

main "$@"
