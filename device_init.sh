#!/usr/bin/env bash

# ============================================================
# Naver Map Auto-Simulation Infrastructure (V2)
# Device Initialization Script (Modular Runner)
# ============================================================

# Resolve script directory to load modules correctly
BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source modules
source "$BASE_DIR/device_init/modules/bluetooth.sh"
source "$BASE_DIR/device_init/modules/sound.sh"
source "$BASE_DIR/device_init/modules/disaster_alerts.sh"
source "$BASE_DIR/device_init/modules/magisk_setup.sh"
source "$BASE_DIR/device_init/modules/scanning_settings.sh"
source "$BASE_DIR/device_init/modules/screen_orientation.sh"
source "$BASE_DIR/device_init/modules/gps_emulator_setup.sh"
source "$BASE_DIR/device_init/modules/naver_map_setup.sh"
source "$BASE_DIR/device_init/modules/app_installation.sh"
source "$BASE_DIR/device_init/modules/mitm_recovery.sh"
source "$BASE_DIR/device_init/modules/touch_protection.sh"

# Get target device from argument (optional)
TARGET_DEVICE=$1

# Get connected devices
if [ -z "$TARGET_DEVICE" ]; then
    echo "[*] No target device specified. Checking all connected devices..."
    DEVICES=$(adb devices | grep -w "device" | awk '{print $1}')
else
    echo "[*] Targeting specific device: $TARGET_DEVICE"
    DEVICES=$TARGET_DEVICE
fi

if [ -z "$DEVICES" ]; then
    echo "[-] No devices connected."
    exit 1
fi

CYAN="\e[1;36m"
GREEN="\e[1;32m"
YELLOW="\e[1;33m"
NC="\e[0m"

