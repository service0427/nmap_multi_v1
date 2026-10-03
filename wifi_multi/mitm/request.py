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
SESSION_LEARNED_IDENTITIES = {}

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

def dynamic_auto_learn_identities(flow: http.HTTPFlow, lookup: IdentityLookup, target_ids: dict, logger=None):
    """Dynamically auto-learns client original identities when server api_response credentials are stale or mismatched."""
    if not flow or not lookup or not target_ids:
        return

    # 1. Direct header identity carriers
    h = flow.request.headers
    target_idfv = target_ids.get("idfv")
    if target_idfv and "da-dv" in h:
        val = h.get("da-dv")
        if val and val != target_idfv and len(val) > 3:
            lookup.register(val, target_idfv)
            SESSION_LEARNED_IDENTITIES[val] = target_idfv
            register_identity(val, target_idfv)
            h["da-dv"] = target_idfv
            if logger:
                logger.record(flow.request.url, "autodiscover", "header", "da-dv", val, target_idfv)

    target_adid = target_ids.get("adid")
    if target_adid:
        for hk in ["da-dd", "x-adid"]:
            if hk in h:
                val = h.get(hk)
                if val and val != target_adid and len(val) > 3:
                    lookup.register(val, target_adid)
                    SESSION_LEARNED_IDENTITIES[val] = target_adid
                    register_identity(val, target_adid)
                    h[hk] = target_adid
                    if logger:
                        logger.record(flow.request.url, "autodiscover", "header", hk, val, target_adid)

    # 2. Direct query parameter identity carriers
    if target_idfv and "iv" in flow.request.query:
        val = flow.request.query.get("iv")
        if val and val != target_idfv and len(val) > 3:
            lookup.register(val, target_idfv)
            SESSION_LEARNED_IDENTITIES[val] = target_idfv
            register_identity(val, target_idfv)
            flow.request.query["iv"] = target_idfv
            if logger:
                logger.record(flow.request.url, "autodiscover", "query", "iv", val, target_idfv)

    if target_adid and "ai" in flow.request.query:
        val = flow.request.query.get("ai")
        if val and val != target_adid and len(val) > 3:
            lookup.register(val, target_adid)
            SESSION_LEARNED_IDENTITIES[val] = target_adid
            register_identity(val, target_adid)
            flow.request.query["ai"] = target_adid
            if logger:
                logger.record(flow.request.url, "autodiscover", "query", "ai", val, target_adid)

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

def synthesize_session_timestamps(obj):
    """Auto-synthesizes realistic time values if pm clear resets them to 0."""
    import time
    current_ms = int(time.time() * 1000)
    
    if isinstance(obj, dict):
        def get_safe_init_ts(val):
            if val < 100000000000:
                return current_ms - random.randint(864000000, 2592000000)
            return val

        def get_safe_install_ts(val):
            if val < 100000000:
                return int(time.time()) - random.randint(86400, 2592000)
            return val

        return {k: (v + SESSION_STORAGE_OFFSET if k == "storage_size" and isinstance(v, (int, float)) else 
                   (v - SESSION_BOOT_OFFSET_MS if k == "last_boot_ts" and isinstance(v, (int, float)) else 
                   (get_safe_install_ts(v) - SESSION_INSTALL_OFFSET_SEC if k == "install_ts" and isinstance(v, (int, float)) else 
                   (get_safe_init_ts(v) - SESSION_INIT_OFFSET_MS if k == "init_ts" and isinstance(v, (int, float)) else synthesize_session_timestamps(v))))) 
                for k, v in obj.items()}
    elif isinstance(obj, list):
        return [synthesize_session_timestamps(i) for i in obj]
    return obj

smart_cleanse = synthesize_session_timestamps

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

    # 1. Target identity credentials & Dynamic Lookup
    target_ids = get_target_identities()
    dynamic_lookup = IdentityLookup(target_ids)
    for orig_v, spoof_v in SESSION_LEARNED_IDENTITIES.items():
        dynamic_lookup.register(orig_v, spoof_v)

    # Auto-learn and align direct identity transport carriers (da-dv, da-dd, iv, ai)
    dynamic_auto_learn_identities(flow, dynamic_lookup, target_ids, AUDIT_LOGGER)

    # Protected query params and headers that must never be altered
    all_protected_query = {"caller", "x-hmac-md", "timestamp"}
    all_protected_headers = {"caller", "x-hmac-md"}

    # 2. Universal Dynamic Header & Query Parameter Replacement (Single Module)
    try:
        dynamic_replace_headers(flow.request.headers, dynamic_lookup, flow.request.url, AUDIT_LOGGER, all_protected_headers)
        flow.request.url = dynamic_replace_url_query(flow.request.url, dynamic_lookup, AUDIT_LOGGER, all_protected_query)
    except Exception as e:
        print(f"[-] Error in header/URL washing: {e}", flush=True)

    # 3. Universal Body Washing (Gzip Decompress -> Parse/Decode -> Dynamic Walk -> Encode -> Re-compress)
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
                            # Location jittering (WiFi blanking & speed/bearing jitter)
                            if "trafficjam" in path_lower or "location" in path_lower:
                                jitter_location_dict(dec)

                            # Dynamic 1:1 tree replacement across entire Protobuf message
                            dynamic_walk_and_replace(dec, dynamic_lookup, "pbf", flow.request.url, AUDIT_LOGGER)

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
                    body_json = synthesize_session_timestamps(body_json)

                    # Auto-learn from JSON usr dictionary (nlogapp, etc.)
                    usr = body_json.get("usr")
                    if isinstance(usr, dict):
                        for k, target_k in [("idfv", "idfv"), ("adid", "adid"), ("ssaid", "ssaid"), ("ni", "ni")]:
                            cur_val = usr.get(k)
                            target_val = target_ids.get(target_k)
                            if cur_val and target_val and cur_val != target_val and len(cur_val) > 3:
                                if cur_val not in dynamic_lookup.exact_map:
                                    dynamic_lookup.register(cur_val, target_val)
                                    SESSION_LEARNED_IDENTITIES[cur_val] = target_val
                                    register_identity(cur_val, target_val)

                    # Dynamic 1:1 tree replacement across entire JSON tree
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

            # C. Non-target / Fallback Payload Washing
            try:
                cleansed_raw, _, _, _ = dynamic_lookup.replace_value(raw)
                flow.request.content = bytes(gzip.compress(cleansed_raw) if is_gz else cleansed_raw)
            except Exception:
                pass
        except Exception as err:
            print(f"[-] Error in body washing: {err}", flush=True)
