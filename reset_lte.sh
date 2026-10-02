#!/usr/bin/env bash
# reset_lte.sh: LTE Modem Real-Time USB Reset & Recovery CLI Wrapper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
python3 "$SCRIPT_DIR/cmd/reset_lte.py" "$@"
