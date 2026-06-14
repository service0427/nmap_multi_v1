import subprocess
import xml.etree.ElementTree as ET
from xml.dom import minidom
import random
import time
import os
import sys
import json

def save_multiline_xml(tree_root, file_path):
    """Saves XML tree as a pretty-printed, multiline file"""
    rough_string = ET.tostring(tree_root, 'utf-8')
    reparsed = minidom.parseString(rough_string)
    with open(file_path, "w", encoding="utf-8") as f:
        f.write(reparsed.toprettyxml(indent="  "))

def get_ui_dump_pair(device_id, category_name):
    """Captures Screenshot and Multiline XML strictly into the session log folder"""
    log_dir = os.environ.get("CAPTURE_LOG_DIR")
    if not log_dir or not os.path.exists(log_dir):
        print(f" [!] FATAL ERROR: Session log directory missing")
        return None, None

    target_dir = os.path.join(log_dir, "screenshot", category_name)
    os.makedirs(target_dir, exist_ok=True)
    
    timestamp = time.strftime("%H%M%S")
    xml_file = os.path.join(target_dir, f"capture_{device_id}_{timestamp}.xml")
    png_file = os.path.join(target_dir, f"capture_{device_id}_{timestamp}.png")
    
    try:
        # 기기별 격리된 tmp 폴더 경로 확보
        root_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        dev_tmp_dir = os.path.join(root_dir, "logs", device_id, "tmp")
        os.makedirs(dev_tmp_dir, exist_ok=True)
        
        # [V2.5] Added timeout to prevent infinite hang of uiautomator dump
        subprocess.run(["adb", "-s", device_id, "shell", "uiautomator", "dump", "/sdcard/ui.xml"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=15)
        temp_xml = os.path.join(dev_tmp_dir, f"raw_{device_id}.xml")
        subprocess.run(["adb", "-s", device_id, "pull", "/sdcard/ui.xml", temp_xml], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=10)
        tree = ET.parse(temp_xml)
        save_multiline_xml(tree.getroot(), xml_file)
        os.remove(temp_xml)
        subprocess.run(["adb", "-s", device_id, "shell", "screencap", "-p", "/sdcard/screen.png"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=10)
        subprocess.run(["adb", "-s", device_id, "pull", "/sdcard/screen.png", png_file], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=10)
        return xml_file, png_file
    except subprocess.TimeoutExpired:
        print(f" [-] Capture Pair Timeout (15s)")
        return None, None
    except Exception as e:
        print(f" [-] Capture Pair Fail: {e}")
        return None, None

def check_fatal_errors(xml_file):
    """Check for UI states that indicate definitive failure (No results, unreachable)"""
    try:
        tree = ET.parse(xml_file)
        root = tree.getroot()
        fatal_messages = [
            "검색 결과가 없습니다",
            "결과를 제공할 수 없습니다",
            "검색 결과가 없어요",
            "장소를 찾을 수 없습니다",
            "길찾기 결과를 제공할 수 없습니다"
        ]
        for node in root.iter():
            text = (node.get('text') or "").strip()
            for msg in fatal_messages:
                if msg in text:
                    return True, text
        return False, None
    except:
        return False, None

def check_and_dismiss_popups(device_id, xml_file, category):
    """Check for known blocking popups like cache clearing and dismiss them"""
    try:
        tree = ET.parse(xml_file)
        root = tree.getroot()
        is_popup_present = False
        
        for node in root.iter():
            text = (node.get('text') or "").strip()
            if "캐시" in text and "삭제" in text:
                is_popup_present = True
                break
                
        if is_popup_present:
            print(f" [!] Interstitial Popup Detected (Cache Delete). Dismissing...")
            # Look for confirm button
            for node in root.iter():
                text = (node.get('text') or "").strip()
                if text in ["확인", "예", "삭제"]:
                    bounds_str = node.get('bounds')
                    if bounds_str:
                        coords = [int(c) for c in bounds_str.replace('][', ',').replace('[', '').replace(']', '').split(',')]
                        tx = (coords[0] + coords[2]) // 2
                        ty = (coords[1] + coords[3]) // 2
                        subprocess.run(["adb", "-s", device_id, "shell", "input", "tap", str(tx), str(ty)])
                        print(f" [✓] Dismissed popup by clicking '{text}'")
                        time.sleep(2)
                        return get_ui_dump_pair(device_id, category)
    except: pass
    return xml_file, None

def find_element(xml_file, query):
    """Pure dynamic discovery with Flexible Address Matching"""
    try:
        tree = ET.parse(xml_file)
        root = tree.getroot()
        mode, val = query.split(':', 1)
        
        matches = []
        for node in root.iter():
            match = False
            node_text = (node.get('text') or "").strip()
            node_id = (node.get('resource-id') or "")
            node_desc = (node.get('content-desc') or "")
            
            if mode == "text": 
                # [V2.3.1] Handle detail addresses by stripping after comma for long addresses
                clean_val = val
                if "," in clean_val and len(clean_val.split()) > 2:
                    clean_val = clean_val.split(',')[0].strip()
                
                # [V2.3] Simple 'Whole Match' after skipping first 2 words
                words = clean_val.split()
                if len(words) > 2:
                    match_target = " ".join(words[2:])
                else:
                    match_target = clean_val
                
                # Check if our target address is within the node text as-is
                match = match_target in node_text
            elif mode == "contains": match = val in node_text
            elif mode == "exact": match = node_text == val
            elif mode == "id": match = node_id == val
            elif mode == "desc": match = val in node_desc
            
            if match:
                bounds_str = node.get('bounds')
                if not bounds_str: continue
                coords = [int(c) for c in bounds_str.replace('][', ',').replace('[', '').replace(']', '').split(',')]
                
                # Scoring logic (Keep original robust scoring)
                score = 0
                x1, y1, x2, y2 = coords
                width, height = x2 - x1, y2 - y1
                area = width * height
                clickable = node.get('clickable', 'false').lower() == 'true'

                if node_text == val: score += 100 
                if clickable: score += 50
                if area > (1080 * 2000 * 0.8): score -= 200
                if area <= 0: score -= 500
                if y1 > 1500: score += 30
                if len(node_text) > len(val) + 10: score -= 30
                if node.get('class') == 'android.view.View' and not clickable: score -= 50
                if 10 < width < 1000 and 10 < height < 500: score += 20
                
                matches.append({
                    'node': node, 'coords': coords, 'checked': node.get('checked', 'false').lower() == 'true',
                    'score': score, 'area': area, 'text': node_text
                })
        
        if not matches: return None, False, None
        
        matches.sort(key=lambda x: (-x['score'], x['area']))
        best = matches[0]
        
        return best['coords'], best['checked'], best['text']
    except Exception as e:
        print(f" [-] find_element Error: {e}")
        return None, False, None

def report_fail(log_id, device_id, status, requested, actual, error):
    """Report failure details to API Server with current log path"""
    if not log_id: return
    log_path = os.environ.get("CAPTURE_LOG_DIR", "Unknown")
    data = {
        "task_id": int(log_id), "device_id": device_id, "status": status, 
        "requested_address": requested, "actual_address": actual, 
        "error_msg": error, "log_path": log_path
    }
    api_server = os.environ.get('API_SERVER', 'localhost:8000')
    try:
        subprocess.run(["curl", "-s", "--connect-timeout", "5", "-X", "POST", f"http://{api_server}/api/v1/update_status", "-H", "Content-Type: application/json", "-d", json.dumps(data)], stdout=subprocess.DEVNULL, timeout=10)
    except: pass

def click_element(device_id, query, padding=10, category="default"):
    """Executes dynamic click with failure reporting and robust heuristics"""
    log_id = os.environ.get("NMAP_LOG_ID")
    last_actual_text = "Not Found"
    
    for attempt in range(3):
        xml_path, png_path = get_ui_dump_pair(device_id, category)
        if not xml_path: time.sleep(2); continue

        # [NEW] Check and dismiss blocking popups
        xml_path, _ = check_and_dismiss_popups(device_id, xml_path, category)
        if not xml_path: time.sleep(2); continue

        # [V2.6] Early Exit if Fatal Error Message is detected on screen
        is_fatal, fatal_msg = check_fatal_errors(xml_path)
        if is_fatal:
            print(f" [!] FATAL UI STATE DETECTED: '{fatal_msg}'. Exiting immediately.")
            report_fail(log_id, device_id, "FAIL_FATAL_UI_STATE", query, fatal_msg, f"Early exit due to: {fatal_msg}")
            return False
            
        bounds, is_checked, actual_text = find_element(xml_path, query)
        if actual_text: last_actual_text = actual_text
        
        if bounds:
            x1, y1, x2, y2 = bounds
            
            # [FIX] Prevent padding from expanding the clickable area outside the bounds
            pad_x = padding if x2 - x1 >= padding * 2 else 0
            pad_y = padding if y2 - y1 >= padding * 2 else 0
            
            rx_start = x1 + pad_x
            rx_end = x2 - pad_x
            ry_start = y1 + pad_y
            ry_end = y2 - pad_y
            
            if rx_start >= rx_end: rx_end = rx_start + 1
            if ry_start >= ry_end: ry_end = ry_start + 1
            
            target_x = random.randrange(rx_start, rx_end)
            target_y = random.randrange(ry_start, ry_end)
            try:
                subprocess.run(["adb", "-s", device_id, "shell", "input", "tap", str(target_x), str(target_y)], timeout=10)
                print(f" [✓] Clicked {query} at ({target_x}, {target_y})")
                return True
            except subprocess.TimeoutExpired:
                print(f" [-] Click Timeout (10s)")
                return False
            
        print(f" [-] Element not found [{query}]. XML: {os.path.basename(xml_path)} | Retry {attempt+1}/3...")
        time.sleep(2)
    
    # [NEW] Failure Reporting for Address mismatch
    if "text:" in query:
        requested_addr = query.split("text:", 1)[1]
        print(f" [!] Reporting Mismatch: Req={requested_addr} | Act={last_actual_text}")
        report_fail(log_id, device_id, "FAIL_ADDRESS_MISMATCH", requested_addr, last_actual_text, "Matching failed after 3 retries")

    return False

def chain_click(device_id, queries, padding=10, category="default", delay_range=(1.5, 3.5)):
    """Executes a sequence of clicks with all robust logic"""
    for attempt in range(3):
        xml_path, png_path = get_ui_dump_pair(device_id, category)
        if not xml_path: time.sleep(2); continue
        
        # [NEW] Check and dismiss blocking popups
        xml_path, _ = check_and_dismiss_popups(device_id, xml_path, category)
        if not xml_path: time.sleep(2); continue

        # [V2.6] Early Exit if Fatal Error Message is detected on screen
        is_fatal, fatal_msg = check_fatal_errors(xml_path)
        if is_fatal:
            print(f" [!] FATAL UI STATE DETECTED: '{fatal_msg}'. Exiting immediately.")
            return False

        targets = []
        all_found = True
        for query in queries:
            bounds, is_checked, _ = find_element(xml_path, query)
            if bounds:
                targets.append({'query': query, 'bounds': bounds, 'checked': is_checked})
            else:
                all_found = False; break
        
        if not all_found:
            time.sleep(2); continue

        for i, target in enumerate(targets):
            x1, y1, x2, y2 = target['bounds']
            
            # [FIX] Prevent padding from expanding the clickable area outside the bounds
            pad_x = padding if x2 - x1 >= padding * 2 else 0
            pad_y = padding if y2 - y1 >= padding * 2 else 0
            
            rx_start = x1 + pad_x
            rx_end = x2 - pad_x
            ry_start = y1 + pad_y
            ry_end = y2 - pad_y
            
            if rx_start >= rx_end: rx_end = rx_start + 1
            if ry_start >= ry_end: ry_end = ry_start + 1
            
            tx = random.randrange(rx_start, rx_end)
            ty = random.randrange(ry_start, ry_end)
            try:
                subprocess.run(["adb", "-s", device_id, "shell", "input", "tap", str(tx), str(ty)], timeout=10)
            except subprocess.TimeoutExpired:
                print(f" [-] Chain Click Timeout (10s)")
                return False
            if i < len(targets) - 1: time.sleep(random.uniform(*delay_range))
        return True
    return False

if __name__ == "__main__":
    if len(sys.argv) < 3: sys.exit(1)
    cat = sys.argv[3] if len(sys.argv) >= 4 else "default"
    click_element(sys.argv[1], sys.argv[2], category=cat)
