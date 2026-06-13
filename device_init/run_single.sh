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

# 1. Fetch Configuration from Connected Devices
# Get list of connected devices
CONNECTED_DEVICES=($(adb devices | grep -w "device" | awk '{print $1}'))
NUM_CONNECTED=${#CONNECTED_DEVICES[@]}

if [[ "$DEV_ID" =~ ^[0-9]+$ ]]; then
    DEV_INDEX=$((DEV_ID - 1))
    if [ $DEV_INDEX -lt 0 ] || [ $DEV_INDEX -ge $NUM_CONNECTED ]; then
        echo "[-] Invalid index: $DEV_ID (Only $NUM_CONNECTED devices connected)"
        exit 1
    fi
    DEV_ID=${CONNECTED_DEVICES[$DEV_INDEX]}
else
    # Check if the provided ID is in the connected list
    FOUND=false
    for d in "${CONNECTED_DEVICES[@]}"; do
        if [ "$d" == "$DEV_ID" ]; then FOUND=true; break; fi
    done
    if [ "$FOUND" = false ]; then
        echo "[-] Device $DEV_ID not connected or not found!"
        exit 1
    fi
    # Find index for port calculation
    for i in "${!CONNECTED_DEVICES[@]}"; do
        if [ "${CONNECTED_DEVICES[$i]}" == "$DEV_ID" ]; then DEV_INDEX=$i; break; fi
    done
fi

# Configuration based on dynamic index
BASE_MITM_PORT=30000
MITM_PORT=$((BASE_MITM_PORT + DEV_INDEX + 1))
FRIDA_PORT=$((MITM_PORT + 10000))

# Fetch Alias dynamically from device
ALIAS=$(adb -s "$DEV_ID" shell getprop ro.product.model | tr -d '\r')
ALIAS=${ALIAS#SM-}
if [ -z "$ALIAS" ]; then ALIAS="UnknownDevice"; fi

# 2. Export Identity (Default empty for Init)
export NMAP_ORIG_SSAID=""
export NMAP_ORIG_ADID=""
export NMAP_ORIG_IDFV=""
export NMAP_ORIG_NI=""
export NMAP_ORIG_TOKEN=""
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
    HAS_SU=$(adb -s "$DEV_ID" shell "which su" 2>/dev/null | tr -d '\r')
    if [ -z "$HAS_SU" ]; then
        HAS_SU=$(adb -s "$DEV_ID" shell "ls /system/bin/su /system/xbin/su /sbin/su 2>/dev/null" | head -1 | tr -d '\r')
    fi
    [ -z "$HAS_SU" ] && HAS_SU="su"
    adb -s "$DEV_ID" shell "$HAS_SU -c \"find /data/data/$PKG_NAME -mindepth 1 -maxdepth 1 ! -name 'lib' -exec rm -rf {} +\""
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

# 7. Frida Attach
adb -s "$DEV_ID" forward tcp:$FRIDA_PORT tcp:27042 >/dev/null 2>&1
FRIDA_LOG="$CAPTURE_LOG_DIR/frida.log"

# Start the application first
echo -e "${YELLOW}[$ALIAS] Starting app via monkey...${NC}"
adb -s "$DEV_ID" shell monkey -p "$PKG_NAME" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1

# Poll for the PID of the app
PID=""
for i in {1..10}; do
    PID=$(adb -s "$DEV_ID" shell pidof "$PKG_NAME" 2>/dev/null | awk '{print $1}' | tr -d '\r\n')
    [ -n "$PID" ] && break
    sleep 1
done

if [ -z "$PID" ]; then
    adb -s "$DEV_ID" shell monkey -p "$PKG_NAME" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
    sleep 3
    PID=$(adb -s "$DEV_ID" shell pidof "$PKG_NAME" 2>/dev/null | awk '{print $1}' | tr -d '\r\n')
fi

if [ -z "$PID" ]; then
    echo -e "${RED}[$ALIAS] ERROR: App failed to launch.${NC}"
    cleanup
fi

echo -e "${GREEN}[$ALIAS] App started with PID: $PID. Attaching Frida...${NC}"
nohup frida -H 127.0.0.1:$FRIDA_PORT --runtime=v8 -p "$PID" \
    -l lib/hooks/survival_light.js \
    -l lib/hooks/network_hook.js \
    -l lib/hooks/data_collector.js \
    --no-auto-reload > "$FRIDA_LOG" 2>&1 &
FRIDA_PID=$!

sleep 3

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

# 8. Wait for Data Capture and SQL Generation
echo -e "${YELLOW}[!] Monitoring for complete nlogapp capture...${NC}"

while true; do
    TARGET_FILE=$(find "$CAPTURE_LOG_DIR" -name "*POST_nlogapp.json" | head -n 1)
    if [ -n "$TARGET_FILE" ]; then
        # Ensure file is fully written
        sleep 1
        
        # Extract values using jq
        # Note: usr is inside .request.body
        ADID=$(jq -r '.request.body.usr.adid // empty' "$TARGET_FILE")
        SSAID=$(jq -r '.request.body.usr.ssaid // empty' "$TARGET_FILE")
        IDFV=$(jq -r '.request.body.usr.idfv // empty' "$TARGET_FILE")
        NI=$(jq -r '.request.body.usr.ni // empty' "$TARGET_FILE")
        
        # Token is the last part of nlog_id in evts[0]
        FULL_NLOG_ID=$(jq -r '.request.body.evts[0].nlog_id // empty' "$TARGET_FILE")
        TOKEN=$(echo "$FULL_NLOG_ID" | awk -F'.' '{print $NF}')
        
        # Check if ALL 4 IDs are present and not empty/null
        if [ -n "$ADID" ] && [ "$ADID" != "null" ] && \
           [ -n "$SSAID" ] && [ "$SSAID" != "null" ] && \
           [ -n "$IDFV" ] && [ "$IDFV" != "null" ] && \
           [ -n "$NI" ] && [ "$NI" != "null" ]; then
            
            echo -e "${GREEN}[✓] Complete Data Set Found: $(basename "$TARGET_FILE")${NC}"
            echo -e "\n${CYAN}--- GENERATED SQL QUERY ---${NC}"
            SQL="INSERT INTO \`devices\`(\`device_id\`, \`alias\`, \`orig_ssaid\`, \`orig_adid\`, \`orig_idfv\`, \`orig_ni\`, \`orig_token\`) VALUES ('$DEV_ID', '$ALIAS', '$SSAID', '$ADID', '$IDFV', '$NI', '$TOKEN');"
            echo -e "$SQL"
            echo -e "${CYAN}----------------------------${NC}\n"
            
            # Cumulative Log in device_init/logs/insert.txt
            mkdir -p "logs"
            echo "$SQL" >> "logs/insert.txt"
            echo -e "${YELLOW}[!] Query appended to: logs/insert.txt${NC}"
            
            # Auto-cleanup and exit
            cleanup
        else
            # Rename incomplete file so we don't check it again
            # echo -e "${YELLOW}[-] Incomplete data in $(basename "$TARGET_FILE"). Skipping...${NC}"
            mv "$TARGET_FILE" "${TARGET_FILE}.incomplete"
        fi
    fi
    sleep 2
done

# Wait for background processes or user interrupt (Fallback)
wait
