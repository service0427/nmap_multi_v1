#!/usr/bin/env bash

# Resolve script directory
CMD_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Parse arguments
TARGET_SSID=""
SELECTED_DEVICES_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--serial|--device)
            SELECTED_DEVICES_ARG="$2"
            shift 2
            ;;
        *)
            if [ -z "$TARGET_SSID" ]; then
                TARGET_SSID="$1"
            fi
            shift
            ;;
    esac
done

# Get all connected devices
all_devices=($(adb devices | grep -v "List of devices attached" | grep -w "device" | awk '{print $1}'))

if [ ${#all_devices[@]} -eq 0 ]; then
    echo "No devices connected."
    exit 0
fi

# Function to get current SSID of a device
get_current_ssid() {
    local serial=$1
    adb -s "$serial" shell "cmd wifi status" 2>/dev/null | grep "SSID:" | head -1 | sed -E 's/.*SSID: "([^"]+)".*/\1/' | tr -d '\r\n'
}

# --- Phase 1: Wi-Fi SSID Selection ---
chosen_ssid=""
if [ -z "$TARGET_SSID" ]; then
    # Use up to 3 connected devices to scan Wi-Fi in parallel (helps bypass local congestion/interference)
    scanners=()
    for i in "${!all_devices[@]}"; do
        if [ $i -lt 3 ]; then
            scanners+=("${all_devices[$i]}")
        fi
    done

    echo -e "\n[*] Scanning Wi-Fi networks using ${#scanners[@]} devices in parallel (${scanners[*]})..."
    
    for serial in "${scanners[@]}"; do
        wifi_status=$(adb -s "$serial" shell "cmd wifi status" 2>/dev/null | grep "Wifi is" | tr -d '\r')
        if [[ "$wifi_status" == *"disabled"* ]]; then
            adb -s "$serial" shell "cmd wifi set-wifi-enabled enabled" >/dev/null 2>&1
        fi
        adb -s "$serial" shell "cmd wifi start-scan" >/dev/null 2>&1 &
    done
    wait
    sleep 5

    # Gather all unique SSIDs starting with "Moon" or "U26-" from all scanning devices
    ssids=()
    raw_ssids=""
    for serial in "${scanners[@]}"; do
        device_ssids=$(adb -s "$serial" shell "cmd wifi list-scan-results" 2>/dev/null | awk 'NR>1 {
            ssid=""
            for (i=5; i<=NF; i++) {
                if ($i ~ /^\[/) break;
                if (ssid == "") ssid = $i;
                else ssid = ssid " " $i;
            }
            if (ssid != "" && ssid != "SSID") print ssid;
        }')
        raw_ssids+=$'\n'"$device_ssids"
    done

    while IFS= read -r line; do
        ssid=$(echo "$line" | xargs)
        if [ -n "$ssid" ] && [ "$ssid" != "SSID" ] && [ "$ssid" != "null" ]; then
            ssids+=("$ssid")
        fi
    done < <(echo "$raw_ssids" | sort -u | grep -E '^(Moon|U26-)')

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
        if [ -n "$host_name" ] && [[ "${ssids[$i]}" == *"$host_name"* ]]; then
            is_default=" * (Default)"
            default_idx=$((i+1))
        fi
        printf "  %2d) %s%s\n" $((i+1)) "${ssids[$i]}" "$is_default"
    done
    echo -e "========================================================================="

    while true; do
        if [ -n "$default_idx" ]; then
            read -p "Select a Wi-Fi network number (1-$num_ssids) [Default: $default_idx]: " selection < /dev/tty
            if [ -z "$selection" ]; then selection=$default_idx; fi
        else
            read -p "Select a Wi-Fi network number (1-$num_ssids): " selection < /dev/tty
        fi

        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "$num_ssids" ]; then
            chosen_ssid="${ssids[$((selection-1))]}"
            break
        else
            echo "Invalid selection."
        fi
    done
else
    chosen_ssid="$TARGET_SSID"
fi

# --- Phase 2: Device Selection ---
devices_to_process=()
if [ -n "$SELECTED_DEVICES_ARG" ]; then
    IFS=', ' read -ra ADDR <<< "$SELECTED_DEVICES_ARG"
    devices_to_process=("${ADDR[@]}")
else
    if [ ${#all_devices[@]} -gt 1 ]; then
        echo -e "\n========================================================================="
        echo -e "Target devices for Wi-Fi SSID: \e[1;32m$chosen_ssid\e[0m"
        echo -e "========================================================================="
        echo "  0) All Devices (Default)"

        # Fetch current SSIDs in parallel
        tmp_ssids=$(mktemp)
        for s in "${all_devices[@]}"; do
            (
                curr_s=$(get_current_ssid "$s")
                echo "$s:$curr_s" >> "$tmp_ssids"
            ) &
        done
        wait

        declare -A dev_ssids
        while IFS=: read -r serial_key ssid_val; do
            dev_ssids["$serial_key"]="$ssid_val"
        done < "$tmp_ssids"
        rm -f "$tmp_ssids"

        for i in "${!all_devices[@]}"; do
            current_s="${dev_ssids[${all_devices[$i]}]}"
            
            # Display current SSID if it exists, otherwise 'Disconnected'
            display_ssid=$current_s
            if [ -z "$display_ssid" ]; then display_ssid="Disconnected"; fi
            
            status_mark=""
            if [ "$current_s" == "$chosen_ssid" ]; then
                status_mark=" \e[1;32m*\e[0m"
            fi
            
            printf "  %2d) %s (%s)%b\n" $((i+1)) "${all_devices[$i]}" "$display_ssid" "$status_mark"
        done
        echo -e "========================================================================="
        
        read -p "Select device number(s) (e.g., 0, 1, 1,3) [Default: 0]: " dev_selection < /dev/tty
        if [[ "$dev_selection" == "0" ]] || [ -z "$dev_selection" ]; then
            devices_to_process=("${all_devices[@]}")
        else
            IFS=', ' read -ra ADDR <<< "$dev_selection"
            for i in "${ADDR[@]}"; do
                idx=$((i-1))
                if [ $idx -ge 0 ] && [ $idx -lt ${#all_devices[@]} ]; then
                    devices_to_process+=("${all_devices[$idx]}")
                fi
            done
        fi
    else
        devices_to_process=("${all_devices[@]}")
    fi
fi

# Final list of devices, skipping those already connected
final_devices=()
tmp_ssids_final=$(mktemp)
for serial in "${devices_to_process[@]}"; do
    (
        curr_s=$(get_current_ssid "$serial")
        echo "$serial:$curr_s" >> "$tmp_ssids_final"
    ) &
done
wait

declare -A dev_ssids_final
while IFS=: read -r serial_key ssid_val; do
    dev_ssids_final["$serial_key"]="$ssid_val"
done < "$tmp_ssids_final"
rm -f "$tmp_ssids_final"

for serial in "${devices_to_process[@]}"; do
    current_s="${dev_ssids_final[$serial]}"
    if [ "$current_s" == "$chosen_ssid" ]; then
        echo -e "[$serial] Already connected to '$chosen_ssid'. \e[1;30mSkipping.\e[0m"
    else
        final_devices+=("$serial")
    fi
done

if [ ${#final_devices[@]} -eq 0 ]; then
    echo "No devices need updating."
    exit 0
fi

echo -e "\nConnecting devices to Wi-Fi SSID: \e[1;32m$chosen_ssid\e[0m (Password: 13241324)..."

# Step A. Forget existing networks & trigger connect in parallel
for serial in "${final_devices[@]}"; do
    (
        echo "[$serial] Initializing Wi-Fi switch..."
        adb -s "$serial" shell "cmd wifi set-wifi-enabled enabled" >/dev/null 2>&1
        adb -s "$serial" shell "settings put global captive_portal_mode 0" >/dev/null 2>&1
        adb -s "$serial" shell "settings put global captive_portal_detection_enabled 0" >/dev/null 2>&1
        
        has_su=false
        has_su_cmd=$(adb -s "$serial" shell "which su" 2>/dev/null | tr -d '\r')
        if [ -z "$has_su_cmd" ]; then
            has_su_cmd=$(adb -s "$serial" shell "ls /system/bin/su /system/xbin/su /sbin/su 2>/dev/null" | head -1 | tr -d '\r')
        fi
        if [ -n "$has_su_cmd" ]; then
            su_test=$(timeout 3 adb -s "$serial" shell "$has_su_cmd -c 'id'" 2>/dev/null | tr -d '\r')
            if [[ "$su_test" == *"uid=0"* ]]; then
                has_su=true
            fi
        fi

        if [ "$has_su" = "true" ]; then
            net_ids=$(adb -s "$serial" shell "cmd wifi list-networks" 2>/dev/null | awk 'NR>1 {print $1}' | sort -u | tr -d '\r')
            for net_id in $net_ids; do
                if [[ "$net_id" =~ ^[0-9]+$ ]]; then
                    echo "[$serial] Forgetting saved network ID: $net_id"
                    adb -s "$serial" shell "cmd wifi forget-network $net_id" >/dev/null 2>&1 || true
                fi
            done
            adb -s "$serial" shell "cmd wifi remove-all-suggestions" >/dev/null 2>&1 || true
            sleep 1
            echo "[$serial] Connecting to '$chosen_ssid'..."
            adb -s "$serial" shell "$has_su_cmd -c 'cmd wifi connect-network \"$chosen_ssid\" wpa2 13241324'" >/dev/null 2>&1
        else
            echo -e "\e[1;31m[$serial] [⚠️] Root (su) permission check failed. Skipping.\e[0m"
        fi
    ) &
done
wait

# Step B. Poll for connection state and run clicker in parallel
echo "Waiting for connection and handling UI prompts in parallel..."
for serial in "${final_devices[@]}"; do
    (
        for i in {1..5}; do
            sleep 3
            python3 "$CMD_DIR/wifi_clicker.py" "$serial" >/dev/null 2>&1
        done
    ) &
done
wait

# Step C. Final Verification in parallel
echo -e "\n============================================="
echo -e "Final Wi-Fi Connection Status"
echo -e "============================================="
tmp_status=$(mktemp)
for serial in "${final_devices[@]}"; do
    (
        current_status=$(adb -s "$serial" shell "cmd wifi status" 2>/dev/null | grep -E "SSID|Wifi is" | tr -d '\r\n')
        echo "[$serial]: $current_status" >> "$tmp_status"
    ) &
done
wait
cat "$tmp_status"
rm -f "$tmp_status"
