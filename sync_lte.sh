#!/bin/bash
# Fast LTE Proxy Route Synchronizer
# Usage: ./sync_lte.sh or sudo ./sync_lte.sh

if [ "$EUID" -ne 0 ]; then
  echo "[*] Requesting root privileges to run lte-sync..."
  exec sudo "$0" "$@"
fi

echo -e "\033[0;34m⚡ Fast LTE Route Syncing...\033[0m"
/usr/local/bin/lte-sync
echo -e "\033[0;32m✅ LTE Route Sync Completed!\033[0m"
