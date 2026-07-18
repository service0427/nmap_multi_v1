#!/usr/bin/env python3
import socket
import re
import subprocess
import json
import xml.etree.ElementTree as ET
import urllib.request
import urllib.error
import sys
import time
import os

def load_config():
    config = {
        "API_SERVER": "114.207.112.245:8013"
    }
    script_dir = os.path.dirname(os.path.abspath(__file__))
    config_path = os.path.join(os.path.dirname(script_dir), "wifi_multi", "config.conf")
    if os.path.exists(config_path):
        try:
            with open(config_path, "r") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    match = re.match(r'^(\w+)\s*=\s*["\']?(.*?)["\']?$', line)
                    if match:
                        key, val = match.group(1), match.group(2)
                        config[key] = val
        except Exception:
            pass
    return config

_config = load_config()
API_SERVER = _config.get("API_SERVER", "114.207.112.245:8013")
API_URL = f"http://{API_SERVER}/api/v1/lte_usage"

def get_lte_interfaces():
    """Find all active lte interfaces and their subnets."""
    interfaces = []
    try:
        output = subprocess.check_output(["ip", "-br", "addr", "show"]).decode()
        for line in output.splitlines():
            parts = line.split()
            if not parts:
                continue
            name = parts[0]
            # Match lte11, lte12, etc.
            match = re.match(r'^lte(\d+)$', name)
            if match:
                subnet = int(match.group(1))
                interfaces.append((name, subnet))
    except Exception as e:
        print(f"Error listing interfaces: {e}")
    return sorted(interfaces)

def get_interface_ip(interface):
    """Get the IPv4 address of a network interface."""
    try:
        output = subprocess.check_output(f"ip -4 addr show {interface}", shell=True).decode()
        match = re.search(r'inet\s+(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})', output)
        if match:
            return match.group(1)
    except Exception:
        pass
    return "0.0.0.0"

def get_modem_traffic(subnet):
    """Query the Huawei modem for traffic statistics."""
    modem_ip = f"192.168.{subnet}.1"
    
    # 1. Get Session & Token
    sestok_url = f"http://{modem_ip}/api/webserver/SesTokInfo"
    try:
        req = urllib.request.Request(sestok_url, method="GET")
        with urllib.request.urlopen(req, timeout=5) as response:
            xml_data = response.read()
            root = ET.fromstring(xml_data)
            ses_info = root.findtext("SesInfo")
            tok_info = root.findtext("TokInfo")
    except Exception:
        return None
        
    if not ses_info or not tok_info:
        return None
        
    # 2. Get Traffic Statistics
    stats_url = f"http://{modem_ip}/api/monitoring/traffic-statistics"
    try:
        headers = {
            "Cookie": f"SessionID={ses_info}",
            "__RequestVerificationToken": tok_info
        }
        req = urllib.request.Request(stats_url, headers=headers, method="GET")
        with urllib.request.urlopen(req, timeout=5) as response:
            xml_data = response.read()
            root = ET.fromstring(xml_data)
            
            total_upload = root.findtext("TotalUpload")
            total_download = root.findtext("TotalDownload")
            
            return {
                "upload": int(total_upload) if total_upload else 0,
                "download": int(total_download) if total_download else 0
            }
    except Exception:
        return None

