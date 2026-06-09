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
    
    # Ensure preference files exist (touch them if not)
    adb -s "$serial" shell "$has_su -c 'mkdir -p /data/data/com.nhn.android.nmap/shared_prefs'" 2>/dev/null
    adb -s "$serial" shell "$has_su -c 'touch /data/data/com.nhn.android.nmap/shared_prefs/NativeNaviDefaults.xml'" 2>/dev/null
    adb -s "$serial" shell "$has_su -c 'touch /data/data/com.nhn.android.nmap/shared_prefs/NaviSettingsInfo.xml'" 2>/dev/null

    # A. Disable Voice Guidance (NaviTtsTurnGuide=false) in NativeNaviDefaults.xml
    local check_tts=$(adb -s "$serial" shell "$has_su -c \"grep -c 'name=\\\"NaviTtsTurnGuide\\\"' /data/data/com.nhn.android.nmap/shared_prefs/NativeNaviDefaults.xml\"" 2>/dev/null | tr -d '\r')
    if [ "$check_tts" = "0" ] || [ -z "$check_tts" ]; then
        adb -s "$serial" shell "$has_su -c \"sed -i 's|</map>|    <boolean name=\\\"NaviTtsTurnGuide\\\" value=\\\"false\\\" />\\\n</map>|' /data/data/com.nhn.android.nmap/shared_prefs/NativeNaviDefaults.xml\""
    else
        adb -s "$serial" shell "$has_su -c \"sed -i 's|<boolean name=\\\"NaviTtsTurnGuide\\\" value=\\\"[a-zA-Z]*\\\"|<boolean name=\\\"NaviTtsTurnGuide\\\" value=\\\"false\\\"|' /data/data/com.nhn.android.nmap/shared_prefs/NativeNaviDefaults.xml\""
    fi

    # B. Set Mute volumes (PREF_NAVI_EFFECT_VOLUME=0, PREF_NAVI_VOLUME=0) in NaviSettingsInfo.xml
    local navi_settings_size=$(adb -s "$serial" shell "$has_su -c 'stat -c %s /data/data/com.nhn.android.nmap/shared_prefs/NaviSettingsInfo.xml'" 2>/dev/null | tr -d '\r')
    if [ -z "$navi_settings_size" ] || [ "$navi_settings_size" = "0" ]; then
        # Write default minimal XML
        adb -s "$serial" shell "$has_su -c \"echo -e '<?xml version=\\\'1.0\\\' encoding=\\\'utf-8\\\' standalone=\\\'yes\\\' ?>\\\n<map>\\\n    <int name=\\\"PREF_NAVI_EFFECT_VOLUME\\\" value=\\\"0\\\" />\\\n    <int name=\\\"PREF_NAVI_VOLUME\\\" value=\\\"0\\\" />\\\n</map>' > /data/data/com.nhn.android.nmap/shared_prefs/NaviSettingsInfo.xml\""
    else
        # Check if PREF_NAVI_EFFECT_VOLUME exists
        local check_effect=$(adb -s "$serial" shell "$has_su -c \"grep -c 'name=\\\"PREF_NAVI_EFFECT_VOLUME\\\"' /data/data/com.nhn.android.nmap/shared_prefs/NaviSettingsInfo.xml\"" 2>/dev/null | tr -d '\r')
        if [ "$check_effect" = "0" ] || [ -z "$check_effect" ]; then
            adb -s "$serial" shell "$has_su -c \"sed -i 's|</map>|    <int name=\\\"PREF_NAVI_EFFECT_VOLUME\\\" value=\\\"0\\\" />\\\n</map>|' /data/data/com.nhn.android.nmap/shared_prefs/NaviSettingsInfo.xml\""
        else
            adb -s "$serial" shell "$has_su -c \"sed -i 's|<int name=\\\"PREF_NAVI_EFFECT_VOLUME\\\" value=\\\"[0-9]*\\\"|<int name=\\\"PREF_NAVI_EFFECT_VOLUME\\\" value=\\\"0\\\"|' /data/data/com.nhn.android.nmap/shared_prefs/NaviSettingsInfo.xml\""
        fi

        # Check if PREF_NAVI_VOLUME exists
        local check_volume=$(adb -s "$serial" shell "$has_su -c \"grep -c 'name=\\\"PREF_NAVI_VOLUME\\\"' /data/data/com.nhn.android.nmap/shared_prefs/NaviSettingsInfo.xml\"" 2>/dev/null | tr -d '\r')
        if [ "$check_volume" = "0" ] || [ -z "$check_volume" ]; then
            adb -s "$serial" shell "$has_su -c \"sed -i 's|</map>|    <int name=\\\"PREF_NAVI_VOLUME\\\" value=\\\"0\\\" />\\\n</map>|' /data/data/com.nhn.android.nmap/shared_prefs/NaviSettingsInfo.xml\""
        else
            adb -s "$serial" shell "$has_su -c \"sed -i 's|<int name=\\\"PREF_NAVI_VOLUME\\\" value=\\\"[0-9]*\\\"|<int name=\\\"PREF_NAVI_VOLUME\\\" value=\\\"0\\\"|' /data/data/com.nhn.android.nmap/shared_prefs/NaviSettingsInfo.xml\""
        fi
    fi

    # C. Restore permissions & labels
    adb -s "$serial" shell "su -c 'chown -R $app_uid:$app_uid /data/data/com.nhn.android.nmap/shared_prefs/ && chmod -R 777 /data/data/com.nhn.android.nmap/shared_prefs/ && restorecon -R /data/data/com.nhn.android.nmap'" >/dev/null 2>&1
    
    # Verification checks
    local v_tts=$(adb -s "$serial" shell "$has_su -c \"grep 'name=\\\"NaviTtsTurnGuide\\\"' /data/data/com.nhn.android.nmap/shared_prefs/NativeNaviDefaults.xml\"" 2>/dev/null | tr -d '\r')
    local v_effect=$(adb -s "$serial" shell "$has_su -c \"grep 'name=\\\"PREF_NAVI_EFFECT_VOLUME\\\"' /data/data/com.nhn.android.nmap/shared_prefs/NaviSettingsInfo.xml\"" 2>/dev/null | tr -d '\r')
    local v_vol=$(adb -s "$serial" shell "$has_su -c \"grep 'name=\\\"PREF_NAVI_VOLUME\\\"' /data/data/com.nhn.android.nmap/shared_prefs/NaviSettingsInfo.xml\"" 2>/dev/null | tr -d '\r')

    if [[ "$v_tts" == *"value=\"false\""* ]] && [[ "$v_effect" == *"value=\"0\""* ]] && [[ "$v_vol" == *"value=\"0\""* ]]; then
        echo -e "    [✓] Naver Map internal mute configured successfully (Voice & Effect volumes set to 0)."
    else
        echo -e "    [!] Naver Map internal mute check failed: TTS: $v_tts, Effect: $v_effect, Volume: $v_vol"
    fi
}
