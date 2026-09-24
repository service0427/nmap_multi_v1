#!/usr/bin/env bash
# ==============================================================================
# Power Mode Controller for Device Fleet
# - Stage 1 (< 25%)  : deep_sleep (Max power saving & fast charging, Airplane ON, CPU Big-Cores OFF, Screen OFF)
# - Stage 2 (25~30%) : default    (Prepared in normal mode, Airplane OFF, Wi-Fi ON, CPU 8-Cores ON, Standby charging)
# - Stage 3 (>= 31%) : default    (Full navigation task execution allowed)
# ==============================================================================

set_power_mode() {
    local serial="$1"
    local mode="$2"
    [ -z "$serial" ] && return 1

    case "$mode" in
        deep_sleep|sleep|charging|max_save)
            echo "[⚡] [$serial] Applying DEEP SLEEP (Max Power Saving & Fast-Charging)..."
            timeout 10 adb -s "$serial" shell "
                # 1. Terminate heavy foreground/background navigation apps & GPS emulator
                am force-stop com.nhn.android.nmap 2>/dev/null
                am force-stop com.rosteam.gpsemulator 2>/dev/null

                # 2. Hardware Fast Charging & High-Current USB Charging
                settings put global protect_battery 0 2>/dev/null
                settings put system super_fast_charging 1 2>/dev/null
                settings put system adaptive_fast_charging 1 2>/dev/null
                su -c '
                    echo 1 > /sys/class/power_supply/battery/batt_high_current_usb
                    echo 0 > /sys/devices/platform/samsung_mobile_device/samsung_mobile_device:battery/power_supply/battery/batt_slate_mode
                    echo 0 > /sys/class/power_supply/battery/store_mode
                ' 2>/dev/null

                # 3. Enable Airplane Mode to kill RF antenna searching (~150-250mA saved)
                cmd connectivity airplane-mode enable 2>/dev/null || settings put global airplane_mode_on 1 2>/dev/null

                # 4. Shutdown CPU Big Cores (Leave only little cores active, ~150-200mA saved)
                su -c 'for c in 4 5 6 7; do echo 0 > /sys/devices/system/cpu/cpu\$c/online 2>/dev/null; done' 2>/dev/null

                # 5. Enable Android OS Low Power Mode (Battery Saver)
                cmd power set-mode 1 2>/dev/null
                settings put global low_power 1 2>/dev/null

                # 6. Turn Off Screen & AOD, Allow Sleep While Plugged In (~150mA saved)
                settings put global stay_on_while_plugged_in 0 2>/dev/null
                settings put system screen_brightness 1 2>/dev/null
                settings put system screen_off_timeout 15000 2>/dev/null
                settings put system aod_mode 0 2>/dev/null
                settings put system aod_charging_mode 0 2>/dev/null
                settings put secure doze_always_on 0 2>/dev/null
                input keyevent 223 2>/dev/null
            " >/dev/null 2>&1
            local script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
            local state_file="$(dirname "$script_dir")/logs/$serial/tmp/deep_sleep_active"
            mkdir -p "$(dirname "$state_file")" 2>/dev/null
            touch "$state_file" 2>/dev/null
            ;;

        default|active|run|wake)
            echo "[⚡] [$serial] Restoring DEFAULT MODE (Wakeup, Stay-Awake, Full Performance)..."
            timeout 10 adb -s "$serial" shell "
                # 1. Restore All CPU Cores (All 8 cores online)
                su -c 'for c in 1 2 3 4 5 6 7; do echo 1 > /sys/devices/system/cpu/cpu\$c/online 2>/dev/null; done' 2>/dev/null

                # 2. Disable Airplane Mode & Enable Wi-Fi for SSID Connection
                cmd connectivity airplane-mode disable 2>/dev/null || settings put global airplane_mode_on 0 2>/dev/null
                svc wifi enable 2>/dev/null

                # 3. Wake Screen & Dismiss Keyguard
                input keyevent 224 2>/dev/null
                wm dismiss-keyguard 2>/dev/null
                settings put global stay_on_while_plugged_in 7 2>/dev/null
                settings put system screen_off_timeout 2147483647 2>/dev/null

                # 4. Foldable Check (Ensure main screen is OPEN)
                cmd device_state state 3 2>/dev/null || true

                # 5. Disable Android Battery Saver (Restore full performance)
                cmd power set-mode 0 2>/dev/null
                settings put global low_power 0 2>/dev/null

                # 6. Standard Display & Refresh Rate Profile
                settings put system screen_brightness_mode 0 2>/dev/null
                settings put system screen_brightness 50 2>/dev/null
                settings put system peak_refresh_rate 60.0 2>/dev/null
                settings put system min_refresh_rate 60.0 2>/dev/null
                cmd uimode night yes 2>/dev/null

                # 7. Maintain High-Current USB Charging
                settings put global protect_battery 0 2>/dev/null
                su -c '
                    echo 1 > /sys/class/power_supply/battery/batt_high_current_usb
                    echo 0 > /sys/devices/platform/samsung_mobile_device/samsung_mobile_device:battery/power_supply/battery/batt_slate_mode
                ' 2>/dev/null

                # 8. Restore Location / High-Accuracy GPS
                cmd location set-location-enabled true 2>/dev/null
                settings put secure location_mode 3 2>/dev/null
            " >/dev/null 2>&1
            local script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
            local state_file="$(dirname "$script_dir")/logs/$serial/tmp/deep_sleep_active"
            rm -f "$state_file" 2>/dev/null
            ;;

        *)
            echo "[-] Unknown power mode: $mode (Usage: set_power_mode <serial> <deep_sleep|default>)"
            return 1
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    set_power_mode "$1" "$2"
fi
