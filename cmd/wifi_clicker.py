#!/usr/bin/env python3
import sys
import os
import subprocess
import xml.etree.ElementTree as ET

def handle_wifi_dialog(device_id):
    script_dir = os.path.dirname(os.path.abspath(__file__))
    dev_tmp_dir = os.path.join(script_dir, "..", "wifi_multi", "logs", device_id, "tmp")
    os.makedirs(dev_tmp_dir, exist_ok=True)
    temp_xml = os.path.join(dev_tmp_dir, f"wifi_ui_{device_id}.xml")
    
    try:
        # Dump UI XML to device, then pull it to isolated session directory
        subprocess.run(["adb", "-s", device_id, "shell", "uiautomator", "dump", "/sdcard/wifi_ui.xml"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        subprocess.run(["adb", "-s", device_id, "pull", "/sdcard/wifi_ui.xml", temp_xml], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    except Exception as e:
        # Silently fail if UI dump times out (e.g. if screen is off or during transition)
        return False

    if not os.path.exists(temp_xml):
        return False

    try:
        tree = ET.parse(temp_xml)
        root = tree.getroot()
    except Exception as e:
        return False
    finally:
        if os.path.exists(temp_xml):
            try:
                os.remove(temp_xml)
            except:
                pass

    # Targets for 'Keep connection' or 'Always allow' dialog buttons
    targets = [
        "항상 연결", "항상 허용", "연결 유지", 
        "Always connect", "Keep connection", "Yes", 
        "허용", "Allow", "확인"
    ]
    
    for node in root.iter():
        text = (node.get('text') or "").strip()
        desc = (node.get('content-desc') or "").strip()
        
        matched = False
        for target in targets:
            if target in text or target in desc:
                matched = True
                break
                
        if matched:
            bounds_str = node.get('bounds')
            if bounds_str:
                # Parse bounds format: [x1,y1][x2,y2]
                coords = [int(c) for c in bounds_str.replace('][', ',').replace('[', '').replace(']', '').split(',')]
                x1, y1, x2, y2 = coords
                cx = (x1 + x2) // 2
                cy = (y1 + y2) // 2
                print(f"[{device_id}] Detected prompt option '{text or desc}' on screen. Clicking center point ({cx}, {cy}).")
                subprocess.run(["adb", "-s", device_id, "shell", "input", "tap", str(cx), str(cy)], stdout=subprocess.DEVNULL)
                return True
                
    return False

if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(1)
    handle_wifi_dialog(sys.argv[1])
