#!/usr/bin/env python3
"""Check whether a DTB actually reaches the bootloader on star2lte.

On this device the boot image is AOSP header v0 with Samsung's twist: the
header field at offset 40 is the size of the appended DTBH blob (the "extra"
region), not a header version. The bootloader reads the Device Tree from there.

AnyKernel3 ships a file named `dtb`, and Magisk's magiskboot writes it into its
own region -- but `dtb_size` only exists in header v2 and later (see
dyn_img_v2 in Magisk's bootimg.hpp). On a v0 image nothing points at that
region, so the DTB in AnyKernel3/dtb never reaches the bootloader.

This script reads a boot image and reports what is actually in the extra
region, so the question can be settled by looking instead of guessing.

    python3 bootimg_dtb.py boot.img [AnyKernel3/dtb]     check what is in an image
    python3 bootimg_dtb.py --dump-header boot.img out.bin  extract the DTBH page
    python3 bootimg_dtb.py --make-extra boot.img new.dtb out
    python3 bootimg_dtb.py --assemble header.bin new.dtb out

Exit status is 0 if the extra region's DTB matches the file given as the second
argument, 1 if it does not, 2 if the image could not be read.
"""

import hashlib
import struct
import sys

FDT_MAGIC = bytes.fromhex("d00dfeed")
DTBH_MAGIC = b"DTBH"


def u32(buf, off):
    return struct.unpack_from("<I", buf, off)[0]


def parse(path):
    with open(path, "rb") as fh:
        data = fh.read()

    if data[:8] != b"ANDROID!":
        raise ValueError("not a boot image (no ANDROID! magic)")

    # AOSP header v0. Offset 40 is header_version upstream, but Samsung uses it
    # for the DTBH size on this device, which is why it is read as `extra_sz`.
    kernel_sz = u32(data, 8)
    ramdisk_sz = u32(data, 16)
    second_sz = u32(data, 24)
    page_sz = u32(data, 36)
    extra_sz = u32(data, 40)

    if page_sz not in (2048, 4096, 8192, 16384):
        raise ValueError(f"implausible page size {page_sz} - not a v0 image?")

    def pad(n):
        return (n + page_sz - 1) // page_sz * page_sz

    off = page_sz + pad(kernel_sz) + pad(ramdisk_sz) + pad(second_sz)
    extra = data[off:off + extra_sz]

    return {
        "page_sz": page_sz,
        "kernel_sz": kernel_sz,
        "ramdisk_sz": ramdisk_sz,
        "extra_sz": extra_sz,
        "extra_off": off,
        "extra": extra,
        "total": len(data),
    }


def dtb_in_extra(extra):
    """Return the offset and bytes of the FDT inside the extra region."""
    if FDT_MAGIC not in extra:
        return None, None
    i = extra.index(FDT_MAGIC)
    totalsize = struct.unpack_from(">I", extra, i + 4)[0]
    if totalsize <= 0 or i + totalsize > len(extra):
        return i, None
    return i, extra[i:i + totalsize]


# --- DTBH rebuild -----------------------------------------------------------
#
# The extra region is a DTBH v2 table:
#
#   +0    "DTBH"
#   +4    version (2)
#   +8    number of entries (1)
#   +12   SoC marker (9810)
#   +16   platform (0x50A6)
#   +20   subtype (0x217584DA)
#   +24   entry: board id / hardware revision (26 on star2lte eur_open_26)
#   +28   entry: unknown, preserved verbatim (255 on this device)
#   +32   entry: offset of the FDT within the region (2048)
#   +36   entry: size of the FDT footprint, page aligned
#
# Everything except the size is device identity, so the safe way to ship a new
# Device Tree is to keep the header page from the image already on the device
# and only replace the FDT after it.

DTBH_ENTRY_OFF_OFFSET = 32
DTBH_ENTRY_SIZE_OFFSET = 36


def build_extra(old_extra, new_dtb, page_sz):
    """Rebuild the extra region around a new FDT, reusing the old header page.

    The trailing padding is zeroed. The blob on this device has 92 bytes of
    non-zero garbage after the FDT (whatever the packing tool's buffer held),
    so a rebuild will not be byte-identical to the original there. The header
    page and the FDT itself are reproduced exactly -- verified by rebuild.
    """
    if old_extra[:4] != DTBH_MAGIC:
        raise ValueError("the existing extra region is not a DTBH table")

    header = bytearray(old_extra[:page_sz])
    fdt_off = struct.unpack_from("<I", header, DTBH_ENTRY_OFF_OFFSET)[0]
    if fdt_off < page_sz:
        raise ValueError(f"implausible FDT offset {fdt_off} in the DTBH table")

    footprint = (len(new_dtb) + page_sz - 1) // page_sz * page_sz
    struct.pack_into("<I", header, DTBH_ENTRY_SIZE_OFFSET, footprint)

    out = bytes(header) + new_dtb
    return out + b"\0" * (footprint - len(new_dtb))


