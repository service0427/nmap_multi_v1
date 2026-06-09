#!/usr/bin/env bash

# ============================================================
# Emergency/Disaster Alerts Block Module
# ============================================================

init_disaster_alerts() {
    local serial=$1
    local has_su=$2
    local YELLOW="\e[1;33m"
    local GREEN="\e[1;32m"
    local NC="\e[0m"

    echo -e "\n[*] Checking Cell Broadcast (Emergency Alerts) configuration..."
    if [ -n "$has_su" ]; then
        local pref_file="/data/user_de/0/com.google.android.cellbroadcastreceiver/shared_prefs/com.google.android.cellbroadcastreceiver_preferences.xml"
        
        # Check if preferences file exists and check alert toggle values
        local check_alerts=$(adb -s "$serial" shell "$has_su -c '[ -f $pref_file ] && grep -q -E \"enable_alerts_master_toggle.*true|enable_alert_vibrate.*true|enable_emergency_alerts.*true\" $pref_file && echo \"NEED_DISABLE\" || echo \"OK\"'" 2>/dev/null | tr -d '\r')
        
        if [ "$check_alerts" = "NEED_DISABLE" ]; then
            echo -e "    - Alerts are currently ${YELLOW}ENABLED${NC} in configuration file."
            echo -e "    - Disabling Emergency Alerts..."
            adb -s "$serial" shell "$has_su -c '
                PREF_FILE=\"/data/user_de/0/com.google.android.cellbroadcastreceiver/shared_prefs/com.google.android.cellbroadcastreceiver_preferences.xml\"
                if [ -f \"\$PREF_FILE\" ]; then
                    OWNER=\$(stat -c \"%U:%G\" \"\$PREF_FILE\")
                    sed -i \"s/\\\"enable_alerts_master_toggle\\\" value=\\\"true\\\"/\\\"enable_alerts_master_toggle\\\" value=\\\"false\\\"/g\" \"\$PREF_FILE\"
                    sed -i \"s/\\\"enable_alert_vibrate\\\" value=\\\"true\\\"/\\\"enable_alert_vibrate\\\" value=\\\"false\\\"/g\" \"\$PREF_FILE\"
                    sed -i \"s/\\\"enable_emergency_alerts\\\" value=\\\"true\\\"/\\\"enable_emergency_alerts\\\" value=\\\"false\\\"/g\" \"\$PREF_FILE\"
                    chown \$OWNER \"\$PREF_FILE\"
                    chmod 660 \"\$PREF_FILE\"
                    am force-stop com.google.android.cellbroadcastreceiver
                fi
            '" 2>/dev/null
            
            # Verify disabling
            local check_alerts_verify=$(adb -s "$serial" shell "$has_su -c '[ -f $pref_file ] && grep -q -E \"enable_alerts_master_toggle.*true|enable_alert_vibrate.*true|enable_emergency_alerts.*true\" $pref_file && echo \"NEED_DISABLE\" || echo \"OK\"'" 2>/dev/null | tr -d '\r')
            if [ "$check_alerts_verify" = "OK" ]; then
                echo -e "    [✓] Emergency Alerts disabled successfully."
            else
                echo -e "    [!] Failed to disable emergency alerts. Please check root access or preference file manually."
            fi
        else
            echo -e "    [✓] Emergency Alerts are already ${GREEN}DISABLED${NC} (or settings not initialized). Skipping."
        fi
    else
        echo -e "    [-] su access unavailable. Cannot verify/disable Emergency Alerts."
    fi
}
