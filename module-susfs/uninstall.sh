#!/system/bin/sh
# Best-effort: reset the uname spoof. sus_path entries and the cmdline spoof
# stay until the next reboot - SUSFS state lives in the kernel only.
/data/adb/ksu/bin/ksu_susfs uname default default 2>/dev/null
echo "SUSFS policy removed. A reboot clears the remaining in-kernel state."
