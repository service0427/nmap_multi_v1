#!/usr/bin/env python3
"""
LTE Multi-Proxy Self-Healing Recovery Module
- Automatically detects disconnected & reconnected USB LTE modems.
- Identifies gateway IP via DHCP (192.168.X.1) and renames interface to lteX.
- Configures isolated routing tables (table X), ip rules, and iptables NAT masquerade.
- Detects frozen modems and triggers hardware USB unbind/bind power-cycle reset.
"""

import os
import sys
import time
import re
import subprocess
from datetime import datetime

LOG_FILE = "/home/tech/nmap_multi_v1/adb_recovery.log"

def log(level, message):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    entry = f"[{timestamp}] [{level}] {message}"
    print(entry, flush=True)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(entry + "\n")
        os.chmod(LOG_FILE, 0o666)
    except Exception:
        pass

def run_cmd(cmd, timeout_sec=10, shell=False):
    """Runs a system command wrapped in subprocess with timeout."""
    try:
        res = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout_sec,
            shell=shell
        )
        return res.returncode == 0, res.stdout.strip(), res.stderr.strip()
    except subprocess.TimeoutExpired:
        return False, "", f"Command timed out ({timeout_sec}s)"
    except Exception as e:
        return False, "", str(e)

def get_primary_interface():
    """Identifies primary host ethernet to ensure it is NEVER touched."""
    try:
        ok, stdout, _ = run_cmd(["ip", "route", "show", "default"])
        if ok and stdout:
            for line in stdout.splitlines():
                parts = line.split()
                if "dev" in parts:
                    dev = parts[parts.index("dev") + 1]
                    if not dev.startswith(("lte", "usb", "tailscale", "lo", "docker", "br-", "veth")):
                        return dev
    except Exception:
        pass
    return None

def get_modem_usb_path(iface):
    """Finds physical USB port name (e.g. 3-4.1) for a given network interface."""
    sys_path = f"/sys/class/net/{iface}/device"
    if os.path.exists(sys_path):
        try:
            real = os.path.realpath(sys_path)
            usb_dev_path = os.path.dirname(real)
            usb_name = os.path.basename(usb_dev_path)
            if os.path.exists(f"/sys/bus/usb/devices/{usb_name}"):
                return usb_name
        except Exception:
            pass
    return None

