# Magisk/KernelSU module (also installed live on device as dp-hwc-selinux)

## Purpose
PE genfs labeled the wrong DP address (`10ab0000`). Real cable is
`11090000.displayport/.../cable.0/state` typed as `sysfs`, so HWC
`readHotplugStatus()` gets AVC denied and ExternalDisplay never opens.

## Install (rooted / KSUN)
```bash
adb root
adb shell mkdir -p /data/adb/modules/dp-hwc-selinux
adb push vendor_modules/dp-hwc-selinux/. /data/adb/modules/dp-hwc-selinux/
adb reboot
```

After reboot with hub plugged: expect HWC hotplug; dmesg may show
`HWC takeover` when WIN_CONFIG arrives. Keep `hdmi-mirror` **disabled**.
