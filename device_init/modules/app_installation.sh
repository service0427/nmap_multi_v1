#!/usr/bin/env bash

# ============================================================
# Application Installation & Base Provisioning Module
# ============================================================

init_app_installation() {
    local serial=$1
    local has_su=$2
    local YELLOW="\e[1;33m"
    local GREEN="\e[1;32m"
    local NC="\e[0m"

    # Base installation paths on the host
    local SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
    local INSTALL_DIR="$PROJECT_ROOT/install"

    # Define packages and their files
    local APPS=(
        "com.nhn.android.nmap:1:$INSTALL_DIR/com.nhn.android.nmap_6.6.1/base.apk $INSTALL_DIR/com.nhn.android.nmap_6.6.1/split_config.arm64_v8a.apk $INSTALL_DIR/com.nhn.android.nmap_6.6.1/split_config.xxhdpi.apk"
        "com.rosteam.gpsemulator:1:$INSTALL_DIR/gpsemulator/base.apk $INSTALL_DIR/gpsemulator/split_config.arm64_v8a.apk $INSTALL_DIR/gpsemulator/split_config.ko.apk $INSTALL_DIR/gpsemulator/split_config.xxhdpi.apk"
        "com.android.adbkeyboard:0:$INSTALL_DIR/ADBKeyboard.apk"
    )

    # 1. Check Android-native BoringSSL Curl on the host
    local CURL_BIN="$INSTALL_DIR/curl-aarch64"
    if [ ! -f "$CURL_BIN" ]; then
        echo -e "    - [!] Error: BoringSSL curl binary not found at $CURL_BIN"
        echo -e "          Please run download_install_assets.sh or place the BoringSSL curl-aarch64 binary manually."
        exit 1
    fi

    echo -e "\n[*] Provisioning applications and base configuration..."

    # 2. Curl Check & Installation on the device
    local has_device_curl=$(adb -s "$serial" shell "which curl" 2>/dev/null | tr -d '\r')
    local is_boring="NO"
    if [ -n "$has_device_curl" ]; then
        is_boring=$(adb -s "$serial" shell "curl --version 2>/dev/null" | grep -q "BoringSSL" && echo "YES" || echo "NO")
    fi

    local curl_ok="NO"
    if [ "$is_boring" = "YES" ]; then
        local test_ip=$(adb -s "$serial" shell "curl -s -4 --connect-timeout 3 https://ifconfig.me" 2>/dev/null | tr -d '\r\n')
        if [[ "$test_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            curl_ok="YES"
        fi
    fi
    
    # Always ensure static curl is deployed to /data/local/tmp/curl as a reliable fallback
    echo -e "    - Deploying static 'curl' to /data/local/tmp/curl..."
    adb -s "$serial" push "$CURL_BIN" /data/local/tmp/curl >/dev/null 2>&1
    adb -s "$serial" shell "chmod 755 /data/local/tmp/curl"
    
    # Try system path installation as best effort (if missing or not BoringSSL)
    if [ -n "$has_su" ]; then
        if [ "$curl_ok" = "NO" ]; then
            echo -e "    - Installing BoringSSL curl to system paths..."
            # Unmount Zygisk file-level overlay (if active)
            adb -s "$serial" shell "$has_su -c 'umount /system/bin/curl'" >/dev/null 2>&1
            # Remount /system and /system/bin as rw
            adb -s "$serial" shell "$has_su -c 'mount -o rw,remount / 2>/dev/null || mount -o rw,remount /system 2>/dev/null; mount -o rw,remount /system/bin 2>/dev/null'" >/dev/null 2>&1
            # Copy to system and clean up legacy resolv.conf
            adb -s "$serial" shell "$has_su -c 'cp /data/local/tmp/curl /system/bin/curl 2>/dev/null || cp /data/local/tmp/curl /system/xbin/curl 2>/dev/null'" >/dev/null 2>&1
            adb -s "$serial" shell "$has_su -c 'chmod 755 /system/bin/curl 2>/dev/null || chmod 755 /system/xbin/curl 2>/dev/null'" >/dev/null 2>&1
            adb -s "$serial" shell "$has_su -c 'rm -f /system/etc/resolv.conf /etc/resolv.conf'" >/dev/null 2>&1
        else
            echo -e "    - System curl already works with BoringSSL. Skipping system install."
            # Clean up residual resolv.conf files if any exist on an already working device
            adb -s "$serial" shell "$has_su -c 'rm -f /system/etc/resolv.conf /etc/resolv.conf'" >/dev/null 2>&1
        fi
    fi

    # Final verification
    local verify_curl=$(adb -s "$serial" shell "which curl || [ -x /data/local/tmp/curl ] && echo '/data/local/tmp/curl'" 2>/dev/null | tr -d '\r')
    if [ -n "$verify_curl" ]; then
        echo -e "    [✓] 'curl' is ready on device ($verify_curl)."
    else
        echo -e "    [!] Failed to verify 'curl' on device."
    fi

    # 3. App Installation with Pass Logic
    local installed_packages=$(adb -s "$serial" shell pm list packages | cut -d':' -f2 | tr -d '\r')
    for app in "${APPS[@]}"; do
        IFS=':' read -r pkg type files <<< "$app"
        if echo "$installed_packages" | grep -qx "$pkg"; then
            echo -e "    [✓] $pkg is already installed. Skipping."
        else
            echo -e "    - $pkg not found. Installing..."
            if [ "$type" -eq "0" ]; then
                adb -s "$serial" install $files >/dev/null 2>&1
            else
                adb -s "$serial" install-multiple $files >/dev/null 2>&1
            fi
            
            # Verify installation
            local check_install=$(adb -s "$serial" shell pm list packages | cut -d':' -f2 | grep -qx "$pkg" && echo "YES" || echo "NO")
            if [ "$check_install" = "YES" ]; then
                echo -e "    [✓] $pkg installed successfully."
            else
                echo -e "    [!] Failed to install $pkg."
            fi
        fi
    done

    # Enable and Set ADBKeyboard as default if installed
    if adb -s "$serial" shell pm list packages | cut -d':' -f2 | grep -qx "com.android.adbkeyboard"; then
        echo -e "    - Enabling and setting ADBKeyboard input method as default..."
        adb -s "$serial" shell ime enable com.android.adbkeyboard/.AdbIME >/dev/null 2>&1
        adb -s "$serial" shell ime set com.android.adbkeyboard/.AdbIME >/dev/null 2>&1
        local current_ime=$(adb -s "$serial" shell settings get secure default_input_method | tr -d '\r')
        if [ "$current_ime" = "com.android.adbkeyboard/.AdbIME" ]; then
            echo -e "    [✓] ADBKeyboard input method is set as default."
        else
            echo -e "    [!] Failed to set ADBKeyboard input method as default."
        fi
    fi

    # 4. Push Magisk Modules to Download directory
    echo -e "    - Syncing Magisk modules to /sdcard/Download/..."
    if [ -d "$INSTALL_DIR/Magisk_Module" ]; then
        local need_push=false
        for f in "$INSTALL_DIR/Magisk_Module"/*.zip; do
            [ -e "$f" ] || continue
            local fname=$(basename "$f")
            if ! adb -s "$serial" shell "[ -f /sdcard/Download/$fname ]" >/dev/null 2>&1; then
                need_push=true; break
            fi
        done
        if [ "$need_push" = true ]; then
            adb -s "$serial" shell "mkdir -p /sdcard/Download"
            adb -s "$serial" push "$INSTALL_DIR/Magisk_Module/." /sdcard/Download/ >/dev/null 2>&1
            echo -e "    [✓] Magisk modules pushed to /sdcard/Download/."
        else
            echo -e "    [✓] Magisk modules are already in sync. Skipping."
        fi
    else
        echo -e "    [!] Local Magisk modules folder not found: $INSTALL_DIR/Magisk_Module"
    fi

    # 5. System Tweak & MTP Lockout
    echo -e "    - Applying System Tweaks & USB/MTP Lockout..."
    
    local su_cmd="su"
    if [ -n "$has_su" ]; then
        su_cmd="$has_su"
    fi
    adb -s "$serial" shell "$su_cmd -c 'setprop persist.sys.usb.config adb && setprop sys.usb.config adb && svc usb setFunctions adb'" 2>/dev/null
    sleep 2
    adb -s "$serial" wait-for-device
    
    # 5.2 Disable Bloatware & MTP packages
    adb -s "$serial" shell pm uninstall com.google.android.webview >/dev/null 2>&1
    adb -s "$serial" shell pm disable-user --user 0 com.android.vending >/dev/null 2>&1
    adb -s "$serial" shell pm disable-user --user 0 com.samsung.android.mtp >/dev/null 2>&1 || true
    adb -s "$serial" shell pm disable-user --user 0 com.samsung.android.mtpapplication >/dev/null 2>&1 || true
    adb -s "$serial" shell pm disable-user --user 0 com.android.mtp >/dev/null 2>&1 || true

    # 5.2.5 Disable Samsung Security Log Agent (Knox "Unauthorized changes" warning)
    for pkg in "com.samsung.android.securitylogagent" "com.sec.knox.securitylogagent"; do
        if adb -s "$serial" shell "pm list packages" | grep -q "$pkg"; then
            echo -e "    - Disabling $pkg to prevent Knox warning..."
            adb -s "$serial" shell "$su_cmd -c 'pm disable $pkg'" >/dev/null 2>&1 || \
            adb -s "$serial" shell "pm disable-user --user 0 $pkg" >/dev/null 2>&1
        fi
    done

    # 5.3 UI Settings
    adb -s "$serial" shell settings put system accelerometer_rotation 0 >/dev/null 2>&1
    adb -s "$serial" shell settings put global ota_disable_automatic_update 1 >/dev/null 2>&1

    # 5.3.5 Disable System Update & Galaxy Store packages to prevent auto-updates (Samsung)
    for pkg in "com.sec.android.soagent" "com.wssyncmldm" "com.sec.android.app.samsungapps"; do
        if adb -s "$serial" shell "pm list packages" | grep -q "$pkg"; then
            echo -e "    - Disabling $pkg to prevent auto-updates..."
            adb -s "$serial" shell "$su_cmd -c 'pm disable $pkg'" >/dev/null 2>&1 || \
            adb -s "$serial" shell "pm disable-user --user 0 $pkg" >/dev/null 2>&1
        fi
    done

    # 5.4 Disable Slow Charging Warning Popup (Samsung Devices)
    if [ -n "$has_su" ]; then
        local pref_dir="/data/user_de/0/com.android.systemui/shared_prefs"
        local pref_file="$pref_dir/com.android.systemui.power_slow_charger_connection_info.xml"
        
        # Check if SystemUI directory exists and find its owner
        local sysui_owner=$(adb -s "$serial" shell "$has_su -c 'stat -c \"%U:%G\" /data/user_de/0/com.android.systemui 2>/dev/null'" 2>/dev/null | tr -d '\r')
        if [ -n "$sysui_owner" ] && [[ "$sysui_owner" != *"No such"* ]]; then
            local current_val=$(adb -s "$serial" shell "$has_su -c 'cat $pref_file 2>/dev/null'" 2>/dev/null | tr -d '\r')
            if [[ "$current_val" != *"DoNotShowSlowChargerConnectionInfo"* ]] || [[ "$current_val" != *"true"* ]]; then
                adb -s "$serial" shell "$has_su -c 'mkdir -p $pref_dir && printf \"<?xml version=\\\"1.0\\\" encoding=\\\"utf-8\\\" standalone=\\\"yes\\\" ?>\n<map>\n    <boolean name=\\\"DoNotShowSlowChargerConnectionInfo\\\" value=\\\"true\\\" />\n</map>\n\" > $pref_file && chmod 660 $pref_file && chown $sysui_owner $pref_file'" >/dev/null 2>&1
                # Restart SystemUI to apply configuration
                adb -s "$serial" shell "$has_su -c 'pkill -f com.android.systemui'" >/dev/null 2>&1
            fi
        fi
    fi

    echo -e "    [✓] System tweaks and USB/MTP Lockout applied."
}
