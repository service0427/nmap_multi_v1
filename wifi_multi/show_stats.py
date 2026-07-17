#!/usr/bin/env python3
import os
import sys
import csv
from datetime import datetime

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

    print("========================================================================")
    if target_date:
        print(f"📊 Session Performance Report for Date: {target_date}")
    else:
        print("📊 Session Performance Report: OVERALL HISTORY")
    print("========================================================================")

    total_runs = 0
    success_count = 0
    fail_count = 0
    api_err_count = 0

    subnet_stats = {}
    failure_reasons = {}

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

            if not subnet:
                subnet = 'Unknown'

            total_runs += 1
            if status == 'SUCCESS':
                success_count += 1
            elif status == 'API_ERROR':
                api_err_count += 1
            else:
                fail_count += 1

            # Group by subnet
            if subnet not in subnet_stats:
                subnet_stats[subnet] = {
                    'total': 0, 'success': 0, 'fail': 0, 'api_err': 0, 'devices': set()
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

            # Failure reasons breakdown
            if status != 'SUCCESS' and status != 'API_ERROR':
                # Sanitize / group reasons
                reason = "Unknown"
                if "nCaptcha Timeout" in msg or "captcha" in msg.lower() or "ERROR_LOG_DETECTED" in msg:
                    reason = "nCaptcha Timeout"
                elif "PACKET_STUCK" in msg:
                    reason = "PACKET_STUCK"
                elif "MISSING_ARRIVAL_PACKETS" in msg:
                    reason = "MISSING_ARRIVAL_PACKETS"
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

    if total_runs == 0:
        print(f"[-] No session records found matching the filter.")
        return

    # Print overall stats
    success_rate = (success_count / (success_count + fail_count)) * 100 if (success_count + fail_count) > 0 else 0
    print(f"Overall Stats:")
    print(f" - Total Runs   : {total_runs}")
    print(f" - SUCCESS      : {success_count}")
    print(f" - FAIL         : {fail_count}")
    if api_err_count > 0:
        print(f" - API_ERROR    : {api_err_count} (Not counted in success rate)")
    print(f" - Success Rate : {success_rate:.1f}%")
    print("========================================================================")

    # Print subnet breakdown
    print("Subnet-wise (lte11 ~ lte16) Performance:")
    for sub in sorted(subnet_stats.keys(), key=lambda x: int(x) if x.isdigit() else 999):
        sub_s = subnet_stats[sub]
        sub_total = sub_s['total']
        sub_success = sub_s['success']
        sub_fail = sub_s['fail']
        sub_api = sub_s['api_err']
        sub_rate = (sub_success / (sub_success + sub_fail)) * 100 if (sub_success + sub_fail) > 0 else 0
        dev_list = sorted(list(sub_s['devices']))
        
        print(f"lte{sub} (Subnet {sub} | Active Devices: {len(dev_list)}):")
        print(f"   Active Devices : {', '.join(dev_list)}")
        print(f"   Runs           : {sub_total} | Success: {sub_success} | Fail: {sub_fail} | Success Rate: {sub_rate:.1f}%")
        if sub_api > 0:
            print(f"   API_ERROR      : {sub_api} (Not counted in success rate)")
        print("------------------------------------------------------------------------")

    # Print failure breakdown
    print("Failure Reasons Breakdown:")
    for r, count in sorted(failure_reasons.items(), key=lambda x: x[1], reverse=True):
        print(f" - {r}: {count} ({count/fail_count*100:.1f}% of failures)")

    print("========================================================================")

if __name__ == "__main__":
    main()
