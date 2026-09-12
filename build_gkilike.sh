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
MEM_FRAGMENT="$ROOT/configs/mem_ion.fragment"
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

MAKE=(make -C "$SRC" O="$OUT" ARCH=arm64 CC=clang CROSS_COMPILE=aarch64-linux-android- CLANG_TRIPLE=aarch64-linux-gnu-)

log() { printf '[gkilike] %s\n' "$*"; }

apply_one_fragment() {
  local frag="$1"
  [[ -f "$frag" ]] || return 0
  log "Applying $frag"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
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
  apply_one_fragment "$MEM_FRAGMENT"
  if [[ "${ENABLE_WIFI_MODULE:-0}" == "1" ]]; then
    log "ENABLE_WIFI_MODULE=1 → applying Wi-Fi modular pilot"
    apply_one_fragment "$WIFI_FRAGMENT"
  fi
  "${MAKE[@]}" olddefconfig
}

build_all() {
  log "Building Image + modules (jobs=$JOBS)"
  "${MAKE[@]}" -j"$JOBS" Image modules dtbs 2>&1 | tee "$ROOT/build_gkilike.log"
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
