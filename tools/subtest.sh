#!/system/bin/sh
# star2lte subsystem test suite - the "board bring-up" check.
# Run after every flash: adb shell su -c 'sh /data/local/tmp/subtest.sh'
# Each check prints PASS/FAIL/WARN. Gate releases on this.

fail=0
note=""
P() { echo "PASS $1"; }
F() { echo "FAIL $1"; fail=$((fail+1)); }
W() { echo "WARN $1"; }

# ---- audio ----
grep -q StarMadera /proc/asound/cards && P "audio: Star-Madera card" || F "audio: Star-Madera card MISSING"
ls /sys/bus/platform/devices/ 2>/dev/null | grep -q "cs47l92" && P "audio: codec child" || W "audio: codec child device name not found"
c=$(logcat -d 2>/dev/null | grep -cE 'createTrack.*-19'); [ "$c" = "0" ] && P "audio: no ENODEV storm" || F "audio: $c ENODEV tracks"
[ -e /dev/snd/pcmC0D0p ] || [ -e /dev/snd/pcmC1D0p ] && P "audio: pcm node" || W "audio: pcm node naming differs"

# ---- touch ----
d=$(dmesg | grep -c 'sec_ts 4-0048'); [ "$d" -gt 5 ] && P "touch: alive ($d lines)" || F "touch: only $d lines"
grep -q sec_ts /proc/modules && P "touch: module loaded" || W "touch: builtin (ok for the 1200 line)"
l=$(dmesg | grep -c module_layout); [ "$l" = "0" ] && P "modules: no layout errors" || F "modules: $l layout errors"

# ---- display ----
idma=$(od -An -tx1 /proc/device-tree/decon_t@0x16050000/default_idma 2>/dev/null | tr -d ' ')
[ "$idma" = "00000003" ] && P "dtb: idma VG1" || F "dtb: idma wrong ($idma)"
s=$(dumpsys SurfaceFlinger 2>/dev/null | grep -c "GLES"); [ "$s" -gt 0 ] && P "display: SF alive" || W "display: SF check inconclusive"

# ---- kernel core ----
:
h=$(dmesg | grep -ciE "kernel panic|BUG:|Oops"); [ "$h" = "0" ] && P "kernel: no panics" || F "kernel: $h panic/BUG lines"
z=$(cat /sys/fs/pstore/ 2>/dev/null | wc -l); echo "INFO pstore entries: $z"

# ---- root ----
su -c id 2>/dev/null | grep -q "uid=0" && P "KernelSU: root works" || F "KernelSU: no root"
v=$(ksud debug version 2>/dev/null | grep -oE "[0-9]+"); [ "$v" -ge 33250 ] && P "KernelSU: version $v" || W "KernelSU: version $v"

# ---- radio/data ----
ip link 2>/dev/null | grep -q "wlan0" && P "wifi: wlan0 up" || F "wifi: no wlan0"
i=$(ip -o addr show dev wlan0 2>/dev/null | grep -c inet); [ "$i" -gt 0 ] && P "wifi: has address" || W "wifi: no address yet"
d=$(dumpsys telephony.registry 2>/dev/null | grep -m1 mDataConnectionState); echo "INFO data: $d"
g=$(getprop init.svc.gpsd 2>/dev/null); echo "INFO gps svc: $g"

# ---- sensors (framework view) ----
n=$(dumpsys sensorservice 2>/dev/null | grep -c "0x"); [ "$n" -gt 10 ] && P "sensors: $n handles" || W "sensors: only $n handles"

# ---- battery/charging ----
b=$(dumpsys battery 2>/dev/null | grep -m1 level); echo "INFO battery: $b"
c=$(dmesg | grep -c "sec_bat"); [ "$c" -gt 3 ] && P "battery: driver active" || W "battery: few driver lines"

# ---- thermal ----
t=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | head -3); echo "INFO temps: $(echo $t | tr '\n' ' ')"

# ---- usb ----
u=$(getprop sys.usb.state); echo "INFO usb: $u"

# ---- camera presence (HAL side) ----
p=$(ps -A | grep -cE "camera.provider|cameraserver"); [ "$p" -gt 1 ] && P "camera: provider+server running" || F "camera: provider missing"

echo "==================================="
[ "$fail" = "0" ] && echo "SUBTEST: PASS" || echo "SUBTEST: $fail FAILURES"
exit $fail
