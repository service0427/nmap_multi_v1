#!/bin/bash
# cmd/extract_real_idfv.sh: Extractor for Real Original IDFV from Captured Logs
export PATH="$HOME/.local/bin:$PATH"

GREEN="\e[1;92m"
YELLOW="\e[1;93m"
CYAN="\e[1;96m"
NC="\e[0m"
BOLD="\e[1m"

TARGET_DEVICE="$1"

echo -e "\n${BOLD}${CYAN}========================================================================${NC}"
echo -e "${BOLD}${CYAN}   🔍  Real Original IDFV Extractor (From Active ADB Devices)           ${NC}"
echo -e "${BOLD}${CYAN}========================================================================${NC}"

# Get active connected devices via ADB
CONNECTED_DEVICES=$(adb devices | grep -v "List of devices attached" | grep -w "device" | awk '{print $1}')

if [ -z "$CONNECTED_DEVICES" ]; then
    echo -e "   ${YELLOW}[!] No connected ADB devices found.${NC}\n"
    exit 1
fi

if [ -n "$TARGET_DEVICE" ]; then
    # Verify target device is actually online
    if ! echo "$CONNECTED_DEVICES" | grep -q -w "$TARGET_DEVICE"; then
        echo -e "   ${YELLOW}[!] Target device $TARGET_DEVICE is offline or not connected.${NC}\n"
        exit 1
    fi
    DEVICES_TO_SCAN="$TARGET_DEVICE"
    echo -e "   Scanning logs for Active Device: ${BOLD}${YELLOW}${TARGET_DEVICE}${NC} (iv=)... Please wait.\n"
else
    DEVICES_TO_SCAN="$CONNECTED_DEVICES"
    echo -e "   Scanning logs for active connected devices (iv=)... Please wait.\n"
fi

INIT_LOGS_DIR="device_init/logs"
RUN_LOGS_DIR="wifi_multi/logs"

printf "   %-3s | %-16s | %-36s | %-10s\n" "No" "Device ID" "Actual Original IDFV" "Source"
echo "   ----------------------------------------------------------------------------------------"

IDX=1
SQL_QUERIES=()

# Scan only active connected devices
for DEV_ID in $DEVICES_TO_SCAN; do
    REAL_IDFV=""
    LOG_SOURCE=""

    # 1. 1st Priority: Scan device initialization origin packet logs (device_init/logs)
    INIT_DEV_DIR="$INIT_LOGS_DIR/$DEV_ID"
    if [ -d "$INIT_DEV_DIR" ]; then
        # Search all_packets.jsonl, mitm.log, or *.json files
        LATEST_INIT_LOGS=$(find "$INIT_DEV_DIR" -type f \( -name "all_packets.jsonl" -o -name "mitm.log" -o -name "*.json" \) | sort -r | head -n 50)
        for LOG_FILE in $LATEST_INIT_LOGS; do
            REAL_IDFV=$(grep -oE "[?&]iv=[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}" "$LOG_FILE" 2>/dev/null | head -n 1 | cut -d'=' -f2)
            if [ -n "$REAL_IDFV" ]; then
                LOG_SOURCE="Init Logs"
                break
            fi
        done
    fi

    # 2. 2nd Priority (Fallback): Scan real-time simulator runtime logs (wifi_multi/logs)
    RUN_DEV_DIR="$RUN_LOGS_DIR/$DEV_ID"
    if [ -z "$REAL_IDFV" ] && [ -d "$RUN_DEV_DIR" ]; then
        LATEST_RUN_LOGS=$(find "$RUN_DEV_DIR" -name "events.log" -type f | sort -r | head -n 50)
        for LOG_FILE in $LATEST_RUN_LOGS; do
            REAL_IDFV=$(grep -oE "[?&]iv=[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}" "$LOG_FILE" 2>/dev/null | head -n 1 | cut -d'=' -f2)
            if [ -n "$REAL_IDFV" ]; then
                LOG_SOURCE="Run Logs"
                break
            fi
        done
    fi
    
    # Render Output
    if [ -z "$REAL_IDFV" ]; then
        REAL_IDFV="UNKNOWN (No logs with iv=)"
        printf "   %02d. %-16s | ${YELLOW}%-36s${NC} | %-10s\n" "$IDX" "$DEV_ID" "$REAL_IDFV" "N/A"
    else
        printf "   %02d. %-16s | ${GREEN}%-36s${NC} | %-10s\n" "$IDX" "$DEV_ID" "$REAL_IDFV" "$LOG_SOURCE"
        SQL_QUERIES+=("UPDATE \`devices\` SET \`orig_idfv\`='$REAL_IDFV' WHERE \`device_id\`='$DEV_ID';")
    fi
    ((IDX++))
done
echo "   ----------------------------------------------------------------------------------------"
echo -e "   Scan completed.\n"

# Output aggregated SQL Query Block at the very end
if [ ${#SQL_QUERIES[@]} -gt 0 ]; then
    echo -e "${BOLD}${CYAN}   📋  Generated SQL UPDATE Queries (Copy Block):${NC}"
    echo "   ====================================================================="
    for query in "${SQL_QUERIES[@]}"; do
        echo -e "   $query"
    done
    echo "   ====================================================================="
    echo ""
fi
