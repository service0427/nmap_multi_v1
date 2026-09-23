#!/usr/bin/env python3
"""
LTE Multi-Modem Diagnostic & Auto-Cure Optimizer
- Checks & disables Huawei Modem SIP ALG (fixes modem CPU lockup & ACK drops)
- Checks & sets LTE interface MTU to 1420 (fixes LTE packet fragmentation & loss)
- Checks & optimizes Linux kernel TCP socket tuning (fixes FIN-WAIT-1 & TIME-WAIT socket accumulation)
- Checks & repairs routing table rules per LTE interface
- Tests latency (ping) and public IP connectivity
- Supports --reboot for recovering frozen/deadlocked modems
"""

import os
import sys
import re
import time
import argparse
import subprocess
import requests

try:
    from huawei_lte_api.Client import Client
    from huawei_lte_api.Connection import Connection
except ImportError:
    print("[!] huawei_lte_api module not found. Installing...")
    subprocess.run([sys.executable, "-m", "pip", "install", "huawei-lte-api"], check=True)
    from huawei_lte_api.Client import Client
    from huawei_lte_api.Connection import Connection

MODEM_USER = "admin"
MODEM_PASS = "KdjLch!@7024"
TARGET_MTU = 1420
SYSCTL_CONF = "/etc/sysctl.d/99-lte-tuning.conf"

SYSCTL_PARAMS = {
    "net.ipv4.conf.all.arp_ignore": "1",
    "net.ipv4.conf.all.arp_announce": "2",
    "net.ipv4.conf.all.rp_filter": "2",
    "net.ipv4.tcp_fin_timeout": "15",
    "net.ipv4.tcp_tw_reuse": "1",
    "net.ipv4.tcp_keepalive_time": "60",
    "net.ipv4.tcp_keepalive_intvl": "10",
    "net.ipv4.tcp_keepalive_probes": "5",
    "net.ipv4.ip_local_port_range": "1024 65535",
}

# ANSI Colors
CLR_RESET = "\033[0m"
CLR_BOLD = "\033[1m"
CLR_RED = "\033[1;31m"
CLR_GREEN = "\033[1;32m"
CLR_YELLOW = "\033[1;33m"
CLR_BLUE = "\033[1;34m"
CLR_CYAN = "\033[1;36m"
CLR_WHITE = "\033[1;37m"

def run_cmd(cmd, check=False, timeout=15):
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

def get_lte_interfaces():
    """Detect LTE interfaces (lte11~lte30, or MAC starting with 00:1e:10)"""
    interfaces = []
    net_dir = "/sys/class/net"
    if not os.path.exists(net_dir):
        return interfaces

    for iface in sorted(os.listdir(net_dir)):
        addr_file = os.path.join(net_dir, iface, "address")
        mac = ""
        if os.path.exists(addr_file):
            try:
                with open(addr_file, "r") as f:
                    mac = f.read().strip().lower()
            except Exception:
                pass

        is_lte = False
        if iface.startswith("lte"):
            is_lte = True
        elif mac.startswith("00:1e:10"):
            is_lte = True

        if not is_lte:
            continue

        # Extract subnet
        subnet = None
        match = re.search(r"lte(\d+)", iface)
        if match:
            subnet = int(match.group(1))
        else:
            # Try to get from IP
            ip_out = run_cmd(f"ip -4 addr show {iface}")
            if ip_out:
                ip_match = re.search(r"inet 192\.168\.(\d+)\.", ip_out)
                if ip_match:
                    subnet = int(ip_match.group(1))

        interfaces.append({
            "iface": iface,
            "mac": mac,
            "subnet": subnet,
            "gateway": f"192.168.{subnet}.1" if subnet else None
        })

    return interfaces

def get_interface_mtu(iface):
    mtu_file = f"/sys/class/net/{iface}/mtu"
    if os.path.exists(mtu_file):
        try:
            with open(mtu_file, "r") as f:
                return int(f.read().strip())
        except Exception:
            pass
    return None

