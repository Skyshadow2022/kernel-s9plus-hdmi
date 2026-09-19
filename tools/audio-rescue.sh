#!/system/bin/sh
# star2lte audio rescue — run when the Star-Madera card fails to register.
#
# The codec (CS47L92, "madera" MFD over SPI on controller 10470000) sometimes
# loses a boot-time probe race: driver registered, spi2.0 device exists, but
# the probe never runs — silently, with an empty deferred list. Rebinding the
# SPI controller re-creates spi2.0 and re-fires the match, which brings the
# Star-Madera card up without a reboot.
#
# Usage: adb shell su -c 'sh /data/local/tmp/audio-rescue.sh'
# (also at tools/ in the repos; wire into the susfs policy module's
#  boot-completed path once proven)

setenforce 0
KICKED=0
if [ -d /sys/bus/platform/drivers/s3c64xx-spi/10470000.spi ]; then
  echo 10470000.spi > /sys/bus/platform/drivers/s3c64xx-spi/unbind 2>/dev/null
  sleep 1
  echo 10470000.spi > /sys/bus/platform/drivers/s3c64xx-spi/bind 2>/dev/null
  KICKED=1
  sleep 3
fi
setenforce 1

if grep -q StarMadera /proc/asound/cards 2>/dev/null; then
  echo "RESCUE OK: Star-Madera card is up"
else
  echo "no card yet (kicked=$KICKED). Check: ls /sys/bus/spi/devices/spi2.0/driver"
fi
