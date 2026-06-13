#!/bin/bash
# Smart Multi-Device Orchestrator (V3.0 - Standardized)
# Supports Manual ADB-order Mapping

# --- [CONFIGURATION] ---
# 수동 배분 모드 (SSID를 읽지 않고 ADB 연결 순서대로 강제 배분)
# 예: (5 5 5 5) -> lte11에 5대, lte12에 5대...
# 예: (4 4 4 3) -> lte11에 4대, lte12에 4대, lte13에 4대, lte14에 3대
MANUAL_COUNTS=(5 5 5 5)

# --- [PATH SETUP] ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
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

while true; do
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

        # --- Manual Assignment Logic ---
        MODEM_IDX=11
        BIND_IP=""
        
        # Calculate which modem this device belongs to based on MANUAL_COUNTS
        current_sum=0
        for i in "${!MANUAL_COUNTS[@]}"; do
            current_sum=$((current_sum + MANUAL_COUNTS[i]))
            if [ "$DEV_INDEX" -lt "$current_sum" ]; then
                MODEM_IDX=$((11 + i))
                BIND_IP="${IP_LIST[$i]}"
                break
            fi
        done

        # Fallback if device index exceeds manual counts (put in last modem)
        if [ -z "$BIND_IP" ]; then
            MODEM_IDX=14
            BIND_IP="${IP_LIST[3]}"
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

        DEV_LOG_DIR="$WIFI_MULTI_LOGS/${DEV_ID}/tmp"
        mkdir -p "$DEV_LOG_DIR"
        
        ENV_FILE="${DEV_LOG_DIR}/env_vars"
        cat <<EOF > "$ENV_FILE"
export WIFI_MULTI_ROOT="$WIFI_MULTI_ROOT"
export WIFI_MULTI_LOGS="$WIFI_MULTI_LOGS"
export WIFI_MULTI_LIB="$WIFI_MULTI_LIB"
export API_SERVER="$API_SERVER"
export NMAP_BIND_IP="$BIND_IP"
export NMAP_API_RESPONSE='$(echo "$RESPONSE" | sed "s/'/'\\\\''/g")'
export NMAP_TASK_ID="$TASK_ID"
export NMAP_LOG_ID="$TASK_ID"
export NMAP_DEST_ID="$(echo "$RESPONSE" | jq -r '.destination.id')"
export NMAP_DEST_LAT="$(echo "$RESPONSE" | jq -r '.destination.lat')"
export NMAP_DEST_LNG="$(echo "$RESPONSE" | jq -r '.destination.lng')"
export NMAP_DEST_NAME="$(echo "$DEST_NAME" | sed "s/\"/\\\"/g")"
export NMAP_DEST_ADDR="$(echo "$RESPONSE" | jq -r '.destination.address' | sed "s/\"/\\\"/g")"
export NMAP_START_LAT="$(echo "$RESPONSE" | jq -r '.start_pos.lat')"
export NMAP_START_LNG="$(echo "$RESPONSE" | jq -r '.start_pos.lng')"
export NMAP_FRIDA_PORT="$FRIDA_PORT"
export NMAP_ORIG_SSAID="$(echo "$RESPONSE" | jq -r '.identity.original.ssaid')"
EOF

        setsid bash "$WIFI_MULTI_LIB/main.sh" "$DEV_ID" >> "${DEV_LOG_DIR}/main_debug.log" 2>&1 &
        
        DEV_INDEX=$((DEV_INDEX + 1))
        sleep 5
    done
    sleep 30
done
