#!/bin/bash
# test_nmap_v2/lib/main.sh: Unified Task Execution Engine (V4.1 - Real IP Verification)
export PATH="$HOME/.local/bin:$PATH"

# --- [ADB TIMEOUT WRAPPER] ---
# ADB 서버 데드락 및 좀비 프로세스 방지를 위해 모든 adb 명령에 10초 타임아웃 적용
# 'command'는 쉘 내장 명령어라 timeout이 실행할 수 없으므로 실제 경로(/usr/bin/adb)를 사용합니다.
adb() {
    timeout 10 /usr/bin/adb "$@"
}
export -f adb

LIB_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$LIB_DIR/.." && pwd )"; cd "$ROOT_DIR" || exit 1

DEV_ID=$1
if [ -z "$DEV_ID" ]; then exit 1; fi

DEV_TMP_DIR="${ROOT_DIR}/logs/${DEV_ID}/tmp"
LOCK_FILE="${DEV_TMP_DIR}/nmap_lock"
CURRENT_TASK_JSON="${ROOT_DIR}/logs/${DEV_ID}/current_task.json"

RESET_MODE=true; AGREE_MODE=true
PKG_NAME="com.nhn.android.nmap"; GPS_PKG="com.rosteam.gpsemulator"

if [ -z "$NMAP_LOG_ID" ] || [ -z "$NMAP_DEST_ID" ]; then exit 1; fi
NMAP_MITM_PORT=$((NMAP_FRIDA_PORT + 10000))

# Export Constants
export NMAP_LOG_ID NMAP_DEST_ID CAPTURE_LOG_DIR
export NMAP_DEST_NAME NMAP_DEST_ADDR
export NMAP_MIN_ARRIVAL NMAP_MAX_ARRIVAL
export NMAP_ID_SSAID NMAP_ID_ADID NMAP_ID_NI NMAP_ID_IDFV NMAP_ID_TOKEN

# 1. Setup Logs
DATE_STR=$(date +%Y%m%d); TIME_STR=$(date +%H%M%S)
LOG_REL_PATH="logs/${DEV_ID}/${DATE_STR}/${TIME_STR}_${NMAP_DEST_ID}"
mkdir -p "$LOG_REL_PATH"
export CAPTURE_LOG_DIR="$(cd "$LOG_REL_PATH" && pwd)"

# Define cleanup function early to ensure it can be called safely anytime
cleanup() {
    echo -e "\n[$DEV_ID] Cleaning up session..."
    kill -9 $MITM_PID $FRIDA_PID $MONITOR_PID $RELOAD_PID $HEARTBEAT_PID 2>/dev/null
    adb -s "$DEV_ID" shell am force-stop $PKG_NAME
    local su_path=$(adb -s "$DEV_ID" shell "which su" 2>/dev/null | tr -d '\r')
    if [ -z "$su_path" ]; then
        su_path=$(adb -s "$DEV_ID" shell "ls /system/bin/su /system/xbin/su /sbin/su 2>/dev/null" | head -1 | tr -d '\r')
    fi
    [ -z "$su_path" ] && su_path="su"
    adb -s "$DEV_ID" shell "$su_path -c 'am stopservice $GPS_PKG/.servicex2484'" 2>/dev/null
    local cur_proxy=$(adb -s "$DEV_ID" shell settings get global http_proxy 2>/dev/null | tr -d '\r\n')
    if [[ "$cur_proxy" == *":"$NMAP_MITM_PORT ]]; then
        adb -s "$DEV_ID" shell settings put global http_proxy :0 2>/dev/null
    fi
    adb -s "$DEV_ID" reverse --remove tcp:"$NMAP_FRIDA_PORT" 2>/dev/null
    adb -s "$DEV_ID" reverse --remove tcp:"$NMAP_MITM_PORT" 2>/dev/null
    adb -s "$DEV_ID" forward --remove tcp:"$NMAP_FRIDA_PORT" 2>/dev/null
    rm -f "$LOCK_FILE"
    rm -f "$CURRENT_TASK_JSON"
    echo "[$DEV_ID] Session terminated safely."
    exit 0
}
trap cleanup INT TERM

# Save Original API Response
if [ -n "$NMAP_API_RESPONSE" ]; then
    echo "$NMAP_API_RESPONSE" | jq '.' > "$CAPTURE_LOG_DIR/api_response.json" 2>/dev/null
fi

EXEC_LOG="$CAPTURE_LOG_DIR/execution.log"
exec > >(tee -a "$EXEC_LOG") 2>&1

echo "============================================================"
echo " [$DEV_ID] TASK STARTED (LogID: $NMAP_LOG_ID)"
echo " Destination: $NMAP_DEST_NAME (ID: $NMAP_DEST_ID)"
echo " FRIDA:$NMAP_FRIDA_PORT | MITM:$NMAP_MITM_PORT"
echo "------------------------------------------------------------"

