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
source "$BASE_DIR/device_init/modules/screen_lock.sh"

# Verify host PC naming convention (P01~P20 / M01~M50)
HOST_NAME=$(hostname 2>/dev/null | tr -d '\r\n')
if [ -n "$HOST_NAME" ]; then
    if [[ ! "$HOST_NAME" =~ ^(P(0[1-9]|1[0-9]|20)|M(0[1-9]|[1-4][0-9]|50))$ ]]; then
        echo -e "\e[1;33m[⚠️] Warning: Current host name '$HOST_NAME' does not match the new convention (P01~P20 / M01~M50).\e[0m"
        echo -e "    - Recommended Host Name format: English uppercase letter + 2 digits (e.g. P01, M05)"
    fi
fi

# Concurrency Lock: Prevent multiple overlapping device_init runs
LOCK_FILE="$BASE_DIR/.device_init.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo -e "\e[1;31m[-] 에러: 이미 다른 device_init.sh 인스턴스가 실행 중입니다.\e[0m"
    echo -e "    진행 중인 작업을 확인하거나 기존 프로세스를 정리한 후 다시 시도해주세요."
    exit 1
fi

# Graceful Ctrl+C (SIGINT) Interruption & Descendant Cleanup Handling
INTERRUPTING=false

get_all_descendants() {
    local pids=("$@")
    local all_desc=()
    while [ ${#pids[@]} -gt 0 ]; do
        local next_pids=()
        for p in "${pids[@]}"; do
            local children
            children=$(pgrep -P "$p" 2>/dev/null)
            if [ -n "$children" ]; then
                all_desc+=($children)
                next_pids+=($children)
            fi
        done
        pids=("${next_pids[@]}")
    done
    echo "${all_desc[@]}"
}

kill_all_children() {
    local desc
    desc=$(get_all_descendants $$)
    if [ -n "$desc" ]; then
        kill -9 $desc 2>/dev/null
    fi
    pkill -9 -P $$ 2>/dev/null
    kill -9 $(jobs -p) 2>/dev/null
    flock -u 200 2>/dev/null
    rm -f "$LOCK_FILE" 2>/dev/null
}

handle_sigint() {
    if [ "$INTERRUPTING" = true ]; then
        echo -e "\n\e[1;31m[*] 강제 종료 신호 재감지. 즉시 종료합니다...\e[0m"
        kill_all_children
        exit 130
    fi
    INTERRUPTING=true

    echo -e "\n\e[1;33m[!] Ctrl+C (인터럽트) 신호가 감지되었습니다.\e[0m"
    local prompt_msg="[?] 디바이스 초기화/패치 작업을 중단하고 실행 중인 모든 프로세스를 종료하시겠습니까? (y/N): "
    
    local confirm=""
    if [ -c /dev/tty ] && [ -r /dev/tty ]; then
        read -r -p "$prompt_msg" confirm < /dev/tty 2>/dev/null
    else
        read -r -p "$prompt_msg" confirm 2>/dev/null
    fi

    if [[ "$confirm" =~ ^[yY](es)?$ ]]; then
        echo -e "\n\e[1;31m[*] 초기화 작업을 중단합니다. 모든 백그라운드 프로세스를 정리합니다...\e[0m"
        kill_all_children
        exit 130
    else
        echo -e "\e[1;32m[*] 초기화 작업을 계속 진행합니다...\e[0m"
        INTERRUPTING=false
    fi
}

trap handle_sigint SIGINT

# Parse options and target device (optional)
AUTO_PROCEED=false
TARGET_DEVICE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes|--skip-failed)
            AUTO_PROCEED=true
            shift
            ;;
        *)
            TARGET_DEVICE="$1"
            shift
            ;;
    esac
done

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
    
    IDX=1
    for serial in $DEVICES; do
        # Find su
        HAS_SU=$(adb -s "$serial" shell "which su" 2>/dev/null | tr -d '\r')
        if [ -z "$HAS_SU" ]; then
            HAS_SU=$(adb -s "$serial" shell "ls /system/bin/su /system/xbin/su /sbin/su 2>/dev/null" | head -1 | tr -d '\r')
        fi
        
        formatted_idx=$(printf "%02d" $IDX)
        if [ -z "$HAS_SU" ]; then
            echo -e "  - ${formatted_idx}. ${serial}: ${YELLOW}su not found${NC}"
            NO_SU_DEVICES+=("$serial")
            ((IDX++))
            continue
        fi
        
        # Test su with a 3-second timeout. If it's waiting for approval, it will time out and trigger the prompt on device.
        SU_TEST=$(timeout 3 adb -s "$serial" shell "$HAS_SU -c 'id'" 2>/dev/null | tr -d '\r')
        if [[ "$SU_TEST" == *"uid=0"* ]]; then
            echo -e "  - ${formatted_idx}. ${serial}: ${GREEN}Root shell authorization OK${NC}"
        else
            echo -e "  - ${formatted_idx}. ${serial}: ${YELLOW}Root shell authorization failed / Requesting popup...${NC}"
            FAILED_DEVICES+=("$serial")
        fi
        ((IDX++))
    done
    
    # Check if there are failures
    if [ ${#FAILED_DEVICES[@]} -ne 0 ] || [ ${#NO_SU_DEVICES[@]} -ne 0 ]; then
        echo -e "\n\e[1;31m[⚠️] 일부 디바이스의 Root 권한이 확보되지 않았습니다.\e[0m"
        
        if [ ${#FAILED_DEVICES[@]} -ne 0 ]; then
            echo -e "\n${YELLOW}[!] Magisk/Root 권한 승인이 필요한 디바이스 (${#FAILED_DEVICES[@]}대):${NC}"
            for serial in "${FAILED_DEVICES[@]}"; do
                echo -e "  - ${serial}"
            done
            echo -e "  -> 대상 휴대폰 화면을 켜고 Magisk 팝업 창에서 'Grant(허용)' 버튼을 클릭하거나 기기 상태를 확인해주세요."
        fi
        
        if [ ${#NO_SU_DEVICES[@]} -ne 0 ]; then
            echo -e "\n${YELLOW}[!] 'su' 명령어를 찾을 수 없거나 루팅이 확인되지 않는 디바이스 (${#NO_SU_DEVICES[@]}대):${NC}"
            for serial in "${NO_SU_DEVICES[@]}"; do
                echo -e "  - ${serial}"
            done
            echo -e "  -> 기기가 정상적으로 루팅(Magisk)되어 있는지 확인해주세요."
        fi

        # Filter out problematic devices
        VALID_DEVICES=()
        for serial in $DEVICES; do
            is_bad=false
            for bad_serial in "${FAILED_DEVICES[@]}" "${NO_SU_DEVICES[@]}"; do
                if [ "$serial" = "$bad_serial" ]; then
                    is_bad=true
                    break
                fi
            done
            if [ "$is_bad" = false ]; then
                VALID_DEVICES+=("$serial")
            fi
        done

        confirm_choice=""
        if [ "$AUTO_PROCEED" = true ]; then
            confirm_choice="y"
        else
            prompt_msg="[?] 문제 있는 디바이스를 제외하고 정상 승인된 디바이스(${#VALID_DEVICES[@]}대)만 계속 진행하시겠습니까? (y/N): "
            if [ -c /dev/tty ] && [ -r /dev/tty ]; then
                read -r -p "$prompt_msg" confirm_choice < /dev/tty
            else
                read -r -p "$prompt_msg" confirm_choice
            fi
        fi

        if [[ "$confirm_choice" =~ ^[yY](es)?$ ]]; then
            if [ ${#VALID_DEVICES[@]} -eq 0 ]; then
                echo -e "\e[1;31m[-] 진행 가능한 정상 디바이스가 없습니다.\e[0m"
                exit 1
            fi
            echo -e "\n${YELLOW}[*] 문제 디바이스를 제외하고 총 ${#VALID_DEVICES[@]}대의 디바이스에 대해 초기화를 계속 진행합니다.${NC}\n"
            DEVICES="${VALID_DEVICES[*]}"
        else
            echo -e "\n초기화 작업을 중단합니다. 승인 완료 후 이 스크립트를 다시 구동해주시기 바랍니다."
            exit 1
        fi
    else
        echo -e "${GREEN}[✓] All connected devices passed root check. Proceeding to initialization...${NC}\n"
    fi
fi
# Source global configurations
if [ -f "$BASE_DIR/version.conf" ]; then
    source "$BASE_DIR/version.conf"
else
    TARGET_NMAP_VERSION="6.10.0.16"
fi

# Ensure installation assets are present before initializing devices
INSTALL_DIR="$BASE_DIR/install"
has_nmap_apk=false
if [ -d "$INSTALL_DIR/com.nhn.android.nmap_${TARGET_NMAP_VERSION}" ] && [ -f "$INSTALL_DIR/com.nhn.android.nmap_${TARGET_NMAP_VERSION}/base.apk" ]; then
    has_nmap_apk=true
elif [ -d "$INSTALL_DIR/naver_map_${TARGET_NMAP_VERSION}" ] && [ -f "$INSTALL_DIR/naver_map_${TARGET_NMAP_VERSION}/base.apk" ]; then
    has_nmap_apk=true
elif [ -d "$INSTALL_DIR/naver_map" ] && [ -f "$INSTALL_DIR/naver_map/base.apk" ]; then
    has_nmap_apk=true
fi

if [ "$has_nmap_apk" = false ]; then
    echo -e "${YELLOW}[*] Installation assets missing or incomplete. Triggering download...${NC}"
    if [ -f "$BASE_DIR/update_nmap.sh" ]; then
        bash "$BASE_DIR/update_nmap.sh" --non-interactive
        if [ $? -ne 0 ]; then
            echo -e "\e[1;31m[-] Error: Failed to download installation assets from Google Drive.\e[0m"
            exit 1
        fi
    else
        echo -e "\e[1;31m[-] Error: update_nmap.sh not found.\e[0m"
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
        init_screen_lock "$serial" "$HAS_SU"

        # Apply MITM certificate recovery and reboot
        force_reboot_flag="false"
        if [ "$magisk_reboot_status" -eq 2 ]; then
            force_reboot_flag="true"
        fi
        init_mitm_recovery "$serial" "$HAS_SU" "$force_reboot_flag"

        echo -e "${CYAN}------------------------------------------------------------${NC}\n"
    ) 2>&1 | sed -u "s/^/[${serial}] /" &
        
        # Sleep 3 seconds to stagger parallel installations and prevent USB/ADB server overload
        sleep 3
done

while [ -n "$(jobs -p)" ]; do
    wait $(jobs -p) 2>/dev/null || true
done
echo -e "${GREEN}[✓] Device Initialization Complete.${NC}"
