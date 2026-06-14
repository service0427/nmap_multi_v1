#!/bin/bash
# LTE Multi-Proxy Infrastructure Master Installer (V1.2 - Dynamic Server Ready)
echo -e "\033[0;34m   🚀 LTE Multi-Proxy Infrastructure Master Installer\033[0m"

if [ "$EUID" -ne 0 ]; then
  echo -e "\033[1;33m[!] Please run as root (sudo ./install_lte_multi.sh)\033[0m"
  exit 1
fi

# 1. Install Dependencies
echo -e "\033[1;33m[1/6] Installing core dependencies...\033[0m"
apt-get update > /dev/null
apt-get install -y adb jq python3-pip curl net-tools iproute2 isc-dhcp-client network-manager 2>/dev/null
pip3 install mitmproxy frida-tools --break-system-packages 2>/dev/null || pip3 install mitmproxy frida-tools

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
cat << EOF > /etc/systemd/resolved.conf
[Resolve]
DNS=8.8.8.8 8.8.4.4
FallbackDNS=1.1.1.1 1.0.0.1
Domains=~.
EOF
mkdir -p /etc/NetworkManager/conf.d
cat << EOF > /etc/NetworkManager/conf.d/dns.conf
[main]
dns=systemd-resolved
EOF
systemctl restart systemd-resolved
systemctl restart NetworkManager
sleep 3

# 4. Dynamic Primary Interface Detection
echo -e "\033[1;33m[4/6] Dynamically detecting primary wired interface...\033[0m"
# Find the active, physical ethernet connection managed by NetworkManager
WIRED_IFACE=$(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null | grep ethernet | grep connected | cut -d: -f1 | head -n 1)

# Fallback if nmcli fails
if [ -z "$WIRED_IFACE" ]; then
    WIRED_IFACE=$(ip route show default | grep -vE "lte|usb|enx" | awk '{print $5}' | head -n 1)
fi
WIRED_GW=$(ip route show default dev "$WIRED_IFACE" 2>/dev/null | awk '{print $3}' | head -n 1)

if [ -n "$WIRED_IFACE" ]; then
    echo -e "   > Primary Wired Interface detected: $WIRED_IFACE"
    NM_CONN=$(nmcli -t -f NAME,DEVICE connection show active 2>/dev/null | grep ":$WIRED_IFACE$" | cut -d: -f1 || true)
    if [ -n "$NM_CONN" ]; then
        nmcli connection modify "$NM_CONN" ipv4.route-metric 50 2>/dev/null || true
        nmcli connection up "$NM_CONN" 2>/dev/null || true
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
        subprocess.run(["dhclient", "-v", iface], timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        res = subprocess.check_output(f"ip -4 route show dev {iface}", shell=True).decode()
        for line in res.split("\n"):
            if "link" in line and "src" in line:
                return line.split()[0].replace("/24", ".1")
    except: return None

def main():
    interfaces = os.listdir("/sys/class/net")
    for iface in interfaces:
        # 안전장치: 메인 유선망은 절대 건드리지 않음
        if iface == PRIMARY_IFACE:
            continue
            
        if re.match(r"^(enx|usb|eth\d+)", iface):
            gw = get_gateway_ip(iface)
            if not gw: continue
            
            try:
                subnet = gw.split(".")[2]
                new_name = f"lte{subnet}"
            except: continue
            
            print(f"Renaming {iface} to {new_name}")
            subprocess.run(["ip", "link", "set", iface, "down"])
            subprocess.run(["ip", "link", "set", iface, "name", new_name])
            subprocess.run(["ip", "link", "set", new_name, "up"])
            
            subprocess.run(["dhclient", "-v", new_name], timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            
            table_id = subnet
            subprocess.run(f"grep -q \"^{table_id} lte{table_id}\" /etc/iproute2/rt_tables || echo \"{table_id} lte{table_id}\" >> /etc/iproute2/rt_tables", shell=True)
            subprocess.run(["ip", "route", "flush", "table", str(table_id)])
            subprocess.run(["ip", "route", "add", "default", "via", gw, "dev", new_name, "table", str(table_id)])
            
            ip_out = subprocess.check_output(f"ip -4 addr show {new_name} | grep inet", shell=True).decode()
            if "inet" in ip_out:
                local_ip = ip_out.split()[1].split("/")[0]
                subprocess.run(["ip", "rule", "del", "from", local_ip, "table", str(table_id)], stderr=subprocess.DEVNULL)
                subprocess.run(["ip", "rule", "add", "from", local_ip, "table", str(table_id)])
            print(f"✅ {new_name} Synced and Isolated")

if __name__ == "__main__":
    time.sleep(2)
    main()
EOF
chmod +x /usr/local/bin/lte-sync

# 6. Apply Udev Rules
echo -e "\033[1;33m[6/6] Applying Udev rules and starting isolation...\033[0m"
echo 'ACTION=="add", SUBSYSTEM=="net", KERNEL=="eth*|usb*|enx*", RUN+="/usr/local/bin/lte-sync"' > /etc/udev/rules.d/99-lte-auto-sync.rules
udevadm control --reload-rules
udevadm trigger

# Sync any already plugged in devices
/usr/local/bin/lte-sync

echo -e "\n============================================================"
echo -e "\033[0;32m ✅ Dynamic Installation Completed Successfully! (V1.2)\033[0m"
echo -e "============================================================"
echo -e " 🌐 Primary Route: $WIRED_IFACE (Protected, Metric 50)"
echo -e " 🛡️  DNS Status   : Locked to 8.8.8.8 (Tailscale safe)"
echo -e " 📡 LTE Modems   : Auto-recognized as lte11 ~ lte30"
echo -e "============================================================"
