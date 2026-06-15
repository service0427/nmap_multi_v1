#!/usr/bin/env python3
import os
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
    gw = get_gateway_ip(iface)
    if not gw:
        # Try running dhclient once to get an IP/gateway
        print(f"[*] Interface {iface} has no IP/route. Requesting lease...")
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
                
            # Match eth*, usb*, enx*, lte*, and tmp_*
            if re.match(r"^(eth\d+|usb\d+|enx\w+|lte\d+|tmp_\w+)", iface):
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
    misnamed = [i for i in interfaces if re.match(r"^(eth\d+|usb\d+|enx\w+|tmp_\w+)", i) and i != PRIMARY_IFACE]
    if misnamed:
        print(f"[!] Some interfaces could not be fully resolved: {misnamed}")
    else:
        print("[*] All interfaces are named correctly and routing is valid.")

if __name__ == "__main__":
    main()
