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

# 폰이 현재 잡고 있는 Wi-Fi SSID를 기반으로 LTE 모뎀 번호 추출
get_modem_idx_from_ssid() {
    local dev_id=$1
    local ssid=""
    
    # 1. dumpsys netstats 방식 시도
    ssid=$(adb -s "$dev_id" shell dumpsys netstats 2>/dev/null | grep -E 'iface=wlan0' | grep -oE 'networkId="[^"]+"' | head -n 1 | cut -d'"' -f2)
    
    # 2. 실패 시 cmd wifi status 방식 시도
    if [ -z "$ssid" ]; then
        ssid=$(adb -s "$dev_id" shell "cmd wifi status" 2>/dev/null | grep -oE 'SSID: "[^"]+"' | head -n 1 | cut -d'"' -f2)
    fi

    # 끝의 숫자 2자리 이상 추출 (예: U26-K01-11 -> 11)
    local idx=$(echo "$ssid" | grep -oE '[0-9]+$' | sed 's/^0//')
    echo "$idx"
}

while true; do
    DEVICES=$(timeout 5 adb devices | grep -w "device" | awk '{print $1}')
    [ -z "$DEVICES" ] && sleep 10 && continue

    echo "------------------------------------------------------------"
    echo "[$(date +%T)] Scanning $(echo $DEVICES | wc -w) devices..."

    for DEV_ID in $DEVICES; do
        # Enhanced process check to prevent double allocation
        if pgrep -f "main.sh $DEV_ID" > /dev/null; then 
            continue
        fi

        # SSID 기반 모뎀 번호 추출
        MODEM_IDX=$(get_modem_idx_from_ssid "$DEV_ID")
        
        if [ -n "$MODEM_IDX" ] && [ "$MODEM_IDX" -ge 11 ]; then
            BIND_IP=$(get_ip "lte$MODEM_IDX")
            # echo "[#] [$DEV_ID] SSID matches lte$MODEM_IDX -> IP: $BIND_IP"
        else
            echo "[!] [$DEV_ID] Failed to determine modem from SSID. Check Wi-Fi."
            continue
        fi

        if [ -z "$BIND_IP" ]; then
            echo "[!] Skipping $DEV_ID: Modem lte$MODEM_IDX not ready (No IP)."
            continue
        fi

        RESPONSE=$(curl -s -X POST "http://$API_SERVER/api/v1/request_task" \
             -H "Content-Type: application/json" \
             -d "{\"device_id\":\"$DEV_ID\"}")
        
        if [ -z "$RESPONSE" ] || [ "$(echo "$RESPONSE" | jq -r '.status')" != "ok" ]; then
            continue
        fi

        TASK_ID=$(echo "$RESPONSE" | jq -r '.task_id')
        DEST_NAME=$(echo "$RESPONSE" | jq -r '.destination.target_name')
        FRIDA_PORT=$((6000 + $(echo "$DEV_ID" | cksum | awk '{print $1 % 1000}')))
        
        echo "[🚀] [$DEV_ID] ALLOCATED: $DEST_NAME (Task:$TASK_ID) -> Modem lte$MODEM_IDX ($BIND_IP)"

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
        
        sleep 5
    done
    sleep 30
done
