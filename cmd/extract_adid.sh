#!/bin/bash
# cmd/extract_adid.sh: Ultra-Fast Parallel Google ADID Extractor
export PATH="$HOME/.local/bin:$PATH"
adb() { timeout 5 /usr/bin/adb "$@"; }

# ANSI Colors for premium look
GREEN="\e[1;92m"
YELLOW="\e[1;93m"
CYAN="\e[1;96m"
NC="\e[0m"
BOLD="\e[1m"

echo -e "\n${BOLD}${CYAN}========================================================================${NC}"
echo -e "${BOLD}${CYAN}   🔍  Google Advertising ID (ADID) Parallel Extractor                  ${NC}"
echo -e "${BOLD}${CYAN}========================================================================${NC}"
echo -e "   Retrieving ADIDs from GMS databases... Please wait.\n"

# Get connected devices list
DEVICES=$(adb devices | grep -w "device" | awk '{print $1}')
if [ -z "$DEVICES" ]; then
    echo -e "   ${YELLOW}[!] No online devices detected.${NC}\n"
    exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Parallel execution loop
for DEV_ID in $DEVICES; do
    (
        # Read GMS adid_settings.xml and parse UUID
        ADID_RAW=$(adb -s "$DEV_ID" shell "su -c 'cat /data/data/com.google.android.gms/shared_prefs/adid_settings.xml' 2>/dev/null")
        ADID=$(echo "$ADID_RAW" | grep -oE "[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}" | head -n 1)
        
        if [ -z "$ADID" ]; then
            # Fallback check
            ADID_RAW_ALT=$(adb -s "$DEV_ID" shell "su -c 'grep -oP \"(?<=<string name=\\\"adid_key\\\">)[^<]+\" /data/data/com.google.android.gms/shared_prefs/adid_settings.xml' 2>/dev/null")
            ADID=$(echo "$ADID_RAW_ALT" | tr -d '\r\n ')
        fi
        
        if [ -z "$ADID" ]; then
            ADID="UNAVAILABLE"
        fi
        
        echo "$DEV_ID|$ADID" > "${TMP_DIR}/${DEV_ID}"
    ) &
done

# Wait for all background extractions to complete
wait

# Render Table
printf "   %-16s | %-36s\n" "Device ID" "Google ADID (Advertising ID)"
echo "   ---------------------------------------------------------------------"

# Sort results by device serial for readability
for DEV_ID in $(echo "$DEVICES" | sort); do
    if [ -f "${TMP_DIR}/${DEV_ID}" ]; then
        VAL=$(cat "${TMP_DIR}/${DEV_ID}")
        SERIAL=$(echo "$VAL" | cut -d'|' -f1)
        ADID_VAL=$(echo "$VAL" | cut -d'|' -f2)
        
        if [ "$ADID_VAL" = "UNAVAILABLE" ]; then
            printf "   %-16s | ${YELLOW}%-36s${NC}\n" "$SERIAL" "$ADID_VAL"
        else
            printf "   %-16s | ${GREEN}%-36s${NC}\n" "$SERIAL" "$ADID_VAL"
        fi
    fi
done
echo "   ---------------------------------------------------------------------"
echo -e "   Total: ${BOLD}$(echo "$DEVICES" | wc -l)${NC} devices verified.\n"
