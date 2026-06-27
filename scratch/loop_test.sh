#!/bin/bash
# Smart Multi-Device Orchestrator (V19.1 - Dynamic SSID Mapping)
# Automatically maps devices to modems based on current Wi-Fi SSID suffix

# --- [CONFIGURATION] ---
MANUAL_COUNTS=(5 5 5 5)

# --- [CACHING] ---
declare -A SSID_CACHE
declare -A DEVICE_MODEL_CACHE

# --- [PATH SETUP] ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR" || exit 1

export WIFI_MULTI_ROOT="$SCRIPT_DIR"
export WIFI_MULTI_LOGS="$SCRIPT_DIR/logs"
export WIFI_MULTI_LIB="$SCRIPT_DIR/lib"
export API_SERVER="114.207.112.245:8000"

pkill -9 -f "main.sh"
pkill -9 -f "mitmdump"
sleep 2

get_ip() {
    ip -4 addr show "$1" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n 1
}

get_device_ssid() {
    local SERIAL=$1
    local SSID=$(timeout 3 adb -s "$SERIAL" shell "cmd wifi status | grep -i 'SSID:' | head -n 1" | awk -F': ' '{print $2}' | tr -d '\"\r\n')
    if [ -z "$SSID" ]; then
        SSID=$(timeout 3 adb -s "$SERIAL" shell "dumpsys connectivity | grep 'extra: ' | head -n 1" | awk -F'extra: ' '{print $2}' | awk -F',' '{print $1}' | tr -d '\"\r\n')
    fi
    echo "$SSID"
}

