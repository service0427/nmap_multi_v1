import os
import json
import random
import gzip
import base64
import re
from mitmproxy import http
from .whitelist import should_process
from .rules import AUDIT_LOGGER, find_matching_rules, get_target_identities
from .dynamic_tree_replacer import IdentityLookup, dynamic_walk_and_replace, dynamic_replace_headers, dynamic_replace_url_query

IDENTITY_MAP = {}
IDENTITY_MAP_BYTES = {}

def register_identity(orig_val, spoof_val):
    """Register identity mapping with case variations and raw byte representations (No hyphen stripping)."""
    if not orig_val or not spoof_val:
        return
    if not isinstance(orig_val, (str, bytes, bytearray)) or not isinstance(spoof_val, (str, bytes, bytearray)):
        return
    orig_str = orig_val.decode('utf-8', 'ignore').strip() if isinstance(orig_val, (bytes, bytearray)) else str(orig_val).strip()
    spoof_str = spoof_val.decode('utf-8', 'ignore').strip() if isinstance(spoof_val, (bytes, bytearray)) else str(spoof_val).strip()
    if len(orig_str) <= 3 or orig_str == spoof_str:
        return

    # 1. Exact string & case variations
    IDENTITY_MAP[orig_str] = spoof_str
    IDENTITY_MAP[orig_str.lower()] = spoof_str.lower()
    IDENTITY_MAP[orig_str.upper()] = spoof_str.upper()

    # 2. Raw hex bytes (for 32-char hex like NI or 16-char hex like SSAID)
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

