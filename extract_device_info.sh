#!/bin/bash
# extract_device_info.sh - Extracts device_id, model, and IMEI for all connected ADB devices.

echo "====================================================="
echo "📱 Connected Devices Information Extractor"
echo "====================================================="
echo -e "Checking devices, please wait...\n"

# Header
printf "%-15s | %-12s | %-16s\n" "DEVICE_ID" "MODEL" "IMEI"
printf "%-15s-|-%-12s-|-%-16s\n" "---------------" "------------" "----------------"

# Get all connected devices
DEVICES=$(adb devices | grep -w "device" | awk '{print $1}')

if [ -z "$DEVICES" ]; then
    echo "No devices connected."
    exit 0
fi

for DEV_ID in $DEVICES; do
    # Get model
    MODEL=$(timeout 5 adb -s "$DEV_ID" shell getprop ro.product.model 2>/dev/null | tr -d '\r\n')
    [ -z "$MODEL" ] && MODEL="Unknown"
    
    # Get IMEI
    IMEI=$(timeout 5 adb -s "$DEV_ID" shell "su -c 'service call iphonesubinfo 1 s16 com.android.shell'" 2>/dev/null | grep -o "'.*'" | tr -d "'. \r\n")
    [ -z "$IMEI" ] && IMEI="Unknown/NoRoot"
    
    printf "%-15s | %-12s | %-16s\n" "$DEV_ID" "$MODEL" "$IMEI"
done
echo "====================================================="
