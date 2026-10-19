#!/usr/bin/env bash
# ==============================================================================
# Power Mode Controller for Device Fleet (Android 11~15 / Galaxy S20+ Modular)
# - Stage 1 (< 25%)  : deep_sleep (Max power saving & fast charging, Airplane ON, CPU Big-Cores OFF, Screen OFF)
# - Stage 2 (25~30%) : default    (Prepared in normal mode, Airplane OFF, Wi-Fi ON, CPU All-Cores ON, Standby charging)
# - Stage 3 (>= 31%) : default    (Full navigation task execution allowed)
# ==============================================================================

# Common helper snippet executed on-device (inside adb shell) to ensure charging
# is active and reset Samsung PMIC "Safety timer expire" / "Not charging" lock
# across different kernel sysfs layouts (Snapdragon, Exynos, GKI 1.0/2.0, Android 11~15).
get_charging_recovery_script() {
    cat << 'EOF'
settings put global protect_battery 0 2>/dev/null || true
settings put system super_fast_charging 1 2>/dev/null || true
settings put system adaptive_fast_charging 1 2>/dev/null || true

su -c '
    # 1. Locate battery sysfs directory across Samsung kernel variants
    BATT_DIR=""
    for d in \
        "/sys/class/power_supply/battery" \
        "/sys/devices/platform/samsung_mobile_device/samsung_mobile_device:battery/power_supply/battery" \
        "/sys/devices/platform/battery/power_supply/battery" \
        "/sys/devices/platform/sec-battery/power_supply/battery"; do
        if [ -d "$d" ]; then
            BATT_DIR="$d"
            break
        fi
    done

    if [ -n "$BATT_DIR" ]; then
        # Enable high-current USB charging if supported by kernel
        [ -f "$BATT_DIR/batt_high_current_usb" ] && echo 1 > "$BATT_DIR/batt_high_current_usb" 2>/dev/null
        # Disable retail store demo charging cap if present
        [ -f "$BATT_DIR/store_mode" ] && echo 0 > "$BATT_DIR/store_mode" 2>/dev/null
        # Override Android 14/15 One UI 6+ battery protection cap (80%/85% -> 100%) if present
        if [ -f "$BATT_DIR/batt_full_capacity" ]; then
            CUR_CAP=$(cat "$BATT_DIR/batt_full_capacity" 2>/dev/null | tr -d " \r\n")
            [ -n "$CUR_CAP" ] && [ "$CUR_CAP" != "100" ] && echo 100 > "$BATT_DIR/batt_full_capacity" 2>/dev/null
        fi
        # Disable Qualcomm/GKI input suspend if present
        [ -f "$BATT_DIR/input_suspend" ] && echo 0 > "$BATT_DIR/input_suspend" 2>/dev/null
        [ -f "$BATT_DIR/charging_enabled" ] && echo 1 > "$BATT_DIR/charging_enabled" 2>/dev/null
    fi
    [ -f "/sys/class/power_supply/usb/input_suspend" ] && echo 0 > "/sys/class/power_supply/usb/input_suspend" 2>/dev/null

    # 2. Check for Samsung PMIC "Safety timer expire" or "Not charging" lock
    NEED_SLATE_TOGGLE=0
    if [ -n "$BATT_DIR" ] && [ -f "$BATT_DIR/uevent" ]; then
        if grep -qE "POWER_SUPPLY_STATUS=Not charging|POWER_SUPPLY_HEALTH=Safety timer expire" "$BATT_DIR/uevent" 2>/dev/null; then
            NEED_SLATE_TOGGLE=1
        fi
    fi

    # 3. Locate batt_slate_mode node and either toggle (1 -> 0) to clear timer lock or ensure 0
    for sp in \
        "/sys/class/power_supply/battery/batt_slate_mode" \
        "/sys/devices/platform/samsung_mobile_device/samsung_mobile_device:battery/power_supply/battery/batt_slate_mode" \
        "/sys/devices/platform/battery/power_supply/battery/batt_slate_mode" \
        "/sys/devices/platform/sec-battery/power_supply/battery/batt_slate_mode"; do
        if [ -f "$sp" ]; then
            CUR_SLATE=$(cat "$sp" 2>/dev/null | tr -d " \r\n")
            if [ "$NEED_SLATE_TOGGLE" -eq 1 ]; then
                echo 1 > "$sp" 2>/dev/null
                sleep 1
                echo 0 > "$sp" 2>/dev/null
            elif [ "$CUR_SLATE" != "0" ]; then
                echo 0 > "$sp" 2>/dev/null
            fi
            break
        fi
    done
' 2>/dev/null || true
EOF
}

