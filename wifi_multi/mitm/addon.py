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
                else:
                    current.update(data)
                
                with open(self.summary_path, "w") as f:
                    json.dump(current, f, ensure_ascii=False, indent=2)
            except Exception as e:
                print(f" [!] Error updating summary: {e}")

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
        if "client-logger/errorLog" in flow.request.url:
            flow.response = http.Response.make(
                200,
                b"",
                {"Content-Type": "application/json"}
            )
            print(f" [🛡️ MITM BLOCK] Successfully blocked errorLog from reaching Naver (Device: {self.device_id})!")
            self._write_stealth_log("errorLog Blocked", "Intercepted and blocked errorLog POST request entirely.")
            return

        # 2. Steal-cap fpDuration in accessLog to look like a normal high-speed device
        if "client-logger/accessLog" in flow.request.url and flow.request.text:
            try:
                import re
                modified_text = flow.request.text
                fp_matches = re.findall(r"fpDuration[:\s]*(\d+)ms", modified_text)
                for val_str in fp_matches:
                    val = int(val_str)
                    if val > 1000:
                        fake_val = random.randint(550, 850)
                        modified_text = modified_text.replace(f"fpDuration: {val_str}ms", f"fpDuration: {fake_val}ms")
                        modified_text = modified_text.replace(f"fpDuration:{val_str}ms", f"fpDuration:{fake_val}ms")
                        print(f" [⚡ MITM STEALTH] Capped accessLog fpDuration from {val}ms to {fake_val}ms (Device: {self.device_id})")
                        self._write_stealth_log("accessLog fpDuration", f"Capped fpDuration from {val}ms to {fake_val}ms")
                flow.request.text = modified_text
            except Exception as e:
                print(f" [!] Error capping accessLog fpDuration: {e}")

        handle_request(self, flow)

    def response(self, flow: http.HTTPFlow):
        # 1. Track Driving/Arrival Events for Timing
        path = flow.request.path
        if "global/driving" in path and flow.response.status_code == 200:
            self.update_summary({
                "driving_start_time": datetime.datetime.now().isoformat(),
                "status": "DRIVING"
            })
        elif "nonloginterm/checkmapservice" in path and flow.response.status_code == 200:
             self.update_summary({
                "driving_end_time": datetime.datetime.now().isoformat(),
                "status": "ARRIVED"
            })

        # 2. Intercept nCaptcha JS and increase timeout from 1s to 10s
        if "ncaptcha-api.js" in flow.request.url and flow.response and flow.response.status_code == 200:
            try:
                original_text = flow.response.text
                target_expr = "-1531*-5+-5599+-8*132+0"
                if target_expr in original_text:
                    flow.response.text = original_text.replace(target_expr, "10000")
                    print(f" [⚡ MITM HACK] Intercepted ncaptcha-api.js and increased timeout to 10s (Device: {self.device_id})!")
                    self._write_stealth_log("ncaptcha-api.js Timeout", "Capped script timeout expression to 10000 (10s)")
                else:
                    print(f" [⚠️ MITM HACK] ncaptcha-api.js loaded but target timeout expression not found!")
            except Exception as e:
                print(f" [!] Error intercepting ncaptcha-api.js: {e}")

        # 3. Intercept Place Home HTML and increase executionTimeout from 1s to 10s
        if "nmap.place.naver.com" in flow.request.host and flow.response and flow.response.status_code == 200:
            if "text/html" in flow.response.headers.get("content-type", ""):
                try:
                    original_html = flow.response.text
                    target_config = "executionTimeout: 1000"
                    if target_config in original_html:
                        flow.response.text = original_html.replace(target_config, "executionTimeout: 10000")
                        print(f" [⚡ MITM HACK] Intercepted Place HTML and increased executionTimeout to 10s (Device: {self.device_id})!")
                        self._write_stealth_log("Place HTML executionTimeout", "Capped executionTimeout config to 10000 (10s)")
                except Exception as e:
                    print(f" [!] Error intercepting Place HTML: {e}")

        handle_response(self, flow)

addons = [ProxyV2ClassicLog()]
