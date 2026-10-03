import os
from mitmproxy import http
from .whitelist import should_process
from .rules import AUDIT_LOGGER, get_target_identities
from .dynamic_tree_replacer import IdentityLookup, dynamic_walk_and_replace, dynamic_replace_headers, dynamic_replace_url_query
from .payload_codec import (
    capture_original_audit,
    decode_request_payload,
    encode_request_payload,
    get_safe_content,
    to_jsonable,
    HAS_BLACKBOX
)
from .telemetry_jitter import (
    synthesize_session_timestamps,
    smart_cleanse,
    jitter_location_dict,
    wash_network_env
)

from .identity_cache import extract_app_version, load_verified_cache

SESSION_LEARNED_IDENTITIES = {}




def handle_request(addon, flow: http.HTTPFlow):
    host = flow.request.pretty_host
    path = flow.request.path

    if not should_process(host, path):
        return

    path_lower = path.lower()
    log_dir = os.environ.get("CAPTURE_LOG_DIR")
    if log_dir:
        event_log_path = os.path.join(log_dir, "events.log")
        with open(event_log_path, "a", encoding="utf-8") as ef:
            ef.write(f"[URL] {path_lower}\n")

    # [V2.0.5] Capture original content for auditing before any modification (except large driving routes)
    orig_audit = capture_original_audit(flow.request, path_lower)
    if orig_audit:
        flow.request.trafficjam_original = orig_audit

    # 1. Target identity credentials & Dynamic Lookup with Verified Cache
    dev_id = getattr(addon, "device_id", None) or os.environ.get("NMAP_DEV_ID", "Unknown")
    app_ver = extract_app_version(flow.request)

    # Load verified cache if this session hasn't loaded it yet
    if not getattr(addon, "_cache_loaded", False):
        cached_data = load_verified_cache(dev_id, app_ver)
        if cached_data:
            cached_learned = cached_data.get("session_learned", {})
            for orig_k, spoof_v in cached_learned.items():
                if orig_k not in SESSION_LEARNED_IDENTITIES:
                    SESSION_LEARNED_IDENTITIES[orig_k] = spoof_v
            setattr(addon, "_cached_targets", cached_data.get("target_ids", {}))
        setattr(addon, "_cache_loaded", True)

    target_ids = get_target_identities()
    cached_targets = getattr(addon, "_cached_targets", {})
    for k in ["orig_ssaid", "orig_adid", "orig_idfv", "orig_ni", "orig_token"]:
        if not target_ids.get(k) and cached_targets.get(k):
            target_ids[k] = cached_targets[k]

    dynamic_lookup = IdentityLookup(target_ids)
    for orig_v, spoof_v in SESSION_LEARNED_IDENTITIES.items():
        dynamic_lookup.register(orig_v, spoof_v)

    # Protected query params and headers that must never be altered
    all_protected_query = {"caller", "x-hmac-md", "timestamp"}
    all_protected_headers = {"caller", "x-hmac-md"}

    # 2. Universal Dynamic Header & Query Parameter Replacement (Single Module)
    try:
        dynamic_replace_headers(flow.request.headers, dynamic_lookup, flow.request.url, AUDIT_LOGGER, all_protected_headers)
        flow.request.url = dynamic_replace_url_query(flow.request.url, dynamic_lookup, AUDIT_LOGGER, all_protected_query)
    except Exception as e:
        print(f"[-] Error in header/URL washing: {e}", flush=True)

    # 3. Universal Body Washing (Decoded via payload_codec -> Walk/Jitter/Wash -> Re-encoded via payload_codec)
    if get_safe_content(flow.request):
        try:
            decoded_obj, meta = decode_request_payload(flow.request)

            # A. Protobuf Processing
            if meta.encoding == "protobuf":
                # Location jittering (WiFi blanking & speed/bearing jitter)
                if "trafficjam" in path_lower or "location" in path_lower:
                    jitter_location_dict(decoded_obj)

                # Dynamic 1:1 tree replacement across entire Protobuf message
                dynamic_walk_and_replace(decoded_obj, dynamic_lookup, "pbf", flow.request.url, AUDIT_LOGGER)

                wash_network_env(decoded_obj)

                flow.request.modified_decoded = to_jsonable(decoded_obj)
                flow.request.content = encode_request_payload(decoded_obj, meta)
                return

            # B. JSON Processing (nlog, nelo, graphql, etc.)
            elif meta.encoding == "json":
                decoded_obj = synthesize_session_timestamps(decoded_obj)

                # Auto-learn from JSON usr dictionary (nlogapp, etc.)
                usr = decoded_obj.get("usr")
                if isinstance(usr, dict):
                    for k, target_k in [("idfv", "idfv"), ("adid", "adid"), ("ssaid", "ssaid"), ("ni", "ni")]:
                        cur_val = usr.get(k)
                        target_val = target_ids.get(target_k)
                        if cur_val and target_val and cur_val != target_val and len(cur_val) > 3:
                            if cur_val not in dynamic_lookup.exact_map:
                                dynamic_lookup.register(cur_val, target_val)
                                SESSION_LEARNED_IDENTITIES[cur_val] = target_val

                # Dynamic 1:1 tree replacement across entire JSON tree
                dynamic_walk_and_replace(decoded_obj, dynamic_lookup, "body", flow.request.url, AUDIT_LOGGER)

                wash_network_env(decoded_obj)

                flow.request.modified_decoded = decoded_obj
                flow.request.content = encode_request_payload(decoded_obj, meta)

                # Extract events in bulk to a flat timeline
                evts = decoded_obj.get("evts", [])
                if evts and isinstance(evts, list) and log_dir:
                    event_log_path = os.path.join(log_dir, "events.log")
                    with open(event_log_path, "a", encoding="utf-8") as ef:
                        for e in evts:
                            t = e.get("type", "unknown")
                            s = e.get("screen_name") or e.get("act_act") or (e.get("act_oval", {}).get("tab") if isinstance(e.get("act_oval"), dict) else None) or "none"
                            ef.write(f"[{t}] {s}\n")
                return

            # C. Non-target / Fallback Payload Washing
            else:
                cleansed_raw, _, _, _ = dynamic_lookup.replace_value(decoded_obj)
                flow.request.content = encode_request_payload(cleansed_raw, meta)
        except Exception as err:
            print(f"[-] Error in body washing: {err}", flush=True)
