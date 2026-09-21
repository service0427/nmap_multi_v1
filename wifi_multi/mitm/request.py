import os
import json
import random
import gzip
import base64
import re
from mitmproxy import http
from .whitelist import should_process

IDENTITY_MAP = {}
IDENTITY_MAP_BYTES = {}

def register_identity(orig_val, spoof_val):
    """Register identity mapping with case variations, hyphen variations, and raw byte representations."""
    if not orig_val or not spoof_val:
        return
    orig_str = str(orig_val).strip()
    spoof_str = str(spoof_val).strip()
    if len(orig_str) <= 3 or orig_str == spoof_str:
        return

    # 1. Exact string & case variations
    IDENTITY_MAP[orig_str] = spoof_str
    IDENTITY_MAP[orig_str.lower()] = spoof_str.lower()
    IDENTITY_MAP[orig_str.upper()] = spoof_str.upper()

    # 2. Hyphen variations (for UUIDs like ADID, IDFV)
    if "-" in orig_str or "-" in spoof_str:
        orig_clean = orig_str.replace("-", "")
        spoof_clean = spoof_str.replace("-", "")
        IDENTITY_MAP[orig_clean] = spoof_clean
        IDENTITY_MAP[orig_clean.lower()] = spoof_clean.lower()
        IDENTITY_MAP[orig_clean.upper()] = spoof_clean.upper()

    # 3. Raw hex bytes (for 32-char hex like NI or 16-char hex like SSAID)
    if len(orig_str) in [16, 32] and all(c in "0123456789abcdefABCDEF" for c in orig_str):
        try:
            b_orig = bytes.fromhex(orig_str)
            b_spoof = bytes.fromhex(spoof_str)
            IDENTITY_MAP_BYTES[b_orig] = b_spoof
        except Exception:
            pass

# Initialize from environment variables
pairs = [
    ("NMAP_ORIG_SSAID", "NMAP_ID_SSAID"),
    ("NMAP_ORIG_ADID", "NMAP_ID_ADID"),
    ("NMAP_ORIG_NI", "NMAP_ID_NI"),
    ("NMAP_ORIG_IDFV", "NMAP_ID_IDFV"),
    ("NMAP_ORIG_TOKEN", "NMAP_ID_TOKEN")
]
for orig_key, spoof_key in pairs:
    o, s = os.environ.get(orig_key), os.environ.get(spoof_key)
    if o and s:
        register_identity(o, s)

# [DEBUG] Check Identity Map
print(f"[*] IDENTITY_MAP Loaded: {len(IDENTITY_MAP)} entries, {len(IDENTITY_MAP_BYTES)} byte entries", flush=True)
for k, v in list(IDENTITY_MAP.items())[:6]:
    print(f"    - Mapping: {k[:6]}... -> {v[:6]}...", flush=True)

SESSION_STORAGE_OFFSET = random.randint(-500000000, 500000000)
SESSION_BOOT_OFFSET_MS = random.randint(300000, 86400000)
SESSION_INSTALL_OFFSET_SEC = random.randint(86400, 604800)
# [V2.1.7] App initialization timestamp offset (Install + 60~600s jitter)
SESSION_INIT_OFFSET_MS = (SESSION_INSTALL_OFFSET_SEC * 1000) - random.randint(60000, 600000)

