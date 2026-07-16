#!/bin/bash
# Shortcut to execute the daily report aggregator script
cd "$(dirname "$0")/.."
python3 wifi_multi/macro/daily_report.py "$1"
