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

# 네이버 지도 설치 함수 (파일 스테이징 + pm install-create/write/commit + 컴파일 가속, 최대 300초)
install_nmap_with_watchdog() {
    local target_serial="$1"
    local apks="$2"
    local has_su="$3"
    local max_timeout=300
    local start_ts=$(date +%s)

    echo "[$(date '+%H:%M:%S')] [$target_serial] [1/3] 패키지 검증/Play Protect 비활성화 및 CPU 전 코어/고성능 모드 해제..."
    timeout 10 adb -s "$target_serial" shell "
        settings put global package_verifier_enable 0 2>/dev/null
        settings put global verifier_verify_adb_installs 0 2>/dev/null
        settings put global package_verifier_user_consent -1 2>/dev/null
        pm disable-user --user 0 com.android.vending >/dev/null 2>&1
        cmd power set-mode 0 2>/dev/null
        settings put global low_power 0 2>/dev/null
        $has_su -c '
            for c in 1 2 3 4 5 6 7 8 9; do
                [ -f \"/sys/devices/system/cpu/cpu\${c}/online\" ] && echo 1 > \"/sys/devices/system/cpu/cpu\${c}/online\" 2>/dev/null
            done
            setprop pm.dexopt.install verify 2>/dev/null
        ' 2>/dev/null
    " >/dev/null 2>&1

    # 1. 기기 내 임시 스테이징 폴더 준비 및 잔여 임시 파일 정리 후 대용량 APK(309MB) 개별 고속 Push
    local remote_tmp="/data/local/tmp/nmap_install_stage"
    timeout 8 adb -s "$target_serial" shell "$has_su -c 'rm -rf /data/local/tmp/*.apk /data/app/vmdl*.tmp $remote_tmp 2>/dev/null'" >/dev/null 2>&1
    timeout 5 adb -s "$target_serial" shell "mkdir -p $remote_tmp" >/dev/null 2>&1

    echo "[$(date '+%H:%M:%S')] [$target_serial] [2/3] 대용량 APK 파일 기기 내부로 고속 전송(Push) 중..."
    local push_ok=true
    for apk_path in $apks; do
        local apk_name=$(basename "$apk_path")
        local apk_size_mb=$(du -m "$apk_path" 2>/dev/null | awk '{print $1}')
        local apk_start_ts=$(date +%s)
        echo -n "    -> [$target_serial] 전송 중: $apk_name (${apk_size_mb}MB)... "
        if timeout 180 adb -s "$target_serial" push "$apk_path" "$remote_tmp/$apk_name" >/dev/null 2>&1; then
            echo "완료 ($(( $(date +%s) - apk_start_ts ))초)"
        else
            echo -e "\e[1;31m실패! (재연결 후 1회 재시도...)\e[0m"
            adb -s "$target_serial" reconnect >/dev/null 2>&1 || true
            timeout 10 adb -s "$target_serial" wait-for-device >/dev/null 2>&1 || true
            sleep 2
            if timeout 180 adb -s "$target_serial" push "$apk_path" "$remote_tmp/$apk_name" >/dev/null 2>&1; then
                echo "    -> [$target_serial] 재시도 전송 완료: $apk_name"
            else
                echo -e "\e[1;31m[⚠️] [$target_serial] $apk_name 파일 전송(push) 최종 실패 또는 타임아웃!\e[0m"
                push_ok=false
                break
            fi
        fi
    done

    if [ "$push_ok" = true ]; then
        local push_elapsed=$(( $(date +%s) - start_ts ))
        echo "[$(date '+%H:%M:%S')] [$target_serial] [✓] APK 전송 완료 (${push_elapsed}초 소요). [3/3] 기기 로컬 패키지 설치(pm install-commit) 시작..."

        # 2. 기기 내부에서 로컬 파일 기반 pm install 세션 생성/기록/커밋 (스트리밍 병목 제거)
        local session_id
        session_id=$(timeout 15 adb -s "$target_serial" shell "pm install-create -r -d -g" 2>/dev/null | grep -oE '[0-9]+' | tail -n 1 | tr -d '\r\n')
        if [ -n "$session_id" ]; then
            local write_ok=true
            local idx=0
            for apk_path in $apks; do
                local apk_name=$(basename "$apk_path")
                local apk_bytes=$(stat -c%s "$apk_path" 2>/dev/null || wc -c < "$apk_path")
                if ! timeout 60 adb -s "$target_serial" shell "pm install-write -S $apk_bytes $session_id ${idx}_${apk_name} $remote_tmp/$apk_name" >/dev/null 2>&1; then
                    write_ok=false
                    break
                fi
                idx=$((idx + 1))
            done

            if [ "$write_ok" = true ]; then
                # 이미 새 APK가 모두 세션에 적재되었으므로, 서명/버전 충돌 방지를 위해 구버전이 다른 서명일 경우를 대비해 commit 시도 후 실패 시에만 제거 후 재시도
                local commit_out
                commit_out=$(timeout 180 adb -s "$target_serial" shell "pm install-commit $session_id" 2>&1 | tr -d '\r')
                if [[ "$commit_out" == *"Success"* ]]; then
                    timeout 5 adb -s "$target_serial" shell "rm -rf $remote_tmp" >/dev/null 2>&1
                    local total_elapsed=$(( $(date +%s) - start_ts ))
                    echo "[$(date '+%H:%M:%S')] [$target_serial] [✓] 로컬 스테이징 설치 정상 완료 (총 ${total_elapsed}초 소요)."
                    return 0
                else
                    echo "    -> [$target_serial] 덮어쓰기 커밋 응답($commit_out). 구버전 앱 제거 후 클린 세션 커밋 재시도..."
                    timeout 15 adb -s "$target_serial" uninstall com.nhn.android.nmap >/dev/null 2>&1
                    session_id=$(timeout 15 adb -s "$target_serial" shell "pm install-create -r -d -g" 2>/dev/null | grep -oE '[0-9]+' | tail -n 1 | tr -d '\r\n')
                    if [ -n "$session_id" ]; then
                        idx=0
                        for apk_path in $apks; do
                            local apk_name=$(basename "$apk_path")
                            local apk_bytes=$(stat -c%s "$apk_path" 2>/dev/null || wc -c < "$apk_path")
                            timeout 60 adb -s "$target_serial" shell "pm install-write -S $apk_bytes $session_id ${idx}_${apk_name} $remote_tmp/$apk_name" >/dev/null 2>&1
                            idx=$((idx + 1))
                        done
                        commit_out=$(timeout 180 adb -s "$target_serial" shell "pm install-commit $session_id" 2>&1 | tr -d '\r')
                        if [[ "$commit_out" == *"Success"* ]]; then
                            timeout 5 adb -s "$target_serial" shell "rm -rf $remote_tmp" >/dev/null 2>&1
                            local total_elapsed=$(( $(date +%s) - start_ts ))
                            echo "[$(date '+%H:%M:%S')] [$target_serial] [✓] 클린 세션 설치 정상 완료 (총 ${total_elapsed}초 소요)."
                            return 0
                        fi
                    fi
                fi
            else
                timeout 5 adb -s "$target_serial" shell "pm install-abandon $session_id" >/dev/null 2>&1
            fi
        fi
    fi

    timeout 5 adb -s "$target_serial" shell "rm -rf $remote_tmp" >/dev/null 2>&1

    # 3. Fallback: install-multiple --no-streaming (최대 240초 대기)
    echo "[$(date '+%H:%M:%S')] [$target_serial] [Fallback] install-multiple --no-streaming 방식으로 재시도 (최대 240초)..."
    if timeout 240 adb -s "$target_serial" install-multiple --no-streaming -r -d -g $apks >/dev/null 2>&1 || \
       timeout 240 adb -s "$target_serial" install-multiple -r -d -g $apks >/dev/null 2>&1; then
        local total_elapsed=$(( $(date +%s) - start_ts ))
        echo "[$(date '+%H:%M:%S')] [$target_serial] [✓] Fallback 설치 완료 (총 ${total_elapsed}초 소요)."
        return 0
    fi

    # 4. 최종 확인
    local final_ver
    final_ver=$(timeout 5 adb -s "$target_serial" shell "dumpsys package com.nhn.android.nmap 2>/dev/null | grep versionName | head -n 1 | cut -d= -f2" 2>/dev/null | tr -d '\r\n ')
    if [ -n "$final_ver" ] && { [ -z "$TARGET_NMAP_VERSION" ] || [ "$final_ver" = "$TARGET_NMAP_VERSION" ]; }; then
        echo "[$(date '+%H:%M:%S')] [$target_serial] [✓] 최종 패키지 버전($final_ver) 설치 확인 완료."
        return 0
    fi

    echo -e "\e[1;31m[⚠️] [$target_serial] APK 설치 실패 또는 타임아웃 발생.\e[0m"
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
    
    # 0. 디바이스 활성 상태 점검 (offline 상태면 1회 자동 reconnect 시도)
    dev_state=$(timeout 4 adb -s "$serial" get-state 2>/dev/null | tr -d '\r\n')
    if [ "$dev_state" != "device" ]; then
        echo "[*] [$serial] 현재 상태(${dev_state:-disconnected}) -> ADB 재연결(reconnect) 시도 중..."
        adb -s "$serial" reconnect >/dev/null 2>&1 || true
        timeout 12 adb -s "$serial" wait-for-device >/dev/null 2>&1 || true
        sleep 2
        dev_state=$(timeout 4 adb -s "$serial" get-state 2>/dev/null | tr -d '\r\n')
    fi
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

    # 2. 패치 중 스케줄러(loop.sh / main.sh) 간섭 차단 락 설정 및 진행 중 프로세스 정리
    PATCH_LOCK_DIR="$PROJECT_ROOT/wifi_multi/logs/devices/${serial}/tmp"
    mkdir -p "$PATCH_LOCK_DIR" 2>/dev/null
    touch "$PATCH_LOCK_DIR/patching_nmap" 2>/dev/null
    pkill -9 -f "main.sh $serial" 2>/dev/null || true
    pkill -9 -f "monitor.sh $serial" 2>/dev/null || true
    pkill -9 -f "auto_reloader.py .* $serial" 2>/dev/null || true
    timeout 5 adb -s "$serial" shell "am force-stop com.nhn.android.nmap" >/dev/null 2>&1

    # 3. 설치 전 연결 상태 재확인
    if [ "$(timeout 3 adb -s "$serial" get-state 2>/dev/null | tr -d '\r\n')" != "device" ]; then
        echo -e "\e[1;31m[⚠️] [$serial] 디바이스 연결 끊김 감지! 다음 기기로 건너뜁니다.\e[0m"
        rm -f "$PATCH_LOCK_DIR/patching_nmap" 2>/dev/null
        continue
    fi

    # 4. 신규 앱 설치 (로컬 스테이징 + verify 필터 가속, 구버전 선제 삭제 방지로 Missing 상태 예방)
    if ! install_nmap_with_watchdog "$serial" "$NMAP_APKS" "$HAS_SU"; then
        echo -e "\e[1;31m[⚠️] [$serial] 설치 실패로 인해 다음 기기로 건너뜁니다.\e[0m"
        rm -f "$PATCH_LOCK_DIR/patching_nmap" 2>/dev/null
        continue
    fi

    # 5. 환경 설정 및 WebView/캐시 잔재 소거 (타임아웃 5초)
    timeout 5 adb -s "$serial" shell "$HAS_SU -c 'rm -rf /data/data/com.nhn.android.nmap/shared_prefs/com.nhn.android.nmap_preferences.xml /data/data/com.nhn.android.nmap/app_webview/* /data/data/com.nhn.android.nmap/cache/* /data/data/com.nhn.android.nmap/code_cache/* 2>/dev/null'" >/dev/null 2>&1

    # 6. 모듈을 통한 초기화 및 볼륨/권한 설정 재이식 (타임아웃 60초)
    echo "[$(date '+%H:%M:%S')] [$serial] 네이버 지도 권한 및 볼륨 0 뮤트 설정 재이식 중..."
    if ! timeout 60 bash -c "source \"$SETUP_MODULE\" && init_naver_map \"$serial\" \"$HAS_SU\""; then
        echo -e "\e[1;31m[⚠️] [$serial] 네이버 지도 초기화 도중 오류 또는 타임아웃 발생. 다음 기기로 진행합니다.\e[0m"
        rm -f "$PATCH_LOCK_DIR/patching_nmap" 2>/dev/null
        continue
    fi

    rm -f "$PATCH_LOCK_DIR/patching_nmap" 2>/dev/null
    echo -e "\e[1;32m[$(date '+%H:%M:%S')] [$serial] [✓] 네이버 지도 강제 패치 및 설정 이식 완료!\e[0m"
    echo "=================================================="
done
