import re
import os

log_file = "/home/tech/.pm2/logs/lte-ip-rotator-out.log"

def analyze():
    if not os.path.exists(log_file):
        print(f"Log file not found: {log_file}")
        return

    # Counter for success/fail by hour
    hourly_stats = {}
    
    # Matching timestamp like [2026-06-24 19:39:54]
    time_pattern = re.compile(r'\[\d{4}-\d{2}-\d{2} (\d{2}):\d{2}:\d{2}\]')

    with open(log_file, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            time_match = time_pattern.search(line)
            if not time_match:
                continue
            hour = time_match.group(1)
            
            if hour not in hourly_stats:
                hourly_stats[hour] = {"success": 0, "failed": 0, "recovery_success": 0, "recovery_failed": 0}
                
            if "Rotation Success!" in line:
                hourly_stats[hour]["success"] += 1
            elif "Rotation failed" in line:
                hourly_stats[hour]["failed"] += 1
            elif "Recovery Success!" in line:
                hourly_stats[hour]["recovery_success"] += 1
            elif "Recovery failed" in line:
                hourly_stats[hour]["recovery_failed"] += 1

    print("=== Hourly IP Rotator Success/Fail Stats ===")
    print("Hour   | Rot_Success | Rot_Failed | Recov_Success | Recov_Failed")
    print("-" * 65)
    for hour in sorted(hourly_stats.keys()):
        s = hourly_stats[hour]
        print(f"{hour}:00  | {s['success']:11d} | {s['failed']:10d} | {s['recovery_success']:13d} | {s['recovery_failed']:12d}")

if __name__ == "__main__":
    analyze()
