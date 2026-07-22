# AnyKernel3 Ramdisk Mod Script
# osm0sis @ xda-developers

## AnyKernel setup
# begin properties
properties() { '
kernel.string=Pseudo-GKI + KernelSU-Next legacy for Galaxy S9+ (star2lte)
do.devicecheck=1
do.modules=1
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=star2lte
device.name2=star2ltexx
device.name3=SM-G965F
device.name4=SM-G965N
supported.versions=
supported.patchlevels=
'; } # end properties

# shell variables
block=/dev/block/platform/11120000.ufs/by-name/BOOT;
is_slot_device=0;
ramdisk_compression=auto;

## AnyKernel methods (DO NOT CHANGE)
. tools/ak3-core.sh;

## AnyKernel install
split_boot;
flash_boot;
flash_dtbo;
## end install
