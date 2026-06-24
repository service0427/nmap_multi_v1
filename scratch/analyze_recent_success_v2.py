import os
import re
import time

log_base_dir = "/home/tech/nmap_multi_v1/wifi_multi/logs"

def analyze_recent():
    if not os.path.exists(log_base_dir):
        print("Log directory not found.")
        return

    success_count = 0
    driving_now_count = 0
    fail_count = 0
    failures = []

    for device in os.listdir(log_base_dir):
        dev_dir = os.path.join(log_base_dir, device)
        if not os.path.isdir(dev_dir):
            continue
        
        date_dir = os.path.join(dev_dir, "20260624")
        if not os.path.exists(date_dir):
            continue
            
        for session in os.listdir(date_dir):
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
                        lines = f.readlines()
                    
                    content = "".join(lines)
                    
                    # 1. SUCCESS CHECK
                    if "Task was SUCCESSFUL" in content or "Reason: Task Completed" in content:
                        if "status: FAIL" in content or "Reported FAIL" in content:
                            fail_count += 1
                            failures.append((device, session, "FAIL_REPORTED"))
                        else:
                            success_count += 1
                    # 2. FAIL SIGNALS
                    elif any(x in content for x in ["Frida Crash", "App Closed", "STUCK DETECTED", "SILENCE DETECTED", "ADDRESS_NOT_FOUND"]):
                        # Extract exact fail line
                        fail_msg = "Unknown Fail"
                        for line in reversed(lines):
                            if any(x in line for x in ["Frida Crash", "Closed", "STUCK", "SILENCE", "ADDRESS_NOT_FOUND"]):
                                fail_msg = line.strip()
                                break
                        fail_count += 1
                        failures.append((device, session, fail_msg))
                    # 3. STILL DRIVING CHECK
                    else:
                        # Check last line for active progress
                        last_line = lines[-1].strip() if lines else ""
                        if "Progress:" in last_line or "MONITORING" in last_line or "Starting road simulation" in last_line:
                            driving_now_count += 1
                        else:
                            # If no fail signal and not active progress, but task is not successful
                            # Let's check last modified time of execution.log
                            mtime = os.path.getmtime(exec_log)
                            if time.time() - mtime < 45: # updated in the last 45 seconds -> active
                                driving_now_count += 1
                            else:
                                fail_count += 1
                                failures.append((device, session, f"Hung/Zombie (Last line: {last_line[:50]})"))
                except Exception as e:
                    pass

    total_finished = success_count + fail_count
    total_all = success_count + fail_count + driving_now_count
    rate = (success_count / total_finished * 100) if total_finished > 0 else 0.0
    
    print(f"=== Seamless Session Stats after KST 20:05 (Last 30 Min) ===")
    print(f"Total Active/Completed Sessions: {total_all}")
    print(f"🟢 SUCCESSFUL       : {success_count}")
    print(f"🔵 DRIVING NOW (LIVE): {driving_now_count}")
    print(f"🔴 REAL FAIL        : {fail_count}")
    print(f"📈 True Success Rate (Completed): {rate:.1f}%")
    if failures:
        print("\n--- Real Failure Details ---")
        for dev, sess, reason in failures:
            print(f"Device: {dev} | Session: {sess} | Reason: {reason}")

if __name__ == "__main__":
    analyze_recent()
