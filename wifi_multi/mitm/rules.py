"""
wifi_multi/mitm/rules.py: Audit Logging & Identity Configuration
- Thread-safe ModificationAuditLogger recording all packet modifications per session into modifications.json.
- get_target_identities(): Reads current session target identity credentials from environment variables.
"""

import os
import json
import datetime
import threading


class ModificationAuditLogger:
    """Thread-safe logger recording all packet modifications per session into modifications.json."""
    def __init__(self):
        self.lock = threading.Lock()
        self.log_dir = os.environ.get("CAPTURE_LOG_DIR")
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

    def record(self, url, rule_name, rule_type, field, orig_val, new_val):
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

# Global audit logger instance
AUDIT_LOGGER = ModificationAuditLogger()

def get_target_identities():
    """Returns the target and original identity credentials configured for the current session."""
    return {
        "ni": os.environ.get("NMAP_ID_NI"),
        "adid": os.environ.get("NMAP_ID_ADID"),
        "idfv": os.environ.get("NMAP_ID_IDFV"),
        "ssaid": os.environ.get("NMAP_ID_SSAID"),
        "token": os.environ.get("NMAP_ID_TOKEN"),
        "orig_ni": os.environ.get("NMAP_ORIG_NI"),
        "orig_adid": os.environ.get("NMAP_ORIG_ADID"),
        "orig_idfv": os.environ.get("NMAP_ORIG_IDFV"),
        "orig_ssaid": os.environ.get("NMAP_ORIG_SSAID"),
        "orig_token": os.environ.get("NMAP_ORIG_TOKEN")
    }
