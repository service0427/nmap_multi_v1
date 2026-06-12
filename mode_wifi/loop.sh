#!/bin/bash
# Smart Multi-Device Orchestrator (V2.9.9 - Standardized)

# --- [PATH SETUP] ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR" || exit 1

export MODE_WIFI_ROOT="$SCRIPT_DIR"
export MODE_WIFI_LOGS="$SCRIPT_DIR/logs"
export MODE_WIFI_LIB="$SCRIPT_DIR/lib"

# Load Network Utils (Standardized path)
source "$PROJECT_ROOT/device_init/modules/network_utils.sh"

export API_SERVER="114.207.112.245:8000"

pkill -9 -f "main.sh"
pkill -9 -f "mitmdump"
sleep 2

while true; do
    DEVICES=$(timeout 5 adb devices | grep -w "device" | awk '{print $1}')
    [ -z "$DEVICES" ] && sleep 10 && continue

    echo "------------------------------------------------------------"
    echo "[$(date +%T)] Scanning $(echo $DEVICES | wc -w) devices..."

    for DEV_ID in $DEVICES; do
        if pgrep -f "main.sh $DEV_ID" > /dev/null; then continue; fi

        # Bypassed per-device binding to route through default route (lowest metric: lte11)
        BIND_IFACE=""
        CURL_OPT=""

        RESPONSE=$(curl $CURL_OPT -s -X POST "http://$API_SERVER/api/v1/request_task" \
             -H "Content-Type: application/json" \
             -d "{\"device_id\":\"$DEV_ID\"}")
        
        [ -z "$RESPONSE" ] || [ "$(echo "$RESPONSE" | jq -r '.status')" != "ok" ] && continue

        TASK_ID=$(echo "$RESPONSE" | jq -r '.task_id')
        DEST_NAME=$(echo "$RESPONSE" | jq -r '.destination.target_name')
        FRIDA_PORT=$((6000 + $(echo "$DEV_ID" | cksum | awk '{print $1 % 1000}')))
        
        echo "[🚀] [$DEV_ID] ALLOCATED: $DEST_NAME (Task:$TASK_ID) via $BIND_IFACE"

        # Pass ALL variables to the engine
        NMAP_API_RESPONSE="$RESPONSE" \
        NMAP_TASK_ID="$TASK_ID" \
        NMAP_LOG_ID="$TASK_ID" \
        NMAP_DEST_ID=$(echo "$RESPONSE" | jq -r '.destination.id') \
        NMAP_DEST_LAT=$(echo "$RESPONSE" | jq -r '.destination.lat') \
        NMAP_DEST_LNG=$(echo "$RESPONSE" | jq -r '.destination.lng') \
        NMAP_DEST_NAME="$DEST_NAME" \
        NMAP_START_LAT=$(echo "$RESPONSE" | jq -r '.start_pos.lat') \
        NMAP_START_LNG=$(echo "$RESPONSE" | jq -r '.start_pos.lng') \
        NMAP_FRIDA_PORT="$FRIDA_PORT" \
        NMAP_ORIG_SSAID=$(echo "$RESPONSE" | jq -r '.identity.original.ssaid') \
        setsid bash "$MODE_WIFI_LIB/main.sh" "$DEV_ID" >> "logs/${DEV_ID}/tmp/main_debug.log" 2>&1 &
        
        sleep 2
    done
    sleep 20
done
