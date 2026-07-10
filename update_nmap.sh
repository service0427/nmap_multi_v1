#!/usr/bin/env bash
# ============================================================
# Naver Map Auto-Simulation Infrastructure (V2)
# Google Drive Asset Downloader & Updater
# ============================================================

WORKSPACE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source global configurations
if [ -f "$WORKSPACE_DIR/version.conf" ]; then
    source "$WORKSPACE_DIR/version.conf"
else
    # Fallbacks in case config is missing
    TARGET_NMAP_VERSION="6.7.3"
    GDRIVE_BASE_ID="1gVkwK5RkuV66cWkElScNttsngmjF7xjy"
    GDRIVE_NMAP_ID="1uXV7Hsys5SqGMVx1SO-GHvMPIQ9SfpCQ"
fi

TARGET_DIR="$WORKSPACE_DIR/install"
BASE_ARCHIVE="$WORKSPACE_DIR/install_base.tar.gz"
NMAP_ARCHIVE="$WORKSPACE_DIR/com.nhn.android.nmap_${TARGET_NMAP_VERSION}.tar.gz"

# Parse arguments for non-interactive flag
interactive=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes|--non-interactive)
            interactive=false
            shift
            ;;
        *)
            shift
            ;;
    esac
done

if [ "$interactive" = true ]; then
    read -p "[?] 정말로 구글 드라이브에서 네이버 지도 및 베이스 의존성 파일을 다운로드/업데이트하시겠습니까? (y/N): " confirm < /dev/tty
    if [[ ! "$confirm" =~ ^[yY](es)?$ ]]; then
        echo -e "\e[1;33m[*] 사용자가 작업을 취소했습니다. 종료합니다.\e[0m"
        exit 0
    fi
fi

# 1. Verification of existing local assets in install directory (Pre-detect local paths)
has_base=false
if [ -d "$TARGET_DIR" ] && [ -f "$TARGET_DIR/ADBKeyboard.apk" ] && [ -d "$TARGET_DIR/gpsemulator" ]; then
    has_base=true
fi

has_nmap=false
# A. Priority 1: Check custom naver_map directory
if [ -d "$TARGET_DIR/naver_map" ] && [ -f "$TARGET_DIR/naver_map/base.apk" ]; then
    has_nmap=true
    echo "[*] 로컬에서 사용자 커스텀 패치 경로를 발견했습니다: install/naver_map"
fi

# B. Priority 2: Check target version directory
target_folder_name="com.nhn.android.nmap_${TARGET_NMAP_VERSION}"
if [ "$has_nmap" = false ] && [ -d "$TARGET_DIR/$target_folder_name" ] && [ -f "$TARGET_DIR/$target_folder_name/base.apk" ]; then
    has_nmap=true
    echo "[*] 로컬에서 ${TARGET_NMAP_VERSION} 목표 버전 경로를 확인했습니다: install/$target_folder_name"
fi

# C. Priority 3: Scan dynamically for other manual versions under com.nhn.android.nmap_*
if [ "$has_nmap" = false ]; then
    highest_local_nmap=$(find "$TARGET_DIR" -maxdepth 1 -type d -name "com.nhn.android.nmap*" 2>/dev/null | sort -V -r | head -n 1)
    if [ -n "$highest_local_nmap" ] && [ -f "$highest_local_nmap/base.apk" ]; then
        has_nmap=true
        echo "[*] 로컬에서 수동 배치된 타겟 버전 경로를 동적 탐지했습니다: install/$(basename "$highest_local_nmap")"
    fi
fi

if [ "$has_base" = true ] && [ "$has_nmap" = true ]; then
    echo -e "\e[1;32m[✓] 베이스 의존성 및 네이버 지도 설치 파일들이 이미 로컬에 존재합니다. 업데이트를 건너뜁니다.\e[0m"
    exit 0
fi

echo "[*] Google Drive에서 최적화 및 설치에 필요한 대용량 파일들을 다운로드합니다..."

# Check and install gdown if not present
if ! command -v gdown &> /dev/null && [ ! -f "$HOME/.local/bin/gdown" ]; then
    echo "[*] 'gdown' 패키지가 설치되어 있지 않습니다. pip를 통해 설치를 진행합니다..."
    export PATH=$PATH:$HOME/.local/bin:/usr/local/bin
    python3 -m pip install --upgrade gdown --break-system-packages 2>/dev/null || \
    python3 -m pip install --upgrade gdown 2>/dev/null || \
    pip3 install --upgrade gdown 2>/dev/null
fi

# Verify installation and resolve executable path
if command -v gdown &> /dev/null; then
    GDOWN_BIN="gdown"
elif [ -f "$HOME/.local/bin/gdown" ]; then
    GDOWN_BIN="$HOME/.local/bin/gdown"
else
    echo "[-] 'gdown' 설치에 실패했습니다. python3-pip 환경을 확인해주세요."
    exit 1
fi

# Check and install tar if not present
if ! command -v tar &> /dev/null; then
    echo "[*] 'tar' 명령어가 설치되어 있지 않습니다. 설치를 시도합니다..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y tar
    else
        echo "[-] 'tar' 설치를 건너뜁니다. 수동으로 설치 여부를 확인해주세요."
    fi
fi

# A. Download and Extract Base Dependencies if missing
if [ "$has_base" = false ]; then
    echo "[*] Google Drive에서 베이스 의존성 다운로드 중 (File ID: $GDRIVE_BASE_ID)..."
    "$GDOWN_BIN" "https://drive.google.com/uc?id=$GDRIVE_BASE_ID" -O "$BASE_ARCHIVE"
    
    if [ $? -eq 0 ] && [ -f "$BASE_ARCHIVE" ]; then
        echo "[✓] 베이스 다운로드 완료. 압축을 해제합니다..."
        mkdir -p "$TARGET_DIR"
        tar -xzf "$BASE_ARCHIVE" -C "$TARGET_DIR"
        rm -f "$BASE_ARCHIVE"
    else
        echo -e "\e[1;31m[-] 베이스 의존성 다운로드 실패. Google Drive 파일 공유 설정을 확인해주세요.\e[0m"
        exit 1
    fi
fi

# B. Download and Extract Naver Map if missing
if [ "$has_nmap" = false ]; then
    echo "[*] Google Drive에서 네이버 지도 APK 다운로드 중 (File ID: $GDRIVE_NMAP_ID)..."
    "$GDOWN_BIN" "https://drive.google.com/uc?id=$GDRIVE_NMAP_ID" -O "$NMAP_ARCHIVE"
    
    if [ $? -eq 0 ] && [ -f "$NMAP_ARCHIVE" ]; then
        echo "[✓] 네이버 지도 다운로드 완료. 압축을 해제합니다..."
        tar -xzf "$NMAP_ARCHIVE" -C "$TARGET_DIR"
        rm -f "$NMAP_ARCHIVE"
    else
        echo -e "\e[1;31m[-] 네이버 지도 다운로드 실패. Google Drive 파일 공유 설정을 확인해주세요.\e[0m"
        exit 1
    fi
fi

echo -e "\e[1;32m[✓] 다운로드 및 파일 갱신 작업이 성공적으로 완료되었습니다.\e[0m"
