import os
import re

log_base_dir = "/home/tech/nmap_multi_v1/wifi_multi/logs"

def analyze_recent():
    if not os.path.exists(log_base_dir):
        print("Log directory not found.")
        return

    success_count = 0
    fail_count = 0
    failures = []

    # Target folders with timestamp >= 200500 today
    # Folder structure: logs/{DEVICE}/20260624/{HHMMSS_TaskID}/execution.log
    for device in os.listdir(log_base_dir):
        dev_dir = os.path.join(log_base_dir, device)
        if not os.path.isdir(dev_dir):
            continue
        
        date_dir = os.path.join(dev_dir, "20260624")
        if not os.path.exists(date_dir):
            continue
            
        for session in os.listdir(date_dir):
            # Parse HHMMSS
            parts = session.split('_')
            if not parts:
                continue
            
            time_str = parts[0]
            if not time_str.isdigit() or len(time_str) < 6:
                continue
                
            # Filter for tasks started after 20:05:00 KST
            if int(time_str) < 200500:
                continue
                
            exec_log = os.path.join(date_dir, session, "execution.log")
            if os.path.exists(exec_log):
                try:
                    with open(exec_log, 'r', encoding='utf-8', errors='ignore') as f:
                        content = f.read()
                        
                    if "Task was SUCCESSFUL" in content or "SUCCESSFUL" in content or "Reason: Task Completed" in content:
                        # Double check if it reported fail due to address or other things in the end
                        if "status: FAIL" in content or "Reported FAIL" in content or "status\": \"FAIL\"" in content:
                            fail_count += 1
                            failures.append((device, session, "FAIL_REPORTED"))
                        else:
                            success_count += 1
                    else:
                        # Extract failure reason if exists
                        reason_match = re.search(r'Terminating\. Reason:\s*(.*)', content)
                        reason = reason_match.group(1).strip() if reason_match else "Unknown/Interrupted"
                        fail_count += 1
                        failures.append((device, session, reason))
                except:
                    pass

    total = success_count + fail_count
    rate = (success_count / total * 100) if total > 0 else 0.0
    print(f"=== Session Success Rate after KST 20:05 (Last 30 Min) ===")
    print(f"Total Completed Sessions: {total}")
    print(f"🟢 SUCCESS: {success_count}")
    print(f"🔴 FAIL   : {fail_count}")
    print(f"📈 Success Rate   : {rate:.1f}%")
    if failures:
        print("\n--- Failure Details ---")
        for dev, sess, reason in failures:
            print(f"Device: {dev} | Session: {sess} | Reason: {reason}")

if __name__ == "__main__":
    analyze_recent()
