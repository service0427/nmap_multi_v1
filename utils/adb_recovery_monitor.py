#!/usr/bin/env python3
import subprocess
import time
import os
import sys
import json
from datetime import datetime

# Import LTE Multi-Modem Self-Healing Watchdog
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    from lte_recovery import check_and_heal_lte_modems
except ImportError:
    try:
        from utils.lte_recovery import check_and_heal_lte_modems
    except ImportError:
        check_and_heal_lte_modems = None

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
    """Returns a list of tuples (pid, user, cmd) for all host adb processes."""
    processes = []
    try:
        # Run ps to get pid, user, and command arguments
        res = subprocess.run(["ps", "-Ao", "pid,user,args"], capture_output=True, text=True, check=True)
        for line in res.stdout.strip().split("\n")[1:]:  # Skip header
            parts = line.strip().split(None, 2)
            if len(parts) >= 3:
                pid, user, cmd = parts[0], parts[1], parts[2]
                # Match actual host adb executable invocations (avoid matching /data/adb, adbkey, adbd, adbkeyboard)
                tokens = cmd.split()
                is_adb_bin = False
                for tok in tokens[:3]:
                    base = os.path.basename(tok)
                    if base == "adb":
                        is_adb_bin = True
                        break
                if is_adb_bin and "adbd" not in cmd and "adbkeyboard" not in cmd and "grep" not in cmd and "adb_recovery_monitor" not in cmd:
                    try:
                        processes.append((int(pid), user, cmd))
                    except ValueError:
                        continue
    except Exception as e:
        log("ERROR", f"Failed to list processes: {e}")
    return processes

def ensure_host_adb_wrapper_and_keys():
    """Ensures /root/.android has tech's adbkey and /usr/bin/adb wraps platform-tools/adb to always run as tech."""
    script = r'''
    if [ -f "/home/tech/.android/adbkey" ] && [ -f "/home/tech/.android/adbkey.pub" ]; then
        mkdir -p /root/.android
        cp /home/tech/.android/adbkey /home/tech/.android/adbkey.pub /root/.android/
        chmod 600 /root/.android/adbkey
        chmod 644 /root/.android/adbkey.pub
    fi
    if [ -x "/usr/lib/android-sdk/platform-tools/adb" ] && [ -L "/usr/bin/adb" ]; then
        rm -f /usr/bin/adb
        cat << 'WRAP_EOF' > /usr/bin/adb
#!/bin/sh
if [ "$(id -u)" -eq 0 ] && id -u tech >/dev/null 2>&1; then
    exec runuser -u tech -- env HOME=/home/tech /usr/lib/android-sdk/platform-tools/adb "$@"
fi
export HOME="/home/tech"
exec /usr/lib/android-sdk/platform-tools/adb "$@"
WRAP_EOF
        chmod 755 /usr/bin/adb
    fi
    '''
    try:
        subprocess.run(["sudo", "-n", "sh", "-c", script], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    except Exception:
        pass

def pin_adb_keys_on_device(serial):
    """Pins host adbkey.pub (with tech@hostname, root@hostname, and original pub comment) into /data/misc/adb/adb_keys on an authorized device."""
    pub_file = os.path.join(TECH_ANDROID_DIR, "adbkey.pub")
    if not os.path.exists(pub_file):
        return False
    try:
        with open(pub_file, "r") as f:
            pub_content = f.read().strip()
        if not pub_content:
            return False
        key_body = pub_content.split()[0]
        cur_host = os.uname().nodename.strip() or "localhost"
        key_tech = f"{key_body} tech@{cur_host}"
        key_root = f"{key_body} root@{cur_host}"
        remote_cmd = (
            "settings put global adb_allowed_connection_time 0 >/dev/null 2>&1; "
            "su -c '"
            "setprop persist.sys.usb.config adb 2>/dev/null; "
            "mkdir -p /data/misc/adb && touch /data/misc/adb/adb_keys; "
            f"for k in \"{key_tech}\" \"{key_root}\" \"{pub_content}\"; do "
            "if [ -n \"$k\" ] && ! grep -qxF \"$k\" /data/misc/adb/adb_keys 2>/dev/null; then "
            "echo \"$k\" >> /data/misc/adb/adb_keys; "
            "fi; done; "
            "chown system:shell /data/misc/adb /data/misc/adb/adb_keys; "
            "chmod 2750 /data/misc/adb; chmod 640 /data/misc/adb/adb_keys; "
            "restorecon -R /data/misc/adb 2>/dev/null || chcon u:object_r:adb_keys_file:s0 /data/misc/adb/adb_keys 2>/dev/null || true"
            "'"
        )
        ok, _, _ = run_adb_cmd(["-s", serial, "shell", remote_cmd], timeout_sec=4)
        return ok
    except Exception:
        return False

def kill_processes(pids, use_sudo=False):
    """Kills a list of PIDs."""
    if not pids:
        return
    log("INFO", f"Killing processes (use_sudo={use_sudo}): {pids}")
    cmd = ["sudo", "kill", "-9"] if use_sudo else ["kill", "-9"]
    cmd.extend(str(pid) for pid in pids)
    try:
        subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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

USB_PORTS_CONFIG_PATH = "/home/tech/nmap_multi_v1/wifi_multi/config/usb_ports.json"
DEVICE_ORDER_CONFIG_PATH = "/home/tech/nmap_multi_v1/wifi_multi/config/device_order.json"

def scan_sysfs_usb_ports():
    """Scans /sys/bus/usb/devices/*/serial with a 2-second timeout to get live {serial: usb_port} mapping."""
    mapping = {}
    try:
        cmd = "timeout 2 sh -c 'for f in /sys/bus/usb/devices/*/serial; do [ -f \"$f\" ] && s=$(cat \"$f\" 2>/dev/null) && [ -n \"$s\" ] && echo \"$s $(basename $(dirname \"$f\"))\"; done'"
        res = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=3)
        if res.returncode == 0 and res.stdout.strip():
            for line in res.stdout.strip().split("\n"):
                parts = line.strip().split()
                if len(parts) == 2:
                    serial, port = parts[0], parts[1]
                    if ":" not in serial and len(serial) >= 6:
                        mapping[serial] = port
    except Exception as e:
        log("ERROR", f"Sysfs USB scan failed: {e}")
    return mapping

