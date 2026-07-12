#!/usr/bin/env python3
# wifi_multi/lib/report.py: Advanced Post-Run Identity Laundering Audit Engine
import os
import sys
import json
import glob
import re
from datetime import datetime

def main():
    if len(sys.argv) < 5:
        print("[!] Missing arguments for report.py", file=sys.stderr)
        sys.exit(2)
        
    log_dir = sys.argv[1]
    device_id = sys.argv[2]
    task_id = sys.argv[3]
    reason = sys.argv[4]
    
    # 1. Load original & spoofed pairs from environment
    pairs = {
        "ssaid": (os.environ.get("NMAP_ORIG_SSAID"), os.environ.get("NMAP_ID_SSAID")),
        "adid": (os.environ.get("NMAP_ORIG_ADID"), os.environ.get("NMAP_ID_ADID")),
        "idfv": (os.environ.get("NMAP_ORIG_IDFV"), os.environ.get("NMAP_ID_IDFV")),
        "ni": (os.environ.get("NMAP_ORIG_NI"), os.environ.get("NMAP_ID_NI")),
        "token": (os.environ.get("NMAP_ORIG_TOKEN"), os.environ.get("NMAP_ID_TOKEN")),
    }
    
    # 2. Scan packets for counts
    actual_replacements = {}
    
    # Target files to audit (ignore local log/debug files)
    ignore_files = {"api_response.json", "session_summary.json", "execution.log", "report.json", "result.json"}
    target_files = []
    for root, _, files in os.walk(log_dir):
        for f in files:
            if f not in ignore_files and (f.endswith(".json") or f.endswith(".jsonl") or f.endswith(".log")):
                target_files.append(os.path.join(root, f))
                
    # Read target content
    all_content = ""
    for fpath in target_files:
        try:
            with open(fpath, "r", encoding="utf-8", errors="ignore") as f:
                all_content += f.read() + "\n"
        except: pass
        
    # Analyze replacement status for each identifier
    leak_detected = False
    leak_msg_list = []
    
    for key, (orig, spoof) in pairs.items():
        orig_count = 0
        spoof_count = 0
        
        if orig and len(orig) > 5:
            # Count original appearances (case-insensitive)
            orig_count = all_content.lower().count(orig.lower())
        if spoof and len(spoof) > 5:
            # Count spoofed appearances (case-insensitive)
            spoof_count = all_content.lower().count(spoof.lower())
            
        status = "NOT_TRANSMITTED"
        if orig_count > 0:
            status = "FAILED_LEAKED"
            leak_detected = True
            leak_msg_list.append(f"{key} leaked {orig_count} times")
        elif spoof_count > 0:
            status = "SUCCESSFULLY_REPLACED"
            
        actual_replacements[key] = {
            "status": status,
            "original_value": orig,
            "spoofed_value": spoof,
            "original_found_count": orig_count,
            "spoofed_found_count": spoof_count
        }
        
    # 3. Parse captured cookies from v2_tokens.json
    cookie_data = {
        "NAPP_DI": None, "NAC": None, "NNB": None, "BUC": None, "NSCS": None
    }
    token_files = glob.glob(os.path.join(log_dir, "**/*_POST_v2_tokens.json"), recursive=True)
    if token_files:
        token_files.sort(reverse=True)
        try:
            with open(token_files[0], "r", encoding="utf-8", errors="ignore") as f:
                t_json = json.load(f)
                cookie_str = t_json.get("request", {}).get("headers", {}).get("cookie", "")
                if cookie_str:
                    for k in cookie_data.keys():
                        m = re.search(rf"{k}=([^,; ]+)", cookie_str)
                        if m:
                            cookie_data[k] = m.group(1)
        except: pass
        
    # 4. Build report object
    leak_msg = "; ".join(leak_msg_list)
    report = {
        "task_metadata": {
            "task_id": int(task_id) if task_id.isdigit() else task_id,
            "device_id": device_id,
            "termination_reason": reason,
            "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        },
        "security_audit": {
            "leak_status": "LEAK_DETECTED" if leak_detected else "CLEAN",
            "leak_message": leak_msg
        },
        "identity_spoofing_audit": actual_replacements,
        "actual_captured_cookies": cookie_data
    }
    
    # Save to report.json
    report_path = os.path.join(log_dir, "report.json")
    with open(report_path, "w", encoding="utf-8") as rf:
        json.dump(report, rf, indent=2, ensure_ascii=False)
        
    print(f"[✓] report.json generated successfully. Leak Status: {report['security_audit']['leak_status']}")
    
    if leak_detected:
        sys.exit(1)
    else:
        sys.exit(0)

if __name__ == "__main__":
    main()
