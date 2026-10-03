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
# Adaptive Tiered Retention (preserving 48h~72h when disk has comfortable free space)
if [ "$DISK_USAGE" -ge 93 ]; then
    KEEP_TIME="1 hour ago"
elif [ "$DISK_USAGE" -ge 88 ]; then
    KEEP_TIME="6 hours ago"
elif [ "$DISK_USAGE" -ge 80 ]; then
    KEEP_TIME="24 hours ago"
elif [ "$DISK_USAGE" -ge 65 ]; then
    KEEP_TIME="48 hours ago"
else
    KEEP_TIME="72 hours ago"
fi

echo "[$NOW] Current Disk Usage: $DISK_USAGE%. Setting retention threshold to: $KEEP_TIME"

# 3. Clean macro session logs (wifi_multi/logs/macro/{DATE}/{DEV_ID}/{SESSION})
MACRO_ROOT="$LOG_ROOT/macro"
if [ -d "$MACRO_ROOT" ]; then
    # Delete individual session folders older than threshold
    find "$MACRO_ROOT" -mindepth 3 -maxdepth 3 -type d -not -newermt "$KEEP_TIME" -exec rm -rf {} + 2>/dev/null
    # Delete date folders older than threshold
    find "$MACRO_ROOT" -mindepth 1 -maxdepth 1 -type d -not -newermt "$KEEP_TIME" -exec rm -rf {} + 2>/dev/null
    # Remove empty directories in macro tree
    find "$MACRO_ROOT" -type d -empty -delete 2>/dev/null
fi

# 4. Clean legacy session logs (wifi_multi/logs/{DEV_ID}/{DATE}) if any remain
find "$LOG_ROOT" -mindepth 2 -maxdepth 3 \
    ! -path "*/macro*" \
    ! -path "*/devices*" \
    ! -path "*/tmp*" \
    ! -path "*/locks*" \
    ! -path "*/stealth_logs*" \
    ! -path "*/rotator_history*" \
    ! -name "current_task.json" \
    ! -name "*lock*" \
    -not -newermt "$KEEP_TIME" \
    -exec rm -rf {} + 2>/dev/null

# 5. Specific 30-day retention cleanup for stealth_logs, rotator_history, and api_backup
find "$LOG_ROOT/stealth_logs" "$LOG_ROOT/rotator_history" -type f -mtime +30 -delete 2>/dev/null
API_BACKUP_DIR="$SCRIPT_DIR/api_backup"
if [ -d "$API_BACKUP_DIR" ]; then
    find "$API_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} + 2>/dev/null
fi

# 6. Cleanup empty directories (excluding tmp and devices folders)
find "$LOG_ROOT" -mindepth 2 -not -path "*/tmp*" -not -path "*/devices*" -type d -empty -delete 2>/dev/null

echo "[$NOW] Cleanup complete. Disk usage remains at $(df / | tail -1 | awk '{print $5}')."
