#!/usr/bin/env bash
# 在 M2 板端运行：sudo bash diagnose-wifibt.sh > wifibt-diagnostic.log 2>&1
# 只读取状态，不重启服务、不解锁 rfkill、不加载模块、不扫描周围设备。
set -u
export LC_ALL=C
section() { printf '\n===== %s =====\n' "$1"; }
section 'Kernel and firmware release'
uname -a
cat /etc/quectel-release 2>/dev/null || true
section 'SDIO devices'
for dev in /sys/bus/sdio/devices/*; do
    [[ -d "$dev" ]] || continue
    printf '%s\n' "$dev"
    cat "$dev/uevent" 2>/dev/null || true
    readlink "$dev/driver" || true
done
section 'Module files / loaded drivers'
lsmod | grep -E 'aic|cfg80211|bluetooth|hci_uart' || true
for mod in aic8800_bsp aic8800_fdrv aic8800_btlpm; do
    file="/usr/lib/modules/$mod.ko"
    sha256sum "$file" 2>/dev/null || true
    if command -v modinfo >/dev/null; then
        modinfo "$file" 2>/dev/null | grep -E '^(filename|version|vermagic|depends|parm):' || true
    fi
done
section 'Firmware directory resolution'
ls -ld /lib /vendor /system /system/etc/firmware /vendor/etc/firmware /usr/lib/firmware 2>/dev/null || true
find /usr/lib/firmware -maxdepth 1 -name '*8800d80*' -printf '%f\n' 2>/dev/null || true
section 'Services'
systemctl --no-pager -l status wifibt-init.service fcs960k.service bluetooth.service NetworkManager.service || true
section 'Wireless / Bluetooth state'
rfkill list || true
ip -brief link || true
nmcli -f DEVICE,TYPE,STATE device status || true
bluetoothctl list || true
hciconfig -a || true
section 'Boot service journal'
journalctl -b --no-pager -n 250 -u wifibt-init.service -u fcs960k.service -u bluetooth.service -u NetworkManager.service || true
section 'Kernel wireless log'
dmesg | grep -iE 'aic|sdio|mmc[0-9]|firmware|bluetooth|hci|rfkill|wlan|unknown symbol|invalid module|oops|call trace' || true
printf '\n日志可能包含本机 MAC、IP、SSID；分享前请按需脱敏。\n'