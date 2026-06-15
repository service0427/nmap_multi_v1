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

def fix_interface(iface):
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
        
    if iface == new_name:
        print(f"[*] Interface {iface} is already named correctly.")
        return True
        
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
    
    # Clean up default route from main table to prevent metric override
    subprocess.run(["sudo", "ip", "route", "del", "default", "dev", new_name], stderr=subprocess.DEVNULL)
    
    # 6. Setup Policy Routing
    table_id = subnet
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
    interfaces = os.listdir('/sys/class/net')
    os.makedirs('/etc/iproute2', exist_ok=True)
    
    fixed_any = False
    for iface in interfaces:
        if iface == PRIMARY_IFACE:
            continue
            
        # Match eth*, usb*, enx* that are NOT named correctly
        if re.match(r"^(eth\d+|usb\d+|enx\w+)", iface):
            if fix_interface(iface):
                fixed_any = True
                
    if not fixed_any:
        print("[*] No misnamed interfaces (eth*, usb*, enx*) detected.")

if __name__ == "__main__":
    main()
