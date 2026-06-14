#!/usr/bin/env python3
import os
import sys
import time
import json
import re
import subprocess
import urllib.request
import urllib.parse
import xml.etree.ElementTree as ET
import random
from datetime import datetime

# Configuration
CHECK_INTERVAL = 300  # Check every 5 minutes
MIN_ROTATION_MINUTES = 120  # 2 hours
MAX_ROTATION_MINUTES = 180  # 3 hours
PROJECT_ROOT = "/home/tech/nmap_mini"
STATE_FILE = os.path.join(PROJECT_ROOT, "wifi_multi", "logs", "lte_rotator_state.json")

def log(msg):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] {msg}")
    sys.stdout.flush()

def get_lte_interfaces():
    interfaces = []
    try:
        for name in os.listdir('/sys/class/net'):
            addr_file = f"/sys/class/net/{name}/address"
            if os.path.exists(addr_file):
                with open(addr_file, 'r') as f:
                    mac = f.read().strip()
                if mac.startswith("00:1e:10"):
                    subnet = None
                    if name.startswith("lte") and name[3:].isdigit():
                        subnet = int(name[3:])
                    else:
                        addr_info = subprocess.getoutput(f"ip -4 addr show {name}")
                        match = re.search(r'inet 192\.168\.(\d+)\.', addr_info)
                        if match:
                            subnet = int(match.group(1))
                    
                    if subnet and 11 <= subnet <= 20:
                        interfaces.append((name, subnet))
    except Exception as e:
        log(f"Error listing interfaces: {e}")
    return sorted(interfaces)

def get_modem_token(modem_ip):
    url = f"http://{modem_ip}/api/webserver/SesTokInfo"
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=5) as response:
            xml_data = response.read()
            root = ET.fromstring(xml_data)
            return root.findtext("SesInfo"), root.findtext("TokInfo")
    except Exception:
        return None, None

def modem_toggle_network(subnet):
    modem_ip = f"192.168.{subnet}.1"
    ses, tok = get_modem_token(modem_ip)
    if not ses or not tok:
        log(f"[{subnet}] Failed to get token for toggle")
        return False

    headers = {
        "Cookie": f"SessionID={ses}",
        "__RequestVerificationToken": tok,
        "Content-Type": "application/xml"
    }

    # Method 1: Mobile Data Switch (Disconnect -> Connect)
    try:
        log(f"[{subnet}] Attempting Mobile Data Toggle...")
        # Disconnect
        off_xml = '<?xml version="1.0" encoding="UTF-8"?><request><dataswitch>0</dataswitch></request>'
        req = urllib.request.Request(f"http://{modem_ip}/api/dialup/mobile-dataswitch", data=off_xml.encode(), headers=headers, method="POST")
        urllib.request.urlopen(req, timeout=5).read()
        time.sleep(3)
        
        # Connect
        on_xml = '<?xml version="1.0" encoding="UTF-8"?><request><dataswitch>1</dataswitch></request>'
        req = urllib.request.Request(f"http://{modem_ip}/api/dialup/mobile-dataswitch", data=on_xml.encode(), headers=headers, method="POST")
        urllib.request.urlopen(req, timeout=5).read()
        log(f"[{subnet}] Mobile Data Toggled.")
        return True
    except Exception as e:
        log(f"[{subnet}] Mobile Data Toggle failed: {e}. Falling back to Network Mode Toggle.")

    # Method 2: Network Mode Toggle (Auto -> LTE Only) - Fallback
    try:
        # Step 1: Switch to Auto (00)
        auto_xml = '<?xml version="1.0" encoding="UTF-8"?><request><NetworkMode>00</NetworkMode><NetworkBand>3FFFFFFF</NetworkBand><LTEBand>7FFFFFFFFFFFFFFF</LTEBand></request>'
        req = urllib.request.Request(f"http://{modem_ip}/api/net/net-mode", data=auto_xml.encode(), headers=headers, method="POST")
        urllib.request.urlopen(req, timeout=5).read()
        log(f"[{subnet}] Switched to Auto mode")
        time.sleep(5)
        
        # Step 2: Switch back to LTE Only (03)
        lte_xml = '<?xml version="1.0" encoding="UTF-8"?><request><NetworkMode>03</NetworkMode><NetworkBand>3FFFFFFF</NetworkBand><LTEBand>7FFFFFFFFFFFFFFF</LTEBand></request>'
        req = urllib.request.Request(f"http://{modem_ip}/api/net/net-mode", data=lte_xml.encode(), headers=headers, method="POST")
        urllib.request.urlopen(req, timeout=5).read()
        log(f"[{subnet}] Switched back to LTE Only mode")
        return True
    except Exception as e:
        log(f"[{subnet}] Network Mode Toggle failed: {e}")
        return False

def reboot_modem(subnet):
    modem_ip = f"192.168.{subnet}.1"
    ses, tok = get_modem_token(modem_ip)
    if not ses or not tok:
        log(f"[{subnet}] Failed to get token for reboot")
        return False

    headers = {
        "Cookie": f"SessionID={ses}",
        "__RequestVerificationToken": tok,
        "Content-Type": "application/xml"
    }

    try:
        log(f"[{subnet}] Sending API reboot command to http://{modem_ip}/api/device/reboot ...")
        reboot_xml = '<?xml version="1.0" encoding="UTF-8"?><request><Control>1</Control></request>'
        req = urllib.request.Request(f"http://{modem_ip}/api/device/reboot", data=reboot_xml.encode(), headers=headers, method="POST")
        urllib.request.urlopen(req, timeout=5).read()
        log(f"[{subnet}] Reboot command sent successfully. Waiting 45s for boot...")
        time.sleep(45)
        return True
    except Exception as e:
        log(f"[{subnet}] Reboot command failed: {e}")
        return False

