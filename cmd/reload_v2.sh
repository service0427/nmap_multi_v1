#!/usr/bin/env bash
# cmd/reload_v2.sh: Specialized Hot-Reloader for NMAP V2

TARGET=$1
DEVICES=$(adb devices | grep -v "List" | grep -w "device" | awk '{print $1}')
BASE_DIR="$(cd "$(dirname "$0")/../test_nmap_v2" && pwd)"

echo "========================================================"
echo "🚑 [V2 HOT-RELOAD] Injecting Real Paths from Packets..."
echo "========================================================"

for serial in $DEVICES; do
    if [ -n "$TARGET" ] && [ "$serial" != "$TARGET" ]; then continue; fi
    
    echo "[$serial] Searching for latest driving packet..."
    
    # Find the absolute latest driving JSON in the V2 log structure
    LATEST_JSON=$(ls -t $BASE_DIR/logs/$serial/20260417/*/*_GET_v3_global_driving.json 2>/dev/null | head -n 1)
    
    if [ -z "$LATEST_JSON" ]; then
        echo -e "\e[1;31m [!] No driving packet found for $serial. Skip.\e[0m"
        continue
    fi
    
    echo "    > Found: $(basename $LATEST_JSON)"
    python3 "$BASE_DIR/gps/reload_path.py" "$LATEST_JSON" "$serial"
done
