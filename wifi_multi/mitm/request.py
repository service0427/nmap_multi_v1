import os
import json
import random
import gzip
import base64
from mitmproxy import http
from .whitelist import should_process

IDENTITY_MAP = {}
pairs = [
    ("NMAP_ORIG_SSAID", "NMAP_ID_SSAID"),
    ("NMAP_ORIG_ADID", "NMAP_ID_ADID"),
    ("NMAP_ORIG_NI", "NMAP_ID_NI"),
    ("NMAP_ORIG_IDFV", "NMAP_ID_IDFV"),
    ("NMAP_ORIG_TOKEN", "NMAP_ID_TOKEN")
]
for orig_key, spoof_key in pairs:
    o, s = os.environ.get(orig_key), os.environ.get(spoof_key)
    if o and s and len(o) > 3:
        IDENTITY_MAP[o] = s
# [DEBUG] Check Identity Map
print(f"[*] IDENTITY_MAP Loaded: {len(IDENTITY_MAP)} entries", flush=True)
for k, v in IDENTITY_MAP.items():
    print(f"    - Mapping: {k[:5]}... -> {v[:5]}...", flush=True)

SESSION_STORAGE_OFFSET = random.randint(-500000000, 500000000)
SESSION_BOOT_OFFSET_MS = random.randint(300000, 86400000)
SESSION_INSTALL_OFFSET_SEC = random.randint(86400, 604800)
# [V2.1.7] App initialization timestamp offset (Install + 60~600s jitter)
SESSION_INIT_OFFSET_MS = (SESSION_INSTALL_OFFSET_SEC * 1000) - random.randint(60000, 600000)

def smart_cleanse(obj):
    """Recursive identity washing using simple string/byte replacement.
    [V2.0.9] Improved to prevent data structure corruption by checking ID length."""
    if isinstance(obj, dict):
        return {k: (v + SESSION_STORAGE_OFFSET if k == "storage_size" and isinstance(v, (int, float)) else 
                   (v - SESSION_BOOT_OFFSET_MS if k == "last_boot_ts" and isinstance(v, (int, float)) else 
                   (v - SESSION_INSTALL_OFFSET_SEC if k == "install_ts" and isinstance(v, (int, float)) else 
                   (v - SESSION_INIT_OFFSET_MS if k == "init_ts" and isinstance(v, (int, float)) else smart_cleanse(v))))) 
                for k, v in obj.items()}
    elif isinstance(obj, list): return [smart_cleanse(i) for i in obj]
    elif isinstance(obj, str):
        for real, fake in IDENTITY_MAP.items():
            if len(real) > 5 and real in obj:
                obj = obj.replace(real, fake)
                print(f"[🛡️ CLEANSE] Replaced {real[:4]}... with {fake[:4]}...", flush=True)
        return obj
    elif isinstance(obj, bytes):
        for real, fake in IDENTITY_MAP.items():
            if len(real) > 5:
                real_b, fake_b = real.encode(), fake.encode()
                if real_b in obj: obj = obj.replace(real_b, fake_b)
        return obj
    return obj

def to_jsonable(d):
    """Deep convert to JSON-safe structure. [V2.0.9]"""
    if isinstance(d, dict): return {str(k): to_jsonable(v) for k, v in d.items()}
    elif isinstance(d, list): return [to_jsonable(v) for v in d]
    elif isinstance(d, bytes):
        try: return d.decode('utf-8')
        except: return f"hex:{d.hex()}"
    return d

def jitter_location_dict(o):
    """Randomize specific fields in trafficjam location dict.
    [V2.0.8] Added debug logs for Object 3 (Locations) and Object 4 (WiFi)."""
    if isinstance(o, dict):
        # 1. WiFi Data Array Cleanup (Object 4)
        for wk in [4, "4"]:
            if wk in o and isinstance(o[wk], list):
                print(f"[📡 DEBUG] Object 4 (WiFi Array) detected. Items: {len(o[wk])}. Blanking...", flush=True)
                o[wk] = []

        # 2. Aggressive Mutation for Speed/Bearing/Accuracy (5, 6, 7)
        for k in list(o.keys()):
            ks = str(k)
            val = o[k]
            
            # [DEBUG] Detect Object 3 (Location List)
            if ks == "3" and isinstance(val, list):
                print(f"[📍 DEBUG] Object 3 (Location Array) detected. Items: {len(val)}", flush=True)

            # Target keys 5, 6, 7 only
            if ks in ["5", "6", "7", 5, 6, 7]:
                try:
                    # Match specific "fixed" values that indicate simulated/static location
                    if str(val) in ["1065353216", "1.0", "0", "0.0"]:
                        new_val = int(random.randint(1080000000, 1150000000))
                        o[k] = new_val
                        print(f"  [⚡ JITTER] Field {ks} matched value {val}. Randomized to: {new_val}", flush=True)
                except:
                    pass
            
            # Recursively process children
            if isinstance(val, (dict, list)):
                jitter_location_dict(val)
    elif isinstance(o, list):
        for i in o:
            jitter_location_dict(i)

