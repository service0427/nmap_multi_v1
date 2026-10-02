import os
import sys
import random
import threading
import gzip
import json
import datetime
import socket
from mitmproxy import http



# Add repository root to python path to resolve mitm modules
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Import the refactored handlers
from mitm.request import handle_request
from mitm.response import handle_response

try:
    import blackboxprotobuf
    HAS_BLACKBOX = True
except ImportError:
    HAS_BLACKBOX = False

class ProxyV2ClassicLog:
    def __init__(self):
        self.lock = threading.Lock()
        self.counter = 0

        self.base_log_dir = os.environ.get("CAPTURE_LOG_DIR", "logs/fallback")
        os.makedirs(self.base_log_dir, exist_ok=True)
        self.summary_path = os.path.join(self.base_log_dir, "session_summary.json")
        self.device_id = os.environ.get("NMAP_DEV_ID", "Unknown")
        self.bind_ip = os.environ.get("NMAP_BIND_IP", "Unknown")

    def _write_stealth_log(self, log_type, details):
        """Write detailed replacement log organized by date under logs/stealth_logs/"""
        try:
            date_str = datetime.datetime.now().strftime("%Y%m%d")
            stealth_dir = "/home/tech/nmap_multi_v1/wifi_multi/logs/stealth_logs"
            os.makedirs(stealth_dir, exist_ok=True)
            log_path = os.path.join(stealth_dir, f"stealth_replacements_{date_str}.log")
            
            # Clean session path to highlight 'Device/Date/Time_PlaceID'
            session_rel = self.base_log_dir.replace("/home/tech/nmap_multi_v1/wifi_multi/logs/", "").replace("logs/", "")
            
            with open(log_path, "a") as f_repl:
                log_line = (
                    f"[{datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] "
                    f"[{session_rel}] [{log_type}] {details}\n"
                )
                f_repl.write(log_line)
        except Exception as e:
            print(f" [!] Error writing stealth log: {e}")

    def update_summary(self, data):
        """Thread-safe update of session_summary.json"""
        with self.lock:
            try:
                current = {}
                if os.path.exists(self.summary_path):
                    with open(self.summary_path, "r") as f:
                        current = json.load(f)
                
                if "packet" in data:
                    if "packets" not in current:
                        current["packets"] = []
                    current["packets"].append(data["packet"])
                elif "blocked_error" in data:
                    if "blocked_errors" not in current:
                        current["blocked_errors"] = []
                    current["blocked_errors"].append(data["blocked_error"])
                    current["blocked_error_count"] = len(current["blocked_errors"])
                else:
                    current.update(data)
                
                with open(self.summary_path, "w") as f:
                    json.dump(current, f, ensure_ascii=False, indent=2)
            except Exception as e:
                print(f" [!] Error updating summary: {e}")

    def _record_blocked_error(self, method, url, raw_body_dict, err_msg_str):
        """Record blocked errorLog into session's blocked_errors.json, summary, and events.log."""
        try:
            now_dt = datetime.datetime.now()
            ts_time = now_dt.strftime("%H:%M:%S.%f")[:-3]

            code = "unknown"
            name = "unknown"
            desc = ""
            ver = ""
            parsed_detail = err_msg_str

            if isinstance(raw_body_dict, dict):
                msg_val = raw_body_dict.get("message")
                if isinstance(msg_val, str):
                    try:
                        msg_json = json.loads(msg_val)
                        ver = msg_json.get("version", "")
                        err_obj = msg_json.get("error", {})
                        code = err_obj.get("code", "unknown")
                        name = err_obj.get("name", "unknown")
                        desc = err_obj.get("message", "")
                        parsed_detail = msg_json
                    except Exception:
                        desc = msg_val
                elif isinstance(msg_val, dict):
                    if "cipherText" in msg_val:
                        code = "encrypted"
                        name = "CIPHER_TEXT"
                        desc = "Encrypted client error payload"
                        parsed_detail = msg_val
                    else:
                        parsed_detail = msg_val
            elif isinstance(err_msg_str, str):
                desc = err_msg_str

            entry = {
                "timestamp": ts_time,
                "method": method,
                "url": url.split('?')[0] if '?' in url else url,
                "action": "BLOCKED_MOCK_200",
                "sent_to_naver": False,
                "error_code": code,
                "error_name": name,
                "error_message": desc,
                "version": ver,
                "detail": parsed_detail
            }

            # 1. Append to blocked_errors.json in session directory
            blocked_file = os.path.join(self.base_log_dir, "blocked_errors.json")
            with self.lock:
                current_blocked = []
                if os.path.exists(blocked_file):
                    try:
                        with open(blocked_file, "r", encoding="utf-8") as bf:
                            current_blocked = json.load(bf)
                    except Exception:
                        current_blocked = []
                current_blocked.append(entry)
                with open(blocked_file, "w", encoding="utf-8") as bf:
                    json.dump(current_blocked, bf, ensure_ascii=False, indent=2)

            # 2. Update session_summary.json
            self.update_summary({
                "blocked_error": {
                    "time": ts_time,
                    "method": method,
                    "code": code,
                    "name": name,
                    "action": "BLOCKED_MOCK_200"
                }
            })

            # 3. Append to events.log in session directory
            events_log = os.path.join(self.base_log_dir, "events.log")
            try:
                with open(events_log, "a", encoding="utf-8") as ef:
                    ef.write(f"[ERROR_BLOCKED] {method} {code} ({name}) - Mocked HTTP 200\n")
            except Exception:
                pass
        except Exception as e:
            print(f" [!] Error recording blocked error: {e}", flush=True)

    def try_pbf_decode(self, raw_bytes):
        """Helper to decode protobuf for logging"""
        if not HAS_BLACKBOX: return None
        try:
            data = raw_bytes
            if data.startswith(b'\x1f\x8b'): data = gzip.decompress(data)
            decoded, _ = blackboxprotobuf.decode_message(data)
            def serializable(d):
                if isinstance(d, dict): return {str(k): serializable(v) for k, v in d.items()}
                elif isinstance(d, list): return [serializable(v) for v in d]
                elif isinstance(d, bytes):
                    try: return d.decode('utf-8')
                    except: return f"hex:{d.hex()}"
                return d
            return serializable(decoded)
        except: return None

    def request(self, flow: http.HTTPFlow):
        # 1. Prevent errorLog from ever reaching Naver (Drop/Mock it with empty HTTP 200)
        if os.environ.get("ERRORLOG_FILTER", "true").lower() == "true" and "client-logger/errorLog" in flow.request.url:
            err_msg_to_save = "Unknown Error"
            raw_body_dict = None
            method = flow.request.method
            try:
                from mitm.request import get_target_identities, SESSION_LEARNED_IDENTITIES
                from mitm.dynamic_tree_replacer import IdentityLookup, dynamic_replace_headers, dynamic_walk_and_replace
                target_ids = get_target_identities()
                lookup = IdentityLookup(target_ids)
                for orig_v, spoof_v in SESSION_LEARNED_IDENTITIES.items():
                    lookup.register(orig_v, spoof_v)
                dynamic_replace_headers(flow.request.headers, lookup, flow.request.url)
                if flow.request.content:
                    raw = flow.request.content
                    is_gz = raw.startswith(b'\x1f\x8b')
                    if is_gz:
                        import gzip
                        raw = gzip.decompress(raw)
                    try:
                        import json
                        body_json = json.loads(raw.decode('utf-8', 'ignore'))
                        raw_body_dict = body_json
                        if isinstance(body_json, dict) and "message" in body_json:
                            err_msg_to_save = body_json["message"]
                        dynamic_walk_and_replace(body_json, lookup)
                        work = json.dumps(body_json).encode('utf-8')
                        if is_gz:
                            import gzip
                            work = gzip.compress(work)
                        flow.request.content = work
                    except:
                        cleansed_raw, _, _, _ = lookup.replace_value(flow.request.content)
                        flow.request.content = cleansed_raw
            except Exception as e:
                print(f" [!] Error cleansing errorLog request: {e}")

            # Record to session's blocked_errors.json, session_summary.json, and events.log
            self._record_blocked_error(method, flow.request.url, raw_body_dict, err_msg_to_save)

            # Write a local session marker file for monitor.sh to fail-fast immediately (do not overwrite with OPTIONS)
            marker_path = os.path.join(self.base_log_dir, "errorLog_detected")
            if method != "OPTIONS" or not os.path.exists(marker_path):
                try:
                    with open(marker_path, "w", encoding="utf-8") as f_marker:
                        f_marker.write(str(err_msg_to_save))
                except Exception as e:
                    print(f" [!] Error writing local errorLog marker: {e}")

            origin = flow.request.headers.get("Origin", "*")
            headers = {
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": origin,
                "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
                "Access-Control-Allow-Headers": flow.request.headers.get("Access-Control-Request-Headers", "*"),
                "Access-Control-Allow-Credentials": "true"
            }
            flow.response = http.Response.make(
                200,
                b"",
                headers
            )
            print(f" [🛡️ MITM BLOCK] Successfully blocked errorLog from reaching Naver (Device: {self.device_id}, Method: {method})!")
            self._write_stealth_log("errorLog Blocked", f"Intercepted, cleansed and blocked errorLog POST/OPTIONS request entirely. Msg: {err_msg_to_save}")
            return

        # 2. Proportional Capping of accessLog Metrics to Ensure Realistic Inequalities
        if "client-logger/accessLog" in flow.request.url and flow.request.text:
            try:
                import re
                modified_text = flow.request.text
                
                # Extract all telemetry values
                fp_dur = re.findall(r"fpDuration[:\s]*(\d+)ms", modified_text)
                net_dur = re.findall(r"networkDuration[:\s]*(\d+)ms", message_str := modified_text)
                hsh_dur = re.findall(r"hashing[:\s]*(\d+)ms", modified_text)
                comp_dur = re.findall(r"compression[:\s]*(\d+)ms", modified_text)
                enc_dur = re.findall(r"encryption[:\s]*(\d+)ms", modified_text)
                fep_dur = re.findall(r"feProcessTime[:\s]*(\d+)ms", modified_text)

                fp = int(fp_dur[0]) if fp_dur else None
                net = int(net_dur[0]) if net_dur else None
                hsh = int(hsh_dur[0]) if hsh_dur else None
                comp = int(comp_dur[0]) if comp_dur else None
                enc = int(enc_dur[0]) if enc_dur else None
                fep = int(fep_dur[0]) if fep_dur else None

                # Detect if any metric exceeds normal phone performance thresholds
                needs_capping = False
                if fp and fp > 1000: needs_capping = True
                if net and net > 600: needs_capping = True
                if fep and fep > 100: needs_capping = True

                if needs_capping:
                    # Proportionally generate realistic metrics preserving natural inequalities:
                    # hashing <= encryption <= feProcessTime <= networkDuration <= fpDuration
                    fake_hsh = random.randint(2, 6)
                    fake_comp = random.randint(4, 9)
                    fake_enc = random.randint(fake_hsh, fake_comp + 2)
                    fake_fep = random.randint(fake_enc + 5, 45)
                    fake_net = random.randint(80, 220)
                    fake_fp = random.randint(580, 840)

                    # Replace in text dynamically
                    if fp_dur:
                        modified_text = modified_text.replace(f"fpDuration: {fp_dur[0]}ms", f"fpDuration: {fake_fp}ms").replace(f"fpDuration:{fp_dur[0]}ms", f"fpDuration:{fake_fp}ms")
                    if net_dur:
                        modified_text = modified_text.replace(f"networkDuration: {net_dur[0]}ms", f"networkDuration: {fake_net}ms").replace(f"networkDuration:{net_dur[0]}ms", f"networkDuration:{fake_net}ms")
                    if hsh_dur:
                        modified_text = modified_text.replace(f"hashing: {hsh_dur[0]}ms", f"hashing: {fake_hsh}ms").replace(f"hashing:{hsh_dur[0]}ms", f"hashing:{fake_hsh}ms")
                    if comp_dur:
                        modified_text = modified_text.replace(f"compression: {comp_dur[0]}ms", f"compression: {fake_comp}ms").replace(f"compression:{comp_dur[0]}ms", f"compression:{fake_comp}ms")
                    if enc_dur:
                        modified_text = modified_text.replace(f"encryption: {enc_dur[0]}ms", f"encryption: {fake_enc}ms").replace(f"encryption:{enc_dur[0]}ms", f"encryption:{fake_enc}ms")
                    if fep_dur:
                        modified_text = modified_text.replace(f"feProcessTime: {fep_dur[0]}ms", f"feProcessTime: {fake_fep}ms").replace(f"feProcessTime:{fep_dur[0]}ms", f"feProcessTime:{fake_fep}ms")

                    print(f" [⚡ MITM STEALTH] Proportional Cap Applied (Device: {self.device_id})")
                    details = f"fp: {fp}ms -> {fake_fp}ms | net: {net}ms -> {fake_net}ms | fep: {fep}ms -> {fake_fep}ms"
                    self._write_stealth_log("proportional Capping", details)

                flow.request.text = modified_text
            except Exception as e:
                print(f" [!] Error applying proportional cap to accessLog: {e}")

        handle_request(self, flow)

    def response(self, flow: http.HTTPFlow):
        # 1. Track Driving/Arrival Events for Timing
        path = flow.request.path
        
        # [🛡️ GraphQL 429 Fail Fast Gate]
        if os.environ.get("GQL_429_FAIL_FAST", "false").lower() == "true":
            if "graphql" in path and flow.response and flow.response.status_code == 429:
                try:
                    marker_path = os.path.join(self.base_log_dir, "gql_429_detected")
                    with open(marker_path, "w", encoding="utf-8") as f_marker:
                        f_marker.write("GraphQL 429 Detected")
                    print(f" [🛡️ MITM BLOCK] GraphQL 429 detected! Fail fast active (Device: {self.device_id})!")
                    self._write_stealth_log("GraphQL 429 Blocked", "Intercepted GraphQL 429 response. Fail-fast active.")
                except Exception as e:
                    print(f" [!] Error writing local GQL 429 marker: {e}")

        if ("global/driving" in path or "drive/v3/driving" in path) and flow.response.status_code == 200:
            self.update_summary({
                "driving_start_time": datetime.datetime.now().isoformat(),
                "status": "DRIVING"
            })
        elif "nonloginterm/checkmapservice" in path and flow.response.status_code == 200:
             self.update_summary({
                "driving_end_time": datetime.datetime.now().isoformat(),
                "status": "ARRIVED"
            })

        # 2. Intercept nCaptcha JS and increase timeout from 1s to target value
        timeout_val = os.environ.get("NCAPTCHA_TIMEOUT_MS", "10000")
        if timeout_val != "1000":
            if "ncaptcha-api.js" in flow.request.url and flow.response and flow.response.status_code == 200:
                try:
                    original_text = flow.response.text
                    target_expr = "-1531*-5+-5599+-8*132+0"
                    if target_expr in original_text:
                        flow.response.text = original_text.replace(target_expr, timeout_val)
                        print(f" [⚡ MITM HACK] Intercepted ncaptcha-api.js and updated timeout to {timeout_val}ms (Device: {self.device_id})!")
                        self._write_stealth_log("ncaptcha-api.js Timeout", f"Capped script timeout expression to {timeout_val}ms")
                    else:
                        print(f" [⚠️ MITM HACK] ncaptcha-api.js loaded but target timeout expression not found!")
                except Exception as e:
                    print(f" [!] Error intercepting ncaptcha-api.js: {e}")

            # 3. Intercept Place Home HTML and increase executionTimeout from 1s to target value
            if "nmap.place.naver.com" in flow.request.host and flow.response and flow.response.status_code == 200:
                if "text/html" in flow.response.headers.get("content-type", ""):
                    try:
                        original_html = flow.response.text
                        target_config = "executionTimeout: 1000"
                        if target_config in original_html:
                            flow.response.text = original_html.replace(target_config, f"executionTimeout: {timeout_val}")
                            print(f" [⚡ MITM HACK] Intercepted Place HTML and updated executionTimeout to {timeout_val}ms (Device: {self.device_id})!")
                            self._write_stealth_log("Place HTML executionTimeout", f"Capped executionTimeout config to {timeout_val}ms")
                    except Exception as e:
                        print(f" [!] Error intercepting Place HTML: {e}")

        handle_response(self, flow)

addons = [ProxyV2ClassicLog()]
