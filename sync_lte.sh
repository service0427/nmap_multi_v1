#!/bin/bash
# Fast LTE Proxy Route Synchronizer
# Usage: ./sync_lte.sh or sudo ./sync_lte.sh

if [ "$EUID" -ne 0 ]; then
  echo "[*] Requesting root privileges to run lte-sync..."
  exec sudo "$0" "$@"
fi

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo -e "\033[0;34m⚡ Fast LTE Route Syncing...\033[0m"
if [ -f "$SCRIPT_DIR/utils/lte_recovery.py" ]; then
    python3 "$SCRIPT_DIR/utils/lte_recovery.py" --force
elif [ -x "/usr/local/bin/lte-sync" ]; then
    /usr/local/bin/lte-sync
fi
echo -e "\033[0;32m✅ LTE Route Sync Completed!\033[0m"
