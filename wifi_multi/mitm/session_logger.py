"""
wifi_multi/mitm/session_logger.py
=================================
Systematic, thread-safe session logging and audit module for mitmproxy.

Centralizes and standardizes all logging responsibilities:
1. Session Summary (session_summary.json)
2. Events Timeline (events.log - URLs, screen views, error blocks)
3. Blocked Client Errors (blocked_errors.json)
4. Modifications Audit (modifications.json via ModificationAuditLogger)
5. Packet JSON Dumps (001_POST_..., 002_GET_...)
6. Stealth Operations Log (stealth_logs/stealth_replacements_{date}.log)
7. Log Payload Decoders (deep_tparse, try_pbf_decode)
"""

import os
import json
import gzip
import base64
import datetime
import threading
from typing import Optional, Dict, Any, List

try:
    import blackboxprotobuf
    HAS_BLACKBOX = True
except ImportError:
    HAS_BLACKBOX = False

_GLOBAL_FILE_LOCK = threading.Lock()


# ---------------------------------------------------------------------------
# 1. Payload Decoders for Logging
# ---------------------------------------------------------------------------

def try_pbf_decode(raw_bytes: bytes) -> Optional[Any]:
    """Helper to decode protobuf bytes for logging purposes into serializable dict/list."""
    if not HAS_BLACKBOX or not raw_bytes:
        return None
    try:
        data = raw_bytes
        if data.startswith(b'\x1f\x8b'):
            data = gzip.decompress(data)
        decoded, _ = blackboxprotobuf.decode_message(data)

        def serializable(d):
            if isinstance(d, dict):
                return {str(k): serializable(v) for k, v in d.items()}
            elif isinstance(d, list):
                return [serializable(v) for v in d]
            elif isinstance(d, bytes):
                try:
                    return d.decode('utf-8')
                except Exception:
                    return f"hex:{d.hex()}"
            return d

        return serializable(decoded)
    except Exception:
        return None


def deep_tparse(c: bytes, ct: str, p: str = "", host: str = "", is_response: bool = False, pbf_decoder=try_pbf_decode) -> Any:
    """Recursive deep decoding for logging JSON, Protobuf, and nested base64 structures."""
    if not c:
        return ""
    ct_l = (ct or "").lower()

    work_str = None
    try:
        work_str = c.decode('utf-8')
    except Exception:
        pass

    # JSON (Check for nested base64 for logs)
    if "json" in ct_l or "nlog" in p or "nlog.naver.com" in (host or "").lower() or (work_str and (work_str.strip().startswith('{') or work_str.strip().startswith('['))):
        try:
            bj = json.loads(work_str if work_str else c.decode('utf-8'))

            # drive_v3_driving response payload is too large, skip nested base64 parsing
            if is_response and ("driving" in p or "drive_v3_driving" in p):
                return bj

            def scan(o):
                if isinstance(o, dict):
                    res = {k: scan(v) for k, v in o.items()}
                    for k, v in o.items():
                        if isinstance(v, str) and v.startswith("base64:"):
                            try:
                                raw = base64.b64decode(v[7:])
                                d = pbf_decoder(raw)
                                if d:
                                    res[k + "_decoded"] = d
                            except Exception:
                                pass
                    return res
                elif isinstance(o, list):
                    return [scan(i) for i in o]
                return o

            return scan(bj)
        except Exception:
            pass

    # Binary / Protobuf
    if "octet-stream" in ct_l or "protobuf" in ct_l or b"\x00" in c:
        b64_str = "base64:" + base64.b64encode(c).decode('ascii')

        # drive_v3_driving response payload is too large, skip decoding
        if is_response and ("driving" in p or "drive_v3_driving" in p):
            return b64_str

        decoded = pbf_decoder(c)
        if decoded:
            return {"_raw": b64_str, "_decoded": decoded}
        return b64_str

    try:
        return c.decode('utf-8', 'ignore')
    except Exception:
        return "base64:" + base64.b64encode(c).decode('ascii')


# ---------------------------------------------------------------------------
# 2. Centralized Stealth Operations Logger
# ---------------------------------------------------------------------------

