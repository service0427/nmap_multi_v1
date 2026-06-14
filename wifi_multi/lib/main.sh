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

# Bypassed per-device binding to route through default route (lowest metric: lte11)
BIND_IFACE=""
BIND_IP="$NMAP_BIND_IP"
CURL_OPT=""

NMAP_MITM_PORT=$((NMAP_FRIDA_PORT + 10000))
DEV_TMP_DIR="logs/${DEV_ID}/tmp"
mkdir -p "$DEV_TMP_DIR"
LOCK_FILE="${DEV_TMP_DIR}/nmap_lock"
CURRENT_TASK_JSON="logs/${DEV_ID}/current_task.json"

( while true; do touch "$LOCK_FILE"; sleep 10; done ) &
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

    kill -9 $MITM_PID $FRIDA_PID $MONITOR_PID $RELOAD_PID $HEARTBEAT_PID 2>/dev/null
    adb -s "$DEV_ID" shell am force-stop com.nhn.android.nmap
    adb -s "$DEV_ID" shell settings put global http_proxy :0 2>/dev/null
    adb -s "$DEV_ID" forward --remove tcp:"$NMAP_FRIDA_PORT" 2>/dev/null
    adb -s "$DEV_ID" reverse --remove tcp:"$NMAP_MITM_PORT" 2>/dev/null
    rm -f "$LOCK_FILE" "$CURRENT_TASK_JSON"
    exit 0
}
trap "cleanup 'SigTerm'" INT TERM

# 1. Setup Logs
DATE_STR=$(date +%Y%m%d); TIME_STR=$(date +%H%M%S)
export CAPTURE_LOG_DIR="$ENGINE_ROOT/logs/${DEV_ID}/${DATE_STR}/${TIME_STR}_${NMAP_DEST_ID}"
mkdir -p "$CAPTURE_LOG_DIR"
EXEC_LOG="$CAPTURE_LOG_DIR/execution.log"
exec > >(tee -a "$EXEC_LOG") 2>&1

echo "============================================================"
echo " [$DEV_ID] TASK STARTED via $BIND_IP"
echo "------------------------------------------------------------"

# 2. IP Verification
REAL_IP=$(adb -s "$DEV_ID" shell "[ -x /data/local/tmp/curl ] && /data/local/tmp/curl -s -4 http://ifconfig.me || curl -s -4 http://ifconfig.me" | tr -d '\r\n')
echo " [✓] Real IPv4: $REAL_IP"
curl $CURL_OPT -s -X POST "http://${API_SERVER}/api/v1/update_status" \
     -H "Content-Type: application/json" \
     -d "{\"task_id\": \"$NMAP_LOG_ID\", \"status\": \"IP_CHANGED\", \"device_id\": \"$DEV_ID\", \"real_ip\": \"$REAL_IP\"}" > /dev/null

# 3. Golden Template
APP_UID=$(adb -s "$DEV_ID" shell "pm list packages -U com.nhn.android.nmap" | grep -oE "uid:[0-9]+" | cut -d: -f2 | head -n 1)
[ -z "$APP_UID" ] && APP_UID="root"
./lib/inject_template.sh "$DEV_ID" "com.nhn.android.nmap" "$APP_UID" "$NMAP_ORIG_SSAID"

# 4. Proxy & Workers
adb -s "$DEV_ID" forward tcp:"$NMAP_FRIDA_PORT" tcp:27042 >/dev/null 2>&1
adb -s "$DEV_ID" reverse tcp:"$NMAP_MITM_PORT" tcp:"$NMAP_MITM_PORT" >/dev/null 2>&1
adb -s "$DEV_ID" shell settings put global http_proxy localhost:"$NMAP_MITM_PORT"

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

# 5. Launch
./gps/static.sh "$DEV_ID" "$NMAP_START_LAT" "$NMAP_START_LNG"
adb -s "$DEV_ID" shell monkey -p com.nhn.android.nmap -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1

PID=""
for i in {1..10}; do
    PID=$(adb -s "$DEV_ID" shell pidof com.nhn.android.nmap | tr -d '\r\n')
    [ -n "$PID" ] && break
    sleep 1
done
[ -z "$PID" ] && cleanup "App Launch Timeout"

nohup frida -H localhost:"$NMAP_FRIDA_PORT" --runtime=v8 -p "$PID" \
    -l lib/hooks/network_hook.js \
    -l lib/hooks/_core_survival.js \
    --no-auto-reload > "$CAPTURE_LOG_DIR/frida.log" 2>&1 &
FRIDA_PID=$!

while true; do
    kill -0 $FRIDA_PID 2>/dev/null || cleanup "Frida Crash"
    adb -s "$DEV_ID" shell pidof com.nhn.android.nmap >/dev/null 2>&1 || cleanup "App Closed"
    sleep 5
done
