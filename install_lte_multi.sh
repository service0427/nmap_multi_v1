#!/usr/bin/env bash
# LTE Multi-Proxy Infrastructure Master Installer (V1.1)
# Optimized for high-performance servers with multiple identical-MAC LTE modems.

set -e

NC="\e[0m"; GREEN="\e[1;32m"; RED="\e[1;31m"; YELLOW="\e[1;33m"; BLUE="\e[1;34m"
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}   🚀 LTE Multi-Proxy Infrastructure Master Installer${NC}"
echo -e "${BLUE}============================================================${NC}"

# 1. Root Check
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}❌ Please run as root (sudo bash install_lte_multi.sh)${NC}"
    exit 1
fi

# 2. Dependency Installation
echo -e "\n${YELLOW}[1/5] Installing essential packages...${NC}"
apt-get update -y > /dev/null
apt-get install -y adb jq python3-pip curl net-tools iproute2 isc-dhcp-client 2>/dev/null
pip3 install mitmproxy frida-tools --break-system-packages 2>/dev/null || pip3 install mitmproxy frida-tools

# 3. Kernel Optimization (ARP Hardening)
echo -e "${YELLOW}[2/5] Optimizing kernel for identical MAC devices...${NC}"
cat <<EOF > /etc/sysctl.d/99-lte-proxy.conf
net.ipv4.conf.all.arp_ignore=1
net.ipv4.conf.all.arp_announce=2
net.ipv4.conf.all.rp_filter=2
EOF
sysctl -p /etc/sysctl.d/99-lte-proxy.conf > /dev/null

# 4. Network Interface & Routing Setup
echo -e "${YELLOW}[3/5] Configuring network interfaces and PBR tables...${NC}"

# Identify Wired Interface
WIRED_IFACE=$(ip route show default | grep -v "lte" | awk '{print $5}' | head -n 1)
WIRED_GW=$(ip route show default dev "$WIRED_IFACE" | awk '{print $3}' | head -n 1)

if [ -n "$WIRED_IFACE" ]; then
    echo -e "   > Wired Interface: $WIRED_IFACE (Priority: 50)"
    ip route del default dev "$WIRED_IFACE" 2>/dev/null || true
    ip route add default via "$WIRED_GW" dev "$WIRED_IFACE" metric 50
fi

# Create the Power Sync Script
cat <<'EOF' > /usr/local/bin/lte-sync
#!/usr/bin/env python3
import os, subprocess, re, time

def run(cmd): return subprocess.getoutput(cmd)

# Wait for potential DHCP session
time.sleep(3)

interfaces = os.listdir('/sys/class/net')
for iface in interfaces:
    if iface in ['lo', 'tailscale0', 'lxdbr0'] or 'enp' in iface or 'veth' in iface: continue
    
    # Try to bring interface up
    subprocess.run(f"ip link set {iface} up", shell=True)
    
    addr_info = run(f"ip -4 addr show {iface}")
    match = re.search(r'inet 192\.168\.(\d+)\.', addr_info)
    
    if match:
        subnet = int(match.group(1))
        if 11 <= subnet <= 30: # Support up to 20 modems
            target = f"lte{subnet}"
            if iface != target:
                subprocess.run(f"ip link set {iface} down", shell=True)
                subprocess.run(f"ip link set {iface} name {target}", shell=True)
                subprocess.run(f"ip link set {target} up", shell=True)
                iface = target

            gw = f"192.168.{subnet}.1"
            table = 200 + subnet
            subprocess.run(f"ip route add default via {gw} dev {iface} metric {table} 2>/dev/null || true", shell=True)
            subprocess.run(f"ip rule add from 192.168.{subnet}.0/24 table {table} 2>/dev/null || true", shell=True)
            subprocess.run(f"ip route replace default via {gw} dev {iface} table {table}", shell=True)
            print(f"✅ {iface} Synced")
EOF
chmod +x /usr/local/bin/lte-sync

# Register Hotplug Rule
echo 'ACTION=="add", SUBSYSTEM=="net", KERNEL=="eth*|usb*", RUN+="/usr/local/bin/lte-sync"' > /etc/udev/rules.d/99-lte-auto-sync.rules
udevadm control --reload-rules

# Run first sync
/usr/local/bin/lte-sync

# 5. Directory & Permission Setup
echo -e "${YELLOW}[4/5] Setting up workspace permissions...${NC}"
mkdir -p wifi_multi/logs
chmod -R 775 wifi_multi/logs
chown -R $SUDO_USER:$SUDO_USER wifi_multi/ 2>/dev/null || true

# 6. Final Report
echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN} ✅ Installation Completed Successfully! (V1.1)${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e " 🌐 Default Route: $WIRED_IFACE (High Priority)"
echo -e " 📡 LTE Modems   : Auto-recognized as lte11 ~ lte30"
echo -e " 🛠️  Auto-Sync   : Enabled via udev rule"
echo -e " 📂 Workspace    : /home/tech/nmap_mini/wifi_multi"
echo -e "\n To start: ${YELLOW}cd wifi_multi && ./loop.sh${NC}"
echo -e "${GREEN}============================================================${NC}"
