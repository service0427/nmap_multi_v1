#!/usr/bin/env bash

# ============================================================
# Touch Protection Settings Module (Disables Accidental Touch Protection)
# ============================================================

init_touch_protection() {
    local serial=$1
    local has_su=$2
    local YELLOW="\e[1;33m"
    local GREEN="\e[1;32m"
    local NC="\e[0m"

    echo -e "\n[*] Checking Accidental Touch Protection (screen_off_pocket)..."
    
    local pocket_status=$(adb -s "$serial" shell "settings get system screen_off_pocket" 2>/dev/null | tr -d '\r')
    
    # Default to 1 (Samsung default enabled) if empty
    pocket_status=${pocket_status:-1}

    if [ "$pocket_status" = "1" ]; then
        echo -e "    - Accidental touch protection is currently ${YELLOW}ON (1)${NC}."
        echo -e "    - Disabling accidental touch protection..."
        adb -s "$serial" shell "settings put system screen_off_pocket 0"
        
        # Verify
        local pocket_verify=$(adb -s "$serial" shell "settings get system screen_off_pocket" 2>/dev/null | tr -d '\r')
        if [ "${pocket_verify:-0}" = "0" ]; then
            echo -e "    [✓] Accidental touch protection disabled successfully."
        else
            echo -e "    [!] Failed to disable accidental touch protection."
        fi
    elif [ "$pocket_status" = "0" ]; then
        echo -e "    [✓] Accidental touch protection is already ${GREEN}OFF (0)${NC}. Skipping."
    else
        echo -e "    [!] Could not read accidental touch protection status (Value: $pocket_status). Skipping."
    fi
}
