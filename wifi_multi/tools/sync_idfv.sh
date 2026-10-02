#!/bin/bash
# Standalone tool to sync local device IDFV with API server DB

API_SERVER="${API_SERVER:-114.207.112.245:8013}"
SPECIFIC_DEV="$1"

if [ -n "$SPECIFIC_DEV" ]; then
    DEVICES="$SPECIFIC_DEV"
else
    DEVICES=$(timeout 5 adb devices | grep -w "device" | awk '{print $1}')
fi

TOTAL=$(echo "$DEVICES" | wc -w)
echo "============================================================"
echo "[$(date +%T)] Starting IDFV Sync for $TOTAL devices..."
echo "API Server: http://$API_SERVER/api/v1/update_idfv"
echo "============================================================"

UPDATED_COUNT=0
MATCH_COUNT=0
FAIL_COUNT=0

sync_one() {
    local DEV_ID=$1
    local LOCAL_IDFV=$(timeout 3 adb -s "$DEV_ID" shell "su -c 'cat /data/data/com.google.android.gms/files/appset/shared/pvids.pb'" 2>/dev/null | grep -a -A 2 "com.nhn.android.nmap" | grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | head -n 1)
    
    if [ -z "$LOCAL_IDFV" ]; then
        echo "[❌ FAIL] [$DEV_ID] Could not extract IDFV from pvids.pb"
        return 1
    fi
    
    local RES=$(curl -s "http://$API_SERVER/api/v1/update_idfv?device_id=$DEV_ID&idfv=$LOCAL_IDFV")
    local OLD_IDFV=$(echo "$RES" | jq -r '.old_idfv // empty' 2>/dev/null)
    local NEW_IDFV=$(echo "$RES" | jq -r '.new_idfv // empty' 2>/dev/null)
    
    if [ -n "$OLD_IDFV" ] && [ -n "$NEW_IDFV" ]; then
        if [ "$OLD_IDFV" != "$NEW_IDFV" ]; then
            echo "[🔄 UPDATED] [$DEV_ID] Local IDFV ($LOCAL_IDFV) != DB ($OLD_IDFV). DB updated successfully."
            return 2
        else
            echo "[✅ MATCH]   [$DEV_ID] Local IDFV ($LOCAL_IDFV) matches DB."
            return 0
        fi
    else
        echo "[⚠️ ERROR]  [$DEV_ID] API call failed: $RES"
        return 1
    fi
}

for DEV_ID in $DEVICES; do
    sync_one "$DEV_ID"
    ret=$?
    if [ $ret -eq 2 ]; then
        UPDATED_COUNT=$((UPDATED_COUNT + 1))
    elif [ $ret -eq 0 ]; then
        MATCH_COUNT=$((MATCH_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

echo "============================================================"
echo "[SUMMARY] Total: $TOTAL | Updated: $UPDATED_COUNT | In-Sync: $MATCH_COUNT | Failed: $FAIL_COUNT"
echo "============================================================"
