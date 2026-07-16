#!/usr/bin/env python3
"""
Multi-Modem IP Rotator (LTE IP 갱신 자동화)
- 4개의 모뎀(lte11 ~ lte14)을 독립적으로 120~180분마다 랜덤하게 토글합니다.
- 토글 및 복구 시 smart_toggle.py를 호출하여 안전하게 수행합니다.
- 5분마다 헬스체크를 수행하며, 인터넷이 끊긴 인터페이스는 smart_toggle.py를 통해 자동 치유합니다.
"""

import os
import sys
import time
import json
import re
import subprocess
import random
from datetime import datetime

# Configuration
CHECK_INTERVAL = 60  # 1 minute
MIN_ROTATION_MINUTES = 120  # 2 hours
MAX_ROTATION_MINUTES = 180  # 3 hours
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STATE_FILE = os.path.join(PROJECT_ROOT, "wifi_multi", "logs", "lte_rotator_state.json")


def log(msg):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] {msg}")
    sys.stdout.flush()

def get_lte_interfaces():
    interfaces = []
    try:
        for name in os.listdir('/sys/class/net'):
            addr_file = f"/sys/class/net/{name}/address"
            if os.path.exists(addr_file):
                with open(addr_file, 'r') as f:
                    mac = f.read().strip()
                if mac.startswith("00:1e:10"):
                    subnet = None
                    if name.startswith("lte") and name[3:].isdigit():
                        subnet = int(name[3:])
                    else:
                        addr_info = subprocess.getoutput(f"ip -4 addr show {name}")
                        match = re.search(r'inet 192\.168\.(\d+)\.', addr_info)
                        if match:
                            subnet = int(match.group(1))
                    
                    if subnet and 11 <= subnet <= 20:
                        interfaces.append((name, subnet))
    except Exception as e:
        log(f"Error listing interfaces: {e}")
    return sorted(interfaces)

def get_public_ip(interface):
    try:
        output = subprocess.check_output([
            "curl", "--interface", interface, "-s", "-m", "10", "https://api.ipify.org"
        ], stderr=subprocess.DEVNULL).decode().strip()
        if re.match(r'^\d+\.\d+\.\d+\.\d+$', output):
            return output
    except:
        pass
    return None

def run_smart_toggle(subnet):
    script_path = os.path.join(PROJECT_ROOT, "wifi_multi", "smart_toggle.py")
    try:
        log(f"[{subnet}] Running smart_toggle.py...")
        result = subprocess.run(
            [sys.executable, script_path, str(subnet)],
            capture_output=True, text=True, timeout=150
        )
        if result.returncode == 0:
            try:
                output = json.loads(result.stdout.strip())
                if output.get("success"):
                    log(f"[{subnet}] smart_toggle.py succeeded: {output}")
                    return True, output.get("ip")
                else:
                    log(f"[{subnet}] smart_toggle.py reported failure: {output}")
            except Exception as parse_err:
                log(f"[{subnet}] Failed to parse JSON output: {parse_err}. Raw stdout: {result.stdout.strip()}")
        else:
            log(f"[{subnet}] smart_toggle.py exited with code {result.returncode}. Stderr: {result.stderr.strip()}")
    except Exception as e:
        log(f"[{subnet}] Exception running smart_toggle.py: {e}")
    return False, None

def to_timestamp(dt_str):
    if not dt_str:
        return 0.0
    try:
        return datetime.strptime(dt_str, "%Y-%m-%d %H:%M:%S").timestamp()
    except:
        return 0.0

def to_datetime_str(ts):
    if not ts or ts <= 0:
        return ""
    return datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")

import fcntl

