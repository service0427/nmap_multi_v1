#!/usr/bin/env bash
# /home/tech/nmap_multi_v1/cmd/patch_naver_map.sh
# 네이버 지도 앱 강제 패치 및 재설정 런너 스크립트

CMD_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(cd "$CMD_DIR/.." && pwd)"
INSTALL_DIR="$PROJECT_ROOT/install"

TARGET_DEVICE=$1

# 연결된 디바이스 감시
if [ -z "$TARGET_DEVICE" ]; then
    echo "[*] 대상 기기가 지정되지 않았습니다. 연결된 전체 기기를 대상으로 패치를 시작합니다."
    DEVICES=$(adb devices | grep -w "device" | awk '{print $1}')
else
    dev_count=$(echo "$TARGET_DEVICE" | wc -w)
    if [ "$dev_count" -gt 1 ]; then
        echo "[*] 지정된 ${dev_count}대 기기 패치를 시작합니다."
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
    
    # su 권한 획득
    HAS_SU=$(adb -s "$serial" shell "which su" 2>/dev/null | tr -d '\r')
    if [ -z "$HAS_SU" ]; then
        HAS_SU=$(adb -s "$serial" shell "ls /system/bin/su /system/xbin/su /sbin/su 2>/dev/null" | head -1 | tr -d '\r')
    fi
    if [ -z "$HAS_SU" ]; then
        echo "[$(date '+%H:%M:%S')] [$serial] [!] su 권한을 찾을 수 없습니다. 루팅 환경이 아닌 기기는 패치하지 않습니다."
        continue
    fi

    # 1. 기존 앱 제거
    echo "[$(date '+%H:%M:%S')] [$serial] 기존 Naver Map 앱 제거 중..."
    adb -s "$serial" uninstall com.nhn.android.nmap >/dev/null 2>&1

    # 2. 신규 앱 설치
    echo "[$(date '+%H:%M:%S')] [$serial] 신규 Naver Map APK 파일들을 기기로 전송(Push) 중..."
    echo "[$(date '+%H:%M:%S')] [$serial] 기기 내부에서 최적화 및 설치 실행 중 (약 10~15초 소요)..."
    adb -s "$serial" install-multiple -r -d -g $NMAP_APKS >/dev/null 2>&1

    # 3. 환경 설정 잔재 소거
    adb -s "$serial" shell "$HAS_SU -c 'rm -f /data/data/com.nhn.android.nmap/shared_prefs/com.nhn.android.nmap_preferences.xml'" >/dev/null 2>&1

    # 4. 모듈을 통한 초기화 및 볼륨/권한 설정 재이식
    echo "[$(date '+%H:%M:%S')] [$serial] 네이버 지도 권한 및 볼륨 0 뮤트 설정 재이식 중..."
    init_naver_map "$serial" "$HAS_SU"
    
    echo "[$(date '+%H:%M:%S')] [$serial] [✓] 네이버 지도 강제 패치 및 설정 이식 완료!"
    echo "=================================================="
done
