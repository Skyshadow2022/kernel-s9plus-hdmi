#!/usr/bin/env python3
"""Minimal, tolerant FDT parser and differ.

dtc refuses some real Samsung DTBs ("String offset N overruns string table")
because of how their generator terminates the string table. This walks the
structure block directly instead, so two Device Trees can be compared even when
one of them will not decompile.

    python3 fdt_diff.py a.dtb b.dtb      # structural diff
    python3 fdt_diff.py a.dtb            # summary of one tree
"""

import struct
import sys

FDT_MAGIC = bytes.fromhex("d00dfeed")
BEGIN_NODE, END_NODE, PROP, NOP, END = 1, 2, 3, 4, 9


def parse(data):
    """Return (paths, properties) where properties maps path -> {name: bytes}."""
    if data[:4] != FDT_MAGIC:
        raise ValueError("not a Device Tree")
    totalsize, off_struct, off_strings = struct.unpack_from(">III", data, 4)
    size_strings, size_struct = struct.unpack_from(">II", data, 32)
    strings = data[off_strings:off_strings + size_strings]

    def str_at(off):
        end = strings.find(b"\0", off)
        if end < 0:
            end = len(strings)
        return strings[off:end].decode("utf-8", "replace")

    props = {}
    path = []
    i = off_struct
    end_struct = off_struct + size_struct
    while i < end_struct:
        tag = struct.unpack_from(">I", data, i)[0]
        i += 4
        if tag == BEGIN_NODE:
            nul = data.index(b"\0", i)
            name = data[i:nul].decode("utf-8", "replace")
            i = nul + 1
            i = (i + 3) & ~3
            path.append(name)
            props.setdefault("/" + "/".join(p for p in path if p), {})
        elif tag == END_NODE:
            if path:
                path.pop()
        elif tag == PROP:
            length, nameoff = struct.unpack_from(">II", data, i)
            i += 8
            value = data[i:i + length]
            i = (i + length + 3) & ~3
            key = "/" + "/".join(p for p in path if p)
            props.setdefault(key, {})[str_at(nameoff)] = value
        elif tag == NOP:
            continue
        elif tag == END:
            break
        else:
            raise ValueError(f"bad FDT tag {tag} at offset {i - 4}")
    return props


def fmt(value):
    if len(value) == 0:
        return "(empty)"
    if len(value) % 4 == 0:
        words = struct.unpack(f">{len(value) // 4}I", value)
        # printable ASCII, e.g. a firmware filename
        if all(32 <= b < 127 or b == 0 for b in value):
            text = value.rstrip(b"\0")
            if text and all(32 <= b < 127 for b in text):
                return f'"{text.decode()}"'
        return " ".join(f"0x{w:x}" for w in words) if len(words) > 1 else f"0x{words[0]:x}"
    return value.hex()


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2

    try:
        a = parse(open(argv[1], "rb").read())
    except (OSError, ValueError) as exc:
        print(f"error reading {argv[1]}: {exc}")
        return 2

    if len(argv) < 3:
        print(f"{argv[1]}: {len(a)} nodes, "
              f"{sum(len(v) for v in a.values())} properties")
        return 0

    try:
        b = parse(open(argv[2], "rb").read())
    except (OSError, ValueError) as exc:
        print(f"error reading {argv[2]}: {exc}")
        return 2

    only_a = sorted(set(a) - set(b))
    only_b = sorted(set(b) - set(a))
    common = sorted(set(a) & set(b))

    print(f"A = {argv[1]}  ({len(a)} nodes)")
    print(f"B = {argv[2]}  ({len(b)} nodes)")
    print()

    n = 0
    for p in only_a:
        print(f"  - node only in A: {p}")
        n += 1
    for p in only_b:
        print(f"  + node only in B: {p}")
        n += 1

    for p in common:
        pa, pb = a[p], b[p]
        for k in sorted(set(pa) - set(pb)):
            print(f"  - {p}:{k} = {fmt(pa[k])}")
            n += 1
        for k in sorted(set(pb) - set(pa)):
            print(f"  + {p}:{k} = {fmt(pb[k])}")
            n += 1
        for k in sorted(set(pa) & set(pb)):
            if pa[k] != pb[k]:
                print(f"  ~ {p}:{k}\n      A: {fmt(pa[k])}\n      B: {fmt(pb[k])}")
                n += 1

    print()
    print(f"{n} difference(s)." if n else "no structural differences.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
