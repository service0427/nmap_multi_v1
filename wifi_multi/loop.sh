#!/bin/bash
# Smart Multi-Device Orchestrator (V2.9.9 - Standardized)

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

    echo "------------------------------------------------------------"
    echo "[$(date +%T)] Scanning $(echo $DEVICES | wc -w) devices..."

    IDX=0
    for DEV_ID in $DEVICES; do
        # Enhanced process check to prevent double allocation
        if pgrep -f "main.sh $DEV_ID" > /dev/null; then 
            IDX=$((IDX + 1))
            continue
        fi

        if [ $IDX -lt 5 ]; then BIND_IP="$IP11"
        elif [ $IDX -lt 10 ]; then BIND_IP="$IP12"
        elif [ $IDX -lt 15 ]; then BIND_IP="$IP13"
        else BIND_IP="$IP14"; fi

        if [ -z "$BIND_IP" ]; then
            IDX=$((IDX + 1))
            continue
        fi

        RESPONSE=$(curl -s -X POST "http://$API_SERVER/api/v1/request_task" \
             -H "Content-Type: application/json" \
             -d "{\"device_id\":\"$DEV_ID\"}")
        
        if [ -z "$RESPONSE" ] || [ "$(echo "$RESPONSE" | jq -r '.status')" != "ok" ]; then
            IDX=$((IDX + 1))
            continue
        fi

        TASK_ID=$(echo "$RESPONSE" | jq -r '.task_id')
        DEST_NAME=$(echo "$RESPONSE" | jq -r '.destination.target_name')
        FRIDA_PORT=$((6000 + $(echo "$DEV_ID" | cksum | awk '{print $1 % 1000}')))
        
        echo "[🚀] [$DEV_ID] ALLOCATED: $DEST_NAME (Task:$TASK_ID) -> Modem:$BIND_IP"

        DEV_LOG_DIR="$WIFI_MULTI_LOGS/${DEV_ID}/tmp"
        mkdir -p "$DEV_LOG_DIR"
        
        # Safer environment variable writing using double quotes and escaping
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

        # Added a small delay before next launch to prevent CPU spikes
        setsid bash "$WIFI_MULTI_LIB/main.sh" "$DEV_ID" >> "${DEV_LOG_DIR}/main_debug.log" 2>&1 &
        
        IDX=$((IDX + 1))
        sleep 5
    done
    sleep 30
done
