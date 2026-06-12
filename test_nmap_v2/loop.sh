#!/bin/bash
# Smart Multi-Device Orchestrator (V2.9.9 - Standardized)

# --- [PATH SETUP] ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR" || exit 1

export MODE_WIFI_ROOT="$SCRIPT_DIR"
export MODE_WIFI_LOGS="$SCRIPT_DIR/logs"
export MODE_WIFI_LIB="$SCRIPT_DIR/lib"

export API_SERVER="121.173.150.103:5003"

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

        RESPONSE=$(curl -s "http://$API_SERVER/api/v1/request?device_id=$DEV_ID")
        
        [ -z "$RESPONSE" ] || [ "$(echo "$RESPONSE" | jq -r '.status')" != "ok" ] && continue

        LOG_ID=$(echo "$RESPONSE" | jq -r '.log_id')
        DEST_NAME=$(echo "$RESPONSE" | jq -r '.destination.name')
        FRIDA_PORT=$(echo "$RESPONSE" | jq -r '.port')
        
        echo "[🚀] [$DEV_ID] ALLOCATED: $DEST_NAME (Log:$LOG_ID)"

        # Pass ALL variables to the engine
        NMAP_API_RESPONSE="$RESPONSE" \
        NMAP_LOG_ID="$LOG_ID" \
        NMAP_TASK_ID="$LOG_ID" \
        NMAP_DEST_ID=$(echo "$RESPONSE" | jq -r '.destination.id') \
        NMAP_DEST_LAT=$(echo "$RESPONSE" | jq -r '.destination.lat') \
        NMAP_DEST_LNG=$(echo "$RESPONSE" | jq -r '.destination.lng') \
        NMAP_DEST_NAME="$DEST_NAME" \
        NMAP_START_LAT=$(echo "$RESPONSE" | jq -r '.destination.lat') \
        NMAP_START_LNG=$(echo "$RESPONSE" | jq -r '.destination.lng') \
        NMAP_FRIDA_PORT="$FRIDA_PORT" \
        NMAP_ORIG_SSAID=$(echo "$RESPONSE" | jq -r '.identity.original.ssaid') \
        setsid bash "$MODE_WIFI_LIB/main.sh" "$DEV_ID" >> "logs/${DEV_ID}/tmp/main_debug.log" 2>&1 &
        
        sleep 2
    done
    sleep 20
done