# Preliminary Root Check for multi-device initialization
if [ -z "$TARGET_DEVICE" ]; then
    echo -e "${YELLOW}[*] Performing preliminary root authorization check on all connected devices...${NC}"
    FAILED_DEVICES=()
    NO_SU_DEVICES=()
    
    for serial in $DEVICES; do
        # Find su
        HAS_SU=$(adb -s "$serial" shell "which su" 2>/dev/null | tr -d '\r')
        if [ -z "$HAS_SU" ]; then
            HAS_SU=$(adb -s "$serial" shell "ls /system/bin/su /system/xbin/su /sbin/su 2>/dev/null" | head -1 | tr -d '\r')
        fi
        
        if [ -z "$HAS_SU" ]; then
            echo -e "  - ${serial}: ${YELLOW}su not found${NC}"
            NO_SU_DEVICES+=("$serial")
            continue
        fi
        
        # Test su with a 3-second timeout. If it's waiting for approval, it will time out and trigger the prompt on device.
        SU_TEST=$(timeout 3 adb -s "$serial" shell "$HAS_SU -c 'id'" 2>/dev/null | tr -d '\r')
        if [[ "$SU_TEST" == *"uid=0"* ]]; then
            echo -e "  - ${serial}: ${GREEN}Root shell authorization OK${NC}"
        else
            echo -e "  - ${serial}: ${YELLOW}Root shell authorization failed / Requesting popup...${NC}"
            FAILED_DEVICES+=("$serial")
        fi
    done
    
    # Check if there are failures
    if [ ${#FAILED_DEVICES[@]} -ne 0 ] || [ ${#NO_SU_DEVICES[@]} -ne 0 ]; then
        echo -e "\n\e[1;31m[⚠️] 일부 디바이스의 Root 권한이 확보되지 않았습니다.\e[0m"
        
        if [ ${#FAILED_DEVICES[@]} -ne 0 ]; then
            echo -e "\n${YELLOW}[!] Magisk 권한 승인이 필요한 디바이스:${NC}"
            for serial in "${FAILED_DEVICES[@]}"; do
                echo -e "  - ${serial}"
            done
            echo -e "  -> 대상 휴대폰 화면을 켜고 Magisk 팝업 창에서 'Grant(허용)' 버튼을 클릭해주세요."
        fi
        
        if [ ${#NO_SU_DEVICES[@]} -ne 0 ]; then
            echo -e "\n${YELLOW}[!] 'su' 명령어를 찾을 수 없거나 루팅이 확인되지 않는 디바이스:${NC}"
            for serial in "${NO_SU_DEVICES[@]}"; do
                echo -e "  - ${serial}"
            done
            echo -e "  -> 기기가 정상적으로 루팅(Magisk)되어 있는지 확인해주세요."
        fi
        
        echo -e "\n승인 완료 후 이 스크립트를 다시 구동해주시기 바랍니다."
        exit 1
    fi
    echo -e "${GREEN}[✓] All connected devices passed root check. Proceeding to initialization...${NC}\n"
fi
# Ensure installation assets are present before initializing devices
INSTALL_DIR="$BASE_DIR/install"
if [ ! -d "$INSTALL_DIR" ] || [ ! -f "$INSTALL_DIR/com.nhn.android.nmap_6.6.1/base.apk" ]; then
    echo -e "${YELLOW}[*] Installation assets missing or incomplete. Triggering download...${NC}"
    if [ -f "$BASE_DIR/device_init/download_install_assets.sh" ]; then
        bash "$BASE_DIR/device_init/download_install_assets.sh"
        if [ $? -ne 0 ]; then
            echo -e "\e[1;31m[-] Error: Failed to download installation assets from Google Drive.\e[0m"
            exit 1
        fi
    else
        echo -e "\e[1;31m[-] Error: download_install_assets.sh not found.\e[0m"
        exit 1
    fi
fi

for serial in $DEVICES; do
    (
        echo -e "${CYAN}============================================================${NC}"
        echo -e "Initializing device: ${GREEN}$serial${NC}"
        echo -e "${CYAN}============================================================${NC}"

        # 0. Root Check
        HAS_SU=$(adb -s "$serial" shell "which su" 2>/dev/null | tr -d '\r')
        if [ -z "$HAS_SU" ]; then
            HAS_SU=$(adb -s "$serial" shell "ls /system/bin/su /system/xbin/su /sbin/su 2>/dev/null" | head -1 | tr -d '\r')
        fi

        if [ -n "$HAS_SU" ]; then
            echo -e "[*] Checking root shell authorization..."
            # Verify su execution
            SU_TEST=$(adb -s "$serial" shell "$HAS_SU -c 'id'" 2>/dev/null | tr -d '\r')
            if [[ "$SU_TEST" == *"uid=0"* ]]; then
                echo -e "[✓] Root shell authorization: ${GREEN}OK (uid=0)${NC}"
            else
                echo -e "\n\e[1;31m[⚠️] 디바이스 $serial 의 Root 권한(su) 승인이 필요합니다.\e[0m"
                echo -e "    - 휴대폰 화면을 켜고 Magisk 팝업 창에서 'Grant(허용)' 버튼을 클릭해주세요."
                echo -e "    - 승인 완료 후 이 스크립트를 다시 구동해주시기 바랍니다."
                exit 1
            fi
        else
            echo -e "\n\e[1;31m[⚠️] 에러: 디바이스 $serial 에서 'su' 명령어를 찾을 수 없습니다.\e[0m"
            echo -e "    - 기기가 정상적으로 루팅(Magisk)되어 있는지 확인해주세요."
            exit 1
        fi

        # 0.5. Run modular application installation & base provisioning
        init_app_installation "$serial" "$HAS_SU"

        # Run individual initialization modules
        init_bluetooth "$serial" "$HAS_SU"
        init_scanning_settings "$serial" "$HAS_SU"
        init_disaster_alerts "$serial" "$HAS_SU"
        init_gps_emulator "$serial" "$HAS_SU"
        init_naver_map "$serial" "$HAS_SU"         # Starts and closes Naver Map
        init_magisk_setup "$serial" "$HAS_SU"
        magisk_reboot_status=$?
        
        # Run these at the very end to override/correct any volume/portrait changes caused by the apps
        init_sound "$serial" "$HAS_SU"
        init_screen_orientation "$serial" "$HAS_SU"
        init_touch_protection "$serial" "$HAS_SU"

        # Apply MITM certificate recovery and reboot
        force_reboot_flag="false"
        if [ "$magisk_reboot_status" -eq 2 ]; then
            force_reboot_flag="true"
        fi
        init_mitm_recovery "$serial" "$HAS_SU" "$force_reboot_flag"

        echo -e "${CYAN}------------------------------------------------------------${NC}\n"
    ) 2>&1 | sed "s/^/[${serial}] /" &
done

wait
echo -e "${GREEN}[✓] Device Initialization Complete.${NC}"
