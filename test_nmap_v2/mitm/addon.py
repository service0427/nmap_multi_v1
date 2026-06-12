import os
import sys
import random
import threading
import gzip
import json
import datetime
import socket
from mitmproxy import http

# Monkey patch socket.socket.connect to force outbound traffic through NMAP_BIND_IP
BIND_IP = os.environ.get("NMAP_BIND_IP")
if BIND_IP:
    old_connect = socket.socket.connect
    def new_connect(self, address):
        if self.family == socket.AF_INET and self.type == socket.SOCK_STREAM:
            try:
                self.bind((BIND_IP, 0))
            except Exception:
                pass
        return old_connect(self, address)
    socket.socket.connect = new_connect

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
        self.real_ip = os.environ.get("NMAP_REAL_IP", "Unknown")

    def update_summary(self, data):
        """Thread-safe update of session_summary.json"""
        with self.lock:
            try:
                current = {}
                if os.path.exists(self.summary_path):
                    with open(self.summary_path, "r") as f:
                        current = json.load(f)
                
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

        handle_response(self, flow)

addons = [ProxyV2ClassicLog()]