# 1.5 IP Change & REAL IP Verification
if [ "$NMAP_NO_IP" != "true" ]; then
    # echo "[$DEV_ID] Skipping Airplane Mode toggle (LTE WiFi mode)..."
    # adb -s "$DEV_ID" shell su -c "cmd connectivity airplane-mode enable"
    # sleep 3
    # adb -s "$DEV_ID" shell su -c "cmd connectivity airplane-mode disable"
    # echo -n "    > Waiting for stable network connection..."
    
    REAL_IP="Unknown"
    CONNECTED=false
    # 최대 30초 대기 (기존 15초에서 증설)
    for i in {1..30}; do
        # 1. 먼저 핑으로 기본 연결 확인
        if adb -s "$DEV_ID" shell "ping -c 1 -W 1 8.8.8.8" >/dev/null 2>&1; then
            # 2. 실제 HTTP 요청이 성공하는지 확인 (static curl DNS & SSL CA 우회 지원)
            resolved_ip=$(adb -s "$DEV_ID" shell "ping -c 1 -W 2 ifconfig.me | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'" | tr -d '\r\n')
            if [ -n "$resolved_ip" ]; then
                REAL_IP=$(adb -s "$DEV_ID" shell "[ -x /data/local/tmp/curl ] && /data/local/tmp/curl -4 -s --connect-timeout 3 --resolve ifconfig.me:80:$resolved_ip http://ifconfig.me || curl -4 -s --connect-timeout 3 --resolve ifconfig.me:80:$resolved_ip http://ifconfig.me" | tr -d '\r\n')
                if [ -n "$REAL_IP" ] && [[ "$REAL_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    echo " [✓] Connected! Real IPv4: $REAL_IP"
                    CONNECTED=true
                    break
                fi
            fi
        fi
        echo -n "."
        sleep 1
    done
    
    if [ "$CONNECTED" = false ]; then
        echo " [🚨] Network verification FAILED. Terminating session."
        curl -s -X POST "http://${API_SERVER:-localhost:5003}/api/v1/update_status" \
             -H "Content-Type: application/json" \
             -d "{\"task_id\": $NMAP_LOG_ID, \"status\": \"FAIL_NETWORK_TIMEOUT\", \"device_id\": \"$DEV_ID\"}" > /dev/null
        exit 1
    fi

    # Update Status to Server with Real IP
    curl -s -X POST "http://${API_SERVER:-localhost:5003}/api/v1/update_status" \
         -H "Content-Type: application/json" \
         -d "{\"task_id\": $NMAP_LOG_ID, \"status\": \"IP_CHANGED\", \"device_id\": \"$DEV_ID\", \"real_ip\": \"$REAL_IP\"}" > /dev/null
    export NMAP_REAL_IP="$REAL_IP"
    # 연결 직후 앱이 실행되면 시스템 팝업(Wi-Fi 확인 등)과 충돌할 수 있으므로 추가 안정화 시간 부여
    sleep 2
fi

# 1.6 Initialize Session Summary
echo "{\"log_id\": $NMAP_LOG_ID, \"device_id\": \"$DEV_ID\", \"real_ip\": \"$NMAP_REAL_IP\", \"task_start_time\": \"$(date +%Y-%m-%dT%H:%M:%S)\", \"status\": \"STARTED\"}" > "$CAPTURE_LOG_DIR/session_summary.json"

# [NEW] Create Live Task Badge for Web Monitor
CURRENT_TASK_JSON="${ROOT_DIR}/logs/${DEV_ID}/current_task.json"
jq -n \
  --arg lid "$NMAP_LOG_ID" \
  --arg dname "$NMAP_DEST_NAME" \
  --arg tmin "$NMAP_MIN_ARRIVAL" \
  --arg tmax "$NMAP_MAX_ARRIVAL" \
  --arg sts "$(date +%s)" \
  --arg siso "$(date -Iseconds)" \
  --arg ip "$NMAP_REAL_IP" \
  --arg path "$LOG_REL_PATH" \
  --arg fport "$NMAP_FRIDA_PORT" \
  --arg mport "$NMAP_MITM_PORT" \
  '{log_id: $lid, dest_name: $dname, target_range: ($tmin + "~" + $tmax), start_ts: ($sts|tonumber), start_iso: $siso, real_ip: $ip, session_path: $path, ports: {frida: $fport, mitm: $mport}}' \
  > "$CURRENT_TASK_JSON" 2>/dev/null

# 2. Cleanup, Screen Wakeup & IME Setup
echo "[$DEV_ID] Waking up screen, bypassing lockscreen and clearing system popups..."
# 화면 깨우기 및 잠금 해제 (Dismiss Keyguard / Swipe)
adb -s "$DEV_ID" shell input keyevent 224
adb -s "$DEV_ID" shell wm dismiss-keyguard >/dev/null 2>&1
adb -s "$DEV_ID" shell input swipe 500 1500 500 200 300
sleep 0.5
adb -s "$DEV_ID" shell input keyevent 4
adb -s "$DEV_ID" shell input keyevent 3

adb -s "$DEV_ID" shell am force-stop $PKG_NAME
adb -s "$DEV_ID" shell am force-stop $GPS_PKG
adb -s "$DEV_ID" shell settings put global http_proxy :0 2>/dev/null
pkill -9 -f "mitmdump.*-p[[:space:]]+$NMAP_MITM_PORT" 2>/dev/null

ADB_KB_PKG="com.android.adbkeyboard"
adb -s "$DEV_ID" shell ime enable $ADB_KB_PKG/.AdbIME >/dev/null 2>&1
adb -s "$DEV_ID" shell ime set $ADB_KB_PKG/.AdbIME >/dev/null 2>&1

# 3. Golden Template Injection
if [ "$RESET_MODE" = true ]; then
    APP_UID=$(adb -s "$DEV_ID" shell "pm list packages -U $PKG_NAME" | grep -oE "uid:[0-9]+" | cut -d: -f2 | head -n 1)
    [ -z "$APP_UID" ] && APP_UID="root"
    chmod +x lib/inject_template.sh
    ./lib/inject_template.sh "$DEV_ID" "$PKG_NAME" "$APP_UID" "$NMAP_ORIG_SSAID"
fi

# 4. Networking & Proxy
echo "[$DEV_ID] Setting up Proxy Tunnel (MITM:$NMAP_MITM_PORT)..."
fuser -k -n tcp "$NMAP_FRIDA_PORT" >/dev/null 2>&1
fuser -k -n tcp "$NMAP_MITM_PORT" >/dev/null 2>&1
adb -s "$DEV_ID" reverse tcp:"$NMAP_FRIDA_PORT" tcp:"$NMAP_FRIDA_PORT" >/dev/null 2>&1
adb -s "$DEV_ID" reverse tcp:"$NMAP_MITM_PORT" tcp:"$NMAP_MITM_PORT" >/dev/null 2>&1
adb -s "$DEV_ID" shell settings put global http_proxy localhost:"$NMAP_MITM_PORT"

# 5. Workers
nohup mitmdump -p "$NMAP_MITM_PORT" -s mitm/addon.py --ssl-insecure --listen-host 0.0.0.0 --set flow_detail=0 > "$CAPTURE_LOG_DIR/mitm.log" 2>&1 &
MITM_PID=$!
chmod +x macro/monitor.sh
nohup ./macro/monitor.sh "$DEV_ID" "$CAPTURE_LOG_DIR" "$NMAP_DEST_ID" &
MONITOR_PID=$!
setsid python3 gps/auto_reloader.py "$CAPTURE_LOG_DIR" "$DEV_ID" >> "$EXEC_LOG" 2>&1 &
RELOAD_PID=$!

# 6. Launch & Frida
echo "[$DEV_ID] Launching Optimized Session via Frida Attach..."
FRIDA_LOG="$CAPTURE_LOG_DIR/frida.log"
adb -s "$DEV_ID" forward tcp:"$NMAP_FRIDA_PORT" tcp:27042 >/dev/null 2>&1
./gps/static.sh "$DEV_ID" "$NMAP_DEST_LAT" "$NMAP_DEST_LNG"

# Start the application first
adb -s "$DEV_ID" shell monkey -p "$PKG_NAME" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1

# Poll for the PID of the app
PID=""
for i in {1..10}; do
    PID=$(adb -s "$DEV_ID" shell pidof "$PKG_NAME" 2>/dev/null | tr -d '\r\n')
    [ -n "$PID" ] && break
    sleep 1
done

if [ -z "$PID" ]; then
    adb -s "$DEV_ID" shell monkey -p "$PKG_NAME" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
    sleep 3
    PID=$(adb -s "$DEV_ID" shell pidof "$PKG_NAME" 2>/dev/null | tr -d '\r\n')
fi

if [ -z "$PID" ]; then
    cleanup "App failed to launch"
fi

nohup frida -H localhost:"$NMAP_FRIDA_PORT" --runtime=v8 -p "$PID" \
    -l lib/hooks/network_hook.js \
    -l lib/hooks/_core_survival.js \
    --no-auto-reload > "$FRIDA_LOG" 2>&1 &
FRIDA_PID=$!

# 기기별 격리된 tmp 폴더 경로 설정 및 생성 (이미 상단에서 정의됨)
mkdir -p "$DEV_TMP_DIR"

( while true; do touch "$LOCK_FILE"; sleep 10; done ) &
HEARTBEAT_PID=$!

sleep 3

while true; do
    PID=$(adb -s "$DEV_ID" shell pidof "$PKG_NAME" 2>/dev/null)
    [ -z "$PID" ] && echo "[$DEV_ID] App process missing. Terminating..." && cleanup
    CURRENT_FOCUS=$(adb -s "$DEV_ID" shell "dumpsys activity activities | grep -E 'mResumedActivity|mCurrentFocus|topResumedActivity' | grep $PKG_NAME" 2>/dev/null)
    [ -z "$CURRENT_FOCUS" ] && echo "[$DEV_ID] App moved to BACKGROUND. Terminating..." && cleanup
    sleep 5
done
