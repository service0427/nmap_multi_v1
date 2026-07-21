#!/usr/bin/env python3
import os
import sys
import csv
import json
from datetime import datetime

def find_session_folder(dev_id, date_str, task_id, ts_str):
    device_dir = f"/home/tech/nmap_multi_v1/wifi_multi/logs/{dev_id}/{date_str}"
    if not os.path.exists(device_dir):
        return None
        
    try:
        subdirs = [os.path.join(device_dir, d) for d in os.listdir(device_dir) if os.path.isdir(os.path.join(device_dir, d))]
    except:
        return None
    
    # 1. Try matching via report.json
    for sd in subdirs:
        report_path = os.path.join(sd, "report.json")
        if os.path.exists(report_path):
            try:
                with open(report_path, "r", encoding="utf-8", errors="ignore") as rf:
                    rep_data = json.load(rf)
                    tid = str(rep_data.get("task_metadata", {}).get("task_id", ""))
                    if tid == str(task_id):
                        return sd
            except:
                pass
                
    # 2. Fallback: match via timestamp proximity
    try:
        csv_dt = datetime.strptime(ts_str, "%Y-%m-%d %H:%M:%S")
    except:
        return None
        
    best_folder = None
    min_diff = 900 # Max 15 minutes difference
    
    for sd in subdirs:
        bname = os.path.basename(sd)
        parts = bname.split("_")
        if not parts: continue
        hms = parts[0]
        if len(hms) == 6 and hms.isdigit():
            try:
                f_hour = int(hms[0:2])
                f_min = int(hms[2:4])
                f_sec = int(hms[4:6])
                folder_dt = csv_dt.replace(hour=f_hour, minute=f_min, second=f_sec)
                diff = (csv_dt - folder_dt).total_seconds()
                if 0 <= diff < min_diff:
                    min_diff = diff
                    best_folder = sd
            except:
                pass
                
    return best_folder

