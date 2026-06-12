#!/usr/bin/env bash

# Get all connected devices
devices=$(adb devices | grep -v "List of devices attached" | grep -w "device" | awk '{print $1}')

if [ -z "$devices" ]; then
    echo "No devices connected."
    exit 0
fi

ACTION="disable"
if [ "$1" == "--on" ]; then
    ACTION="enable"
    echo "Enabling emergency alerts (cellbroadcast) on all connected devices..."
else
    echo "Disabling emergency alerts (cellbroadcast) on all connected devices..."
fi

PACKAGES=(
    "com.google.android.cellbroadcastreceiver"
    "com.google.android.cellbroadcastservice"
    "com.android.cellbroadcastreceiver"
    "com.android.cellbroadcastservice"
    "com.sec.android.emergencyalert"
)

for serial in $devices; do
    echo "=================================================="
    echo "[$serial] Processing Emergency Alert settings..."
    echo "=================================================="
    
    for pkg in "${PACKAGES[@]}"; do
        # Check if package exists on the device
        if timeout 5 adb -s "$serial" shell pm list packages | grep -q "$pkg"; then
            if [ "$ACTION" == "disable" ]; then
                echo -n "  -> Disabling $pkg ... "
                if timeout 5 adb -s "$serial" shell pm disable-user --user 0 "$pkg" >/dev/null 2>&1; then
                    echo "[OK]"
                else
                    echo "[FAILED]"
                fi
            else
                echo -n "  -> Enabling $pkg ... "
                if timeout 5 adb -s "$serial" shell pm enable "$pkg" >/dev/null 2>&1; then
                    echo "[OK]"
                else
                    echo "[FAILED]"
                fi
            fi
        fi
    done
done

echo "Done."
