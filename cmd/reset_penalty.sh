#!/usr/bin/env bash
# cmd/reset_penalty.sh: 중앙 API 서버 벌점 리셋 및 로컬 태스크 캐시 초기화

CMD_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(cd "$CMD_DIR/.." && pwd)"

# Source config if available
ADMIN_SERVER="114.207.112.245:8001"
if [ -f "$PROJECT_ROOT/wifi_multi/config.conf" ]; then
    source "$PROJECT_ROOT/wifi_multi/config.conf" 2>/dev/null || true
    ADMIN_SERVER="${ADMIN_API_SERVER:-$ADMIN_SERVER}"
fi

TARGET_DEV="$1"

if [ -n "$TARGET_DEV" ]; then
    echo -e "\n[*] Resetting penalty for single device: \033[1;33m$TARGET_DEV\033[0m..."
    res=$(curl -s --connect-timeout 5 "http://${ADMIN_SERVER}/api/v1/admin/device/reset_penalty?device_id=$TARGET_DEV")
    echo "  -> Server response: $res"
    # Local cache reset
    if [ -f "$PROJECT_ROOT/wifi_multi/logs/$TARGET_DEV/current_task.json" ]; then
        echo '{"status": "IDLE"}' > "$PROJECT_ROOT/wifi_multi/logs/$TARGET_DEV/current_task.json"
    fi
    echo -e "\033[1;32m[✅] $TARGET_DEV penalty reset complete!\033[0m\n"
else
    echo -e "\n[*] Resetting penalties for ALL devices on server \033[1;33m$ADMIN_SERVER\033[0m..."
    res=$(curl -s --connect-timeout 5 "http://${ADMIN_SERVER}/api/v1/admin/device/reset_all_penalties")
    echo "  -> Server response: $res"
    # Clear local penalty cache
    count=0
    for task_file in "$PROJECT_ROOT"/wifi_multi/logs/*/current_task.json; do
        [ -f "$task_file" ] || continue
        if grep -q "PENALTY" "$task_file" 2>/dev/null; then
            echo '{"status": "IDLE"}' > "$task_file"
            count=$((count + 1))
        fi
    done
    echo -e "\033[1;32m[✅] Cleared local PENALTY cache for $count devices.\033[0m"
    echo -e "\033[1;32m[✅] All devices successfully unblocked and ready for tasks!\033[0m\n"
fi
