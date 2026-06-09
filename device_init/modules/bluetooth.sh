#!/usr/bin/env bash

# ============================================================
# Bluetooth Initialization Module
# ============================================================

init_bluetooth() {
    local serial=$1
    local has_su=$2
    local YELLOW="\e[1;33m"
    local GREEN="\e[1;32m"
    local NC="\e[0m"

    echo -e "\n[*] Checking Bluetooth status..."
    local bt_status=$(adb -s "$serial" shell "settings get global bluetooth_on" 2>/dev/null | tr -d '\r')
    
    if [ "$bt_status" = "1" ]; then
        echo -e "    - Bluetooth is currently ${YELLOW}ON (1)${NC}."
        echo -e "    - Turning Bluetooth ${GREEN}OFF${NC}..."
        adb -s "$serial" shell "svc bluetooth disable"
        sleep 2
        
        # Verify
        local bt_verify=$(adb -s "$serial" shell "settings get global bluetooth_on" 2>/dev/null | tr -d '\r')
        if [ "$bt_verify" = "0" ]; then
            echo -e "    [✓] Bluetooth disabled successfully."
        else
            echo -e "    [!] Failed to disable Bluetooth."
        fi
    elif [ "$bt_status" = "0" ]; then
        echo -e "    [✓] Bluetooth is already ${GREEN}OFF (0)${NC}. Skipping."
    else
        echo -e "    [!] Could not read Bluetooth status (Value: $bt_status). Skipping."
    fi
}
