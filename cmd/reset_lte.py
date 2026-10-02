#!/usr/bin/env python3
"""
LTE Modem Real-Time USB Reset & Recovery Tool
- Dynamically detects USB ports for lte11~lte20 across different server hardware topologies.
- Supports Hardware USB Power-Cycle (unbind/bind) and Hilink API Reboot.
- Automatically synchronizes interface naming and policy routing tables via fix_eth_number.sh.
"""

import os
import sys
import re
import time
import json
import argparse
import subprocess
import urllib.request
from datetime import datetime

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX_SCRIPT = os.path.join(PROJECT_ROOT, "fix_eth_number.sh")

# ANSI Color codes
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_RED = "\033[1;31m"
CLR_GREEN = "\033[1;32m"
CLR_YELLOW = "\033[1;33m"
CLR_BLUE = "\033[1;34m"
CLR_CYAN = "\033[1;36m"
CLR_MAGENTA = "\033[1;35m"

def log(msg, level="INFO"):
    ts = datetime.now().strftime("%H:%M:%S")
    color = CLR_CYAN if level == "INFO" else (CLR_GREEN if level == "OK" else (CLR_YELLOW if level == "WARN" else CLR_RED))
    print(f"[{ts}] {color}[{level}]{CLR_RESET} {msg}", flush=True)

def run_cmd(cmd, timeout=15, check=False):
    try:
        res = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        if check and res.returncode != 0:
            return None
        return res.stdout.strip()
    except Exception:
        return None

def run_sudo(cmd, timeout=15):
    if os.geteuid() == 0:
        return run_cmd(cmd, timeout=timeout)
    return run_cmd(f"sudo {cmd}", timeout=timeout)

def get_realtime_usb_port(iface):
    """
    Dynamically discovers the physical USB device node (e.g. 3-4.3, 1-1.2, 3-4.4.2)
    by traversing up sysfs from /sys/class/net/{iface}/device.
    Works dynamically on ANY motherboard / USB hub topology.
    """
    net_dev = f"/sys/class/net/{iface}/device"
    if not os.path.exists(net_dev):
        return None
    try:
        real_path = os.path.realpath(net_dev)
        cur = real_path
        while cur and cur != "/":
            base = os.path.basename(cur)
            if os.path.exists(f"/sys/bus/usb/devices/{base}/idVendor"):
                return base
            cur = os.path.dirname(cur)
    except Exception:
        pass
    return None

def get_modem_info(iface):
    """Gathers real-time hardware and network details for an interface."""
    usb_port = get_realtime_usb_port(iface)
    
    # Subnet extraction
    subnet = None
    m = re.search(r"lte(\d+)", iface)
    if m:
        subnet = int(m.group(1))
    else:
        ip_out = run_cmd(f"ip -4 addr show {iface}") or ""
        m_ip = re.search(r"inet 192\.168\.(\d+)\.", ip_out)
        if m_ip:
            subnet = int(m_ip.group(1))

    gw = f"192.168.{subnet}.1" if subnet else None
    
    # Local IP
    local_ip = "No IP"
    ip_out = run_cmd(f"ip -4 addr show {iface}") or ""
    m_local = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", ip_out)
    if m_local:
        local_ip = m_local.group(1)

    # USB Vendor / Product
    vendor = "N/A"
    product = "N/A"
    prod_name = "N/A"
    if usb_port:
        v_file = f"/sys/bus/usb/devices/{usb_port}/idVendor"
        p_file = f"/sys/bus/usb/devices/{usb_port}/idProduct"
        n_file = f"/sys/bus/usb/devices/{usb_port}/product"
        if os.path.exists(v_file):
            with open(v_file) as f: vendor = f.read().strip()
        if os.path.exists(p_file):
            with open(p_file) as f: product = f.read().strip()
        if os.path.exists(n_file):
            with open(n_file) as f: prod_name = f.read().strip()

    return {
        "iface": iface,
        "subnet": subnet,
        "gw": gw,
        "local_ip": local_ip,
        "usb_port": usb_port,
        "vendor": vendor,
        "product": product,
        "prod_name": prod_name
    }

