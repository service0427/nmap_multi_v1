#!/usr/bin/env python3
import json
import subprocess
import os
import sys
import time

def get_adb_status():
    res = subprocess.run(["adb", "devices"], capture_output=True, text=True)
    connected = []
    offline = []
    for line in res.stdout.strip().split("\n")[1:]:
        line = line.strip()
        if line and not line.startswith("*"):
            parts = line.split()
            if len(parts) >= 2:
                serial, status = parts[0], parts[1]
                connected.append(serial)
                if status == "offline" or status == "unauthorized":
                    offline.append(serial)
            elif len(parts) == 1:
                connected.append(parts[0])
    return connected, offline

def main():
    if os.geteuid() != 0:
        print("[🚨] Error: This script must be run with root privileges. Please use 'sudo'.")
        sys.exit(1)

    config_path = "/home/tech/nmap_multi_v1/wifi_multi/config/usb_ports.json"
    if not os.path.exists(config_path):
        print(f"[-] Config file not found at {config_path}")
        sys.exit(1)

    with open(config_path, "r") as f:
        usb_ports = json.load(f)

    connected, offline = get_adb_status()
    print(f"[*] Total configured devices: {len(usb_ports)}")
    print(f"[*] Currently seen devices via ADB: {len(connected)}")

    targets = []
    
    # 1. Identify missing devices (not in adb devices list at all)
    for serial in usb_ports:
        if serial not in connected:
            targets.append((serial, usb_ports[serial], "MISSING"))
            
    # 2. Identify offline/unauthorized devices
    for serial in offline:
        if serial in usb_ports:
            targets.append((serial, usb_ports[serial], "OFFLINE"))

    if not targets:
        print("[✓] All devices are connected and online! No recovery needed.")
        sys.exit(0)

    print(f"\n[⚠️] Found {len(targets)} device(s) requiring hardware recovery:")
    for serial, port, reason in targets:
        print(f"  - Serial: {serial} | USB Port: {port} | Reason: {reason}")

    # Reset USB ports
    unbind_file = "/sys/bus/usb/drivers/usb/unbind"
    bind_file = "/sys/bus/usb/drivers/usb/bind"

    print("\n[*] Commencing USB unbind/bind hardware recovery loop...")
    for serial, port, reason in targets:
        usb_path = port.replace("usb:", "")
        print(f"  -> Resetting USB port {usb_path} for device {serial} ({reason})...")
        
        # Unbind
        try:
            with open(unbind_file, "w") as f:
                f.write(usb_path)
            print(f"     [✓] Sent unbind to {usb_path}")
        except Exception as e:
            print(f"     [!] Unbind failed: {e}")

        # Wait for power down
        time.sleep(2)

        # Bind
        try:
            with open(bind_file, "w") as f:
                f.write(usb_path)
            print(f"     [✓] Sent bind to {usb_path}")
        except Exception as e:
            print(f"     [!] Bind failed: {e}")

    print("\n[✓] Hardware recovery completed. Please wait 5-10 seconds for the devices to initialize, then run 'adb devices'.")

if __name__ == "__main__":
    main()
