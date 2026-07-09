#!/bin/bash

# --- [SAFETY ROOT CHECK] ---
if [ "$EUID" -ne 0 ]; then
    echo "[🚨] Error: This script must be run with root privileges. Please use 'sudo'."
    exit 1
fi

TECH_USER="tech"
TECH_ANDROID_DIR="/home/$TECH_USER/.android"
ROOT_ANDROID_DIR="/root/.android"

echo "============================================================"
echo " Starting ADB Key Synchronization & Device Hardware Recovery "
echo "============================================================"

# 1. Sync tech user's keys to root account
if [ -f "$TECH_ANDROID_DIR/adbkey" ] && [ -f "$TECH_ANDROID_DIR/adbkey.pub" ]; then
    echo "[*] Synchronizing ADB keys from $TECH_USER to root account..."
    mkdir -p "$ROOT_ANDROID_DIR"
    cp "$TECH_ANDROID_DIR/adbkey" "$ROOT_ANDROID_DIR/adbkey"
    cp "$TECH_ANDROID_DIR/adbkey.pub" "$ROOT_ANDROID_DIR/adbkey.pub"
    chmod 600 "$ROOT_ANDROID_DIR/adbkey"
    chmod 644 "$ROOT_ANDROID_DIR/adbkey.pub"
    echo "[✓] ADB keys synchronized successfully."
else
    echo "[⚠️] Warning: Tech user's ADB keys not found at $TECH_ANDROID_DIR."
fi

# 2. Get list of attached devices
DEVICES=$(adb devices | grep -w "device" | awk '{print $1}')
if [ -z "$DEVICES" ]; then
    echo "[⚠️] No active devices detected via ADB. Exiting."
    exit 0
fi

echo "[*] Found $(echo "$DEVICES" | wc -w) devices. Commencing recovery loop..."

for dev in $DEVICES; do
    echo "------------------------------------------------------------"
    echo " Processing Device: $dev"
    
    # A. Push common adbkey.pub to device and append to adb_keys
    echo "  -> Injecting shared public key to device adb_keys..."
    adb -s "$dev" push "$TECH_ANDROID_DIR/adbkey.pub" /data/local/tmp/new_adbkey.pub >/dev/null 2>&1
    adb -s "$dev" shell "su -c 'cat /data/local/tmp/new_adbkey.pub >> /data/misc/adb/adb_keys && chmod 640 /data/misc/adb/adb_keys && chown system:shell /data/misc/adb/adb_keys && rm -f /data/local/tmp/new_adbkey.pub'" >/dev/null 2>&1
    
    # B. Restart adbd daemon inside the device to reload keys
    echo "  -> Restarting adbd daemon on device..."
    adb -s "$dev" shell "su -c 'stop adbd && start adbd'" >/dev/null 2>&1
    
    # C. Perform physical USB unbind to force session refresh
    RESET_DONE=false
    for d in /sys/bus/usb/devices/*; do
        if [ -f "$d/serial" ]; then
            serial=$(cat "$d/serial" 2>/dev/null)
            if [ "$serial" = "$dev" ]; then
                usb_path=$(basename "$d")
                echo "  -> Triggering hardware USB reset on port: $usb_path"
                echo "$usb_path" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null
                RESET_DONE=true
                break
            fi
        fi
    done
    
    if [ "$RESET_DONE" = true ]; then
        echo "  [✓] Device $dev successfully recovered."
    else
        echo "  [⚠️] USB port for $dev not found in sysfs."
    fi
done

echo "============================================================"
echo " Recovery complete. All devices have been synchronized and reset."
echo "============================================================"