def reset_usb_port(usb_path):
    """Performs pinpoint hardware unbind/bind power-cycle reset on a USB port."""
    if not usb_path:
        return False
    unbind_file = "/sys/bus/usb/drivers/usb/unbind"
    bind_file = "/sys/bus/usb/drivers/usb/bind"
    log("WARNING", f"[LTE-USB] Performing hardware power-cycle reset on USB port {usb_path}...")
    try:
        p_un = subprocess.run(["sudo", "tee", unbind_file], input=usb_path.encode(), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        if p_un.returncode != 0:
            log("ERROR", f"[LTE-USB] Unbind failed on {usb_path}: {p_un.stderr.decode().strip()}")
            return False
        
        time.sleep(2)

        p_bi = subprocess.run(["sudo", "tee", bind_file], input=usb_path.encode(), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        if p_bi.returncode == 0:
            log("SUCCESS", f"[LTE-USB] Hardware power-cycle successfully completed on USB port {usb_path}")
            return True
        else:
            log("ERROR", f"[LTE-USB] Bind failed on {usb_path}: {p_bi.stderr.decode().strip()}")
            return False
    except Exception as e:
        log("ERROR", f"[LTE-USB] Reset exception on {usb_path}: {e}")
        return False

def get_gateway_for_iface(iface):
    """Retrieves gateway IP from existing route or runs dhclient if missing."""
    ok, stdout, _ = run_cmd(["ip", "-4", "route", "show", "dev", iface])
    if ok and stdout:
        m = re.search(r'default via (\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})', stdout)
        if m:
            return m.group(1)
        for line in stdout.splitlines():
            if '/' in line:
                net_part = line.split()[0].split('/')[0]
                return net_part.rsplit('.', 1)[0] + '.1'

    run_cmd(["sudo", "timeout", "10", "dhclient", "-v", iface])
    ok, stdout, _ = run_cmd(["ip", "-4", "route", "show", "dev", iface])
    if ok and stdout:
        m = re.search(r'default via (\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})', stdout)
        if m:
            return m.group(1)
        for line in stdout.splitlines():
            if '/' in line:
                net_part = line.split()[0].split('/')[0]
                return net_part.rsplit('.', 1)[0] + '.1'

    return None

def configure_lte_interface(iface, subnet, gw):
    """
    Renames interface to lte{subnet}, assigns clean IP via DHCP,
    and ensures routing tables, ip rules, and NAT are properly configured.
    """
    target_name = f"lte{subnet}"
    table_id = str(subnet)
    log("INFO", f"[LTE] Configuring modem on interface '{iface}' -> '{target_name}' (Gateway: {gw})...")

    if iface != target_name:
        if os.path.exists(f"/sys/class/net/{target_name}"):
            tmp_name = f"tmp_{target_name}_{int(time.time())}"
            log("WARNING", f"[LTE] Collision! Renaming stale '{target_name}' -> '{tmp_name}'")
            run_cmd(["sudo", "ip", "link", "set", target_name, "down"])
            run_cmd(["sudo", "ip", "link", "set", target_name, "name", tmp_name])
            run_cmd(["sudo", "ip", "link", "set", tmp_name, "up"])
            time.sleep(1)

        run_cmd(["sudo", "ip", "link", "set", iface, "down"])
        ok_rename, _, err_ren = run_cmd(["sudo", "ip", "link", "set", iface, "name", target_name])
        if not ok_rename:
            log("ERROR", f"[LTE] Failed renaming {iface} to {target_name}: {err_ren}")
            return False
        run_cmd(["sudo", "ip", "link", "set", target_name, "up"])
        time.sleep(1)

    try:
        ok, pgrep_out, _ = run_cmd(f"pgrep -f 'dhclient.*{target_name}'", shell=True)
        if ok and pgrep_out:
            for pid in pgrep_out.split():
                run_cmd(["sudo", "kill", "-9", pid])
    except Exception:
        pass

    run_cmd(["sudo", "ip", "addr", "flush", "dev", target_name])
    run_cmd(["sudo", "timeout", "10", "dhclient", "-v", target_name])

    os.makedirs("/etc/iproute2", exist_ok=True)
    run_cmd(
        f'grep -q "^{table_id} lte{table_id}" /etc/iproute2/rt_tables || echo "{table_id} lte{table_id}" | sudo tee -a /etc/iproute2/rt_tables',
        shell=True
    )
    run_cmd(["sudo", "ip", "route", "flush", "table", table_id])
    run_cmd(["sudo", "ip", "route", "replace", "default", "via", gw, "dev", target_name, "table", table_id])

    run_cmd(["sudo", "ip", "route", "del", "default", "dev", target_name])
    metric_val = 100 + int(table_id)
    run_cmd(["sudo", "ip", "route", "add", "default", "via", gw, "dev", target_name, "metric", str(metric_val)])

    ok, ip_res, _ = run_cmd(["ip", "-4", "addr", "show", target_name])
    if ok and ip_res:
        m = re.search(r'inet (192\.168\.\d+\.\d+)', ip_res)
        if m:
            local_ip = m.group(1)
            run_cmd(["sudo", "ip", "rule", "del", "from", local_ip, "table", table_id])
            run_cmd(["sudo", "ip", "rule", "add", "from", local_ip, "table", table_id])
            run_cmd(["sudo", "ip", "rule", "del", "from", f"192.168.{subnet}.0/24", "table", table_id])
            run_cmd(["sudo", "ip", "rule", "add", "from", f"192.168.{subnet}.0/24", "table", table_id])

    run_cmd(
        f"sudo iptables -t nat -C POSTROUTING -o {target_name} -j MASQUERADE 2>/dev/null || sudo iptables -t nat -A POSTROUTING -o {target_name} -j MASQUERADE",
        shell=True
    )

    log("SUCCESS", f"[LTE] Successfully configured and synchronized '{target_name}' (GW: {gw})")
    return True

_LTE_FAIL_STREAKS = {}

def check_and_heal_lte_modems(force_all=False):
    """
    Main entry point for LTE self-healing watchdog.
    - Runs in < 40ms when all modems are healthy.
    - If unmapped interface or broken routing is detected, executes auto-recovery.
    """
    primary_iface = get_primary_interface()

    try:
        interfaces = os.listdir('/sys/class/net')
    except Exception as e:
        log("ERROR", f"[LTE] Failed reading /sys/class/net: {e}")
        return

    unmapped_ifaces = []
    broken_lte_ifaces = []
    active_lte_subnets = set()

    for iface in interfaces:
        if iface in [primary_iface, "lo", "tailscale0"] or iface.startswith(("docker", "br-", "veth")):
            continue

        mac = ""
        try:
            with open(f"/sys/class/net/{iface}/address", "r") as f:
                mac = f.read().strip().lower()
        except Exception:
            pass

        is_lte_mac = (mac == "00:1e:10:1f:00:00" or mac.startswith("00:1e:10"))
        is_candidate_name = re.match(r"^(enx|usb\d+|eth\d+|z_\w+)", iface) is not None

        if is_lte_mac or is_candidate_name:
            if not iface.startswith("lte"):
                unmapped_ifaces.append(iface)
            else:
                try:
                    subnet = int(iface.replace("lte", ""))
                    active_lte_subnets.add(subnet)
                except Exception:
                    continue

                if force_all:
                    broken_lte_ifaces.append(iface)
                    continue

                ok_addr, addr_res, _ = run_cmd(["ip", "-4", "addr", "show", iface])
                has_ip = re.search(r'inet 192\.168\.\d+\.\d+', addr_res) is not None if ok_addr else False

                ok_route, route_res, _ = run_cmd(["ip", "route", "show", "table", str(subnet)])
                has_route = ("default via" in route_res) if ok_route else False

                operstate = ""
                try:
                    with open(f"/sys/class/net/{iface}/operstate", "r") as f:
                        operstate = f.read().strip().lower()
                except Exception:
                    pass

                if not has_ip or not has_route or operstate == "down":
                    broken_lte_ifaces.append(iface)

    if not unmapped_ifaces and not broken_lte_ifaces and not force_all:
        return

    log("WARNING", f"[LTE] Anomaly detected: unmapped={unmapped_ifaces}, broken={broken_lte_ifaces}")

    for iface in unmapped_ifaces:
        log("INFO", f"[LTE] Healing unmapped modem '{iface}'...")
        run_cmd(["sudo", "ip", "link", "set", iface, "up"])
        time.sleep(1)
        gw = get_gateway_for_iface(iface)
        if not gw:
            streak = _LTE_FAIL_STREAKS.get(iface, 0) + 1
            _LTE_FAIL_STREAKS[iface] = streak
            log("WARNING", f"[LTE] Gateway not ready for '{iface}' (streak: {streak}/3).")
            if streak >= 3:
                usb_p = get_modem_usb_path(iface)
                if usb_p:
                    log("WARNING", f"[LTE] Modem '{iface}' unresponsive for 3 cycles. Triggering USB hardware reset on {usb_p}...")
                    reset_usb_port(usb_p)
                _LTE_FAIL_STREAKS[iface] = 0
            continue

        _LTE_FAIL_STREAKS[iface] = 0
        try:
            subnet = int(gw.split(".")[2])
            if 10 <= subnet <= 30:
                configure_lte_interface(iface, subnet, gw)
        except Exception as e:
            log("ERROR", f"[LTE] Failed parsing subnet from gateway {gw}: {e}")

    for iface in broken_lte_ifaces:
        log("INFO", f"[LTE] Restoring unhealthy interface '{iface}'...")
        run_cmd(["sudo", "ip", "link", "set", iface, "up"])
        gw = get_gateway_for_iface(iface)
        if not gw:
            try:
                subnet = int(iface.replace("lte", ""))
                gw = f"192.168.{subnet}.1"
            except Exception:
                pass

        if gw:
            try:
                subnet = int(iface.replace("lte", ""))
                success = configure_lte_interface(iface, subnet, gw)
                if success:
                    _LTE_FAIL_STREAKS[iface] = 0
                else:
                    streak = _LTE_FAIL_STREAKS.get(iface, 0) + 1
                    _LTE_FAIL_STREAKS[iface] = streak
            except Exception as e:
                log("ERROR", f"[LTE] Failed re-configuring {iface}: {e}")
        else:
            streak = _LTE_FAIL_STREAKS.get(iface, 0) + 1
            _LTE_FAIL_STREAKS[iface] = streak
            log("WARNING", f"[LTE] Could not determine gateway for '{iface}' (streak: {streak}/3)")
            if streak >= 3:
                usb_p = get_modem_usb_path(iface)
                if usb_p:
                    log("WARNING", f"[LTE] Persistent failure on '{iface}'. Triggering USB hardware reset on {usb_p}...")
                    reset_usb_port(usb_p)
                _LTE_FAIL_STREAKS[iface] = 0

if __name__ == '__main__':
    force = ('--force' in sys.argv or '-f' in sys.argv)
    log('INFO', f'Executing LTE Recovery Tool (force={force})...')
    check_and_heal_lte_modems(force_all=force)
    log('INFO', 'LTE Recovery Tool execution finished.')
