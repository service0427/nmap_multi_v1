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
    ignore_files = {"api_response.json", "session_summary.json", "execution.log", "report.json", "result.json", "events.log"}
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
                content = f.read()
                
                # JSON 로그 파일의 경우, 원래 유출 감시를 위해 저장해둔 로컬 디버깅용 복제 키(original_*)를 제외하고 실제 송신값만 검사
                if fpath.endswith(".json"):
                    try:
                        obj = json.loads(content)
                        def clean_original_logs(item):
                            if isinstance(item, dict):
                                for k in list(item.keys()):
                                    if k.startswith("original_") or k == "_raw":
                                        item.pop(k)
                                    else:
                                        clean_original_logs(item[k])
                            elif isinstance(item, list):
                                for x in item:
                                    clean_original_logs(x)
                        clean_original_logs(obj)
                        content = json.dumps(obj)
                    except:
                        pass
                
                all_content += content + "\n"
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
    
    # [🚀 Unified Score-based IP Rotator Integration with Exclusive File Lock]
    # Update lte_rotator_state.json dynamically based on the session execution result
    try:
        real_ip = "UNKNOWN"
        bind_ip = "UNKNOWN"
        
        # 1. Parse real_ip from session_summary.json
        summary_path = os.path.join(log_dir, "session_summary.json")
        if os.path.exists(summary_path):
            with open(summary_path, 'r', encoding='utf-8', errors='ignore') as sf:
                summary_data = json.load(sf)
                real_ip = summary_data.get("real_ip", "UNKNOWN")
        
        # 2. Parse bind_ip and real_ip from execution.log
        exec_log_path = os.path.join(log_dir, "execution.log")
        if os.path.exists(exec_log_path):
            with open(exec_log_path, 'r', encoding='utf-8', errors='ignore') as ef:
                exec_content = ef.read()
                if real_ip == "UNKNOWN":
                    ip_match = re.search(r'Real IPv4:\s*([0-9\.]+)', exec_content)
                    if ip_match:
                        real_ip = ip_match.group(1)
                
                # BIND_IP 파싱 (예: BIND_IP:192.168.11.106)
                bind_match = re.search(r'BIND_IP:([0-9\.]+)', exec_content)
                if bind_match:
                    bind_ip = bind_match.group(1)
        
        # 3. Check for errorLog and accessLog
        has_real_error_log = False
        has_access_log = False
        
        error_log_files = glob.glob(os.path.join(log_dir, "**/*_POST_client-logger_errorLog.json"), recursive=True)
        for ef in error_log_files:
            try:
                with open(ef, 'r', encoding='utf-8', errors='ignore') as f:
                    data = json.load(f)
                    if data.get("url") == "https://ncpt.naver.com/client-logger/errorLog":
                        body = data.get("request", {}).get("body", {})
                        if isinstance(body, dict):
                            msg = body.get("message")
                            if msg:
                                has_real_error_log = True
                                break
            except:
                pass

        access_log_files = glob.glob(os.path.join(log_dir, "**/*_POST_client-logger_accessLog.json"), recursive=True)
        for af in access_log_files:
            try:
                with open(af, 'r', encoding='utf-8', errors='ignore') as f:
                    data = json.load(f)
                    if data.get("url") == "https://ncpt.naver.com/client-logger/accessLog":
                        has_access_log = True
                        break
            except:
                pass

        # Determine modem interface by BIND_IP subnet
        modem_name = None
        if bind_ip != "UNKNOWN":
            parts = bind_ip.split('.')
            if len(parts) >= 3:
                subnet_num = parts[2] # 11, 12, 13, 14
                if subnet_num.isdigit() and 11 <= int(subnet_num) <= 20:
                    modem_name = f"lte{subnet_num}"

        state_file = "/home/tech/nmap_multi_v1/wifi_multi/logs/lte_rotator_state.json"
        os.makedirs(os.path.dirname(state_file), exist_ok=True)
        
        # [🛡️ Unix Exclusive File Lock Implementation]
        import fcntl
        
        # Ensure file exists first
        if not os.path.exists(state_file):
            with open(state_file, 'w', encoding='utf-8') as f:
                json.dump({}, f)
                
        with open(state_file, 'r+', encoding='utf-8') as s_f:
            # 락 획득 (대기 상태 진입)
            fcntl.flock(s_f, fcntl.LOCK_EX)
            
            try:
                state_data = json.load(s_f)
            except:
                state_data = {}
                
            # ip에서 lte가 붙은 인터페이스들을 순서대로 탐색 (예: lte11, lte12...)
            lte_keys = []
            try:
                for name in os.listdir('/sys/class/net'):
                    if name.startswith("lte"):
                        lte_keys.append(name)
            except:
                pass
            
            # 숫자 기반 정렬 (문자열 정렬 시 lte100이 lte2보다 앞에 오는 문제 방지)
            def extract_num(s):
                m = re.search(r'\d+', s)
                return int(m.group(0)) if m else 0
            lte_keys = sorted(list(set(lte_keys)), key=extract_num)
            
            # 기존 상태 데이터에 등록되어 있는 lte* 키들도 누락되지 않도록 통합 및 재정렬
            for k in state_data.keys():
                if k.startswith("lte") and k not in lte_keys:
                    lte_keys.append(k)
            lte_keys = sorted(lte_keys, key=extract_num)
            
            if not lte_keys:
                lte_keys = ["lte11", "lte12", "lte13", "lte14"]
                
            # 만약 기존 1세대(단순 타임스탬프) 구조가 남아있다면 정규화 객체 구조로 즉시 자동 변환
            for key in lte_keys:
                if key not in state_data:
                    state_data[key] = {}
                if isinstance(state_data[key], (int, float)):
                    state_data[key] = {
                        "next_scheduled_rotation": "",
                        "last_toggle": "",
                        "current_ip": "UNKNOWN",
                        "ip_score": 0,
                        "last_score_update": ""
                    }
                elif not isinstance(state_data[key], dict):
                    state_data[key] = {}
                    
                # 필수 디렉토리 키 보장
                state_data[key].setdefault("next_scheduled_rotation", "")
                state_data[key].setdefault("last_toggle", "")
                state_data[key].setdefault("current_ip", "UNKNOWN")
                state_data[key].setdefault("ip_score", 0)
                state_data[key].setdefault("last_score_update", "")
                
            # 모뎀 특정 (IP 매치 혹은 서브넷 매치)
            if not modem_name and real_ip != "UNKNOWN":
                for name, details in state_data.items():
                    if isinstance(details, dict) and details.get("current_ip") == real_ip:
                        modem_name = name
                        break
                        
            if modem_name and modem_name in state_data:
                details = state_data[modem_name]
                registered_ip = details.get("current_ip", "UNKNOWN")
                
                # [🛡️ Timing Issue Guard]
                if registered_ip != "UNKNOWN" and real_ip != "UNKNOWN" and registered_ip != real_ip:
                    print(f"[⚪ IP SCORING] Skipped score update: Session IP {real_ip} does not match current registered IP {registered_ip} on {modem_name} (likely rotated during drive).")
                else:
                    curr_score = details.get("ip_score", 0)
                    
                    # Scoring Logic (errorLog: +1, accessLog: -2, neither: 0)
                    change_amount = 0
                    event_type = "NEUTRAL"
                    
                    if has_real_error_log:
                        new_score = min(100, curr_score + 1)
                        change_amount = 1
                        event_type = "ERR_LOG"
                        log_msg = f"[🛑 IP SCORING] {modem_name} ({real_ip}) hit errorLog. Score: {curr_score} -> {new_score}"
                    elif has_access_log and reason == "Task Completed":
                        new_score = max(-100, curr_score - 2)
                        change_amount = -2
                        event_type = "ACC_LOG"
                        log_msg = f"[🟢 IP SCORING] {modem_name} ({real_ip}) accessLog SUCCESS. Score: {curr_score} -> {new_score}"
                    else:
                        new_score = curr_score
                        log_msg = f"[⚪ IP SCORING] {modem_name} ({real_ip}) neutral (Reason: {reason}). Score: {curr_score}"
                        
                    details["ip_score"] = new_score
                    details["last_score_update"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                    if real_ip != "UNKNOWN":
                        details["current_ip"] = real_ip
                    
                    # [📜 Daily Partitioning Score History Record Logger]
                    # nmap-log-cleaner의 청소 영향성을 차단하기 위해 logs/rotator_history/ 격리 폴더 내에 누적합니다.
                    try:
                        today_str = datetime.now().strftime("%Y%m%d")
                        history_dir = os.path.join(os.path.dirname(state_file), "rotator_history")
                        os.makedirs(history_dir, exist_ok=True)
                        history_file = os.path.join(history_dir, f"scoring_history_{today_str}.log")
                        
                        sign_str = f"+{change_amount}" if change_amount > 0 else str(change_amount)
                        
                        # [🕒 HH:MM:SS.FFF 포맷 및 칼줄 정렬 적용]
                        now_dt = datetime.now()
                        time_stamp = now_dt.strftime("%H:%M:%S") + f".{now_dt.microsecond // 1000:03d}"
                        
                        # 기동 폴더명 파싱을 통한 시작 시각(Start Time) 획득
                        start_time_str = "UNKNOWN"
                        try:
                            base_name = os.path.basename(log_dir)
                            time_match = re.match(r'^(\d{2})(\d{2})(\d{2})_', base_name)
                            if time_match:
                                start_time_str = f"{time_match.group(1)}:{time_match.group(2)}:{time_match.group(3)}"
                        except:
                            pass
                        
                        end_time_str = now_dt.strftime("%H:%M:%S")
                        time_range_str = f"({start_time_str} ~ {end_time_str})"
                        
                        padded_ip = f"{real_ip:<15}"
                        padded_modem = f"{modem_name:<5}"
                        padded_event = f"{event_type:<9}"
                        padded_sign = f"{sign_str:<4}"
                        
                        # 오직 점수 변동이 실제 있는 경우에만 일자별 레코드를 기입합니다 (Change != 0)
                        if change_amount != 0:
                            record_line = f"[{time_stamp}] [{padded_modem}] ({padded_ip}) {padded_event} {time_range_str} -> Score: {curr_score:4d} -> {new_score:4d} (Change: {padded_sign})\n"
                            with open(history_file, 'a', encoding='utf-8') as h_f:
                                h_f.write(record_line)
                    except Exception as history_err:
                        print(f"[-] Error writing history record: {history_err}", file=sys.stderr)
                    
                    print(log_msg)
                    s_f.seek(0)
                    s_f.truncate()
                    json.dump(state_data, s_f, indent=2, ensure_ascii=False)
            else:
                print(f"[⚪ IP SCORING] Could not map real_ip {real_ip} or bind_ip {bind_ip} to any modem interface.")
                
    except Exception as score_err:
        print(f"[-] Error writing unified IP scores: {score_err}", file=sys.stderr)
        
    if leak_detected:
        sys.exit(1)
    else:
        sys.exit(0)

if __name__ == "__main__":
    main()
