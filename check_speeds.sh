#!/bin/bash
# Shell wrapper for check_speeds.py
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$SCRIPT_DIR/wifi_multi/utils/check_speeds.py" "$@"
