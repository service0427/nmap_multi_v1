#!/bin/bash
# log_clean.sh: Robust Hourly log cleanup with Dynamic Disk Usage Safety

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LOG_ROOT="$SCRIPT_DIR/wifi_multi/logs"
NOW=$(date +"%Y-%m-%d %H:%M:%S")

echo "[$NOW] Starting Dynamic Hourly Cleanup for wifi_multi..."

if [ ! -d "$LOG_ROOT" ]; then
    echo "[$NOW] [!] Log root not found: $LOG_ROOT"
    exit 1
fi

# 1. Get current root disk usage percentage
DISK_USAGE=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')

# 2. Determine retention limit based on disk usage
if [ "$DISK_USAGE" -ge 90 ]; then
    KEEP_TIME="30 minutes ago"
elif [ "$DISK_USAGE" -ge 80 ]; then
    KEEP_TIME="2 hours ago"
elif [ "$DISK_USAGE" -ge 70 ]; then
    KEEP_TIME="4 hours ago"
elif [ "$DISK_USAGE" -ge 50 ]; then
    KEEP_TIME="8 hours ago"
else
    KEEP_TIME="24 hours ago"
fi

echo "[$NOW] Current Disk Usage: $DISK_USAGE%. Setting retention threshold to: $KEEP_TIME"

# 3. Delete everything older than threshold at depth 2 or deeper
# We explicitly protect critical orchestrator files and the 'tmp' directory.
find "$LOG_ROOT" -mindepth 2 -not -newermt "$KEEP_TIME" \
    ! -path "*/tmp*" \
    ! -path "*/locks*" \
    ! -name "current_task.json" \
    ! -name "nmap_lock" \
    -exec rm -rf {} + 2>/dev/null

# 4. Cleanup empty directories (date folders, session folders)
find "$LOG_ROOT" -mindepth 2 -type d -empty -delete 2>/dev/null

echo "[$NOW] Cleanup complete. Disk usage remains at $DISK_USAGE%."