def remove_stale_device_from_configs(serial, reason=""):
    """Removes a physically unplugged/stale serial from usb_ports.json and device_order.json."""
    try:
        if os.path.exists(USB_PORTS_CONFIG_PATH):
            with open(USB_PORTS_CONFIG_PATH, "r") as f:
                usb_ports = json.load(f)
            if serial in usb_ports:
                removed_port = usb_ports.pop(serial, None)
                with open(USB_PORTS_CONFIG_PATH, "w") as f:
                    json.dump(usb_ports, f, indent=2)
                log("INFO", f"[AUTO_PRUNE] Removed stale device {serial} ({removed_port}) from usb_ports.json ({reason})")
                write_recovery_log("AUTO_PRUNE", f"Removed stale {serial} ({removed_port}) from usb_ports.json: {reason}")
    except Exception as e:
        log("ERROR", f"Failed to prune {serial} from usb_ports.json: {e}")

    try:
        if os.path.exists(DEVICE_ORDER_CONFIG_PATH):
            with open(DEVICE_ORDER_CONFIG_PATH, "r") as f:
                order_list = json.load(f)
            if serial in order_list:
                order_list.remove(serial)
                with open(DEVICE_ORDER_CONFIG_PATH, "w") as f:
                    json.dump(order_list, f, indent=2)
    except Exception as e:
        log("ERROR", f"Failed to prune {serial} from device_order.json: {e}")

