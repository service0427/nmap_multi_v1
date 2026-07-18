import json
import os
import sys
import time
import glob
import subprocess
import hashlib
import datetime
import random
import math
import traceback
# reload_path.py의 고도화된 디코더를 그대로 활용
from reload_path import RouteDecoder

def get_now():
    return datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]

def log_print(msg):
    print(f"[{get_now()}] {msg}")
    sys.stdout.flush()

def get_latest_driving_packet(log_dir):
    pattern = os.path.join(log_dir, "*_GET_v3_global_driving.json")
    files = glob.glob(pattern)
    if not files: return None
    try:
        files.sort(key=lambda x: int(os.path.basename(x).split('_')[0]), reverse=True)
        return files[0]
    except: return None

def get_su_cmd(device_id):
    try:
        res = subprocess.run(["adb", "-s", device_id, "shell", "which su"], capture_output=True, text=True).stdout.strip()
        if res and "not found" not in res:
            return res
    except:
        pass
    for path in ["/system/bin/su", "/system/xbin/su", "/sbin/su"]:
        try:
            res = subprocess.run(["adb", "-s", device_id, "shell", f"ls {path}"], capture_output=True, text=True).stdout.strip()
            if res and "No such" not in res:
                return path
        except:
            pass
    return "su"

def get_current_mock_location(device_id):
    cmd = ["adb", "-s", device_id, "shell", "dumpsys location | grep -E 'last location=Location\\[(gps|fused|test) [0-9]{2}\\.[0-9]+,[0-9]{3}\\.[0-9]+' | head -n 1"]
    res = subprocess.run(cmd, capture_output=True, text=True).stdout.strip()
    if not res:
        cmd = ["adb", "-s", device_id, "shell", "dumpsys location | grep -E 'last mock location=Location\\[(gps|fused|test) [0-9]{2}\\.[0-9]+,[0-9]{3}\\.[0-9]+' | head -n 1"]
        res = subprocess.run(cmd, capture_output=True, text=True).stdout.strip()
    try:
        content = res.split("[")[1].split("]")[0]
        parts = content.split()
        for p in parts:
            if "," in p:
                lat, lng = map(float, p.split(","))
                return lat, lng
        return None, None
    except: return None, None

def set_simulator_speed(device_id, kmh):
    speed_mps = round(kmh / 3.6, 4)
    speed_mps = max(speed_mps, 0.8333) # Double Protection: Enforce 3.0 km/h floor at m/s level
    pkg = "com.rosteam.gpsemulator"
    su_cmd = get_su_cmd(device_id)
    cmd = ["adb", "-s", device_id, "shell", su_cmd, "-c", 
           f"am start-foreground-service -n {pkg}/.servicex2484 -a ACTION_START_CONTINUOUS --es uy.digitools.RUTA 'ruta0' --ef velocidad {speed_mps} --ei loopMode 0"]
    subprocess.run(cmd, capture_output=True)
    log_print(f"[*] [🚀] Speed Adjusted: {kmh} km/h (m/s: {speed_mps})")

def move_gps_to_target(device_id, target_lat, target_lng):
    """2단계: 목적지 좌표로 GPS 순간이동"""
    pkg = "com.rosteam.gpsemulator"
    log_print(f"[🛡️] SAFETY STEP 2: Force Moving GPS to Target: {target_lat}, {target_lng}")
    
    # 기기별 격리된 tmp 폴더 경로 확보
    script_dir = os.path.dirname(os.path.abspath(__file__))
    dev_tmp_dir = os.path.join(script_dir, "..", "logs", device_id, "tmp")
    os.makedirs(dev_tmp_dir, exist_ok=True)
    local_xml = os.path.join(dev_tmp_dir, "force_prefs.xml")
    
    with open(local_xml, "w") as f:
        f.write(f"<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n")
        f.write(f'    <boolean name="noads" value="true" />\n')
        f.write(f'    <float name="velocidad" value="0.0" />\n')
        f.write(f'    <string name="ruta0">Parking+1+0.0+0.0+{target_lat},{target_lng};{target_lat},{target_lng};</string>\n')
        f.write(f'    <string name="lastloc">Current+{target_lat},{target_lng}+15.0</string>\n')
        f.write(f"</map>")
    prefs_path = f"/data/data/{pkg}/shared_prefs/{pkg}_preferences.xml"
    subprocess.run(["adb", "-s", device_id, "shell", "am", "force-stop", pkg], capture_output=True)
    subprocess.run(["adb", "-s", device_id, "push", local_xml, "/data/local/tmp/force_gps.xml"], capture_output=True)
    su_cmd = get_su_cmd(device_id)
    subprocess.run(["adb", "-s", device_id, "shell", su_cmd, "-c",
                    f"cp /data/local/tmp/force_gps.xml {prefs_path} && chown \$(stat -c %u:%g /data/data/{pkg}) {prefs_path} && chmod 660 {prefs_path} && rm /data/local/tmp/force_gps.xml"], capture_output=True)
    cmd = ["adb", "-s", device_id, "shell", su_cmd, "-c", 
           f"am start-foreground-service -n {pkg}/.servicex2484 -a ACTION_START_CONTINUOUS --es uy.digitools.RUTA 'ruta0' --ef velocidad 0.0 --ei loopMode 1"]
    subprocess.run(cmd, capture_output=True)
    if os.path.exists(local_xml): os.remove(local_xml)

