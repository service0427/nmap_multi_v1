#!/usr/bin/env python3
import os
import sys
import re
import subprocess
import time

def is_lte_subnet(iface):
    try:
        ip_out = subprocess.check_output(f"ip -4 addr show {iface}", shell=True).decode()
        if "inet 192.168." in ip_out:
            return True
    except Exception:
        pass
    return False

# 1. Dynamically detect primary wired interface
def get_primary_interface():
    try:
        # Check active connected ethernet via nmcli
        nm_out = subprocess.check_output("nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null", shell=True).decode()
        for line in nm_out.splitlines():
            parts = line.split(':')
            if len(parts) >= 3 and parts[1] == 'ethernet' and parts[2] == 'connected':
                dev = parts[0]
                if not is_lte_subnet(dev):
                    return dev
    except Exception:
        pass
    
    try:
        # Fallback to default route interface
        route_out = subprocess.check_output("ip route show default", shell=True).decode()
        for line in route_out.splitlines():
            if 'dev' in line:
                parts = line.split()
                dev_idx = parts.index('dev')
                dev = parts[dev_idx + 1]
                if not any(x in dev for x in ['lte', 'usb', 'enx']):
                    if not is_lte_subnet(dev):
                        return dev
    except Exception:
        pass
    return "eth0"

PRIMARY_IFACE = get_primary_interface()
print(f"[*] Detected Primary Wired Interface: {PRIMARY_IFACE}")

def get_gateway_ip(iface):
    try:
        res = subprocess.check_output(f"ip -4 route show dev {iface}", shell=True).decode()
        # Look for default route
        match_default = re.search(r'default via (\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})', res)
        if match_default:
            return match_default.group(1)
        # Look for subnet route
        for line in res.splitlines():
            if '/' in line:
                network_part = line.split()[0].split('/')[0]
                gateway = network_part.rsplit('.', 1)[0] + '.1'
                return gateway
    except Exception:
        pass
    return None

def is_table_valid(subnet):
    """Check if policy routing table exists and has a default route."""
    try:
        res = subprocess.check_output(f"ip route show table {subnet}", shell=True).decode()
        if "default via" in res:
            return True
    except Exception:
        pass
    return False

def kill_dhclient(iface):
    """Kill any running dhclient process for the given interface."""
    try:
        # Find PIDs of dhclient running on this interface
        pgrep_out = subprocess.check_output(f"pgrep -f 'dhclient.*{iface}'", shell=True).decode().strip()
        if pgrep_out:
            for pid in pgrep_out.split():
                print(f"[*] Killing dhclient process {pid} for {iface}...")
                subprocess.run(["sudo", "kill", "-9", pid])
    except Exception:
        pass

