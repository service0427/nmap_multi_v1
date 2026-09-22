#!/usr/bin/env bash
# /home/tech/nmap_multi_v1/cmd/check_nmap_version.sh
# 연결된 전체 adb 디바이스의 네이버 지도(com.nhn.android.nmap) 버전 검수 스크립트

CMD_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(cd "$CMD_DIR/.." && pwd)"

# Source global configurations
if [ -f "$PROJECT_ROOT/version.conf" ]; then
    source "$PROJECT_ROOT/version.conf"
    TARGET_VER="$TARGET_NMAP_VERSION"
else
    # Fallback to dynamic local check if version.conf is missing
    INSTALL_DIR="$PROJECT_ROOT/install"
    TARGET_VER="6.10.0.16" # Fallback default
    NMAP_DIR=$(find "$INSTALL_DIR" -maxdepth 1 -type d \( -name "com.nhn.android.nmap*" -o -name "naver_map_*" \) | sort -V -r | head -n 1)
    if [ -n "$NMAP_DIR" ]; then
        folder_name=$(basename "$NMAP_DIR")
        if [[ "$folder_name" =~ _([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
            TARGET_VER="${BASH_REMATCH[1]}"
        fi
    fi
fi

AUTO_UPDATE=false
FORCE_UPDATE=false
TARGET_DEVICE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--update|-y|--yes)
            AUTO_UPDATE=true
            shift
            ;;
        -f|--force)
            FORCE_UPDATE=true
            shift
            ;;
        *)
            if [ -z "$TARGET_DEVICE" ]; then
                TARGET_DEVICE="$1"
            fi
            shift
            ;;
    esac
done

# 연결된 기기 리스팅
if [ -n "$TARGET_DEVICE" ]; then
    # 특정 디바이스가 지정된 경우 연결 여부 검증
    if adb devices | grep -w "device" | grep -q -w "$TARGET_DEVICE"; then
        DEVICES="$TARGET_DEVICE"
    else
        echo -e "\e[1;31m[-] 에러: 지정된 디바이스 ${TARGET_DEVICE}가 연결되어 있지 않거나 오프라인입니다.\e[0m"
        exit 1
    fi
else
    # 지정되지 않은 경우 기존대로 전체 연결 기기 획득
    DEVICES=$(adb devices | grep -v "List of devices attached" | grep -w "device" | awk '{print $1}')
fi

if [ -z "$DEVICES" ]; then
    echo -e "\e[1;31m[-] 에러: 연결된 adb 디바이스가 없습니다.\e[0m"
    exit 1
fi

GREEN="\e[1;32m"
RED="\e[1;31m"
YELLOW="\e[1;33m"
NC="\e[0m"

echo -e "\n============================================================"
echo -e " 🗺️  Naver Map Version Checker (Server Target: \e[1;36m$TARGET_VER\e[0m)"
echo -e "============================================================"
printf "  %-3s  %-15s | %-15s | %-12s\n" "No." "Device ID" "Version" "Status"
echo -e "------------------------------------------------------------"

# 병렬 처리를 위한 임시 파일 활용
tmp_file=$(mktemp)
for serial in $DEVICES; do
    (
        # 패키지 버전명 획득
        version=$(adb -s "$serial" shell "dumpsys package com.nhn.android.nmap 2>/dev/null | grep versionName | head -n 1 | cut -d= -f2" | tr -d '\r\n ')
        
        if [ -z "$version" ]; then
            # 설치 안 됨
            printf "%s:Not Installed:${RED}Missing${NC}\n" "$serial" >> "$tmp_file"
        elif [ "$version" = "$TARGET_VER" ]; then
            # 서버 버전과 완전 일치 (최신)
            printf "%s:%s:${GREEN}Latest${NC}\n" "$serial" "$version" >> "$tmp_file"
        else
            # 구버전
            printf "%s:%s:${YELLOW}Outdated${NC}\n" "$serial" "$version" >> "$tmp_file"
        fi
    ) &
done
wait

# 임시 파일에서 내용을 정렬하여 별도 파일에 쓰고 부모 쉘 루프로 파싱하여 변수 보존
sorted_tmp=$(mktemp)
sort "$tmp_file" > "$sorted_tmp"
rm -f "$tmp_file"

needs_update_count=0
needs_update_list=()
idx=1

while IFS=: read -r serial version status; do
    printf "  %02d. %-15s | %-15s | %b\n" "$idx" "$serial" "$version" "$status"
    idx=$((idx + 1))
    if [[ "$status" == *"Missing"* ]] || [[ "$status" == *"Outdated"* ]]; then
        needs_update_count=$((needs_update_count + 1))
        needs_update_list+=("$serial")
    fi
done < "$sorted_tmp"

rm -f "$sorted_tmp"
echo -e "============================================================\n"

if [ $needs_update_count -gt 0 ]; then
    echo -e "${YELLOW}[⚠️] 업데이트 또는 설치가 필요한 기기가 총 ${needs_update_count}대 발견되었습니다.${NC}"
    
    do_update=false
    if [ "$AUTO_UPDATE" = true ]; then
        do_update=true
    else
        prompt_msg="[?] 업데이트 대상 기기(${needs_update_count}대)의 네이버 지도 앱만 지금 즉시 패치/업데이트하시겠습니까? (y/N): "
        if [ -c /dev/tty ] && [ -r /dev/tty ]; then
            read -r -p "$prompt_msg" confirm_choice < /dev/tty
        else
            read -r -p "$prompt_msg" confirm_choice
        fi
        if [[ "$confirm_choice" =~ ^[yY](es)?$ ]]; then
            do_update=true
        fi
    fi

    if [ "$do_update" = true ]; then
        # 목표 버전 설치 파일 존재 여부 사전 확인
        target_asset_exists=false
        for p in "$PROJECT_ROOT/install/naver_map_${TARGET_VER}" "$PROJECT_ROOT/install/com.nhn.android.nmap_${TARGET_VER}"; do
            if [ -d "$p" ] && [ -n "$(find "$p" -maxdepth 1 -name '*.apk' 2>/dev/null)" ]; then
                target_asset_exists=true
                break
            fi
        done
        if [ "$target_asset_exists" = false ]; then
            echo -e "\n${YELLOW}[*] 목표 버전(${TARGET_VER}) 패치 파일이 install/ 폴더에 없습니다.${NC}"
            echo -e "${YELLOW}[*] update_nmap.sh 를 호출하여 최신 파일 다운로드를 먼저 진행합니다...${NC}"
            bash "$PROJECT_ROOT/update_nmap.sh" -y
        fi

        echo -e "\n${CYAN}============================================================${NC}"
        echo -e "${CYAN}🚀 네이버 지도 앱 전용 패치 시작 (대상: ${needs_update_count}대)${NC}"
        echo -e "${CYAN}============================================================${NC}"
        bash "$CMD_DIR/patch_naver_map.sh" "${needs_update_list[*]}"
        
        echo -e "\n${GREEN}[*] 패치 완료 후 버전 재검증 실행 중...${NC}"
        exec bash "$0" $TARGET_DEVICE
    else
        echo -e "${YELLOW}[*] 업데이트를 건너뛰었습니다.${NC}"
        echo -e "    - 네이버 지도 앱만 즉시 패치하려면: ${GREEN}./cmd.sh --nmap -u${NC} 또는 ${GREEN}bash cmd/patch_naver_map.sh${NC}"
    fi
else
    echo -e "${GREEN}[✓] 모든 연결 기기가 최신 버전($TARGET_VER)입니다.${NC}"
    if [ "$FORCE_UPDATE" = true ]; then
        echo -e "\n${CYAN}============================================================${NC}"
        echo -e "${CYAN}🚀 [강제 재패치] 네이버 지도 앱 패치 시작...${NC}"
        echo -e "${CYAN}============================================================${NC}"
        bash "$CMD_DIR/patch_naver_map.sh" $TARGET_DEVICE
        echo -e "\n${GREEN}[✓] 네이버 지도 앱 강제 재패치가 완료되었습니다.${NC}"
    fi
fi