def load_state():
    state = {}
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, 'r', encoding='utf-8') as f:
                # Shared Lock (읽기 락)
                fcntl.flock(f, fcntl.LOCK_SH)
                state = json.load(f)
        except:
            pass
            
    # Normalize structure to nested dicts automatically with human-readable dates
    lte_keys = [name for name, _ in get_lte_interfaces()]
    for k in state.keys():
        if k.startswith("lte") and k not in lte_keys:
            lte_keys.append(k)
            
    def extract_num(s):
        m = re.search(r'\d+', s)
        return int(m.group(0)) if m else 0
    lte_keys = sorted(lte_keys, key=extract_num)
    
    if not lte_keys:
        lte_keys = ["lte11", "lte12", "lte13", "lte14"]
        
    for key in lte_keys:
            
        # Backward migration for old numerical values
        if isinstance(state[key], (int, float)):
            state[key] = {
                "next_scheduled_rotation": to_datetime_str(float(state[key])),
                "last_toggle": "",
                "current_ip": "UNKNOWN",
                "ip_score": 0,
                "last_score_update": ""
            }
        elif not isinstance(state[key], dict):
            state[key] = {}
            
        # Migrate old _ts keys if they exist
        if "next_scheduled_rotation_ts" in state[key]:
            old_ts = state[key].pop("next_scheduled_rotation_ts", 0.0)
            state[key]["next_scheduled_rotation"] = to_datetime_str(old_ts)
        if "last_toggle_ts" in state[key]:
            old_ts = state[key].pop("last_toggle_ts", 0.0)
            state[key]["last_toggle"] = to_datetime_str(old_ts)
            
        state[key].setdefault("next_scheduled_rotation", "")
        state[key].setdefault("last_toggle", "")
        state[key].setdefault("current_ip", "UNKNOWN")
        state[key].setdefault("ip_score", 0)
        state[key].setdefault("last_score_update", "")
        
    return state

def save_state(state):
    try:
         os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
         # Ensure file exists
         if not os.path.exists(STATE_FILE):
             with open(STATE_FILE, 'w', encoding='utf-8') as f:
                 json.dump({}, f)
                 
         with open(STATE_FILE, 'r+', encoding='utf-8') as f:
             # Exclusive Lock (쓰기 배타 락)
             fcntl.flock(f, fcntl.LOCK_EX)
             f.seek(0)
             f.truncate()
             json.dump(state, f, indent=2, ensure_ascii=False)
    except Exception as e:
        log(f"Error saving state: {e}")

def get_next_rotation_ts():
    minutes = random.randint(MIN_ROTATION_MINUTES, MAX_ROTATION_MINUTES)
    return time.time() + (minutes * 60)

def get_local_ip(interface):
    try:
        addr_info = subprocess.getoutput(f"ip -4 addr show {interface}")
        match = re.search(r'inet (\d+\.\d+\.\d+\.\d+)', addr_info)
        if match:
            return match.group(1)
    except:
        pass
    return None

def ensure_ip_rules():
    try:
        rules_output = subprocess.getoutput("ip rule show")
        interfaces = get_lte_interfaces()
        
        for name, subnet in interfaces:
            local_ip = get_local_ip(name)
            if not local_ip:
                log(f"[{name}] No local IP found, skipping IP rule sync.")
                continue
            
            table_name = f"lte{subnet}"
            correct_rule_exists = False
            rules_to_delete = []
            
            for line in rules_output.strip().split('\n'):
                line = line.strip()
                if not line:
                    continue
                parts = line.split(':', 1)
                if len(parts) < 2:
                    continue
                try:
                    priority = int(parts[0].strip())
                except ValueError:
                    continue
                
                rule_detail = parts[1].strip()
                is_for_our_table = False
                if f"lookup {table_name}" in rule_detail or f"table {table_name}" in rule_detail:
                    is_for_our_table = True
                elif f"lookup {subnet}" in rule_detail or f"table {subnet}" in rule_detail:
                    is_for_our_table = True
                
                if is_for_our_table:
                    ip_match = re.search(r'from ([0-9./]+)', rule_detail)
                    if ip_match:
                        rule_ip = ip_match.group(1)
                        if rule_ip == local_ip:
                            if priority < 5210:
                                correct_rule_exists = True
                            else:
                                rules_to_delete.append((priority, rule_ip))
                        else:
                            rules_to_delete.append((priority, rule_ip))
            
            for priority, ip_addr in rules_to_delete:
                log(f"[{name}] Removing outdated IP rule: priority {priority} from {ip_addr} table {table_name}")
                subprocess.run(["sudo", "ip", "rule", "del", "from", ip_addr, "table", table_name, "priority", str(priority)], stderr=subprocess.DEVNULL)
                subprocess.run(["sudo", "ip", "rule", "del", "from", ip_addr, "table", str(subnet), "priority", str(priority)], stderr=subprocess.DEVNULL)
            
            if not correct_rule_exists:
                log(f"[{name}] Adding IP rule: from {local_ip} table {table_name} priority 5209")
                res = subprocess.run(["sudo", "ip", "rule", "add", "from", local_ip, "table", table_name, "priority", "5209"], capture_output=True, text=True)
                if res.returncode != 0:
                    subprocess.run(["sudo", "ip", "rule", "add", "from", local_ip, "table", str(subnet), "priority", "5209"])
    except Exception as e:
        log(f"Error in ensure_ip_rules: {e}")

