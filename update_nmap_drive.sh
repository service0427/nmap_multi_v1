#!/usr/bin/env bash
# ============================================================
# Naver Map Auto-Simulation Infrastructure (V2)
# Automated Google Drive Asset Downloader, Inspector & Git Sync
# ============================================================

WORKSPACE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
GREEN="\e[1;32m"
CYAN="\e[1;36m"
YELLOW="\e[1;33m"
RED="\e[1;31m"
NC="\e[0m"

INPUT_ARG="$1"

if [ -z "$INPUT_ARG" ]; then
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}   Naver Map Automated Version Updater (Google Drive)       ${NC}"
    echo -e "${CYAN}============================================================${NC}"
    read -p "[?] Google Drive 공유 링크 또는 파일 ID를 입력하세요: " INPUT_ARG < /dev/tty
fi

if [ -z "$INPUT_ARG" ]; then
    echo -e "${RED}[-] 오류: Google Drive 링크 또는 파일 ID가 입력되지 않았습니다.${NC}"
    exit 1
fi

# 1. Google Drive File ID 추출 (URL 또는 직접 ID 지원)
GDRIVE_FILE_ID=$(echo "$INPUT_ARG" | grep -oP '(?<=/d/|id=)[a-zA-Z0-9_-]+' || echo "$INPUT_ARG")
# 특수문자 및 파라미터 제거
GDRIVE_FILE_ID=$(echo "$GDRIVE_FILE_ID" | cut -d'/' -f1 | cut -d'&' -f1 | cut -d'?' -f1 | tr -d ' \r\n')

if [ -z "$GDRIVE_FILE_ID" ]; then
    echo -e "${RED}[-] 오류: 입력한 링크에서 File ID를 추출하지 못했습니다: $INPUT_ARG${NC}"
    exit 1
fi

echo -e "${CYAN}[*] Google Drive File ID 감지:${NC} ${GREEN}$GDRIVE_FILE_ID${NC}"

# 2. gdown 패키지 확인 및 설치
if ! command -v gdown &> /dev/null && [ ! -f "$HOME/.local/bin/gdown" ]; then
    echo -e "${YELLOW}[*] 'gdown' 패키지가 설치되어 있지 않습니다. 설치를 진행합니다...${NC}"
    export PATH=$PATH:$HOME/.local/bin:/usr/local/bin
    python3 -m pip install --upgrade gdown --break-system-packages 2>/dev/null || \
    python3 -m pip install --upgrade gdown 2>/dev/null || \
    pip3 install --upgrade gdown 2>/dev/null
fi

if command -v gdown &> /dev/null; then
    GDOWN_BIN="gdown"
elif [ -f "$HOME/.local/bin/gdown" ]; then
    GDOWN_BIN="$HOME/.local/bin/gdown"
else
    echo -e "${RED}[-] 'gdown' executable을 찾을 수 없습니다. python3-pip 환경을 확인해주세요.${NC}"
    exit 1
fi

# 3. Google Drive에서 파일 다운로드 (임시 파일)
TMP_ARCHIVE=$(mktemp /tmp/nmap_update_XXXXXX.tar.gz)
echo -e "${CYAN}[*] Google Drive에서 패키지 다운로드 중...${NC}"
"$GDOWN_BIN" "https://drive.google.com/uc?id=$GDRIVE_FILE_ID" -O "$TMP_ARCHIVE"

if [ $? -ne 0 ] || [ ! -s "$TMP_ARCHIVE" ]; then
    echo -e "${RED}[-] 파일 다운로드 실패. Google Drive 링크 및 권한을 확인해주세요.${NC}"
    rm -f "$TMP_ARCHIVE"
    exit 1
fi

echo -e "${GREEN}[✓] 다운로드 완료. 아카이브 검수 및 버전 탐지 중...${NC}"

# 4. 아카이브 검수 및 버전 자동 추출
DETECTED_VERSION=""
if tar -tzf "$TMP_ARCHIVE" &>/dev/null; then
    # tar.gz 구조 탐색
    DETECTED_VERSION=$(tar -tf "$TMP_ARCHIVE" | grep -oP '(?:naver_map_|com\.nhn\.android\.nmap_)\K[0-9.]+' | head -n 1 | sed 's/\/$//')
fi

if [ -z "$DETECTED_VERSION" ]; then
    echo -e "${YELLOW}[!] 아카이브 내부에서 버전 정보를 자동으로 감지하지 못했습니다.${NC}"
    read -p "[?] 네이버 지도 버전 번호를 수동 입력하세요 (예: 6.8.1.1): " DETECTED_VERSION < /dev/tty
