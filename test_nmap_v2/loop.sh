#!/bin/bash
# test_nmap_v2: Smart Multi-Device Task Orchestrator (V2.9.6 - Global Safety & Recovery)

# Parse Arguments
SKIP_IP=false; SINGLE_DEV_ID=""
for arg in "$@"; do
    if [ "$arg" == "--no-ip" ]; then SKIP_IP=true; elif [[ "$arg" != --* ]]; then SINGLE_DEV_ID="$arg"; fi
done

PKG_NAME="com.nhn.android.nmap"
export API_SERVER="121.173.150.103:5003"

# --- [CORE] Functions ---
NOW() { date +"%H:%M:%S.%3N"; }
log_info() { echo "[$(NOW)] [*] $1"; }
log_success() { echo "[$(NOW)] [🚀] $1"; }
log_busy() { echo "[$(NOW)] [⏳] $1"; }

echo "============================================================"
echo "   NMAP V2 DYNAMIC TASK ORCHESTRATOR (V2.9.6)"
echo "   Action: Global Safety & Offline Recovery"
echo "============================================================"

# 0. Initial Purge
pkill -9 -f "lib/main.sh"
pkill -9 -f "auto_reloader.py"
pkill -9 -f "monitor.sh"
pkill -9 -f "mitmdump"
pkill -9 -f "frida"
sleep 2

get_devices() {
    if [ -n "$SINGLE_DEV_ID" ]; then echo "$SINGLE_DEV_ID"; else timeout 5 /usr/bin/adb devices | grep -w "device" | awk '{print $1}'; fi
}

force_purge_device() {
    local TARGET_DEV=$1
    log_info "[$TARGET_DEV] Executing comprehensive purge for background workers..."
    
    # 1. Kill main.sh script
    local PIDS=$(pgrep -f "main.sh $TARGET_DEV" | xargs)
    [ -n "$PIDS" ] && kill -9 $PIDS 2>/dev/null
    
    # 2. Kill child workers based on target device signature
    local DEV_SEQ=$(echo "$TARGET_DEV" | cksum | awk '{print $1 % 1000}')
    local EXP_FRIDA=$((6000 + DEV_SEQ))
    local EXP_MITM=$((EXP_FRIDA + 10000))
    
    pkill -9 -f "mitmdump -p $EXP_MITM" 2>/dev/null
    pkill -9 -f "monitor.sh $TARGET_DEV" 2>/dev/null
    pkill -9 -f "auto_reloader.py.*$TARGET_DEV" 2>/dev/null
    pkill -9 -f "frida -H localhost:$EXP_FRIDA" 2>/dev/null
    
    # 3. Terminate android app and GPS service
    timeout 5 /usr/bin/adb -s "$TARGET_DEV" shell am force-stop $PKG_NAME 2>/dev/null
    
    local su_path=$(timeout 5 /usr/bin/adb -s "$TARGET_DEV" shell "which su" 2>/dev/null | tr -d '\r')
    [ -z "$su_path" ] && su_path="su"
    timeout 5 /usr/bin/adb -s "$TARGET_DEV" shell "$su_path -c 'am stopservice com.rosteam.gpsemulator/.servicex2484'" 2>/dev/null
    
    # 4. Reset network & proxy configurations
    timeout 5 /usr/bin/adb -s "$TARGET_DEV" shell settings put global http_proxy :0 2>/dev/null
    timeout 5 /usr/bin/adb -s "$TARGET_DEV" reverse --remove tcp:$EXP_FRIDA 2>/dev/null
    timeout 5 /usr/bin/adb -s "$TARGET_DEV" reverse --remove tcp:$EXP_MITM 2>/dev/null
    timeout 5 /usr/bin/adb -s "$TARGET_DEV" forward --remove tcp:$EXP_FRIDA 2>/dev/null
}

