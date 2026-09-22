#!/usr/bin/env bash
# /home/tech/nmap_multi_v1/cmd/patch_naver_map.sh
# 네이버 지도 앱 강제 패치 및 재설정 런너 스크립트

CMD_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(cd "$CMD_DIR/.." && pwd)"
INSTALL_DIR="$PROJECT_ROOT/install"

TARGET_DEVICE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--serial|-d|--device)
            TARGET_DEVICE="$2"
            shift 2
            ;;
        *)
            if [ -z "$TARGET_DEVICE" ]; then
                TARGET_DEVICE="$1"
            else
                TARGET_DEVICE="$TARGET_DEVICE $1"
            fi
            shift
            ;;
    esac
done

echo -e "\n============================================================"
echo -e " 🚀 Naver Map Patch Runner"
echo -e " 💡 단일 기기 지정 명령어:"
echo -e "    - \e[1;32m./cmd.sh --nmap -u <기기ID>\e[0m"
echo -e "    - \e[1;32mbash cmd/patch_naver_map.sh <기기ID>\e[0m"
echo -e "      (예: ./cmd.sh --nmap -u R3CR70JFFWD)"
echo -e "============================================================"

# 연결된 디바이스 확인
if [ -z "$TARGET_DEVICE" ]; then
    echo "[*] 대상 기기가 지정되지 않았습니다. 연결된 전체 기기를 대상으로 패치를 시작합니다."
    DEVICES=$(adb devices | grep -w "device" | awk '{print $1}')
else
    dev_count=$(echo "$TARGET_DEVICE" | wc -w)
    if [ "$dev_count" -gt 1 ]; then
        echo "[*] 지정된 ${dev_count}대 기기 패치를 시작합니다: $TARGET_DEVICE"
    else
        echo "[*] 단일 기기 패치를 시작합니다: $TARGET_DEVICE"
    fi
    DEVICES=$TARGET_DEVICE
fi

if [ -z "$DEVICES" ]; then
    echo "[-] 에러: 연결된 디바이스가 없습니다."
    exit 1
fi

# Source global configurations
if [ -f "$PROJECT_ROOT/version.conf" ]; then
    source "$PROJECT_ROOT/version.conf"
fi

# 패치 대상 디렉토리 탐색
NMAP_DIR=""
if [ -n "$TARGET_NMAP_VERSION" ] && [ -d "$INSTALL_DIR/naver_map_${TARGET_NMAP_VERSION}" ]; then
    NMAP_DIR="$INSTALL_DIR/naver_map_${TARGET_NMAP_VERSION}"
elif [ -n "$TARGET_NMAP_VERSION" ] && [ -d "$INSTALL_DIR/com.nhn.android.nmap_${TARGET_NMAP_VERSION}" ]; then
    NMAP_DIR="$INSTALL_DIR/com.nhn.android.nmap_${TARGET_NMAP_VERSION}"
elif [ -d "$INSTALL_DIR/naver_map" ]; then
    NMAP_DIR="$INSTALL_DIR/naver_map"
fi

# 목표 버전 폴더가 없을 경우 자동 다운로드/압축 해제 시도
if [ -z "$NMAP_DIR" ] && [ -n "$TARGET_NMAP_VERSION" ]; then
    echo "[*] 로컬 install/ 폴더에 목표 버전(${TARGET_NMAP_VERSION}) 설치 파일이 없습니다."
    
    # 1. 로컬 tar.gz 아카이브 존재 여부 확인
    for arch in "$PROJECT_ROOT/naver_map_${TARGET_NMAP_VERSION}.tar.gz" "$PROJECT_ROOT/com.nhn.android.nmap_${TARGET_NMAP_VERSION}.tar.gz"; do
        if [ -f "$arch" ]; then
            echo "[*] 로컬 아카이브 발견: $(basename "$arch"). 압축 해제 중..."
            mkdir -p "$INSTALL_DIR"
            tar -xzf "$arch" -C "$INSTALL_DIR"
            break
        fi
    done
    
    # 2. 그래도 없으면 update_nmap.sh 자동 실행
    if [ ! -d "$INSTALL_DIR/naver_map_${TARGET_NMAP_VERSION}" ] && [ ! -d "$INSTALL_DIR/com.nhn.android.nmap_${TARGET_NMAP_VERSION}" ]; then
        if [ -f "$PROJECT_ROOT/update_nmap.sh" ]; then
            echo "[*] Google Drive에서 ${TARGET_NMAP_VERSION} 자산 자동 다운로드를 진행합니다..."
            bash "$PROJECT_ROOT/update_nmap.sh" -y
        fi
    fi
    
    # 3. 다운로드/압축 해제 후 재확인
    if [ -d "$INSTALL_DIR/naver_map_${TARGET_NMAP_VERSION}" ]; then
        NMAP_DIR="$INSTALL_DIR/naver_map_${TARGET_NMAP_VERSION}"
    elif [ -d "$INSTALL_DIR/com.nhn.android.nmap_${TARGET_NMAP_VERSION}" ]; then
        NMAP_DIR="$INSTALL_DIR/com.nhn.android.nmap_${TARGET_NMAP_VERSION}"
    fi