def smart_cleanse(obj):
    """Recursive identity washing using simple string/byte replacement.
    [V2.0.9] Improved to prevent data structure corruption by checking ID length.
    [V2.1.8] Auto-synthesizes realistic time values if pm clear resets them to 0."""
    import time
    current_ms = int(time.time() * 1000)
    
    if isinstance(obj, dict):
        # pm clear로 0 또는 비정상 범위의 작은 값이 유입된 경우 10~30일 전 타임스탬프로 위조 복원
        def get_safe_init_ts(val):
            if val < 100000000000: # 13자리 밀리초가 아닌 비정상 범위(0 등)
                import random
                return current_ms - random.randint(864000000, 2592000000)
            return val

        def get_safe_install_ts(val):
            if val < 100000000: # 10자리 초 단위가 아닌 비정상 범위(0 등)
                import random
                return int(time.time()) - random.randint(86400, 2592000)
            return val

        return {k: (v + SESSION_STORAGE_OFFSET if k == "storage_size" and isinstance(v, (int, float)) else 
                   (v - SESSION_BOOT_OFFSET_MS if k == "last_boot_ts" and isinstance(v, (int, float)) else 
                   (get_safe_install_ts(v) - SESSION_INSTALL_OFFSET_SEC if k == "install_ts" and isinstance(v, (int, float)) else 
                   (get_safe_init_ts(v) - SESSION_INIT_OFFSET_MS if k == "init_ts" and isinstance(v, (int, float)) else smart_cleanse(v))))) 
                for k, v in obj.items()}
    elif isinstance(obj, list): return [smart_cleanse(i) for i in obj]
    elif isinstance(obj, str):
        for real, fake in IDENTITY_MAP.items():
            if len(real) > 5 and real in obj:
                obj = obj.replace(real, fake)
                print(f"[🛡️ CLEANSE] Replaced {real[:4]}... with {fake[:4]}...", flush=True)
        return obj
    elif isinstance(obj, (bytes, bytearray)):
        b = bytes(obj)
        for real_b, fake_b in IDENTITY_MAP_BYTES.items():
            if real_b in b:
                b = b.replace(real_b, fake_b)
        for real, fake in IDENTITY_MAP.items():
            if len(real) > 5:
                real_b, fake_b = real.encode('utf-8'), fake.encode('utf-8')
                if real_b in b:
                    b = b.replace(real_b, fake_b)
        return b if isinstance(obj, bytes) else bytearray(b)
    return obj

