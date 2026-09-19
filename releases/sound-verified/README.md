# boot-star2lte-sound-verified.img — faf07bc6

The exact boot partition image that was running on the device when sound was
last verified working (2026-09-19, after the SUSFS experiments were rolled
back). sha256 = faf07bc6d57ff3e7c66bf0dd7ac92ef6…

Provenance: the July 2026 Image + ramdisk with the Device Tree replaced inside
the DTBH blob by the freshly built exynos9810-star2lte_eur_open_26.dtb
(default_idma = 3, VG1). Reconstructible byte-for-byte with
tools/bootimg_dtb.py against BOOT-live-20260918.img + the built DTB.

Known-good: sound (AP ALSA card registers), touch, camera, KernelSU-Next 33250.
Flash with dd to /dev/block/platform/11120000.ufs/by-name/BOOT (root) or via
TWRP. A backup copy lives on the device at /cache/BOOT-backup-presusfs.img.