def fix_interface(iface, force_route=False):
    print(f"\n[*] Processing interface: {iface}")
    # Ensure interface is UP
    try:
        operstate = ""
        if os.path.exists(f"/sys/class/net/{iface}/operstate"):
            with open(f"/sys/class/net/{iface}/operstate", "r") as f:
                operstate = f.read().strip().lower()
        if operstate == "down":
            print(f"[*] Interface {iface} is down. Bringing it up...")
            subprocess.run(["sudo", "ip", "link", "set", iface, "up"])
            time.sleep(2)
    except Exception as e:
        print(f"[!] Error bringing up {iface}: {e}")

    gw = get_gateway_ip(iface)
    if not gw:
        # Try running dhclient once to get an IP/gateway
        print(f"[*] Interface {iface} has no IP/route. Requesting lease...")
        subprocess.run(["sudo", "ip", "addr", "flush", "dev", iface])
        subprocess.run(["sudo", "dhclient", "-v", iface], timeout=15, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        gw = get_gateway_ip(iface)
        
    if not gw:
        print(f"[!] Could not determine gateway for {iface}. Skipping.")
        return False
        
    try:
        subnet = gw.split(".")[2]
        new_name = f"lte{subnet}"
    except Exception as e:
        print(f"[!] Error parsing subnet for gateway {gw}: {e}")
        return False
        
    table_id = subnet
    table_valid = is_table_valid(table_id)
    
    if iface == new_name and table_valid and not force_route:
        print(f"[*] Interface {iface} is already named correctly and routing is valid.")
        return True
        
    if iface != new_name:
        # Check for name collision
        if os.path.exists(f"/sys/class/net/{new_name}"):
            tmp_name = f"tmp_{new_name}"
            counter = 1
            while os.path.exists(f"/sys/class/net/{tmp_name}"):
                tmp_name = f"tmp_{new_name}_{counter}"
                counter += 1
            print(f"[*] Name collision! Temporarily renaming existing {new_name} -> {tmp_name}")
            
            kill_dhclient(new_name)
            subprocess.run(["sudo", "ip", "route", "del", "default", "dev", new_name], stderr=subprocess.DEVNULL)
            subprocess.run(["sudo", "ip", "link", "set", new_name, "down"])
            time.sleep(1)
            res = subprocess.run(["sudo", "ip", "link", "set", new_name, "name", tmp_name], capture_output=True, text=True)
            if res.returncode != 0:
                print(f"[!] Collision rename failed: {res.stderr.strip()}")
                subprocess.run(["sudo", "ip", "link", "set", new_name, "up"])
                return False
            subprocess.run(["sudo", "ip", "link", "set", tmp_name, "up"])
            time.sleep(1)

        print(f"[*] Renaming {iface} -> {new_name} (Subnet: {subnet})")
        
        # 1. Kill dhclient and delete default route from main table
        kill_dhclient(iface)
        subprocess.run(["sudo", "ip", "route", "del", "default", "dev", iface], stderr=subprocess.DEVNULL)
        
        # 2. Down interface
        subprocess.run(["sudo", "ip", "link", "set", iface, "down"])
        time.sleep(1)
        
        # 3. Rename interface
        res = subprocess.run(["sudo", "ip", "link", "set", iface, "name", new_name], capture_output=True, text=True)
        if res.returncode != 0:
            print(f"[!] Rename failed: {res.stderr.strip()}")
            # Bring it back up just in case
            subprocess.run(["sudo", "ip", "link", "set", iface, "up"])
            return False
            
        # 4. Up interface
        subprocess.run(["sudo", "ip", "link", "set", new_name, "up"])
        time.sleep(1)
        
        # 5. Run dhclient on new interface
        print(f"[*] Starting dhclient on {new_name}...")
        subprocess.run(["sudo", "ip", "addr", "flush", "dev", new_name])
        subprocess.run(["sudo", "dhclient", "-v", new_name], timeout=15, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    
    # Clean up default route and add with proper metric (200 + subnet)
    subprocess.run(["sudo", "ip", "route", "del", "default", "dev", new_name], stderr=subprocess.DEVNULL)
    metric_val = 200 + int(subnet)
    subprocess.run(["sudo", "ip", "route", "add", "default", "via", gw, "dev", new_name, "metric", str(metric_val)], stderr=subprocess.DEVNULL)
    
    # 6. Setup Policy Routing
    print(f"[*] Configuring policy routing for {new_name}...")
    subprocess.run(f"grep -q \"^{table_id} lte{table_id}\" /etc/iproute2/rt_tables || echo \"{table_id} lte{table_id}\" | sudo tee -a /etc/iproute2/rt_tables", shell=True, stdout=subprocess.DEVNULL)
    subprocess.run(["sudo", "ip", "route", "flush", "table", str(table_id)])
    subprocess.run(["sudo", "ip", "route", "add", "default", "via", gw, "dev", new_name, "table", str(table_id)])
    
    try:
        ip_out = subprocess.check_output(f"ip -4 addr show {new_name} | grep inet", shell=True).decode()
        if 'inet' in ip_out:
            local_ip = ip_out.split()[1].split('/')[0]
            subprocess.run(["sudo", "ip", "rule", "del", "from", local_ip, "table", str(table_id)], stderr=subprocess.DEVNULL)
            subprocess.run(["sudo", "ip", "rule", "add", "from", local_ip, "table", str(table_id)])
    except Exception as e:
        print(f"[!] Error configuring routing rule for {new_name}: {e}")
        return False
        
    print(f"✅ {new_name} Synced and Isolated Successfully")
    return True

def main():
    os.makedirs('/etc/iproute2', exist_ok=True)
    
    max_passes = 4
    for pass_num in range(max_passes):
        interfaces = os.listdir('/sys/class/net')
        fixed_any = False
        
        for iface in interfaces:
            if iface == PRIMARY_IFACE:
                continue
                
            mac = ""
            try:
                with open(f'/sys/class/net/{iface}/address', 'r') as f:
                    mac = f.read().strip().lower()
            except:
                pass
                
            # Match by MAC address or Name pattern (including z_*)
            is_target = (mac == "00:1e:10:1f:00:00") or bool(re.match(r"^(eth\d+|usb\d+|enx\w+|lte\d+|tmp_\w+|z_\w+)", iface))
            if is_target:
                force_route = False
                if iface.startswith('lte'):
                    gw = get_gateway_ip(iface)
                    if gw:
                        try:
                            actual_subnet = gw.split(".")[2]
                            new_name = f"lte{actual_subnet}"
                            if iface != new_name:
                                print(f"[*] Interface {iface} has subnet {actual_subnet} but is named {iface}. Renaming needed.")
                                force_route = True
                        except Exception:
                            pass
                    
                    if not force_route:
                        subnet = iface.replace('lte', '')
                        if not is_table_valid(subnet):
                            print(f"[*] Interface {iface} routing table is invalid or empty.")
                            force_route = True
                        else:
                            continue
                
                if fix_interface(iface, force_route=force_route):
                    fixed_any = True
                    break # Restart loop pass
                    
        if not fixed_any:
            break
            
    # Final check
    interfaces = os.listdir('/sys/class/net')
    misnamed = []
    for i in interfaces:
        if i == PRIMARY_IFACE:
            continue
        mac = ""
        try:
            with open(f'/sys/class/net/{i}/address', 'r') as f:
                mac = f.read().strip().lower()
        except:
            pass
        if mac == "00:1e:10:1f:00:00" and not i.startswith("lte"):
            misnamed.append(i)
        elif re.match(r"^(eth\d+|usb\d+|enx\w+|tmp_\w+|z_\w+)", i):
            misnamed.append(i)
            
    if misnamed:
        print(f"[!] Some interfaces could not be fully resolved: {misnamed}")
    else:
        print("[*] All interfaces are named correctly and routing is valid.")

def get_realtime_usb_port(iface):
    """
    Dynamically discovers the physical USB device node (e.g. 3-4.3, 1-1.2)
    by traversing up sysfs from /sys/class/net/{iface}/device.
    Works dynamically across any server hardware or USB hub topology.
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

def list_lte_usb_ports():
    """Prints detected LTE interfaces and dynamic USB port mapping."""
    print("\n" + "="*65)
    print(" 📡 LTE Modems & Real-Time Dynamic USB Port Mapping")
    print("="*65)
    print(f"{'INTERFACE':<12} | {'SUBNET':<8} | {'USB PORT':<12} | {'GATEWAY':<16}")
    print("-" * 65)
    
    found = 0
    for iface in sorted(os.listdir('/sys/class/net')):
        if iface.startswith("lte") or iface.startswith("enx") or iface.startswith("usb"):
            usb_p = get_realtime_usb_port(iface)
            if usb_p:
                gw = get_gateway_ip(iface) or "N/A"
                subnet = gw.split(".")[2] if "." in gw else (iface.replace("lte", "") if iface.startswith("lte") else "N/A")
                print(f"{iface:<12} | {subnet:<8} | {usb_p:<12} | {gw:<16}")
                found += 1
                
    if found == 0:
        print("[!] No LTE USB modems detected.")
    print("="*65 + "\n")

def reset_modem_usb(targets):
    """
    Performs real-time hardware USB unbind/bind power-cycle on target LTE modems (lte11~lte20).
    """
    unbind_file = "/sys/bus/usb/drivers/usb/unbind"
    bind_file = "/sys/bus/usb/drivers/usb/bind"
    
    # 1. Discover all active LTE interfaces
    discovered = []
    for iface in sorted(os.listdir('/sys/class/net')):
        if iface == PRIMARY_IFACE or iface in ["lo", "tailscale0"]:
            continue
        if iface.startswith("lte") or iface.startswith("enx") or iface.startswith("usb"):
            usb_p = get_realtime_usb_port(iface)
            if usb_p:
                gw = get_gateway_ip(iface) or ""
                subnet = gw.split(".")[2] if "." in gw else (iface.replace("lte", "") if iface.startswith("lte") else "")
                discovered.append({
                    "iface": iface,
                    "subnet": subnet,
                    "usb_port": usb_p
                })
                
    if not discovered:
        print("[!] No LTE USB modem devices discovered via sysfs.")
        return False

    # 2. Filter targets
    to_reset = []
    if not targets or "all" in targets:
        to_reset = discovered
    else:
        norm_targets = set()
        for t in targets:
            norm_targets.add(t.lower())
            if t.isdigit():
                norm_targets.add(f"lte{t}")
            elif t.lower().startswith("lte"):
                norm_targets.add(t.lower().replace("lte", ""))
                
        for d in discovered:
            if d["iface"].lower() in norm_targets or d["subnet"] in norm_targets:
                to_reset.append(d)

    if not to_reset:
        print(f"[!] No matching LTE interfaces found for targets: {targets}")
        list_lte_usb_ports()
        return False

    print("\n" + "="*65)
    print(f" 🔄 Real-Time USB Hardware Unbind/Bind Reset (Targeting {len(to_reset)} modem(s))")
    print("="*65)

    for d in to_reset:
        iface = d["iface"]
        usb_p = d["usb_port"]
        print(f"[*] Targeting {iface} (Subnet: {d['subnet'] or 'N/A'}) -> Real-Time USB Port: {usb_p}")
        
        # Unbind
        print(f"    [-] Sending UNBIND to /sys/bus/usb/drivers/usb/unbind ({usb_p})...")
        res_un = subprocess.run(["sudo", "tee", unbind_file], input=usb_p.encode(),
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        if res_un.returncode != 0:
            print(f"    [!] Unbind error: {res_un.stderr.decode().strip()}")
        
        time.sleep(3)
        
        # Bind
        print(f"    [+] Sending BIND to /sys/bus/usb/drivers/usb/bind ({usb_p})...")
        res_bi = subprocess.run(["sudo", "tee", bind_file], input=usb_p.encode(),
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        if res_bi.returncode != 0:
            print(f"    [!] Bind error: {res_bi.stderr.decode().strip()}")
        else:
            print(f"    [✔] Hardware USB power-cycle completed on port {usb_p}.")

    print("\n[*] Waiting 6 seconds for USB devices to re-enumerate in kernel before repairing network...")
    time.sleep(6)
    return True

if __name__ == "__main__":
    args = sys.argv[1:]
    
    if "--help" in args or "-h" in args:
        print("\nUsage: fix_eth_number.sh [OPTIONS] [TARGETS...]")
        print("Checks and repairs LTE network interface names (lte11~lte20) and policy routing.")
        print("\nOptions:")
        print("  (no arguments)       Run normal interface naming & routing inspection and repair")
        print("  --list, -l           List detected LTE interfaces and dynamic USB ports")
        print("  --reset, -r [TARGET] Real-time USB unbind/bind hardware reset, followed by route repair")
        print("                       (TARGET: e.g. 11, lte12, '11 12', all)")
        print("\nExamples:")
        print("  sudo ./fix_eth_number.sh                 # Normal check & fix")
        print("  sudo ./fix_eth_number.sh --list          # View real-time USB port mapping")
        print("  sudo ./fix_eth_number.sh --reset 11      # Reset lte11 USB port & fix")
        print("  sudo ./fix_eth_number.sh --reset all     # Reset all LTE modems & fix\n")
        sys.exit(0)

    if "--list" in args or "-l" in args:
        list_lte_usb_ports()
        sys.exit(0)

    if "--reset" in args or "-r" in args or "--unbind" in args or "--unbind-bind" in args:
        # Extract targets after --reset
        reset_flags = {"--reset", "-r", "--unbind", "--unbind-bind"}
        targets = [a for a in args if a not in reset_flags]
        reset_modem_usb(targets)
        # Proceed with normal repair loop
        main()
        sys.exit(0)

    main()

