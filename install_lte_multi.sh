#!/bin/bash
# LTE Multi-Proxy Infrastructure Master Installer (V1.2 - Dynamic Server Ready)
echo -e "\033[0;34m   🚀 LTE Multi-Proxy Infrastructure Master Installer\033[0m"

if [ "$EUID" -ne 0 ]; then
  echo -e "\033[1;31m[❌] Error: This script must be run with sudo or as root. Exiting...\033[0m"
  exit 1
fi

# 1. Install Dependencies
if ! command -v adb >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v mitmdump >/dev/null 2>&1 || ! command -v frida >/dev/null 2>&1 || ! command -v lsof >/dev/null 2>&1; then
    echo -e "\033[1;33m[1/6] Installing core dependencies...\033[0m"
    apt-get update > /dev/null
    apt-get install -y adb jq python3-pip curl net-tools iproute2 isc-dhcp-client network-manager lsof 2>/dev/null
    pip3 install mitmproxy frida-tools --break-system-packages 2>/dev/null || pip3 install mitmproxy frida-tools
else
    echo -e "\033[1;32m[1/6] Core dependencies already installed. Skipping apt/pip updates.\033[0m"
fi

# 1.5. Legacy Clean Up to Prevent Conflicts on Older Servers
echo -e "\033[1;33m[1.5/6] Cleaning up legacy network & udev configs to prevent routing collisions...\033[0m"

# A. Clean legacy udev rules
for rule in /etc/udev/rules.d/70-persistent-net.rules /etc/udev/rules.d/99-lte-proxy.rules; do
    if [ -f "$rule" ]; then
        echo -e "   > Removing conflicting legacy udev rule: $rule"
        rm -f "$rule"
    fi
done