def get_usb_path_by_serial(serial, sysfs_map=None):
    # 1. Always check live sysfs first so moved devices never reset the wrong port
    if sysfs_map is None:
        sysfs_map = scan_sysfs_usb_ports()
    if serial in sysfs_map:
        return sysfs_map[serial]

    # 2. Fallback to usb_ports.json only if device dropped off sysfs
    if os.path.exists(USB_PORTS_CONFIG_PATH):
        try:
            with open(USB_PORTS_CONFIG_PATH, "r") as f:
                usb_ports = json.load(f)
            if serial in usb_ports:
                usb_path = usb_ports[serial].replace("usb:", "")
                # Safety Check A: Ensure this port is not occupied by a different live device
                occupant = next((s for s, p in sysfs_map.items() if p == usb_path and s != serial), None)
                if occupant:
                    remove_stale_device_from_configs(serial, f"port {usb_path} is now occupied by {occupant}")
                    return None
                # Safety Check B: Ensure parent USB hub actually exists on this machine
                parent_hub = usb_path.rsplit(".", 1)[0] if "." in usb_path else f"usb{usb_path.split('-')[0]}"
                if not os.path.exists(f"/sys/bus/usb/devices/{parent_hub}"):
                    remove_stale_device_from_configs(serial, f"parent USB hub {parent_hub} does not exist on this host")
                    return None
                return usb_path
        except Exception as e:
            log("ERROR", f"Failed to read usb_ports.json: {e}")
    return None

def reset_usb_device(usb_path):
    unbind_file = "/sys/bus/usb/drivers/usb/unbind"
    bind_file = "/sys/bus/usb/drivers/usb/bind"
    if not os.path.exists(f"/sys/bus/usb/devices/{usb_path}"):
        log("WARNING", f"Sysfs path /sys/bus/usb/devices/{usb_path} does not exist (device physically unplugged).")
        return False

    log("INFO", f"Targeting USB port {usb_path} for hardware unbind/bind reset...")
    try:
        # 1. Unbind port (Proceed to bind even if already unbound)
        res_unbind = subprocess.run(
            ["sudo", "tee", unbind_file],
            input=usb_path.encode(),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE
        )
        if res_unbind.returncode == 0:
            log("INFO", f"Successfully sent unbind to {usb_path}")
        else:
            log("INFO", f"Unbind note for {usb_path} (may already be unbound): {res_unbind.stderr.decode().strip()}")

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

