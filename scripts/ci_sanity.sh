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
  docs/DEX_PATTERN.md \
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

# HDMI/DP workstream abandoned (2026-09-20): the HWC takeover / default_idma /
# reference-tree checks were removed with configs/displayport.fragment.

if [[ "$fail" -ne 0 ]]; then
  echo "sanity FAILED"
  exit 1
fi
echo "sanity PASSED"
