#!/usr/bin/env bash

# ============================================================
# Naver Map Auto-Simulation Infrastructure (V2)
# Google Drive Asset Downloader
# ============================================================

# ⚠️ 구글 드라이브에 업로드한 install.tar.gz 파일의 고유 File ID를 입력해주세요.
GDRIVE_FILE_ID="1_JSzUHkj5FY1W04odxKou1Tc5mVIuuiL"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(dirname "$SCRIPT_DIR")"
TARGET_DIR="$WORKSPACE_DIR/install"
ARCHIVE_PATH="$WORKSPACE_DIR/install.tar.gz"

if [ "$GDRIVE_FILE_ID" = "YOUR_GOOGLE_DRIVE_FILE_ID_HERE" ]; then
    echo -e "\e[1;31m[-] 에러: download_install_assets.sh 내의 GDRIVE_FILE_ID 값을 설정해야 합니다.\e[0m"
    exit 1
fi

# 기존에 수동으로 올렸거나 이미 설치 파일이 구성되어 있는 경우 스킵
if [ -d "$TARGET_DIR" ] && [ -f "$TARGET_DIR/com.nhn.android.nmap_6.6.1/base.apk" ]; then
    echo -e "\e[1;32m[✓] '$TARGET_DIR' 폴더와 필수 설치 파일들이 이미 존재합니다. 다운로드를 건너뜁니다.\e[0m"
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
    elif command -v yum &> /dev/null; then
        sudo yum install -y tar
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y tar
    elif command -v apk &> /dev/null; then
        sudo apk add --no-cache tar
    else
        echo "[-] 자동 설치 도구(apt, yum, dnf, apk)를 찾지 못했습니다. 수동으로 'tar'를 설치해주세요."
        exit 1
    fi
fi

# Download archive from Google Drive
echo "[*] Google Drive에서 파일 다운로드 중 (File ID: $GDRIVE_FILE_ID)..."
"$GDOWN_BIN" "https://drive.google.com/uc?id=$GDRIVE_FILE_ID" -O "$ARCHIVE_PATH"

if [ $? -eq 0 ] && [ -f "$ARCHIVE_PATH" ]; then
    echo "[✓] 다운로드 완료. 기존 install 폴더가 존재할 경우 백업 후 새로 압축을 해제합니다..."
    if [ -d "$TARGET_DIR" ]; then
        mv "$TARGET_DIR" "${TARGET_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
    fi
    
    tar -xzf "$ARCHIVE_PATH" -C "$WORKSPACE_DIR"
    
    # Remove archive after extraction
    rm -f "$ARCHIVE_PATH"
    echo -e "\e[1;32m[✓] 압축 해제 완료. '$TARGET_DIR' 폴더가 성공적으로 복구되었습니다.\e[0m"
else
    echo -e "\e[1;31m[-] 다운로드 실패. 공유 링크 설정이 '링크가 있는 모든 사용자에게 공개' 상태인지 확인해 주세요.\e[0m"
    exit 1
fi
