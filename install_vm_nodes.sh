#!/usr/bin/env bash
# LTE Multi-Proxy Infrastructure - Dynamic VM Isolation Master Installer
# This script sets up LXD Virtual Machines dynamically based on connected Wi-Fi SSIDs.

set -e

NC="\e[0m"; GREEN="\e[1;32m"; RED="\e[1;31m"; YELLOW="\e[1;33m"; BLUE="\e[1;34m"
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}   🚀 LXD Dynamic VM-Based Hardware Isolation Installer${NC}"
echo -e "${BLUE}============================================================${NC}"

if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}❌ Please run as root (sudo bash install_vm_nodes.sh)${NC}"
    exit 1
fi

# 1. Install LXD if not present
echo -e "\n${YELLOW}[1/3] Installing and initializing LXD...${NC}"
if ! command -v lxc &> /dev/null; then
    snap install lxd
    lxd init --auto
else
    echo "LXD is already installed."
fi

# 2. Setup Host Directory for Sharing
HOST_SHARE_DIR="/home/$SUDO_USER/nmap_mini"
echo -e "${YELLOW}[2/3] Preparing host share directory: $HOST_SHARE_DIR...${NC}"
mkdir -p "$HOST_SHARE_DIR"

# 3. Generate and Execute the Dynamic Orchestrator Script
PASSTHROUGH_SCRIPT="map_usb_devices.py"
echo -e "${YELLOW}[3/3] Launching Dynamic Hardware Orchestrator...${NC}"
cat << 'EOF' > "$PASSTHROUGH_SCRIPT"
#!/usr/bin/env python3
import subprocess, re, sys

print("🔌 Smart USB Passthrough & VM Orchestration Tool")

def run(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True).strip()
    except:
        return ""

def get_ssid_index(dev_id):
    out = run(f"adb -s {dev_id} shell dumpsys netstats 2>/dev/null | grep -E 'iface=wlan0'")
    match = re.search(r'networkId="([^"]+)"', out)
    if not match:
        out = run(f"adb -s {dev_id} shell cmd wifi status 2>/dev/null")
        match = re.search(r'SSID: "([^"]+)"', out)
    
    if match:
        ssid = match.group(1)
        idx_match = re.search(r'([0-9]+)$', ssid)
        if idx_match:
            return str(int(idx_match.group(1)))
    return None

# 1. Scan Phones & Extract SSIDs
adb_out = run("adb devices")
phones = [line.split()[0] for line in adb_out.split('\n') if 'device' in line and not line.startswith('List')]
print(f"\n📱 Found {len(phones)} phones. Analyzing connected Wi-Fi networks...")

vnode_groups = {}
for serial in phones:
    idx = get_ssid_index(serial)
    if idx:
        if idx not in vnode_groups:
            vnode_groups[idx] = []
        vnode_groups[idx].append(serial)
        print(f"   > Phone {serial} -> Wi-Fi Index [{idx}]")
    else:
        print(f"   > Phone {serial} -> Unrecognized SSID. Skipping.")

if not vnode_groups:
    print("❌ No valid Wi-Fi groups detected. Exiting.")
    sys.exit(1)

# 2. Get Modems
usb_out = run("lsusb")
modems = []
for line in usb_out.split('\n'):
    if '12d1:14db' in line:
        parts = line.split()
        modems.append((parts[1], parts[3].replace(':', '')))
print(f"\n📡 Found {len(modems)} modems.")

# 3. Dynamically Create VMs & Assign Hardware
host_dir = run("echo /home/$SUDO_USER/nmap_mini")
if not host_dir or "SUDO_USER" in host_dir:
    host_dir = "/home/tech/nmap_mini" # Fallback

modem_counter = 0
for idx, phone_list in vnode_groups.items():
    vnode = f"vnode-{idx}"
    print(f"\n--- Processing {vnode} ---")
    
    # Check/Create VM
    vm_exists = run(f"lxc info {vnode}")
    if "Error" in vm_exists or not vm_exists:
        print(f"   > Creating VM {vnode} (Ubuntu 26.04)...")
        run(f"lxc init ubuntu:26.04 {vnode} --vm -c limits.cpu=2 -c limits.memory=2GiB")
        run(f"lxc config device add {vnode} project_disk disk source={host_dir} path=/root/nmap_mini")
        run(f"lxc config set {vnode} raw.apparmor \"mount fstype=cgroup -> /sys/fs/cgroup/**,\"")
        run(f"lxc start {vnode}")
        print(f"   ✅ VM {vnode} Started.")
    else:
        print(f"   ✅ VM {vnode} already exists.")
    
    # Assign Modem
    if modem_counter < len(modems):
        bus, dev = modems[modem_counter]
        run(f"lxc config device remove {vnode} modem 2>/dev/null") # cleanup old
        run(f"lxc config device add {vnode} modem usb bus={bus} device={dev} required=false")
        print(f"   ✅ Assigned Modem (Bus {bus} Dev {dev})")
        modem_counter += 1
    else:
        print(f"   ⚠️ No free modems left for {vnode}!")
    
    # Assign Phones
    for serial in phone_list:
        run(f"lxc config device remove {vnode} phone-{serial} 2>/dev/null") # cleanup old
        run(f"lxc config device add {vnode} phone-{serial} usb serial={serial} required=false")
        print(f"   ✅ Assigned Phone {serial}")

print("\n🎉 Dynamic VM Creation & Hardware Mapping Complete!")
EOF
chmod +x "$PASSTHROUGH_SCRIPT"

# Execute the mapping tool immediately
python3 "$PASSTHROUGH_SCRIPT"

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN} ✅ Dynamic VM Infrastructure Ready!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e " 1. Log into each VM (e.g., lxc shell vnode-11)."
echo -e " 2. Navigate to /root/nmap_mini/wifi_multi."
echo -e " 3. Run ./loop.sh to start the isolated scheduler."
echo -e "${GREEN}============================================================${NC}"
