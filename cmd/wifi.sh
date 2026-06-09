#!/usr/bin/env bash

# Resolve script directory
CMD_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Target SSID from argument (optional)
TARGET_SSID=$1

# Get all connected devices
devices=$(adb devices | grep -v "List of devices attached" | grep -w "device" | awk '{print $1}')

if [ -z "$devices" ]; then
    echo "No devices connected."
    exit 0
fi

# Enable Wi-Fi on all devices first so we can scan properly
for serial in $devices; do
    (
        wifi_status=$(adb -s "$serial" shell "cmd wifi status" 2>/dev/null | grep "Wifi is" | tr -d '\r')
        if [[ "$wifi_status" == *"disabled"* ]]; then
            echo "[$serial] Wi-Fi is disabled. Enabling temporarily to scan..."
            adb -s "$serial" shell "cmd wifi set-wifi-enabled enabled" >/dev/null 2>&1
            sleep 1
        fi
    ) &
done
wait

echo "Scanning Wi-Fi networks on all connected devices..."
for serial in $devices; do
    adb -s "$serial" shell "cmd wifi start-scan" >/dev/null 2>&1 &
done
wait
sleep 2

chosen_ssid=""

if [ -z "$TARGET_SSID" ]; then
    # Gather all unique SSIDs starting with "Moon" or "U26-"
    ssids=()
    while IFS= read -r line; do
        ssid=$(echo "$line" | xargs)
        if [ -n "$ssid" ] && [ "$ssid" != "SSID" ] && [ "$ssid" != "null" ]; then
            ssids+=("$ssid")
        fi
    done < <(
        for serial in $devices; do
            adb -s "$serial" shell "cmd wifi list-scan-results" 2>/dev/null | awk 'NR>1 {
                ssid=""
                for (i=5; i<=NF; i++) {
                    if ($i ~ /^\[/) break;
                    if (ssid == "") ssid = $i;
                    else ssid = ssid " " $i;
                }
                if (ssid != "" && ssid != "SSID") print ssid;
            }'
        done | sort -u | grep -E '^(Moon|U26-)'
    )

    num_ssids=${#ssids[@]}
    if [ $num_ssids -eq 0 ]; then
        echo "No matching Wi-Fi networks (starting with Moon or U26-) found."
        exit 0
    fi

    # Determine default option based on current PC hostname
    host_name=$(hostname 2>/dev/null | tr -d '\r\n')
    default_idx=""

    echo -e "\n========================================================================="
    echo -e "Available Wi-Fi Networks (Filtered):"
    echo -e "========================================================================="
    for i in "${!ssids[@]}"; do
        is_default=""
        # Check if SSID contains the host PC name
        if [ -n "$host_name" ] && [[ "${ssids[$i]}" == *"$host_name"* ]]; then
            is_default=" * (Default)"
            default_idx=$((i+1))
        fi
        printf "  %2d) %s%s\n" $((i+1)) "${ssids[$i]}" "$is_default"
    done
    echo -e "========================================================================="

    # Ask user to select a Wi-Fi (reading from terminal device to support interactive TTY)
    while true; do
        if [ -n "$default_idx" ]; then
            read -p "Select a Wi-Fi network number to connect (1-$num_ssids) [Default: $default_idx]: " selection < /dev/tty
            # Use default option if user simply presses Enter
            if [ -z "$selection" ]; then
                selection=$default_idx
            fi
        else
            read -p "Select a Wi-Fi network number to connect (1-$num_ssids): " selection < /dev/tty
        fi

        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "$num_ssids" ]; then
            chosen_ssid="${ssids[$((selection-1))]}"
            break
        else
            echo "Invalid selection. Please enter a number between 1 and $num_ssids."
        fi
    done
else
    chosen_ssid="$TARGET_SSID"
fi

echo -e "\nConnecting all devices to Wi-Fi SSID: \e[1;32m$chosen_ssid\e[0m (Password: 13241324)..."

# Step A. Forget existing networks & trigger connect in parallel
for serial in $devices; do
    (
        echo "[$serial] Initializing Wi-Fi switch..."
        # Enable Wi-Fi if disabled
        adb -s "$serial" shell "cmd wifi set-wifi-enabled enabled" >/dev/null 2>&1
        
        # Disable captive portal checks to minimize popup chances
        adb -s "$serial" shell "settings put global captive_portal_mode 0" >/dev/null 2>&1
        adb -s "$serial" shell "settings put global captive_portal_detection_enabled 0" >/dev/null 2>&1
        
        # Check root authorization with a non-blocking timeout
        has_su=false
        has_su_cmd=$(adb -s "$serial" shell "which su" 2>/dev/null | tr -d '\r')
        if [ -n "$has_su_cmd" ]; then
            su_test=$(timeout 3 adb -s "$serial" shell "su -c 'id'" 2>/dev/null | tr -d '\r')
            if [[ "$su_test" == *"uid=0"* ]]; then
                has_su=true
            fi
        fi

        if [ "$has_su" = "true" ]; then
            # Forget all saved networks to clear auto-connect records (as requested)
            net_ids=$(adb -s "$serial" shell "cmd wifi list-networks" 2>/dev/null | awk 'NR>1 {print $1}' | sort -u | tr -d '\r')
            for net_id in $net_ids; do
                if [[ "$net_id" =~ ^[0-9]+$ ]]; then
                    echo "[$serial] Forgetting saved network ID: $net_id"
                    adb -s "$serial" shell "cmd wifi forget-network $net_id" >/dev/null 2>&1 || true
                fi
            done
            
            # Remove suggestions too
            adb -s "$serial" shell "cmd wifi remove-all-suggestions" >/dev/null 2>&1 || true
            
            # Wait a brief moment before connecting
            sleep 1
            
            # Connect to new network (needs root su execution for connect-network)
            echo "[$serial] Connecting to '$chosen_ssid'..."
            adb -s "$serial" shell "su -c 'cmd wifi connect-network \"$chosen_ssid\" wpa2 13241324'" >/dev/null 2>&1
        else
            echo -e "\e[1;31m[$serial] [⚠️] Root (su) permission check failed or pending. Skipping connection switch.\e[0m"
        fi
    ) &
done

# Wait for connection triggers to complete
wait

# Step B. Poll for connection state and run the UI Clicker helper in a loop
echo "Waiting for connection to establish and handling potential UI prompts..."
for i in {1..5}; do
    sleep 3
    # Check connection status and run clicker for each device
    for serial in $devices; do
        # Run UI clicker to handle "Always connect / Keep connection" popup
        python3 "$CMD_DIR/wifi_clicker.py" "$serial"
    done
done

# Step C. Final Verification of connected network
echo -e "\n============================================="
echo -e "Final Wi-Fi Connection Status"
echo -e "============================================="
for serial in $devices; do
    current_status=$(adb -s "$serial" shell "cmd wifi status" 2>/dev/null | grep -E "SSID|Wifi is" | tr -d '\r\n')
    echo -e "[$serial]: $current_status"
done
