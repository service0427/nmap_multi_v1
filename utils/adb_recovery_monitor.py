#!/usr/bin/env python3
import subprocess
import time
import os
import sys
import json
from datetime import datetime

def run_adb_cmd(args, timeout_sec=5):
    """Runs an adb command wrapped in linux timeout tool to prevent D-state hangs."""
    cmd = ["timeout", str(timeout_sec), "adb"] + args
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_sec + 2)
        if res.returncode == 124:
            return False, "", "ADB command timed out via linux timeout tool (D-state safety)"
        return True, res.stdout, res.stderr
    except Exception as e:
        return False, "", f"Execution error: {e}"

# Configuration
CHECK_INTERVAL_SEC = 30  # 30 seconds
ADB_TIMEOUT_SEC = 5
TECH_USER = "tech"
TECH_HOME = f"/home/{TECH_USER}"
TECH_ANDROID_DIR = os.path.join(TECH_HOME, ".android")

def log(level, message):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] [{level}] {message}", flush=True)

def get_adb_processes():
    """Returns a list of tuples (pid, user, cmd) for all adb processes."""
    processes = []
    try:
        # Run ps to get pid, user, and command arguments
        res = subprocess.run(["ps", "-Ao", "pid,user,args"], capture_output=True, text=True, check=True)
        for line in res.stdout.strip().split("\n")[1:]:  # Skip header
            parts = line.strip().split(None, 2)
            if len(parts) >= 3:
                pid, user, cmd = parts[0], parts[1], parts[2]
                # Filter for processes containing 'adb' but exclude grep, ps, or this monitor itself
                if "adb" in cmd and "grep" not in cmd and "adb_recovery_monitor" not in cmd:
                    try:
                        processes.append((int(pid), user, cmd))
                    except ValueError:
                        continue
    except Exception as e:
        log("ERROR", f"Failed to list processes: {e}")
    return processes

def kill_processes(pids, use_sudo=False):
    """Kills a list of PIDs."""
    if not pids:
        return
    log("INFO", f"Killing processes (use_sudo={use_sudo}): {pids}")
    cmd = ["sudo", "kill", "-9"] if use_sudo else ["kill", "-9"]
    cmd.extend(str(pid) for pid in pids)
    try:
        subprocess.run(cmd, check=True)
    except Exception as e:
        log("ERROR", f"Failed to kill processes: {e}")

def perform_recovery():
    log("WARNING", "Initiating ADB Recovery...")
    
    # 1. Gather all adb processes
    procs = get_adb_processes()
    root_pids = [pid for pid, user, _ in procs if user == "root"]
    tech_pids = [pid for pid, user, _ in procs if user == TECH_USER]

    # 2. Kill root-owned processes
    if root_pids:
        log("INFO", f"Found {len(root_pids)} root-owned adb processes. Killing them...")
        kill_processes(root_pids, use_sudo=True)

    # 3. Kill tech-owned processes
    if tech_pids:
        log("INFO", f"Found {len(tech_pids)} tech-owned adb processes. Killing them...")
        kill_processes(tech_pids, use_sudo=False)

    # Clean killall safety just in case
    try:
        subprocess.run(["sudo", "killall", "-9", "adb"], stderr=subprocess.DEVNULL)
        subprocess.run(["killall", "-9", "adb"], stderr=subprocess.DEVNULL)
    except:
        pass

    # Wait a bit for sockets to free up
    time.sleep(2)

    # 5. Start adb server as tech with explicit HOME directory
    try:
        log("INFO", "Starting adb server as tech user with explicit HOME=/home/tech ...")
        import os
        env = os.environ.copy()
        env["HOME"] = "/home/tech"
        # Explicitly pass HOME environment variable to ensure consistent adbkey usage
        subprocess.run(["adb", "start-server"], env=env, check=True)
    except Exception as e:
        log("ERROR", f"Failed to start adb server: {e}")
        return False

    # 6. Verify
    success, stdout, stderr = run_adb_cmd(["devices"], timeout_sec=5)
    if success:
        # Count connected devices
        lines = stdout.strip().split("\n")
        device_count = sum(1 for line in lines[1:] if line.strip() and not line.startswith("*"))
        log("SUCCESS", f"ADB server recovered successfully. {device_count} devices attached.")
        return True
    else:
        log("ERROR", f"ADB verification failed: {stderr}")
        return False

RECOVERY_LOG_PATH = "/home/tech/nmap_multi_v1/adb_recovery.log"

