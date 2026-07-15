#!/bin/bash
# Manual IP Toggle Helper

SUBNET=$1
if [ -z "$SUBNET" ]; then
    echo "Usage: ./toggle_ip.sh <subnet_idx> (e.g., 11 to 16, or 'all')"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$SUBNET" = "all" ]; then
    echo "[*] Toggling IP for ALL subnets (11 to 16)..."
    for s in 11 12 13 14 15 16; do
        echo "--------------------------------------------------"
        echo "[*] Toggling subnet $s..."
        python3 "$SCRIPT_DIR/smart_toggle.py" "$s"
    done
else
    if ! [[ "$SUBNET" =~ ^[0-9]+$ ]]; then
        echo "[Error] Subnet must be a number (11-16) or 'all'."
        exit 1
    fi
    echo "[*] Toggling IP for subnet $SUBNET..."
    python3 "$SCRIPT_DIR/smart_toggle.py" "$SUBNET"
fi
