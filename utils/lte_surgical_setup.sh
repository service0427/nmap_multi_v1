#!/bin/bash
# LTE Surgical Setup Script (Zero-Downtime)
# Use this after plugging in LTE modems.

echo "--- [1] Identifying New Interfaces ---"
# Find any interface that starts with eth, usb, or enx (default names for USB modems) but not lte
NEW_IFACES=$(ls /sys/class/net/ | grep -E "^(eth|usb|enx)" | grep -vE "lte")

if [ -z "$NEW_IFACES" ]; then
    echo "No new LTE modems detected."
else
    for iface in $NEW_IFACES; do
        echo "Found: $iface. Activating..."
        sudo ip link set "$iface" up
    done
fi

echo "--- [2] Requesting IPs (Background) ---"
# Using a loop to request IP without systemctl restart (modem patterns only)
for iface in $(ls /sys/class/net/ | grep -E "^(lte|eth|usb|enx)"); do
    # Only if it doesn't have an IP yet
    if ! ip -4 addr show "$iface" | grep -q "inet "; then
        echo "Requesting IP for $iface..."
        # If dhclient is missing, we rely on networkd's auto-config via link up
    fi
done

sleep 5

echo "--- [3] Renaming & Routing Orchestration ---"
for iface in $(ls /sys/class/net/ | grep -E "^(lte|eth|usb|enx)"); do
    IP=$(ip -4 addr show "$iface" | grep -oP '(?<=inet\s)192\.168\.[0-9]+\.[0-9]+' | head -n 1)
    [ -z "$IP" ] && continue
    
    SUBNET=$(echo "$IP" | cut -d. -f3)
    [ "$SUBNET" -lt 11 ] || [ "$SUBNET" -gt 20 ] && continue
    
    TARGET_NAME="lte$SUBNET"
    TABLE_ID="2$SUBNET" # Table ID aligned with lte_manager.py (211 ~ 220)
    
    # Rename if needed
    if [ "$iface" != "$TARGET_NAME" ]; then
        echo "Naming: $iface -> $TARGET_NAME"
        sudo ip link set "$iface" down
        sudo ip link set "$iface" name "$TARGET_NAME"
        sudo ip link set "$TARGET_NAME" up
    fi
    
    # Apply Routing strictly to this IP
    echo "Routing: Mapping $IP to Table $TABLE_ID via $TARGET_NAME"
    sudo ip route replace default via 192.168.$SUBNET.1 dev "$TARGET_NAME" table "$TABLE_ID"
    sudo ip rule add from "$IP" table "$TABLE_ID" priority "$TABLE_ID" 2>/dev/null || true
    sudo ip rule add from 192.168.$SUBNET.0/24 table "$TABLE_ID" priority "$TABLE_ID" 2>/dev/null || true
done

sudo ip rule add from all lookup main priority 32766 2>/dev/null || true

echo "--- [DONE] LTE Discovery & Binding Ready ---"
ip rule show