def get_public_ip(interface):
    try:
        output = subprocess.check_output([
            "curl", "--interface", interface, "-s", "-m", "10", "https://api.ipify.org"
        ], stderr=subprocess.DEVNULL).decode().strip()
        if re.match(r'^\d+\.\d+\.\d+\.\d+$', output):
            return output
    except:
        pass
    return None

def usb_reset(interface):
    try:
        # Find USB device ID
        usb_id = subprocess.check_output(f"readlink -f /sys/class/net/{interface}/device | xargs basename", shell=True).decode().strip()
        if not usb_id: return False
        
        log(f"[{interface}] Resetting USB device {usb_id}...")
        
        # Unbind
        subprocess.run(f"echo '{usb_id}' | sudo tee /sys/bus/usb/drivers/cdc_ether/unbind", shell=True, check=True, capture_output=True)
        time.sleep(2)
        # Bind
        subprocess.run(f"echo '{usb_id}' | sudo tee /sys/bus/usb/drivers/cdc_ether/bind", shell=True, check=True, capture_output=True)
        
        log(f"[{interface}] USB Reset complete. Waiting 15s for re-initialization...")
        time.sleep(15)
        return True
    except Exception as e:
        log(f"[{interface}] USB Reset failed: {e}")
        return False

def recover_interface(name, subnet):
    log(f"[{name}] Starting recovery sequence...")
    
    # 1. Force Link Up
    subprocess.run(["sudo", "ip", "link", "set", name, "up"])
    time.sleep(2)
    
    # 2. Run Surgical Setup
    log(f"[{name}] Running lte_surgical_setup.sh...")
    subprocess.run(["sudo", "bash", f"{PROJECT_ROOT}/utils/lte_surgical_setup.sh"])
    time.sleep(5)
    
    # 3. Check connectivity
    if get_public_ip(name):
        log(f"[{name}] Recovery Step 2 (Surgical Setup) Succeeded!")
        return True
        
    # 4. USB Reset
    if usb_reset(name):
        log(f"[{name}] USB Reset done, running surgical setup again...")
        subprocess.run(["sudo", "bash", f"{PROJECT_ROOT}/utils/lte_surgical_setup.sh"])
        time.sleep(10)
        if get_public_ip(name):
            log(f"[{name}] Recovery Step 4 (USB Reset) Succeeded!")
            return True

    # 5. Dongle API Reboot
    log(f"[{name}] USB Reset did not restore connectivity. Trying API reboot...")
    if reboot_modem(subnet):
        log(f"[{name}] API Reboot triggered, running surgical setup again...")
        subprocess.run(["sudo", "bash", f"{PROJECT_ROOT}/utils/lte_surgical_setup.sh"])
        time.sleep(15)
        if get_public_ip(name):
            log(f"[{name}] Recovery Step 5 (Dongle API Reboot) Succeeded!")
            return True
            
    log(f"[{name}] All recovery steps failed.")
    return False

def load_state():
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, 'r') as f:
                return json.load(f)
        except:
            pass
    return {}

def save_state(state):
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        with open(STATE_FILE, 'w') as f:
            json.dump(state, f)
    except Exception as e:
        log(f"Error saving state: {e}")

def get_next_rotation_ts():
    """Pick a random interval between 120 and 180 minutes."""
    minutes = random.randint(MIN_ROTATION_MINUTES, MAX_ROTATION_MINUTES)
    return time.time() + (minutes * 60)

def run_rotation():
    state = load_state()
    interfaces = get_lte_interfaces()
    
    for name, subnet in interfaces:
        next_rotate = state.get(name, 0)
        now_ts = time.time()
        
        # Check if rotation is needed
        if now_ts >= next_rotate:
            log(f"[{name}] Starting scheduled IP rotation...")
            old_ip = get_public_ip(name)
            log(f"[{name}] Current IP: {old_ip}")
            
            success = modem_toggle_network(subnet)
            if success:
                log(f"[{name}] Waiting for reconnection...")
                new_ip = None
                for _ in range(30): # Wait up to 60 seconds
                    time.sleep(2)
                    new_ip = get_public_ip(name)
                    if new_ip: break
                
                if new_ip and new_ip != old_ip:
                    log(f"[{name}] Rotation Success! New IP: {new_ip}")
                elif new_ip == old_ip:
                    log(f"[{name}] IP did not change after toggle. Attempting recovery sequence...")
                    recover_interface(name, subnet)
                else:
                    log(f"[{name}] Failed to get IP after toggle. Attempting recovery...")
                    recover_interface(name, subnet)
                
                state[name] = get_next_rotation_ts()
                next_dt = datetime.fromtimestamp(state[name]).strftime("%Y-%m-%d %H:%M:%S")
                log(f"[{name}] Next rotation scheduled at {next_dt}")
            else:
                log(f"[{name}] Toggle command failed. Attempting recovery...")
                if recover_interface(name, subnet):
                    state[name] = get_next_rotation_ts()
        else:
            # Not yet time for rotation, but check health
            if not get_public_ip(name):
                log(f"[{name}] Interface appears offline during health check. Recovering...")
                recover_interface(name, subnet)
                
    save_state(state)

def main():
    log("LTE IP Rotator started (Randomized Interval: 120-180m)")
    # Force initial PBR routing table configuration
    subprocess.run(["sudo", "bash", f"{PROJECT_ROOT}/utils/lte_surgical_setup.sh"])
    while True:
        try:
            run_rotation()
        except Exception as e:
            log(f"Error in main loop: {e}")
        time.sleep(CHECK_INTERVAL)

if __name__ == "__main__":
    main()
