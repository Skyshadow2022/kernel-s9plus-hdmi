# star2lte Audio Repair

## What it fixes

On this device the audio HAL fails during boot:

```
E/audio_hw_proxy_9810: cannot find Mixer Control
E/audio_hw_proxy_9810: proxy_init_route: failed to open Mixer
E/audio_hw_primary:    device-adev_open: failed to open Primary Audio HW Device
E/AudioFlinger:        loadHwModule() error -22 loading module primary
```

Because the `primary` module never loads, AudioFlinger has no output thread, every
app gets `-19 ENODEV` on any audio call, and `AudioService` retries
`initStreamVolume` every 2 seconds forever — which is what pins the CPU and makes
the phone lag.

The cause is not the kernel: the running kernel's audio config is byte-identical to
a known-good build (`CONFIG_SND_SOC_SAMSUNG_ABOX`, `..._EXYNOS9810_MAX98512`,
`CONFIG_SND_SOC_MAX98512` all `=y`). It is the `/vendor` overlay:

```
overlay /vendor overlay lowerdir=/vendor,upperdir=/cache/overlay/vendor/upper
```

`/vendor` is a read-only erofs image; everything in the upper dir shadows it.
Audio-effect modules (ViPER) write into that upper, and when their copies of the
HAL/effect libraries do not match the ROM, the HAL cannot find its mixer controls.

## Usage

1. KernelSU manager → Modules → Install → `audiofix-module.zip`
2. Reboot
3. Modules → **star2lte Audio Repair** → tap **ACTION**

The action logs what is in the overlay upper to `/sdcard/audio-repair.log`, then
**moves** `upper` to `upper.bak` (nothing is deleted) and recreates an empty
`upper`. Reverting `/vendor` to stock.

4. Reboot. Sound should work. ViPER will be gone — that is the point.

To undo: rename `upper.bak` back to `upper` and reboot.

`service.sh` also writes `/sdcard/audio-bootstate.txt` on every boot, which is
readable over adb without root.
