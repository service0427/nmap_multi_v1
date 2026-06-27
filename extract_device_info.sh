#!/bin/bash
# extract_device_info.sh - Extracts device_id, model, and IMEI for all connected ADB devices.

HOSTNAME_VAL=$(hostname 2>/dev/null | tr -d '\r\n')
[ -z "$HOSTNAME_VAL" ] && HOSTNAME_VAL="UnknownHost"

# Header
echo -e "NO\tHOSTNAME\tDEVICE_ID\tMODEL\tIMEI"

# Get all connected devices
DEVICES=$(adb devices | grep -w "device" | awk '{print $1}')

if [ -z "$DEVICES" ]; then
    exit 0
fi

COUNT=1
for DEV_ID in $DEVICES; do
    # Get model
    MODEL=$(timeout 5 adb -s "$DEV_ID" shell getprop ro.product.model 2>/dev/null | tr -d '\r\n')
    [ -z "$MODEL" ] && MODEL="Unknown"
    
    # Get IMEI
    IMEI=$(timeout 5 adb -s "$DEV_ID" shell "su -c 'service call iphonesubinfo 1 s16 com.android.shell'" 2>/dev/null | grep -o "'.*'" | tr -d "'. \r\n")
    [ -z "$IMEI" ] && IMEI="Unknown/NoRoot"
    
    printf "%02d\t%s\t%s\t%s\t%s\n" "$COUNT" "${HOSTNAME_VAL}" "${DEV_ID}" "${MODEL}" "${IMEI}"
    COUNT=$((COUNT + 1))
done
