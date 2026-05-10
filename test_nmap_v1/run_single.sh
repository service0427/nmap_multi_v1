#!/bin/bash
# test_nmap_v1: Minimal Single Device Launcher (Original Value Fetcher)

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$BASE_DIR" || exit 1

DEV_ID=$1
shift

if [ -z "$DEV_ID" ]; then
    echo "Usage: ./run_single.sh <DEVICE_ID/INDEX> [--id TARGET_ID]"
    exit 1
fi

# [V1.1] Hardcoded Defaults for Original Value Fetching
RESET_MODE=true
CLOSE_ON_EXIT=true
NO_FILTER="true"
TARGET_ID=""

# Minimal Argument Parsing (for Target ID only)
while [[ $# -gt 0 ]]; do
    case $1 in
        --id) TARGET_ID="$2"; shift 2 ;;
        *) shift ;;
    esac
done

PKG_NAME="com.nhn.android.nmap"
GPS_PKG="com.rosteam.gpsemulator"

# 0. Environment Setup
# Add common pip/python installation paths to PATH
export PATH=$PATH:/usr/local/bin:$HOME/.local/bin

# Robust command checking function
check_cmd() {
    if ! command -v "$1" &> /dev/null; then
        # Try finding in common python user bin if not in PATH
        if [ -f "$HOME/.local/bin/$1" ]; then
            export PATH="$PATH:$HOME/.local/bin"
        elif [ -f "/usr/local/bin/$1" ]; then
            export PATH="$PATH:/usr/local/bin"
        else
            return 1
        fi
    fi
    return 0
}

if ! check_cmd "mitmdump"; then echo -e "\e[1;31m[-] mitmdump not found. Try: pip3 install mitmproxy\e[0m"; exit 1; fi
if ! check_cmd "frida"; then echo -e "\e[1;31m[-] frida not found. Try: pip3 install frida-tools\e[0m"; exit 1; fi

CYAN="\e[1;36m"; GREEN="\e[1;32m"; YELLOW="\e[1;33m"; NC="\e[0m"

# 1. Fetch Configuration from devices.json
CONFIG_FILE="api/devices.json"
if [[ "$DEV_ID" =~ ^[0-9]+$ ]]; then
    DEV_INDEX="$DEV_ID"
    MAPPED_ID=$(jq -r ".devices[$DEV_INDEX].id // empty" "$CONFIG_FILE")
    if [ -n "$MAPPED_ID" ]; then DEV_ID="$MAPPED_ID"; else echo "[-] Invalid index: $DEV_ID"; exit 1; fi
else
    DEV_INDEX=$(jq -r ".devices | map(.id) | index(\"$DEV_ID\") // empty" "$CONFIG_FILE")
fi

DEV_JSON=$(jq -c ".devices[] | select(.id == \"$DEV_ID\")" "$CONFIG_FILE")
if [ -z "$DEV_JSON" ]; then echo "[-] Device $DEV_ID not found!"; exit 1; fi

BASE_MITM_PORT=$(jq -r '.base_mitm_port // 30000' "$CONFIG_FILE")
MITM_PORT=$((BASE_MITM_PORT + DEV_INDEX + 1))
ALIAS=$(echo "$DEV_JSON" | jq -r '.alias')
FRIDA_PORT=$((MITM_PORT + 10000))

# 2. Export Identity (Originals only)
export NMAP_ORIG_SSAID=$(echo "$DEV_JSON" | jq -r '.baseline.ssaid')
export NMAP_ORIG_ADID=$(echo "$DEV_JSON" | jq -r '.baseline.adid')
export NMAP_ORIG_IDFV=$(echo "$DEV_JSON" | jq -r '.baseline.idfv')
export NMAP_ORIG_NI=$(echo "$DEV_JSON" | jq -r '.baseline.ni')
export NMAP_ORIG_TOKEN=$(echo "$DEV_JSON" | jq -r '.baseline.token')
export NMAP_NO_FILTER="true"

echo "============================================================"
echo "   NMAP V1 ORIGINAL FETCH: $ALIAS ($DEV_ID)"
echo "   MITM:$MITM_PORT | FRIDA:$FRIDA_PORT | TARGET:${TARGET_ID:-None}"
echo "   Mode: Reset=ON, CloseOnExit=ON, Filtering=OFF"
echo "============================================================"

