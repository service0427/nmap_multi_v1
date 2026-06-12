#!/usr/bin/env bash

# LTE Modem Setup Script (Automated Priority Routing)
# This script handles USB mode switching, consistent naming (lte11-lte20),
# and priority-based routing (lte11 > lte12 > ... > Ethernet).

# 0. Auto-elevate to root if not already
if [ "$EUID" -ne 0 ]; then
    echo "[*] Requesting root privileges..."
    sudo bash "$0" "$@"
    exit $?
fi

set -e

echo "----------------------------------------------------"
echo " Starting LTE Modem Setup & Priority Configuration"
echo "----------------------------------------------------"

# 1. Install Dependencies
echo "[1/4] Installing necessary tools (usb-modeswitch, yaml, etc.)..."
apt-get update -qq
apt-get install -y -qq usb-modeswitch python3-yaml curl iproute2 > /dev/null

# 2. Trigger USB ModeSwitch for any Huawei modems in storage mode
echo "[2/4] Ensuring modems are in Ethernet mode..."
# Huawei storage mode is often 12d1:1f01
if lsusb | grep -q "12d1:1f01"; then
    echo " -> Found Huawei modems in storage mode. Triggering modeswitch..."
    usb_modeswitch -v 0x12d1 -p 0x1f01 -J > /dev/null 2>&1 || true
    sleep 5
fi

# --- Add persistent udev rule for automatic recognition on re-plug ---
echo "[*] Installing persistent auto-configuration rule..."
AUTOCONFIG_RULE="/etc/udev/rules.d/99-lte-autoconfig.rules"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/device_init/modules/auto_configure_modems.py"
echo "ACTION==\"add\", SUBSYSTEM==\"net\", ATTRS{idVendor}==\"12d1\", ATTRS{idProduct}==\"14db\", RUN+=\"/usr/bin/python3 $SCRIPT_PATH\"" > "$AUTOCONFIG_RULE"
udevadm control --reload-rules
# --------------------------------------------------------------------------

# 3. Run the Auto-Configuration Engine (Initial Pass)
echo "[3/4] Running auto-configuration engine (Phase 1: Initial Setup)..."
python3 "$SCRIPT_PATH"

# Wait for DHCP leases to populate for re-verification
echo "[*] Waiting 10 seconds for network stabilization & IP assignment..."
sleep 10

# 4. Re-verification & Alignment Pass
echo "[*] Running auto-configuration engine (Phase 2: Subnet Re-alignment)..."
# The script will now see the IPs and fix any lte11/12 swaps
python3 "$SCRIPT_PATH"

# 5. Final Verification
echo "[4/4] Verifying final network status..."
echo "===================================================="
echo " Interface Name | IP Address       | Metric"
echo "----------------------------------------------------"
ip -br addr show | grep -E "lte|enp|eth" | awk '{print $1, $3}' | while read name addr; do
    metric=$(ip route show dev $name | grep default | awk '{print $NF}' | head -n 1)
    printf " %-14s | %-16s | %s\n" "$name" "$addr" "$metric"
done
echo "===================================================="

# Connectivity test via lte11 (highest priority)
if ip link show lte11 >/dev/null 2>&1; then
    echo "[*] Testing internet via lte11..."
    if curl --interface lte11 -s --connect-timeout 5 https://www.google.com > /dev/null; then
        echo " -> [SUCCESS] Internet reachable via lte11"
    else
        echo " -> [WARNING] lte11 is UP but cannot reach internet."
    fi
fi

echo "----------------------------------------------------"
echo " Done! LTE priority routing is configured."
echo " Priority order: lte11 > lte12 > ... > lte20 > Wired"
echo "----------------------------------------------------"
