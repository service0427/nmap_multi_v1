#!/usr/bin/env bash

# ============================================================
# Naver Map Initialization & Permissions Module
# ============================================================

init_naver_map() {
    local serial=$1
    local has_su=$2
    local YELLOW="\e[1;33m"
    local GREEN="\e[1;32m"
    local NC="\e[0m"

    echo -e "\n[*] Checking Naver Map (com.nhn.android.nmap) status..."

    # Check if package is installed
    local is_installed=$(adb -s "$serial" shell "pm path com.nhn.android.nmap" 2>/dev/null | tr -d '\r')
    if [ -z "$is_installed" ]; then
        echo -e "    ${YELLOW}[⚠️] Naver Map is NOT installed. Skipping this module.${NC}"
        return 0
    fi

    local pref_file="/data/data/com.nhn.android.nmap/shared_prefs/com.nhn.android.nmap_preferences.xml"
    local is_initialized="NO"

    if [ -n "$has_su" ]; then
        is_initialized=$(adb -s "$serial" shell "$has_su -c '[ -f $pref_file ] && echo \"YES\" || echo \"NO\"'" 2>/dev/null | tr -d '\r')
    fi

    # 1. First-time Launch & Initialize preferences
    if [ "$is_initialized" = "YES" ]; then
        echo -e "    [✓] Naver Map is already initialized. Skipping."
    else
        echo -e "    - Naver Map is NOT initialized. Performing first-time launch..."
        
        # Start Naver Map using monkey launcher
        adb -s "$serial" shell "monkey -p com.nhn.android.nmap -c android.intent.category.LAUNCHER 1" >/dev/null 2>&1
        
        # Poll up to 15 seconds waiting for preference file to be created
        local count=0
        local max_wait=15
        while [ $count -lt $max_wait ]; do
            sleep 1
            count=$((count + 1))
            local check=$(adb -s "$serial" shell "$has_su -c '[ -f $pref_file ] && echo \"YES\" || echo \"NO\"'" 2>/dev/null | tr -d '\r')
            if [ "$check" = "YES" ]; then
                echo -e "    [✓] Naver Map settings initialized successfully (Took ${count}s)."
                is_initialized="YES"
                break
            fi
        done

        if [ "$is_initialized" != "YES" ]; then
            echo -e "    [!] Timeout waiting for Naver Map preference initialization."
        fi

        # Force stop the app after initialization
        echo -e "    - Forcing Naver Map to close..."
        adb -s "$serial" shell "am force-stop com.nhn.android.nmap"
    fi

    # 2. Grant Runtime Permissions
    echo -e "\n[*] Checking Naver Map runtime permissions..."
    
    # Location
    local fine_loc=$(adb -s "$serial" shell "dumpsys package com.nhn.android.nmap" 2>/dev/null | grep "ACCESS_FINE_LOCATION" | grep "granted=true")
    if [ -z "$fine_loc" ]; then
        echo -e "    - Location permission is NOT granted. Granting..."
        adb -s "$serial" shell "pm grant com.nhn.android.nmap android.permission.ACCESS_FINE_LOCATION" 2>/dev/null
        adb -s "$serial" shell "pm grant com.nhn.android.nmap android.permission.ACCESS_COARSE_LOCATION" 2>/dev/null
        adb -s "$serial" shell "pm grant com.nhn.android.nmap android.permission.ACCESS_BACKGROUND_LOCATION" 2>/dev/null
        
        local fine_verify=$(adb -s "$serial" shell "dumpsys package com.nhn.android.nmap" 2>/dev/null | grep "ACCESS_FINE_LOCATION" | grep "granted=true")
        if [ -n "$fine_verify" ]; then
            echo -e "    [✓] Location permissions granted successfully."
        else
            echo -e "    [!] Failed to grant location permissions."
        fi
    else
        echo -e "    [✓] Location permissions are already granted. Skipping."
    fi

    # Notifications
    local post_notif=$(adb -s "$serial" shell "dumpsys package com.nhn.android.nmap" 2>/dev/null | grep "POST_NOTIFICATIONS" | grep "granted=true")
    if [ -z "$post_notif" ]; then
        echo -e "    - Notification permission is NOT granted. Granting..."
        adb -s "$serial" shell "pm grant com.nhn.android.nmap android.permission.POST_NOTIFICATIONS" 2>/dev/null
        
        local notif_verify=$(adb -s "$serial" shell "dumpsys package com.nhn.android.nmap" 2>/dev/null | grep "POST_NOTIFICATIONS" | grep "granted=true")
        if [ -n "$notif_verify" ]; then
            echo -e "    [✓] Notification permission granted successfully."
        else
            echo -e "    [!] Notification check failed (might not be supported on this OS version)."
        fi
    else
        echo -e "    [✓] Notification permission is already granted. Skipping."
    fi

    # Phone State
    local phone_state=$(adb -s "$serial" shell "dumpsys package com.nhn.android.nmap" 2>/dev/null | grep "READ_PHONE_STATE" | grep "granted=true")
    if [ -z "$phone_state" ]; then
        echo -e "    - Phone State permission is NOT granted. Granting..."
        adb -s "$serial" shell "pm grant com.nhn.android.nmap android.permission.READ_PHONE_STATE" 2>/dev/null
        
        local phone_verify=$(adb -s "$serial" shell "dumpsys package com.nhn.android.nmap" 2>/dev/null | grep "READ_PHONE_STATE" | grep "granted=true")
        if [ -n "$phone_verify" ]; then
            echo -e "    [✓] Phone State permission granted successfully."
        else
            echo -e "    [!] Failed to grant Phone State permission."
        fi
    else
        echo -e "    [✓] Phone State permission is already granted. Skipping."
    fi

    # Audio Record (Microphone)
    local audio_rec=$(adb -s "$serial" shell "dumpsys package com.nhn.android.nmap" 2>/dev/null | grep "RECORD_AUDIO" | grep "granted=true")
    if [ -z "$audio_rec" ]; then
        echo -e "    - Audio Record permission is NOT granted. Granting..."
        adb -s "$serial" shell "pm grant com.nhn.android.nmap android.permission.RECORD_AUDIO" 2>/dev/null
        
        local audio_verify=$(adb -s "$serial" shell "dumpsys package com.nhn.android.nmap" 2>/dev/null | grep "RECORD_AUDIO" | grep "granted=true")
        if [ -n "$audio_verify" ]; then
            echo -e "    [✓] Audio Record permission granted successfully."
        else
            echo -e "    [!] Failed to grant Audio Record permission."
        fi
    else
        echo -e "    [✓] Audio Record permission is already granted. Skipping."
    fi

    # 3. Draw Over Other Apps (SYSTEM_ALERT_WINDOW)
    echo -e "\n[*] Checking 'Draw over other apps' (SYSTEM_ALERT_WINDOW) for Naver Map..."
    local alert_win=$(adb -s "$serial" shell "appops get com.nhn.android.nmap SYSTEM_ALERT_WINDOW" 2>/dev/null)
    if [[ "$alert_win" != *"allow"* ]]; then
        echo -e "    - Draw over other apps is NOT allowed. Allowing..."
        adb -s "$serial" shell "appops set com.nhn.android.nmap SYSTEM_ALERT_WINDOW allow"
        
        # Verify
        local alert_verify=$(adb -s "$serial" shell "appops get com.nhn.android.nmap SYSTEM_ALERT_WINDOW" 2>/dev/null)
        if [[ "$alert_verify" == *"allow"* ]]; then
            echo -e "    [✓] Draw over other apps allowed successfully."
        else
            echo -e "    [!] Failed to set SYSTEM_ALERT_WINDOW AppOps."
        fi
    else
        echo -e "    [✓] Draw over other apps is already allowed. Skipping."
    fi

    # 4. Configure Naver Map Mute & Disable Voice Guidance preferences
    echo -e "\n[*] Configuring Naver Map internal mute settings..."
    
    # Retrieve app's UID
    local app_uid=$(adb -s "$serial" shell "pm list packages -U com.nhn.android.nmap" 2>/dev/null | grep -oE "uid:[0-9]+" | cut -d: -f2 | head -n 1)
    if [ -z "$app_uid" ]; then
        app_uid="root"
    fi
    
    # Force stop to avoid setting override by cached memory of active app
    adb -s "$serial" shell "am force-stop com.nhn.android.nmap"
    
    local SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local HOST_TMP="$(cd "$SCRIPT_DIR/.." && pwd)/tmp"
    mkdir -p "$HOST_TMP"

    # Create the modification script to run on the device
    cat << 'EOF' > "$HOST_TMP/nmap_mute_$serial.sh"
#!/system/bin/sh
DEFAULTS_FILE="/data/data/com.nhn.android.nmap/shared_prefs/NativeNaviDefaults.xml"
SETTINGS_FILE="/data/data/com.nhn.android.nmap/shared_prefs/NaviSettingsInfo.xml"
CONSENT_FILE="/data/data/com.nhn.android.nmap/shared_prefs/ConsentInfo.xml"
PREFS_FILE="/data/data/com.nhn.android.nmap/shared_prefs/com.nhn.android.nmap_preferences.xml"

# Ensure directory and files exist
mkdir -p "/data/data/com.nhn.android.nmap/shared_prefs"
touch "$DEFAULTS_FILE"
touch "$SETTINGS_FILE"
touch "$CONSENT_FILE"
touch "$PREFS_FILE"

# A. Disable Voice Guidance in NativeNaviDefaults.xml
if [ ! -s "$DEFAULTS_FILE" ] || ! grep -q "<map>" "$DEFAULTS_FILE"; then
    echo '<?xml version="1.0" encoding="utf-8" standalone="yes" ?>' > "$DEFAULTS_FILE"
    echo '<map>' >> "$DEFAULTS_FILE"
    echo '    <boolean name="NaviTtsTurnGuide" value="false" />' >> "$DEFAULTS_FILE"
    echo '</map>' >> "$DEFAULTS_FILE"
else
    if ! grep -q 'name="NaviTtsTurnGuide"' "$DEFAULTS_FILE"; then
        sed -i 's|</map>|    <boolean name="NaviTtsTurnGuide" value="false" />\n</map>|' "$DEFAULTS_FILE"
    else
        sed -i 's|<boolean name="NaviTtsTurnGuide" value="[a-zA-Z]*"|<boolean name="NaviTtsTurnGuide" value="false"|' "$DEFAULTS_FILE"
    fi
fi

# B. Set Mute volumes in NaviSettingsInfo.xml
if [ ! -s "$SETTINGS_FILE" ] || ! grep -q "<map>" "$SETTINGS_FILE"; then
    echo '<?xml version="1.0" encoding="utf-8" standalone="yes" ?>' > "$SETTINGS_FILE"
    echo '<map>' >> "$SETTINGS_FILE"
    echo '    <int name="PREF_NAVI_EFFECT_VOLUME" value="0" />' >> "$SETTINGS_FILE"
    echo '    <int name="PREF_NAVI_VOLUME" value="0" />' >> "$SETTINGS_FILE"
    echo '</map>' >> "$SETTINGS_FILE"
else
    if ! grep -q 'name="PREF_NAVI_EFFECT_VOLUME"' "$SETTINGS_FILE"; then
        sed -i 's|</map>|    <int name="PREF_NAVI_EFFECT_VOLUME" value="0" />\n</map>|' "$SETTINGS_FILE"
    else
        sed -i 's|<int name="PREF_NAVI_EFFECT_VOLUME" value="[0-9]*"|<int name="PREF_NAVI_EFFECT_VOLUME" value="0"|' "$SETTINGS_FILE"
    fi
    
    if ! grep -q 'name="PREF_NAVI_VOLUME"' "$SETTINGS_FILE"; then
        sed -i 's|</map>|    <int name="PREF_NAVI_VOLUME" value="0" />\n</map>|' "$SETTINGS_FILE"
    else
        sed -i 's|<int name="PREF_NAVI_VOLUME" value="[0-9]*"|<int name="PREF_NAVI_VOLUME" value="0"|' "$SETTINGS_FILE"
    fi
fi

# C. Inject/Bypass terms in ConsentInfo.xml (Location, Clova consent)
if [ ! -s "$CONSENT_FILE" ] || ! grep -q "<map>" "$CONSENT_FILE"; then
    echo '<?xml version="1.0" encoding="utf-8" standalone="yes" ?>' > "$CONSENT_FILE"
    echo '<map>' >> "$CONSENT_FILE"
    echo '    <string name="PREF_CONSENT_GUEST_MAP_TERMS_AGREEMENT_STATUS">2026-04-17</string>' >> "$CONSENT_FILE"
    echo '    <string name="PREF_CONSENT_GUEST_LOCATION_TERMS_AGREEMENT_STATUS">2026-04-17</string>' >> "$CONSENT_FILE"
    echo '    <string name="PREF_CONSENT_GUEST_MAP_LOCATION_TERMS_AGREEMENT_STATUS">2026-04-17</string>' >> "$CONSENT_FILE"
    echo '    <boolean name="PREF_CONSENT_CLOVA_CHECKED" value="true" />' >> "$CONSENT_FILE"
    echo '    <boolean name="PREF_CONSENT_CLOVA_AGREED" value="true" />' >> "$CONSENT_FILE"
    echo '    <boolean name="PREF_CONSENT_NEW_MAP_LOCATION_TERROD_AGREED" value="true" />' >> "$CONSENT_FILE"
    echo '    <boolean name="PREF_CONSENT_NEW_MAP_LOCATION_TERMS_AGREED" value="true" />' >> "$CONSENT_FILE"
    echo '</map>' >> "$CONSENT_FILE"
else
    for key in "PREF_CONSENT_CLOVA_CHECKED" "PREF_CONSENT_CLOVA_AGREED" "PREF_CONSENT_NEW_MAP_LOCATION_TERMS_AGREED"; do
        if ! grep -q "name=\"$key\"" "$CONSENT_FILE"; then
            sed -i "s|</map>|    <boolean name=\"$key\" value=\"true\" />\n</map>|" "$CONSENT_FILE"
        else
            sed -i "s|<boolean name=\"$key\" value=\"[a-zA-Z]*\"|<boolean name=\"$key\" value=\"true\"|" "$CONSENT_FILE"
        fi
    done
fi

# D. Inject/Bypass darkmode alert, hipass warning, and first-run tutorial in com.nhn.android.nmap_preferences.xml
if [ ! -s "$PREFS_FILE" ] || ! grep -q "<map>" "$PREFS_FILE"; then
    echo '<?xml version="1.0" encoding="utf-8" standalone="yes" ?>' > "$PREFS_FILE"
    echo '<map>' >> "$PREFS_FILE"
    echo '    <boolean name="THEME_CHANGE_POPUP_NEVER_SHOW_AGAIN" value="true" />' >> "$PREFS_FILE"
    echo '    <boolean name="HIPASS_POPUP_SHOWN" value="true" />' >> "$PREFS_FILE"
    echo '    <boolean name="PREF_NOT_FIRST_RUN" value="true" />' >> "$PREFS_FILE"
    echo '</map>' >> "$PREFS_FILE"
else
    for key in "THEME_CHANGE_POPUP_NEVER_SHOW_AGAIN" "HIPASS_POPUP_SHOWN" "PREF_NOT_FIRST_RUN"; do
        if ! grep -q "name=\"$key\"" "$PREFS_FILE"; then
            sed -i "s|</map>|    <boolean name=\"$key\" value=\"true\" />\n</map>|" "$PREFS_FILE"
        else
            sed -i "s|<boolean name=\"$key\" value=\"[a-zA-Z]*\"|<boolean name=\"$key\" value=\"true\"|" "$PREFS_FILE"
        fi
    done
fi
EOF

    # Push and execute the helper script
    adb -s "$serial" push "$HOST_TMP/nmap_mute_$serial.sh" /data/local/tmp/nmap_mute.sh >/dev/null 2>&1
    adb -s "$serial" shell "$has_su -c 'sh /data/local/tmp/nmap_mute.sh'"
    adb -s "$serial" shell "$has_su -c 'rm -f /data/local/tmp/nmap_mute.sh'"
    rm -f "$HOST_TMP/nmap_mute_$serial.sh"

    # C. Restore permissions & labels
    local su_cmd="su"
    if [ -n "$has_su" ]; then
        su_cmd="$has_su"
    fi
    adb -s "$serial" shell "$su_cmd -c 'chown -R $app_uid:$app_uid /data/data/com.nhn.android.nmap/shared_prefs/ && chmod -R 777 /data/data/com.nhn.android.nmap/shared_prefs/ && restorecon -R /data/data/com.nhn.android.nmap'" >/dev/null 2>&1
    
    # Verification checks (Perform cat on device and grep on host for safety and simplicity)
    local v_tts=$(adb -s "$serial" shell "$has_su -c 'cat /data/data/com.nhn.android.nmap/shared_prefs/NativeNaviDefaults.xml'" 2>/dev/null | grep 'name="NaviTtsTurnGuide"' | tr -d '\r')
    local v_effect=$(adb -s "$serial" shell "$has_su -c 'cat /data/data/com.nhn.android.nmap/shared_prefs/NaviSettingsInfo.xml'" 2>/dev/null | grep 'name="PREF_NAVI_EFFECT_VOLUME"' | tr -d '\r')
    local v_vol=$(adb -s "$serial" shell "$has_su -c 'cat /data/data/com.nhn.android.nmap/shared_prefs/NaviSettingsInfo.xml'" 2>/dev/null | grep 'name="PREF_NAVI_VOLUME"' | tr -d '\r')


    if [[ "$v_tts" == *"value=\"false\""* ]] && [[ "$v_effect" == *"value=\"0\""* ]] && [[ "$v_vol" == *"value=\"0\""* ]]; then
        echo -e "    [✓] Naver Map internal mute configured successfully (Voice & Effect volumes set to 0)."
    else
        echo -e "    [!] Naver Map internal mute check failed: TTS: $v_tts, Effect: $v_effect, Volume: $v_vol"
    fi
}
