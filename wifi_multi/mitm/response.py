import json
import base64
import os
import gzip
import datetime
from mitmproxy import http
from .whitelist import should_process
from .session_logger import deep_tparse, write_packet_log

def handle_response(addon, flow: http.HTTPFlow):
    if not flow.response: return
    
    path = flow.request.path
    host = flow.request.pretty_host

    # Banner Bypass (Always Active: Supports linchpin-client, maps-event-popup, and generic popup endpoints)
    if any(k in path for k in ["linchpin-client/v2/popups", "maps-event-popup", "/popups"]) and flow.response.content:
        try:
            content = flow.response.content
            is_gz = content.startswith(b'\x1f\x8b')
            raw = gzip.decompress(content) if is_gz else content
            res_json = json.loads(raw.decode('utf-8', 'ignore'))
            for key in ["eventModal", "normalPopups", "eventNormalPopups", "eventPagePopups", "eventModalPopups"]:
                if key in res_json:
                    res_json[key] = [] if "Popups" in key else None
            work = json.dumps(res_json).encode('utf-8')
            flow.response.content = bytes(gzip.compress(work) if is_gz else work)
        except Exception:
            pass

    # [V14.2] Filter logging noise using extracted whitelist logic
    if not should_process(host, path):
        return

    # [V14.3] err-109 및 err-112 무해 경고 로그는 디스크 파일 생성을 강제 차단
    if "client-logger/errorLog" in path:
        try:
            content = flow.request.content
            if content:
                # Gzip 압축 해제
                is_gz = content.startswith(b'\x1f\x8b')
                if is_gz:
                    import gzip
                    content = gzip.decompress(content)
                body_json = json.loads(content.decode('utf-8', 'ignore'))
                msg_str = body_json.get("message")
                if msg_str:
                    msg_json = json.loads(msg_str)
                    err_code = msg_json.get("error", {}).get("code")
                    if err_code in ["err-109", "err-112"]:
                        return # 디스크 기록을 수행하지 않고 통과(Ignore)
        except:
            pass

    with addon.lock:
        addon.counter += 1
        idx = addon.counter
    
    m = flow.request.method
    cp = path.split('?')[0].replace('/', '_').strip('_')

    # [V2.0.6] Include modified body, its encoding format, and raw base64 sent to upstream server
    tj_mod = getattr(flow.request, "modified_decoded", None)
    ct_req = flow.request.headers.get("Content-Type", "").lower()
    ce_req = flow.request.headers.get("Content-Encoding", "").lower()
    req_bytes = flow.request.content or b""
    is_req_gz = req_bytes.startswith(b'\x1f\x8b') or "gzip" in ce_req

    parsed = None
    if not tj_mod:
        parsed = deep_tparse(flow.request.content, flow.request.headers.get("Content-Type", ""), path, host=host, is_response=False)

    is_parsed_json = (isinstance(parsed, (dict, list)) and "_raw" not in parsed)

    tj_orig = getattr(flow.request, "trafficjam_original", {})
    orig_enc = tj_orig.get("_encoding") if isinstance(tj_orig, dict) else None

    if orig_enc:
        req_encoding = orig_enc
    elif "json" in ct_req or (isinstance(tj_mod, dict) and "usr" in tj_mod) or is_parsed_json:
        req_encoding = "json"
    elif "protobuf" in ct_req or "octet-stream" in ct_req or b"\x00" in req_bytes:
        req_encoding = "protobuf"
    elif is_req_gz:
        req_encoding = "gzip"
    elif "urlencoded" in ct_req:
        req_encoding = "form-urlencoded"
    else:
        req_encoding = "raw"

    req_raw_b64 = ("base64:" + base64.b64encode(req_bytes).decode('ascii')) if req_bytes else ""

    if tj_mod:
        req_body = {
            "_encoding": req_encoding,
            "_raw": req_raw_b64,
            "_decoded": tj_mod
        }
    else:
        if isinstance(parsed, dict) and ("_raw" in parsed or "_decoded" in parsed):
            req_body = parsed
            if "_encoding" not in req_body:
                req_body["_encoding"] = req_encoding
            if "_raw" not in req_body and req_raw_b64:
                req_body["_raw"] = req_raw_b64
        elif parsed:
            req_body = {
                "_encoding": req_encoding,
                "_raw": req_raw_b64,
                "_decoded": parsed
            }
        else:
            req_body = ""

    tj_orig = getattr(flow.request, "trafficjam_original", {})

    full_packet = {
        "index": idx, "timestamp": datetime.datetime.now().isoformat(), "url": flow.request.url,
        "request": {
            "method": m, 
            "headers": dict(flow.request.headers), 
            "body": req_body,
            "original_body": tj_orig if tj_orig else {}
        },
        "response": {"status_code": flow.response.status_code, "headers": dict(flow.response.headers), "body": deep_tparse(flow.response.content, flow.response.headers.get("Content-Type", ""), path, host=host, is_response=True)}
    }

    fn = write_packet_log(addon.base_log_dir, idx, m, path, full_packet)

    # Append packet log summary to session_summary.json
    addon.update_summary({
        "packet": {
            "idx": idx,
            "method": m,
            "path": cp[:80],
            "status": flow.response.status_code
        }
    })

    # [RouteEnd Verified Cache Save]
    # When routeend succeeds with HTTP 200 and no errorLog/429 failures occurred,
    # create a verified snapshot cache to be reused across future cycles on the same app version.
    if "routeend" in path and flow.response.status_code == 200:
        try:
            has_error = (
                os.path.exists(os.path.join(addon.base_log_dir, "errorLog_detected")) or
                os.path.exists(os.path.join(addon.base_log_dir, "gql_429_detected"))
            )
            if not has_error:
                from .identity_cache import extract_app_version, save_verified_cache
                from .rules import get_target_identities
                from .request import SESSION_LEARNED_IDENTITIES

                dev_id = getattr(addon, "device_id", None) or os.environ.get("NMAP_DEV_ID", "Unknown")
                app_ver = extract_app_version(flow.request)
                target_ids = get_target_identities()
                cached_targets = getattr(addon, "_cached_targets", {})
                for k in ["orig_ssaid", "orig_adid", "orig_idfv", "orig_ni", "orig_token"]:
                    if not target_ids.get(k) and cached_targets.get(k):
                        target_ids[k] = cached_targets[k]

                saved = save_verified_cache(dev_id, app_ver, target_ids, SESSION_LEARNED_IDENTITIES)
                if saved:
                    if hasattr(addon, "_write_stealth_log"):
                        addon._write_stealth_log("RouteEnd Verified", f"Created verified identity cache for {dev_id} (App Ver: {app_ver})")
                    addon.update_summary({
                        "routeend_verified": True,
                        "verified_cache_saved": True
                    })
        except Exception as e:
            print(f" [!] Error saving routeend verified cache: {e}", flush=True)
