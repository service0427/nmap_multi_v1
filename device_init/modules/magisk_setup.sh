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
                
                # Module-specific integrity verification (Detect partial / corrupt installs)
                local is_corrupt=false
                if [ "$is_installed" = "YES" ]; then
                    if [ "$mod_id" = "magisk-frida" ]; then
                        local has_fs=$(adb -s "$serial" shell "$has_su -c '[ -x /data/adb/modules/magisk-frida/system/bin/frida-server ] && echo \"YES\" || echo \"NO\"'" | tr -d '\r')
                        if [ "$has_fs" != "YES" ]; then
                            echo -e "    - Module ${YELLOW}$zip_name${NC} (ID: $mod_id) is installed but ${YELLOW}CORRUPT / INCOMPLETE${NC} (missing system/bin/frida-server)."
                            is_corrupt=true
                        fi
                    fi
                fi

                # Self-healing repair for corrupt / incomplete module
                if [ "$is_corrupt" = true ]; then
                    echo -e "    - Attempting self-healing repair for $mod_id..."
                    local has_src=$(adb -s "$serial" shell "$has_su -c '[ -f /data/adb/modules/magisk-frida/files/frida-server-arm64 ] && echo \"YES\" || echo \"NO\"'" | tr -d '\r')
                    if [ "$has_src" = "YES" ]; then
                        adb -s "$serial" shell "$has_su -c '
                            mkdir -p /data/adb/modules/magisk-frida/system/bin /data/adb/modules/magisk-frida/logs
                            cp /data/adb/modules/magisk-frida/files/frida-server-arm64 /data/adb/modules/magisk-frida/system/bin/frida-server
                            chmod 755 /data/adb/modules/magisk-frida/system/bin/frida-server
                            chown 0:2000 /data/adb/modules/magisk-frida/system/bin/frida-server
                            chcon u:object_r:system_file:s0 /data/adb/modules/magisk-frida/system/bin/frida-server
                            rm -f /data/adb/modules/magisk-frida/disable
                        '" >/dev/null 2>&1
                        echo -e "    [✓] Self-healing repair completed. frida-server binary restored."
                        reboot_required=true
                        is_installed="YES"
                    else
                        echo -e "    - Source binary missing. Purging corrupt module directory to force clean reinstall..."
                        adb -s "$serial" shell "$has_su -c 'rm -rf /data/adb/modules/$mod_id'" >/dev/null 2>&1
                        is_installed="NO"
                    fi
                fi

                if [ "$is_installed" = "YES" ]; then
                    # Ensure logs directory exists for service.sh stdout/stderr redirection
                    if [ "$mod_id" = "magisk-frida" ]; then
                        adb -s "$serial" shell "$has_su -c 'mkdir -p /data/adb/modules/magisk-frida/logs'" >/dev/null 2>&1
                    fi

                    # Check if the module is currently disabled
                    local is_disabled=$(adb -s "$serial" shell "$has_su -c '[ -f /data/adb/modules/$mod_id/disable ] && echo \"YES\" || echo \"NO\"'" | tr -d '\r')
                    if [ "$is_disabled" = "YES" ]; then
                        echo -e "    - Module ${YELLOW}$zip_name${NC} (ID: $mod_id) is installed but ${YELLOW}DISABLED${NC}."
                        echo -e "    - Enabling module..."
                        adb -s "$serial" shell "$has_su -c 'rm -f /data/adb/modules/$mod_id/disable'" >/dev/null 2>&1
                        reboot_required=true
                    else
                        echo -e "    [✓] Module ${GREEN}$zip_name${NC} (ID: $mod_id) is already ${GREEN}INSTALLED & ACTIVE${NC}. Skipping."
                    fi
                else
                    echo -e "    - Module ${YELLOW}$zip_name${NC} (ID: $mod_id) is ${YELLOW}NOT INSTALLED${NC}."
                    echo -e "    - Installing module..."
                    
                    # Run unattended installation and capture output/errors
                    local install_log=$(adb -s "$serial" shell "$has_su -c 'magisk --install-module \"$zip_path\"'" 2>&1)
                    
                    # Post-installation verification and fallback repair
                    if [ "$mod_id" = "magisk-frida" ]; then
                        local has_fs=$(adb -s "$serial" shell "$has_su -c '[ -x /data/adb/modules/magisk-frida/system/bin/frida-server ] && echo \"YES\" || echo \"NO\"'" | tr -d '\r')
                        if [ "$has_fs" != "YES" ]; then
                            echo -e "    - [Fallback] Deploying frida-server binary directly..."
                            adb -s "$serial" shell "$has_su -c '
                                mkdir -p /data/adb/modules/magisk-frida/system/bin /data/adb/modules/magisk-frida/logs
                                if [ -f /data/adb/modules/magisk-frida/files/frida-server-arm64 ]; then
                                    cp /data/adb/modules/magisk-frida/files/frida-server-arm64 /data/adb/modules/magisk-frida/system/bin/frida-server
                                else
                                    unzip -p \"$zip_path\" files/frida-server-arm64 > /data/adb/modules/magisk-frida/system/bin/frida-server 2>/dev/null
                                fi
                                chmod 755 /data/adb/modules/magisk-frida/system/bin/frida-server
                                chown 0:2000 /data/adb/modules/magisk-frida/system/bin/frida-server
                                chcon u:object_r:system_file:s0 /data/adb/modules/magisk-frida/system/bin/frida-server
                                rm -f /data/adb/modules/magisk-frida/disable
                            '" >/dev/null 2>&1
                        fi
                    fi

                    # Verify installation
                    local verify_install=$(adb -s "$serial" shell "$has_su -c '[ -d /data/adb/modules/$mod_id ] && echo \"YES\" || echo \"NO\"'" | tr -d '\r')
                    if [ "$verify_install" = "YES" ]; then
                        # Make sure it's not disabled
                        adb -s "$serial" shell "$has_su -c 'rm -f /data/adb/modules/$mod_id/disable'" >/dev/null 2>&1
                        echo -e "    [✓] Module $zip_name installed successfully."
                        reboot_required=true
                    else
                        echo -e "    [!] Failed to install module $zip_name."
                        echo -e "    [!] Magisk install output:\n$install_log"
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
        return 2
    fi
    return 0
}