# B. Clean legacy Netplan yaml files that hardcode LTE interfaces
if [ -d "/etc/netplan" ]; then
    for yaml in /etc/netplan/*.yaml /etc/netplan/*.yml; do
        [ -f "$yaml" ] || continue
        if [ "$(basename "$yaml")" != "00-installer-config.yaml" ]; then
            if grep -qE "lte|enx001e101f0000" "$yaml" 2>/dev/null; then
                echo -e "   > Removing conflicting legacy Netplan file: $yaml"
                rm -f "$yaml"
            fi
        fi
    done
fi

# C. Clean legacy table entries in rt_tables
if [ -f "/etc/iproute2/rt_tables" ]; then
    if grep -q "lte" /etc/iproute2/rt_tables 2>/dev/null; then
        echo -e "   > Removing legacy 'lte' routing tables from /etc/iproute2/rt_tables..."
        sed -i '/lte/d' /etc/iproute2/rt_tables
    fi
fi

# D. Apply udev control reload to enforce cleanup immediately
udevadm control --reload-rules 2>/dev/null || true


# 2. Kernel Tuning
echo -e "\033[1;33m[2/6] Optimizing kernel for identical MAC devices...\033[0m"
cat <<EOF > /etc/sysctl.d/99-lte-proxy.conf
net.ipv4.conf.all.arp_ignore=1
net.ipv4.conf.all.arp_announce=2
net.ipv4.conf.all.rp_filter=2
EOF
sysctl -p /etc/sysctl.d/99-lte-proxy.conf > /dev/null

# 3. DNS Blackhole Prevention (Tailscale Survival)
echo -e "\033[1;33m[3/6] Locking Global DNS to prevent Tailscale drops...\033[0m"
DNS_NEEDS_RESTART=0
if [ ! -f /etc/systemd/resolved.conf ] || ! grep -q "DNS=8.8.8.8 8.8.4.4" /etc/systemd/resolved.conf; then
    cat << EOF > /etc/systemd/resolved.conf
[Resolve]
DNS=8.8.8.8 8.8.4.4
FallbackDNS=1.1.1.1 1.0.0.1
Domains=~.
EOF
    DNS_NEEDS_RESTART=1
fi

mkdir -p /etc/NetworkManager/conf.d
if [ ! -f /etc/NetworkManager/conf.d/dns.conf ] || ! grep -q "dns=systemd-resolved" /etc/NetworkManager/conf.d/dns.conf; then
    cat << EOF > /etc/NetworkManager/conf.d/dns.conf
[main]
dns=systemd-resolved
EOF
    DNS_NEEDS_RESTART=1
fi

if [ "$DNS_NEEDS_RESTART" -eq 1 ]; then
    echo -e "   > Applying new DNS configurations and restarting NetworkManager..."
    systemctl restart systemd-resolved
    systemctl restart NetworkManager
    sleep 3
else
    echo -e "   > DNS configuration already locked. Skipping NetworkManager restart."
fi

# 4. Dynamic Primary Interface Detection
echo -e "\033[1;33m[4/6] Dynamically detecting primary wired interface...\033[0m"
# Find the active, physical ethernet connection managed by NetworkManager
WIRED_IFACE=$(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null | grep ethernet | grep connected | cut -d: -f1 | head -n 1)

# Fallback 1: Look at the default route in the routing table (excluding lte, usb, enx)
if [ -z "$WIRED_IFACE" ]; then
    WIRED_IFACE=$(ip route show default | grep -vE "lte|usb|enx" | awk '{print $5}' | head -n 1)
fi

# Fallback 2: Look for any active enp/eth/eno interface that is UP and has an IP address
if [ -z "$WIRED_IFACE" ]; then
    WIRED_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -E "^(enp|eth|eno|enx)" | grep -vE "lte|usb" | while read -r iface; do
        if ip -4 addr show dev "$iface" | grep -q "inet"; then
            echo "$iface"
            break
        fi
    done)
fi

# Fallback 3: Just find any interface starting with enp/eth/eno that exists (excluding lte, usb)
if [ -z "$WIRED_IFACE" ]; then
    WIRED_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -E "^(enp|eth|eno)" | grep -vE "lte|usb" | head -n 1)
fi

WIRED_GW=$(ip route show default dev "$WIRED_IFACE" 2>/dev/null | awk '{print $3}' | head -n 1)

if [ -n "$WIRED_IFACE" ]; then
    echo -e "   > Primary Wired Interface detected: $WIRED_IFACE"
    NM_CONN=$(nmcli -t -f NAME,DEVICE connection show active 2>/dev/null | grep ":$WIRED_IFACE$" | cut -d: -f1 || true)
    if [ -n "$NM_CONN" ]; then
        nmcli connection modify "$NM_CONN" ipv4.route-metric 100 2>/dev/null || true
        nmcli connection up "$NM_CONN" 2>/dev/null || true
    fi
    
    # Netplan Configuration
    WIRED_MAC=$(cat /sys/class/net/"$WIRED_IFACE"/address 2>/dev/null)
    if [ -d "/etc/netplan" ] && [ -n "$WIRED_MAC" ]; then
        echo -e "   > Configuring Netplan for $WIRED_IFACE ($WIRED_MAC) with metric 100..."
        cat << EOF > /etc/netplan/00-installer-config.yaml
# Generated by install_lte_multi.sh
network:
  version: 2
  renderer: networkd
  ethernets:
    $WIRED_IFACE:
      dhcp4: true
      dhcp6: true
      match:
        macaddress: $WIRED_MAC
      set-name: $WIRED_IFACE
      dhcp4-overrides:
        route-metric: 100
      dhcp6-overrides:
        route-metric: 100
    enx001e101f0000:
      dhcp4: true
      dhcp6: true
      match:
        macaddress: 00:1e:10:1f:00:00
      set-name: enx001e101f0000
      dhcp4-overrides:
        route-metric: 100
      dhcp6-overrides:
        route-metric: 100
EOF
        netplan apply 2>/dev/null || true
    fi
else
    echo -e "\033[1;31m[!] Could not detect primary wired interface. Proceeding with caution.\033[0m"
    WIRED_IFACE="UNKNOWN_IFACE"
fi

# 5. Create the Safe Power Sync Script
echo -e "\033[1;33m[5/6] Generating dynamic lte-sync daemon...\033[0m"
cat <<EOF > /usr/local/bin/lte-sync
#!/usr/bin/env python3
import os, subprocess, re, time

PRIMARY_IFACE = "$WIRED_IFACE"

def get_gateway_ip(iface):
    try:
        res = subprocess.check_output(f"ip -4 route show dev {iface}", shell=True).decode()
        # 1. Look for default route first
        match_default = re.search(r'default via (\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})', res)
        if match_default:
            return match_default.group(1)
        # 2. Look for subnet route (e.g. 192.168.14.0/24)
        for line in res.splitlines():
            if '/' in line:
                network_part = line.split()[0].split('/')[0]
                gateway = network_part.rsplit('.', 1)[0] + '.1'
                return gateway
    except Exception:
        pass

    try:
        # 3. If no route, run dhclient
        subprocess.run(["dhclient", "-v", iface], timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        res = subprocess.check_output(f"ip -4 route show dev {iface}", shell=True).decode()
        match_default = re.search(r'default via (\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})', res)
        if match_default:
            return match_default.group(1)
        for line in res.splitlines():
            if '/' in line:
                network_part = line.split()[0].split('/')[0]
                gateway = network_part.rsplit('.', 1)[0] + '.1'
                return gateway
    except Exception:
        pass
    return None

def main():
    interfaces = os.listdir('/sys/class/net')
    # Ensure iproute2 directory exists
    os.makedirs('/etc/iproute2', exist_ok=True)
    for iface in interfaces:
        # 안전장치: 메인 유선망은 절대 건드리지 않음
        if iface == PRIMARY_IFACE:
            continue
            
        mac = ""
        try:
            with open(f'/sys/class/net/{iface}/address', 'r') as f:
                mac = f.read().strip().lower()
        except:
            pass
        if mac == "00:1e:10:1f:00:00" or re.match(r"^(enx|usb|eth\d+|lte\d+|z_\w+)", iface):
            # Ensure the interface is UP before getting gateway
            try:
                operstate = ""
                if os.path.exists(f"/sys/class/net/{iface}/operstate"):
                    with open(f"/sys/class/net/{iface}/operstate", "r") as f:
                        operstate = f.read().strip().lower()
                if operstate == "down":
                    print(f"Bringing up {iface}...")
                    subprocess.run(["ip", "link", "set", iface, "up"])
                    time.sleep(2)
            except Exception as e:
                print(f"Error bringing up {iface}: {e}")

            gw = get_gateway_ip(iface)
            if not gw: continue
            
            try:
                subnet = gw.split(".")[2]
                new_name = f"lte{subnet}"
            except: continue
            
            if iface != new_name:
                if os.path.exists(f"/sys/class/net/{new_name}"):
                    tmp_name = f"tmp_{new_name}"
                    counter = 1
                    while os.path.exists(f"/sys/class/net/{tmp_name}"):
                        tmp_name = f"tmp_{new_name}_{counter}"
                        counter += 1
                    print(f"Collision! Renaming existing {new_name} -> {tmp_name}")
                    subprocess.run(["ip", "link", "set", new_name, "down"])
                    subprocess.run(["ip", "link", "set", new_name, "name", tmp_name])
                    subprocess.run(["ip", "link", "set", tmp_name, "up"])
                    time.sleep(1)

                print(f"Renaming {iface} to {new_name}")
                subprocess.run(["ip", "link", "set", iface, "down"])
                subprocess.run(["ip", "link", "set", iface, "name", new_name])
                subprocess.run(["ip", "link", "set", new_name, "up"])
            
            # Kill existing dhclient processes for this interface to avoid duplicates
            try:
                pgrep_out = subprocess.check_output(f"pgrep -f 'dhclient.*{new_name}'", shell=True).decode().strip()
                if pgrep_out:
                    for pid in pgrep_out.split():
                        subprocess.run(["kill", "-9", pid])
            except:
                pass
            # Clean up all existing IP addresses to prevent secondary IP accumulation
            subprocess.run(["ip", "addr", "flush", "dev", new_name])
            subprocess.run(["dhclient", "-v", new_name], timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            
            table_id = subnet
            subprocess.run(f"grep -q \"^{table_id} lte{table_id}\" /etc/iproute2/rt_tables || echo \"{table_id} lte{table_id}\" >> /etc/iproute2/rt_tables", shell=True)
            subprocess.run(["ip", "route", "flush", "table", str(table_id)])
            subprocess.run(["ip", "route", "add", "default", "via", gw, "dev", new_name, "table", str(table_id)])
            
            # Add fallback default route to main table with metric (100 + subnet)
            subprocess.run(["ip", "route", "del", "default", "dev", new_name], stderr=subprocess.DEVNULL)
            metric_val = 100 + int(table_id)
            subprocess.run(["ip", "route", "add", "default", "via", gw, "dev", new_name, "metric", str(metric_val)], stderr=subprocess.DEVNULL)
            
            ip_out = subprocess.check_output(f"ip -4 addr show {new_name} | grep inet", shell=True).decode()
            if 'inet' in ip_out:
                local_ip = ip_out.split()[1].split('/')[0]
                subprocess.run(["ip", "rule", "del", "from", local_ip, "table", str(table_id)], stderr=subprocess.DEVNULL)
                subprocess.run(["ip", "rule", "add", "from", local_ip, "table", str(table_id)])
            # Ensure NAT (Masquerade) rule exists for this interface to share internet to devices
            try:
                subprocess.run(f"iptables -t nat -C POSTROUTING -o {new_name} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o {new_name} -j MASQUERADE", shell=True)
            except Exception as e:
                print(f"Error setting up NAT for {new_name}: {e}")
            print(f"✅ {new_name} Synced and Isolated")

if __name__ == "__main__":
    time.sleep(2)
    main()
EOF
chmod +x /usr/local/bin/lte-sync

# 6. Apply Udev Rules & Systemd Reboot Service
echo -e "\033[1;33m[6/6] Applying Udev rules and Systemd service...\033[0m"
echo 'ACTION=="add", SUBSYSTEM=="net", KERNEL=="eth*|usb*|enx*", RUN+="/usr/local/bin/lte-sync"' > /etc/udev/rules.d/99-lte-auto-sync.rules
echo 'ACTION=="add", SUBSYSTEM=="net", ATTR{address}=="00:1e:10:1f:00:00", RUN+="/usr/local/bin/lte-sync"' >> /etc/udev/rules.d/99-lte-auto-sync.rules
udevadm control --reload-rules
udevadm trigger

# Create systemd service for boot reliability
cat << EOF > /etc/systemd/system/lte-sync.service
[Unit]
Description=LTE Multi-Proxy Routing Sync Service
After=network-online.target NetworkManager.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/lte-sync
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable lte-sync.service

# Sync any already plugged in devices
/usr/local/bin/lte-sync

echo -e "\n============================================================"
echo -e "\033[0;32m ✅ Dynamic Installation Completed Successfully! (V1.2)\033[0m"
echo -e "============================================================"
echo -e " 🌐 Primary Route: $WIRED_IFACE (Protected, Metric 100)"
echo -e " 🛡️  DNS Status   : Locked to 8.8.8.8 (Tailscale safe)"
echo -e " 📡 LTE Modems   : Auto-recognized as lte11 ~ lte30"
echo -e "============================================================"
