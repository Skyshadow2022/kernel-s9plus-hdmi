# star2lte_tune (KSU module)

Runtime companion for the `tune-2026-09-12` kernel.

Install on device:

```bash
adb push modules/star2lte_tune /data/adb/modules/star2lte_tune
adb shell chmod 755 /data/adb/modules/star2lte_tune/*.sh
adb reboot
```

Config override: `/data/adb/star2lte_tune.conf` (see `docs/TUNE_HANDOFF_2026-09-13.md`).
