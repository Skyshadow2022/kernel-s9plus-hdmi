#!/system/bin/sh
# star2lte post-flash smoke test - run after EVERY flash, gate releases on it.
# Usage (host): adb push tools/smoke.sh /data/local/tmp/ && adb shell su -c sh /data/local/tmp/smoke.sh
fail=0
chk() { out=$(eval "$2" 2>&1); echo "--- $1: $(echo "$out" | head -2 | tr '\n' ' ')"
        echo "$out" | grep -qi "$3" || { echo "FAIL: $1"; fail=1; } }

chk "kernel release"  "uname -r"                          "4\\.9\\."   # 4.9.337 real, 4.9.219 when the SUSFS uname spoof is on
chk "sound card AP"   "cat /proc/asound/cards"            "StarMadera"   # THE gate - a clean-rebuild kernel loses this card
chk "asoc codec"      "ls /sys/bus/platform/devices/"     "cs47l92"
chk "touch alive"     "dmesg"                             "sec_ts"
chk "DTB idma=VG1"    "od -An -tx1 /proc/device-tree/decon_t@0x16050000/default_idma | tr -d ' '" "00000003"
chk "KernelSU root"   "su -c id"                          "uid=0"
chk "KSU version"     "ksud debug version"                "3325"
chk "SELinux"         "getenforce"                        "Enforc"
chk "wlan"            "ip link"                           "wlan0"
echo "--- modules: $(cat /proc/modules | awk '{print $1}' | tr '\n' ' ')"
echo "--- audio HAL -19 storm: $(logcat -d 2>/dev/null | grep -cE 'createTrack.*-19')"
echo "--- module_layout errors: $(dmesg | grep -c module_layout)"
echo "--- pstore/last_kmsg: $(ls /sys/fs/pstore/ 2>/dev/null | wc -l) entries"
[ "$fail" = "0" ] && echo "SMOKE: PASS" || echo "SMOKE: FAIL - DO NOT SHIP"
exit $fail