while true; do
    # --- [STALE PROCESS SELF-HEALING CLEANER] ---
    # 20분(1200초) 이상 구동 중인 main.sh 프로세스가 있다면 15분 안전장치가 정상 동작하지 못한 좀비 상태로 판정하여 강제 킬 및 락 초기화 진행
    while read -r pid etime args; do
        [ -z "$pid" ] && continue
        # args에서 DEV_ID 추출 (예: 'bash /home/tech/.../main.sh R3CN807BQXA')
        DEV_ID=$(echo "$args" | awk '{print $NF}')
        if [ "$etime" -gt 1200 ] && [ -n "$DEV_ID" ]; then
            echo "[⚠️] [$(date +%T)] [$DEV_ID] DETECTED STALE PROCESS (PID: $pid, Elapsed: ${etime}s). Force killing..."
            
            # 프로세스 강제 종료
            pkill -9 -f "main.sh $DEV_ID"
            pkill -9 -f "monitor.sh $DEV_ID"
            pkill -9 -f "auto_reloader.py .* $DEV_ID"
            
            # 포트 파싱 및 미트덤프/프리다 정리
            FRIDA_PORT=$((6000 + $(echo "$DEV_ID" | cksum | awk '{print $1 % 1000}')))
            MITM_PORT=$((FRIDA_PORT + 10000))
            pkill -9 -f "mitmdump -p $MITM_PORT"
            pkill -9 -f "frida -H localhost:$FRIDA_PORT"
            
            # ADB 터널 및 프록시 설정 원복, 앱 강제종료
            timeout 10 adb -s "$DEV_ID" forward --remove tcp:"$FRIDA_PORT" 2>/dev/null
            timeout 10 adb -s "$DEV_ID" reverse --remove tcp:"$MITM_PORT" 2>/dev/null
            timeout 10 adb -s "$DEV_ID" shell am force-stop com.nhn.android.nmap 2>/dev/null
            timeout 10 adb -s "$DEV_ID" shell settings put global http_proxy :0 2>/dev/null
            
            # 락 파일 및 태스크 메타파일 정리
            rm -f "logs/${DEV_ID}/tmp/nmap_lock" "logs/${DEV_ID}/current_task.json" "logs/${DEV_ID}/tmp/guidance_started" 2>/dev/null
            
            # API 서버에 실패 결과 보고
            curl -s -X POST "http://${API_SERVER}/api/v1/report_result" \
                 -H "Content-Type: application/json" \
                 -d "{\"task_id\": \"stale_kill\", \"device_id\": \"$DEV_ID\", \"status\": \"FAIL\", \"message\": \"STALE_PROCESS_KILLED_ELAPSED_${etime}s\"}" > /dev/null
        fi
    done < <(ps -eo pid,etimes,args | grep -E "bash .*/main\.sh " | grep -v grep)

    DEVICES=$(timeout 5 adb devices | grep -w "device" | awk '{print $1}')
    [ -z "$DEVICES" ] && sleep 10 && continue

    IP11=$(get_ip lte11); IP12=$(get_ip lte12); IP13=$(get_ip lte13); IP14=$(get_ip lte14)
    IP_LIST=("$IP11" "$IP12" "$IP13" "$IP14")

    echo "------------------------------------------------------------"
    echo "[$(date +%T)] Scanning $(echo $DEVICES | wc -w) devices..."
    echo "Current Modems: lte11:$IP11, lte12:$IP12, lte13:$IP13, lte14:$IP14"

    DEV_INDEX=0
    for DEV_ID in $DEVICES; do
        if pgrep -f "main.sh $DEV_ID" > /dev/null; then 
            DEV_INDEX=$((DEV_INDEX + 1))
            continue
        fi

        # --- [NEW] Dynamic SSID-to-Modem Mapping with Caching & Z Flip Override ---
        BIND_IP=""
        MODEM_IDX=""
        
        # 1. Device Initial Scan: Cache model and override state for Z Flip models if CLOSED
        if [ -z "${DEVICE_MODEL_CACHE[$DEV_ID]}" ]; then
            MODEL=$(timeout 3 adb -s "$DEV_ID" shell "getprop ro.product.model" | tr -d '\r\n')
            if [ -n "$MODEL" ]; then
                DEVICE_MODEL_CACHE["$DEV_ID"]="$MODEL"
                echo "[INITIALIZE] [$DEV_ID] Detected Model: $MODEL"
                if [[ "$MODEL" == "SM-F711N" || "$MODEL" == "SM-F721N" ]]; then
                    if adb -s "$DEV_ID" shell cmd device_state state 2>/dev/null | grep -q "Committed state:.*CLOSE"; then
                        echo "[INITIALIZE] [$DEV_ID] Z Flip is CLOSED. Overriding to state 3 (OPEN)..."
                        adb -s "$DEV_ID" shell cmd device_state state 3 >/dev/null 2>&1
                    fi
                fi
            fi
        fi

        # 2. Get Wi-Fi SSID with caching to prevent excessive adb queries
        SSID="${SSID_CACHE[$DEV_ID]}"
        if [ -z "$SSID" ]; then
            SSID=$(get_device_ssid "$DEV_ID")
            if [ -n "$SSID" ]; then
                SSID_CACHE["$DEV_ID"]="$SSID"
                echo "[DYNAMICS] [$DEV_ID] Cached SSID: $SSID"
            fi
        fi
        
        SSID_SUFFIX=$(echo "$SSID" | grep -oE "[0-9]{2}$")
        if [ -n "$SSID_SUFFIX" ]; then
            MODEM_IDX=$SSID_SUFFIX
            case "$MODEM_IDX" in
                "11") BIND_IP="$IP11" ;;
                "12") BIND_IP="$IP12" ;;
                "13") BIND_IP="$IP13" ;;
                "14") BIND_IP="$IP14" ;;
            esac
            if [ -n "$BIND_IP" ]; then
                echo "[DYNAMICS] [$DEV_ID] Matched SSID '$SSID' to Modem lte$MODEM_IDX"
            fi
        fi

        # --- Fallback to Manual Assignment Logic ---
        if [ -z "$BIND_IP" ]; then
            current_sum=0
            for i in "${!MANUAL_COUNTS[@]}"; do
                current_sum=$((current_sum + MANUAL_COUNTS[i]))
                if [ "$DEV_INDEX" -lt "$current_sum" ]; then
                    MODEM_IDX=$((11 + i))
                    BIND_IP="${IP_LIST[$i]}"
                    break
                fi
            done
            echo "[FALLBACK] [$DEV_ID] No SSID match. Using index-based Modem lte$MODEM_IDX"
        fi

        if [ -z "$BIND_IP" ]; then
            echo "[!] Skipping $DEV_ID: Modem lte$MODEM_IDX not ready (No IP)."
            DEV_INDEX=$((DEV_INDEX + 1))
            continue
        fi

        RESPONSE=$(curl -s -X POST "http://$API_SERVER/api/v1/request_task" \
             -H "Content-Type: application/json" \
             -d "{\"device_id\":\"$DEV_ID\"}")
        
        if [ -z "$RESPONSE" ] || [ "$(echo "$RESPONSE" | jq -r '.status')" != "ok" ]; then
            DEV_INDEX=$((DEV_INDEX + 1))
            continue
        fi

        TASK_ID=$(echo "$RESPONSE" | jq -r '.task_id')
        DEST_NAME=$(echo "$RESPONSE" | jq -r '.destination.target_name')
        FRIDA_PORT=$((6000 + $(echo "$DEV_ID" | cksum | awk '{print $1 % 1000}')))
        
        echo "[🚀] [$DEV_ID] ALLOCATED: $DEST_NAME (Task:$TASK_ID) -> Modem lte$MODEM_IDX ($BIND_IP)"

        # Ensure log directory exists before redirecting output
        mkdir -p "logs/${DEV_ID}/tmp"

        # [Security Warning] NMAP_ORIG_TOKEN and NMAP_ID_TOKEN are crucial for identity washing.
        # Ensure these are passed properly to prevent raw tracking token leaks.
        NMAP_BIND_IP="$BIND_IP" \
        NMAP_API_RESPONSE="$RESPONSE" \
        NMAP_TASK_ID="$TASK_ID" \
        NMAP_LOG_ID="$TASK_ID" \
        NMAP_DEST_ID=$(echo "$RESPONSE" | jq -r '.destination.id') \
        NMAP_DEST_LAT=$(echo "$RESPONSE" | jq -r '.destination.lat') \
        NMAP_DEST_LNG=$(echo "$RESPONSE" | jq -r '.destination.lng') \
        NMAP_DEST_NAME="$DEST_NAME" \
        NMAP_DEST_ADDR="$(echo "$RESPONSE" | jq -r '.destination.address' | sed "s/\"/\\\"/g")" \
        NMAP_START_LAT=$(echo "$RESPONSE" | jq -r '.start_pos.lat') \
        NMAP_START_LNG=$(echo "$RESPONSE" | jq -r '.start_pos.lng') \
        NMAP_START_SPEED=$(echo "$RESPONSE" | jq -r '.start_pos.speed_kmh') \
        NMAP_ARRIVAL_TIME=$(echo "$RESPONSE" | jq -r '.arrival_time') \
        NMAP_FRIDA_PORT="$FRIDA_PORT" \
        NMAP_ORIG_SSAID=$(echo "$RESPONSE" | jq -r '.identity.original.ssaid') \
        NMAP_ORIG_ADID=$(echo "$RESPONSE" | jq -r '.identity.original.adid') \
        NMAP_ORIG_IDFV=$(echo "$RESPONSE" | jq -r '.identity.original.idfv') \
        NMAP_ORIG_NI=$(echo "$RESPONSE" | jq -r '.identity.original.ni') \
        NMAP_ORIG_TOKEN=$(echo "$RESPONSE" | jq -r '.identity.original.token') \
        NMAP_ID_ADID=$(echo "$RESPONSE" | jq -r '.identity.spoofed.adid') \
        NMAP_ID_SSAID=$(echo "$RESPONSE" | jq -r '.identity.spoofed.ssaid') \
        NMAP_ID_IDFV=$(echo "$RESPONSE" | jq -r '.identity.spoofed.idfv') \
        NMAP_ID_NI=$(echo "$RESPONSE" | jq -r '.identity.spoofed.ni') \
        NMAP_ID_TOKEN=$(echo "$RESPONSE" | jq -r '.identity.spoofed.token') \
        setsid bash "$WIFI_MULTI_LIB/main.sh" "$DEV_ID" >> "logs/${DEV_ID}/tmp/main_debug.log" 2>&1 &
        
        DEV_INDEX=$((DEV_INDEX + 1))
        sleep 2
    done
    sleep 20
done
