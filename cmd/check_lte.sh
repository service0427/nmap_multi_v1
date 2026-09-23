#!/usr/bin/env bash
# cmd/check_lte.sh: LTE Modem Inspection & Auto-Cure CLI Wrapper

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

# Check if python3 is available
if ! command -v python3 &> /dev/null; then
    echo -e "\033[1;31m[❌] Error: python3 is not installed.\033[0m"
    exit 1
fi

# Ensure huawei-lte-api is installed
if ! python3 -c "import huawei_lte_api" &> /dev/null; then
    echo -e "\033[1;33m[*] Installing huawei-lte-api dependency...\033[0m"
    pip3 install huawei-lte-api --break-system-packages 2>/dev/null || pip3 install huawei-lte-api 2>/dev/null || sudo pip3 install huawei-lte-api
fi

# Execute optimizer
python3 "$SCRIPT_DIR/lte_optimizer.py" "$@"
