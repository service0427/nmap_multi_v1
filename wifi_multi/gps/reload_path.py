import json
import os
import sys
import time
import gzip
import base64
import subprocess
import math
import random
import datetime

def get_now():
    """H:M:S.SSS 형식의 타임스탬프 반환"""
    return datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]

class RouteDecoder:
    @staticmethod
    def calculate_distance(coords):
        if not coords or len(coords) < 2: return 0.0
        total = 0.0
        for i in range(len(coords) - 1):
            lat1, lon1 = coords[i]; lat2, lon2 = coords[i+1]
            R = 6371.0
            dlat = math.radians(lat2 - lat1); dlon = math.radians(lon2 - lon1)
            a = math.sin(dlat / 2)**2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlon / 2)**2
            c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
            total += R * c
        return total

    @staticmethod
    def decode_zigzag(n): return (n >> 1) ^ (-(n & 1))

    @staticmethod
    def decode_json_path(coords_array):
        if not coords_array or len(coords_array) < 2: return []
        pts = []
        curr_x, curr_y = coords_array[0], coords_array[1]
        pts.append([float(curr_y) / 10000000.0, float(curr_x) / 10000000.0])
        for i in range(2, len(coords_array), 2):
            if i + 1 < len(coords_array):
                curr_x += coords_array[i]; curr_y += coords_array[i+1]
                pts.append([float(curr_y) / 10000000.0, float(curr_x) / 10000000.0])
        return pts

    @classmethod
    def decode_pbf_path(cls, resp_content_raw):
        try:
            if isinstance(resp_content_raw, str):
                if resp_content_raw.startswith("base64:"):
                    resp_content = base64.b64decode(resp_content_raw.split("base64:")[1])
                else:
                    resp_content = resp_content_raw.encode("latin-1", "replace")
                    if len(resp_content) < 10: 
                        resp_content = resp_content_raw.encode("utf-8", "ignore")
            else:
                resp_content = resp_content_raw
            if resp_content and resp_content[:2] == b"\x1f\x8b": 
                resp_content = gzip.decompress(resp_content)
        except Exception as e: return []
        if not resp_content: return []
        for i in range(len(resp_content) - 10):
            if resp_content[i] == 0x0a:
                try:
                    idx = i + 1; length = 0; shift = 0
                    while idx < len(resp_content):
                        b = resp_content[idx]; idx += 1
                        length |= (b & 0x7f) << shift
                        shift += 7
                        if not (b & 0x80): break
                    if 10 < length < 2000000 and idx + length <= len(resp_content):
                        arr = resp_content[idx:idx+length]; idx2 = 0; coords = []
                        while idx2 < len(arr):
                            val = 0; s2 = 0
                            while idx2 < len(arr):
                                b = arr[idx2]; idx2 += 1
                                val |= (b & 0x7f) << s2
                                s2 += 7
                                if not (b & 0x80): break
                            coords.append(cls.decode_zigzag(val))
                        if len(coords) >= 4:
                            lng_sample, lat_sample = coords[0], coords[1]
                            if 1200000000 < lng_sample < 1350000000 and 300000000 < lat_sample < 450000000:
                                return cls.decode_json_path(coords)
                except Exception: pass
        return []

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

def run_reload(packet_file, device_id):
    if not os.path.exists(packet_file): return
    with open(packet_file, "r", encoding="utf-8") as f:
        try: data = json.load(f)
        except: return

    res_body = data.get("response_body_base64")
    if not res_body: res_body = data.get("response", {}).get("body", "")
    if not res_body: return

    coords = RouteDecoder.decode_pbf_path(res_body)
    if not coords: return

    dist_km = RouteDecoder.calculate_distance(coords)
    
    # 1. Fetch Session Constraints
    try:
        target_sec = float(os.environ.get("NMAP_TARGET_TOTAL_SEC", 1200))
        initial_dist_km = float(os.environ.get("NMAP_INITIAL_DIST_KM", dist_km))
    except:
        target_sec, initial_dist_km = 1200, dist_km

    # 2. Calculate Base Speed (Dynamic Recalculation strictly based on real path)
    base_speed_kmh = (initial_dist_km / (target_sec / 3600.0)) if target_sec > 0 else 60.0
    
    # 3. Apply Speed (Simplified for V7.1 - Enforcing a 15km/h floor to prevent freezing)
    base_speed_kmh = max(base_speed_kmh, 15.0)
    final_kmh = round(base_speed_kmh, 1)
    
    # [V7.1 Logging] Debug calculation info
    print(f"[{get_now()}] [V7.1] Path Reloaded: {dist_km:.2f}km | Initial: {initial_dist_km:.2f}km | TargetTime: {target_sec}s")
    print(f"[{get_now()}] [V7.1] Calculation: ({initial_dist_km:.2f} / ({target_sec}/3600)) = {final_kmh} km/h")
    script_dir = os.path.dirname(os.path.abspath(__file__))
    tmp_dir = os.path.join(os.path.dirname(script_dir), "tmp")
    os.makedirs(tmp_dir, exist_ok=True)
    temp_route = os.path.join(tmp_dir, f"hot_route_{device_id}.json")
    with open(temp_route, "w") as f: json.dump(coords, f)
    
    try:
        subprocess.run(["python3", os.path.join(script_dir, "rebuild_xml.py"), temp_route, str(final_kmh), device_id], check=True)
        
        pkg = "com.rosteam.gpsemulator"
        local_xml = os.path.join(tmp_dir, f"gps_prefs_{device_id}.xml")
        android_tmp = f"/data/local/tmp/hot_gps_{device_id}.xml"
        prefs_path = f"/data/data/{pkg}/shared_prefs/{pkg}_preferences.xml"
        
        subprocess.run(["adb", "-s", device_id, "shell", "am", "force-stop", pkg], check=True)
        subprocess.run(["adb", "-s", device_id, "push", local_xml, android_tmp], check=True, capture_output=True)
        
        su_cmd = get_su_cmd(device_id)
        subprocess.run(["adb", "-s", device_id, "shell", f"{su_cmd} -c 'cp {android_tmp} {prefs_path} && chown $(stat -c %u:%g /data/data/{pkg}) {prefs_path} && chmod 660 {prefs_path} && rm {android_tmp}'"], check=True)
        
        speed_mps = round(final_kmh / 3.6, 6)
        subprocess.run(["adb", "-s", device_id, "shell", su_cmd, "-c", f"am start-foreground-service -n {pkg}/.servicex2484 -a ACTION_START_CONTINUOUS --es uy.digitools.RUTA 'ruta0' --ef velocidad {speed_mps} --ei loopMode 0"], check=True)

        log_id = os.environ.get("NMAP_LOG_ID")
        if log_id:
            report_data = {"task_id": log_id, "applied_speed": final_kmh, "status": "DRIVING", "remaining_dist": dist_km}
            api_server = os.environ.get('API_SERVER', 'localhost:8000')
            subprocess.run(["curl", "-s", "-X", "POST", f"http://{api_server}/api/v1/update_status", "-H", "Content-Type: application/json", "-d", json.dumps(report_data)], stdout=subprocess.DEVNULL)
        
    finally:
        if os.path.exists(temp_route): os.remove(temp_route)

if __name__ == "__main__":
    if len(sys.argv) < 3: sys.exit(1)
    run_reload(sys.argv[1], sys.argv[2])
