#!/usr/bin/env python3
import os
import re
import json
import time
import sys
from datetime import datetime, timedelta

def extract_json(text, start_pos):
    brace_count = 0
    in_string = False
    escape = False
    json_start = -1
    
    for i in range(start_pos, len(text)):
        char = text[i]
        if char == '"' and not escape:
            in_string = not in_string
        
        if not in_string:
            if char == '{':
                if brace_count == 0:
                    json_start = i
                brace_count += 1
            elif char == '}':
                brace_count -= 1
                if brace_count == 0 and json_start != -1:
                    return text[json_start:i+1]
                    
        if char == '\\' and not escape:
            escape = True
        else:
            escape = False
            
    return None

def generate_report(target_date_str=None):
    logs_dir = "/home/tech/nmap_multi_v1/wifi_multi/logs"
    if not target_date_str:
        target_date_str = datetime.now().strftime("%Y%m%d")
        
    target_date_dashes = f"{target_date_str[:4]}-{target_date_str[4:6]}-{target_date_str[6:]}"
    
    success_cnt = 0
    fail_cnt = 0
    api_error_cnt = 0
    total_cnt = 0
    
    error_breakdown = {}
    device_stats = {}
    modem_stats = {}
    
    # Subnet mapping helper
    def get_modem_name(ip):
        if not ip:
            return "unknown"
        match = re.search(r"192\.168\.(\d+)\.", ip)
        if match:
            idx = match.group(1)
            return f"lte{idx}"
        return "unknown"

    # Walk through device log directories
    for device_id in os.listdir(logs_dir):
        dev_path = os.path.join(logs_dir, device_id)
        if not os.path.isdir(dev_path) or device_id == "rotator_history":
            continue
            
        date_path = os.path.join(dev_path, target_date_str)
        if not os.path.isdir(date_path):
            continue
            
        for session_dir in os.listdir(date_path):
            session_path = os.path.join(date_path, session_dir)
            exec_log_path = os.path.join(session_path, "execution.log")
            if not os.path.exists(exec_log_path):
                continue
                
            bind_ip = None
            status = "UNKNOWN"
            fail_msg = "No API report found"
            
            try:
                with open(exec_log_path, 'r', errors='ignore') as f:
                    content = f.read()
                    
                    # Extract BIND_IP
                    ip_match = re.search(r"BIND_IP:([\d\.]+)", content)
                    if ip_match:
                        bind_ip = ip_match.group(1)
                        
                    # Extract report_result API call (multi-line balanced brace support)
                    start_idx = content.find("/api/v1/report_result")
                    if start_idx != -1:
                        json_str = extract_json(content, start_idx)
                        if json_str:
                            try:
                                payload = json.loads(json_str)
                                status = payload.get("status", "UNKNOWN")
                                fail_msg = payload.get("message", "")
                            except Exception:
                                pass
            except Exception:
                continue

            if status == "UNKNOWN":
                continue  # Skip unfinalized sessions

            modem = get_modem_name(bind_ip)
            
            # Init stats structures
            if device_id not in device_stats:
                device_stats[device_id] = {"success": 0, "fail": 0, "api_error": 0}
            if modem not in modem_stats:
                modem_stats[modem] = {"success": 0, "fail": 0, "api_error": 0}
                
            if status == "SUCCESS":
                success_cnt += 1
                device_stats[device_id]["success"] += 1
                modem_stats[modem]["success"] += 1
            elif status == "FAIL":
                fail_cnt += 1
                device_stats[device_id]["fail"] += 1
                modem_stats[modem]["fail"] += 1
                
                # Normalize fail message for grouping
                norm_msg = fail_msg
                if "ERROR_LOG_DETECTED" in fail_msg:
                    if "err-999" in fail_msg:
                        norm_msg = "FAIL: err-999 (executionTimeout)"
                    elif "err-112" in fail_msg:
                        norm_msg = "FAIL: err-112 (nCaptcha not initialized)"
                    elif "err-109" in fail_msg:
                        norm_msg = "FAIL: err-109 (incomplete request)"
                    else:
                        norm_msg = "FAIL: errorLog (Other)"
                elif "ADDRESS_NOT_FOUND" in fail_msg:
                    norm_msg = "FAIL: Destination POI not found"
                elif "GUIDANCE_NOT_FOUND" in fail_msg:
                    norm_msg = "FAIL: Guidance start button not found"
                elif "IDENTITY_MISMATCH" in fail_msg:
                    norm_msg = "FAIL: Frida Identity Mismatch"
                elif "PACKET_STUCK" in fail_msg:
                    norm_msg = "FAIL: Packet transmission stuck"
                
                error_breakdown[norm_msg] = error_breakdown.get(norm_msg, 0) + 1
            elif status == "API_ERROR":
                api_error_cnt += 1
                device_stats[device_id]["api_error"] += 1
                modem_stats[modem]["api_error"] += 1
                error_breakdown["API_ERROR: Address matching error (Bypassed)"] = error_breakdown.get("API_ERROR: Address matching error (Bypassed)", 0) + 1
                
            total_cnt += 1

    success_rate = (success_cnt / total_cnt * 100) if total_cnt > 0 else 0.0
    
    # Generate Markdown Output
    report_md = f"""# Naver Map Traffic Simulator Daily Report - {target_date_dashes}
Generated at: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}

## 📊 Summary Statistics
| Metric | Count | Percentage |
| :--- | :--- | :--- |
| **Total Jobs Completed** | {total_cnt} | 100.0% |
| **Success Runs (ACC_LOG)** | {success_cnt} | {success_rate:.2f}% |
| **Failed Runs (ERR_LOG)** | {fail_cnt} | {((fail_cnt / total_cnt * 100) if total_cnt > 0 else 0.0):.2f}% |
| **API Errors (POI Bypassed)** | {api_error_cnt} | {((api_error_cnt / total_cnt * 100) if total_cnt > 0 else 0.0):.2f}% |

---

## 🛑 Failure Reasons Breakdown
| Failure Reason | Occurrences | Share of Failures |
| :--- | :---: | :---: |
"""
    for err, count in sorted(error_breakdown.items(), key=lambda x: x[1], reverse=True):
        share = (count / (fail_cnt + api_error_cnt) * 100) if (fail_cnt + api_error_cnt) > 0 else 0.0
        report_md += f"| {err} | {count} | {share:.1f}% |\n"
        
    report_md += """
---

## 📶 Modem / IP Subnet Performance
| Modem | Total Jobs | Success | Fail | Success Rate |
| :--- | :---: | :---: | :---: | :---: |
"""
    for modem, stats in sorted(modem_stats.items()):
        m_total = stats["success"] + stats["fail"] + stats["api_error"]
        m_rate = (stats["success"] / m_total * 100) if m_total > 0 else 0.0
        report_md += f"| {modem} | {m_total} | {stats['success']} | {stats['fail']} | {m_rate:.2f}% |\n"

    report_md += """
---

## 📱 Top 10 Best Performing Devices
| Device ID | Total Jobs | Success | Fail | Success Rate |
| :--- | :---: | :---: | :---: | :---: |
"""
    sorted_devs = sorted(device_stats.items(), key=lambda x: (x[1]["success"] / (x[1]["success"]+x[1]["fail"]+x[1]["api_error"]) if (x[1]["success"]+x[1]["fail"]+x[1]["api_error"]) > 0 else 0.0, x[1]["success"]), reverse=True)
    for dev_id, stats in sorted_devs[:10]:
        d_total = stats["success"] + stats["fail"] + stats["api_error"]
        d_rate = (stats["success"] / d_total * 100) if d_total > 0 else 0.0
        report_md += f"| {dev_id} | {d_total} | {stats['success']} | {stats['fail']} | {d_rate:.2f}% |\n"

    report_md += """
---

## 📱 Top 10 Worst Performing Devices (High Failures)
| Device ID | Total Jobs | Success | Fail | Success Rate |
| :--- | :---: | :---: | :---: | :---: |
"""
    sorted_devs_worst = sorted(device_stats.items(), key=lambda x: (x[1]["fail"], -(x[1]["success"] / (x[1]["success"]+x[1]["fail"]+x[1]["api_error"]) if (x[1]["success"]+x[1]["fail"]+x[1]["api_error"]) > 0 else 0.0)), reverse=True)
    for dev_id, stats in sorted_devs_worst[:10]:
        d_total = stats["success"] + stats["fail"] + stats["api_error"]
        d_rate = (stats["success"] / d_total * 100) if d_total > 0 else 0.0
        report_md += f"| {dev_id} | {d_total} | {stats['success']} | {stats['fail']} | {d_rate:.2f}% |\n"

    # Write report file
    report_file_path = os.path.join(logs_dir, f"daily_report_{target_date_str}.md")
    with open(report_file_path, "w") as f:
        f.write(report_md)
        
    print(report_md)
    print(f"\n[✓] Daily report written to: {report_file_path}")

if __name__ == "__main__":
    target_date = sys.argv[1] if len(sys.argv) > 1 else None
    generate_report(target_date)