def write_stealth_log(base_log_dir: str, log_type: str, details: str, root_log_dir: str = "/home/tech/nmap_multi_v1/wifi_multi/logs"):
    """Write detailed stealth operations/replacement log organized by date under logs/stealth_logs/"""
    try:
        date_str = datetime.datetime.now().strftime("%Y%m%d")
        stealth_dir = os.path.join(root_log_dir, "stealth_logs")
        os.makedirs(stealth_dir, exist_ok=True)
        log_path = os.path.join(stealth_dir, f"stealth_replacements_{date_str}.log")

        # Clean session path to highlight 'Device/Date/Time_PlaceID'
        session_rel = base_log_dir.replace(f"{root_log_dir}/", "").replace("logs/", "")

        with _GLOBAL_FILE_LOCK:
            with open(log_path, "a", encoding="utf-8") as f_repl:
                log_line = (
                    f"[{datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] "
                    f"[{session_rel}] [{log_type}] {details}\n"
                )
                f_repl.write(log_line)
    except Exception as e:
        print(f" [!] Error writing stealth log: {e}", flush=True)


# ---------------------------------------------------------------------------
# 3. Session Summary Manager (session_summary.json)
# ---------------------------------------------------------------------------

def update_session_summary(base_log_dir: str, data: Dict[str, Any], lock: Optional[threading.Lock] = None):
    """Thread-safe update of session_summary.json"""
    if not base_log_dir:
        return

    summary_path = os.path.join(base_log_dir, "session_summary.json")
    use_lock = lock or _GLOBAL_FILE_LOCK

    with use_lock:
        try:
            current = {}
            if os.path.exists(summary_path):
                with open(summary_path, "r", encoding="utf-8") as f:
                    current = json.load(f)

            data_copy = dict(data)
            if "packet" in data_copy:
                if "packets" not in current:
                    current["packets"] = []
                current["packets"].append(data_copy.pop("packet"))
            if "blocked_error" in data_copy:
                if "blocked_errors" not in current:
                    current["blocked_errors"] = []
                current["blocked_errors"].append(data_copy.pop("blocked_error"))
                current["blocked_error_count"] = len(current["blocked_errors"])
            if data_copy:
                current.update(data_copy)

            with open(summary_path, "w", encoding="utf-8") as f:
                json.dump(current, f, ensure_ascii=False, indent=2)
        except Exception as e:
            print(f" [!] Error updating session summary: {e}", flush=True)


# ---------------------------------------------------------------------------
# 4. Events Timeline Logger (events.log)
# ---------------------------------------------------------------------------

def log_url_event(base_log_dir: str, path_lower: str):
    """Logs visited URL path to events.log."""
    if not base_log_dir:
        return
    try:
        events_log = os.path.join(base_log_dir, "events.log")
        with open(events_log, "a", encoding="utf-8") as ef:
            ef.write(f"[URL] {path_lower}\n")
    except Exception:
        pass


def log_screen_events(base_log_dir: str, evts: List[Dict[str, Any]]):
    """Logs bulk UI/screen interaction events to events.log."""
    if not base_log_dir or not evts or not isinstance(evts, list):
        return
    try:
        events_log = os.path.join(base_log_dir, "events.log")
        with open(events_log, "a", encoding="utf-8") as ef:
            for e in evts:
                t = e.get("type", "unknown")
                s = (
                    e.get("screen_name") or
                    e.get("act_act") or
                    (e.get("act_oval", {}).get("tab") if isinstance(e.get("act_oval"), dict) else None) or
                    "none"
                )
                ef.write(f"[{t}] {s}\n")
    except Exception:
        pass


# ---------------------------------------------------------------------------
# 5. Blocked Error Recorder (blocked_errors.json + summary + events.log)
# ---------------------------------------------------------------------------

def record_blocked_error(
    base_log_dir: str,
    method: str,
    url: str,
    raw_body_dict: Any,
    err_msg_str: str,
    lock: Optional[threading.Lock] = None
):
    """Record blocked client errorLog into session's blocked_errors.json, session_summary.json, and events.log."""
    if not base_log_dir:
        return

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
        blocked_file = os.path.join(base_log_dir, "blocked_errors.json")
        use_lock = lock or _GLOBAL_FILE_LOCK
        with use_lock:
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
        update_session_summary(base_log_dir, {
            "blocked_error": {
                "time": ts_time,
                "method": method,
                "code": code,
                "name": name,
                "action": "BLOCKED_MOCK_200"
            }
        }, lock=use_lock)

        # 3. Append to events.log in session directory
        events_log = os.path.join(base_log_dir, "events.log")
        try:
            with open(events_log, "a", encoding="utf-8") as ef:
                ef.write(f"[ERROR_BLOCKED] {method} {code} ({name}) - Mocked HTTP 200\n")
        except Exception:
            pass

    except Exception as e:
        print(f" [!] Error recording blocked error: {e}", flush=True)


# ---------------------------------------------------------------------------
# 6. Packet Dump Logger (001_POST_..., 002_GET_...)
# ---------------------------------------------------------------------------

