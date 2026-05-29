import json
import os
import datetime
import random
import threading
import base64
import re
from mitmproxy import http

# [NEW] Protobuf Decoding Support
try:
    import blackboxprotobuf
    HAS_BLACKBOX = True
    print("[✓] blackboxprotobuf detected.")
except ImportError:
    HAS_BLACKBOX = False
    print("[!] blackboxprotobuf NOT FOUND. Protobuf washing limited.")

class ProxyCoreWash:
    def __init__(self):
        self.lock = threading.Lock()
        self.counter = 0
        
        self.base_log_dir = os.environ.get("CAPTURE_LOG_DIR")
        if not self.base_log_dir:
            self.base_log_dir = os.path.join("logs", datetime.datetime.now().strftime("%Y%m%d/%H%M%S"))
        os.makedirs(self.base_log_dir, exist_ok=True)
        print(f"[*] Core Proxy Logging to: {self.base_log_dir}")
        self.all_packets_path = os.path.join(self.base_log_dir, "all_packets.jsonl")

        # Telemetry Offsets
        self.session_storage_offset = random.randint(-1024 * 1024 * 500, 1024 * 1024 * 500)
        self.session_boot_offset_ms = random.randint(1000 * 60 * 5, 1000 * 60 * 60 * 24)
        self.session_install_offset_sec = random.randint(3600 * 24, 3600 * 24 * 7)

        self.NOISE_PATHS = ["/font/sdf/", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".woff", ".ttf", ".zip", ".mvt", ".wav", ".js"]
        self.NOISE_HOSTS = ["facebook.com", "tivan.naver.com", "pstatic.net", "gstatic.com", "veta.naver.com", "ad.naver.com", "clova.ai"]

    def request(self, flow: http.HTTPFlow):
        # 1. [CRITICAL] TTS ExoPlayer Block
        if "api/v1/synthesize" in flow.request.path:
            flow.response = http.Response.make(500, b"TTS Blocked to prevent MediaCodec SIGBUS", {"Content-Type": "text/plain"})
            print(f"[🛡️] TTS EXOPLAYER BLOCKED: {flow.request.path[:40]}")
            return

        if os.environ.get("NMAP_NO_FILTER") == "true":
            return

        spoofed_adid = os.environ.get("NMAP_SPOOFED_ADID", "")
        is_random_mode = bool(spoofed_adid and spoofed_adid != "none")

        IDENTITY_MAP = {}
        if is_random_mode:
            IDENTITY_MAP = {
                os.environ.get("NMAP_ORIG_ADID", ""): spoofed_adid,
                os.environ.get("NMAP_ORIG_NI", ""): os.environ.get("NMAP_SPOOFED_NI", ""),
                os.environ.get("NMAP_ORIG_IDFV", ""): os.environ.get("NMAP_SPOOFED_IDFV", ""),
                os.environ.get("NMAP_ORIG_SSAID", ""): os.environ.get("NMAP_SPOOFED_SSAID", ""),
                os.environ.get("NMAP_ORIG_TOKEN", ""): os.environ.get("NMAP_SPOOFED_NLOG_TOKEN", "")
            }
            # Remove empty keys to avoid matching empty strings
            IDENTITY_MAP = {k: v for k, v in IDENTITY_MAP.items() if len(k) > 6}

        def smart_cleanse(obj, is_nlogapp=False):
            if isinstance(obj, dict):
                new_dict = {}
                for k, v in obj.items():
                    if k == "storage_size" and isinstance(v, int):
                        new_dict[k] = v + self.session_storage_offset
                    elif k == "last_boot_ts" and isinstance(v, int):
                        new_dict[k] = v - self.session_boot_offset_ms
                    elif k == "install_ts" and isinstance(v, int):
                        new_dict[k] = v - self.session_install_offset_sec
                    else:
                        new_dict[k] = smart_cleanse(v, is_nlogapp)
                return new_dict
            elif isinstance(obj, list): 
                return [smart_cleanse(i, is_nlogapp) for i in obj]
            elif isinstance(obj, str):
                for real, fake in IDENTITY_MAP.items():
                    if real in obj: obj = obj.replace(real, fake)
                return obj
            elif isinstance(obj, bytes):
                for real, fake in IDENTITY_MAP.items():
                    real_b = real.encode('utf-8')
                    fake_b = fake.encode('utf-8')
                    if real_b in obj: obj = obj.replace(real_b, fake_b)
                return obj
            return obj

        # URL and Headers Wash
        try:
            flow.request.url = smart_cleanse(flow.request.url)
            for k in flow.request.headers:
                if k.lower() == "user-agent": continue
                flow.request.headers[k] = smart_cleanse(flow.request.headers[k])
        except: pass

        # Body Wash
        if flow.request.content:
            path = flow.request.path
            host = flow.request.pretty_host
            is_nlogapp = "nlogapp" in path
            is_nelo = "nelo" in host or "nelo" in path

            try:
                content_type = flow.request.headers.get("Content-Type", "").lower()
                
                # Protobuf Deep Inspection
                if ("trafficjam" in path or "x-protobuf" in content_type) and HAS_BLACKBOX:
                    import gzip as _gzip
                    raw_data = flow.request.content
                    is_gzip = raw_data.startswith(b'\x1f\x8b')
                    if is_gzip: raw_data = _gzip.decompress(raw_data)
                    
                    decoded, msg_type = blackboxprotobuf.decode_message(raw_data)
                    if decoded:
                        washed_fields = 0
                        # [ATTACK & CLEANUP] Apply ONLY to trafficjam/location requests
                        if "trafficjam/location" in path:
                            def attack_recursive(o):
                                c = 0
                                if isinstance(o, dict):
                                    for k in list(o.keys()):
                                        # Fused(5) -> LTE(3) Provider mutation
                                        if str(k) == "1" and str(o[k]) == "5":
                                            o[k] = 3
                                            c += 1
                                        elif str(k) in ["5", "6", "7"]:
                                            if str(o[k]) in ["1065353216", "1.0", "0", "0.0"]:
                                                o[k] = int(random.randint(1080000000, 1150000000))
                                                c += 1
                                        elif isinstance(o[k], (dict, list)):
                                            c += attack_recursive(o[k])
                                elif isinstance(o, list):
                                    for i in o: c += attack_recursive(i)
                                return c
                            
                            washed_fields += attack_recursive(decoded)

                            # [CLEANUP] Blanking WiFi data array to prevent common location correlation
                            for w_key in ["4", 4]:
                                if w_key in decoded and isinstance(decoded[w_key], list):
                                    decoded[w_key] = []
                                    washed_fields += 1

                        decoded = smart_cleanse(decoded, is_nlogapp)
                        encoded_payload = blackboxprotobuf.encode_message(decoded, msg_type)
                        if is_gzip: encoded_payload = _gzip.compress(encoded_payload)
                        flow.request.content = bytes(encoded_payload)
                        if washed_fields > 0:
                            print(f"[✓] PROTO JITTER WASHED: {path[:35]}... ({washed_fields} fields randomized)")
                
                # JSON/NLogApp Inspection
                elif "json" in content_type or is_nlogapp or "heartbeat" in path or is_nelo:
                    try:
                        body_json = json.loads(flow.request.content.decode('utf-8', 'ignore'))
                        body_json = smart_cleanse(body_json, is_nlogapp)
                        flow.request.content = json.dumps(body_json).encode('utf-8')
                        if is_nelo: print(f"[🧼] NELO Washed: {path[:40]}")
                    except:
                        flow.request.content = smart_cleanse(flow.request.content, is_nlogapp)
            except Exception as e:
                pass

    def responseheaders(self, flow: http.HTTPFlow):
        # Prevent downloading heavy UI/noise assets internally to save RAM
        content_type = flow.response.headers.get("Content-Type", "").lower()
        if any(noise in content_type for noise in ["image", "font", "video"]):
            flow.response.stream = True
        elif any(nh in flow.request.pretty_host for nh in self.NOISE_HOSTS) and ("protobuf" in content_type or "octet-stream" in content_type):
            flow.response.stream = True

    def response(self, flow: http.HTTPFlow):
        if not flow.response:
            return

        host = flow.request.pretty_host
        path = flow.request.path
        
        # Noise checking
        is_noise = any(nh in host for nh in self.NOISE_HOSTS) or any(np in path for np in self.NOISE_PATHS)

        with self.lock:
            self.counter += 1
            idx = self.counter

        # 1. Filename mapping matching lib_new logic
        m = flow.request.method
        clean_path = path.split('?')[0].replace('/', '_').strip('_')
        if not clean_path: clean_path = "root"
        if len(clean_path) > 100: clean_path = clean_path[:100] + "_trunc"
        
        # Format: 001_POST_api_v1_trafficjam.json
        filename = f"{idx:03d}_{m}_{clean_path}.json"
        
        def try_parse_content(content_bytes, ct):
            if not content_bytes: return ""
            ct = ct.lower()
            if "image" in ct or "font" in ct or "video" in ct: return f"<MEDIA_SKIPPED: {len(content_bytes)} bytes>"
            if "json" in ct:
                try: return json.loads(content_bytes.decode('utf-8'))
                except: pass
            if "protobuf" in ct or "octet-stream" in ct or "trafficjam" in path:
                return "base64:" + base64.b64encode(content_bytes).decode('ascii')
            try:
                text = content_bytes.decode('utf-8')
                try: return json.loads(text)
                except: return text
            except:
                return "base64:" + base64.b64encode(content_bytes).decode('ascii')

        req_body = try_parse_content(flow.request.content, flow.request.headers.get("Content-Type", ""))
        res_body = try_parse_content(flow.response.content, flow.response.headers.get("Content-Type", ""))
        
        # Drop noise logs completely to save SSD space
        if is_noise:
            req_body = "<NOISE_SKIPPED>"
            res_body = "<NOISE_SKIPPED>"
            # Don't even write individual files for noise logs
            return 
        
        full_packet = {
            "index": idx,
            "timestamp": datetime.datetime.now().isoformat(),
            "request": {
                "method": m,
                "url": flow.request.url,
                "headers": dict(flow.request.headers),
                "body": req_body
            },
            "response": {
                "status_code": flow.response.status_code,
                "headers": dict(flow.response.headers),
                "body": res_body
            }
        }

        # [RESTORED] Protobuf Decoding for logging (Important for Driving Paths)
        if HAS_BLACKBOX and flow.request.content and ("x-protobuf" in flow.request.headers.get("Content-Type", "").lower() or "trafficjam" in path):
            try:
                decoded, _ = blackboxprotobuf.decode_message(flow.request.content)
                def make_serializable(d):
                    if isinstance(d, dict): return {k: make_serializable(v) for k, v in d.items()}
                    elif isinstance(d, list): return [make_serializable(v) for v in d]
                    elif isinstance(d, bytes):
                        try: return d.decode('utf-8')
                        except: return f"hex:{d.hex()}"
                    return d
                full_packet["request"]["body_protobuf"] = make_serializable(decoded)
            except: pass

        # JSONL Log
        with open(self.all_packets_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(full_packet, ensure_ascii=False) + "\n")

        # Compact file log
        file_path = os.path.join(self.base_log_dir, filename)
        with open(file_path, "w", encoding="utf-8") as f:
            json.dump(full_packet, f, ensure_ascii=False, indent=2)

addons = [ProxyCoreWash()]
