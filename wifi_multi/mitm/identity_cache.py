"""
wifi_multi/mitm/identity_cache.py: RouteEnd-Verified Dynamic Identity Caching
=============================================================================
Manages persistent caching of verified identity credentials per device and app version.

Key Lifecycle:
1. Session Execution: Fully dynamic tree replacements with zero key hardcoding.
2. RouteEnd Completion: When /drive/v3/routeend returns HTTP 200, the session is
   proven successful. A verified snapshot is saved to cache/{device_id}_verified_cache.json.
3. Next Cycle / Re-use: If current app_version matches cached app_version, verified
   credentials are immediately trusted and utilized.
4. App Upgrade Invalidation: When app_version increments, cache automatically invalidates,
   triggering fresh baseline verification.
"""

import os
import re
import json
import datetime
import threading
from typing import Optional, Dict, Any

CACHE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cache")
os.makedirs(CACHE_DIR, exist_ok=True)

_LOCK = threading.Lock()


def extract_app_version(flow_request) -> str:
    """Extracts Naver Map application version from request URL, headers, or environment."""
    if not flow_request:
        return os.environ.get("TARGET_NMAP_VERSION", "6.10.0.16")

    # 1. From caller query param
    url = getattr(flow_request, "url", "")
    m = re.search(r'caller=android_NaverMap_([0-9\.]+)', url)
    if m:
        return m.group(1)
    m = re.search(r'caller=mapmobileapps_[^&]*?app([0-9\.]+)', url)
    if m:
        return m.group(1)

    # 2. From caller header
    headers = getattr(flow_request, "headers", {})
    caller_h = headers.get("caller") or headers.get("Caller") or ""
    m = re.search(r'android_NaverMap_([0-9\.]+)', caller_h)
    if m:
        return m.group(1)
    m = re.search(r'mapmobileapps_[^&]*?app([0-9\.]+)', caller_h)
    if m:
        return m.group(1)

    # 3. From User-Agent header
    ua = headers.get("user-agent") or headers.get("User-Agent") or ""
    m = re.search(r'navermap\.v5\.android;\s*([0-9\.]+)', ua)
    if m:
        return m.group(1)
    m = re.search(r'NaverMap/([0-9\.]+)', ua)
    if m:
        return m.group(1)

    # 4. Fallback to global config or environment
    return os.environ.get("TARGET_NMAP_VERSION", "6.10.0.16")


def get_cache_path(device_id: str, app_version: Optional[str] = None) -> str:
    """Returns absolute path to verified identity cache file for given device and app version."""
    clean_dev = re.sub(r'[^a-zA-Z0-9_-]', '_', device_id.strip())
    ver_str = (app_version or "default").strip()
    clean_ver = re.sub(r'[^a-zA-Z0-9_.-]', '_', ver_str)
    return os.path.join(CACHE_DIR, f"{clean_dev}_{clean_ver}_verified_cache.json")


def load_verified_cache(device_id: str, current_app_version: Optional[str] = None) -> Optional[Dict[str, Any]]:
    """Loads verified identity cache for device and app version if available."""
    if not device_id or device_id == "Unknown":
        return None

    app_ver = (current_app_version or os.environ.get("TARGET_NMAP_VERSION", "6.10.0.16")).strip()
    cache_file = get_cache_path(device_id, app_ver)

    # Check version-specific cache first
    target_file = None
    if os.path.exists(cache_file):
        target_file = cache_file
    else:
        # Check legacy unversioned cache fallback if matching
        legacy_file = os.path.join(CACHE_DIR, f"{re.sub(r'[^a-zA-Z0-9_-]', '_', device_id.strip())}_verified_cache.json")
        if os.path.exists(legacy_file):
            try:
                with open(legacy_file, "r", encoding="utf-8") as f:
                    leg_data = json.load(f)
                if leg_data.get("app_version", "").strip() == app_ver:
                    target_file = legacy_file
            except Exception:
                pass

    if not target_file:
        return None

    with _LOCK:
        try:
            with open(target_file, "r", encoding="utf-8") as f:
                data = json.load(f)

            cached_ver = data.get("app_version", "").strip()
            if app_ver and cached_ver and cached_ver != app_ver:
                return None

            print(f" [⚡ CACHE HIT] Loaded verified identity cache for {device_id} (App Ver: {cached_ver})", flush=True)
            return data
        except Exception as e:
            print(f" [!] Error reading verified identity cache: {e}", flush=True)
            return None


def save_verified_cache(device_id: str, app_version: str, target_ids: Dict[str, Any], session_learned: Optional[Dict[str, str]] = None) -> bool:
    """Saves verified identity mapping for specific device and app version upon successful routeend HTTP 200."""
    if not device_id or device_id == "Unknown":
        return False

    app_ver = (app_version or os.environ.get("TARGET_NMAP_VERSION", "6.10.0.16")).strip()
    cache_file = get_cache_path(device_id, app_ver)
    cache_data = {
        "device_id": device_id,
        "app_version": app_ver,
        "verified_at": datetime.datetime.now().isoformat(),
        "routeend_status": 200,
        "target_ids": {k: v for k, v in target_ids.items() if v},
        "session_learned": session_learned or {}
    }

    with _LOCK:
        try:
            with open(cache_file, "w", encoding="utf-8") as f:
                json.dump(cache_data, f, ensure_ascii=False, indent=2)
            print(f" [🌟 CACHE SAVED] Verified identity cache saved for device {device_id} (App Ver: {app_ver})!", flush=True)
            return True
        except Exception as e:
            print(f" [!] Error saving verified identity cache: {e}", flush=True)
            return False


def invalidate_cache(device_id: str, app_version: Optional[str] = None) -> bool:
    """Invalidates cache for device. If app_version is given, deletes only that version;
    otherwise deletes all cached versions for this device.
    """
    clean_dev = re.sub(r'[^a-zA-Z0-9_-]', '_', device_id.strip())
    removed_any = False
    with _LOCK:
        try:
            if app_version:
                cache_file = get_cache_path(device_id, app_version)
                if os.path.exists(cache_file):
                    os.remove(cache_file)
                    print(f" [🗑️ CACHE REMOVED] Cleared identity cache for {device_id} (Ver: {app_version})", flush=True)
                    return True
            else:
                prefix = f"{clean_dev}_"
                for fn in os.listdir(CACHE_DIR):
                    if (fn.startswith(prefix) and fn.endswith("_verified_cache.json")) or fn == f"{clean_dev}_verified_cache.json":
                        try:
                            os.remove(os.path.join(CACHE_DIR, fn))
                            removed_any = True
                        except Exception:
                            pass
                if removed_any:
                    print(f" [🗑️ CACHE REMOVED] Cleared all identity caches for {device_id}", flush=True)
                    return True
        except Exception as e:
            print(f" [!] Error invalidating identity cache: {e}", flush=True)
    return False
