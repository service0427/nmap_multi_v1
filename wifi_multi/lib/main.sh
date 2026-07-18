#!/bin/bash
# Unified Task Execution Engine (Reverted to stable mode_wifi base + PBR)
export PATH="$HOME/.local/bin:$PATH"

# --- [ADB TIMEOUT WRAPPER] ---
adb() { timeout 10 /usr/bin/adb "$@"; }
export -f adb

# Setup Paths
LIB_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ENGINE_ROOT="$(dirname "$LIB_DIR")"
PROJECT_ROOT="$(dirname "$ENGINE_ROOT")"
cd "$ENGINE_ROOT" || exit 1

# --- [전역 설정 로드] ---
if [ -f "config.conf" ]; then
    source "config.conf"
fi

DEV_ID=$1
if [ -z "$DEV_ID" ]; then exit 1; fi

CURRENT_TASK_JSON="logs/${DEV_ID}/current_task.json"
# Do not remove CURRENT_TASK_JSON to preserve the allocation metadata written by loop.sh

# Bypassed per-device binding to route through default route (lowest metric: lte11)
BIND_IFACE=""
BIND_IP="$NMAP_BIND_IP"
CURL_OPT=""

# =================================================================================
# [포트 대역 구조 가이드 - 절대 롤백 금지]
# - NMAP_FRIDA_PORT = 10000 + device_seq (DB 고유 일련번호)
# - NMAP_MITM_PORT  = 20000 + device_seq (NMAP_FRIDA_PORT + 10000)
# - 이 방식은 DB 상 고유값인 device_seq를 사용하므로 다중 서버/다중 기기 스케일아웃 시 충돌 확률이 0%입니다.
# - 절대 임의의 해시(cksum 등) 기반 로컬 포트 할당으로 변경하지 마십시오.
# =================================================================================
NMAP_MITM_PORT=$((NMAP_FRIDA_PORT + 10000))

