#!/usr/bin/env bash
# LTE Multi-Proxy Infrastructure - VM Isolation Master Installer
# This script sets up LXD Virtual Machines dynamically based on manual ADB order.

set -e

NC="\e[0m"; GREEN="\e[1;32m"; RED="\e[1;31m"; YELLOW="\e[1;33m"; BLUE="\e[1;34m"
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}   🚀 LXD Sequential VM-Based Hardware Isolation Installer${NC}"
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

# 2. Setup Host Directory for Sharing (Dynamic Path)
HOST_SHARE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_NAME="$(basename "$HOST_SHARE_DIR")"
echo -e "${YELLOW}[2/3] Preparing host share directory: $HOST_SHARE_DIR...${NC}"

# 3. Generate and Execute the Sequential Orchestrator Script
PASSTHROUGH_SCRIPT="map_usb_devices.py"
echo -e "${YELLOW}[3/3] Launching Sequential Hardware Orchestrator...${NC}"
cat << EOF_OUTER > "$PASSTHROUGH_SCRIPT"
#!/usr/bin/env python3
import subprocess, sys

print("🔌 Sequential USB Passthrough & VM Orchestration Tool")

# --- [CONFIGURATION] ---
# 수동 배분 모드 (ADB 연결 순서대로 강제 배분)
# 예: [5, 5, 5, 5] -> vnode-11에 5대, vnode-12에 5대...
MANUAL_COUNTS = [5, 5, 5, 5]
START_VNODE_IDX = 11
HOST_DIR = "$HOST_SHARE_DIR"
PROJECT_NAME = "$PROJECT_NAME"

def run(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True).strip()
    except:
        return ""

# 1. Get ADB Devices
adb_out = run("adb devices")
phones = [line.split()[0] for line in adb_out.split('\n') if 'device' in line and not line.startswith('List')]
print(f"\n📱 Found {len(phones)} phones. Assigning sequentially...")

vnode_groups = {}
current_phone_idx = 0

for i, count in enumerate(MANUAL_COUNTS):
    vnode_idx = START_VNODE_IDX + i
    vnode_groups[vnode_idx] = []
    
    for _ in range(count):
        if current_phone_idx < len(phones):
            serial = phones[current_phone_idx]
            vnode_groups[vnode_idx].append(serial)
            print(f"   > Phone {serial} -> vnode-{vnode_idx}")
            current_phone_idx += 1

if not any(vnode_groups.values()):
    print("❌ No phones to assign. Exiting.")
    sys.exit(1)

# 2. Get Huawei Modems
usb_out = run("lsusb")
modems = []
for line in usb_out.split('\n'):
    if '12d1:14db' in line:
        parts = line.split()
        modems.append((parts[1], parts[3].replace(':', '')))
print(f"\n📡 Found {len(modems)} modems.")

# 3. Dynamically Create VMs & Assign Hardware
modem_counter = 0
for vnode_idx, phone_list in vnode_groups.items():
    if not phone_list:
        continue # Skip empty groups
        
    vnode = f"vnode-{vnode_idx}"
    print(f"\n--- Processing {vnode} ---")
    
    # Check/Create VM
    vm_exists = run(f"lxc info {vnode}")
    if "Error" in vm_exists or not vm_exists:
        print(f"   > Creating VM {vnode} (Ubuntu 26.04)...")
        run(f"lxc init ubuntu:26.04 {vnode} --vm -c limits.cpu=2 -c limits.memory=2GiB")
        run(f"lxc config device add {vnode} project_disk disk source={HOST_DIR} path=/root/{PROJECT_NAME}")
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

print("\n🎉 Sequential VM Creation & Hardware Mapping Complete!")
EOF_OUTER
chmod +x "$PASSTHROUGH_SCRIPT"

# Execute the mapping tool immediately
python3 "$PASSTHROUGH_SCRIPT"

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN} ✅ Sequential VM Infrastructure Ready!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e " 1. Log into each VM (e.g., lxc shell vnode-11)."
echo -e " 2. Navigate to /root/$PROJECT_NAME/wifi_multi."
echo -e " 3. Run ./loop.sh to start the isolated scheduler."
echo -e "${GREEN}============================================================${NC}"
