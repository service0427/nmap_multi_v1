import sys
import os
import json
import base64

# Add the current directory to sys.path to import RouteDecoder
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from smart_route_gen import RouteDecoder

def main():
    if len(sys.argv) < 2:
        print("[!] Missing device ID.")
        sys.exit(1)
        
    device_id = sys.argv[1]
    
    script_dir = os.path.dirname(os.path.abspath(__file__))
    base_dir = os.path.dirname(script_dir)
    macro_dir = os.path.join(base_dir, "logs", "macro")
    
    session_dirs = []
    latest_date_dir = ""
    if os.path.exists(macro_dir):
        date_dirs = sorted([d for d in os.listdir(macro_dir) if os.path.isdir(os.path.join(macro_dir, d))], reverse=True)
        for d in date_dirs:
            dev_dir = os.path.join(macro_dir, d, device_id)
            if os.path.exists(dev_dir):
                s_dirs = sorted([s for s in os.listdir(dev_dir) if os.path.isdir(os.path.join(dev_dir, s))], reverse=True)
                if s_dirs:
                    latest_date_dir = dev_dir
                    session_dirs = s_dirs
                    break
                    
    if not session_dirs:
        legacy_logs = os.path.join(base_dir, "logs", device_id)
        if os.path.exists(legacy_logs):
            date_dirs = sorted([d for d in os.listdir(legacy_logs) if os.path.isdir(os.path.join(legacy_logs, d))], reverse=True)
            if date_dirs:
                latest_date_dir = os.path.join(legacy_logs, date_dirs[0])
                session_dirs = sorted([s for s in os.listdir(latest_date_dir) if os.path.isdir(os.path.join(latest_date_dir, s))], reverse=True)
                
    if not session_dirs:
        print(f"[!] No session logs found for device {device_id}")
        sys.exit(1)
        
    latest_session_dir = os.path.join(latest_date_dir, session_dirs[0])
    
    # Extract latest driving log
    driving_logs = []
    for f in os.listdir(latest_session_dir):
        if "routeend.json" in f:
            print(f"[!] Route already ended for {device_id}. Skipping.")
            sys.exit(1)
        if "_GET_drive_v3_driving.json" in f or "_GET_v3_global_driving.json" in f or ("_GET_" in f and "driving.json" in f):
            try:
                idx = int(f.split("_")[0])
                driving_logs.append((idx, f))
            except ValueError:
                pass
                
    if not driving_logs:
        print(f"[!] No driving logs found in session {latest_session_dir}")
        sys.exit(1)
        
    driving_logs.sort(key=lambda x: x[0], reverse=True)
    
    route_pts = None
    dist = 0.0
    
    for idx, log_filename in driving_logs:
        log_file_path = os.path.join(latest_session_dir, log_filename)
        
        with open(log_file_path, "r", encoding="utf-8") as f:
            data = json.load(f)
            
        resp_body = data.get("response", {}).get("body", "")
        if not resp_body or not resp_body.startswith("base64:"):
            continue
            
        b64_data = resp_body.replace("base64:", "")
        try:
            pbf_content = base64.b64decode(b64_data)
            pts = RouteDecoder.decode_pbf_path(pbf_content)
        except Exception:
            continue
            
        if pts and len(pts) > 0:
            route_pts = pts
            dist = RouteDecoder.calculate_distance(route_pts)
            break
            
    if not route_pts:
        print("[!] Decoder could not extract route geometry from ANY of the recent logs.")
        sys.exit(1)
    lib_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tmp", "route_library")
    os.makedirs(lib_dir, exist_ok=True)
    filename = f"reload_{device_id}.json"
    full_path = os.path.join(lib_dir, filename)
    with open(full_path, "w") as f:
        json.dump(route_pts, f)
        
    print(f"ROUTE_FILE: {full_path}")
    print(f"TOTAL_DISTANCE: {dist:.2f}")

if __name__ == "__main__":
    main()