# 3. Setup Logs
DATE_STR=$(date +%Y%m%d); TIME_STR=$(date +%H%M%S)
LOG_DIR="logs/${DEV_ID}/${DATE_STR}/${TIME_STR}_original"
mkdir -p "$LOG_DIR"
export CAPTURE_LOG_DIR="$(realpath "$LOG_DIR")"

# 4. Cleanup & Purge
echo -e "${CYAN}[$ALIAS]${NC} Cleaning up and performing Data Purge..."
adb -s "$DEV_ID" shell am force-stop $PKG_NAME
adb -s "$DEV_ID" shell am force-stop $GPS_PKG
adb -s "$DEV_ID" shell settings put global http_proxy :0 2>/dev/null
pkill -f "mitmdump.*$MITM_PORT" 2>/dev/null

if [ "$RESET_MODE" = true ]; then
    adb -s "$DEV_ID" shell su -c "find /data/data/$PKG_NAME -mindepth 1 -maxdepth 1 ! -name 'lib' -exec rm -rf {} +"
fi

# 5. MITM Network proxy
echo -e "${CYAN}[$ALIAS]${NC} Setting up Proxy Tunnel (localhost:$MITM_PORT)..."
adb -s "$DEV_ID" reverse tcp:"$MITM_PORT" tcp:"$MITM_PORT" >/dev/null 2>&1
adb -s "$DEV_ID" shell settings put global http_proxy localhost:"$MITM_PORT"

MITM_LOG="$CAPTURE_LOG_DIR/mitm.log"
PYTHONWARNINGS=ignore nohup mitmdump -p "$MITM_PORT" -s lib/mitm_addon.py --ssl-insecure --listen-host 0.0.0.0 --set flow_detail=0 > "$MITM_LOG" 2>&1 &
MITM_PID=$!

# 6. GPS Setup (If target ID provided)
GPS_PID=""
if [ -n "$TARGET_ID" ]; then
    echo -e "${YELLOW}[$ALIAS] Initializing GPS Simulation for Target: $TARGET_ID${NC}"
    ./utils/run_gps_multi.sh "$DEV_ID" "$TARGET_ID" &
    GPS_PID=$!
    sleep 2
fi

# 7. Frida Spawn
adb -s "$DEV_ID" forward tcp:$FRIDA_PORT tcp:27042 >/dev/null 2>&1
FRIDA_LOG="$CAPTURE_LOG_DIR/frida.log"
nohup frida -H 127.0.0.1:$FRIDA_PORT --runtime=v8 -f "$PKG_NAME" \
    -l lib/hooks/survival_light.js \
    -l lib/hooks/network_hook.js \
    -l lib/hooks/data_collector.js \
    --no-auto-reload > "$FRIDA_LOG" 2>&1 &
FRIDA_PID=$!

(sleep 3; adb -s "$DEV_ID" shell monkey -p "$PKG_NAME" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1) &

echo -e "${GREEN}============================================================${NC}"
echo -e " [✓] [$ALIAS] SYSTEM READY. Original Value Logging..."
echo -e " [!] Log Directory: $CAPTURE_LOG_DIR"
echo -e "${GREEN}============================================================${NC}"

cleanup() {
    echo -e "\n${YELLOW}[$ALIAS] Stopping processes...${NC}"
    kill -9 $MITM_PID $FRIDA_PID $GPS_PID 2>/dev/null
    adb -s "$DEV_ID" shell am force-stop $PKG_NAME
    adb -s "$DEV_ID" shell settings put global http_proxy :0 2>/dev/null
    adb -s "$DEV_ID" reverse --remove-all 2>/dev/null
    adb -s "$DEV_ID" forward --remove-all 2>/dev/null
    exit 0
}
trap cleanup INT TERM

# 8. Wait for manual termination
echo -e "${YELLOW}[!] Session is active. Perform manual actions now.${NC}"
echo -e "${YELLOW}[!] Press Ctrl+C to stop and cleanup.${NC}"

# Wait for background processes or user interrupt
wait
