#!/usr/bin/env bash
# Fast offline sanity checks for CI and local pre-push.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0

ok() { printf 'OK  %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

echo "== kernel-s9plus-hdmi sanity =="

# Required project files
for f in \
  build_gkilike.sh \
  HDMI_READY.md \
  docs/DEX_PATTERN.md \
  configs/displayport.fragment \
  configs/gkilike_touch.fragment \
  kernel_source/Makefile \
  kernel_source/drivers/video/fbdev/exynos/dpu_9810/displayport_drv.c \
  kernel_source/drivers/video/fbdev/exynos/dpu_9810/decon_core.c \
  scripts/dp_hdmi_debug.sh
do
  if [[ -f "$f" ]]; then ok "exists $f"; else bad "missing $f"; fi
done

# Bash syntax
for s in build_gkilike.sh scripts/ci_sanity.sh scripts/dp_hdmi_debug.sh \
         scripts/install_persist_helpers.sh; do
  [[ -f "$s" ]] || continue
  if bash -n "$s"; then ok "bash -n $s"; else bad "bash -n $s"; fi
done

# Config fragments: only CONFIG_ / comments / blanks
while IFS= read -r -d '' frag; do
  if grep -Ev '^(#|$|CONFIG_[A-Za-z0-9_]+=)' "$frag" >/dev/null; then
    bad "bad lines in $frag"
    grep -nEv '^(#|$|CONFIG_[A-Za-z0-9_]+=)' "$frag" | head -5 || true
  else
    ok "fragment $frag"
  fi
done < <(find configs -type f -name '*.fragment' -print0)

# HWC host markers must remain in tree
if grep -q 'displayport_hwc_takeover' \
    kernel_source/drivers/video/fbdev/exynos/dpu_9810/displayport_drv.c \
    kernel_source/drivers/video/fbdev/exynos/dpu_9810/decon_core.c; then
  ok "HWC takeover hook present"
else
  bad "HWC takeover hook missing"
fi

if grep -q 'default_idma = <0x3>' \
    kernel_source/arch/arm64/boot/dts/exynos/exynos9810-star2lte_eur_open_26.dts; then
  ok "star2lte DP default_idma=VG1"
else
  bad "star2lte DP default_idma not VG1"
fi

# Reference trees for Phase A
if [[ -f reference/android_hardware_samsung_slsi-linaro_graphics/base/libhwc2.1/platform/exynos9810/ExynosHWCModule.h ]]; then
  ok "HWC exynos9810 reference present"
else
  bad "HWC reference missing"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "sanity FAILED"
  exit 1
fi
echo "sanity PASSED"