def write_packet_log(base_log_dir: str, idx: int, method: str, path: str, full_packet: Dict[str, Any]) -> str:
    """Writes full packet JSON dump {idx:03d}_{method}_{path[:80]}.json."""
    if not base_log_dir:
        return ""

    cp = path.split('?')[0].replace('/', '_').strip('_')
    fn = f"{idx:03d}_{method}_{cp[:80]}.json"
    file_path = os.path.join(base_log_dir, fn)

    try:
        with open(file_path, "w", encoding="utf-8") as f:
            json.dump(full_packet, f, ensure_ascii=False, indent=2)
    except Exception as e:
        print(f" [!] Error writing packet log {fn}: {e}", flush=True)

    return fn


# ---------------------------------------------------------------------------
# 7. Modification Audit Logger (modifications.json)
# ---------------------------------------------------------------------------

class ModificationAuditLogger:
    """Thread-safe logger recording all packet modifications per session into modifications.json."""
    def __init__(self, log_dir: Optional[str] = None):
        self.lock = threading.Lock()
        self.log_dir = log_dir or os.environ.get("CAPTURE_LOG_DIR")
        self.audit_file = os.path.join(self.log_dir, "modifications.json") if self.log_dir else None
        self._init_file()

    def _init_file(self):
        if self.audit_file and not os.path.exists(self.audit_file):
            try:
                os.makedirs(os.path.dirname(self.audit_file), exist_ok=True)
                with open(self.audit_file, "w", encoding="utf-8") as f:
                    json.dump([], f, indent=2)
            except Exception:
                pass

    def record(self, url: str, rule_name: str, rule_type: str, field: str, orig_val: Any, new_val: Any):
        if not orig_val or not new_val or orig_val == new_val:
            return

        orig_s = orig_val.decode('utf-8', 'ignore') if isinstance(orig_val, (bytes, bytearray)) else str(orig_val)
        new_s = new_val.decode('utf-8', 'ignore') if isinstance(new_val, (bytes, bytearray)) else str(new_val)
        if orig_s == new_s:
            return

        entry = {
            "timestamp": datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3],
            "url": url.split('?')[0] if '?' in url else url,
            "rule": rule_name,
            "type": rule_type,
            "field": field,
            "original": orig_s,
            "replaced": new_s
        }
        with self.lock:
            if self.audit_file:
                try:
                    current = []
                    if os.path.exists(self.audit_file):
                        try:
                            with open(self.audit_file, "r", encoding="utf-8") as f:
                                current = json.load(f)
                        except Exception:
                            current = []
                    current.append(entry)
                    with open(self.audit_file, "w", encoding="utf-8") as f:
                        json.dump(current, f, ensure_ascii=False, indent=2)
                except Exception:
                    pass


# ---------------------------------------------------------------------------
# 8. Unified SessionLogger Class
# ---------------------------------------------------------------------------

class SessionLogger:
    """Stateful logger instance bound to a specific session log directory and device."""
    def __init__(self, base_log_dir: str, lock: Optional[threading.Lock] = None, device_id: str = "Unknown"):
        self.base_log_dir = base_log_dir
        self.lock = lock or threading.Lock()
        self.device_id = device_id
        os.makedirs(self.base_log_dir, exist_ok=True)

    def write_stealth_log(self, log_type: str, details: str):
        write_stealth_log(self.base_log_dir, log_type, details)

    def update_summary(self, data: Dict[str, Any]):
        update_session_summary(self.base_log_dir, data, lock=self.lock)

    def record_blocked_error(self, method: str, url: str, raw_body_dict: Any, err_msg_str: str):
        record_blocked_error(self.base_log_dir, method, url, raw_body_dict, err_msg_str, lock=self.lock)

    def log_url(self, path_lower: str):
        log_url_event(self.base_log_dir, path_lower)

    def log_screens(self, evts: List[Dict[str, Any]]):
        log_screen_events(self.base_log_dir, evts)

    def write_packet(self, idx: int, method: str, path: str, full_packet: Dict[str, Any]) -> str:
        return write_packet_log(self.base_log_dir, idx, method, path, full_packet)

    def try_pbf_decode(self, raw_bytes: bytes) -> Optional[Any]:
        return try_pbf_decode(raw_bytes)

    def deep_tparse(self, c: bytes, ct: str, p: str = "", host: str = "", is_response: bool = False) -> Any:
        return deep_tparse(c, ct, p=p, host=host, is_response=is_response, pbf_decoder=self.try_pbf_decode)