def write_recovery_log(event_type, details):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    log_entry = f"[{timestamp}] [{event_type}] {details}\n"
    try:
        with open(RECOVERY_LOG_PATH, 'a') as f:
            f.write(log_entry)
        # Ensure tech user and others can write/read the log safely
        os.chmod(RECOVERY_LOG_PATH, 0o666)
    except Exception as e:
        log("ERROR", f"Failed to write to adb_recovery.log: {e}")

def get_usb_path_by_serial(serial):
    # 1. Try reading from usb_ports.json first (No FS scan, 100% safe against D-state)
    config_path = "/home/tech/nmap_multi_v1/wifi_multi/config/usb_ports.json"
    if os.path.exists(config_path):
        try:
            with open(config_path, "r") as f:
                usb_ports = json.load(f)
            if serial in usb_ports:
                return usb_ports[serial].replace("usb:", "")
        except Exception as e:
            log("ERROR", f"Failed to read usb_ports.json: {e}")

    # 2. Fallback to shell-level grep with 2-second timeout to prevent D-state hangs
    try:
        cmd = f"timeout 2 grep -s -l '^{serial}$' /sys/bus/usb/devices/*/serial"
        res = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        if res.returncode == 0 and res.stdout.strip():
            path = res.stdout.strip().split("\n")[0]
            parts = path.split("/")
            if len(parts) >= 2:
                return parts[-2]
    except Exception as e:
        log("ERROR", f"Fallback grep scanning failed: {e}")
    return None

def reset_usb_device(usb_path):
    unbind_file = "/sys/bus/usb/drivers/usb/unbind"
    bind_file = "/sys/bus/usb/drivers/usb/bind"
    log("INFO", f"Targeting USB port {usb_path} for hardware unbind/bind reset...")
    try:
        # 1. Unbind port
        res_unbind = subprocess.run(
            ["sudo", "tee", unbind_file],
            input=usb_path.encode(),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE
        )
        if res_unbind.returncode == 0:
            log("INFO", f"Successfully sent unbind to {usb_path}")
        else:
            log("ERROR", f"Unbind failed for {usb_path}: {res_unbind.stderr.decode().strip()}")
            return False

        # Wait 2 seconds for hardware power down
        time.sleep(2)

        # 2. Bind port
        res_bind = subprocess.run(
            ["sudo", "tee", bind_file],
            input=usb_path.encode(),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE
        )
        if res_bind.returncode == 0:
            log("INFO", f"Successfully sent bind to {usb_path}")
            return True
        else:
            log("ERROR", f"Bind failed for {usb_path}: {res_bind.stderr.decode().strip()}")
    except Exception as e:
        log("ERROR", f"Failed to execute hardware reset for {usb_path}: {e}")
    return False

def check_adb_status():
    """
    Checks the adb server status.
    Returns (is_ok, reason, bad_serials, device_count, root_pids)
    """
    # 1. Check for root processes (Collect but don't fail immediately, we will kill them target-selectively)
    procs = get_adb_processes()
    root_pids = [p[0] for p in procs if p[1] == "root"]

    # 2. Check for adb hanging
    try:
        success, stdout, stderr = run_adb_cmd(["devices"], timeout_sec=ADB_TIMEOUT_SEC)
        if not success:
            return False, f"adb devices failed: {stderr}", [], 0, root_pids
        
        # Parse device count and statuses
        lines = stdout.strip().split("\n")
        device_count = 0
        connected_serials = []
        unauthorized_serials = []
        offline_serials = []
        for line in lines[1:]:
            line = line.strip()
            if not line or line.startswith("*"):
                continue
            device_count += 1
            parts = line.split()
            if not parts:
                continue
            serial = parts[0]
            connected_serials.append(serial)
            if "unauthorized" in line:
                unauthorized_serials.append(serial)
            elif "offline" in line:
                offline_serials.append(serial)

        # 3. Detect completely missing devices (configured in usb_ports.json but not in adb output)
        missing_serials = []
        config_path = "/home/tech/nmap_multi_v1/wifi_multi/config/usb_ports.json"
        if os.path.exists(config_path):
            try:
                with open(config_path, "r") as f:
                    usb_ports = json.load(f)
                for serial in usb_ports:
                    if serial not in connected_serials:
                        missing_serials.append(serial)
            except Exception as e:
                log("ERROR", f"Failed to check missing devices from config: {e}")

        bad_serials = list(set(unauthorized_serials + offline_serials + missing_serials))
        if bad_serials:
            reasons = []
            if unauthorized_serials: reasons.append(f"unauthorized: {unauthorized_serials}")
            if offline_serials: reasons.append(f"offline: {offline_serials}")
            if missing_serials: reasons.append(f"missing: {missing_serials}")
            reason_str = "Problematic/Missing devices detected: " + ", ".join(reasons)
            return False, reason_str, bad_serials, device_count, root_pids
            
        return True, "OK", [], device_count, root_pids

    except subprocess.TimeoutExpired:
        return False, "adb devices command timed out", [], 0, root_pids
    except Exception as e:
        return False, f"adb check encountered error: {e}", [], 0, root_pids