def check_429_in_session(folder_path):
    if not folder_path:
        return False
    summary_file = os.path.join(folder_path, "session_summary.json")
    if not os.path.exists(summary_file):
        return False
    try:
        with open(summary_file, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
            if '"status": 429' in content or '"status_code": 429' in content:
                return True
    except:
        pass
    return False

def main():
    history_file = "/home/tech/nmap_multi_v1/wifi_multi/logs/rotator_history/session_history.csv"
    if not os.path.exists(history_file):
        print(f"[-] No history file found at: {history_file}")
        print("Please run some sessions first to generate logs.")
        return

    # Check argument for date filter
    target_date = None
    if len(sys.argv) > 1:
        arg = sys.argv[1]
        if arg.lower() != 'all':
            target_date = arg
    else:
        # Default to today
        target_date = datetime.now().strftime("%Y-%m-%d")

    total_runs = 0
    success_count = 0
    fail_count = 0
    api_err_count = 0
    gql_429_runs = 0

    subnet_stats = {}
    failure_reasons = {}
    
    all_devices = set()
    timestamps = []

    with open(history_file, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            ts = row.get('Timestamp', '')
            if target_date and not ts.startswith(target_date):
                continue

            status = row.get('Status', '')
            subnet = row.get('Subnet', 'Unknown')
            msg = row.get('Message', '')
            dev_id = row.get('DeviceID', '')
            task_id = row.get('TaskID', '')

            if not subnet:
                subnet = 'Unknown'

            total_runs += 1
            all_devices.add(dev_id)
            
            try:
                dt = datetime.strptime(ts, "%Y-%m-%d %H:%M:%S")
                timestamps.append(dt)
            except:
                pass

            if status == 'SUCCESS':
                success_count += 1
            elif status == 'API_ERROR':
                api_err_count += 1
            else:
                fail_count += 1

            # Extract date string for folder matching
            date_str = ts.split()[0].replace("-", "") if ts else ""
            
            # Find the session directory and check for 429
            had_429 = False
            if dev_id and date_str and task_id:
                folder = find_session_folder(dev_id, date_str, task_id, ts)
                had_429 = check_429_in_session(folder)

            if had_429 or "GQL_429" in msg or "429" in msg:
                gql_429_runs += 1
                had_429_event = True
            else:
                had_429_event = False

            # Group by subnet
            if subnet not in subnet_stats:
                subnet_stats[subnet] = {
                    'total': 0, 'success': 0, 'fail': 0, 'api_err': 0, 'gql_429': 0, 'devices': set()
                }
            
            sub_s = subnet_stats[subnet]
            sub_s['total'] += 1
            sub_s['devices'].add(dev_id)
            if status == 'SUCCESS':
                sub_s['success'] += 1
            elif status == 'API_ERROR':
                sub_s['api_err'] += 1
            else:
                sub_s['fail'] += 1

            if had_429_event:
                sub_s['gql_429'] += 1

            # Failure reasons breakdown
            if status != 'SUCCESS' and status != 'API_ERROR':
                reason = "Unknown"
                if "PACKET_STUCK" in msg:
                    reason = "PACKET_STUCK"
                elif "MISSING_ARRIVAL_PACKETS" in msg:
                    reason = "MISSING_ARRIVAL_PACKETS"
                elif "GQL_429" in msg or "429" in msg or had_429_event:
                    reason = "GQL_429_DETECTED"
                elif "nCaptcha Timeout" in msg or "captcha" in msg.lower() or "ERROR_LOG_DETECTED" in msg:
                    reason = "nCaptcha Timeout"
                elif "ADDRESS_NOT_FOUND" in msg:
                    reason = "ADDRESS_NOT_FOUND"
                elif "GUIDANCE_NOT_FOUND" in msg:
                    reason = "GUIDANCE_NOT_FOUND"
                elif "IDENTITY_MISMATCH" in msg:
                    reason = "IDENTITY_MISMATCH"
                elif "GLOBAL_TIMEOUT" in msg:
                    reason = "GLOBAL_TIMEOUT"
                else:
                    reason = msg if msg else "Unknown"

                failure_reasons[reason] = failure_reasons.get(reason, 0) + 1

    print("========================================================================")
    if target_date:
        print(f"📊 Session Performance Report for Date: {target_date}")
    else:
        print("📊 Session Performance Report: OVERALL HISTORY")
    print("========================================================================")

    if total_runs == 0:
        print(f"[-] No session records found matching the filter.")
        return

    # Calculate elapsed hours based on timestamps
    hours = 1.0
    time_range_str = "N/A"
    if len(timestamps) >= 2:
        min_ts = min(timestamps)
        max_ts = max(timestamps)
        duration_seconds = (max_ts - min_ts).total_seconds()
        hours = duration_seconds / 3600.0
        time_range_str = f"{min_ts.strftime('%H:%M:%S')} ~ {max_ts.strftime('%H:%M:%S')}"
    
    # Cap hours to avoid division by zero or extreme numbers for very short windows
    if hours < 0.1:
        hours = 0.1

    # Print overall stats
    success_rate = (success_count / (success_count + fail_count)) * 100 if (success_count + fail_count) > 0 else 0
    unique_devices = len(all_devices)
    overall_efficiency = success_count / (unique_devices * hours) if (unique_devices * hours) > 0 else 0

    print(f"Overall Stats:")
    print(f" - Total Runs       : {total_runs}")
    print(f" - SUCCESS          : {success_count}")
    print(f" - FAIL             : {fail_count}")
    print(f" - GQL_429 Detected : {gql_429_runs} runs ({(gql_429_runs/total_runs*100) if total_runs > 0 else 0:.1f}% of total)")
    if api_err_count > 0:
        print(f" - API_ERROR        : {api_err_count} (Not counted in success rate)")
    print(f" - Success Rate     : {success_rate:.1f}%")
    print(f" - Active Devices   : {unique_devices} unique devices")
    print(f" - Report Duration  : {hours:.2f} hours ({time_range_str})")
    print(f" - Work Efficiency  : {overall_efficiency:.2f} successes/device/hour 🚀")
    print("========================================================================")

    # Print subnet breakdown
    print("Subnet-wise (lte11 ~ lte16) Performance:")
    for sub in sorted(subnet_stats.keys(), key=lambda x: int(x) if x.isdigit() else 999):
        sub_s = subnet_stats[sub]
        sub_total = sub_s['total']
        sub_success = sub_s['success']
        sub_fail = sub_s['fail']
        sub_api = sub_s['api_err']
        sub_gql = sub_s['gql_429']
        sub_rate = (sub_success / (sub_success + sub_fail)) * 100 if (sub_success + sub_fail) > 0 else 0
        sub_devs = len(sub_s['devices'])
        sub_efficiency = sub_success / (sub_devs * hours) if (sub_devs * hours) > 0 else 0
        dev_list = sorted(list(sub_s['devices']))
        
        print(f"lte{sub} (Subnet {sub} | Active Devices: {sub_devs}):")
        print(f"   Active Devices  : {', '.join(dev_list)}")
        print(f"   Runs            : {sub_total} | Success: {sub_success} | Fail: {sub_fail} | Success Rate: {sub_rate:.1f}%")
        print(f"   GQL_429 Detected: {sub_gql} runs ({(sub_gql/sub_total*100) if sub_total > 0 else 0:.1f}%)")
        if sub_api > 0:
            print(f"   API_ERROR       : {sub_api} (Not counted in success rate)")
        print(f"   Work Efficiency : {sub_efficiency:.2f} successes/device/hour 🚀")
        print("------------------------------------------------------------------------")

    # Print failure breakdown
    print("Failure Reasons Breakdown:")
    for r, count in sorted(failure_reasons.items(), key=lambda x: x[1], reverse=True):
        print(f" - {r}: {count} ({count/fail_count*100:.1f}% of failures)")

    print("========================================================================")

if __name__ == "__main__":
    main()