LAST_CLEANUP=0
while true; do
    DEVICES=$(get_devices)
    if [ -z "$DEVICES" ]; then
        # [V2.9.6] Offline Recovery: 아무 기기도 없거나 offline인 경우 adb reconnect 시도
        OFFLINE_DEVICES=$(/usr/bin/adb devices | grep -w "offline" | awk '{print $1}')
        if [ -n "$OFFLINE_DEVICES" ]; then
            log_info "Offline devices detected: $OFFLINE_DEVICES. Attempting reconnect..."
            for OFF_ID in $OFFLINE_DEVICES; do
                /usr/bin/adb -s "$OFF_ID" reconnect 2>/dev/null
            done
            sleep 2
        fi
        log_info "No active devices detected. Retrying in 10s..."
        sleep 10
        continue
    fi

    echo "------------------------------------------------------------"
    log_info "Scanning $(echo $DEVICES | wc -w) devices..."

    for DEV_ID in $DEVICES; do
        # 기기별 격리된 tmp 폴더 생성
        DEV_TMP_DIR="$(dirname "$0")/logs/${DEV_ID}/tmp"
        mkdir -p "$DEV_TMP_DIR"

        # 1. 프로세스 및 타임아웃 체크 (격리된 락파일 및 current_task.json 사용)
        SCRIPT_PIDS=$(pgrep -f "lib/main.sh $DEV_ID" | xargs)
        CURRENT_TASK_JSON="$(dirname "$0")/logs/${DEV_ID}/current_task.json"
        
        # [V2.9.6] Global Safety: current_task.json 기반 15분 강제 종료
        if [ -f "$CURRENT_TASK_JSON" ]; then
            START_TS=$(jq -r '.start_ts // 0' "$CURRENT_TASK_JSON" 2>/dev/null)
            NOW_TS=$(date +%s)
            AGE=$((NOW_TS - START_TS))
            
            if [ "$AGE" -gt 900 ]; then
                log_info "[$DEV_ID] GLOBAL TIMEOUT ($AGE s > 15m). Force Purging everything..."
                force_purge_device "$DEV_ID"
                rm -f "$CURRENT_TASK_JSON"
                rm -f "${DEV_TMP_DIR}/nmap_lock"
                continue
            fi
        fi

        # [V2.9.6] Ghost App Detection: 프로세스는 없는데 앱만 떠있는 경우
        CURRENT_FOCUS=$(timeout 5 /usr/bin/adb -s "$DEV_ID" shell "dumpsys activity activities | grep -E 'mResumedActivity|mCurrentFocus|topResumedActivity' | grep $PKG_NAME" 2>/dev/null)
        if [ -n "$CURRENT_FOCUS" ] && [ -z "$SCRIPT_PIDS" ]; then
            log_info "[$DEV_ID] GHOST APP detected (No script running). Force stopping..."
            timeout 5 /usr/bin/adb -s "$DEV_ID" shell am force-stop $PKG_NAME 2>/dev/null
            continue
        fi

        # 기존 스케줄러 락파일 체크 (하트비트용)
        if [ -n "$SCRIPT_PIDS" ]; then
            LOCK_FILE="${DEV_TMP_DIR}/nmap_lock"
            LOCK_TIME=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0)
            AGE=0
            if [ "$LOCK_TIME" -gt 0 ]; then
                AGE=$(( $(date +%s) - LOCK_TIME ))
                if [ $AGE -lt 45 ]; then
                    continue
                fi
            fi
            log_info "[$DEV_ID] STALE Session Detected. Reason: $AGE."
            force_purge_device "$DEV_ID"
            rm -f "$LOCK_FILE"
            rm -f "$CURRENT_TASK_JSON"
        fi

        # 2. 기기 상태 체크 (앱이 포그라운드인지)
        if [ -n "$CURRENT_FOCUS" ]; then
            continue
        fi

        # [NEW] Battery Level Safety Check (Skip if battery < 10%)
        BATT_LEVEL=$(timeout 5 /usr/bin/adb -s "$DEV_ID" shell "dumpsys battery" | grep "level:" | grep -oE '[0-9]+' | head -n 1)
        if [ -n "$BATT_LEVEL" ] && [ "$BATT_LEVEL" -lt 10 ]; then
            log_info "[$DEV_ID] Battery level too low (${BATT_LEVEL}% < 10%). Skipping..."
            continue
        fi

        # 3. Request Task
        API_URL="http://$API_SERVER/api/v1/request?device_id=$DEV_ID"
        RESPONSE=$(curl -s "$API_URL")
        
        if [ -z "$RESPONSE" ] || [ "$(echo "$RESPONSE" | jq -r '.status')" != "ok" ]; then
            continue
        fi

        # Extract
        LOG_ID=$(echo "$RESPONSE" | jq -r '.log_id')
        NAME=$(echo "$RESPONSE" | jq -r '.destination.name')
        FRIDA_PORT=$(echo "$RESPONSE" | jq -r '.port')
        MITM_PORT=$((FRIDA_PORT + 10000))
        
        log_success "[$DEV_ID] ALLOCATED: $NAME (LogID:$LOG_ID)"

        # Record Spoofed Identity
        SPOOFED_JSON=$(echo "$RESPONSE" | jq -c '.identity.spoofed')
        curl -s -X POST "http://$API_SERVER/api/v1/update_status" \
             -H "Content-Type: application/json" \
             -d "{\"log_id\": $LOG_ID, \"status\": \"ALLOCATED\", \"device_id\": \"$DEV_ID\", \"spoofed_identity\": $SPOOFED_JSON}" >> "${DEV_TMP_DIR}/main_debug.log"

        # Socket Purge
        timeout 5 /usr/bin/adb -s "$DEV_ID" forward --remove tcp:$FRIDA_PORT >/dev/null 2>&1 || true
        fuser -k -n tcp "$MITM_PORT" >/dev/null 2>&1
        sleep 1

        # 4. EXECUTE V2 ENGINE
        DEBUG_LOG="${DEV_TMP_DIR}/main_debug.log"
        SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/lib/main.sh"
        NMAP_API_RESPONSE="$RESPONSE" \
        NMAP_LOG_ID="$LOG_ID" \
        NMAP_DEST_ID=$(echo "$RESPONSE" | jq -r '.destination.id') \
        NMAP_DEST_LAT=$(echo "$RESPONSE" | jq -r '.destination.lat') \
        NMAP_DEST_LNG=$(echo "$RESPONSE" | jq -r '.destination.lng') \
        NMAP_DEST_NAME="$NAME" \
        NMAP_DEST_ADDR=$(echo "$RESPONSE" | jq -r '.destination.address') \
        NMAP_MIN_ARRIVAL=$(echo "$RESPONSE" | jq -r '.destination.min_arrival // 10') \
        NMAP_MAX_ARRIVAL=$(echo "$RESPONSE" | jq -r '.destination.max_arrival // 30') \
        NMAP_ID_SSAID=$(echo "$RESPONSE" | jq -r '.identity.spoofed.ssaid') \
        NMAP_ID_ADID=$(echo "$RESPONSE" | jq -r '.identity.spoofed.adid') \
        NMAP_ID_IDFV=$(echo "$RESPONSE" | jq -r '.identity.spoofed.idfv') \
        NMAP_ID_NI=$(echo "$RESPONSE" | jq -r '.identity.spoofed.ni') \
        NMAP_ID_TOKEN=$(echo "$RESPONSE" | jq -r '.identity.spoofed.token') \
        NMAP_ORIG_SSAID=$(echo "$RESPONSE" | jq -r '.identity.original.ssaid') \
        NMAP_ORIG_ADID=$(echo "$RESPONSE" | jq -r '.identity.original.adid') \
        NMAP_ORIG_IDFV=$(echo "$RESPONSE" | jq -r '.identity.original.idfv') \
        NMAP_ORIG_NI=$(echo "$RESPONSE" | jq -r '.identity.original.ni') \
        NMAP_ORIG_TOKEN=$(echo "$RESPONSE" | jq -r '.identity.original.token') \
        NMAP_FRIDA_PORT="$FRIDA_PORT" \
        NMAP_NO_IP="$SKIP_IP" \
        setsid bash "$SCRIPT_PATH" "$DEV_ID" >> "$DEBUG_LOG" 2>&1 &
        
        log_info "[$DEV_ID] Engine forked successfully."
        sleep 2
    done
    
    sleep 20
done
