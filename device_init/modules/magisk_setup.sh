#!/usr/bin/env bash

# ============================================================
# Magisk Settings & Modules Initialization Module
# ============================================================

init_magisk_setup() {
    local serial=$1
    local has_su=$2
    local YELLOW="\e[1;33m"
    local GREEN="\e[1;32m"
    local NC="\e[0m"
    local reboot_required=false

    # 1. Zygisk Check & Enable
    echo -e "\n[*] Checking Magisk Zygisk status..."
    if [ -n "$has_su" ]; then
        local zygisk_val=$(adb -s "$serial" shell "$has_su -c 'magisk --sqlite \"SELECT value FROM settings WHERE key=\\\"zygisk\\\";\"'" 2>/dev/null | grep -o 'value=[0-9]' | cut -d'=' -f2 | tr -d '\r')
        if [ "$zygisk_val" != "1" ]; then
            echo -e "    - Zygisk is currently ${YELLOW}DISABLED (or not set)${NC}."
            echo -e "    - Enabling Zygisk..."
            adb -s "$serial" shell "$has_su -c 'magisk --sqlite \"REPLACE INTO settings (key, value) VALUES (\\\"zygisk\\\", 1);\"'" 2>/dev/null
            
            local zygisk_verify=$(adb -s "$serial" shell "$has_su -c 'magisk --sqlite \"SELECT value FROM settings WHERE key=\\\"zygisk\\\";\"'" 2>/dev/null | grep -o 'value=[0-9]' | cut -d'=' -f2 | tr -d '\r')
            if [ "$zygisk_verify" = "1" ]; then
                echo -e "    [✓] Zygisk enabled successfully in database."
                reboot_required=true
            else
                echo -e "    [!] Failed to enable Zygisk via Magisk DB."
            fi
        else
            echo -e "    [✓] Zygisk is already ${GREEN}ENABLED${NC} in Magisk settings. Skipping."
        fi
    else
        echo -e "    [-] su access unavailable. Cannot check Zygisk status."
    fi

    # 2. Magisk Modules Auto-Installation
    echo -e "\n[*] Checking Magisk modules in /sdcard/Download/..."
    if [ -n "$has_su" ]; then
        # Find all zip files in Download folder on device
        local zip_files=$(adb -s "$serial" shell "ls /sdcard/Download/*.zip 2>/dev/null" | tr -d '\r')
        
        if [ -z "$zip_files" ]; then
            echo -e "    - No Magisk module ZIP files found in /sdcard/Download/."
        else
            for zip_path in $zip_files; do
                [ -n "$zip_path" ] || continue
                local zip_name=$(basename "$zip_path")
                
                # Extract module ID using unzip on the device
                local mod_id=$(adb -s "$serial" shell "unzip -p \"$zip_path\" module.prop 2>/dev/null | grep '^id=' | cut -d'=' -f2" | tr -d '\r ')
                
                if [ -z "$mod_id" ]; then
                    echo -e "    [!] Failed to read module ID from $zip_name. Skipping."
                    continue
                fi
                
                # Check if module directory exists under /data/adb/modules/
                local is_installed=$(adb -s "$serial" shell "$has_su -c '[ -d /data/adb/modules/$mod_id ] && echo \"YES\" || echo \"NO\"'" | tr -d '\r')
                
                if [ "$is_installed" = "YES" ]; then
                    echo -e "    [✓] Module ${GREEN}$zip_name${NC} (ID: $mod_id) is already ${GREEN}INSTALLED${NC}. Skipping."
                else
                    echo -e "    - Module ${YELLOW}$zip_name${NC} (ID: $mod_id) is ${YELLOW}NOT INSTALLED${NC}."
                    echo -e "    - Installing module..."
                    
                    # Run unattended installation
                    adb -s "$serial" shell "$has_su -c 'magisk --install-module \"$zip_path\"'" >/dev/null 2>&1
                    
                    # Verify installation
                    local verify_install=$(adb -s "$serial" shell "$has_su -c '[ -d /data/adb/modules/$mod_id ] && echo \"YES\" || echo \"NO\"'" | tr -d '\r')
                    if [ "$verify_install" = "YES" ]; then
                        echo -e "    [✓] Module $zip_name installed successfully."
                        reboot_required=true
                    else
                        echo -e "    [!] Failed to install module $zip_name."
                    fi
                fi
            done
        fi
    else
        echo -e "    [-] su access unavailable. Cannot install Magisk modules."
    fi

    # Reboot warning
    if [ "$reboot_required" = true ]; then
        echo -e "\n${YELLOW}[!] Magisk configuration changes were made. PLEASE REBOOT the device to apply.${NC}"
    fi
}