def discover_all_lte_devices():
    """
    Scans /sys/class/net for LTE interfaces (lte11~lte30, or Huawei vendor devices).
    Returns a sorted list of modem info dicts.
    """
    devices = []
    net_dir = "/sys/class/net"
    if not os.path.exists(net_dir):
        return devices

    for iface in sorted(os.listdir(net_dir)):
        if iface in ["lo", "tailscale0"] or iface.startswith(("eth0", "docker", "br-", "veth")):
            continue

        is_lte = False
        if iface.startswith("lte"):
            is_lte = True
        else:
            # Check MAC or USB Vendor
            mac = ""
            addr_file = f"{net_dir}/{iface}/address"
            if os.path.exists(addr_file):
                try:
                    with open(addr_file) as f: mac = f.read().strip().lower()
                except Exception:
                    pass
            if mac.startswith("00:1e:10") or mac == "00:1e:10:1f:00:00":
                is_lte = True

        if is_lte:
            info = get_modem_info(iface)
            if info["subnet"] and 10 <= info["subnet"] <= 30:
                devices.append(info)

    # Sort by subnet
    devices.sort(key=lambda x: x["subnet"] if x["subnet"] else 999)
    return devices

def reset_usb_hardware(usb_port, wait_sec=3):
    """Performs real-time hardware power-cycle via USB driver unbind/bind."""
    if not usb_port:
        return False, "USB port not detected"

    unbind_file = "/sys/bus/usb/drivers/usb/unbind"
    bind_file = "/sys/bus/usb/drivers/usb/bind"

    if not os.path.exists(unbind_file) or not os.path.exists(bind_file):
        return False, "USB driver sysfs unbind/bind not available"

    # 1. Unbind
    try:
        p_un = subprocess.run(["sudo", "tee", unbind_file], input=usb_port.encode(),
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=10)
        if p_un.returncode != 0:
            return False, f"Unbind error: {p_un.stderr.decode().strip()}"
    except Exception as e:
        return False, f"Unbind exception: {e}"

    time.sleep(wait_sec)

    # 2. Bind
    try:
        p_bi = subprocess.run(["sudo", "tee", bind_file], input=usb_port.encode(),
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=10)
        if p_bi.returncode != 0:
            return False, f"Bind error: {p_bi.stderr.decode().strip()}"
    except Exception as e:
        return False, f"Bind exception: {e}"

    return True, "USB rebound successfully"

def reboot_hilink_api(subnet, gw=None, timeout=6):
    """Sends official Hilink reboot command to Huawei E8372 modem."""
    gw = gw or f"192.168.{subnet}.1"
    try:
        from huawei_lte_api.Client import Client
        from huawei_lte_api.Connection import Connection
        conn = Connection(f"http://{gw}/", username="admin", password="KdjLch!@7024", timeout=timeout)
        client = Client(conn)
        client.device.reboot()
        return True, "Hilink API reboot command accepted"
    except Exception as e1:
        # Fallback to direct HTTP POST
        try:
            req = urllib.request.Request(
                f"http://{gw}/api/device/control",
                data=b"<request><Control>1</Control></request>",
                headers={"Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"},
                method="POST"
            )
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                if resp.status == 200:
                    return True, "Direct HTTP POST reboot accepted"
        except Exception:
            pass
        return False, f"API error: {e1}"

def trigger_fix_eth_number():
    """Executes fix_eth_number.sh to restore interface names and routing tables."""
    if os.path.exists(FIX_SCRIPT):
        log(f"Running fix_eth_number.sh to synchronize names and routing...", "INFO")
        run_sudo(f"python3 {FIX_SCRIPT}", timeout=35)