def set_interface_mtu(iface, mtu):
    run_sudo(f"ip link set dev {iface} mtu {mtu}")
    return get_interface_mtu(iface) == mtu

def logout_modem_raw(modem_ip):
    try:
        requests.post(
            f"http://{modem_ip}/api/user/logout",
            data='<?xml version="1.0" encoding="UTF-8"?><request><Logout>1</Logout></request>',
            headers={"Content-Type": "application/xml"},
            timeout=3
        )
    except Exception:
        pass

def check_and_cure_sip_alg(modem_ip, cure=True, max_retries=3, timeout=12):
    """
    Check Huawei Modem SIP ALG with adaptive timeout & retries.
    Returns: (initial_status, cured_status, message)
    initial_status: 'ENABLED', 'DISABLED', 'ERROR', 'UNREACHABLE'
    """
    last_err = None

    for attempt in range(1, max_retries + 1):
        try:
            conn = Connection(f"http://{modem_ip}/", username=MODEM_USER, password=MODEM_PASS, timeout=timeout)
            client = None
            try:
                client = Client(conn)
            except Exception as e:
                err_str = str(e)
                if "Already login" in err_str or "108003" in err_str:
                    logout_modem_raw(modem_ip)
                    time.sleep(1.5)
                    conn = Connection(f"http://{modem_ip}/", username=MODEM_USER, password=MODEM_PASS, timeout=timeout)
                    client = Client(conn)
                else:
                    raise e

            sip_info = client.security.sip()
            initial_status = "ENABLED" if sip_info.get("SipStatus") == "1" else "DISABLED"
            cured_status = initial_status

            if initial_status == "ENABLED" and cure:
                client.security.set_sip(enabled=False, port=5060)
                time.sleep(0.5)
                verify_info = client.security.sip()
                cured_status = "ENABLED" if verify_info.get("SipStatus") == "1" else "DISABLED"

            try:
                client.user.logout()
            except Exception:
                pass

            return initial_status, cured_status, None

        except requests.exceptions.Timeout:
            last_err = f"Timeout ({timeout}s) - Modem CPU overloaded"
        except requests.exceptions.ConnectionError:
            last_err = "Connection refused or unreachable"
        except Exception as e:
            last_err = str(e)

        if attempt < max_retries:
            time.sleep(1.5)

    return "ERROR", None, last_err

def reboot_modem_device(iface, subnet, gw):
    """Reboot modem via Hilink API, falling back to USB driver unbind/bind"""
    # 1. API Reboot
    if gw:
        try:
            conn = Connection(f"http://{gw}/", username=MODEM_USER, password=MODEM_PASS, timeout=8)
            client = Client(conn)
            client.device.reboot()
            print(f"     ✔ [{iface}] Hilink API reboot command sent successfully.")
            return True
        except Exception as e:
            print(f"     ⚠ [{iface}] API reboot failed ({e}), attempting USB hardware reset...")

    # 2. USB reset via driver unbind/bind
    try:
        cmd = f"ls -la /sys/class/net/{iface}/device/driver/ | grep {iface} | awk '{{print $9}}'"
        usb_path = run_cmd(cmd)
        if usb_path:
            run_sudo(f"echo '{usb_path}' | tee /sys/bus/usb/drivers/cdc_ether/unbind > /dev/null")
            time.sleep(2)
            run_sudo(f"echo '{usb_path}' | tee /sys/bus/usb/drivers/cdc_ether/bind > /dev/null")
            print(f"     ✔ [{iface}] USB driver rebound ({usb_path}).")
            return True
    except Exception as e:
        print(f"     ❌ [{iface}] USB reset failed: {e}")

    return False

