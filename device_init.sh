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


for serial in $DEVICES; do
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

    # 0.5. Automatic Package Installation check
    local is_nmap_installed=$(adb -s "$serial" shell "pm path com.nhn.android.nmap" 2>/dev/null | tr -d '\r')
    local is_gps_installed=$(adb -s "$serial" shell "pm path com.rosteam.gpsemulator" 2>/dev/null | tr -d '\r')
    if [ -z "$is_nmap_installed" ] || [ -z "$is_gps_installed" ]; then
        echo -e "${YELLOW}[*] Required packages not found. Automatically running install_devices.sh for $serial...${NC}"
        bash "$BASE_DIR/install_devices.sh" "$serial"
    fi

    # Run individual initialization modules
    init_bluetooth "$serial" "$HAS_SU"
    init_scanning_settings "$serial" "$HAS_SU"
    init_disaster_alerts "$serial" "$HAS_SU"
    init_gps_emulator "$serial" "$HAS_SU"
    init_naver_map "$serial" "$HAS_SU"         # Starts and closes Naver Map
    init_magisk_setup "$serial" "$HAS_SU"
    local magisk_reboot_status=$?
    
    # Run these at the very end to override/correct any volume/portrait changes caused by the apps
    init_sound "$serial" "$HAS_SU"
    init_screen_orientation "$serial" "$HAS_SU"

    # Apply MITM certificate recovery and reboot
    echo -e "\n[*] Running MITM certificate recovery & reboot..."
    if [ "$magisk_reboot_status" -eq 2 ]; then
        bash "$BASE_DIR/mitm_recovery.sh" "$serial" --force-reboot
    else
        bash "$BASE_DIR/mitm_recovery.sh" "$serial"
    fi

    echo -e "${CYAN}------------------------------------------------------------${NC}\n"
done

echo -e "${GREEN}[✓] Device Initialization Complete.${NC}"
