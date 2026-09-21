#!/usr/bin/env bash

# ============================================================
# Screen Lock & Stay-Awake Configuration Module
# - Disables screen lock (locksettings set-disabled true & secure lockscreen.disabled 1)
# - Sets Stay-Awake while plugged in (stay_on_while_plugged_in 7)
# - Sets screen timeout to maximum (screen_off_timeout 2147483647)
# - Dismisses keyguard immediately (wm dismiss-keyguard)
# - Keeps Z-Flip / Foldable devices open (cmd device_state state 3)
# ============================================================

init_screen_lock() {
    local serial=$1
    local has_su=$2
    local YELLOW="\e[1;33m"
    local GREEN="\e[1;32m"
    local NC="\e[0m"

    echo -e "\n[*] Checking Screen Lock & Stay-Awake settings..."

    local stay_on=$(adb -s "$serial" shell "settings get global stay_on_while_plugged_in" 2>/dev/null | tr -d '\r')
    local lock_disabled=$(adb -s "$serial" shell "settings get secure lockscreen.disabled" 2>/dev/null | tr -d '\r')
    local timeout_val=$(adb -s "$serial" shell "settings get system screen_off_timeout" 2>/dev/null | tr -d '\r')

    local needs_update=false
    if [ "$stay_on" != "7" ] || [ "$lock_disabled" != "1" ] || [ "$timeout_val" != "2147483647" ]; then
        needs_update=true
    fi

    if [ "$needs_update" = true ]; then
        echo -e "    - Current settings: stay_on=${stay_on:-0}, lockscreen.disabled=${lock_disabled:-0}, timeout=${timeout_val:-default}"
        echo -e "    - Disabling lockscreen & enabling stay-awake on USB/charging..."

        # 1. Stay on while plugged in (7 = AC + USB + Wireless)
        adb -s "$serial" shell "settings put global stay_on_while_plugged_in 7" 2>/dev/null

        # 2. Set screen off timeout to maximum (2147483647 ms)
        adb -s "$serial" shell "settings put system screen_off_timeout 2147483647" 2>/dev/null

        # 3. Disable lock screen completely via locksettings
        adb -s "$serial" shell "locksettings set-disabled true 2>/dev/null || true"
        adb -s "$serial" shell "settings put secure lockscreen.disabled 1" 2>/dev/null

        # 4. Dismiss any active keyguard
        adb -s "$serial" shell "wm dismiss-keyguard" 2>/dev/null

        # 5. Z-Flip / Foldable: ensure main screen is OPEN (prevents SubHome/Cover screen mode)
        adb -s "$serial" shell "cmd device_state state 3 2>/dev/null || true"

        # 6. Battery & Display Power Optimization:
        # - Lock to 60Hz (prevents 120Hz power drain)
        # - Disable auto brightness
        # - Enable dark mode
        # - Disable battery protect cap (allow 100% full charge)
        # - Disable slate kiosk mode & enable high-current USB
        adb -s "$serial" shell "
            settings put system screen_brightness_mode 0
            settings put system peak_refresh_rate 60.0
            settings put system min_refresh_rate 60.0
            settings put global protect_battery 0
            cmd uimode night yes
            su -c 'echo 1 > /sys/class/power_supply/battery/batt_high_current_usb; echo 0 > /sys/devices/platform/samsung_mobile_device/samsung_mobile_device:battery/power_supply/battery/batt_slate_mode' 2>/dev/null
        " 2>/dev/null

        # Verify
        local verify_stay=$(adb -s "$serial" shell "settings get global stay_on_while_plugged_in" 2>/dev/null | tr -d '\r')
        local verify_lock=$(adb -s "$serial" shell "settings get secure lockscreen.disabled" 2>/dev/null | tr -d '\r')
        echo -e "    [✓] Lockscreen disabled & Stay-Awake set (stay_on=$verify_stay, lockscreen.disabled=$verify_lock)."
    else
        # Still dismiss keyguard, ensure device_state and power settings just in case
        adb -s "$serial" shell "wm dismiss-keyguard" 2>/dev/null
        adb -s "$serial" shell "cmd device_state state 3 2>/dev/null || true"
        adb -s "$serial" shell "
            settings put system screen_brightness_mode 0
            settings put system peak_refresh_rate 60.0
            settings put system min_refresh_rate 60.0
            settings put global protect_battery 0
            cmd uimode night yes
            su -c 'echo 1 > /sys/class/power_supply/battery/batt_high_current_usb; echo 0 > /sys/devices/platform/samsung_mobile_device/samsung_mobile_device:battery/power_supply/battery/batt_slate_mode' 2>/dev/null
        " 2>/dev/null
        echo -e "    [✓] Screen lock is already DISABLED & Power optimizations applied. Skipping."
    fi
}
