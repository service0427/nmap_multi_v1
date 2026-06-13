import os
import subprocess
import json
import time
import threading

MAX_SLOTS = 5
LOG_BASE_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "logs")

device_slots = [None] * MAX_SLOTS

def get_device_diagnostics(serial):
    info = {
        "status": "IDLE",
        "ip": "N/A",
        "temp": "??",
        "battery": "??",
        "latest_log": "No Log",
        "current_task": None
    }
    
    # 1. Check Working Status (Lightweight)
    try:
        # Changed from "wifi_multi/lib/main.sh {serial}" to "main.sh {serial}" to match the absolute path execution
        subprocess.check_output(["pgrep", "-f", f"main.sh {serial}"])
        info["status"] = "WORKING"
    except:
        info["status"] = "IDLE"

    # 2. Get Battery & Temp (Cached)
    try:
        batt_raw = subprocess.check_output(["adb", "-s", serial, "shell", "dumpsys battery"], timeout=5).decode()
        for line in batt_raw.splitlines():
            if "level:" in line: info["battery"] = line.split(":")[1].strip()
            if "temperature:" in line: info["temp"] = int(line.split(":")[1].strip()) / 10
    except:
        pass

    # 3. Find Latest Task Badge (current_task.json)
    try:
        task_info_path = os.path.join(LOG_BASE_DIR, serial, "current_task.json")
        if os.path.exists(task_info_path):
            with open(task_info_path, 'r') as f:
                task_data = json.load(f)
                info["current_task"] = task_data
                info["ip"] = task_data.get("real_ip", "N/A")
                sp = task_data.get("session_path", "")
                if "_" in sp:
                    info["dest_id"] = sp.split("_")[-1]
    except:
        pass
        
    return info

def refresh_device_slots():
    global device_slots
    try:
        output = subprocess.check_output(["adb", "devices", "-l"], timeout=5).decode("utf-8")
        lines = output.strip().split("\n")[1:]
        current_connected = {}
        for line in lines:
            if not line.strip() or "device" not in line: continue
            parts = line.split()
            serial = parts[0]
            model = "Unknown"
            for p in parts:
                if p.startswith("model:"): model = p.split(":")[1]; break
            current_connected[serial] = model

        # 1. Update existing slots
        for i in range(MAX_SLOTS):
            slot = device_slots[i]
            if slot:
                if slot["id"] in current_connected:
                    slot["offline"] = False
                    slot["model"] = current_connected[slot["id"]]
                    # Update diagnostics
                    diag = get_device_diagnostics(slot["id"])
                    slot.update(diag)
                    del current_connected[slot["id"]]
                else:
                    slot["offline"] = True

        # 2. Assign new devices to empty or offline slots
        for serial, model in current_connected.items():
            # Find first None or Offline slot
            assigned = False
            for i in range(MAX_SLOTS):
                if device_slots[i] is None or device_slots[i].get("offline"):
                    diag = get_device_diagnostics(serial)
                    device_slots[i] = {"id": serial, "model": model, "offline": False, **diag}
                    assigned = True
                    break
    except:
        pass

def diag_background_thread():
    while True:
        refresh_device_slots()
        time.sleep(10) # 10초마다 무거운 진단 갱신

def start_diag_thread():
    # 초기 1회 실행 후 스레드 시작
    refresh_device_slots()
    threading.Thread(target=diag_background_thread, daemon=True).start()
