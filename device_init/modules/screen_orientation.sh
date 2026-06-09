#!/usr/bin/env bash

# ============================================================
# Screen Orientation Lock Module (Forces Portrait)
# ============================================================

init_screen_orientation() {
    local serial=$1
    local has_su=$2
    local YELLOW="\e[1;33m"
    local GREEN="\e[1;32m"
    local NC="\e[0m"

    echo -e "\n[*] Checking Display Orientation lock status..."
    
    local accel_rot=$(adb -s "$serial" shell "settings get system accelerometer_rotation" 2>/dev/null | tr -d '\r')
    local user_rot=$(adb -s "$serial" shell "settings get system user_rotation" 2>/dev/null | tr -d '\r')
    local ignore_req=$(adb -s "$serial" shell "wm get-ignore-orientation-request" 2>/dev/null | tr -d '\r')
    local fixed_rot=$(adb -s "$serial" shell "wm fixed-to-user-rotation" 2>/dev/null | tr -d '\r')

    # Default values if empty
    accel_rot=${accel_rot:-1}
    user_rot=${user_rot:-0}

    local needs_update=false
    if [ "$accel_rot" != "0" ] || [ "$user_rot" != "0" ]; then
        needs_update=true
    fi
    if [[ "$ignore_req" != *"true"* ]]; then
        needs_update=true
    fi
    if [[ "$fixed_rot" != *"enabled"* ]]; then
        needs_update=true
    fi

    if [ "$needs_update" = true ]; then
        echo -e "    - Current settings: Auto-rotate=$accel_rot, User-rotate=$user_rot, Ignore-app-orient=$ignore_req, Fixed-to-user=$fixed_rot"
        echo -e "    - Locking display orientation to ${GREEN}PORTRAIT${NC}..."
        
        # 1. Turn off auto-rotation
        adb -s "$serial" shell "settings put system accelerometer_rotation 0"
        
        # 2. Force system UI rotation to Portrait (0 degrees)
        adb -s "$serial" shell "settings put system user_rotation 0"
        
        # 3. Ignore App's requested orientation (Forces apps to stay Portrait)
        adb -s "$serial" shell "wm set-ignore-orientation-request true" >/dev/null 2>&1 || true
        
        # 4. Force Window Manager to strictly follow user-rotation
        adb -s "$serial" shell "wm fixed-to-user-rotation enabled" >/dev/null 2>&1 || true
        
        # Verify
        local accel_verify=$(adb -s "$serial" shell "settings get system accelerometer_rotation" 2>/dev/null | tr -d '\r')
        local user_verify=$(adb -s "$serial" shell "settings get system user_rotation" 2>/dev/null | tr -d '\r')
        echo -e "    [✓] Display locked to Portrait successfully (Auto-rotate=${accel_verify:-0}, User-rotate=${user_verify:-0})."
    else
        echo -e "    [✓] Display orientation is already locked to PORTRAIT. Skipping."
    fi
}
