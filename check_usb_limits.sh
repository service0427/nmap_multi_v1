#!/usr/bin/env python3
import os
import sys
import subprocess

# ANSI Colors for premium terminal output
RED = "\033[1;91m"
GREEN = "\033[1;92m"
YELLOW = "\033[1;93m"
BLUE = "\033[1;94m"
CYAN = "\033[1;96m"
BOLD = "\033[1m"
RESET = "\033[0m"

def check_root():
    if os.geteuid() != 0:
        print(f"{RED}Error: This script must be run as root to access xHCI debug statistics.{RESET}")
        print(f"Please run: {BOLD}sudo {sys.argv[0]}{RESET}")
        sys.exit(1)

def get_pci_info(pci_addr):
    try:
        output = subprocess.check_output(["lspci", "-s", pci_addr]).decode().strip()
        if output.startswith(pci_addr):
            output = output[len(pci_addr):].lstrip(": ")
        return output
    except Exception:
        return "Unknown USB Controller"

def read_file(path):
    try:
        with open(path, 'r') as f:
            return f.read().strip()
    except Exception:
        return ""

def parse_reg_cap(path):
    hcsparams1 = None
    if os.path.exists(path):
        content = read_file(path)
        for line in content.splitlines():
            if line.startswith("HCSPARAMS1"):
                parts = line.split("=")
                if len(parts) == 2:
                    val_str = parts[1].strip()
                    try:
                        hcsparams1 = int(val_str, 16)
                    except ValueError:
                        pass
    if hcsparams1 is not None:
        max_slots = hcsparams1 & 0xFF
        max_intrs = (hcsparams1 >> 8) & 0x7FF
        max_ports = (hcsparams1 >> 24) & 0xFF
        return max_slots, max_ports
    return None, None

def get_adb_serials():
    try:
        output = subprocess.check_output(["adb", "devices"]).decode().strip()
        serials = []
        for line in output.splitlines():
            if "device" in line and not line.startswith("List"):
                parts = line.split()
                if parts:
                    serials.append(parts[0])
        return set(serials)
    except Exception:
        return set()

def get_sys_usb_info(usb_path, adb_serials):
    sys_dir = f"/sys/bus/usb/devices/{usb_path}"
    if not os.path.exists(sys_dir):
        return {}
    
    vendor = read_file(f"{sys_dir}/idVendor")
    product_id = read_file(f"{sys_dir}/idProduct")
    product_name = read_file(f"{sys_dir}/product")
    manufacturer = read_file(f"{sys_dir}/manufacturer")
    speed = read_file(f"{sys_dir}/speed")
    serial = read_file(f"{sys_dir}/serial")
    dev_class = read_file(f"{sys_dir}/bDeviceClass")
    
    # Classify device type
    dev_type = "Device"
    if dev_class == "09":
        dev_type = "USB Hub"
    elif serial in adb_serials:
        dev_type = "ADB Phone"
    elif vendor == "12d1" and product_id == "14db":
        dev_type = "LTE Modem"
        
    return {
        "vendor": vendor,
        "product_id": product_id,
        "product_name": product_name,
        "manufacturer": manufacturer,
        "speed": speed,
        "serial": serial,
        "type": dev_type
    }

