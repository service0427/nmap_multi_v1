"""
wifi_multi/mitm/telemetry_jitter.py: Device & Telemetry Emulation Module
========================================================================
Handles device fingerprint sanitization, Wi-Fi blanking, FCD location jittering,
session timestamp synthesis for pm clear recovery, and cellular network emulation.

This module is intentionally isolated from request routing and encoding codecs
to guarantee behavioral stability and prevent regressions.
"""

import random
import time


# =============================================================================
# 1. Session-level Randomized State Offsets
# =============================================================================
# Global session state offsets (initialized on import via reset_session_offsets)
SESSION_STORAGE_OFFSET = 0
SESSION_BOOT_OFFSET_MS = 0
SESSION_INSTALL_OFFSET_SEC = 0
SESSION_INIT_OFFSET_MS = 0


def reset_session_offsets():
    """Initializes or re-randomizes session offsets."""
    global SESSION_STORAGE_OFFSET, SESSION_BOOT_OFFSET_MS, SESSION_INSTALL_OFFSET_SEC, SESSION_INIT_OFFSET_MS
    SESSION_STORAGE_OFFSET = random.randint(-500000000, 500000000)
    SESSION_BOOT_OFFSET_MS = random.randint(300000, 86400000)
    SESSION_INSTALL_OFFSET_SEC = random.randint(86400, 604800)
    SESSION_INIT_OFFSET_MS = (SESSION_INSTALL_OFFSET_SEC * 1000) - random.randint(60000, 600000)


# Initialize on module import
reset_session_offsets()


# =============================================================================
# 2. Timestamp Synthesis (pm clear recovery)
# =============================================================================
def synthesize_session_timestamps(obj, url: str = "", logger=None):
    """Auto-synthesizes realistic time values if pm clear resets them to 0."""
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

        res = {}
        for k, v in obj.items():
            if k == "storage_size" and isinstance(v, (int, float)):
                new_v = v + SESSION_STORAGE_OFFSET
                if logger:
                    logger.record(url, "telemetry_jitter", "timestamp", "storage_size", v, new_v)
                res[k] = new_v
            elif k == "last_boot_ts" and isinstance(v, (int, float)):
                new_v = v - SESSION_BOOT_OFFSET_MS
                if logger:
                    logger.record(url, "telemetry_jitter", "timestamp", "last_boot_ts", v, new_v)
                res[k] = new_v
            elif k == "install_ts" and isinstance(v, (int, float)):
                new_v = get_safe_install_ts(v) - SESSION_INSTALL_OFFSET_SEC
                if logger:
                    logger.record(url, "telemetry_jitter", "timestamp", "install_ts", v, new_v)
                res[k] = new_v
            elif k == "init_ts" and isinstance(v, (int, float)):
                new_v = get_safe_init_ts(v) - SESSION_INIT_OFFSET_MS
                if logger:
                    logger.record(url, "telemetry_jitter", "timestamp", "init_ts", v, new_v)
                res[k] = new_v
            elif isinstance(v, (dict, list)):
                res[k] = synthesize_session_timestamps(v, url=url, logger=logger)
            else:
                res[k] = v
        return res
    elif isinstance(obj, list):
        return [synthesize_session_timestamps(i, url=url, logger=logger) for i in obj]
    return obj

smart_cleanse = synthesize_session_timestamps


# =============================================================================
# 3. Location Jittering & WiFi AP Blanking
# =============================================================================
def jitter_location_dict(o, url: str = "", logger=None):
    """Randomize specific fields in trafficjam location dict.
    - Blanks Object 4 (Wi-Fi AP scan list) to prevent office location pinning.
    - Randomizes static/simulated speed, bearing, and accuracy indicators (fields 5, 6, 7).
    """
    if isinstance(o, dict):
        # 1. WiFi Data Array Cleanup (Object 4)
        for wk in [4, "4"]:
            if wk in o and isinstance(o[wk], list):
                orig_cnt = len(o[wk])
                if orig_cnt > 0:
                    print(f"[📡 DEBUG] Object 4 (WiFi Array) detected. Items: {orig_cnt}. Blanking...", flush=True)
                    if logger:
                        logger.record(url, "telemetry_jitter", "wifi_blanking", "object_4_wifi", f"wifi_count_{orig_cnt}", "blanked")
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
                        if logger:
                            logger.record(url, "telemetry_jitter", "location_jitter", f"field_{ks}", val, new_val)
                except Exception:
                    pass
            
            # Recursively process children
            if isinstance(val, (dict, list)):
                jitter_location_dict(val, url=url, logger=logger)
    elif isinstance(o, list):
        for i in o:
            jitter_location_dict(i, url=url, logger=logger)


# =============================================================================
# 4. Network Environment Washer (Cellular / LTE Emulation)
# =============================================================================
def wash_network_env(o, url: str = "", logger=None):
    """Recursively search for 'env' dict or specific keys and override them to emulate cellular network.
    Specifically: env.network_type -> 'cellular', env.mcc_mnc -> '450_08', Carrier -> 'KT'
    """
    if isinstance(o, dict):
        if "env" in o and isinstance(o["env"], dict):
            env = o["env"]
            if "network_type" in env and env["network_type"] != "cellular":
                if logger:
                    logger.record(url, "cellular_env", "network", "env.network_type", env["network_type"], "cellular")
                env["network_type"] = "cellular"
            if "mcc_mnc" in env and env["mcc_mnc"] != "450_08":
                if logger:
                    logger.record(url, "cellular_env", "network", "env.mcc_mnc", env["mcc_mnc"], "450_08")
                env["mcc_mnc"] = "450_08"
        
        if "network_type" in o and o["network_type"] != "cellular":
            if logger:
                logger.record(url, "cellular_env", "network", "network_type", o["network_type"], "cellular")
            o["network_type"] = "cellular"
        if "mcc_mnc" in o and o["mcc_mnc"] != "450_08":
            if logger:
                logger.record(url, "cellular_env", "network", "mcc_mnc", o["mcc_mnc"], "450_08")
            o["mcc_mnc"] = "450_08"

        if "NetworkType" in o and o["NetworkType"] != "Cellular":
            if logger:
                logger.record(url, "cellular_env", "network", "NetworkType", o["NetworkType"], "Cellular")
            o["NetworkType"] = "Cellular"
        if "Carrier" in o and o["Carrier"] != "KT":
            if logger:
                logger.record(url, "cellular_env", "network", "Carrier", o["Carrier"], "KT")
            o["Carrier"] = "KT"
        if "host" in o and isinstance(o["host"], str) and o["host"] != "192.0.0.2":
            parts = o["host"].split('.')
            if len(parts) == 4 and all(p.isdigit() for p in parts):
                if logger:
                    logger.record(url, "cellular_env", "network", "host", o["host"], "192.0.0.2")
                o["host"] = "192.0.0.2"

        for k, v in o.items():
            if isinstance(v, (dict, list)):
                wash_network_env(v, url=url, logger=logger)
    elif isinstance(o, list):
        for item in o:
            if isinstance(item, (dict, list)):
                wash_network_env(item, url=url, logger=logger)
