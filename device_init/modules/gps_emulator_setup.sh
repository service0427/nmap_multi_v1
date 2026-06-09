#!/usr/bin/env bash

# ============================================================
# GPS Emulator Settings & Permissions Lock Module
# ============================================================

init_gps_emulator() {
    local serial=$1
    local has_su=$2
    local YELLOW="\e[1;33m"
    local GREEN="\e[1;32m"
    local NC="\e[0m"

    echo -e "\n[*] Checking GPS Emulator (com.rosteam.gpsemulator) options..."

    # 1. Location Permissions Check & Grant
    local fine_loc=$(adb -s "$serial" shell "dumpsys package com.rosteam.gpsemulator" 2>/dev/null | grep "ACCESS_FINE_LOCATION" | grep "granted=true")
    if [ -z "$fine_loc" ]; then
        echo -e "    - Location permission is NOT granted. Granting..."
        adb -s "$serial" shell "pm grant com.rosteam.gpsemulator android.permission.ACCESS_FINE_LOCATION"
        adb -s "$serial" shell "pm grant com.rosteam.gpsemulator android.permission.ACCESS_COARSE_LOCATION"
        
        # Double check
        local fine_verify=$(adb -s "$serial" shell "dumpsys package com.rosteam.gpsemulator" 2>/dev/null | grep "ACCESS_FINE_LOCATION" | grep "granted=true")
        if [ -n "$fine_verify" ]; then
            echo -e "    [✓] Location permissions granted successfully."
        else
            echo -e "    [!] Failed to grant location permissions."
        fi
    else
        echo -e "    [✓] Location permissions are already granted. Skipping."
    fi

    # 2. Notification Permission Check & Grant
    local post_notif=$(adb -s "$serial" shell "dumpsys package com.rosteam.gpsemulator" 2>/dev/null | grep "POST_NOTIFICATIONS" | grep "granted=true")
    if [ -z "$post_notif" ]; then
        echo -e "    - Notification permission is NOT granted. Granting..."
        adb -s "$serial" shell "pm grant com.rosteam.gpsemulator android.permission.POST_NOTIFICATIONS" 2>/dev/null
        
        # Double check
        local notif_verify=$(adb -s "$serial" shell "dumpsys package com.rosteam.gpsemulator" 2>/dev/null | grep "POST_NOTIFICATIONS" | grep "granted=true")
        if [ -n "$notif_verify" ]; then
            echo -e "    [✓] Notification permission granted successfully."
        else
            echo -e "    [!] Notification permission check failed (might not be supported on this OS version)."
        fi
    else
        echo -e "    [✓] Notification permission is already granted. Skipping."
    fi

    # 3. Battery Optimization Whitelist Check & Add
    local is_whitelisted=$(adb -s "$serial" shell "dumpsys deviceidle whitelist" 2>/dev/null | grep "com.rosteam.gpsemulator")
    if [ -z "$is_whitelisted" ]; then
        echo -e "    - GPS Emulator is NOT whitelisted for battery optimization. Adding..."
        adb -s "$serial" shell "dumpsys deviceidle whitelist +com.rosteam.gpsemulator" >/dev/null
        
        # Double check
        local whitelist_verify=$(adb -s "$serial" shell "dumpsys deviceidle whitelist" 2>/dev/null | grep "com.rosteam.gpsemulator")
        if [ -n "$whitelist_verify" ]; then
            echo -e "    [✓] Battery optimization whitelist updated successfully."
        else
            echo -e "    [!] Failed to update battery optimization whitelist."
        fi
    else
        echo -e "    [✓] Battery optimization exclusion is already enabled. Skipping."
    fi

    # 4. Mock Location App AppOps Check & Set
    local mock_loc=$(adb -s "$serial" shell "appops get com.rosteam.gpsemulator android:mock_location" 2>/dev/null)
    if [[ "$mock_loc" != *"allow"* ]]; then
        echo -e "    - Mock Location permission is NOT allowed. Allowing..."
        adb -s "$serial" shell "appops set com.rosteam.gpsemulator android:mock_location allow"
        
        # Double check
        local mock_verify=$(adb -s "$serial" shell "appops get com.rosteam.gpsemulator android:mock_location" 2>/dev/null)
        if [[ "$mock_verify" == *"allow"* ]]; then
            echo -e "    [✓] Mock Location allowed successfully."
        else
            echo -e "    [!] Failed to set Mock Location AppOps."
        fi
    else
        echo -e "    [✓] Mock Location is already allowed. Skipping."
    fi
}
