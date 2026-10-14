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
        local pref_dir="/data/user_de/0/com.google.android.cellbroadcastreceiver/shared_prefs"
        local pref_file="$pref_dir/com.google.android.cellbroadcastreceiver_preferences.xml"
        
        # Check if preferences file exists and check all critical alert toggle values
        local check_alerts=$(adb -s "$serial" shell "$has_su -c '
            f=\"$pref_file\"
            if [ ! -f \"\$f\" ]; then
                echo \"NEED_DISABLE\"
            elif grep -q -E \"enable_alerts_master_toggle.*true|enable_public_safety_messages.*true|enable_cmas_severe_threat_alerts.*true|enable_cmas_extreme_threat_alerts.*true|enable_cmas_amber_alerts.*true|enable_emergency_alerts.*true\" \"\$f\"; then
                echo \"NEED_DISABLE\"
            else
                echo \"OK\"
            fi
        '" 2>/dev/null | tr -d '\r\n ')
        
        local is_pkg_disabled=$(adb -s "$serial" shell "pm list packages -d | grep -q 'com.google.android.cellbroadcastreceiver' && echo 'YES' || echo 'NO'" 2>/dev/null | tr -d '\r\n ')

        if [ "$check_alerts" = "NEED_DISABLE" ] || [ "$is_pkg_disabled" != "YES" ]; then
            echo -e "    - Alerts are currently ${YELLOW}ENABLED or INCOMPLETE${NC}."
            echo -e "    - Disabling Emergency/Disaster Alerts completely..."

            # 1. Force stop app first to prevent in-memory cache overwriting files
            adb -s "$serial" shell "am force-stop com.google.android.cellbroadcastreceiver" 2>/dev/null

            # 2. Configure XML preferences under /data/user_de/0
            adb -s "$serial" shell "$has_su -c '
                PREF_DIR=\"/data/user_de/0/com.google.android.cellbroadcastreceiver/shared_prefs\"
                PREF_FILE=\"\$PREF_DIR/com.google.android.cellbroadcastreceiver_preferences.xml\"
                mkdir -p \"\$PREF_DIR\"

                # Get package UID/GID
                OWNER=\$(stat -c \"%U:%G\" /data/user_de/0/com.google.android.cellbroadcastreceiver 2>/dev/null)
                [ -z \"\$OWNER\" ] && OWNER=\$(stat -c \"%U:%G\" \"\$PREF_DIR\" 2>/dev/null)
                [ -z \"\$OWNER\" ] && OWNER=\"u0_a273:u0_a273\"

                if [ ! -f \"\$PREF_FILE\" ]; then
                    cat << \"EOF\" > \"\$PREF_FILE\"
<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\" ?>
<map>
    <boolean name=\"enable_alerts_master_toggle\" value=\"false\" />
    <boolean name=\"enable_emergency_alerts\" value=\"false\" />
    <boolean name=\"enable_public_safety_messages\" value=\"false\" />
    <boolean name=\"enable_public_safety_messages_full_screen\" value=\"false\" />
    <boolean name=\"enable_cmas_severe_threat_alerts\" value=\"false\" />
    <boolean name=\"enable_cmas_extreme_threat_alerts\" value=\"false\" />
    <boolean name=\"enable_cmas_amber_alerts\" value=\"false\" />
    <boolean name=\"enable_area_update_info_alerts\" value=\"false\" />
    <boolean name=\"enable_alert_vibrate\" value=\"false\" />
    <boolean name=\"enable_alert_speech\" value=\"false\" />
    <boolean name=\"enable_test_alerts\" value=\"false\" />
    <boolean name=\"enable_state_local_test_alerts\" value=\"false\" />
    <boolean name=\"enable_exercise_alerts\" value=\"false\" />
    <boolean name=\"enable_operator_defined_alerts\" value=\"false\" />
    <boolean name=\"receive_cmas_in_second_language\" value=\"false\" />
    <boolean name=\"override_dnd\" value=\"false\" />
    <string name=\"alert_reminder_interval\">0</string>
    <boolean name=\"any_preference_changed_by_user\" value=\"true\" />
    <boolean name=\"_has_set_default_values\" value=\"true\" />
</map>
EOF
                else
                    KEYS=(
                        \"enable_alerts_master_toggle\"
                        \"enable_emergency_alerts\"
                        \"enable_public_safety_messages\"
                        \"enable_public_safety_messages_full_screen\"
                        \"enable_cmas_severe_threat_alerts\"
                        \"enable_cmas_extreme_threat_alerts\"
                        \"enable_cmas_amber_alerts\"
                        \"enable_area_update_info_alerts\"
                        \"enable_alert_vibrate\"
                        \"enable_alert_speech\"
                        \"enable_test_alerts\"
                        \"enable_state_local_test_alerts\"
                        \"enable_exercise_alerts\"
                        \"enable_operator_defined_alerts\"
                        \"receive_cmas_in_second_language\"
                        \"override_dnd\"
                    )
                    for k in \"\${KEYS[@]}\"; do
                        if grep -q \"name=\\\"\$k\\\"\" \"\$PREF_FILE\"; then
                            sed -i \"s/\\\"\$k\\\" value=\\\"true\\\"/\\\"\$k\\\" value=\\\"false\\\"/g\" \"\$PREF_FILE\"
                        else
                            sed -i \"/<\\/map>/i \\    <boolean name=\\\"\$k\\\" value=\\\"false\\\" \\/>\" \"\$PREF_FILE\"
                        fi
                    done

                    # Crucial: any_preference_changed_by_user & _has_set_default_values prevent carrier override on reboot
                    if grep -q \"name=\\\"any_preference_changed_by_user\\\"\" \"\$PREF_FILE\"; then
                        sed -i \"s/\\\"any_preference_changed_by_user\\\" value=\\\"false\\\"/\\\"any_preference_changed_by_user\\\" value=\\\"true\\\"/g\" \"\$PREF_FILE\"
                    else
                        sed -i \"/<\\/map>/i \\    <boolean name=\\\"any_preference_changed_by_user\\\" value=\\\"true\\\" \\/>\" \"\$PREF_FILE\"
                    fi

                    if grep -q \"name=\\\"_has_set_default_values\\\"\" \"\$PREF_FILE\"; then
                        sed -i \"s/\\\"_has_set_default_values\\\" value=\\\"false\\\"/\\\"_has_set_default_values\\\" value=\\\"true\\\"/g\" \"\$PREF_FILE\"
                    else
                        sed -i \"/<\\/map>/i \\    <boolean name=\\\"_has_set_default_values\\\" value=\\\"true\\\" \\/>\" \"\$PREF_FILE\"
                    fi
                fi

                chown -R \"\$OWNER\" \"\$PREF_DIR\"
                chmod 771 \"\$PREF_DIR\"
                chmod 660 \"\$PREF_FILE\"
            '" 2>/dev/null

            # 3. Disable CellBroadcastReceiver package to 100% prevent popups
            adb -s "$serial" shell "pm disable-user --user 0 com.google.android.cellbroadcastreceiver" >/dev/null 2>&1 || true

            # Verify disabling
            local check_alerts_verify=$(adb -s "$serial" shell "$has_su -c '
                f=\"$pref_file\"
                if [ -f \"\$f\" ] && ! grep -q -E \"enable_alerts_master_toggle.*true|enable_public_safety_messages.*true|enable_cmas_severe_threat_alerts.*true|enable_cmas_extreme_threat_alerts.*true\" \"\$f\"; then
                    echo \"OK\"
                else
                    echo \"FAIL\"
                fi
            '" 2>/dev/null | tr -d '\r\n ')

            if [ "$check_alerts_verify" = "OK" ]; then
                echo -e "    [✓] Emergency/Disaster Alerts disabled successfully."
            else
                echo -e "    [!] Failed to disable emergency alerts. Please check root access or preference file manually."
            fi
        else
            echo -e "    [✓] Emergency Alerts are already ${GREEN}DISABLED${NC} & Package blocked. Skipping."
        fi
    else
        echo -e "    [-] su access unavailable. Cannot verify/disable Emergency Alerts."
    fi
}