# --- [ZOMBIE PURGE & UNREPORTED INTERRUPT CLEANUP] ---
# Ensure no task is left hanging in 'Running' state on the API server if it was killed by a new task
if [ -f "$CURRENT_TASK_JSON" ]; then
    PREV_STATUS=$(jq -r '.status // empty' "$CURRENT_TASK_JSON" 2>/dev/null)
    PREV_TASK_ID=$(jq -r '.task_id // empty' "$CURRENT_TASK_JSON" 2>/dev/null)
    if [ -n "$PREV_TASK_ID" ] && [ "$PREV_STATUS" != "SUCCESS" ] && [ "$PREV_STATUS" != "FAIL" ] && [ "$PREV_STATUS" != "API_ERROR" ]; then
        echo "[$DEV_ID] [⚠️] Reporting FAIL for interrupted/zombie task: $PREV_TASK_ID (Previous status: $PREV_STATUS)"
        curl -s -X POST "http://${API_SERVER}/api/v1/report_result" \
             -H "Content-Type: application/json" \
             -d "{\"task_id\": $PREV_TASK_ID, \"status\": \"FAIL\", \"device_id\": \"$DEV_ID\", \"message\": \"INTERRUPTED_BY_NEW_TASK\"}" >/dev/null 2>&1
        
        # Also log to our persistent history
        local history_file="logs/rotator_history/session_history.csv"
        if [ -f "$history_file" ]; then
            # Get subnet index from BIND_IP or BIND_IFACE
            local sub_idx=""
            if [ -n "$BIND_IP" ] && [[ "$BIND_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                sub_idx=$(echo "$BIND_IP" | cut -d. -f3)
            fi
            echo "$(date +'%Y-%m-%d %H:%M:%S'),$DEV_ID,$sub_idx,$PREV_TASK_ID,FAIL,INTERRUPTED_BY_NEW_TASK" >> "$history_file"
        fi
    fi
fi

# Ensure no orphaned processes from previous crashed runs are fighting over this device/port
echo "[$DEV_ID] Purging any lingering zombie processes..."
pkill -9 -f "monitor.sh $DEV_ID"
pkill -9 -f "auto_reloader.py .* $DEV_ID"
pkill -9 -f "mitmdump -p $NMAP_MITM_PORT"
pkill -9 -f "frida -H localhost:$NMAP_FRIDA_PORT"
# Also clean up any lingering adb forwards just in case
adb -s "$DEV_ID" forward --remove tcp:"$NMAP_FRIDA_PORT" 2>/dev/null
adb -s "$DEV_ID" reverse --remove tcp:"$NMAP_MITM_PORT" 2>/dev/null
adb -s "$DEV_ID" shell am force-stop com.nhn.android.nmap 2>/dev/null

DEV_TMP_DIR="logs/${DEV_ID}/tmp"
mkdir -p "$DEV_TMP_DIR"
rm -f "${DEV_TMP_DIR}/guidance_started" 2>/dev/null
LOCK_FILE="${DEV_TMP_DIR}/nmap_lock"

( while true; do touch "$LOCK_FILE"; sleep 10; done ) >/dev/null 2>&1 &
HEARTBEAT_PID=$!

cleanup() {
    local REASON=$1
    echo -e "\n[$DEV_ID] Terminating. Reason: $REASON"
    
    # [NEW] Advanced report.py Audit Engine
    local LEAK_DETECTED=false
    local LEAK_MSG=""
    if [ -d "$CAPTURE_LOG_DIR" ]; then
        python3 "$LIB_DIR/report.py" "$CAPTURE_LOG_DIR" "$DEV_ID" "$NMAP_LOG_ID" "$REASON"
        if [ $? -eq 1 ]; then
            LEAK_DETECTED=true
            LEAK_MSG=$(jq -r '.security_audit.leak_message // empty' "$CAPTURE_LOG_DIR/report.json" 2>/dev/null)
        fi
    fi

    # Check if the task already finished successfully
    local IS_SUCCESS=false
    if grep -q "SUCCESS" "$CURRENT_TASK_JSON" 2>/dev/null; then
        IS_SUCCESS=true
    fi

    # 보안 누설이 1건이라도 감지되면 성공 판정을 강제로 취소하고 무조건 FAIL 처리!
    if [ "$LEAK_DETECTED" = true ]; then
        echo -e "\n[🚨🚨🚨] CRITICAL SECURITY LEAK DETECTED!"
        echo -e "[🚨🚨🚨] $LEAK_MSG"
        echo -e "[🚨🚨🚨] FORCING TASK RESULT TO 'FAIL' TO PROTECT IDENTITY ANONYMITY!\n"
        IS_SUCCESS=false
        REASON="IDENTITY_LEAK_DETECTED ($LEAK_MSG)"
        rm -f "$CURRENT_TASK_JSON" 2>/dev/null
        # report.json 다시 생성해서 실패 원인 업데이트
        python3 "$LIB_DIR/report.py" "$CAPTURE_LOG_DIR" "$DEV_ID" "$NMAP_LOG_ID" "$REASON" > /dev/null 2>&1
    fi

    if [ "$IS_SUCCESS" = false ]; then
        # Report FAIL only if it wasn't a success or got overridden by leak audit
        local REPORT_STATUS="FAIL"
        # ADDRESS_NOT_FOUND 이거나 App Closed 인 경우 어드민 격리 패널티를 피하기 위해 API_ERROR로 우회
        if [ "$REASON" = "ADDRESS_NOT_FOUND" ] || [ "$REASON" = "App Closed" ] || [[ "$REASON" == *"ADDRESS_NOT_FOUND"* ]]; then
            REPORT_STATUS="API_ERROR"
        fi
        curl $CURL_OPT -s -X POST "http://${API_SERVER}/api/v1/report_result" \
             -H "Content-Type: application/json" \
             -d "{\"task_id\": \"$NMAP_LOG_ID\", \"device_id\": \"$DEV_ID\", \"status\": \"$REPORT_STATUS\", \"message\": \"$REASON\"}" > /dev/null
    else
        echo "[$DEV_ID] Task was SUCCESSFUL. Skipping FAIL report."
    fi

    kill -9 $MITM_PID $FRIDA_PID $MONITOR_PID $RELOAD_PID $HEARTBEAT_PID $WATCHDOG_PID 2>/dev/null
    adb -s "$DEV_ID" shell am force-stop com.nhn.android.nmap
    adb -s "$DEV_ID" shell settings put global http_proxy :0 2>/dev/null
    adb -s "$DEV_ID" forward --remove tcp:"$NMAP_FRIDA_PORT" 2>/dev/null
    adb -s "$DEV_ID" reverse --remove tcp:"$NMAP_MITM_PORT" 2>/dev/null
    rm -f "$LOCK_FILE" "$CURRENT_TASK_JSON" "${DEV_TMP_DIR}/guidance_started"
    exit 0
}
trap "cleanup 'SigTerm'" INT TERM

# 1. Setup Logs
DATE_STR=${NMAP_DATE_STR:-$(date +%Y%m%d)}; TIME_STR=${NMAP_TIME_STR:-$(date +%H%M%S)}
export CAPTURE_LOG_DIR="$ENGINE_ROOT/logs/${DEV_ID}/${DATE_STR}/${TIME_STR}_${NMAP_DEST_ID}"
mkdir -p "$CAPTURE_LOG_DIR"
EXEC_LOG="$CAPTURE_LOG_DIR/execution.log"
exec > >(tee -a "$EXEC_LOG") 2>&1

# Save the original API task response for debugging (pretty printed for humans)
echo "$NMAP_API_RESPONSE" | jq . > "$CAPTURE_LOG_DIR/api_response.json"

# Get Environment Snapshot (No bc package requirement)
BATT_LEVEL=$(adb -s "$DEV_ID" shell dumpsys battery | grep level | awk '{print $2}')
# --- [BATTERY SAFETY GATE] ---
if [ -n "$BATT_LEVEL" ] && [ "$BATT_LEVEL" -eq "$BATT_LEVEL" ] 2>/dev/null; then
    if [ "$BATT_LEVEL" -lt 20 ]; then
        echo " [$DEV_ID] [🚨] BATTERY CRITICAL: ${BATT_LEVEL}% (Threshold < 20%). Aborting task to prevent hard shutdown."
        cleanup "BATTERY_LOW_${BATT_LEVEL}%"
    fi
fi

TEMP_RAW=$(adb -s "$DEV_ID" shell dumpsys battery | grep temperature | awk '{print $2}')
if [ -n "$TEMP_RAW" ] && [ "$TEMP_RAW" -eq "$TEMP_RAW" ] 2>/dev/null; then
    TEMP_C="$((TEMP_RAW / 10)).$((TEMP_RAW % 10))"
else
    TEMP_C="N/A"
fi
FREE_RAM=$(adb -s "$DEV_ID" shell cat /proc/meminfo | grep MemFree | awk '{print $2$3}')

echo "============================================================"
echo " [$DEV_ID] TASK STARTED (LogID: $NMAP_LOG_ID)"
echo " Destination: $NMAP_DEST_NAME (ID: $NMAP_DEST_ID)"
echo " FRIDA:$NMAP_FRIDA_PORT | MITM:$NMAP_MITM_PORT | BIND_IP:$BIND_IP"
echo "------------------------------------------------------------"
echo " [$DEV_ID] [📊] Environment Snapshot: Temp=${TEMP_C}°C | Batt=${BATT_LEVEL}% | Free RAM=${FREE_RAM}"

# 2. IP Verification (Robust 30s Wait for IP Toggles)
# Clear any lingering proxy settings from previous failed/killed runs first to ensure curl runs direct
adb -s "$DEV_ID" shell settings put global http_proxy :0 2>/dev/null
echo " [$DEV_ID] [🌐] Verifying External Network..."
IP_READY=false
TO_VAL=${STARTUP_CONNECT_TIMEOUT:-10}
for i in {1..3}; do
    # Try system curl first as it is native and works on modern 64-bit-only CPUs (Z Flip 3, etc.)
    REAL_IP=$(adb -s "$DEV_ID" shell "curl -s --connect-timeout $TO_VAL -4 http://ifconfig.me" 2>/dev/null | tr -d '\r\n' | grep -oE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+")
    if [ -z "$REAL_IP" ]; then
        REAL_IP=$(adb -s "$DEV_ID" shell "curl -s --connect-timeout $TO_VAL -4 http://api.ipify.org" 2>/dev/null | tr -d '\r\n' | grep -oE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+")
    fi
    if [ -z "$REAL_IP" ]; then
        REAL_IP=$(adb -s "$DEV_ID" shell "curl -s --connect-timeout $TO_VAL -4 http://icanhazip.com" 2>/dev/null | tr -d '\r\n' | grep -oE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+")
    fi

    # Fallback to custom curl if system curl is missing or failed
    if [ -z "$REAL_IP" ]; then
        REAL_IP=$(adb -s "$DEV_ID" shell "/data/local/tmp/curl -s --connect-timeout $TO_VAL -4 http://ifconfig.me" 2>/dev/null | tr -d '\r\n' | grep -oE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+")
    fi
    if [ -z "$REAL_IP" ]; then
        REAL_IP=$(adb -s "$DEV_ID" shell "/data/local/tmp/curl -s --connect-timeout $TO_VAL -4 http://api.ipify.org" 2>/dev/null | tr -d '\r\n' | grep -oE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+")
    fi
    
    # Fallback to wget as a final attempt
    if [ -z "$REAL_IP" ]; then
        REAL_IP=$(adb -s "$DEV_ID" shell "wget -qO- --timeout=$TO_VAL http://ifconfig.me" 2>/dev/null | tr -d '\r\n' | grep -oE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+")
    fi

    if [ -n "$REAL_IP" ]; then
        echo " [$DEV_ID] [✓] Real IPv4: $REAL_IP"
        IP_READY=true
        break
    fi
    
    echo " [$DEV_ID] Waiting for IP (Timeout: ${TO_VAL}s)... ($i/3)"
    sleep 3
done

if [ "$IP_READY" = false ]; then
    mkdir -p "logs/${DEV_ID}/tmp"
    touch "logs/${DEV_ID}/tmp/ip_failed_gate"
    cleanup "NETWORK_TIMEOUT"
fi

curl $CURL_OPT -s -X POST "http://${API_SERVER}/api/v1/update_status" \
     -H "Content-Type: application/json" \
     -d "{\"task_id\": \"$NMAP_LOG_ID\", \"status\": \"IP_CHANGED\", \"device_id\": \"$DEV_ID\", \"real_ip\": \"$REAL_IP\"}" > /dev/null

# Save Real IP to current_task.json and session_summary.json for Web Monitor
CURRENT_TASK_JSON="logs/${DEV_ID}/current_task.json"
if [ -f "$CURRENT_TASK_JSON" ]; then
    TMP_JSON=$(mktemp)
    jq --arg ip "$REAL_IP" '.real_ip = $ip' "$CURRENT_TASK_JSON" > "$TMP_JSON" && mv "$TMP_JSON" "$CURRENT_TASK_JSON"
else
    echo "{\"real_ip\": \"$REAL_IP\"}" > "$CURRENT_TASK_JSON"
fi

SESSION_SUMMARY_JSON="$CAPTURE_LOG_DIR/session_summary.json"
if [ -f "$SESSION_SUMMARY_JSON" ]; then
    TMP_JSON=$(mktemp)
    jq --arg ip "$REAL_IP" '.real_ip = $ip' "$SESSION_SUMMARY_JSON" > "$TMP_JSON" && mv "$TMP_JSON" "$SESSION_SUMMARY_JSON"
else
    echo "{\"real_ip\": \"$REAL_IP\"}" > "$SESSION_SUMMARY_JSON"
fi

# [🧼 Smart Purge] Purge WebView cookies, session DBs, and tracking SDK identifiers (Nelo, Firebase, Braze, AppsFlyer)
# while preserving the map tile caches (NaverNavi/ and naviguide/) to prevent massive download traffic and nCaptcha time-outs under QoS.
echo " [$DEV_ID] [🧹] Force stopping Naver Map..."
adb -s "$DEV_ID" shell am force-stop com.nhn.android.nmap >/dev/null 2>&1
echo " [$DEV_ID] [🧼] Performing Smart Purge (preserving offline map tiles & webview caches)..."
adb -s "$DEV_ID" shell "su -c '
    rm -rf /data/data/com.nhn.android.nmap/app_webview/Default/Cookies* \
           /data/data/com.nhn.android.nmap/app_webview/Default/Local\ Storage \
           /data/data/com.nhn.android.nmap/app_webview/Default/Session\ Storage \
           /data/data/com.nhn.android.nmap/app_webview/Default/Preferences* \
           /data/data/com.nhn.android.nmap/databases \
           /data/data/com.nhn.android.nmap/shared_prefs \
           /data/data/com.nhn.android.nmap/no_backup/* \
           /data/data/com.nhn.android.nmap/code_cache/*
    # Clean cache except WebView cache to preserve compiled JS/Wasm cache and save mobile data
    find /data/data/com.nhn.android.nmap/cache/ -maxdepth 1 ! -name \"cache\" ! -name \"WebView\" -exec rm -rf {} +
    # Clean files/ except NaverNavi and naviguide to preserve map tiles
    find /data/data/com.nhn.android.nmap/files/ -maxdepth 1 ! -name \"files\" ! -name \"NaverNavi\" ! -name \"naviguide\" -exec rm -rf {} +
'" >/dev/null 2>&1

echo " [$DEV_ID] [🛡️] Granting location & system permissions..."
adb -s "$DEV_ID" shell pm grant com.nhn.android.nmap android.permission.ACCESS_FINE_LOCATION >/dev/null 2>&1
adb -s "$DEV_ID" shell pm grant com.nhn.android.nmap android.permission.ACCESS_COARSE_LOCATION >/dev/null 2>&1
adb -s "$DEV_ID" shell pm grant com.nhn.android.nmap android.permission.READ_PHONE_STATE >/dev/null 2>&1
adb -s "$DEV_ID" shell pm grant com.nhn.android.nmap android.permission.POST_NOTIFICATIONS >/dev/null 2>&1
adb -s "$DEV_ID" shell pm grant com.nhn.android.nmap android.permission.RECORD_AUDIO >/dev/null 2>&1
# Grant Draw Over Other Apps (SYSTEM_ALERT_WINDOW) since pm clear resets AppOps
adb -s "$DEV_ID" shell appops set com.nhn.android.nmap SYSTEM_ALERT_WINDOW allow >/dev/null 2>&1
sleep 1

APP_UID=$(adb -s "$DEV_ID" shell "pm list packages -U com.nhn.android.nmap" | grep -oE "uid:[0-9]+" | cut -d: -f2 | head -n 1)
[ -z "$APP_UID" ] && APP_UID="root"
./lib/inject_template.sh "$DEV_ID" "com.nhn.android.nmap" "$APP_UID" "$NMAP_ID_SSAID" "$NMAP_ID_IDFV" "$NMAP_ID_ADID"

# 4. Proxy & Workers
adb -s "$DEV_ID" forward tcp:"$NMAP_FRIDA_PORT" tcp:27042 >/dev/null 2>&1
adb -s "$DEV_ID" reverse tcp:"$NMAP_MITM_PORT" tcp:"$NMAP_MITM_PORT" >/dev/null 2>&1
adb -s "$DEV_ID" shell settings put global http_proxy localhost:"$NMAP_MITM_PORT"

# --- [NEW] ADB Tunnel Watchdog ---
# Prevents network drops during long drives by ensuring the proxy reverse tunnel stays alive
(
    while true; do
        if ! adb -s "$DEV_ID" reverse --list 2>/dev/null | grep -q "tcp:$NMAP_MITM_PORT"; then
            echo " [$DEV_ID] [⚠️] ADB Reverse Tunnel dropped! Restoring..." >> "$EXEC_LOG"
            adb -s "$DEV_ID" reverse tcp:"$NMAP_MITM_PORT" tcp:"$NMAP_MITM_PORT" >/dev/null 2>&1
        fi
        sleep 60
    done
) >/dev/null 2>&1 &
WATCHDOG_PID=$!

# [CRITICAL] Export identity variables to subshells so background mitmdump can access them
export NMAP_ORIG_SSAID NMAP_ORIG_ADID NMAP_ORIG_IDFV NMAP_ORIG_NI NMAP_ORIG_TOKEN
export NMAP_ID_SSAID NMAP_ID_ADID NMAP_ID_IDFV NMAP_ID_NI NMAP_ID_TOKEN
export NMAP_DEV_ID="$DEV_ID"
export NMAP_BIND_IP="$NMAP_BIND_IP"

BIND_OPT=""
if [ -n "$NMAP_BIND_IP" ]; then
    BIND_OPT="--set connect_addr=$NMAP_BIND_IP"
fi

nohup mitmdump -p "$NMAP_MITM_PORT" $BIND_OPT -s mitm/addon.py --ssl-insecure --listen-host 0.0.0.0 --set flow_detail=0 > "$CAPTURE_LOG_DIR/mitm.log" 2>&1 &
MITM_PID=$!
setsid python3 gps/auto_reloader.py "$CAPTURE_LOG_DIR" "$DEV_ID" >> "$EXEC_LOG" 2>&1 &
RELOAD_PID=$!
chmod +x macro/monitor.sh
nohup ./macro/monitor.sh "$DEV_ID" "$CAPTURE_LOG_DIR" "$NMAP_DEST_ID" > "$CAPTURE_LOG_DIR/monitor.log" 2>&1 &
MONITOR_PID=$!

# 5. Launch (Wake & Unlock Screen Robustly - Intelligent Verification Loop)
check_keyguard_showing() {
    # Get window manager dump, search for lines mentioning keyguard, lockscreen, or statusbar
    local win_dump=$(adb -s "$DEV_ID" shell "dumpsys window" 2>/dev/null)
    
    # 1. Search for explicit 'isKeyguardShowing=true' or 'mShowingKeyguard=true'
    if [[ "$win_dump" == *"isKeyguardShowing=true"* ]] || [[ "$win_dump" == *"mShowingKeyguard=true"* ]]; then
        return 0 # Locked
    fi
    
    # 2. Check for dreaming lockscreen
    if [[ "$win_dump" == *"mDreamingLockscreen=true"* ]]; then
        return 0 # Locked
    fi

    # 3. Check for general 'showing=true' or 'mShowing=true' on keyguard-related lines
    local keyguard_lines=$(echo "$win_dump" | grep -i -E "keyguard|lockscreen")
    if echo "$keyguard_lines" | grep -i -q -E "showing\s*=\s*true|mShowing\s*=\s*true"; then
        return 0 # Locked
    fi
    
    # 4. Fallback check: window policy dump
    local policy_dump=$(adb -s "$DEV_ID" shell "dumpsys window policy" 2>/dev/null)
    if [[ "$policy_dump" == *"isKeyguardShowing=true"* ]] || [[ "$policy_dump" == *"mShowingKeyguard=true"* ]]; then
        return 0 # Locked
    fi
    if echo "$policy_dump" | grep -i -E "keyguard|lockscreen" | grep -i -q -E "showing\s*=\s*true|mShowing\s*=\s*true"; then
        return 0 # Locked
    fi

    return 1 # Unlocked
}

echo " [$DEV_ID] Waking up device screen..."
IS_ON=$(adb -s "$DEV_ID" shell "dumpsys power | grep -E 'mWakefulness=|Display Power: state='" 2>/dev/null)
if [[ "$IS_ON" == *"Asleep"* ]] || [[ "$IS_ON" == *"OFF"* ]]; then
    adb -s "$DEV_ID" shell input keyevent 224
    sleep 0.8
fi

if ! check_keyguard_showing; then
    echo " [$DEV_ID] Screen is already unlocked. Skipping unlock swipe."
else
    echo " [$DEV_ID] Keyguard is showing. Attempting unlock retry loop..."
    for retry in {1..5}; do
        # Waking screen in case it went back to sleep during retries
        IS_ON=$(adb -s "$DEV_ID" shell "dumpsys power | grep -E 'mWakefulness=|Display Power: state='" 2>/dev/null)
        if [[ "$IS_ON" == *"Asleep"* ]] || [[ "$IS_ON" == *"OFF"* ]]; then
            adb -s "$DEV_ID" shell input keyevent 224
            sleep 0.8
        fi

        # Dismiss using standard dismiss command
        adb -s "$DEV_ID" shell wm dismiss-keyguard >/dev/null 2>&1
        sleep 0.4
        
        # Send Menu keyevent (82) which is extremely effective on Samsung and other brands to clear swipe locks
        adb -s "$DEV_ID" shell input keyevent 82
        sleep 0.6
        
        if ! check_keyguard_showing; then
            echo " [$DEV_ID] Keyguard successfully dismissed via Menu key event."
            break
        fi
        
        # Swipe UP (swipe from bottom to top to dismiss swipe lock screens)
        if [ $retry -eq 1 ]; then
            adb -s "$DEV_ID" shell input swipe 500 1600 500 400 350
        elif [ $retry -eq 2 ]; then
            adb -s "$DEV_ID" shell input swipe 300 1600 800 400 400
        else
            adb -s "$DEV_ID" shell input swipe 500 1800 500 200 450
        fi
        sleep 1.2

        if ! check_keyguard_showing; then
            echo " [$DEV_ID] Keyguard successfully dismissed."
            break
        fi
        echo " [$DEV_ID] [Attempt $retry/5] Keyguard still active. Retrying unlock..."
    done
fi


# Fixed: Use START coordinates for initial position
./gps/static.sh "$DEV_ID" "$NMAP_START_LAT" "$NMAP_START_LNG"
adb -s "$DEV_ID" shell monkey -p com.nhn.android.nmap -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1

PID=""
for i in {1..10}; do
    PID=$(adb -s "$DEV_ID" shell pidof com.nhn.android.nmap | tr -d '\r\n')
    [ -n "$PID" ] && break
    sleep 1
done
[ -z "$PID" ] && cleanup "App Launch Timeout"

sleep 3

nohup frida -H localhost:"$NMAP_FRIDA_PORT" --runtime=v8 -p "$PID" \
    -l lib/hooks/network_hook.js \
    -l lib/hooks/_core_survival.js \
    --no-auto-reload \
    -q -t inf > "$CAPTURE_LOG_DIR/frida.log" 2>&1 &
FRIDA_PID=$!

while true; do
    # 1. Check if monitor.sh finished
    kill -0 $MONITOR_PID 2>/dev/null || cleanup "Task Completed"
    
    # 2. Check if Naver Map app is still running (Robust check against transient ADB/USB drops)
    APP_RUNNING=false
    if ! adb devices | grep -q -w "$DEV_ID"; then
        # Device is temporarily disconnected/offline. Assume the app is still running to prevent false kill.
        APP_RUNNING=true
    else
        for r in {1..3}; do
            if adb -s "$DEV_ID" shell pidof com.nhn.android.nmap >/dev/null 2>&1; then
                APP_RUNNING=true
                break
            fi
            sleep 1
        done
    fi
    if [ "$APP_RUNNING" = false ]; then
        cleanup "App Closed"
    fi
    
    # 3. Check Frida connection
    if ! kill -0 $FRIDA_PID 2>/dev/null; then
        cleanup "Frida Crash (Connection lost)"
    fi

    # 4. Check mitmdump proxy
    if ! kill -0 $MITM_PID 2>/dev/null; then
        cleanup "mitmdump Crash (Proxy stopped)"
    fi
    
    sleep 5
done
