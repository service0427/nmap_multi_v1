#!/usr/bin/env python3
import os
import sys
import time
import subprocess
from datetime import datetime
from huawei_lte_api.Client import Client
from huawei_lte_api.Connection import Connection

USERNAME = "admin"
PASSWORD = "KdjLch!@7024"
TIMEOUT = 3

# ANSI Colors
RESET = "\033[0m"
BOLD = "\033[1m"
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
MAGENTA = "\033[35m"

def format_rate(rate_bytes_sec):
    try:
        rate = float(rate_bytes_sec)
        # Convert to bps for Mbps display
        rate_bits = rate * 8
        if rate < 1024:
            return f"{rate:.0f} B/s"
        elif rate < 1024 * 1024:
            return f"{rate / 1024:.1f} KB/s ({rate_bits / 1000 / 1000:.2f} Mbps)"
        else:
            return f"{rate / 1024 / 1024:.2f} MB/s ({rate_bits / 1000 / 1000:.1f} Mbps)"
    except:
        return "N/A"

def format_bytes(bytes_val):
    try:
        b = float(bytes_val)
        if b < 1024 * 1024:
            return f"{b / 1024:.1f} KB"
        elif b < 1024 * 1024 * 1024:
            return f"{b / 1024 / 1024:.1f} MB"
        else:
            return f"{b / 1024 / 1024 / 1024:.2f} GB"
    except:
        return "N/A"

def format_time(seconds_str):
    try:
        sec = int(seconds_str)
        hours = sec // 3600
        minutes = (sec % 3600) // 60
        seconds = sec % 60
        return f"{hours:02d}:{minutes:02d}:{seconds:02d}"
    except:
        return "N/A"

def query_modem_traffic(subnet):
    modem_ip = f"192.168.{subnet}.1"
    try:
        connection = Connection(f'http://{modem_ip}/', username=USERNAME, password=PASSWORD, timeout=TIMEOUT)
        client = Client(connection)
        stats = client.monitoring.traffic_statistics()
        try:
            client.user.logout()
        except:
            pass
        return stats
    except Exception as e:
        return None

def draw_dashboard():
    # Clear screen if watching
    if len(sys.argv) > 1 and sys.argv[1] in ("-w", "--watch"):
        print("\033[H\033[J", end="")

    print("==================================================================================================================")
    print(f"📊 LTE Modem Real-Time Traffic & Speed Dashboard (Checked at: {datetime.now().strftime('%H:%M:%S')})")
    print("==================================================================================================================")
    print(f"{BOLD}{'Modem':<6} | {'Status':<7} | {'Uptime':<8} | {'Upload Speed':<24} | {'Download Speed':<24} | {'Sent Data':<10} | {'Recv Data':<10}{RESET}")
    print("------------------------------------------------------------------------------------------------------------------")

    for subnet in range(11, 17):
        modem_name = f"lte{subnet}"
        
        # Check physical interface existence
        if not os.path.exists(f"/sys/class/net/{modem_name}"):
            print(f"{RED}{modem_name:<6} | {'MISSING':<7} | {'N/A':<8} | {'N/A':<24} | {'N/A':<24} | {'N/A':<10} | {'N/A':<10}{RESET}")
            continue

        stats = query_modem_traffic(subnet)
        
        if stats is None:
            print(f"{RED}{modem_name:<6} | {'OFFLINE':<7} | {'N/A':<8} | {'N/A':<24} | {'N/A':<24} | {'N/A':<10} | {'N/A':<10}{RESET}")
            continue

        uptime = format_time(stats.get('CurrentConnectTime'))
        up_speed = format_rate(stats.get('CurrentUploadRate', 0))
        down_speed = format_rate(stats.get('CurrentDownloadRate', 0))
        sent = format_bytes(stats.get('CurrentUpload', 0))
        recv = format_bytes(stats.get('CurrentDownload', 0))

        # Color coding for speeds to show high activity
        up_rate = float(stats.get('CurrentUploadRate', 0))
        down_rate = float(stats.get('CurrentDownloadRate', 0))

        up_color = GREEN if up_rate > 100 * 1024 else (CYAN if up_rate > 10 * 1024 else RESET)
        down_color = GREEN if down_rate > 500 * 1024 else (CYAN if down_rate > 50 * 1024 else RESET)

        print(f"{BOLD}{modem_name:<6}{RESET} | {GREEN}{'ONLINE':<7}{RESET} | {uptime:<8} | "
              f"{up_color}{up_speed:<24}{RESET} | {down_color}{down_speed:<24}{RESET} | "
              f"{sent:<10} | {recv:<10}")

    print("==================================================================================================================")
    if len(sys.argv) > 1 and sys.argv[1] in ("-w", "--watch"):
        print(f"{YELLOW}Watching mode active (Refreshing every 2 seconds). Press Ctrl+C to exit.{RESET}")
    else:
        print(f"{CYAN}Tip: Run './wifi_multi/check_speeds.sh --watch' to view real-time traffic flow.{RESET}")
    print("==================================================================================================================")

def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("-w", "--watch"):
        try:
            while True:
                draw_dashboard()
                time.sleep(2)
        except KeyboardInterrupt:
            print("\nDashboard exited.")
    else:
        draw_dashboard()

if __name__ == "__main__":
    main()