def check_and_cure_routing(iface, subnet, cure=True):
    """Ensure routing table and IP rules exist for LTE interface"""
    if not subnet:
        return "UNKNOWN", None

    table_id = str(subnet)
    gw = f"192.168.{subnet}.1"
    
    # Check rt_tables entry
    rt_tables_file = "/etc/iproute2/rt_tables"
    has_rt_entry = False
    if os.path.exists(rt_tables_file):
        with open(rt_tables_file, "r") as f:
            for line in f:
                if line.strip().startswith(f"{table_id} ") or line.strip().endswith(f" lte{table_id}"):
                    has_rt_entry = True
                    break

    # Check route
    route_out = run_cmd(f"ip route show table {table_id}")
    has_route = f"default via {gw}" in (route_out or "")

    # Check rule
    rule_out = run_cmd("ip rule show")
    has_rule = f"lookup {table_id}" in (rule_out or "") or f"table {table_id}" in (rule_out or "")

    initial_ok = has_route and has_rule
    cured_ok = initial_ok

    if not initial_ok and cure:
        if not has_rt_entry:
            run_sudo(f'bash -c \'echo "{table_id} lte{table_id}" >> /etc/iproute2/rt_tables\'')
        run_sudo(f"ip route replace default via {gw} dev {iface} table {table_id}")
        
        # Get local IP
        ip_out = run_cmd(f"ip -4 addr show {iface}")
        local_ip_match = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", ip_out or "")
        if local_ip_match:
            local_ip = local_ip_match.group(1)
            run_sudo(f"ip rule del from {local_ip} table {table_id} 2>/dev/null || true")
            run_sudo(f"ip rule add from {local_ip} table {table_id} priority 5209")
        run_sudo(f"ip rule del from 192.168.{subnet}.0/24 table {table_id} 2>/dev/null || true")
        run_sudo(f"ip rule add from 192.168.{subnet}.0/24 table {table_id} priority 5209")

        # Verify
        verify_route = run_cmd(f"ip route show table {table_id}")
        verify_rule = run_cmd("ip rule show")
        cured_ok = (f"default via {gw}" in (verify_route or "")) and (f"{table_id}" in (verify_rule or ""))

    return ("OK" if initial_ok else "DEFECTIVE"), ("OK" if cured_ok else "FAILED")

def test_connectivity(iface):
    """Test ping latency to 8.8.8.8 and get public IP"""
    ping_out = run_cmd(f"ping -c 3 -W 3 -I {iface} 8.8.8.8", timeout=15)
    loss = "100%"
    avg_rtt = "N/A"
    
    if ping_out:
        loss_match = re.search(r"([\d.]+)% packet loss", ping_out)
        if loss_match:
            loss_val = float(loss_match.group(1))
            loss = f"{loss_val:.0f}%"
        rtt_match = re.search(r"rtt min/avg/max/mdev = [\d.]+/([\d.]+)/", ping_out)
        if rtt_match:
            avg_rtt = f"{float(rtt_match.group(1)):.1f}ms"

    # Public IP
    public_ip = "N/A"
    for url in ["https://api.ipify.org", "https://icanhazip.com"]:
        ip_res = run_cmd(f"curl --interface {iface} -s -m 5 {url}", timeout=6)
        if ip_res and re.match(r"^\d+\.\d+\.\d+\.\d+$", ip_res.strip()):
            public_ip = ip_res.strip()
            break

    return avg_rtt, loss, public_ip

def check_and_cure_sysctl(cure=True):
    """Check and apply kernel TCP tuning"""
    diffs = {}
    current_values = {}
    for key, target_val in SYSCTL_PARAMS.items():
        curr = run_cmd(f"sysctl -n {key}")
        current_values[key] = curr
        curr_norm = " ".join((curr or "").split())
        target_norm = " ".join(target_val.split())
        if curr_norm != target_norm:
            diffs[key] = (curr, target_val)

    initial_status = "TUNED" if not diffs else "SUBOPTIMAL"
    cured_status = initial_status

    if diffs and cure:
        conf_lines = ["# Optimized LTE & TCP socket recycling tuning"]
        for k, v in SYSCTL_PARAMS.items():
            conf_lines.append(f"{k} = {v}")
        conf_content = "\n".join(conf_lines) + "\n"

        tmp_file = "/tmp/99-lte-tuning.conf"
        try:
            with open(tmp_file, "w") as f:
                f.write(conf_content)

            run_sudo(f"cp {tmp_file} {SYSCTL_CONF}")
            run_sudo(f"sysctl -p {SYSCTL_CONF}")
            if os.path.exists(tmp_file):
                os.remove(tmp_file)
        except Exception as e:
            print(f"  [!] Failed to write {SYSCTL_CONF}: {e}")

        # Re-verify
        recheck_diffs = []
        for key, target_val in SYSCTL_PARAMS.items():
            curr = run_cmd(f"sysctl -n {key}")
            curr_norm = " ".join((curr or "").split())
            target_norm = " ".join(target_val.split())
            if curr_norm != target_norm:
                recheck_diffs.append(key)
        cured_status = "TUNED" if not recheck_diffs else "PARTIAL"

    return initial_status, cured_status, diffs