def check_adb_status(missing_reset_done, pinned_serials=None):
    """
    Checks the adb server status and synchronizes usb_ports.json with live hardware.
    Returns (is_ok, reason, bad_serials, offline_serials, missing_serials, unauthorized_serials, device_count, root_pids, sysfs_map)
    """
    # 1. Check for root processes (Collect but don't fail immediately, we will kill them target-selectively)
    procs = get_adb_processes()
    root_pids = [p[0] for p in procs if p[1] == "root"]

    # 2. Check for adb hanging using 'devices -l' to also capture live usb: paths
    try:
        success, stdout, stderr = run_adb_cmd(["devices", "-l"], timeout_sec=ADB_TIMEOUT_SEC)
        if not success:
            return False, f"adb devices failed: {stderr}", [], [], [], [], 0, root_pids, {}
        
        sysfs_map = scan_sysfs_usb_ports()

        # Parse device count, statuses, and usb paths
        lines = stdout.strip().split("\n")
        device_count = 0
        connected_serials = []
        authorized_serials = []
        unauthorized_serials = []
        offline_serials = []
        live_usb_updates = {}

        for line in lines[1:]:
            line = line.strip()
            if not line or line.startswith("*"):
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            serial = parts[0]
            if ":" in serial:
                continue
            state = parts[1]
            device_count += 1
            connected_serials.append(serial)
            if serial in sysfs_map:
                live_usb_updates[serial] = f"usb:{sysfs_map[serial]}"
            for p in parts[2:]:
                if p.startswith("usb:"):
                    live_usb_updates[serial] = p
            if state == "device":
                authorized_serials.append(serial)
            elif state == "unauthorized":
                unauthorized_serials.append(serial)
                if pinned_serials is not None:
                    pinned_serials.discard(serial)
            elif state == "offline":
                offline_serials.append(serial)
                if pinned_serials is not None:
                    pinned_serials.discard(serial)

        # 2.5 Auto-pin adb_keys on newly authorized devices (up to 5 per cycle to avoid blocking monitor loop)
        if pinned_serials is not None:
            unpinned = [s for s in authorized_serials if s not in pinned_serials]
            for s in unpinned[:5]:
                if pin_adb_keys_on_device(s):
                    pinned_serials.add(s)

        # 3. Synchronize usb_ports.json with live port mappings and prune unplugged ghost devices
        missing_serials = []
        usb_ports = {}
        if os.path.exists(USB_PORTS_CONFIG_PATH):
            try:
                with open(USB_PORTS_CONFIG_PATH, "r") as f:
                    usb_ports = json.load(f)
            except Exception as e:
                log("ERROR", f"Failed to read usb_ports.json: {e}")

        # Also update any known device in usb_ports if it moved ports in sysfs
        for serial in list(usb_ports.keys()):
            if serial in sysfs_map:
                live_usb_updates[serial] = f"usb:{sysfs_map[serial]}"

        ports_modified = False
        for serial, usb_tag in live_usb_updates.items():
            if usb_ports.get(serial) != usb_tag:
                log("INFO", f"[USB_SYNC] Updating USB port for {serial}: {usb_ports.get(serial)} -> {usb_tag}")
                usb_ports[serial] = usb_tag
                ports_modified = True

        if ports_modified:
            try:
                os.makedirs(os.path.dirname(USB_PORTS_CONFIG_PATH), exist_ok=True)
                with open(USB_PORTS_CONFIG_PATH, "w") as f:
                    json.dump(usb_ports, f, indent=2)
            except Exception as e:
                log("ERROR", f"Failed to save updated usb_ports.json: {e}")

        for serial in list(usb_ports.keys()):
            if serial in connected_serials:
                missing_reset_done.discard(serial)
                continue

            usb_path = usb_ports[serial].replace("usb:", "")
            parent_hub = usb_path.rsplit(".", 1)[0] if "." in usb_path else f"usb{usb_path.split('-')[0]}"
            occupant = next((s for s, p in sysfs_map.items() if p == usb_path and s != serial), None)

            if occupant:
                remove_stale_device_from_configs(serial, f"port {usb_path} now occupied by {occupant}")
                missing_reset_done.discard(serial)
            elif not os.path.exists(f"/sys/bus/usb/devices/{parent_hub}"):
                remove_stale_device_from_configs(serial, f"parent hub {parent_hub} not present on host")
                missing_reset_done.discard(serial)
            elif serial in missing_reset_done and serial not in sysfs_map:
                remove_stale_device_from_configs(serial, f"device did not return after USB reset on {usb_path} (unplugged)")
                missing_reset_done.discard(serial)
            else:
                missing_serials.append(serial)

        # IMPORTANT: Do NOT include unauthorized_serials in bad_serials!
        # Resetting USB on an unauthorized device cannot authorize it and causes 12s xhci_hcd bus hangs (error -71) + popup spam.
        bad_serials = list(set(offline_serials + missing_serials))
        if bad_serials:
            reasons = []
            if offline_serials: reasons.append(f"offline: {offline_serials}")
            if missing_serials: reasons.append(f"missing: {missing_serials}")
            if unauthorized_serials: reasons.append(f"unauthorized (skipped reset): {unauthorized_serials}")
            reason_str = "Problematic/Missing devices detected: " + ", ".join(reasons)
            return False, reason_str, bad_serials, offline_serials, missing_serials, unauthorized_serials, device_count, root_pids, sysfs_map
            
        return True, "OK", [], [], [], unauthorized_serials, device_count, root_pids, sysfs_map

    except subprocess.TimeoutExpired:
        return False, "adb devices command timed out", [], [], [], [], 0, root_pids, {}
    except Exception as e:
        return False, f"adb check encountered error: {e}", [], [], [], [], 0, root_pids, {}

