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

# base.apk가 반드시 첫 번째 인자로 전달되도록 정렬
NMAP_APKS=$(ls -1 "$NMAP_DIR"/base.apk "$NMAP_DIR"/split_*.apk 2>/dev/null | tr '\n' ' ' | xargs)
if [ -z "$NMAP_APKS" ]; then
    NMAP_APKS=$(find "$NMAP_DIR" -maxdepth 1 -name "*.apk" | sort | tr '\n' ' ' | xargs)
fi
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

# 네이버 지도 설치 와치독 함수 (최대 180초, PackageManager 락 경합 방지 및 1회 자동 재시도)
install_nmap_with_watchdog() {
    local target_serial="$1"
    local apks="$2"
    local has_su="$3"
    local max_timeout=180
    local attempt=1

    while [ $attempt -le 2 ]; do
        local elapsed=0
        local install_success=false
        local install_log="/tmp/nmap_install_${target_serial}.log"
        rm -f "$install_log"

        # 설치 전 Play Protect / Package Verifier 비활성화 및 임시 파일 정리 (설치 행/지연 방지)
        timeout 8 adb -s "$target_serial" shell "
            settings put global package_verifier_enable 0
            settings put global verifier_verify_adb_installs 0
            settings put global package_verifier_user_consent -1
            pm disable-user --user 0 com.android.vending 2>/dev/null
            rm -f /data/local/tmp/*.apk 2>/dev/null
        " >/dev/null 2>&1

        echo "[$(date '+%H:%M:%S')] [$target_serial] 신규 Naver Map APK 파일 전송 및 설치 시작 (시도 ${attempt}/2, 최대 ${max_timeout}초 제한)..."

        adb -s "$target_serial" install-multiple -r -d -g $apks >"$install_log" 2>&1 &
        local install_pid=$!

        while [ $elapsed -lt $max_timeout ]; do
            # 1. 프로세스 자연 종료 확인
            if ! kill -0 $install_pid 2>/dev/null; then
                wait $install_pid 2>/dev/null
                local install_ret=$?
                if [ $install_ret -eq 0 ] || grep -q "Success" "$install_log" 2>/dev/null; then
                    install_success=true
                    echo "[$(date '+%H:%M:%S')] [$target_serial] [✓] install-multiple 프로세스 정상 완료 (${elapsed}초 소요)."
                else
                    local check_path
                    check_path=$(timeout 5 adb -s "$target_serial" shell "pm path com.nhn.android.nmap" 2>/dev/null | tr -d '\r\n')
                    if [[ "$check_path" == *"package:"* ]]; then
                        install_success=true
                        echo "[$(date '+%H:%M:%S')] [$target_serial] [✓] 프로세스 종료 후 패키지 설치 확인됨 (${elapsed}초 소요)."
                    else
                        local err_msg
                        err_msg=$(tail -n 3 "$install_log" 2>/dev/null | tr '\r\n' ' ')
                        echo -e "\e[1;33m[!] [$target_serial] install-multiple 반환 코드 ${install_ret} (${elapsed}초): ${err_msg:-출력 없음}\e[0m"
                    fi
                fi
                break
            fi

            # 2. 5초 주기로 디바이스 연결 끊김 감지 (과도한 ADB 폴링으로 인한 USB 대역폭 저하 방지)
            if [ $((elapsed % 5)) -eq 0 ] && [ $elapsed -gt 0 ]; then
                if [ "$(timeout 3 adb -s "$target_serial" get-state 2>/dev/null | tr -d '\r\n')" != "device" ]; then
                    echo -e "\e[1;31m[⚠️] [$target_serial] 설치 도중 디바이스 연결 끊김 감지! (${elapsed}초 경과)\e[0m"
                    kill -9 $install_pid 2>/dev/null
                    wait $install_pid 2>/dev/null
                    rm -f "$install_log"
                    return 1
                fi
            fi

            # 3. 90초 경과 후부터 15초 단위로만 설치 여부 확인 (PackageManager 락 경합 최소화)
            if [ $elapsed -ge 90 ] && [ $((elapsed % 15)) -eq 0 ]; then
                local check_path
                check_path=$(timeout 4 adb -s "$target_serial" shell "pm path com.nhn.android.nmap" 2>/dev/null | tr -d '\r\n')
                if [[ "$check_path" == *"package:"* ]]; then
                    install_success=true
                    echo "[$(date '+%H:%M:%S')] [$target_serial] [✓] 조기 설치 감지 성공! (${elapsed}초 시점 완료)"
                    kill -9 $install_pid 2>/dev/null
                    wait $install_pid 2>/dev/null
                    break
                fi
            fi

            sleep 1
            elapsed=$((elapsed + 1))
        done

        # 타임아웃 시 백그라운드 프로세스 정리
        if kill -0 $install_pid 2>/dev/null; then
            kill -9 $install_pid 2>/dev/null
            wait $install_pid 2>/dev/null
        fi

        # 최종 안전 확인
        if [ "$install_success" != true ]; then
            local final_check
            final_check=$(timeout 5 adb -s "$target_serial" shell "pm path com.nhn.android.nmap" 2>/dev/null | tr -d '\r\n')
            if [[ "$final_check" == *"package:"* ]]; then
                install_success=true
                echo "[$(date '+%H:%M:%S')] [$target_serial] [✓] 최종 시점 패키지 설치 완료 감지."
            fi
        fi

        rm -f "$install_log"

        if [ "$install_success" = true ]; then
            return 0
        fi

        if [ $attempt -eq 1 ]; then
            echo -e "\e[1;33m[*] [$target_serial] 미완료 설치 세션을 정리하고 1회 재시도합니다...\e[0m"
            timeout 8 adb -s "$target_serial" shell "$has_su -c 'rm -rf /data/local/tmp/*.apk /data/app/vmdl*.tmp 2>/dev/null'" >/dev/null 2>&1
            sleep 2
        fi
        attempt=$((attempt + 1))
    done

    echo -e "\e[1;31m[⚠️] [$target_serial] APK 설치 실패 또는 타임아웃(${max_timeout}초) 발생.\e[0m"
    return 1
}

# ADB 래퍼 설치 및 호스트 ADB 키 동기화/각인 보장
if [ -f "$PROJECT_ROOT/utils/recovery_adbkey.sh" ]; then
    bash "$PROJECT_ROOT/utils/recovery_adbkey.sh" >/dev/null 2>&1 || true
fi

# 구버전 MITM 캐시 초기화
if [ -d "$PROJECT_ROOT/wifi_multi/mitm/cache" ]; then
    rm -f "$PROJECT_ROOT/wifi_multi/mitm/cache/"*.json 2>/dev/null || true
    echo "[*] MITM 기기 캐시(wifi_multi/mitm/cache/*.json) 초기화 완료."
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

    # 2. 기존 앱 강제 종료 및 제거 (타임아웃 20초)
    echo "[$(date '+%H:%M:%S')] [$serial] 기존 Naver Map 앱 제거 중..."
    timeout 5 adb -s "$serial" shell "am force-stop com.nhn.android.nmap" >/dev/null 2>&1
    timeout 20 adb -s "$serial" uninstall com.nhn.android.nmap >/dev/null 2>&1

    # 3. 설치 전 연결 상태 재확인
    if [ "$(timeout 3 adb -s "$serial" get-state 2>/dev/null | tr -d '\r\n')" != "device" ]; then
        echo -e "\e[1;31m[⚠️] [$serial] 디바이스 연결 끊김 감지! 다음 기기로 건너뜁니다.\e[0m"
        continue
    fi

    # 4. 신규 앱 설치 (최대 180초 제한, 1회 자동 재시도 포함)
    if ! install_nmap_with_watchdog "$serial" "$NMAP_APKS" "$HAS_SU"; then
        echo -e "\e[1;31m[⚠️] [$serial] 설치 실패로 인해 다음 기기로 건너뜁니다.\e[0m"
        continue
    fi

    # 5. 환경 설정 및 WebView/캐시 잔재 소거 (타임아웃 5초)
    timeout 5 adb -s "$serial" shell "$HAS_SU -c 'rm -rf /data/data/com.nhn.android.nmap/shared_prefs/com.nhn.android.nmap_preferences.xml /data/data/com.nhn.android.nmap/app_webview/* /data/data/com.nhn.android.nmap/cache/* /data/data/com.nhn.android.nmap/code_cache/* 2>/dev/null'" >/dev/null 2>&1

    # 6. 모듈을 통한 초기화 및 볼륨/권한 설정 재이식 (타임아웃 90초)
    echo "[$(date '+%H:%M:%S')] [$serial] 네이버 지도 권한 및 볼륨 0 뮤트 설정 재이식 중..."
    if ! timeout 90 bash -c "source \"$SETUP_MODULE\" && init_naver_map \"$serial\" \"$HAS_SU\""; then
        echo -e "\e[1;31m[⚠️] [$serial] 네이버 지도 초기화 도중 오류 또는 타임아웃 발생. 다음 기기로 진행합니다.\e[0m"
        continue
    fi
    
    echo -e "\e[1;32m[$(date '+%H:%M:%S')] [$serial] [✓] 네이버 지도 강제 패치 및 설정 이식 완료!\e[0m"
    echo "=================================================="
done
