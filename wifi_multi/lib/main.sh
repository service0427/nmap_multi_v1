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

# --- [ZOMBIE PURGE] ---
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
    
    # Check if the task already finished successfully
    local IS_SUCCESS=false
    if grep -q "SUCCESS" "$CURRENT_TASK_JSON" 2>/dev/null; then
        IS_SUCCESS=true
    fi

    if [ "$IS_SUCCESS" = false ]; then
        # Report FAIL only if it wasn't a success
        curl $CURL_OPT -s -X POST "http://${API_SERVER}/api/v1/report_result" \
             -H "Content-Type: application/json" \
             -d "{\"task_id\": \"$NMAP_LOG_ID\", \"device_id\": \"$DEV_ID\", \"status\": \"FAIL\", \"message\": \"$REASON\"}" > /dev/null
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
DATE_STR=$(date +%Y%m%d); TIME_STR=$(date +%H%M%S)
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
echo " [$DEV_ID] [🌐] Verifying External Network..."
IP_READY=false
for i in {1..15}; do
    # Try multiple IP check services in sequence to resolve rate limits or downtime
    REAL_IP=$(adb -s "$DEV_ID" shell "[ -x /data/local/tmp/curl ] && /data/local/tmp/curl -s --connect-timeout 2 -4 http://ifconfig.me || curl -s --connect-timeout 2 -4 http://ifconfig.me" | tr -d '\r\n' | grep -oE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+")
    if [ -z "$REAL_IP" ]; then
        REAL_IP=$(adb -s "$DEV_ID" shell "[ -x /data/local/tmp/curl ] && /data/local/tmp/curl -s --connect-timeout 2 -4 http://api.ipify.org || curl -s --connect-timeout 2 -4 http://api.ipify.org" | tr -d '\r\n' | grep -oE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+")
    fi
    if [ -z "$REAL_IP" ]; then
        REAL_IP=$(adb -s "$DEV_ID" shell "[ -x /data/local/tmp/curl ] && /data/local/tmp/curl -s --connect-timeout 2 -4 http://icanhazip.com || curl -s --connect-timeout 2 -4 http://icanhazip.com" | tr -d '\r\n' | grep -oE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+")
    fi

    if [ -n "$REAL_IP" ]; then
        echo " [$DEV_ID] [✓] Real IPv4: $REAL_IP"
        IP_READY=true
        break
    fi
    
    # [NEW] Backup check: If 8.8.8.8 is reachable, allow session passage to prevent NETWORK_TIMEOUT under proxy load
    if adb -s "$DEV_ID" shell "ping -c 1 -W 2 8.8.8.8" >/dev/null 2>&1; then
        echo " [$DEV_ID] [⚠️] IP check sites timed out, but 8.8.8.8 ping succeeded. Proceeding with active connection."
        REAL_IP="0.0.0.0"
        IP_READY=true
        break
    fi
    
    echo " [$DEV_ID] Waiting for IP (Toggle Recovery)... ($i/15)"
    sleep 2
done

if [ "$IP_READY" = false ]; then
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

# 3. Golden Template
# [NEW] Clear App Data and Grant Permissions before applying Golden Template
echo " [$DEV_ID] [🧹] Clearing Naver Map app data (pm clear)..."
adb -s "$DEV_ID" shell pm clear com.nhn.android.nmap >/dev/null 2>&1

echo " [$DEV_ID] [🛡️] Granting location & system permissions..."
adb -s "$DEV_ID" shell pm grant com.nhn.android.nmap android.permission.ACCESS_FINE_LOCATION >/dev/null 2>&1
adb -s "$DEV_ID" shell pm grant com.nhn.android.nmap android.permission.ACCESS_COARSE_LOCATION >/dev/null 2>&1
adb -s "$DEV_ID" shell pm grant com.nhn.android.nmap android.permission.READ_PHONE_STATE >/dev/null 2>&1
adb -s "$DEV_ID" shell pm grant com.nhn.android.nmap android.permission.POST_NOTIFICATIONS >/dev/null 2>&1
adb -s "$DEV_ID" shell pm grant com.nhn.android.nmap android.permission.RECORD_AUDIO >/dev/null 2>&1
sleep 1

APP_UID=$(adb -s "$DEV_ID" shell "pm list packages -U com.nhn.android.nmap" | grep -oE "uid:[0-9]+" | cut -d: -f2 | head -n 1)
[ -z "$APP_UID" ] && APP_UID="root"
./lib/inject_template.sh "$DEV_ID" "com.nhn.android.nmap" "$APP_UID" "$NMAP_ORIG_SSAID"

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

# 5. Launch (Wake & Unlock Screen Robustly)
if adb -s "$DEV_ID" shell dumpsys power | grep -q "mWakefulness=Asleep"; then
    echo " [$DEV_ID] Screen is Asleep. Waking up..."
    adb -s "$DEV_ID" shell input keyevent 224
    sleep 0.5
fi
if adb -s "$DEV_ID" shell dumpsys window | grep -qE "mShowingLockscreen=true|isKeyguardShowing=true|mDreamingLockscreen=true"; then
    echo " [$DEV_ID] Lock screen detected. Force unlocking..."
    adb -s "$DEV_ID" shell wm dismiss-keyguard >/dev/null 2>&1
    sleep 0.5
    # Force a long upward swipe to clear the lock screen just in case dismiss-keyguard fails
    adb -s "$DEV_ID" shell input swipe 500 2000 500 200 300
    sleep 0.5
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
    local APP_RUNNING=false
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
    
    # 3. [Self-Healing] Check and restore Frida connection
    if ! kill -0 $FRIDA_PID 2>/dev/null; then
        echo "[$(date +'%H:%M:%S')] [⚠️] Frida connection lost! Attempting to re-attach..." >> "$EXEC_LOG"
        PID=$(adb -s "$DEV_ID" shell pidof com.nhn.android.nmap | tr -d '\r\n')
        if [ -n "$PID" ]; then
            adb -s "$DEV_ID" forward --remove tcp:"$NMAP_FRIDA_PORT" 2>/dev/null
            adb -s "$DEV_ID" forward tcp:"$NMAP_FRIDA_PORT" tcp:27042 >/dev/null 2>&1
            nohup frida -H localhost:"$NMAP_FRIDA_PORT" --runtime=v8 -p "$PID" \
                -l lib/hooks/network_hook.js \
                -l lib/hooks/_core_survival.js \
                --no-auto-reload \
                -q -t inf > "$CAPTURE_LOG_DIR/frida.log" 2>&1 &
            FRIDA_PID=$!
            echo "[$(date +'%H:%M:%S')] [✓] Frida successfully re-attached to PID $PID." >> "$EXEC_LOG"
        else
            cleanup "Frida Crash (App not running)"
        fi
    fi

    # 4. [Self-Healing] Check and restore mitmdump proxy
    if ! kill -0 $MITM_PID 2>/dev/null; then
        echo "[$(date +'%H:%M:%S')] [⚠️] mitmdump crashed! Attempting to restart..." >> "$EXEC_LOG"
        nohup mitmdump -p "$NMAP_MITM_PORT" $BIND_OPT -s mitm/addon.py --ssl-insecure --listen-host 0.0.0.0 --set flow_detail=0 > "$CAPTURE_LOG_DIR/mitm.log" 2>&1 &
        MITM_PID=$!
        echo "[$(date +'%H:%M:%S')] [✓] mitmdump successfully restarted." >> "$EXEC_LOG"
    fi
    
    sleep 5
done