fi

if [[ ! "$DETECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}[-] 오류: 올바르지 않은 버전 포맷입니다 ($DETECTED_VERSION). 4자리 버전 형식(예: 6.8.1.1)이어야 합니다.${NC}"
    rm -f "$TMP_ARCHIVE"
    exit 1
fi

echo -e "${GREEN}[✓] 검수 완료: 네이버 지도 버전 ${CYAN}$DETECTED_VERSION${NC} 감지됨"

# 5. install 디렉토리에 압축 해제 (로컬 에셋 갱신)
TARGET_DIR="$WORKSPACE_DIR/install"
mkdir -p "$TARGET_DIR"
echo -e "${CYAN}[*] 로컬 install 디렉토리에 에셋 배치 중...${NC}"
tar -xzf "$TMP_ARCHIVE" -C "$TARGET_DIR"
rm -f "$TMP_ARCHIVE"

# 6. version.conf 및 폴백 기본값 업데이트
VERSION_CONF="$WORKSPACE_DIR/version.conf"
if [ -f "$VERSION_CONF" ]; then
    sed -i 's/^TARGET_NMAP_VERSION=.*/TARGET_NMAP_VERSION="'"$DETECTED_VERSION"'"/' "$VERSION_CONF"
    sed -i 's/^GDRIVE_NMAP_ID=.*/GDRIVE_NMAP_ID="'"$GDRIVE_FILE_ID"'"/' "$VERSION_CONF"
    echo -e "${GREEN}[✓] version.conf 갱신 완료:${NC} TARGET_NMAP_VERSION=$DETECTED_VERSION, GDRIVE_NMAP_ID=$GDRIVE_FILE_ID"
fi

# 폴백 코드 갱신
for script_file in "$WORKSPACE_DIR/device_init.sh" "$WORKSPACE_DIR/update_nmap.sh" "$WORKSPACE_DIR/cmd/check_nmap_version.sh"; do
    if [ -f "$script_file" ]; then
        sed -i 's/TARGET_NMAP_VERSION="[0-9.]*"/TARGET_NMAP_VERSION="'"$DETECTED_VERSION"'"/g' "$script_file"
        sed -i 's/TARGET_VER="[0-9.]*"/TARGET_VER="'"$DETECTED_VERSION"'"/g' "$script_file"
        sed -i 's/GDRIVE_NMAP_ID="[a-zA-Z0-9_-]*"/GDRIVE_NMAP_ID="'"$GDRIVE_FILE_ID"'"/g' "$script_file"
    fi
done

# 7. Git Push 인증 체크 및 자동 푸시
echo -e "${CYAN}[*] Git 푸시 권한 확인 중...${NC}"

# Dry-run 또는 remote 연결 체크
git ls-remote origin &>/dev/null
CAN_PUSH=$?

NEED_PROMPT=false
if [ $CAN_PUSH -ne 0 ]; then
    NEED_PROMPT=true
fi

if [ "$NEED_PROMPT" = true ]; then
    echo -e "${YELLOW}[⚠️] 경고: 현재 서버에서 Git Remote 인증 키 확인이 필요합니다.${NC}"
    read -p "[?] GitHub에 새 버전($DETECTED_VERSION) 설정 푸시를 진행하시겠습니까? (y/N): " PUSH_CONFIRM < /dev/tty
    if [[ ! "$PUSH_CONFIRM" =~ ^[yY](es)?$ ]]; then
        echo -e "${YELLOW}[*] 사용자가 Git Push를 취소했습니다. 로컬 설정만 변경되었습니다.${NC}"
        exit 0
    fi
fi

echo -e "${CYAN}[*] GitHub에 새 버전 설정 Commit & Push 진행 중...${NC}"
git add version.conf device_init.sh update_nmap.sh cmd/check_nmap_version.sh
git commit -m "Update: Upgrade Naver Map target version to $DETECTED_VERSION (GDrive ID: $GDRIVE_FILE_ID)"
git push origin main

if [ $? -eq 0 ]; then
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${GREEN}🚀 성공: 네이버 지도 v$DETECTED_VERSION 업데이트 & Git Push가 완료되었습니다!${NC}"
    echo -e "${GREEN}============================================================${NC}"
else
    echo -e "${RED}[-] Git Push 실패. 네트워크 및 SSH/GitHub 인증 권한을 확인해주세요.${NC}"
fi