def get_socket_counts():
    """Count sockets by TCP state"""
    fin1 = run_cmd("ss -tan state fin-wait-1 | wc -l")
    tw = run_cmd("ss -tan state time-wait | wc -l")
    estab = run_cmd("ss -tan state established | wc -l")
    
    def parse_cnt(val):
        try:
            n = int(val)
            return max(0, n - 1)
        except Exception:
            return 0

    return {
        "fin_wait_1": parse_cnt(fin1),
        "time_wait": parse_cnt(tw),
        "established": parse_cnt(estab)
    }

def print_header(title):
    print(f"\n{CLR_BOLD}{CLR_BLUE}======================================================================{CLR_RESET}")
    print(f"{CLR_BOLD}{CLR_WHITE} 🚀 {title}{CLR_RESET}")
    print(f"{CLR_BOLD}{CLR_BLUE}======================================================================{CLR_RESET}")

def main():
    parser = argparse.ArgumentParser(description="LTE Multi-Modem Diagnostic & Auto-Cure Optimizer")
    parser.add_argument("target", nargs="?", default=None, help="Target interface or subnet (e.g. lte11, 11)")
    parser.add_argument("--iface", type=str, help="Specific interface to target (e.g. lte12)")
    parser.add_argument("--check-only", action="store_true", help="Only check status without modifying settings")
    parser.add_argument("--reboot", action="store_true", help="Reboot target modem to resolve deep freeze/deadlock")
    args = parser.parse_args()

    target_name = args.target or args.iface
    cure = not args.check_only
    action_label = "Checking & Auto-Curing" if cure else "Checking Only (Dry-Run)"

    print_header(f"LTE Multi-Modem Optimizer ({action_label})")

    # 1. Discover interfaces
    all_interfaces = get_lte_interfaces()
    if target_name:
        interfaces = [i for i in all_interfaces if i["iface"] == target_name or str(i["subnet"]) == target_name]
        if not interfaces:
            print(f"{CLR_RED}[❌] Specified interface '{target_name}' not found!{CLR_RESET}")
            sys.exit(1)
    else:
        interfaces = all_interfaces

    if not interfaces:
        print(f"{CLR_YELLOW}[!] No LTE modem interfaces detected.{CLR_RESET}")
        print("    (Interface name must be lte* or MAC must start with 00:1e:10)")
        sys.exit(0)

    print(f"{CLR_CYAN}[*] Detected {len(interfaces)} LTE modem interface(s): {', '.join(i['iface'] for i in interfaces)}{CLR_RESET}\n")

    # Optional Modem Reboot
    if args.reboot:
        print(f"{CLR_BOLD}[*] Reboot requested. Rebooting target modems...{CLR_RESET}")
        for item in interfaces:
            reboot_modem_device(item["iface"], item["subnet"], item["gateway"])
        print(f"  ⏳ Waiting 20 seconds for modems to restart and acquire IP leases...")
        time.sleep(20)
        print(f"  ✔ Resuming diagnostic & optimization...")

    # Record initial socket stats
    sockets_before = get_socket_counts()

    # 2. Kernel TCP Tuning
    print(f"{CLR_BOLD}[1/4] Linux Kernel TCP Tuning Inspection & Cure...{CLR_RESET}")
    sys_init, sys_cured, sys_diffs = check_and_cure_sysctl(cure=cure)
    if sys_init == "TUNED":
        print(f"  {CLR_GREEN}✔ Kernel TCP settings already fully optimized.{CLR_RESET}")
    else:
        if cure:
            print(f"  {CLR_CYAN}⚡ Applied TCP tuning to {SYSCTL_CONF} & reloaded sysctl:{CLR_RESET}")
            for k, (c, t) in sys_diffs.items():
                print(f"     - {k}: {CLR_YELLOW}{c}{CLR_RESET} -> {CLR_GREEN}{t}{CLR_RESET}")
            print(f"  {CLR_GREEN}✔ Kernel status: {sys_cured}{CLR_RESET}")
        else:
            print(f"  {CLR_YELLOW}⚠ Kernel TCP parameters are suboptimal:{CLR_RESET}")
            for k, (c, t) in sys_diffs.items():
                print(f"     - {k}: {c} (Recommended: {t})")

    # 3. Process each modem interface
    print(f"\n{CLR_BOLD}[2/4] LTE Interface MTU & Routing Table Check...{CLR_RESET}")
    results = []

    for item in interfaces:
        iface = item["iface"]
        subnet = item["subnet"]
        gw = item["gateway"]

        print(f"  ⚙ Inspecting {CLR_BOLD}{iface}{CLR_RESET} (Gateway: {gw or 'Unknown'})...")

        # A. MTU Check & Cure
        curr_mtu = get_interface_mtu(iface)
        init_mtu = curr_mtu
        cured_mtu = curr_mtu
        if curr_mtu != TARGET_MTU and cure:
            if set_interface_mtu(iface, TARGET_MTU):
                cured_mtu = TARGET_MTU

        # B. Routing Check & Cure
        init_rt, cured_rt = check_and_cure_routing(iface, subnet, cure=cure)

        # C. SIP ALG Check & Cure
        init_sip, cured_sip, sip_err = ("N/A", "N/A", None)
        if gw:
            init_sip, cured_sip, sip_err = check_and_cure_sip_alg(gw, cure=cure)

        # D. Connectivity Test
        avg_rtt, loss, pub_ip = test_connectivity(iface)

        results.append({
            "iface": iface,
            "subnet": subnet,
            "gw": gw,
            "init_mtu": init_mtu,
            "cured_mtu": cured_mtu,
            "init_sip": init_sip,
            "cured_sip": cured_sip,
            "sip_err": sip_err,
            "init_rt": init_rt,
            "cured_rt": cured_rt,
            "rtt": avg_rtt,
            "loss": loss,
            "pub_ip": pub_ip
        })

    # Record sockets after
    time.sleep(1)
    sockets_after = get_socket_counts()

    # 4. Final Summary Table
    print(f"\n{CLR_BOLD}[3/4] Optimization & Diagnostic Results Summary{CLR_RESET}")
    print("+" + "-"*8 + "+" + "-"*12 + "+" + "-"*15 + "+" + "-"*12 + "+" + "-"*10 + "+" + "-"*10 + "+" + "-"*16 + "+")
    print(f"| {'IFACE':<6} | {'MTU':<10} | {'SIP ALG':<13} | {'ROUTING':<10} | {'LATENCY':<8} | {'LOSS':<8} | {'PUBLIC IP':<14} |")
    print("+" + "-"*8 + "+" + "-"*12 + "+" + "-"*15 + "+" + "-"*12 + "+" + "-"*10 + "+" + "-"*10 + "+" + "-"*16 + "+")

    for r in results:
        # Format MTU
        if r["cured_mtu"] == TARGET_MTU:
            if r["init_mtu"] != TARGET_MTU:
                mtu_str = f"{r['init_mtu']}->{r['cured_mtu']}"
            else:
                mtu_str = f"{r['cured_mtu']} (OK)"
        else:
            mtu_str = f"{r['cured_mtu']} (!)"

        # Format SIP
        if r["cured_sip"] == "DISABLED":
            if r["init_sip"] == "ENABLED":
                sip_str = "OFF (Cured)"
            else:
                sip_str = "OFF (OK)"
        elif r["cured_sip"] == "ENABLED":
            sip_str = "ON (Active!)"
        else:
            sip_str = r["cured_sip"] or "ERR"

        # Format Routing
        rt_str = r["cured_rt"]

        # Format Latency / Loss
        lat_str = r["rtt"]
        loss_str = r["loss"]
        ip_str = r["pub_ip"]

        print(f"| {r['iface']:<6} | {mtu_str:<10} | {sip_str:<13} | {rt_str:<10} | {lat_str:<8} | {loss_str:<8} | {ip_str:<14} |")

    print("+" + "-"*8 + "+" + "-"*12 + "+" + "-"*15 + "+" + "-"*12 + "+" + "-"*10 + "+" + "-"*10 + "+" + "-"*16 + "+")

    # 5. Socket Status
    print(f"\n{CLR_BOLD}[4/4] Kernel TCP Socket Health Status{CLR_RESET}")
    print(f"  • FIN-WAIT-1 Sockets : {CLR_YELLOW if sockets_before['fin_wait_1'] > 20 else CLR_GREEN}{sockets_before['fin_wait_1']}{CLR_RESET} -> {CLR_GREEN}{sockets_after['fin_wait_1']}{CLR_RESET}")
    print(f"  • TIME-WAIT Sockets  : {CLR_YELLOW if sockets_before['time_wait'] > 1000 else CLR_GREEN}{sockets_before['time_wait']}{CLR_RESET} -> {CLR_GREEN}{sockets_after['time_wait']}{CLR_RESET} (Max timeout reduced to 15s)")
    print(f"  • Active Established : {sockets_after['established']}")

    # 6. Detailed Issue Reporting & Suggestions
    has_issues = False
    for r in results:
        if r["sip_err"] or r["cured_sip"] != "DISABLED" or r["loss"] != "0%":
            if not has_issues:
                print(f"\n{CLR_BOLD}{CLR_YELLOW}[!] Detailed Diagnostics & Action Needed:{CLR_RESET}")
                has_issues = True
            
            print(f"  • {CLR_BOLD}{r['iface']}{CLR_RESET} (Gateway: {r['gw']}):")
            if r["sip_err"]:
                print(f"     - SIP ALG Issue: {CLR_RED}{r['sip_err']}{CLR_RESET}")
            if r["loss"] != "0%":
                print(f"     - Packet Loss: {CLR_RED}{r['loss']}{CLR_RESET} (Latency: {r['rtt']})")
            
            print(f"     👉 {CLR_CYAN}Solution:{CLR_RESET} The modem CPU is currently hung/overloaded by SIP packet storm.")
            print(f"        Run reboot command: {CLR_WHITE}./cmd.sh --lte --reboot {r['iface']}{CLR_RESET}")
            print(f"        or smart recovery : {CLR_WHITE}python3 wifi_multi/smart_toggle.py {r['subnet']}{CLR_RESET}")

    # Check overall health
    all_mtu_ok = all(r["cured_mtu"] == TARGET_MTU for r in results)
    all_sip_ok = all(r["cured_sip"] == "DISABLED" for r in results)
    all_loss_ok = all(r["loss"] == "0%" for r in results)

    print(f"\n{CLR_BOLD}{CLR_BLUE}======================================================================{CLR_RESET}")
    if all_mtu_ok and all_sip_ok and all_loss_ok and (sys_cured == "TUNED"):
        print(f"{CLR_BOLD}{CLR_GREEN} ✔ ALL LTE MODEMS FULLY OPTIMIZED & HEALTHY! (Packet Loss 0%){CLR_RESET}")
    else:
        print(f"{CLR_BOLD}{CLR_YELLOW} ⚠ Optimization completed with warnings on some modems. Check details above.{CLR_RESET}")
    print(f"{CLR_BOLD}{CLR_BLUE}======================================================================{CLR_RESET}\n")

if __name__ == "__main__":
    main()