def to_jsonable(d):
    """Deep convert to JSON-safe structure. [V2.0.9]"""
    if isinstance(d, dict): return {str(k): to_jsonable(v) for k, v in d.items()}
    elif isinstance(d, list): return [to_jsonable(v) for v in d]
    elif isinstance(d, (bytes, bytearray)):
        try: return d.decode('utf-8')
        except: return f"hex:{bytes(d).hex()}"
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

    # [V2.0.5] Capture original content for auditing before any modification (except large driving routes)
    if flow.request.content and "driving" not in path_lower:
        raw = flow.request.content
        is_gz = raw.startswith(b'\x1f\x8b')
        try:
            work_raw = gzip.decompress(raw) if is_gz else raw
        except Exception:
            work_raw = raw
        
        orig_audit = {
            "_raw": "base64:" + base64.b64encode(work_raw).decode('ascii'),
            "_decoded": None
        }
        
        try:
            ct = flow.request.headers.get("Content-Type", "").lower()
            if "json" in ct:
                orig_audit["_decoded"] = json.loads(work_raw.decode('utf-8', 'ignore'))
            elif HAS_BLACKBOX:
                dec, _ = blackboxprotobuf.decode_message(work_raw)
                orig_audit["_decoded"] = to_jsonable(dec)
        except Exception:
            pass
        
        flow.request.trafficjam_original = orig_audit

    # Target identity credentials
    target_ni = os.environ.get("NMAP_ID_NI")
    target_adid = os.environ.get("NMAP_ID_ADID")
    target_idfv = os.environ.get("NMAP_ID_IDFV")
    target_ssaid = os.environ.get("NMAP_ID_SSAID")

    # 2. Exhaustive Header Hardening & Dynamic Identity Learning
    try:
        for k in list(flow.request.headers.keys()):
            kl = k.lower()
            val = flow.request.headers[k]
            
            if kl in ["uuid", "device-id"]:
                if target_ni and len(val) >= 16:
                    if val != target_ni and val not in IDENTITY_MAP:
                        register_identity(val, target_ni)
                        print(f"[*] Dynamically registered NI from header {k}: {val[:6]}... -> {target_ni[:6]}...", flush=True)
                    flow.request.headers[k] = target_ni
                    
            elif kl in ["x-adid", "da-dd"]:
                if target_adid and len(val) >= 16:
                    if val != target_adid and val not in IDENTITY_MAP:
                        register_identity(val, target_adid)
                        print(f"[*] Dynamically registered ADID from header {k}: {val[:6]}... -> {target_adid[:6]}...", flush=True)
                    flow.request.headers[k] = target_adid
                    
            elif kl in ["da-dv"]:
                if target_idfv and len(val) >= 16:
                    if val != target_idfv and val not in IDENTITY_MAP:
                        register_identity(val, target_idfv)
                        print(f"[*] Dynamically registered IDFV from header {k}: {val[:6]}... -> {target_idfv[:6]}...", flush=True)
                    flow.request.headers[k] = target_idfv
                    
            elif kl == "cookie":
                if target_ni and "NAPP_DI=" in val:
                    m = re.search(r'NAPP_DI=([a-fA-F0-9]{16,32})', val)
                    if m:
                        old_napp = m.group(1)
                        if old_napp != target_ni and old_napp not in IDENTITY_MAP:
                            register_identity(old_napp, target_ni)
                    flow.request.headers[k] = re.sub(r'NAPP_DI=[a-fA-F0-9]{16,32}', f'NAPP_DI={target_ni}', val)

        # URL Query Parameter Hardening & Dynamic Learning
        if target_ni and "device_id=" in flow.request.url:
            m = re.search(r'[?&]device_id=([a-fA-F0-9]{16,32})', flow.request.url)
            if m and m.group(1) != target_ni:
                register_identity(m.group(1), target_ni)
            flow.request.url = re.sub(r'([?&]device_id=)[a-fA-F0-9]{16,32}', f'\\g<1>{target_ni}', flow.request.url)

        if target_adid and "ai=" in flow.request.url:
            m = re.search(r'[?&]ai=([a-fA-F0-9-]{32,36})', flow.request.url)
            if m and m.group(1) != target_adid:
                register_identity(m.group(1), target_adid)
            flow.request.url = re.sub(r'([?&]ai=)[a-fA-F0-9-]{32,36}', f'\\g<1>{target_adid}', flow.request.url)

        if target_idfv and "iv=" in flow.request.url:
            m = re.search(r'[?&]iv=([a-fA-F0-9-]{32,36})', flow.request.url)
            if m and m.group(1) != target_idfv:
                register_identity(m.group(1), target_idfv)
            flow.request.url = re.sub(r'([?&]iv=)[a-fA-F0-9-]{32,36}', f'\\g<1>{target_idfv}', flow.request.url)

        # General recursive string cleanse on URL and remaining headers
        flow.request.url = smart_cleanse(flow.request.url)
        for k in list(flow.request.headers.keys()):
            old_val = flow.request.headers[k]
            new_val = smart_cleanse(old_val)
            if old_val != new_val:
                flow.request.headers[k] = new_val
    except Exception as e:
        print(f"[-] Error in header/URL washing: {e}", flush=True)

    # 3. Universal Body Washing (Gzip Decompress -> Parse/Decode -> Active Overwrite & Wash -> Encode -> Re-compress)
    if flow.request.content:
        raw = flow.request.content
        is_gz = raw.startswith(b'\x1f\x8b')
        if is_gz:
            try:
                raw = gzip.decompress(raw)
            except Exception:
                pass
        
        content_type = flow.request.headers.get("Content-Type", "").lower()
        is_json = "json" in content_type
        is_pb_target = ("trafficjam" in path_lower or "receiver" in path_lower or 
                        "log-receiver" in host.lower() or "protobuf" in content_type or 
                        "octet-stream" in content_type)

        try:
            # A. Protobuf Processing
            if not is_json and (is_pb_target or HAS_BLACKBOX):
                pb_handled = False
                if HAS_BLACKBOX:
                    try:
                        dec, mt = blackboxprotobuf.decode_message(raw)
                        if dec and isinstance(dec, dict):
                            # Active NI replacement in known Protobuf fields & dynamic learning
                            if "1" in dec and isinstance(dec["1"], dict):
                                # Field 1.1: trafficjam location
                                if "1" in dec["1"]:
                                    f1 = dec["1"]["1"]
                                    f1_str = f1.decode('utf-8', 'ignore') if isinstance(f1, (bytes, bytearray)) else str(f1)
                                    if len(f1_str) >= 16 and target_ni:
                                        if f1_str != target_ni:
                                            register_identity(f1_str, target_ni)
                                            print(f"[*] Dynamically registered NI from Protobuf 1.1: {f1_str[:6]}... -> {target_ni[:6]}...", flush=True)
                                        dec["1"]["1"] = target_ni.encode('utf-8') if isinstance(f1, (bytes, bytearray)) else target_ni

                                # Field 1.3: receiver log / trafficjam log
                                if "3" in dec["1"]:
                                    f3 = dec["1"]["3"]
                                    f3_str = f3.decode('utf-8', 'ignore') if isinstance(f3, (bytes, bytearray)) else str(f3)
                                    if len(f3_str) >= 16 and target_ni:
                                        if f3_str != target_ni:
                                            register_identity(f3_str, target_ni)
                                            print(f"[*] Dynamically registered NI from Protobuf 1.3: {f3_str[:6]}... -> {target_ni[:6]}...", flush=True)
                                        dec["1"]["3"] = target_ni.encode('utf-8') if isinstance(f3, (bytes, bytearray)) else target_ni

                            # Location jittering
                            if "trafficjam" in path_lower or "location" in path_lower:
                                jitter_location_dict(dec)

                            # Recursive wash & network emulation
                            dec = smart_cleanse(dec)
                            wash_network_env(dec)

                            flow.request.modified_decoded = to_jsonable(dec)
                            work = blackboxprotobuf.encode_message(dec, mt)
                            flow.request.content = bytes(gzip.compress(work) if is_gz else work)
                            pb_handled = True
                    except Exception:
                        pass
                
                if pb_handled:
                    return

            # B. JSON Processing (nlog, nelo, graphql, etc.)
            if is_json or "nlog" in path_lower or "nelo" in path_lower:
                json_handled = False
                try:
                    body_json = json.loads(raw.decode('utf-8', 'ignore'))
                    
                    # Dynamic identity registration from usr dict & missing-key enforcement
                    if "usr" in body_json and isinstance(body_json["usr"], dict):
                        for k, target_val in [("adid", target_adid), ("ssaid", target_ssaid), ("idfv", target_idfv), ("ni", target_ni)]:
                            cur_val = body_json["usr"].get(k)
                            if cur_val and target_val and len(cur_val) > 3:
                                if cur_val != target_val:
                                    register_identity(cur_val, target_val)
                                    print(f"[*] Dynamically registered identity: {k} {cur_val[:6]}... -> {target_val[:6]}...", flush=True)
                                body_json["usr"][k] = target_val
                            elif target_val:
                                # Ensure missing keys exist so monitor.sh verification passes
                                body_json["usr"][k] = target_val

                    body_json = smart_cleanse(body_json)
                    wash_network_env(body_json)
                    
                    flow.request.modified_decoded = body_json
                    work = json.dumps(body_json, ensure_ascii=False).encode('utf-8')
                    flow.request.content = bytes(gzip.compress(work) if is_gz else work)
                    json_handled = True

                    # Extract events in bulk to a flat timeline
                    evts = body_json.get("evts", [])
                    if evts and isinstance(evts, list) and log_dir:
                        event_log_path = os.path.join(log_dir, "events.log")
                        with open(event_log_path, "a", encoding="utf-8") as ef:
                            for e in evts:
                                t = e.get("type", "unknown")
                                s = e.get("screen_name") or e.get("act_act") or (e.get("act_oval", {}).get("tab") if isinstance(e.get("act_oval"), dict) else None) or "none"
                                ef.write(f"[{t}] {s}\n")
                except Exception:
                    pass
                
                if json_handled:
                    return

            # C. Non-target / Fallback Payload Washing (Decompressed first!)
            try:
                cleansed_raw = smart_cleanse(raw)
                flow.request.content = bytes(gzip.compress(cleansed_raw) if is_gz else cleansed_raw)
            except Exception:
                flow.request.content = smart_cleanse(flow.request.content)
        except Exception as err:
            print(f"[-] Error in body washing: {err}", flush=True)
