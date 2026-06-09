#!/usr/bin/env bash

# ============================================================
# Scanning & Location Settings Initialization Module
# ============================================================

init_scanning_settings() {
    local serial=$1
    local has_su=$2
    local YELLOW="\e[1;33m"
    local GREEN="\e[1;32m"
    local NC="\e[0m"

    echo -e "\n[*] Checking Scanning settings (Wi-Fi/BLE/Nearby)..."
    
    local wifi_scan=$(adb -s "$serial" shell "settings get global wifi_scan_always_enabled" 2>/dev/null | tr -d '\r')
    local ble_scan=$(adb -s "$serial" shell "settings get global ble_scan_always_enabled" 2>/dev/null | tr -d '\r')
    local nearby_scan=$(adb -s "$serial" shell "settings get system nearby_scanning_enabled" 2>/dev/null | tr -d '\r')

    # Default to 0 if null
    wifi_scan=${wifi_scan:-0}
    ble_scan=${ble_scan:-0}
    nearby_scan=${nearby_scan:-0}

    if [ "$wifi_scan" != "0" ] || [ "$ble_scan" != "0" ] || [ "$nearby_scan" != "0" ]; then
        echo -e "    - Current settings: Wi-Fi Scan=$wifi_scan, BLE Scan=$ble_scan, Nearby Scan=$nearby_scan"
        echo -e "    - Disabling location and nearby scanning..."
        
        adb -s "$serial" shell "settings put global wifi_scan_always_enabled 0"
        adb -s "$serial" shell "settings put global ble_scan_always_enabled 0"
        adb -s "$serial" shell "settings put system nearby_scanning_enabled 0" 2>/dev/null
        
        # Verify
        local wifi_verify=$(adb -s "$serial" shell "settings get global wifi_scan_always_enabled" 2>/dev/null | tr -d '\r')
        local ble_verify=$(adb -s "$serial" shell "settings get global ble_scan_always_enabled" 2>/dev/null | tr -d '\r')
        local nearby_verify=$(adb -s "$serial" shell "settings get system nearby_scanning_enabled" 2>/dev/null | tr -d '\r')
        
        echo -e "    [✓] Scanning settings updated: Wi-Fi Scan=${wifi_verify:-0}, BLE Scan=${ble_verify:-0}, Nearby Scan=${nearby_verify:-0}"
    else
        echo -e "    [✓] Wi-Fi, BLE, and Nearby scanning are already disabled. Skipping."
    fi
}
