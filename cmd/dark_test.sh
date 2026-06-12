#!/usr/bin/env bash

TARGET_DEVICES=("R5CR919ZL9A" "R5CRA0PW01W")

echo "Running dark mode test on target devices: ${TARGET_DEVICES[*]}"

for serial in "${TARGET_DEVICES[@]}"; do
    echo "=================================================="
    echo "Testing Device: $serial"
    echo "=================================================="
    
    # Check if device is connected
    if ! adb devices | grep -q -w "$serial"; then
        echo "[-] Device $serial is NOT connected via ADB!"
        continue
    fi
    
    # Helper function to run adb command with 5-second timeout
    run_with_timeout() {
        local desc="$1"
        shift
        echo -n "  -> Running: $desc ... "
        if timeout 5 adb -s "$serial" "$@" >/dev/null 2>&1; then
            echo "[OK]"
        else
            local status=$?
            if [ $status -eq 124 ]; then
                echo "[TIMEOUT (HUNG)]"
            else
                echo "[FAILED (Code $status)]"
            fi
        fi
    }

    # 1. Disable auto-brightness and set to 0
    run_with_timeout "Disable auto-brightness" shell settings put system screen_brightness_mode 0
    run_with_timeout "Set brightness to 0" shell settings put system screen_brightness 0
    
    # 2. Mute all volume streams
    for stream in 1 2 3 4 5; do
        run_with_timeout "Mute volume stream $stream" shell cmd media_session volume --stream $stream --set 0
    done
    
    # 3. Disable animations
    run_with_timeout "Disable window animation scale" shell settings put global window_animation_scale 0
    run_with_timeout "Disable transition animation scale" shell settings put global transition_animation_scale 0
    run_with_timeout "Disable animator duration scale" shell settings put global animator_duration_scale 0

    # 4. Enable Do Not Disturb (Zen Mode)
    run_with_timeout "Enable Zen Mode (DND)" shell settings put global zen_mode 1
done

echo "Test finished."
