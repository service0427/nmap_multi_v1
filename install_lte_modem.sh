#!/usr/bin/env bash

# LTE Modem Setup Script (Advanced Multi-Route PBR)
# This script configures all Huawei LTE modems independently, ensuring each
# operates on its own routing table to prevent IP bans in phone farm environments.

if [ "$EUID" -ne 0 ]; then
    echo "[*] Requesting root privileges..."
    sudo bash "$0" "$@"
    exit $?
fi

set -e

echo "----------------------------------------------------"
echo " Starting LTE Modem Setup (Multi-Route PBR Mode)"
echo "----------------------------------------------------"

echo "[1/4] Installing necessary tools..."
apt-get update -qq
apt-get install -y -qq usb-modeswitch python3-yaml curl iproute2 jq > /dev/null

echo "[2/4] Ensuring modems are in Ethernet mode..."
if lsusb | grep -q "12d1:1f01"; then
    usb_modeswitch -v 0x12d1 -p 0x1f01 -J > /dev/null 2>&1 || true
    sleep 5
fi

echo "[*] Installing persistent auto-configuration rule..."
AUTOCONFIG_RULE="/etc/udev/rules.d/99-lte-autoconfig.rules"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/auto_configure_modems.py"
echo "ACTION==\"add\", SUBSYSTEM==\"net\", ATTRS{idVendor}==\"12d1\", ATTRS{idProduct}==\"14db\", RUN+=\"/usr/bin/python3 $SCRIPT_PATH\"" > "$AUTOCONFIG_RULE"
udevadm control --reload-rules

echo "[3/4] Running multi-route configuration (PBR)..."
python3 "$SCRIPT_PATH"

echo "[*] Waiting 10 seconds for DHCP leases & IP assignment..."
sleep 10
# Second pass to ensure exact subnet matching after DHCP finishes
python3 "$SCRIPT_PATH"

echo "[4/4] Verifying final network status..."
echo "===================================================="
echo " Interface Name | IP Address       | Metric"
echo "----------------------------------------------------"
ip -br addr show | grep -E "lte|enp|eth" | awk '{print $1, $3}' | while read name addr; do
    metric=$(ip route show dev $name | grep default | awk '{print $NF}' | head -n 1)
    if [ -z "$metric" ]; then metric="(No Default Route - Check Netplan)"; fi
    printf " %-14s | %-16s | %s\n" "$name" "$addr" "$metric"
done
echo "===================================================="

echo "----------------------------------------------------"
echo " Done! Multi-Route Architecture is restored."
echo " Each phone is now strictly routed out through its"
echo " respective LTE modem (lte11, lte12, lte13, lte14)."
echo "----------------------------------------------------"
