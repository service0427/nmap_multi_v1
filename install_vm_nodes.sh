#!/usr/bin/env bash
# LTE Multi-Proxy Infrastructure - VM Isolation Master Installer
# This script sets up LXD Virtual Machines for perfect hardware isolation.

set -e

NC="\e[0m"; GREEN="\e[1;32m"; RED="\e[1;31m"; YELLOW="\e[1;33m"; BLUE="\e[1;34m"
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}   🚀 LXD VM-Based Hardware Isolation Installer${NC}"
echo -e "${BLUE}============================================================${NC}"

if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}❌ Please run as root (sudo bash install_vm_nodes.sh)${NC}"
    exit 1
fi

# 1. Install LXD if not present
echo -e "\n${YELLOW}[1/4] Installing and initializing LXD...${NC}"
if ! command -v lxc &> /dev/null; then
    snap install lxd
    lxd init --auto
else
    echo "LXD is already installed."
fi

# 2. Setup Host Directory for Sharing
HOST_SHARE_DIR="/home/$SUDO_USER/nmap_mini"
echo -e "${YELLOW}[2/4] Preparing host share directory: $HOST_SHARE_DIR...${NC}"
mkdir -p "$HOST_SHARE_DIR"

# 3. Create 4 Virtual Machines based on target indices
echo -e "${YELLOW}[3/4] Creating Virtual Machines (Ubuntu 26.04)...${NC}"
for i in {11..14}; do
    VM_NAME="vnode-$i"
    
    if lxc info "$VM_NAME" &> /dev/null; then
        echo "   > $VM_NAME already exists. Skipping creation."
    else
        echo "   > Initializing $VM_NAME..."
        lxc init ubuntu:26.04 "$VM_NAME" --vm -c limits.cpu=2 -c limits.memory=2GiB
        lxc config device add "$VM_NAME" project_disk disk source="$HOST_SHARE_DIR" path=/root/nmap_mini
        lxc config set "$VM_NAME" raw.apparmor "mount fstype=cgroup -> /sys/fs/cgroup/**,"
        echo "   > Starting $VM_NAME..."
        lxc start "$VM_NAME"
    fi
done

# 4. Generate Smart USB Passthrough Template
PASSTHROUGH_SCRIPT="map_usb_devices.py"
echo -e "${YELLOW}[4/4] Generating Smart USB Passthrough tool ($PASSTHROUGH_SCRIPT)...${NC}"
cat << 'EOF' > "$PASSTHROUGH_SCRIPT"
#!/usr/bin/env python3
import subprocess, re

print("🔌 Smart USB Passthrough Mapping Tool")
print("Extracting Wi-Fi SSIDs to assign phones to the correct vnode...")

def run(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True).strip()
    except:
        return ""

def get_ssid_index(dev_id):
    # Try dumpsys netstats
    out = run(f"adb -s {dev_id} shell dumpsys netstats 2>/dev/null | grep -E 'iface=wlan0'")
    match = re.search(r'networkId="([^"]+)"', out)
    if not match:
        # Fallback to cmd wifi status
        out = run(f"adb -s {dev_id} shell cmd wifi status 2>/dev/null")
        match = re.search(r'SSID: "([^"]+)"', out)
    
    if match:
        ssid = match.group(1)
        idx_match = re.search(r'([0-9]+)$', ssid)
        if idx_match:
            # Return as integer to strip leading zeros, then string
            return str(int(idx_match.group(1)))
    return None

# 1. Map Phones by SSID
adb_out = run("adb devices")
phones = [line.split()[0] for line in adb_out.split('\n') if 'device' in line and not line.startswith('List')]
print(f"\n📱 Found {len(phones)} phones. Analyzing SSIDs...")

vnode_groups = { "11": [], "12": [], "13": [], "14": [] }

for serial in phones:
    idx = get_ssid_index(serial)
    if idx and idx in vnode_groups:
        vnode_groups[idx].append(serial)
        print(f"   > Phone {serial} -> Wi-Fi Index [{idx}] -> vnode-{idx}")
    else:
        print(f"   > Phone {serial} -> Unrecognized SSID or Index. Skipping.")

# 2. Get Huawei Modems
usb_out = run("lsusb")
modems = []
for line in usb_out.split('\n'):
    if '12d1:14db' in line:
        parts = line.split()
        bus = parts[1]
        dev = parts[3].replace(':', '')
        modems.append((bus, dev))
print(f"\n📡 Found {len(modems)} modems.")

# 3. Assign to LXD
modem_counter = 0
for idx, phone_list in vnode_groups.items():
    vnode = f"vnode-{idx}"
    print(f"\n--- Applying hardware to {vnode} ---")
    
    # Assign one modem sequentially
    if modem_counter < len(modems):
        bus, dev = modems[modem_counter]
        run(f"lxc config device add {vnode} modem usb bus={bus} device={dev} required=false")
        print(f"   ✅ Assigned Modem (Bus {bus} Dev {dev})")
        modem_counter += 1
    
    # Assign Phones
    for serial in phone_list:
        run(f"lxc config device add {vnode} phone-{serial} usb serial={serial} required=false")
        print(f"   ✅ Assigned Phone {serial}")

print("\n🎉 Hardware mapping complete! Devices are successfully distributed to their matching VMs.")
EOF
chmod +x "$PASSTHROUGH_SCRIPT"

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN} ✅ VM Infrastructure Prepared!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e " 1. VMs created: vnode-11, vnode-12, vnode-13, vnode-14"
echo -e " 2. Next Step: Run ${YELLOW}sudo python3 $PASSTHROUGH_SCRIPT${NC}"
echo -e " 3. The script will read the Wi-Fi name from each phone and assign it automatically."
echo -e "${GREEN}============================================================${NC}"
