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
CHECK_INTERVAL = 300  # 5 minutes
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

def load_state():
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, 'r') as f:
                return json.load(f)
        except:
            pass
    return {}

def save_state(state):
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        with open(STATE_FILE, 'w') as f:
            json.dump(state, f)
    except Exception as e:
        log(f"Error saving state: {e}")

def get_next_rotation_ts():
    minutes = random.randint(MIN_ROTATION_MINUTES, MAX_ROTATION_MINUTES)
    return time.time() + (minutes * 60)

def run_rotation():
    state = load_state()
    interfaces = get_lte_interfaces()
    
    for name, subnet in interfaces:
        next_rotate = state.get(name, 0)
        now_ts = time.time()
        
        # Check if rotation is needed
        if now_ts >= next_rotate:
                
            log(f"[{name}] Starting scheduled IP rotation (subnet {subnet})...")
            success, new_ip = run_smart_toggle(subnet)
            if success:
                log(f"[{name}] Rotation Success! New IP: {new_ip}")
                state[name] = get_next_rotation_ts()
                next_dt = datetime.fromtimestamp(state[name]).strftime("%Y-%m-%d %H:%M:%S")
                log(f"[{name}] Next rotation scheduled at {next_dt}")
            else:
                log(f"[{name}] Rotation failed. Will retry next cycle or via health check.")
        else:
            # Not yet time for rotation, check health
            if not get_public_ip(name):
                log(f"[{name}] Interface offline during health check. Triggering smart_toggle.py for recovery...")
                success, new_ip = run_smart_toggle(subnet)
                if success:
                    log(f"[{name}] Recovery Success! New IP: {new_ip}")
                else:
                    log(f"[{name}] Recovery failed.")
                
    save_state(state)

def main():
    log("LTE IP Rotator started (Randomized Interval: 120-180m)")
    # Force initial PBR routing table configuration
    log("Running initial routing setup...")
    subprocess.run(["sudo", "bash", f"{PROJECT_ROOT}/utils/lte_surgical_setup.sh"])
    
    while True:
        try:
            run_rotation()
        except Exception as e:
            log(f"Error in main loop: {e}")
        time.sleep(CHECK_INTERVAL)

if __name__ == "__main__":
    main()
