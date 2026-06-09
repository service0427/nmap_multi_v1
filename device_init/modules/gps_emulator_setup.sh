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

    # Check if package is installed
    local is_installed=$(adb -s "$serial" shell "pm path com.rosteam.gpsemulator" 2>/dev/null | tr -d '\r')
    if [ -z "$is_installed" ]; then
        echo -e "    ${YELLOW}[⚠️] GPS Emulator is NOT installed. Skipping this module.${NC}"
        return 0
    fi

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

    # 5. Pre-configure preferences (No underscore in lastloc to avoid parsing crash)
    if [ -n "$has_su" ]; then
        echo -e "    - Pre-configuring GPS Emulator preferences..."
        local pref_dir="/data/data/com.rosteam.gpsemulator/shared_prefs"
        local pref_file="$pref_dir/com.rosteam.gpsemulator_preferences.xml"
        
        local gps_owner=$(adb -s "$serial" shell "$has_su -c 'stat -c \"%U:%G\" /data/data/com.rosteam.gpsemulator 2>/dev/null'" 2>/dev/null | tr -d '\r')
        if [ -n "$gps_owner" ] && [[ "$gps_owner" != *"No such"* ]]; then
            adb -s "$serial" shell "$has_su -c 'mkdir -p $pref_dir && printf \"<?xml version=\\\"1.0\\\" encoding=\\\"utf-8\\\" standalone=\\\"yes\\\" ?>\n<map>\n    <boolean name=\\\"noads\\\" value=\\\"true\\\" />\n    <boolean name=\\\"onettimeblock\\\" value=\\\"true\\\" />\n    <int name=\\\"pagbookmark\\\" value=\\\"1\\\" />\n    <int name=\\\"accion\\\" value=\\\"0\\\" />\n    <float name=\\\"velocidad\\\" value=\\\"0.0\\\" />\n    <int name=\\\"consent_status\\\" value=\\\"1\\\" />\n    <boolean name=\\\"appstartvisible\\\" value=\\\"false\\\" />\n    <string name=\\\"lastloc\\\">CurrentStart+37.5665,126.9780+15.0</string>\n</map>\n\" > $pref_file && chmod 660 $pref_file && chown $gps_owner $pref_file && restorecon -R /data/data/com.rosteam.gpsemulator'" >/dev/null 2>&1
        fi
    fi

    # 6. First-time Launch UI Dismissal (Auto-dismiss Important popup)
    echo -e "    - Performing first-time launch auto-dismiss..."
    adb -s "$serial" shell monkey -p com.rosteam.gpsemulator -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    sleep 3
    
    local script_dir
    if [ -n "$BASE_DIR" ]; then
        script_dir="$BASE_DIR"
    else
        script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )/../.." && pwd )"
    fi
    
    # Click OK/Accept button (android:id/button1) dynamically
    python3 "$script_dir/device_init/utils/ui_clicker.py" "$serial" "id:android:id/button1" >/dev/null 2>&1 || true
    
    # Force stop to complete the initialization
    adb -s "$serial" shell am force-stop com.rosteam.gpsemulator
    echo -e "    [✓] GPS Emulator auto-dismiss check complete."
}
