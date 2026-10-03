"""
wifi_multi/mitm/rules.py: Audit Logging & Identity Configuration
- Thread-safe ModificationAuditLogger recording all packet modifications per session into modifications.json.
- get_target_identities(): Reads current session target identity credentials from environment variables.
"""

import os
import json
import datetime
import threading


from .session_logger import ModificationAuditLogger

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
