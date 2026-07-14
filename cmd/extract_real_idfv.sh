#!/bin/bash
# cmd/extract_real_idfv.sh: Extractor for Real Original IDFV from Captured Logs
export PATH="$HOME/.local/bin:$PATH"

GREEN="\e[1;92m"
YELLOW="\e[1;93m"
CYAN="\e[1;96m"
NC="\e[0m"
BOLD="\e[1m"

echo -e "\n${BOLD}${CYAN}========================================================================${NC}"
echo -e "${BOLD}${CYAN}   🔍  Real Original IDFV Extractor (From Local Logs)                   ${NC}"
echo -e "${BOLD}${CYAN}========================================================================${NC}"
echo -e "   Scanning events.log for genuine IDFVs (iv=)... Please wait.\n"

LOGS_DIR="wifi_multi/logs"
if [ ! -d "$LOGS_DIR" ]; then
    echo -e "   ${YELLOW}[!] Logs directory not found.${NC}\n"
    exit 1
fi

printf "   %-3s | %-16s | %-36s\n" "No" "Device ID" "Actual Original IDFV"
echo "   ---------------------------------------------------------------------"

IDX=1
SQL_QUERIES=()

# Get device directories sorted
for DEV_DIR in $(find "$LOGS_DIR" -maxdepth 1 -type d | sort); do
    DEV_ID=$(basename "$DEV_DIR")
    [ "$DEV_ID" = "logs" ] && continue
    [ "$DEV_ID" = "tmp" ] && continue
    [ "$DEV_ID" = "FAKE1234" ] && continue
    [ "$DEV_ID" = "logs_sample" ] && continue
    [ "$DEV_ID" = "rotator_history" ] && continue
    [ "$DEV_ID" = "scratch" ] && continue
    
    # Find the most recent events.log containing "iv="
    REAL_IDFV=""
    # Scan up to 50 logs to find one with iv=
    LATEST_LOGS=$(find "$DEV_DIR" -name "events.log" -type f | sort -r | head -n 50)
    for LOG_FILE in $LATEST_LOGS; do
        # Extract iv parameter from events.log (matches UUID pattern)
        REAL_IDFV=$(grep -oE "[?&]iv=[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}" "$LOG_FILE" 2>/dev/null | head -n 1 | cut -d'=' -f2)
        if [ -n "$REAL_IDFV" ]; then
            break
        fi
    done
    
    if [ -z "$REAL_IDFV" ]; then
        REAL_IDFV="UNKNOWN (No logs with iv=)"
        printf "   %02d. %-16s | ${YELLOW}%-36s${NC}\n" "$IDX" "$DEV_ID" "$REAL_IDFV"
    else
        printf "   %02d. %-16s | ${GREEN}%-36s${NC}\n" "$IDX" "$DEV_ID" "$REAL_IDFV"
        SQL_QUERIES+=("UPDATE \`devices\` SET \`orig_idfv\`='$REAL_IDFV' WHERE \`device_id\`='$DEV_ID';")
    fi
    ((IDX++))
done
echo "   ---------------------------------------------------------------------"
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