def main():
    check_root()
    
    xhci_debug_dir = "/sys/kernel/debug/usb/xhci"
    if not os.path.exists(xhci_debug_dir):
        # Try to mount debugfs
        print(f"{YELLOW}Warning: Debugfs not mounted. Attempting to mount...{RESET}")
        try:
            subprocess.check_call(["mount", "-t", "debugfs", "none", "/sys/kernel/debug"])
        except Exception as e:
            print(f"{RED}Error: Failed to mount debugfs ({e}). Please mount it manually:{RESET}")
            print(f"  sudo mount -t debugfs none /sys/kernel/debug")
            sys.exit(1)
            
    if not os.path.exists(xhci_debug_dir):
        print(f"{RED}Error: xHCI debug directory {xhci_debug_dir} still not found.{RESET}")
        sys.exit(1)
        
    adb_serials = get_adb_serials()
    
    print(f"\n{BOLD}{CYAN}========================================================================{RESET}")
    print(f"{BOLD}{CYAN}               PCIe / USB xHCI Limits & Usage Dashboard                 {RESET}")
    print(f"{BOLD}{CYAN}========================================================================{RESET}")
    
    controllers = [d for d in os.listdir(xhci_debug_dir) if os.path.isdir(os.path.join(xhci_debug_dir, d))]
    controllers.sort()
    
    # First: summary section
    print(f"\n{BOLD}📊 Controller Summary Status{RESET}")
    print("-" * 92)
    print(f"{'PCI Address':<12} | {'Slots Used / Limit':<22} | {'Usage %':<10} | {'Endpoints':<10} | {'Status':<12}")
    print("-" * 92)
    
    ctrl_data = {}
    
    for ctrl in controllers:
        ctrl_path = os.path.join(xhci_debug_dir, ctrl)
        reg_cap_path = os.path.join(ctrl_path, "reg-cap")
        max_slots, max_ports = parse_reg_cap(reg_cap_path)
        
        devices_dir = os.path.join(ctrl_path, "devices")
        if not os.path.exists(devices_dir):
            continue
            
        slots = [s for s in os.listdir(devices_dir) if os.path.isdir(os.path.join(devices_dir, s))]
        total_slots = len(slots)
        
        total_endpoints = 0
        device_details = []
        
        # Count endpoints and details
        for slot in sorted(slots, key=lambda x: int(x) if x.isdigit() else 999):
            slot_path = os.path.join(devices_dir, slot)
            name_file = os.path.join(slot_path, "name")
            usb_path = read_file(name_file)
            
            ep_dirs = [e for e in os.listdir(slot_path) if e.startswith("ep") and os.path.isdir(os.path.join(slot_path, e))]
            ep_count = len(ep_dirs)
            total_endpoints += ep_count
            
            usb_info = get_sys_usb_info(usb_path, adb_serials) if usb_path else {}
            device_details.append({
                "slot": slot,
                "usb_path": usb_path,
                "ep_count": ep_count,
                "info": usb_info
            })
            
        pct = (total_slots / max_slots * 100) if max_slots else 0
        
        if pct >= 90:
            status_color = RED
            status_txt = "CRITICAL"
        elif pct >= 75:
            status_color = YELLOW
            status_txt = "WARNING"
        else:
            status_color = GREEN
            status_txt = "OK"
            
        slots_str = f"{total_slots} / {max_slots if max_slots else 'N/A'}"
        pct_str = f"{pct:.1f}%"
        
        print(f"{BLUE}{ctrl:<12}{RESET} | {slots_str:<22} | {status_color}{pct_str:<10}{RESET} | {total_endpoints:<10} | {status_color}{status_txt:<12}{RESET}")
        
        ctrl_data[ctrl] = {
            "pci_desc": get_pci_info(ctrl),
            "slots_str": slots_str,
            "pct_str": pct_str,
            "status_color": status_color,
            "total_endpoints": total_endpoints,
            "devices": device_details
        }
    print("-" * 92)
    
    # Second: details section
    for ctrl in sorted(ctrl_data.keys()):
        data = ctrl_data[ctrl]
        print(f"\n\n{BOLD}🔌 Details for Controller {BLUE}{ctrl}{RESET} ({data['pci_desc']})")
        print(f"   Slot Usage: {data['status_color']}{data['slots_str']} ({data['pct_str']}){RESET} | Configured Endpoints: {BOLD}{data['total_endpoints']}{RESET}")
        
        if not data["devices"]:
            print("   (No devices connected)")
            continue
            
        print("   " + "-" * 108)
        print(f"   {'Slot':<5} | {'USB Path':<12} | {'EPs':<4} | {'Speed':<6} | {'Vendor:Prod':<12} | {'Type':<12} | {'Device Name / Description'}")
        print("   " + "-" * 108)
        
        for dev in data["devices"]:
            info = dev["info"]
            v_p = f"{info.get('vendor', '')}:{info.get('product_id', '')}" if info else "N/A"
            speed = f"{info.get('speed', '')}M" if info.get('speed') else "N/A"
            dev_type = info.get('type', 'Device')
            
            # Formulate description
            desc = ""
            if info:
                manuf = info.get('manufacturer', '')
                prod = info.get('product_name', '')
                serial = info.get('serial', '')
                
                parts = []
                if manuf: parts.append(manuf)
                if prod: parts.append(prod)
                desc = " ".join(parts)
                if serial:
                    desc += f" (S/N: {serial})"
            
            # Apply color to Device Type
            type_color = RESET
            if dev_type == "ADB Phone":
                type_color = GREEN
            elif dev_type == "USB Hub":
                type_color = CYAN
            elif dev_type == "LTE Modem":
                type_color = BLUE
                
            print(f"   {dev['slot']:<5} | {dev['usb_path']:<12} | {dev['ep_count']:<4} | {speed:<6} | {v_p:<12} | {type_color}{dev_type:<12}{RESET} | {desc}")
            
        print("   " + "-" * 108)
        
        # Give explicit advice if near limit
        limit_slots = int(data['slots_str'].split(' / ')[1]) if ' / ' in data['slots_str'] else 0
        used_slots = int(data['slots_str'].split(' / ')[0])
        
        if limit_slots and (limit_slots - used_slots) <= 10:
            print(f"\n   ⚠️  {YELLOW}Warning: Only {limit_slots - used_slots} slots left on this controller!{RESET}")
            print(f"      Connecting more USB hubs or phones to ports on this controller will cause connection failure.")
            print(f"      Please connect new devices to another controller or install PCIe USB cards with dedicated controllers.")

    print(f"\n{BOLD}{CYAN}========================================================================{RESET}\n")

if __name__ == '__main__':
    main()
