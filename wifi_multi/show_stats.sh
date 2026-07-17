#!/bin/bash
# Shell wrapper for show_stats.py
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$SCRIPT_DIR/show_stats.py" "$@"
