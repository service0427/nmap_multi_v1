#!/usr/bin/env bash

echo "Applying normal/light mode to all connected devices..."

# Get all connected devices
devices=$(adb devices | grep -v "List of devices attached" | grep -w "device" | awk '{print $1}')

if [ -z "$devices" ]; then
    echo "No devices connected."
    exit 0
fi

for serial in $devices; do
    echo "[$serial] Restoring light mode (Brightness 127, Unmute, Zen Mode OFF, Animations ON)..."
    
    # 1. Enable auto-brightness mode and set manual brightness to 127 (medium)
    adb -s "$serial" shell settings put system screen_brightness_mode 1
    adb -s "$serial" shell settings put system screen_brightness 127
    
    # 2. Reset volume streams (System=7, Ring=7, Music=7, Alarm=7, Notification=7)
    for stream in 1 2 3 4 5; do
        adb -s "$serial" shell cmd media_session volume --stream $stream --set 7 >/dev/null 2>&1 || true
    done
    
    # 3. Restore animation scales (1.0)
    adb -s "$serial" shell settings put global window_animation_scale 1
    adb -s "$serial" shell settings put global transition_animation_scale 1
    adb -s "$serial" shell settings put global animator_duration_scale 1

    # 4. Disable Do Not Disturb (Zen Mode 0)
    adb -s "$serial" shell settings put global zen_mode 0 >/dev/null 2>&1 || true
done

echo "Done. All devices are now in normal/light mode."