def is_subnet_active(subnet):
    try:
        # Get list of running main.sh processes to extract active devices
        running_devices = []
        ps_output = subprocess.getoutput("ps -eo args | grep 'main.sh' | grep -v grep")
        for line in ps_output.strip().split('\n'):
            if not line.strip():
                continue
            parts = line.strip().split()
            if len(parts) >= 2:
                dev_id = parts[-1]
                if len(dev_id) > 5:
                    running_devices.append(dev_id)
        
        # Check logs of running devices for active task matching this subnet
        logs_dir = os.path.join(PROJECT_ROOT, "wifi_multi", "logs")
        for dev_id in running_devices:
            task_file = os.path.join(logs_dir, dev_id, "current_task.json")
            if os.path.exists(task_file):
                with open(task_file, 'r', encoding='utf-8', errors='ignore') as f:
                    data = json.load(f)
                    if data.get("subnet") == subnet:
                        status = data.get("status", "IDLE")
                        if status not in ["SUCCESS", "FAIL", "IDLE", "IP_COOLDOWN", "COOLDOWN", "PENALTY", "UNAUTHORIZED"]:
                            return True
    except Exception as e:
        log(f"Error checking subnet active state for {subnet}: {e}")
    return False

def run_rotation():
    ensure_ip_rules()
    state = load_state()
    interfaces = get_lte_interfaces()
    state_changed = False
    
    rotated_interfaces = set()
    toggle_triggered = False # 이번 1분 주기 내 물리 토글 집행 여부 플래그
    
    for name, subnet in interfaces:
        details = state[name]
        next_rotate = to_timestamp(details.get("next_scheduled_rotation", ""))
        last_toggle = to_timestamp(details.get("last_toggle", ""))
        now_ts = time.time()
        
        # 1. 헬스체크 및 실시간 퍼블릭 IP 조회
        curr_ip = get_public_ip(name)
        
        # 2. 오프라인 상태 복구 (IP가 안 잡히는 먹통 상태)
        if not curr_ip:
            if toggle_triggered:
                log(f"[{name}] Interface offline but another rotation is already in progress. Skipping for next check.")
                continue
                
            log(f"[{name}] Interface offline. Triggering smart_toggle.py for recovery...")
            toggle_triggered = True
            success, new_ip = run_smart_toggle(subnet)
            if success:
                log(f"[{name}] Recovery Success! New IP: {new_ip}")
                details["last_toggle"] = to_datetime_str(now_ts)
                details["next_scheduled_rotation"] = to_datetime_str(get_next_rotation_ts())
                details["current_ip"] = new_ip
                details["ip_score"] = 0
                state_changed = True
                rotated_interfaces.add(name)
            else:
                log(f"[{name}] Recovery failed.")
            continue
            
        # Update current_ip in state dynamically if it changed
        if details.get("current_ip") != curr_ip:
            details["current_ip"] = curr_ip
            state_changed = True
            
        # 3. 지능형 IP 점수 기반 토글 판정 (Threshold >= 20, Cooldown >= 60 minutes)
        ip_score = details.get("ip_score", 0)
        cooldown_elapsed = (now_ts - last_toggle) >= 3600 # 60 minutes
        
        if ip_score >= 20:
            if cooldown_elapsed:
                if is_subnet_active(subnet):
                    log(f"[{name}] Dirty IP (Score: {ip_score} >= 20) but subnet has active tasks. Postponing rotation.")
                    continue
                if toggle_triggered:
                    log(f"[{name}] Dirty IP (Score: {ip_score} >= 20) but another rotation is already in progress. Skipping for next check.")
                    continue
                    
                log(f"[{name}] ⚡ [IP SCORING TRIGGER] IP {curr_ip} is dirty (Score: {ip_score} >= 20) and cooldown (60m) elapsed. Initiating early rotation...")
                toggle_triggered = True
                success, new_ip = run_smart_toggle(subnet)
                if success:
                    log(f"[{name}] Score-based Rotation Success! New IP: {new_ip}")
                    details["last_toggle"] = to_datetime_str(now_ts)
                    details["next_scheduled_rotation"] = to_datetime_str(get_next_rotation_ts())
                    details["current_ip"] = new_ip
                    details["ip_score"] = 0
                    state_changed = True
                    rotated_interfaces.add(name)
                else:
                    log(f"[{name}] Score-based Rotation failed. Will retry.")
            else:
                remaining = int(3600 - (now_ts - last_toggle))
                log(f"[{name}] IP {curr_ip} is dirty (Score: {ip_score} >= 20) but 60-minute limit not reached. Waiting {remaining}s. Leaving it alone.")
            continue
            
        # 4. 정기 스케줄 로테이션 (2~3시간 주기)
        if now_ts >= next_rotate:
            if is_subnet_active(subnet):
                log(f"[{name}] Scheduled rotation due but subnet has active tasks. Postponing rotation.")
                continue
            if toggle_triggered:
                log(f"[{name}] Scheduled rotation pending but another rotation is already in progress. Skipping for next check.")
                continue
                
            log(f"[{name}] Starting scheduled IP rotation (subnet {subnet})...")
            toggle_triggered = True
            success, new_ip = run_smart_toggle(subnet)
            if success:
                log(f"[{name}] Rotation Success! New IP: {new_ip}")
                details["last_toggle"] = to_datetime_str(now_ts)
                details["next_scheduled_rotation"] = to_datetime_str(get_next_rotation_ts())
                details["current_ip"] = new_ip
                details["ip_score"] = 0
                log(f"[{name}] Next rotation scheduled at {details['next_scheduled_rotation']}")
                state_changed = True
                rotated_interfaces.add(name)
            else:
                log(f"[{name}] Rotation failed. Will retry.")
        else:
            # IP가 깨끗하게 작동 중인 정상 상태
            log(f"[{name}] IP {curr_ip} is clean (Score: {ip_score} < 20). Keeping alive.")
                
    if state_changed:
        # [🛡️ Concurrency Safety] Merge latest scores from disk before writing to prevent wiping out updates from report.py
        try:
            latest_disk_state = load_state()
            for key in state.keys():
                # 이번 루프에서 방금 실제로 토글/리셋(0점화)된 모뎀은 디스크의 옛날 점수를 합치지 않고 0점 보존
                if key in rotated_interfaces:
                    continue
                if key in latest_disk_state and isinstance(latest_disk_state[key], dict):
                    # 디스크상의 최신 스코어 및 채점 업데이트 시간 보존
                    state[key]["ip_score"] = latest_disk_state[key].get("ip_score", 0)
                    state[key]["last_score_update"] = latest_disk_state[key].get("last_score_update", "")
        except Exception as merge_err:
            log(f"Error merging scores from disk during save: {merge_err}")
            
        save_state(state)

def main():
    log("LTE IP Rotator started (Randomized Interval: 120-180m)")
    # Force initial PBR routing table configuration
    log("Running initial routing setup...")
    subprocess.run(["sudo", "bash", f"{PROJECT_ROOT}/utils/lte_surgical_setup.sh"])
    
    log("Running initial IP rules synchronization...")
    ensure_ip_rules()
    
    while True:
        try:
            run_rotation()
        except Exception as e:
            log(f"Error in main loop: {e}")
        time.sleep(CHECK_INTERVAL)

if __name__ == "__main__":
    main()

