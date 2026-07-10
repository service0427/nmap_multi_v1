#!/usr/bin/env python3
import subprocess
import time
import os
import sys
from datetime import datetime

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

# adbkey synchronization logic removed as per user preference (manual local verification only)

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

    # 5. Start adb server as tech
    try:
        log("INFO", "Starting adb server as tech user...")
        # Explicitly run as tech
        subprocess.run(["adb", "start-server"], check=True)
    except Exception as e:
        log("ERROR", f"Failed to start adb server: {e}")
        return False

    # 6. Verify
    try:
        res = subprocess.run(["adb", "devices"], capture_output=True, text=True, timeout=5)
        if res.returncode == 0:
            # Count connected devices
            lines = res.stdout.strip().split("\n")
            device_count = sum(1 for line in lines[1:] if line.strip() and not line.startswith("*"))
            log("SUCCESS", f"ADB server recovered successfully. {device_count} devices attached.")
            return True
        else:
            log("ERROR", f"ADB verification returned exit code {res.returncode}")
            return False
    except subprocess.TimeoutExpired:
        log("ERROR", "ADB verification timed out during recovery validation.")
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
    base_dir = "/sys/bus/usb/devices"
    if not os.path.exists(base_dir):
        return None
    try:
        for d in os.listdir(base_dir):
            serial_file = os.path.join(base_dir, d, "serial")
            if os.path.exists(serial_file):
                try:
                    with open(serial_file, 'r') as f:
                        if f.read().strip() == serial:
                            return d
                except Exception:
                    pass
    except Exception as e:
        log("ERROR", f"Error scanning sysfs for serial {serial}: {e}")
    return None

def reset_usb_device(usb_path):
    unbind_file = "/sys/bus/usb/drivers/usb/unbind"
    log("INFO", f"Targeting USB port {usb_path} for unbind reset...")
    try:
        # Since monitor runs as tech, write via sudo tee
        res = subprocess.run(
            ["sudo", "tee", unbind_file],
            input=usb_path.encode(),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE
        )
        if res.returncode == 0:
            log("INFO", f"Successfully sent unbind to {usb_path}")
            return True
        else:
            log("ERROR", f"Unbind failed for {usb_path}: {res.stderr.decode().strip()}")
    except Exception as e:
        log("ERROR", f"Failed to execute unbind for {usb_path}: {e}")
    return False

def check_adb_status():
    """
    Checks the adb server status.
    Returns (is_ok, reason, unauthorized_serials, device_count)
    """
    # 1. Check for root processes
    procs = get_adb_processes()
    root_procs = [p for p in procs if p[1] == "root"]
    if root_procs:
        return False, f"Root-owned adb process detected (PID: {root_procs[0][0]})", [], 0

    # 2. Check for adb hanging
    try:
        res = subprocess.run(["adb", "devices"], capture_output=True, text=True, timeout=ADB_TIMEOUT_SEC)
        if res.returncode != 0:
            return False, f"adb devices failed with code {res.returncode}", [], 0
        
        # Parse device count
        lines = res.stdout.strip().split("\n")
        device_count = 0
        unauthorized_serials = []
        for line in lines[1:]:
            line = line.strip()
            if not line or line.startswith("*"):
                continue
            device_count += 1
            if "unauthorized" in line:
                parts = line.split()
                if parts:
                    unauthorized_serials.append(parts[0])

        if device_count > 0:
            unauthorized_pct = len(unauthorized_serials) / device_count
            if unauthorized_pct >= 0.20:
                # 20% or more are unauthorized
                return False, f"Global issue: {len(unauthorized_serials)}/{device_count} ({unauthorized_pct*100:.1f}%) devices are unauthorized", unauthorized_serials, device_count
            elif len(unauthorized_serials) > 0:
                # Less than 20% unauthorized
                return False, f"Pinpoint issue: {len(unauthorized_serials)}/{device_count} devices are unauthorized", unauthorized_serials, device_count
            
        return True, "OK", [], device_count

    except subprocess.TimeoutExpired:
        return False, "adb devices command timed out", [], 0
    except Exception as e:
        return False, f"adb check encountered error: {e}", [], 0

def main():
    log("INFO", "ADB Recovery Monitor Daemon started.")
    
    # Run an initial check
    
    unauthorized_consecutive_counts = {}
    global_unauthorized_streak = 0
    
    while True:
        try:
            is_ok, reason, unauthorized_serials, dev_count = check_adb_status()
            
            # Update unauthorized serials counters
            for serial in unauthorized_serials:
                unauthorized_consecutive_counts[serial] = unauthorized_consecutive_counts.get(serial, 0) + 1
            # Reset counters for successful/unseen devices
            for serial in list(unauthorized_consecutive_counts.keys()):
                if serial not in unauthorized_serials:
                    unauthorized_consecutive_counts[serial] = 0

            if not is_ok:
                log("WARNING", f"ADB issue detected: {reason}")
                
                if "unauthorized" in reason:
                    # If the issue is unauthorized devices, enforce a 3-minute grace period (6 checks * 30s)
                    target_resets = []
                    for serial in unauthorized_serials:
                        streak = unauthorized_consecutive_counts.get(serial, 0)
                        if streak >= 6:  # 3 minutes
                            target_resets.append(serial)
                        else:
                            log("INFO", f"Device {serial} is unauthorized. Streak: {streak}/6 (Waiting grace period...)")
                    
                    if reason.startswith("Global issue"):
                        # Global recovery: only perform if global issue persists
                        global_unauthorized_streak += 1
                        if global_unauthorized_streak >= 6:
                            log("WARNING", "Global unauthorized issue persists for 3 minutes. Restarting ADB server...")
                            perform_recovery()
                            write_recovery_log("GLOBAL_RECOVERY", f"Restarted ADB server due to: {reason}")
                            global_unauthorized_streak = 0
                            time.sleep(10)
                        else:
                            log("INFO", f"Global unauthorized issue streak: {global_unauthorized_streak}/6. Waiting...")
                    
                    elif target_resets:
                        log("INFO", f"Handling pinpoint recovery for persistent serials: {target_resets}")
                        for serial in target_resets:
                            usb_path = get_usb_path_by_serial(serial)
                            if usb_path:
                                log("INFO", f"Pinpoint reset for {serial} on USB path {usb_path}")
                                success = reset_usb_device(usb_path)
                                if success:
                                    write_recovery_log("PINPOINT_RECOVERY", f"Successfully reset {serial} at USB {usb_path}")
                                else:
                                    write_recovery_log("PINPOINT_FAILED", f"Failed reset {serial} at USB {usb_path}")
                            else:
                                log("WARNING", f"Could not find USB path for serial {serial}")
                                write_recovery_log("PINPOINT_NOT_FOUND", f"USB path not found for {serial}")
                            # Reset counter after recovery attempt
                            unauthorized_consecutive_counts[serial] = 0
                        time.sleep(10)
                else:
                    # For non-unauthorized issues (e.g. adb hung, root process), perform recovery immediately
                    log("WARNING", "Handling immediate recovery for system/hung adb issues...")
                    perform_recovery()
                    write_recovery_log("GLOBAL_RECOVERY", f"Restarted ADB server due to: {reason}")
                    time.sleep(10)
            else:
                global_unauthorized_streak = 0
                log("INFO", f"ADB status check: OK ({dev_count} devices connected)")
        except Exception as e:
            log("ERROR", f"Exception in main loop: {e}")
            
        time.sleep(CHECK_INTERVAL_SEC)

if __name__ == "__main__":
    main()
