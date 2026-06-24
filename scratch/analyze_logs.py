import re
import os

log_file = "/home/tech/.pm2/logs/wifi-scheduler-out.log"

def analyze():
    if not os.path.exists(log_file):
        print(f"Log file not found: {log_file}")
        return

    # Counter for allocations by hour
    hourly_allocations = {f"{i:02d}": 0 for i in range(24)}
    
    current_hour = None
    time_pattern = re.compile(r'\[(\d{2}):\d{2}:\d{2}\]')

    with open(log_file, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            # Check for timestamp
            time_match = time_pattern.search(line)
            if time_match:
                current_hour = time_match.group(1)
            
            # Check for allocation mark
            if "[🚀]" in line or "ALLOCATED:" in line:
                if current_hour:
                    hourly_allocations[current_hour] += 1

    print("=== Hourly Task Allocations today (from PM2 Log) ===")
    for hour in sorted(hourly_allocations.keys()):
        count = hourly_allocations[hour]
        bar = "*" * min(count // 2, 50)  # Draw a simple text bar chart
        print(f"{hour}:00 - {count:4d} tasks {bar}")

if __name__ == "__main__":
    analyze()