set_power_mode() {
    local serial="$1"
    local mode="$2"
    [ -z "$serial" ] && return 1

    local charging_script
    charging_script="$(get_charging_recovery_script)"

    case "$mode" in
        deep_sleep|sleep|charging|max_save)
            echo "[⚡] [$serial] Applying DEEP SLEEP (Max Power Saving & Fast-Charging)..."
            timeout 12 adb -s "$serial" shell "
                # 1. Terminate heavy foreground/background navigation apps & GPS emulator
                am force-stop com.nhn.android.nmap 2>/dev/null
                am force-stop com.rosteam.gpsemulator 2>/dev/null

                # 2. Hardware Fast Charging & Safety Timer Recovery (Modular across Android 11~15 / S20+)
                $charging_script

                # 3. Enable Airplane Mode to kill RF antenna searching (~150-250mA saved)
                cmd connectivity airplane-mode enable 2>/dev/null || {
                    settings put global airplane_mode_on 1 2>/dev/null
                    am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true 2>/dev/null
                }

                # 4. Shutdown CPU Big Cores if hotplug is supported (Leave little cores active, ~150-200mA saved)
                su -c '
                    for c in 4 5 6 7; do
                        [ -f \"/sys/devices/system/cpu/cpu\${c}/online\" ] && echo 0 > \"/sys/devices/system/cpu/cpu\${c}/online\" 2>/dev/null
                    done
                ' 2>/dev/null

                # 5. Enable Android OS Low Power Mode (Battery Saver)
                cmd power set-mode 1 2>/dev/null || true
                settings put global low_power 1 2>/dev/null || true

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
            local state_file="$(dirname "$script_dir")/logs/devices/$serial/tmp/deep_sleep_active"
            mkdir -p "$(dirname "$state_file")" 2>/dev/null
            touch "$state_file" 2>/dev/null
            ;;

        default|active|run|wake)
            echo "[⚡] [$serial] Restoring DEFAULT MODE (Wakeup, Stay-Awake, Full Performance)..."
            timeout 12 adb -s "$serial" shell "
                # 1. Restore All CPU Cores (Check existence for 8-core/10-core models)
                su -c '
                    for c in 1 2 3 4 5 6 7 8 9; do
                        [ -f \"/sys/devices/system/cpu/cpu\${c}/online\" ] && echo 1 > \"/sys/devices/system/cpu/cpu\${c}/online\" 2>/dev/null
                    done
                ' 2>/dev/null

                # 2. Disable Airplane Mode & Enable Wi-Fi for SSID Connection (Android 11~15 compatible)
                cmd connectivity airplane-mode disable 2>/dev/null || {
                    settings put global airplane_mode_on 0 2>/dev/null
                    am broadcast -a android.intent.action.AIRPLANE_MODE --ez state false 2>/dev/null
                }
                svc wifi enable 2>/dev/null || true
                cmd wifi set-wifi-enabled enabled 2>/dev/null || true

                # 3. Wake Screen, Exit Doze & Dismiss Keyguard
                cmd deviceidle unforce 2>/dev/null || true
                input keyevent 224 2>/dev/null
                wm dismiss-keyguard 2>/dev/null || true
                input keyevent 82 2>/dev/null
                settings put secure lockscreen.disabled 1 2>/dev/null
                settings put global stay_on_while_plugged_in 7 2>/dev/null
                settings put system screen_off_timeout 2147483647 2>/dev/null
                settings put global adb_allowed_connection_time 0 2>/dev/null

                # 4. Foldable Check (Only run on SM-F* foldables where device_state service exists)
                MODEL=\$(getprop ro.product.model 2>/dev/null)
                case \"\$MODEL\" in
                    SM-F*)
                        if cmd -l 2>/dev/null | grep -q 'device_state'; then
                            if ! cmd device_state state 2>/dev/null | grep -q 'Committed state:.*OPEN'; then
                                cmd device_state state 3 2>/dev/null || true
                                sleep 0.5 2>/dev/null
                            fi
                        fi
                        ;;
                esac
                settings put system accelerometer_rotation 0 2>/dev/null
                settings put system user_rotation 0 2>/dev/null

                # 5. Disable Android Battery Saver (Restore full performance)
                cmd power set-mode 0 2>/dev/null || true
                settings put global low_power 0 2>/dev/null || true

                # 6. Standard Display & Refresh Rate Profile
                settings put system screen_brightness_mode 0 2>/dev/null
                settings put system screen_brightness 50 2>/dev/null
                settings put system peak_refresh_rate 60.0 2>/dev/null
                settings put system min_refresh_rate 60.0 2>/dev/null
                cmd uimode night yes 2>/dev/null || true

                # 7. Maintain Fast Charging & Safety Timer Recovery (Modular across Android 11~15 / S20+)
                $charging_script

                # 8. Restore Location / High-Accuracy GPS
                cmd location set-location-enabled true 2>/dev/null || true
                settings put secure location_mode 3 2>/dev/null
                settings put secure location_providers_allowed '+gps,+network' 2>/dev/null
            " >/dev/null 2>&1
            local script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
            local state_file="$(dirname "$script_dir")/logs/devices/$serial/tmp/deep_sleep_active"
            rm -f "$state_file" "$(dirname "$script_dir")/logs/$serial/tmp/deep_sleep_active" 2>/dev/null
            ;;

        heal_charging)
            echo "[⚡] [$serial] Executing targeted charging safety-timer recovery..."
            timeout 10 adb -s "$serial" shell "$charging_script" >/dev/null 2>&1
            ;;

        *)
            echo "[-] Unknown power mode: $mode (Usage: set_power_mode <serial> <deep_sleep|default|heal_charging>)"
            return 1
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    set_power_mode "$1" "$2"
fi