def smart_cleanse(obj, url=""):
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
                   (get_safe_init_ts(v) - SESSION_INIT_OFFSET_MS if k == "init_ts" and isinstance(v, (int, float)) else smart_cleanse(v, url))))) 
                for k, v in obj.items()}
    elif isinstance(obj, list): return [smart_cleanse(i, url) for i in obj]
    elif isinstance(obj, str):
        for real, fake in IDENTITY_MAP.items():
            if len(real) > 5 and real in obj:
                obj = obj.replace(real, fake)
                AUDIT_LOGGER.record(url or "payload", "smart_cleanse", "string_replace", "payload_string", real, fake)
                print(f"[🛡️ CLEANSE] Replaced {real[:4]}... with {fake[:4]}...", flush=True)
        return obj
    elif isinstance(obj, (bytes, bytearray)):
        b = bytes(obj)
        for real_b, fake_b in IDENTITY_MAP_BYTES.items():
            if real_b in b:
                b = b.replace(real_b, fake_b)
                AUDIT_LOGGER.record(url or "payload", "smart_cleanse", "bytes_replace", "payload_bytes", real_b.hex()[:8], fake_b.hex()[:8])
        for real, fake in IDENTITY_MAP.items():
            if len(real) > 5:
                real_b, fake_b = real.encode('utf-8'), fake.encode('utf-8')
                if real_b in b:
                    b = b.replace(real_b, fake_b)
                    AUDIT_LOGGER.record(url or "payload", "smart_cleanse", "string_in_bytes", "payload_bytes", real, fake)
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
        
        orig_ct = flow.request.headers.get("Content-Type", "").lower()
        orig_ce = flow.request.headers.get("Content-Encoding", "").lower()
        if is_gz or "gzip" in orig_ce:
            orig_encoding = "gzip"
        elif "json" in orig_ct:
            orig_encoding = "json"
        elif "protobuf" in orig_ct or "octet-stream" in orig_ct or b"\x00" in raw:
            orig_encoding = "protobuf"
        elif "urlencoded" in orig_ct:
            orig_encoding = "form-urlencoded"
        else:
            orig_encoding = "raw"

        orig_audit = {
            "_encoding": orig_encoding,
            "_raw": "base64:" + base64.b64encode(work_raw).decode('ascii'),
            "_decoded": None
        }
        
        try:
            ct = flow.request.headers.get("Content-Type", "").lower()
            work_str = None
            try:
                work_str = work_raw.decode('utf-8')
            except Exception:
                pass

            # 1. Try JSON if content-type has json or text begins with { or [
            if "json" in ct or (work_str and (work_str.strip().startswith('{') or work_str.strip().startswith('['))):
                try:
                    orig_audit["_decoded"] = json.loads(work_str if work_str else work_raw.decode('utf-8', 'ignore'))
                    if orig_audit["_encoding"] == "raw":
                        orig_audit["_encoding"] = "json"
                except Exception:
                    pass

            # 2. Try Protobuf if not already decoded and looks like protobuf/binary
            if orig_audit["_decoded"] is None and HAS_BLACKBOX and ("protobuf" in ct or "octet-stream" in ct or b"\x00" in work_raw):
                try:
                    dec, _ = blackboxprotobuf.decode_message(work_raw)
                    orig_audit["_decoded"] = to_jsonable(dec)
                    orig_audit["_encoding"] = "protobuf"
                except Exception:
                    pass

            # 3. Fallback to readable string if UTF-8
            if orig_audit["_decoded"] is None and work_str:
                orig_audit["_decoded"] = work_str
        except Exception:
            pass
        
        flow.request.trafficjam_original = orig_audit

    # Target identity credentials
    target_ids = get_target_identities()
    target_ni = target_ids.get("ni")
    target_adid = target_ids.get("adid")
    target_idfv = target_ids.get("idfv")
    target_ssaid = target_ids.get("ssaid")
    target_token = target_ids.get("token")

    # Dynamic 1:1 Identity Lookup Table
    dynamic_lookup = IdentityLookup(target_ids)

    # Match declarative rules for this URL endpoint
    matching_rules = find_matching_rules(path)
    all_protected_query = set()
    all_protected_headers = set()
    for r in matching_rules:
        if "protected_query" in r:
            all_protected_query.update(r["protected_query"])
        if "protected_headers" in r:
            all_protected_headers.update(r["protected_headers"])

    # 2. Declarative Header & Query Parameter Hardening with Audit Logging
    try:
        # A. Apply header rules from matching rules
        for r in matching_rules:
            header_rules = r.get("headers", {})
            for h_rule_key, id_type in header_rules.items():
                for real_h_key in list(flow.request.headers.keys()):
                    if real_h_key.lower() == h_rule_key.lower():
                        if real_h_key.lower() in all_protected_headers:
                            continue
                        target_val = target_ids.get(id_type)
                        if target_val:
                            val = flow.request.headers[real_h_key]
                            if val != target_val:
                                AUDIT_LOGGER.record(flow.request.url, r["name"], "header", real_h_key, val, target_val)
                                flow.request.headers[real_h_key] = target_val

            # Cookie rules
            cookie_rules = r.get("cookie_keys", {})
            if "cookie" in flow.request.headers:
                cookie_val = flow.request.headers["cookie"]
                for c_key, id_type in cookie_rules.items():
                    target_val = target_ids.get(id_type)
                    if target_val and f"{c_key}=" in cookie_val:
                        m = re.search(rf'{re.escape(c_key)}=([a-fA-F0-9]{{16,64}})', cookie_val)
                        if m:
                            old_c_val = m.group(1)
                            if old_c_val != target_val:
                                AUDIT_LOGGER.record(flow.request.url, r["name"], "cookie", c_key, old_c_val, target_val)
                                cookie_val = cookie_val.replace(f"{c_key}={old_c_val}", f"{c_key}={target_val}")
                                flow.request.headers["cookie"] = cookie_val

        # B. Apply URL query parameter rules (strictly respecting protected_query)
        for r in matching_rules:
            query_rules = r.get("query_params", {})
            for q_param, id_type in query_rules.items():
                if q_param.lower() in all_protected_query:
                    continue
                target_val = target_ids.get(id_type)
                if not target_val:
                    continue
                pattern = rf'([?&]{re.escape(q_param)}=)([^&]+)'
                while True:
                    m = re.search(pattern, flow.request.url)
                    if not m:
                        break
                    old_q_val = m.group(2)
                    if old_q_val == target_val:
                        break
                    AUDIT_LOGGER.record(flow.request.url, r["name"], "query_param", q_param, old_q_val, target_val)
                    flow.request.url = flow.request.url[:m.start(2)] + target_val + flow.request.url[m.end(2):]

        # C. For remaining non-protected headers, apply smart_cleanse
        for k in list(flow.request.headers.keys()):
            if k.lower() in all_protected_headers or k.lower() in ["authorization", "host", "content-length", "content-type", "accept-encoding", "cookie"]:
                continue
            old_val = flow.request.headers[k]
            new_val = smart_cleanse(old_val, flow.request.url)
            if old_val != new_val:
                flow.request.headers[k] = new_val

        # D. Cleanse remaining URL query parameters using IDENTITY_MAP for non-protected parameters
        if "?" in flow.request.url:
            base_part, query_part = flow.request.url.split("?", 1)
            q_items = query_part.split("&")
            modified_q = False
            new_q_items = []
            for item in q_items:
                if "=" in item:
                    qk, qv = item.split("=", 1)
                    if qk.lower() not in all_protected_query:
                        new_qv = smart_cleanse(qv, flow.request.url)
                        if new_qv != qv:
                            modified_q = True
                            item = f"{qk}={new_qv}"
                new_q_items.append(item)
            if modified_q:
                flow.request.url = f"{base_part}?{'&'.join(new_q_items)}"

        # E. Universal Dynamic Header & Query Replacement (1:1 Value Match)
        dynamic_replace_headers(flow.request.headers, dynamic_lookup, flow.request.url, AUDIT_LOGGER, all_protected_headers)
        flow.request.url = dynamic_replace_url_query(flow.request.url, dynamic_lookup, AUDIT_LOGGER, all_protected_query)
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
                            is_trafficjam = ("trafficjam" in path_lower or "location" in path_lower)
                            is_receiver = ("receiver" in path_lower or "log-receiver" in host.lower())

                            # Active NI replacement in known Protobuf fields & dynamic learning
                            if (is_trafficjam or is_receiver) and "1" in dec and isinstance(dec["1"], dict):
                                # 1. Trafficjam location: Field 1.1 is NI
                                if is_trafficjam and "1" in dec["1"]:
                                    f1 = dec["1"]["1"]
                                    if isinstance(f1, (bytes, bytearray, str)):
                                        f1_str = f1.decode('utf-8', 'ignore') if isinstance(f1, (bytes, bytearray)) else f1
                                        if target_ni and f1_str != target_ni:
                                            AUDIT_LOGGER.record(flow.request.url, "trafficjam_location", "protobuf", "1.1 (device_id)", f1_str, target_ni)
                                            dec["1"]["1"] = target_ni.encode('utf-8') if isinstance(f1, (bytes, bytearray)) else target_ni

                                # 2. Receiver log: Field 1.1 is caller (PRESERVED), Field 1.3 is NI
                                if is_receiver and "3" in dec["1"]:
                                    f3 = dec["1"]["3"]
                                    if isinstance(f3, (bytes, bytearray, str)):
                                        f3_str = f3.decode('utf-8', 'ignore') if isinstance(f3, (bytes, bytearray)) else f3
                                        if target_ni and f3_str != target_ni:
                                            AUDIT_LOGGER.record(flow.request.url, "receiver_log", "protobuf", "1.3 (device_id)", f3_str, target_ni)
                                            dec["1"]["3"] = target_ni.encode('utf-8') if isinstance(f3, (bytes, bytearray)) else target_ni

                            # Location jittering
                            if "trafficjam" in path_lower or "location" in path_lower:
                                jitter_location_dict(dec)

                            # Receiver log caller backup to prevent any corruption
                            caller_backup = None
                            if is_receiver and "1" in dec and isinstance(dec["1"], dict) and "1" in dec["1"]:
                                caller_backup = dec["1"]["1"]

                            # Recursive wash & network emulation
                            dec = smart_cleanse(dec, flow.request.url)
                            dynamic_walk_and_replace(dec, dynamic_lookup, "pbf", flow.request.url, AUDIT_LOGGER)
                            if caller_backup is not None and is_receiver and "1" in dec and isinstance(dec["1"], dict):
                                dec["1"]["1"] = caller_backup

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
                    rule_name = "nlogapp" if "nlog" in path_lower else "json_body"
                    
                    # 1:1 identity replacement from usr dict (pure substitution: ONLY replace existing keys)
                    if "usr" in body_json and isinstance(body_json["usr"], dict):
                        for k, target_val in [("adid", target_adid), ("ssaid", target_ssaid), ("idfv", target_idfv), ("ni", target_ni)]:
                            cur_val = body_json["usr"].get(k)
                            if cur_val and target_val:
                                if cur_val != target_val:
                                    AUDIT_LOGGER.record(flow.request.url, rule_name, "json_usr", f"usr.{k}", cur_val, target_val)
                                body_json["usr"][k] = target_val

                    # Exact 1:1 token replacement in evts nlog_id
                    orig_token = target_ids.get("orig_token")
                    if target_token and "evts" in body_json and isinstance(body_json["evts"], list):
                        for e in body_json["evts"]:
                            if isinstance(e, dict) and "nlog_id" in e and isinstance(e["nlog_id"], str):
                                nid = e["nlog_id"]
                                if orig_token and orig_token in nid:
                                    new_nid = nid.replace(orig_token, target_token)
                                    AUDIT_LOGGER.record(flow.request.url, rule_name, "json_evt", "evts[].nlog_id", orig_token, target_token)
                                    e["nlog_id"] = new_nid
                                elif "." in nid:
                                    parts = nid.rsplit(".", 1)
                                    if len(parts[-1]) >= 8 and parts[-1] != target_token:
                                        new_nid = f"{parts[0]}.{target_token}"
                                        AUDIT_LOGGER.record(flow.request.url, rule_name, "json_evt", "evts[].nlog_id", parts[-1], target_token)
                                        e["nlog_id"] = new_nid

                    body_json = smart_cleanse(body_json, flow.request.url)
                    dynamic_walk_and_replace(body_json, dynamic_lookup, "body", flow.request.url, AUDIT_LOGGER)
                    wash_network_env(body_json)
                    
                    flow.request.modified_decoded = body_json
                    work = json.dumps(body_json, separators=(',', ':'), ensure_ascii=False).encode('utf-8')
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
                cleansed_raw = smart_cleanse(raw, flow.request.url)
                cleansed_raw, _, _, _ = dynamic_lookup.replace_value(cleansed_raw)
                flow.request.content = bytes(gzip.compress(cleansed_raw) if is_gz else cleansed_raw)
            except Exception:
                flow.request.content = smart_cleanse(flow.request.content, flow.request.url)
        except Exception as err:
            print(f"[-] Error in body washing: {err}", flush=True)