fi

if [ -z "$NMAP_DIR" ] || [ ! -d "$NMAP_DIR" ]; then
    echo "[-] 에러: 목표 버전(${TARGET_NMAP_VERSION})의 네이버 지도 패치 폴더를 찾을 수 없습니다."
    echo "    - 구버전으로 잘못 설치되는 것을 방지하기 위해 패치를 중단합니다."
    echo "    - 해결 방법: './update_nmap.sh' 를 실행하여 ${TARGET_NMAP_VERSION} 설치 파일을 먼저 다운로드해주세요."
    exit 1
fi

NMAP_APKS=$(find "$NMAP_DIR" -maxdepth 1 -name "*.apk" | tr '\n' ' ' | xargs)
if [ -z "$NMAP_APKS" ]; then
    echo "[-] 에러: 패치용 폴더에 APK 파일이 없습니다."
    exit 1
fi

echo "[*] 대상 패치 폴더: $(basename "$NMAP_DIR")"

# device_init 의 naver_map_setup 모듈 동적 로드
SETUP_MODULE="$PROJECT_ROOT/device_init/modules/naver_map_setup.sh"
if [ -f "$SETUP_MODULE" ]; then
    source "$SETUP_MODULE"
else
    echo "[-] 에러: naver_map_setup.sh 모듈 파일을 찾을 수 없습니다."
    exit 1
fi

for serial in $DEVICES; do
    echo "=================================================="
    echo "[$(date '+%H:%M:%S')] 🚀 [$serial] 네이버 지도 강제 패치 시작..."
    
    # 0. 디바이스 활성 상태 점검 (연결 끊김/오프라인 사전 방어)
    dev_state=$(timeout 4 adb -s "$serial" get-state 2>/dev/null | tr -d '\r\n')
    if [ "$dev_state" != "device" ]; then
        echo -e "\e[1;31m[⚠️] [$serial] 디바이스가 연결 해제되었거나 오프라인 상태입니다 (상태: ${dev_state:-disconnected}). 다음 기기로 건너뜁니다.\e[0m"
        continue
    fi

    # 1. su 권한 획득 (타임아웃 5초)
    HAS_SU=$(timeout 5 adb -s "$serial" shell "which su" 2>/dev/null | tr -d '\r\n')
    if [ -z "$HAS_SU" ]; then
        HAS_SU=$(timeout 5 adb -s "$serial" shell "ls /system/bin/su /system/xbin/su /sbin/su 2>/dev/null" | head -1 | tr -d '\r\n')
    fi
    if [ -z "$HAS_SU" ]; then
        echo -e "\e[1;33m[!] [$serial] su 권한을 찾을 수 없습니다. 루팅 환경이 아닌 기기는 건너뜁니다.\e[0m"
        continue
    fi

    # 2. 기존 앱 제거 (타임아웃 15초)
    echo "[$(date '+%H:%M:%S')] [$serial] 기존 Naver Map 앱 제거 중..."
    timeout 15 adb -s "$serial" uninstall com.nhn.android.nmap >/dev/null 2>&1

    # 3. 설치 전 연결 상태 재확인
    if [ "$(timeout 3 adb -s "$serial" get-state 2>/dev/null | tr -d '\r\n')" != "device" ]; then
        echo -e "\e[1;31m[⚠️] [$serial] 디바이스 연결 끊김 감지! 다음 기기로 건너뜁니다.\e[0m"
        continue
    fi

    # 4. 신규 앱 설치 (타임아웃 60초)
    echo "[$(date '+%H:%M:%S')] [$serial] 신규 Naver Map APK 파일 전송 및 설치 중 (최대 60초 제한)..."
    if ! timeout 60 adb -s "$serial" install-multiple -r -d -g $NMAP_APKS >/dev/null 2>&1; then
        echo -e "\e[1;31m[⚠️] [$serial] APK 설치 실패 또는 타임아웃 발생 (연결 끊김 또는 전송 오류). 다음 기기로 건너뜁니다.\e[0m"
        continue
    fi

    # 5. 환경 설정 잔재 소거 (타임아웃 5초)
    timeout 5 adb -s "$serial" shell "$HAS_SU -c 'rm -f /data/data/com.nhn.android.nmap/shared_prefs/com.nhn.android.nmap_preferences.xml'" >/dev/null 2>&1

    # 6. 모듈을 통한 초기화 및 볼륨/권한 설정 재이식 (타임아웃 60초)
    echo "[$(date '+%H:%M:%S')] [$serial] 네이버 지도 권한 및 볼륨 0 뮤트 설정 재이식 중..."
    if ! timeout 60 bash -c "source \"$SETUP_MODULE\" && init_naver_map \"$serial\" \"$HAS_SU\""; then
        echo -e "\e[1;31m[⚠️] [$serial] 네이버 지도 초기화 도중 오류 또는 타임아웃 발생. 다음 기기로 진행합니다.\e[0m"
        continue
    fi
    
    echo -e "\e[1;32m[$(date '+%H:%M:%S')] [$serial] [✓] 네이버 지도 강제 패치 및 설정 이식 완료!\e[0m"
    echo "=================================================="
done