def main():
    log("INFO", "ADB Recovery Monitor Daemon started (Pinpoint Targeted Healing & Auto USB Sync active).")
    ensure_host_adb_wrapper_and_keys()
    
    bad_consecutive_counts = {}
    missing_reset_done = set()
    pinned_serials = set()
    logged_unauthorized = set()
    global_hang_streak = 0
    
    while True:
        try:
            is_ok, reason, bad_serials, offline_serials, missing_serials, unauthorized_serials, dev_count, root_pids, sysfs_map = check_adb_status(missing_reset_done, pinned_serials)
            
            # 1. Root adb 프로세스가 발견되면 전체 리셋 대신 해당 Root PID만 조용히 저격 사살
            if root_pids:
                log("WARNING", f"Root-owned adb process detected (PIDs: {root_pids}). Targeted kill...")
                kill_processes(root_pids, use_sudo=True)
                write_recovery_log("TARGETED_ROOT_KILL", f"Killed root adb PIDs: {root_pids}")
                time.sleep(2)
                continue

            # Log unauthorized devices once without triggering USB reset or reconnect loops
            current_unauth = set(unauthorized_serials)
            new_unauth = current_unauth - logged_unauthorized
            if new_unauth:
                log("WARNING", f"[UNAUTHORIZED] Device(s) {sorted(list(new_unauth))} are unauthorized. Skipping USB reset/reconnect loop to prevent USB bus freeze.")
                write_recovery_log("UNAUTHORIZED_SKIP", f"Skipped auto-reset for unauthorized devices: {sorted(list(new_unauth))}")
            logged_unauthorized = current_unauth
            
            # Update bad serials counters
            for serial in bad_serials:
                bad_consecutive_counts[serial] = bad_consecutive_counts.get(serial, 0) + 1
            # Reset counters for successful/unseen devices
            for serial in list(bad_consecutive_counts.keys()):
                if serial not in bad_serials:
                    bad_consecutive_counts[serial] = 0

            if not is_ok:
                log("WARNING", f"ADB issues/deviations detected: {reason}")
                
                # Case A: 개별 단말기 꼬임 (Offline / Missing) ➡️ 기기별 저격 치유 (Unauthorized는 제외됨!)
                if bad_serials and "Problematic" in reason:
                    global_hang_streak = 0 # ADB 서버 자체는 통신이 되므로 행상태 아님
                    target_resets = []
                    for serial in bad_serials:
                        streak = bad_consecutive_counts.get(serial, 0)
                        
                        # 1단계 (streak == 1): offline 기기에 한해 가벼운 소프트웨어 reconnect 1회만 시도 (unbind와 동시 실행 절대 금지)
                        if streak == 1:
                            if serial in offline_serials:
                                log("INFO", f"Attempting quick software reconnect for offline {serial} (Streak: 1/2)")
                                run_adb_cmd(["-s", serial, "reconnect"], timeout_sec=5)
                            else:
                                log("INFO", f"Device {serial} is missing from ADB (Streak: 1/2). Waiting grace cycle before hardware check...")
                        
                        # 2단계 (streak >= 2): reconnect 호출 없이 하드웨어 USB unbind/bind 단독 수행 (충돌 방지)
                        elif streak >= 2:
                            target_resets.append(serial)
                    
                    if target_resets:
                        log("INFO", f"Handling pinpoint hardware recovery for persistent offline/missing serials: {target_resets}")
                        for serial in target_resets:
                            usb_path = get_usb_path_by_serial(serial, sysfs_map=sysfs_map)
                            if usb_path:
                                log("INFO", f"Pinpoint USB reset for {serial} on USB path {usb_path}")
                                success = reset_usb_device(usb_path)
                                if success:
                                    write_recovery_log("PINPOINT_RECOVERY", f"Successfully reset problematic {serial} at USB {usb_path}")
                                else:
                                    write_recovery_log("PINPOINT_FAILED", f"Failed reset problematic {serial} at USB {usb_path}")
                            else:
                                log("WARNING", f"Could not find valid USB path for serial {serial}")
                                write_recovery_log("PINPOINT_NOT_FOUND", f"USB path not found or pruned for {serial}")
                            if serial in missing_serials:
                                missing_reset_done.add(serial)
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
                if unauthorized_serials:
                    log("INFO", f"ADB status check: OK ({dev_count} attached, {len(unauthorized_serials)} unauthorized awaiting approval: {unauthorized_serials})")
                else:
                    log("INFO", f"ADB status check: OK ({dev_count} devices connected)")

            # 4. LTE Multi-Modem Self-Healing Watchdog (Detects unmapped/reconnected modems, broken routes)
            if check_and_heal_lte_modems:
                try:
                    check_and_heal_lte_modems()
                except Exception as lte_err:
                    log("ERROR", f"LTE healing watchdog exception: {lte_err}")
        except Exception as e:
            log("ERROR", f"Exception in main loop: {e}")
            
        time.sleep(CHECK_INTERVAL_SEC)

if __name__ == "__main__":
    main()
