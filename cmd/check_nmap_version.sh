#!/usr/bin/env bash
# /home/tech/nmap_multi_v1/cmd/check_nmap_version.sh
# 연결된 전체 adb 디바이스의 네이버 지도(com.nhn.android.nmap) 버전 검수 스크립트

CMD_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(cd "$CMD_DIR/.." && pwd)"

# install 디렉토리에서 현재 서버의 타겟 버전을 파악
INSTALL_DIR="$PROJECT_ROOT/install"
TARGET_VER="6.7.3" # Fallback 기본값
NMAP_DIR=$(find "$INSTALL_DIR" -maxdepth 1 -type d -name "com.nhn.android.nmap*" | sort -V -r | head -n 1)
if [ -n "$NMAP_DIR" ]; then
    folder_name=$(basename "$NMAP_DIR")
    if [[ "$folder_name" =~ _([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        TARGET_VER="${BASH_REMATCH[1]}"
    fi
fi

# 연결된 기기 리스팅
DEVICES=$(adb devices | grep -v "List of devices attached" | grep -w "device" | awk '{print $1}')

if [ -z "$DEVICES" ]; then
    echo -e "\e[1;31m[-] 에러: 연결된 adb 디바이스가 없습니다.\e[0m"
    exit 1
fi

GREEN="\e[1;32m"
RED="\e[1;31m"
YELLOW="\e[1;33m"
NC="\e[0m"

echo -e "\n========================================================"
echo -e " 🗺️  Naver Map Version Checker (Server Target: \e[1;36m$TARGET_VER\e[0m)"
echo -e "========================================================"
printf "  %-15s | %-15s | %-12s\n" "Device ID" "Version" "Status"
echo -e "--------------------------------------------------------"

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

# 임시 파일에서 내용 정렬하여 출력
sort "$tmp_file" | while IFS=: read -r serial version status; do
    printf "  %-15s | %-15s | %b\n" "$serial" "$version" "$status"
done

rm -f "$tmp_file"
echo -e "========================================================\n"
