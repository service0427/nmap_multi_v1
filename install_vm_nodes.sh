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

# 3. Create 4 Virtual Machines (vnode-1 to vnode-4)
echo -e "${YELLOW}[3/4] Creating 4 Virtual Machines (Ubuntu 24.04)...${NC}"
for i in {1..4}; do
    VM_NAME="vnode-$i"
    
    if lxc info "$VM_NAME" &> /dev/null; then
        echo "   > $VM_NAME already exists. Skipping creation."
    else
        echo "   > Launching $VM_NAME..."
        # Launch as a full Virtual Machine
        lxc launch ubuntu:24.04 "$VM_NAME" --vm -c limits.cpu=2 -c limits.memory=2GiB
        
        # Share the project directory
        lxc config device add "$VM_NAME" project_disk disk source="$HOST_SHARE_DIR" path=/root/nmap_mini
        
        # Grant USB permissions inside the VM
        lxc config set "$VM_NAME" raw.apparmor "mount fstype=cgroup -> /sys/fs/cgroup/**,"
    fi
done

# 4. Generate USB Passthrough Template
PASSTHROUGH_SCRIPT="map_usb_devices.py"
echo -e "${YELLOW}[4/4] Generating USB Passthrough tool ($PASSTHROUGH_SCRIPT)...${NC}"
cat << 'EOF' > "$PASSTHROUGH_SCRIPT"
#!/usr/bin/env python3
import subprocess, re

print("🔌 USB Passthrough Mapping Tool")
print("Run this tool after connecting all phones and modems.")
print("This will assign devices to vnode-1 ~ vnode-4 based on adb list and lsusb.")

def run(cmd):
    try:
        return subprocess.getoutput(cmd)
    except:
        return ""

# 1. Get ADB Devices
adb_out = run("adb devices")
phones = [line.split()[0] for line in adb_out.split('\n') if 'device' in line and not line.startswith('List')]
print(f"Found {len(phones)} phones.")

# 2. Get Huawei Modems (12d1:14db)
usb_out = run("lsusb")
modems = []
for line in usb_out.split('\n'):
    if '12d1:14db' in line:
        parts = line.split()
        bus = parts[1]
        dev = parts[3].replace(':', '')
        modems.append((bus, dev))
print(f"Found {len(modems)} modems.")

# 3. Mapping Logic (5 phones + 1 modem per node)
for i in range(4):
    vnode = f"vnode-{i+1}"
    print(f"\n--- Assigning to {vnode} ---")
    
    # Assign Modem
    if i < len(modems):
        bus, dev = modems[i]
        run(f"lxc config device add {vnode} modem usb bus={bus} device={dev} required=false")
        print(f"📡 Assigned Modem (Bus {bus} Dev {dev})")
    
    # Assign Phones
    start_idx = i * 5
    for j in range(5):
        idx = start_idx + j
        if idx < len(phones):
            serial = phones[idx]
            run(f"lxc config device add {vnode} phone-{serial} usb serial={serial} required=false")
            print(f"📱 Assigned Phone {serial}")

print("\n✅ Hardware mapping complete! Devices are now isolated inside VMs.")
EOF
chmod +x "$PASSTHROUGH_SCRIPT"

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN} ✅ VM Infrastructure Prepared!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e " 1. VMs created: vnode-1, vnode-2, vnode-3, vnode-4"
echo -e " 2. Next Step: Connect all hardware to the new server."
echo -e " 3. Run: ${YELLOW}sudo python3 $PASSTHROUGH_SCRIPT${NC} to assign devices."
echo -e " 4. Then, log into each VM (e.g., lxc shell vnode-1) and run loop.sh."
echo -e "${GREEN}============================================================${NC}"