def main():
    log("INFO", "ADB Recovery Monitor Daemon started (Pinpoint Targeted Healing active).")
    
    bad_consecutive_counts = {}
    global_hang_streak = 0
    
    while True:
        try:
            is_ok, reason, bad_serials, dev_count, root_pids = check_adb_status()
            
            # 1. Root adb 프로세스가 발견되면 전체 리셋 대신 해당 Root PID만 조용히 저격 사살
            if root_pids:
                log("WARNING", f"Root-owned adb process detected (PIDs: {root_pids}). Targeted kill...")
                kill_processes(root_pids, use_sudo=True)
                write_recovery_log("TARGETED_ROOT_KILL", f"Killed root adb PIDs: {root_pids}")
                time.sleep(2)
                continue
            
            # Update bad serials counters
            for serial in bad_serials:
                bad_consecutive_counts[serial] = bad_consecutive_counts.get(serial, 0) + 1
            # Reset counters for successful/unseen devices
            for serial in list(bad_consecutive_counts.keys()):
                if serial not in bad_serials:
                    bad_consecutive_counts[serial] = 0

            if not is_ok:
                log("WARNING", f"ADB issues/deviations detected: {reason}")
                
                # Case A: 개별 단말기 꼬임 (Offline / Unauthorized) ➡️ 기기별 저격 치유 (전체 리셋 안 함!)
                if bad_serials and "Problematic" in reason:
                    global_hang_streak = 0 # ADB 서버 자체는 통신이 되므로 행상태 아님
                    target_resets = []
                    for serial in bad_serials:
                        streak = bad_consecutive_counts.get(serial, 0)
                        
                        # 1단계: 초반 1~2회 오동작 시 가벼운 소프트웨어 reconnect 재시도
                        if streak <= 2:
                            log("INFO", f"Attempting quick software reconnect for {serial} (Streak: {streak})")
                            run_adb_cmd(["-s", serial, "reconnect"], timeout_sec=5)
                            run_adb_cmd(["-s", serial, "reconnect", "device"], timeout_sec=5)
                        
                        # 2단계: 1분(2회) 이상 꼬임 지속 시 하드웨어 USB unbind/bind 리셋
                        if streak >= 2:
                            target_resets.append(serial)
                        else:
                            log("INFO", f"Device {serial} is problematic. Streak: {streak}/2 (Waiting grace period...)")
                    
                    if target_resets:
                        log("INFO", f"Handling pinpoint recovery for persistent offline/unauthorized serials: {target_resets}")
                        for serial in target_resets:
                            usb_path = get_usb_path_by_serial(serial)
                            if usb_path:
                                log("INFO", f"Pinpoint USB reset for {serial} on USB path {usb_path}")
                                success = reset_usb_device(usb_path)
                                if success:
                                    write_recovery_log("PINPOINT_RECOVERY", f"Successfully reset problematic {serial} at USB {usb_path}")
                                else:
                                    write_recovery_log("PINPOINT_FAILED", f"Failed reset problematic {serial} at USB {usb_path}")
                            else:
                                log("WARNING", f"Could not find USB path for serial {serial}")
                                write_recovery_log("PINPOINT_NOT_FOUND", f"USB path not found for {serial}")
                            # Reset counter after recovery attempt
                            bad_consecutive_counts[serial] = 0
                        time.sleep(10)
                
                # Case B: ADB 서버 자체가 완전히 먹통(Timeout/Failed) ➡️ 3회 연속 지속 시에만 전체 리셋 단행!
                else:
                    global_hang_streak += 1
                    if global_hang_streak >= 3:
                        log("CRITICAL", f"ADB server is unresponsive for 3 consecutive check cycles ({reason}). Executing GLOBAL RECOVERY...")
                        perform_recovery()
                        write_recovery_log("GLOBAL_RECOVERY", f"Restarted entire ADB server due to: {reason}")
                        global_hang_streak = 0
                        time.sleep(10)
                    else:
                        log("WARNING", f"ADB server unresponsive. Streak: {global_hang_streak}/3. Waiting next cycle before global recovery...")
            else:
                global_hang_streak = 0
                log("INFO", f"ADB status check: OK ({dev_count} devices connected)")
        except Exception as e:
            log("ERROR", f"Exception in main loop: {e}")
            
        time.sleep(CHECK_INTERVAL_SEC)

if __name__ == "__main__":
    main()