def assemble_extra(header_page, new_dtb, page_sz):
    """Assemble an extra region from a standalone DTBH header page + a DTB.

    `header_page` is the 2048-byte page extracted from a boot image that boots
    (see --dump-header). It carries the device identity - board revision,
    platform, subtype - and only the FDT footprint field is rewritten.
    """
    if header_page[:4] != DTBH_MAGIC:
        raise ValueError("header page does not start with DTBH")
    if len(header_page) < page_sz:
        raise ValueError(f"header page is {len(header_page)} bytes, need {page_sz}")
    if new_dtb[:4] != FDT_MAGIC:
        raise ValueError("the Device Tree does not start with d00dfeed")

    header = bytearray(header_page[:page_sz])
    footprint = (len(new_dtb) + page_sz - 1) // page_sz * page_sz
    struct.pack_into("<I", header, DTBH_ENTRY_SIZE_OFFSET, footprint)

    return bytes(header) + new_dtb + b"\0" * (footprint - len(new_dtb))


def main(argv):
    if len(argv) >= 5 and argv[1] == "--make-extra":
        # --make-extra <boot.img on device> <new.dtb> <out-extra>
        try:
            img = parse(argv[2])
        except (OSError, ValueError) as exc:
            print(f"error reading {argv[2]}: {exc}")
            return 2
        with open(argv[3], "rb") as fh:
            new_dtb = fh.read()
        if new_dtb[:4] != FDT_MAGIC:
            print(f"error: {argv[3]} is not a Device Tree (no d00dfeed magic)")
            return 2
        try:
            blob = build_extra(img["extra"], new_dtb, img["page_sz"])
        except ValueError as exc:
            print(f"error: {exc}")
            return 2
        with open(argv[4], "wb") as fh:
            fh.write(blob)
        print(f"wrote {argv[4]}: {len(blob)} bytes "
              f"({img['page_sz']} header + {len(new_dtb)} dtb, "
              f"padded to {len(blob) - img['page_sz']})")
        print(f"copy this into the AnyKernel3 staging dir as 'extra' before repack,")
        print(f"or name it 'dt' so ak3-core.sh:319 does it for you.")
        return 0

    if len(argv) >= 5 and argv[1] == "--assemble":
        # --assemble <dtbh-header.bin> <new.dtb> <out>
        try:
            header = open(argv[2], "rb").read()
            new_dtb = open(argv[3], "rb").read()
            blob = assemble_extra(header, new_dtb, 2048)
        except (OSError, ValueError) as exc:
            print(f"error: {exc}")
            return 2
        with open(argv[4], "wb") as fh:
            fh.write(blob)
        print(f"wrote {argv[4]}: {len(blob)} bytes "
              f"(2048 header + {len(new_dtb)} dtb, footprint {len(blob) - 2048})")
        return 0

    if len(argv) >= 4 and argv[1] == "--dump-header":
        # --dump-header <boot.img> <out.bin>
        try:
            img = parse(argv[2])
        except (OSError, ValueError) as exc:
            print(f"error: {exc}")
            return 2
        if img["extra"][:4] != DTBH_MAGIC:
            print("error: this image's extra region is not a DTBH table")
            return 2
        with open(argv[3], "wb") as fh:
            fh.write(img["extra"][:img["page_sz"]])
        print(f"wrote {argv[3]}: {img['page_sz']}-byte DTBH header page")
        return 0

    if len(argv) < 2:
        print(__doc__)
        return 2

    try:
        img = parse(argv[1])
    except (OSError, ValueError) as exc:
        print(f"error: {exc}")
        return 2

    ex = img["extra"]
    print(f"image            : {argv[1]} ({img['total']} bytes)")
    print(f"page size        : {img['page_sz']}")
    print(f"kernel / ramdisk : {img['kernel_sz']} / {img['ramdisk_sz']}")
    print(f"offset 40 (DTBH) : {img['extra_sz']}")
    print(f"extra region     : offset 0x{img['extra_off']:x}, {len(ex)} bytes")

    if not ex:
        print("\nextra region is empty. On this device that means the bootloader")
        print("has no appended Device Tree to read at all.")
        return 2

    head = ex[:4]
    print(f"extra[0:4]       : {head!r}"
          + ("  <- DTBH table (Samsung format)" if head == DTBH_MAGIC else ""))

    off, dtb = dtb_in_extra(ex)
    if off is None:
        print("\nno FDT (d00dfeed) anywhere in the extra region.")
        return 2

    if dtb is None:
        print(f"\nFDT header at +{off} but its totalsize runs past the region - truncated.")
        return 2

    print(f"FDT at           : +{off} within extra, totalsize {len(dtb)}")
    print(f"sha256(extra dtb): {hashlib.sha256(dtb).hexdigest()}")

    if len(argv) < 3:
        print("\npass a second argument (e.g. AnyKernel3/dtb) to compare against it.")
        return 0

    with open(argv[2], "rb") as fh:
        want = fh.read()
    print(f"sha256({argv[2]})".ljust(18) + f": {hashlib.sha256(want).hexdigest()}")
    print(f"                    ({len(want)} bytes)")

    if want == dtb:
        print("\nMATCH - the DTB in this image is the one you shipped.")
        return 0

    print("\nMISMATCH - the bootloader is reading a different Device Tree than")
    print("the one in your AnyKernel3 directory. See KERNEL-REFERENCE.md section 2.")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
