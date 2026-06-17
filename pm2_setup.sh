#!/usr/bin/env bash

# pm2_setup.sh: Register Nmap services to PM2 for production automation

# Determine the absolute path of the directory where this script is located
PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$PROJECT_ROOT" || exit 1

echo "============================================================"
echo "   Nmap Production Service Registration (PM2)"
echo "   Root: $PROJECT_ROOT"
echo "============================================================"

# 1.5 Back up current running status of schedulers
WIFI_STATUS=""
NMAP_STATUS=""
if command -v pm2 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    WIFI_STATUS=$(pm2 jlist 2>/dev/null | jq -r '.[] | select(.name=="wifi-scheduler") | .pm2_env.status' 2>/dev/null)
    NMAP_STATUS=$(pm2 jlist 2>/dev/null | jq -r '.[] | select(.name=="nmap-scheduler") | .pm2_env.status' 2>/dev/null)
fi


# Default to active wifi-scheduler if both are empty/unset but wifi_multi exists
if [ -z "$WIFI_STATUS" ] && [ -z "$NMAP_STATUS" ]; then
    if [ -d "wifi_multi" ]; then
        WIFI_STATUS="online"
    else
        NMAP_STATUS="online"
    fi
fi

# 1. Ensure PM2 is installed
if ! command -v pm2 >/dev/null 2>&1; then
    echo "[*] PM2 not found. Installing..."
    sudo npm install -g pm2
fi

# 2. Register Web Monitor
if [ -f "utils/web_monitor.py" ]; then
    echo "[*] Registering Nmap Web Monitor..."
    pm2 delete nmap-monitor 2>/dev/null
    pm2 start utils/web_monitor.py --name "nmap-monitor" --interpreter python3
else
    echo "[!] utils/web_monitor.py not found. Skipping."
fi

# 3. Register Scheduler (Runner)
if [ -f "wifi_multi/run_scheduler.sh" ]; then
    echo "[*] Registering Nmap Scheduler (STOPPED state)..."
    chmod +x wifi_multi/run_scheduler.sh
    pm2 delete nmap-scheduler 2>/dev/null
    # 일단 등록한 뒤 바로 중지 상태로 만듦
    pm2 start wifi_multi/run_scheduler.sh --name "nmap-scheduler"
    pm2 stop nmap-scheduler
else
    echo "[!] wifi_multi/run_scheduler.sh not found. Skipping."
fi

# 3.5 Register Wi-Fi Scheduler (STOPPED state)
if [ -f "wifi_multi/run_scheduler.sh" ]; then
    echo "[*] Registering Nmap Wi-Fi Scheduler (STOPPED state)..."
    chmod +x wifi_multi/run_scheduler.sh
    pm2 delete wifi-scheduler 2>/dev/null
    pm2 start wifi_multi/run_scheduler.sh --name "wifi-scheduler"
    pm2 stop wifi-scheduler
else
    echo "[!] wifi_multi/run_scheduler.sh not found. Skipping."
fi

# 4. Register Log Cleaner (Hourly Cron)
if [ -f "log_clean.sh" ]; then
    echo "[*] Registering Nmap Log Cleaner (Hourly Cron)..."
    chmod +x log_clean.sh
    pm2 delete nmap-log-cleaner 2>/dev/null
    pm2 start log_clean.sh --name "nmap-log-cleaner" --cron "0 * * * *" --no-autorestart
else
    echo "[!] log_clean.sh not found. Skipping."
fi

# 4.5 Register LTE Usage Sender (Daemon)
if [ -f "utils/send_lte_usage.py" ]; then
    echo "[*] Registering Nmap LTE Usage Sender (Daemon)..."
    chmod +x utils/send_lte_usage.py
    pm2 delete lte-usage-sender 2>/dev/null
    pm2 start utils/send_lte_usage.py --name "lte-usage-sender" --interpreter python3 -- --daemon
else
    echo "[!] utils/send_lte_usage.py not found. Skipping."
fi

# 4.6 Register Multi-Modem LTE IP Rotator
if [ -f "wifi_multi/utils/lte_ip_rotator.py" ]; then
    echo "[*] Registering Multi-Modem LTE IP Rotator..."
    chmod +x wifi_multi/utils/lte_ip_rotator.py
    pm2 delete lte-ip-rotator 2>/dev/null
    pm2 start wifi_multi/utils/lte_ip_rotator.py --name "lte-ip-rotator" --interpreter python3
else
    echo "[!] wifi_multi/utils/lte_ip_rotator.py not found. Skipping."
fi

# 4.7 Restore Running Status
if [ "$WIFI_STATUS" = "online" ]; then
    echo "[*] Restoring Wi-Fi Scheduler to online..."
    pm2 start wifi-scheduler
fi

if [ "$NMAP_STATUS" = "online" ]; then
    echo "[*] Restoring Nmap Scheduler to online..."
    pm2 start nmap-scheduler
fi

# 5. Save & Setup Startup
echo "[*] Finalizing PM2 configuration..."
pm2 save
pm2 startup | tail -n 1 | bash 2>/dev/null

echo "============================================================"
echo "   PM2 Setup Complete!"
echo "   - Commands: pm2 list, pm2 logs, pm2 monit"
echo "============================================================"