def trigger_back_sequence(device_id):
    """3단계: 안내 강제 종료 (Back Key + 15s)"""
    log_print(f"[🛡️] SAFETY STEP 3: No arrival signal. Sending 'Back' key and waiting 15s...")
    subprocess.run(["adb", "-s", device_id, "shell", "input", "keyevent", "4"], capture_output=True)
    time.sleep(15)
    log_print(f"[✓] Safety Sequence Complete.")

def update_session_summary(log_dir, data):
    summary_path = os.path.join(log_dir, "session_summary.json")
    try:
        current = {}
        if os.path.exists(summary_path):
            with open(summary_path, "r") as f:
                current = json.load(f)
        current.update(data)
        with open(summary_path, "w") as f:
            json.dump(current, f, ensure_ascii=False, indent=2)
    except Exception as e:
        log_print(f" [!] Summary Update Fail: {e}")

def update_current_task_badge(device_id, data):
    """[NEW] 웹 모니터용 실시간 명표(current_task.json) 정보 보강"""
    try:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        badge_path = os.path.join(script_dir, "..", "logs", device_id, "current_task.json")
        if os.path.exists(badge_path):
            with open(badge_path, 'r') as f:
                current = json.load(f)
            current.update(data)
            with open(badge_path, 'w') as f:
                json.dump(current, f, ensure_ascii=False, indent=2)
    except Exception as e:
        log_print(f" [!] Badge Update Fail: {e}")

