#!/usr/bin/env bash
# Wrap a raw dtc .dtb into Samsung Exynos DTBH boot EXTRA format.
# BOOT-68 on star2lte: 2048-byte DTBH header + page-aligned FDT payload
# (2048 + 301056 = 303104).
#
# Usage:
#   pack_exynos_dtbh.sh <input.dtb> <output.dtbh> [template.extra]

set -euo pipefail

in="${1:?input dtb}"
out="${2:?output dtbh}"
template="${3:-}"

pagesize=2048
raw_size=$(stat -c%s "$in" 2>/dev/null || stat -f%z "$in")
pad_size=$(( (raw_size + pagesize - 1) / pagesize * pagesize ))
total=$((pagesize + pad_size))

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [[ -n "$template" && -f "$template" ]]; then
  dd if="$template" of="$tmp/hdr" bs="$pagesize" count=1 status=none
else
  python3 - "$tmp/hdr" "$pagesize" <<'PY'
import struct, sys
path, pagesize = sys.argv[1], int(sys.argv[2])
hdr = bytearray(pagesize)
hdr[0:4] = b"DTBH"
# version, count, platform, subtype, hw_rev, hw_rev_end, reserved, offset, size
struct.pack_into(
    "<IIIIIIIII",
    hdr,
    4,
    2,
    1,
    9810,
    0x50A6,
    0x217584DA,
    26,
    255,
    pagesize,
    0,
)
struct.pack_into("<I", hdr, 40, 32)
open(path, "wb").write(hdr)
PY
fi

python3 - "$tmp/hdr" "$pagesize" "$pad_size" <<'PY'
import struct, sys
path, pagesize, pad_size = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
hdr = bytearray(open(path, "rb").read())
assert hdr[0:4] == b"DTBH", hdr[0:4]
struct.pack_into("<I", hdr, 32, pagesize)
struct.pack_into("<I", hdr, 36, pad_size)
open(path, "wb").write(hdr)
PY

dd if="$tmp/hdr" of="$tmp/out" status=none
dd if="$in" of="$tmp/out" bs=1 seek="$pagesize" conv=notrunc status=none
python3 - "$tmp/out" "$total" <<'PY'
import os, sys
path, need = sys.argv[1], int(sys.argv[2])
cur = os.path.getsize(path)
if cur < need:
    with open(path, "ab") as f:
        f.write(b"\x00" * (need - cur))
elif cur > need:
    raise SystemExit(f"output too large: {cur} > {need}")
PY

cp -f "$tmp/out" "$out"
echo "pack_exynos_dtbh: raw=$raw_size pad=$pad_size total=$total -> $out"
