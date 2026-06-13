#!/usr/bin/env python3
import subprocess, sys

print("🔌 Sequential USB Passthrough & VM Orchestration Tool")

# --- [CONFIGURATION] ---
# 수동 배분 모드 (ADB 연결 순서대로 강제 배분)
# 예: [5, 5, 5, 5] -> vnode-11에 5대, vnode-12에 5대...
MANUAL_COUNTS = [5, 5, 5, 5]
START_VNODE_IDX = 11

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

# 3. Assign Hardware to VMs
modem_counter = 0
for vnode_idx, phone_list in vnode_groups.items():
    if not phone_list:
        continue # Skip empty groups
        
    vnode = f"vnode-{vnode_idx}"
    print(f"\n--- Processing {vnode} ---")
    
    # Check if VM exists
    vm_exists = run(f"lxc info {vnode}")
    if "Error" in vm_exists or not vm_exists:
        print(f"   ❌ VM {vnode} does not exist. Please run install_vm_nodes.sh first.")
        continue
    
    # Assign Modem (Using vendorid/productid to bypass VM bus error)
    run(f"lxc config device remove {vnode} modem 2>/dev/null") # cleanup old
    # Huawei modems share 12d1:14db. We pass the class of device.
    run(f"lxc config device add {vnode} modem usb vendorid=12d1 productid=14db required=false")
    print(f"   ✅ Assigned Huawei Modem (12d1:14db)")
    modem_counter += 1
    
    # Assign Phones
    for serial in phone_list:
        run(f"lxc config device remove {vnode} phone-{serial} 2>/dev/null") # cleanup old
        run(f"lxc config device add {vnode} phone-{serial} usb serial={serial} required=false")
        print(f"   ✅ Assigned Phone {serial}")

print("\n🎉 Sequential Hardware Mapping Complete!")