def send_usage(name, upload_mb, download_mb, ip_addr):
    """Send LTE usage data to the API server."""
    payload = {
        "name": name,
        "upload": upload_mb,
        "download": download_mb,
        "ip": ip_addr
    }
    
    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(API_URL, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    
    try:
        with urllib.request.urlopen(req, timeout=5) as response:
            res_body = response.read().decode('utf-8')
            return True, res_body
    except Exception as e:
        return False, str(e)

# Global tracker for consecutive failure count per interface
failure_counts = {}

def get_usb_port(interface):
    """Find the USB port name (e.g. 1-2.3) for the given interface using sysfs."""
    try:
        dev_path = os.path.realpath(f"/sys/class/net/{interface}/device")
        parts = dev_path.split('/')
        for part in reversed(parts):
            if re.match(r'^\d+-\d+(\.\d+)*$', part):
                return part
    except Exception as e:
        print(f"[RECOVERY] Error getting USB port for {interface}: {e}")
    return None

def recover_modem(interface):
    """Attempt self-healing recovery for a frozen/dead LTE modem."""
    print(f"[RECOVERY] 🚨 {interface} has failed for 10 minutes consecutively! Attempting self-healing...")
    
    usb_port = get_usb_port(interface)
    if not usb_port:
        print(f"[RECOVERY] Could not find USB port for {interface}. Skipping physical reset.")
        return
        
    print(f"[RECOVERY] Target USB port identified: {usb_port}. Attempting single-port unbind/bind...")
    
    # 1. Unbind single port
    subprocess.run(f"echo '{usb_port}' | sudo tee /sys/bus/usb/drivers/usb/unbind", shell=True, stdout=subprocess.DEVNULL)
    time.sleep(3)
    
    # 2. Bind single port
    res = subprocess.run(f"echo '{usb_port}' | sudo tee /sys/bus/usb/drivers/usb/bind", shell=True, capture_output=True, text=True)
    
    # 3. If bind failed, fallback to USB host controller (PCI) reset
    if res.returncode != 0 or "No such device" in res.stderr:
        print(f"[RECOVERY] ⚠️ Single port bind failed (os error). Attempting USB controller level reset...")
        try:
            dev_path = os.path.realpath(f"/sys/class/net/{interface}/device")
            pci_match = re.search(r'0000:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]', dev_path)
            if pci_match:
                pci_addr = pci_match.group(0)
                print(f"[RECOVERY] Resetting PCI Host Controller: {pci_addr}...")
                subprocess.run(f"echo '{pci_addr}' | sudo tee /sys/bus/pci/drivers/xhci_hcd/unbind", shell=True, stdout=subprocess.DEVNULL)
                time.sleep(3)
                subprocess.run(f"echo '{pci_addr}' | sudo tee /sys/bus/pci/drivers/xhci_hcd/bind", shell=True, stdout=subprocess.DEVNULL)
                time.sleep(5)
                
                # Trigger udevadm
                subprocess.run(["sudo", "udevadm", "trigger"])
                print(f"[RECOVERY] PCI Controller reset and udevadm trigger completed.")
                time.sleep(8)
        except Exception as e:
            print(f"[RECOVERY] Fallback PCI reset failed: {e}")
    else:
        print(f"[RECOVERY] Single port unbind/bind command executed successfully.")
        time.sleep(5)
        
    # 4. Run dynamic lte-sync in a loop to restore interface names and routing
    print(f"[RECOVERY] Running lte-sync to restore interface routing and names (3 attempts)...")
    for attempt in range(3):
        time.sleep(5)  # Wait for kernel to initialize device and DHCP lease
        try:
            print(f"[RECOVERY] lte-sync Attempt {attempt+1}/3...")
            subprocess.run(["sudo", "/usr/local/bin/lte-sync"], timeout=30)
        except Exception as e:
            print(f"[RECOVERY] Failed to run lte-sync: {e}")

def run_once():
    hostname = socket.gethostname()
    interfaces = get_lte_interfaces()
    
    print(f"=== Sending LTE usage to {API_URL} ===")
    
    for name, subnet in interfaces:
        stats = get_modem_traffic(subnet)
        if stats:
            failure_counts[name] = 0
            
            upload_raw = stats["upload"]
            download_raw = stats["download"]
            combined_name = f"{hostname}_{name}"
            ip_addr = get_interface_ip(name)
            
            success, message = send_usage(combined_name, upload_raw, download_raw, ip_addr)
            status_str = "SUCCESS" if success else "FAILED"
            print(f"[{status_str}] {combined_name} ({ip_addr}) -> Upload: {upload_raw} Bytes, Download: {download_raw} Bytes | Response: {message}")
        else:
            failure_counts[name] = failure_counts.get(name, 0) + 1
            cur_fails = failure_counts[name]
            print(f"[ERROR] {name} -> Could not fetch traffic data (modem offline or unreachable) | Consec Fails: {cur_fails}/10")
            
            if cur_fails >= 10:
                failure_counts[name] = 0
                recover_modem(name)

def main():
    daemon_mode = "--daemon" in sys.argv or "-d" in sys.argv
    
    if daemon_mode:
        print(f"Starting LTE Usage Sender in daemon mode (looping every 60 seconds)...")
        while True:
            try:
                run_once()
            except Exception as e:
                print(f"Error in daemon run: {e}")
            time.sleep(60)
    else:
        run_once()

if __name__ == "__main__":
    main()
