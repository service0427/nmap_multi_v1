#!/bin/bash
# log_clean.sh: Robust Hourly log cleanup for wifi_multi

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LOG_ROOT="$SCRIPT_DIR/wifi_multi/logs"
NOW=$(date +"%Y-%m-%d %H:%M:%S")

echo "[$NOW] Starting Robust Hourly Cleanup for wifi_multi..."

if [ ! -d "$LOG_ROOT" ]; then
    echo "[$NOW] [!] Log root not found: $LOG_ROOT"
    exit 1
fi

# 1. Delete everything older than 1 hour at depth 2 or deeper
# (wifi_multi/logs/{DEVICE}/{DATE} or wifi_multi/logs/{DEVICE}/{DATE}/{SESSION})
# We use -not -newermt for better precision than -mmin.
# We explicitly protect critical orchestrator files and the 'tmp' directory.

find "$LOG_ROOT" -mindepth 2 -not -newermt "1 hour ago" \
    ! -path "*/tmp*" \
    ! -name "current_task.json" \
    ! -name "nmap_lock" \
    -exec rm -rf {} + 2>/dev/null

# 2. Cleanup empty directories (date folders, session folders)
# We do this from bottom up to remove now-empty parent folders.
find "$LOG_ROOT" -mindepth 2 -type d -empty -delete 2>/dev/null

echo "[$NOW] Cleanup complete for wifi_multi."