def main(log_dir, device_id):
    try:
        total_target_sec = int(float(os.environ.get("NMAP_ARRIVAL_TIME", 0)))
    except:
        total_target_sec = 0
        
    if total_target_sec <= 0:
        log_print("[!] ERROR: NMAP_ARRIVAL_TIME is missing or invalid. Falling back to 300s.")
        total_target_sec = 300
    else:
        log_print(f"[*] Using Exact Server Arrival Time: {total_target_sec}s")
        
    session_start_ts = time.time()
    driving_start_ts = None
    log_print(f"[*] Session Start Time: {datetime.datetime.fromtimestamp(session_start_ts).strftime('%H:%M:%S')}")
    
    drive_state = "INIT"
    coords_list = []
    initial_total_dist = 0.0
    
    # 정체 감지 및 안전 단계 변수
    last_remaining_dist = 99999.9
    stuck_count = 0
    gps_fail_count = 0
    safety_stage = 0 # 0: Normal, 1: GPS Moved, 2: Finished
    slowdown_applied = False
    final_badge_speed = 0.0
    
    log_print(f"============================================================")
    log_print(f"[*] [Auto-Reloader V7.7] Sequential Safety Monitor Started")
    log_print(f"[*] Device ID      : {device_id}")
    log_print(f"[*] Session Goal   : {total_target_sec}s ({total_target_sec/60:.1f} min)")
    log_print(f"[*] Safety Config  : Stuck 30s -> Force Move -> (20s) -> Back key")
    log_print(f"============================================================")
    
    while True:
        try:
            api_speed = float(os.environ.get("NMAP_START_SPEED", 0.0))
        except:
            api_speed = 0.0

        try:
            elapsed = int(time.time() - session_start_ts)
            
            if drive_state == "INIT":
                latest_file = get_latest_driving_packet(log_dir)
                if latest_file:
                    with open(latest_file, "r", encoding="utf-8") as f:
                        data = json.load(f)
                    res_body = data.get("response", {}).get("body", "")
                    if res_body:
                        coords_list = RouteDecoder.decode_pbf_path(res_body)
                        dist = RouteDecoder.calculate_distance(coords_list)
                        if coords_list and dist >= 0.1:
                            initial_total_dist = dist
                            log_print(f"[📍] Initial Path Loaded: {dist:.2f} km")
                            
                            # [NEW] Update Summary with Distance info
                            update_session_summary(log_dir, {
                                "total_distance_km": round(dist, 3),
                                "path_loaded_time": datetime.datetime.now().isoformat()
                            })
                            
                            # [NEW] 확정된 주행 목표 데이터를 웹 모니터 명표에 기록 (동적 보정 속도 우선)
                            calc_speed = round((dist / (total_target_sec / 3600)), 1) if total_target_sec > 0 else 0.0
                            final_badge_speed = calc_speed
                            
                            log_print(f"[⚙️] Dynamic Speed Calc: {dist:.2f}km / ({total_target_sec}s) = {final_badge_speed}km/h")
                            
                            update_current_task_badge(device_id, {
                                "target_sec": total_target_sec,
                                "total_dist_km": round(dist, 3),
                                "avg_speed_kmh": final_badge_speed
                            })
                            
                            # Wait for monitor.sh to click 'Guidance Start' and create the flag file
                            flag_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "logs", device_id, "tmp", "guidance_started")
                            log_print(f"[⏳] Waiting for Guidance Start click (checking flag: {flag_path})...")
                            
                            # Timeout to prevent infinite hang if click fails (max 90s for slow networks & modal delays)
                            wait_start = time.time()
                            while not os.path.exists(flag_path):
                                time.sleep(0.5)
                                if time.time() - wait_start > 90.0:
                                    log_print("[-] Timeout waiting for guidance_started flag file. Aborting GPS trigger.")
                                    break
                            
                            if os.path.exists(flag_path):
                                log_print("[🚀] Guidance Start click detected! Starting road simulation immediately...")
                                script_dir = os.path.dirname(os.path.abspath(__file__))
                                env = os.environ.copy()
                                env["NMAP_TARGET_TOTAL_SEC"] = str(total_target_sec)
                                env["NMAP_SESSION_START_TS"] = str(session_start_ts)
                                env["NMAP_INITIAL_DIST_KM"] = str(dist)
                                subprocess.run(["python3", os.path.join(script_dir, "reload_path.py"), latest_file, device_id], check=True, env=env)
                                drive_state = "MONITORING"
                                driving_start_ts = time.time()
                                log_print(f"[🚀] Guidance Start Click Registered at {datetime.datetime.fromtimestamp(driving_start_ts).strftime('%H:%M:%S')}. Initiating driving.")
                                log_print(f"[🛰️] State Transition: MONITORING")
                            else:
                                log_print("[🚨] Failed to detect Guidance Start click. Exiting auto_reloader.")
                                sys.exit(1)
 
            elif drive_state == "MONITORING":
                if safety_stage == 1:
                    # Wobble GPS slightly to wake up Naver Map's location listener at the destination
                    wobble_lat = coords_list[-1][0] + random.uniform(-0.00008, 0.00008)
                    wobble_lng = coords_list[-1][1] + random.uniform(-0.00008, 0.00008)
                    move_gps_to_target(device_id, wobble_lat, wobble_lng)
                
                cur_lat, cur_lng = get_current_mock_location(device_id)
                if cur_lat and coords_list:
                    gps_fail_count = 0
                    min_err = float('inf')
                    start_idx = 0
                    for i, (plat, plng) in enumerate(coords_list):
                        err = math.sqrt((cur_lat - plat)**2 + (cur_lng - plng)**2)
                        if err < min_err:
                            min_err = err; start_idx = i
                    remaining_dist = RouteDecoder.calculate_distance(coords_list[start_idx:])
                    
                    driving_elapsed = int(time.time() - driving_start_ts) if driving_start_ts else 0
                    log_print(f"[🛣️] Progress: {remaining_dist:.2f} km remaining | Drive Time: {driving_elapsed}s / {total_target_sec}s (Total Session: {elapsed}s)")
                    
                    # Proactive Slowdown near Destination (<500m) for high-speed runs (>100 km/h)
                    if final_badge_speed > 100.0 and remaining_dist < 0.5 and not slowdown_applied:
                        slowdown_speed = random.randint(30, 50)
                        log_print(f"[⚙️] Proactive Slowdown near Destination (<500m): Speed reduced from {final_badge_speed} to {slowdown_speed} km/h")
                        set_simulator_speed(device_id, slowdown_speed)
                        slowdown_applied = True
                    
                    # Stuck Detection Logic (Optimized for slow speed floor 3km/h = 8.3m/10s)
                    if remaining_dist > 0.0:
                        if last_remaining_dist == 99999.9:
                            last_remaining_dist = remaining_dist
                        
                        dist_diff = last_remaining_dist - remaining_dist
                        
                        # 40초 미만 극초반 렉 구간은 stuck 판단 제외, 임계치는 5m 미만 이동으로 세밀화
                        if elapsed > 40 and 0.0 <= dist_diff < 0.005: # less than 5m
                            stuck_count += 1
                            log_print(f"[⏳] Stuck warning: progress {dist_diff*1000:.1f}m < 5m. Stuck count: {stuck_count}/9")
                            # Self-healing: 60s stuck (6 counts) -> teleport to end
                            if stuck_count == 6 and safety_stage == 0:
                                move_gps_to_target(device_id, coords_list[-1][0], coords_list[-1][1])
                                safety_stage = 1
                        else:
                            stuck_count = 0
                            last_remaining_dist = remaining_dist
                        
                        if stuck_count >= 9:
                            log_print(f"[🚨] STUCK DETECTED (No progress for 90s). Aborting session...")
                            # Report fail status to API server
                            log_id = os.environ.get("NMAP_LOG_ID")
                            api_server = os.environ.get("API_SERVER", "localhost:8000")
                            if log_id:
                                try:
                                    import urllib.request
                                    url = f"http://{api_server}/api/v1/report_result"
                                    req_data = json.dumps({
                                        "task_id": int(log_id),
                                        "log_id": int(log_id),
                                        "status": "FAIL",
                                        "message": "DRIVING_STUCK",
                                        "device_id": device_id
                                    }).encode('utf-8')
                                    req = urllib.request.Request(url, data=req_data, headers={'Content-Type': 'application/json'}, method='POST')
                                    with urllib.request.urlopen(req, timeout=5) as response:
                                        log_print(f"[*] Reported FAIL_DRIVING_STUCK: {response.read().decode('utf-8')}")
                                except Exception as e:
                                    log_print(f"[!] Failed to report status: {e}")
                            
                            pkg = "com.nhn.android.nmap"
                            subprocess.run(["adb", "-s", device_id, "shell", "am", "force-stop", pkg], capture_output=True)
                            sys.exit(1)

                    if remaining_dist < 0.03:
                        log_print("[✨] Destination reached. Transitioning to FORCED_FINISH.")
                        # [Self-Healing] Inject virtual routeend to events.log to prevent 15-minute hangs if proxy misses the packet
                        try:
                            events_path = os.path.join(log_dir, "events.log")
                            with open(events_path, "a", encoding="utf-8") as ef:
                                ef.write(f"[{datetime.datetime.now().strftime('%H:%M:%S.%3N')}] [screenview] routeend\n")
                            log_print("[✓] Self-Healed: Injected virtual routeend event to events.log")
                        except Exception as ee:
                            log_print(f"[!] Failed to inject virtual routeend: {ee}")
                        drive_state = "FORCED_FINISH"
                        time.sleep(30)
                else:
                    gps_fail_count += 1
                    log_print(f"[?] Waiting for GPS update... ({gps_fail_count}/30)")
                    if gps_fail_count >= 30:
                        log_print("[🚨] GPS UPDATE TIMEOUT (300s). Aborting session...")
                        log_id = os.environ.get("NMAP_LOG_ID")
                        api_server = os.environ.get("API_SERVER", "localhost:8000")
                        if log_id:
                            try:
                                import urllib.request
                                url = f"http://{api_server}/api/v1/update_status"
                                req_data = json.dumps({
                                    "task_id": int(log_id),
                                    "log_id": int(log_id),
                                    "status": "FAIL_GPS_TIMEOUT",
                                    "device_id": device_id
                                }).encode('utf-8')
                                req = urllib.request.Request(url, data=req_data, headers={'Content-Type': 'application/json'}, method='POST')
                                with urllib.request.urlopen(req, timeout=5) as response:
                                    log_print(f"[*] Reported FAIL_GPS_TIMEOUT: {response.read().decode('utf-8')}")
                            except Exception as e:
                                log_print(f"[!] Failed to report status: {e}")
                        
                        pkg = "com.nhn.android.nmap"
                        subprocess.run(["adb", "-s", device_id, "shell", "am", "force-stop", pkg], capture_output=True)
                        sys.exit(1)
            
            elif drive_state == "FORCED_FINISH":
                time.sleep(30)

        except Exception as e:
            log_print(f"[🔥] LOOP ERROR: {e}")

        time.sleep(10)

if __name__ == "__main__":
    if len(sys.argv) < 3: sys.exit(1)
    main(sys.argv[1], sys.argv[2])
