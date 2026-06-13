#!/usr/bin/env bash
# LTE Multi-Proxy Infrastructure - VM Isolation Master Installer
# This script sets up LXD Virtual Machines.
# Usage: sudo bash install_vm_nodes.sh [NUMBER_OF_VMS] (Default is 4)

set -e

NC="\e[0m"; GREEN="\e[1;32m"; RED="\e[1;31m"; YELLOW="\e[1;33m"; BLUE="\e[1;34m"
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}   🚀 LXD VM-Based Hardware Isolation Installer${NC}"
echo -e "${BLUE}============================================================${NC}"

if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}❌ Please run as root (sudo bash install_vm_nodes.sh)${NC}"
    exit 1
fi

VM_COUNT=${1:-4}
START_IDX=11
END_IDX=$((START_IDX + VM_COUNT - 1))

echo -e "⚙️ Configuration: Creating ${VM_COUNT} VMs (vnode-${START_IDX} to vnode-${END_IDX})"

# 1. Install LXD if not present
echo -e "\n${YELLOW}[1/3] Installing and initializing LXD...${NC}"
if ! command -v lxc &> /dev/null; then
    snap install lxd
    lxd init --auto
else
    echo "LXD is already installed."
fi

# 2. Setup Host Directory for Sharing
HOST_SHARE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_NAME="$(basename "$HOST_SHARE_DIR")"
echo -e "${YELLOW}[2/3] Preparing host share directory: $HOST_SHARE_DIR...${NC}"

# 3. Create Virtual Machines
echo -e "${YELLOW}[3/3] Creating Virtual Machines (Ubuntu 26.04)...${NC}"
for (( i=$START_IDX; i<=$END_IDX; i++ )); do
    VM_NAME="vnode-$i"
    
    if lxc info "$VM_NAME" &> /dev/null; then
        echo "   > $VM_NAME already exists. Skipping creation."
    else
        echo "   > Initializing $VM_NAME..."
        lxc init ubuntu:26.04 "$VM_NAME" --vm -c limits.cpu=2 -c limits.memory=2GiB
        lxc config device add "$VM_NAME" project_disk disk source="$HOST_SHARE_DIR" path="/root/$PROJECT_NAME"
        lxc config set "$VM_NAME" raw.apparmor "mount fstype=cgroup -> /sys/fs/cgroup/**,"
        echo "   > Starting $VM_NAME..."
        lxc start "$VM_NAME"
    fi
done

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN} ✅ VM Infrastructure Prepared!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e " 1. VMs created: vnode-${START_IDX} ~ vnode-${END_IDX}"
echo -e " 2. Next Step: Edit and run ${YELLOW}sudo python3 map_usb_devices.py${NC} to assign devices."
echo -e "${GREEN}============================================================${NC}"