def get_public_ip(iface):
    """Fetches public IP for a specific interface."""
    out = run_cmd(f"curl -s -m 4 --interface {iface} https://api.ipify.org || curl -s -m 4 --interface {iface} https://icanhazip.com")
    if out and re.match(r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$", out.strip()):
        return out.strip()
    return "Offline / Pending"

def print_table(devices):
    print(f"\n{CLR_BOLD}📡 Detected LTE Modems & Dynamic USB Port Mapping:{CLR_RESET}")
    print("+" + "-"*8 + "+" + "-"*8 + "+" + "-"*12 + "+" + "-"*18 + "+" + "-"*16 + "+" + "-"*18 + "+")
    print(f"| {'IFACE':<6} | {'SUBNET':<6} | {'USB PORT':<10} | {'LOCAL IP':<16} | {'VENDOR/DEVICE':<14} | {'GATEWAY':<16} |")
    print("+" + "-"*8 + "+" + "-"*8 + "+" + "-"*12 + "+" + "-"*18 + "+" + "-"*16 + "+" + "-"*18 + "+")
    for d in devices:
        vend_str = f"{d['vendor']}:{d['product']}"
        print(f"| {d['iface']:<6} | {str(d['subnet']):<6} | {d['usb_port'] or 'UNKNOWN':<10} | {d['local_ip']:<16} | {vend_str:<14} | {d['gw'] or 'N/A':<16} |")
    print("+" + "-"*8 + "+" + "-"*8 + "+" + "-"*12 + "+" + "-"*18 + "+" + "-"*16 + "+" + "-"*18 + "+\n")

def parse_targets(args_targets, all_devices):
    """Resolves target arguments (e.g. ['11', 'lte12', '11-14', 'all']) to device dicts."""
    if not args_targets or "all" in args_targets:
        return all_devices

    selected = []
    target_tokens = set()
    for t in args_targets:
        for item in t.replace(",", " ").split():
            # Support range e.g. 11-14
            if "-" in item and not item.startswith("-"):
                parts = item.split("-")
                if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
                    for r in range(int(parts[0]), int(parts[1]) + 1):
                        target_tokens.add(str(r))
                        target_tokens.add(f"lte{r}")
                    continue
            clean = item.lower()
            target_tokens.add(clean)
            if clean.isdigit():
                target_tokens.add(f"lte{clean}")
            elif clean.startswith("lte"):
                target_tokens.add(clean.replace("lte", ""))

    for d in all_devices:
        if d["iface"] in target_tokens or str(d["subnet"]) in target_tokens:
            selected.append(d)

    return selected

def main():
    parser = argparse.ArgumentParser(
        description="LTE Modem Real-Time USB Reset & Recovery Tool (Supports lte11~lte20 across any server)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python3 cmd/reset_lte.py --list                 # 실시간 USB 포트 매핑 현황 확인
  python3 cmd/reset_lte.py 11                     # lte11 기기 실시간 USB 포트 감지 후 언바인드/바인드 리셋
  python3 cmd/reset_lte.py lte12                  # lte12 기기 리셋
  python3 cmd/reset_lte.py 11 12 13               # lte11, lte12, lte13 동시 리셋
  python3 cmd/reset_lte.py 11-14                  # lte11 ~ lte14 범위 리셋
  python3 cmd/reset_lte.py all                    # 감지된 모든 LTE 모뎀 리셋
  python3 cmd/reset_lte.py --mode api 11          # 화웨이 Hilink Web API 모뎀 소프트 재부팅
  python3 cmd/reset_lte.py --mode full 11         # API 재부팅 후 USB 언바인드/바인드 복합 리셋
        """
    )
    parser.add_argument("targets", nargs="*", default=[], help="Target interface or subnet (e.g. 11, lte12, 11-14, all)")
    parser.add_argument("--list", "-l", action="store_true", help="List detected LTE interfaces and dynamic USB ports")
    parser.add_argument("--mode", "-m", choices=["usb", "api", "full"], default="usb",
                        help="Reset mode: 'usb' (Hardware unbind/bind, default), 'api' (Hilink API reboot), 'full' (API + USB)")
    parser.add_argument("--wait", "-w", type=int, default=3, help="Seconds to wait between USB unbind and bind (default: 3)")
    parser.add_argument("--no-fix", action="store_true", help="Skip running fix_eth_number.sh after reset")

    args = parser.parse_args()

    print(f"\n{CLR_BOLD}{CLR_BLUE}======================================================================{CLR_RESET}")
    print(f"{CLR_BOLD} 🔄 LTE Multi-Modem Real-Time Dynamic USB Reset & Health Tool{CLR_RESET}")
    print(f"{CLR_BOLD}{CLR_BLUE}======================================================================{CLR_RESET}")

    all_devices = discover_all_lte_devices()
    if not all_devices:
        log("No LTE modem interfaces (lte11~lte20) detected on this server.", "WARN")
        sys.exit(1)

    if args.list:
        print_table(all_devices)
        sys.exit(0)

    targets = parse_targets(args.targets, all_devices)
    if not targets:
        print_table(all_devices)
        log(f"Specified targets '{args.targets}' did not match any active LTE interfaces.", "RED")
        sys.exit(1)

    print_table(targets)
    log(f"Targeting {len(targets)} modem(s): {', '.join(t['iface'] for t in targets)} (Mode: {args.mode.upper()})", "INFO")

    reset_success_count = 0

    for dev in targets:
        iface = dev["iface"]
        subnet = dev["subnet"]
        usb_port = dev["usb_port"]
        gw = dev["gw"]

        print(f"\n{CLR_BOLD}▶ Processing {CLR_CYAN}{iface}{CLR_RESET} (Subnet: {subnet}, USB Port: {CLR_YELLOW}{usb_port or 'N/A'}{CLR_RESET}):{CLR_RESET}")

        # 1. API Reboot Mode
        if args.mode in ["api", "full"]:
            log(f"Sending Hilink API reboot to http://{gw}/...", "INFO")
            ok_api, msg_api = reboot_hilink_api(subnet, gw=gw)
            if ok_api:
                log(f"Hilink API reboot: {msg_api}", "OK")
            else:
                log(f"Hilink API reboot failed ({msg_api})", "WARN")

        # 2. Hardware USB Unbind/Bind Mode
        if args.mode in ["usb", "full"]:
            if not usb_port:
                # Real-time re-check if it wasn't detected
                usb_port = get_realtime_usb_port(iface)

            if not usb_port:
                log(f"Cannot perform USB unbind/bind: USB port path could not be resolved for {iface}", "RED")
                continue

            log(f"Executing USB Hardware Unbind on port '{usb_port}'...", "INFO")
            ok_un, msg_un = reset_usb_hardware(usb_port, wait_sec=args.wait)
            if ok_un:
                log(f"Hardware USB Power-Cycle completed: {msg_un} (waited {args.wait}s)", "OK")
                reset_success_count += 1
            else:
                log(f"Hardware USB Reset failed: {msg_un}", "RED")

    # 3. Post-Reset Interface & Routing Restoration
    if not args.no_fix:
        log("Waiting 6 seconds for USB devices to re-enumerate in kernel...", "INFO")
        time.sleep(6)
        trigger_fix_eth_number()

    # 4. Final Verification
    print(f"\n{CLR_BOLD}📋 Post-Reset Verification & Public IP Check:{CLR_RESET}")
    print("+" + "-"*8 + "+" + "-"*12 + "+" + "-"*18 + "+" + "-"*18 + "+")
    print(f"| {'IFACE':<6} | {'STATUS':<10} | {'LOCAL IP':<16} | {'PUBLIC IP':<16} |")
    print("+" + "-"*8 + "+" + "-"*12 + "+" + "-"*18 + "+" + "-"*18 + "+")
    for dev in targets:
        iface = dev["iface"]
        pub_ip = get_public_ip(iface)
        ip_out = run_cmd(f"ip -4 addr show {iface}") or ""
        m_local = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", ip_out)
        loc_ip = m_local.group(1) if m_local else "No IP"
        status_str = f"{CLR_GREEN}ONLINE{CLR_RESET}" if "Offline" not in pub_ip else f"{CLR_YELLOW}CHECKING{CLR_RESET}"
        print(f"| {iface:<6} | {status_str:<19} | {loc_ip:<16} | {pub_ip:<16} |")
    print("+" + "-"*8 + "+" + "-"*12 + "+" + "-"*18 + "+" + "-"*18 + "+\n")

    log("Reset & Recovery operation finished.", "OK")

if __name__ == "__main__":
    main()