def wash_network_env(o):
    """Recursively search for 'env' dict or specific keys and override them to emulate cellular network.
    Specifically: env.network_type -> 'cellular', env.mcc_mnc -> '450_08'"""
    if isinstance(o, dict):
        if "env" in o and isinstance(o["env"], dict):
            env = o["env"]
            if "network_type" in env:
                env["network_type"] = "cellular"
            if "mcc_mnc" in env:
                env["mcc_mnc"] = "450_08"
        
        if "network_type" in o:
            o["network_type"] = "cellular"
        if "mcc_mnc" in o:
            o["mcc_mnc"] = "450_08"

        if "NetworkType" in o:
            o["NetworkType"] = "Cellular"
        if "Carrier" in o:
            o["Carrier"] = "KT"
        if "host" in o and isinstance(o["host"], str):
            parts = o["host"].split('.')
            if len(parts) == 4 and all(p.isdigit() for p in parts):
                o["host"] = "192.0.0.2"

        for k, v in o.items():
            wash_network_env(v)
    elif isinstance(o, list):
        for item in o:
            wash_network_env(item)

try:
    import blackboxprotobuf
    HAS_BLACKBOX = True
except ImportError:
    HAS_BLACKBOX = False

def handle_request(addon, flow: http.HTTPFlow):
    host = flow.request.pretty_host
    path = flow.request.path

    if not should_process(host, path):
        return

    path_lower = path.lower()
    log_dir = os.environ.get("CAPTURE_LOG_DIR")
    if log_dir:
        event_log_path = os.path.join(log_dir, "events.log")
        with open(event_log_path, "a", encoding="utf-8") as ef:
            ef.write(f"[URL] {path_lower}\n")

    # [V2.0.5] Capture original content for auditing before any modification
    if flow.request.content:
        if "trafficjam" in path_lower:
            raw = flow.request.content
            is_gz = raw.startswith(b'\x1f\x8b')
            work_raw = gzip.decompress(raw) if is_gz else raw
            
            orig_audit = {
                "_raw": "base64:" + base64.b64encode(work_raw).decode('ascii'),
                "_decoded": None
            }
            
            try:
                if "json" in flow.request.headers.get("Content-Type", "").lower():
                    orig_audit["_decoded"] = json.loads(work_raw.decode('utf-8', 'ignore'))
                elif HAS_BLACKBOX:
                    dec, _ = blackboxprotobuf.decode_message(work_raw)
                    orig_audit["_decoded"] = to_jsonable(dec)
            except: pass
            
            flow.request.trafficjam_original = orig_audit

    # 2. Exhaustive Identity Washing (Headers & URL)
    try:
        flow.request.url = smart_cleanse(flow.request.url)
        for k in flow.request.headers:
            old_val = flow.request.headers[k]
            new_val = smart_cleanse(old_val)
            if old_val != new_val: flow.request.headers[k] = new_val
    except: pass

    # 3. Targeted Body Washing (trafficjam/nlogapp specialized)
    if flow.request.content:
        path_lower = path.lower()
        content_type = flow.request.headers.get("Content-Type", "").lower()
        is_json = "json" in content_type
        
        try:
            if "trafficjam" in path_lower:
                # Handle trafficjam (location, log, etc.)
                raw = flow.request.content
                is_gz = raw.startswith(b'\x1f\x8b')
                if is_gz: raw = gzip.decompress(raw)
                
                modified = False
                # Try Protobuf first
                if not is_json and HAS_BLACKBOX:
                    try:
                        dec, mt = blackboxprotobuf.decode_message(raw)
                        if dec:
                            jitter_location_dict(dec)
                            # Apply identity washing
                            dec = smart_cleanse(dec)
                            wash_network_env(dec)
                            
                            # [V2.1.0] Save modified object for consistent logging
                            flow.request.modified_decoded = to_jsonable(dec)
                            
                            work = blackboxprotobuf.encode_message(dec, mt)
                            flow.request.content = bytes(gzip.compress(work) if is_gz else work)
                            modified = True
                    except: pass
                
                # Fallback to JSON or if is_json
                if not modified:
                    try:
                        body_json = json.loads(raw.decode('utf-8', 'ignore'))
                        jitter_location_dict(body_json)
                        body_json = smart_cleanse(body_json)
                        wash_network_env(body_json)
                        
                        # [V2.1.0] Save modified object for consistent logging
                        flow.request.modified_decoded = body_json
                        
                        work = json.dumps(body_json).encode('utf-8')
                        flow.request.content = bytes(gzip.compress(work) if is_gz else work)
                    except:
                        flow.request.content = smart_cleanse(flow.request.content)
                return # Important: trafficjam handled
            
            elif "nlogapp" in path_lower or "nelo" in path_lower or "nelo" in host.lower() or is_json:
                try:
                    raw = flow.request.content
                    is_gz = raw.startswith(b'\x1f\x8b')
                    if is_gz:
                        raw = gzip.decompress(raw)
                    body_json = json.loads(raw.decode('utf-8', 'ignore'))
                    body_json = smart_cleanse(body_json)
                    wash_network_env(body_json)
                    
                    work = json.dumps(body_json).encode('utf-8')
                    flow.request.content = bytes(gzip.compress(work) if is_gz else work)
                    
                    # [V2.1.6] Extract events in bulk to a flat timeline immediately
                    evts = body_json.get("evts", [])
                    log_dir = os.environ.get("CAPTURE_LOG_DIR")
                    if evts and isinstance(evts, list) and log_dir:
                        event_log_path = os.path.join(log_dir, "events.log")
                        with open(event_log_path, "a", encoding="utf-8") as ef:
                            for e in evts:
                                t = e.get("type", "unknown")
                                s = e.get("screen_name") or e.get("act_act") or (e.get("act_oval", {}).get("tab") if isinstance(e.get("act_oval"), dict) else None) or "none"
                                ef.write(f"[{t}] {s}\n")
                except:
                    flow.request.content = smart_cleanse(flow.request.content)
            else:
                # Non-target: Simple byte wash for performance
                flow.request.content = smart_cleanse(flow.request.content)
        except: pass
