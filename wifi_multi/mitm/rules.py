"""
wifi_multi/mitm/rules.py: Declarative URL & Endpoint Rewriting Rules Engine
- Defines explicit endpoint-to-field rewriting rules.
- Prevents cross-endpoint spillover (e.g. protects caller in routechoice and receiver).
- Records all replacements in real-time to $CAPTURE_LOG_DIR/modifications.json.
"""

import os
import re
import json
import datetime
import threading

# Identity validation regex
# Accepts 16-64 char hex (NI, SSAID), standard UUID (ADID, IDFV), or 16-char alphanumeric base62 (TOKEN)
RE_VALID_IDENTITY = re.compile(
    r'^[a-fA-F0-9]{16,64}$|'
    r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$|'
    r'^[a-zA-Z0-9]{16}$'
)

def is_valid_identity(val):
    """Checks if a string is a valid device identity credential.
    Strictly filters out caller strings, versions, system models, and JSON/array syntax."""
    if not val or not isinstance(val, (str, bytes, bytearray)):
        return False
    s = val.decode('utf-8', 'ignore').strip() if isinstance(val, (bytes, bytearray)) else str(val).strip()
    if len(s) < 16 or len(s) > 64:
        return False
    if s.startswith(('{', '[', '"', "'", 'mapmobileapps_', 'android_', 'http', 'v1-', 'SM-')):
        return False
    return bool(RE_VALID_IDENTITY.match(s))

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
    """Returns the target identity credentials configured for the current session."""
    return {
        "ni": os.environ.get("NMAP_ID_NI"),
        "adid": os.environ.get("NMAP_ID_ADID"),
        "idfv": os.environ.get("NMAP_ID_IDFV"),
        "ssaid": os.environ.get("NMAP_ID_SSAID"),
        "token": os.environ.get("NMAP_ID_TOKEN")
    }

# Explicit URL-to-rule mapping dictionary
ENDPOINT_RULES = [
    # 1. Drive Routechoice (Path finding)
    # Strictly replaces device_id/uuid -> NI, and protects caller & HMAC from being touched.
    {
        "name": "drive_routechoice",
        "url_pattern": re.compile(r"/drive/v3/routechoice", re.IGNORECASE),
        "query_params": {
            "device_id": "ni",
            "ai": "adid",
            "iv": "idfv"
        },
        "headers": {
            "uuid": "ni",
            "device-id": "ni",
            "x-adid": "adid",
            "da-dd": "adid",
            "da-dv": "idfv"
        },
        "protected_query": {"caller", "x-hmac-md", "timestamp"},
        "protected_headers": {"caller", "x-hmac-md"}
    },

    # 2. General Drive Navigation (driving, routeend, summary)
    {
        "name": "drive_navigation",
        "url_pattern": re.compile(r"/drive/v3/(driving|routeend|summary)", re.IGNORECASE),
        "query_params": {
            "device_id": "ni",
            "ai": "adid",
            "iv": "idfv"
        },
        "headers": {
            "uuid": "ni",
            "device-id": "ni"
        },
        "protected_query": {"caller"}
    },

    # 3. Trafficjam Location (FCD real-time congestion)
    # Field 1.1 is device NI. Fields 5,6,7 are jittered. Field 4 (WiFi) is blanked.
    {
        "name": "trafficjam_location",
        "url_pattern": re.compile(r"/trafficjam/location", re.IGNORECASE),
        "protobuf": {
            "field_1_1": "ni",
            "clear_wifi": [4, "4"],
            "jitter_fields": [5, 6, 7, "5", "6", "7"]
        }
    },

    # 4. Receiver Log (Telemetry / device log)
    # Field 1.3 is device NI. Field 1.1 (caller) is PRESERVED.
    {
        "name": "receiver_log",
        "url_pattern": re.compile(r"/(receiver/log|log-receiver)", re.IGNORECASE),
        "protobuf": {
            "field_1_3": "ni",
            "protected_fields": ["1.1"]
        }
    },

    # 5. nlogapp (Analytics, screen events, and user IDs)
    # usr.adid/ssaid/idfv/ni -> target credentials. evts[].nlog_id -> target_token.
    {
        "name": "nlogapp",
        "url_pattern": re.compile(r"/nlogapp", re.IGNORECASE),
        "json": {
            "usr_fields": {
                "adid": "adid",
                "ssaid": "ssaid",
                "idfv": "idfv",
                "ni": "ni"
            },
            "token_evts": "evts"
        }
    },

    # 6. Fallback Common Headers & Cookies (applied across all matched Naver domains)
    {
        "name": "common_headers_and_cookies",
        "url_pattern": re.compile(r".*", re.IGNORECASE),
        "headers": {
            "uuid": "ni",
            "device-id": "ni",
            "x-adid": "adid",
            "da-dd": "adid",
            "da-dv": "idfv"
        },
        "cookie_keys": {
            "NAPP_DI": "ni"
        }
    }
]

def find_matching_rules(url_path):
    """Finds all applicable rules for a given URL path in order."""
    matched = []
    for r in ENDPOINT_RULES:
        if r["url_pattern"].search(url_path):
            matched.append(r)
    return matched
