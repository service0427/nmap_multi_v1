import json
import base64
import os
import datetime
from mitmproxy import http
from .whitelist import should_process

def handle_response(addon, flow: http.HTTPFlow):
    if not flow.response: return
    
    path = flow.request.path
    host = flow.request.pretty_host

    # Banner Bypass (Always Active)
    if "linchpin-client/v2/popups" in path and flow.response.content:
        try:
            res_json = json.loads(flow.response.content.decode('utf-8', 'ignore'))
            for key in ["eventModal", "normalPopups", "eventNormalPopups", "eventPagePopups", "eventModalPopups"]:
                if key in res_json: res_json[key] = [] if "Popups" in key else None
            flow.response.content = json.dumps(res_json).encode('utf-8')
        except: pass

    # [V14.2] Filter logging noise using extracted whitelist logic
    if not should_process(host, path):
        return

    with addon.lock:
        addon.counter += 1
        idx = addon.counter
    
    m = flow.request.method
    cp = path.split('?')[0].replace('/', '_').strip('_')
    fn = f"{idx:03d}_{m}_{cp[:80]}.json"

    # [V1 STYLE] Recursive Deep Decoding for Logging
    def deep_tparse(c, ct, p="", is_response=False):
        if not c: return ""
        ct_l = ct.lower()
        
        # JSON (Check for nested base64 for logs)
        if "json" in ct_l or "nlogapp" in p:
            try: 
                bj = json.loads(c.decode('utf-8'))
                
                # 부하가 상당히 심하므로 response 에서는 base64 디코딩 및 body_protobuf 해석 처리를 생략합니다.
                if is_response:
                    return bj
                    
                def scan(o):
                    if isinstance(o, dict):
                        res = {k: scan(v) for k, v in o.items()}
                        for k, v in o.items():
                            if isinstance(v, str) and v.startswith("base64:"):
                                try:
                                    raw = base64.b64decode(v[7:])
                                    d = addon.try_pbf_decode(raw)
                                    if d: res[k + "_decoded"] = d
                                except: pass
                        return res
                    elif isinstance(o, list): return [scan(i) for i in o]
                    return o
                return scan(bj)
            except: pass
        
        # Binary / Protobuf
        if "octet-stream" in ct_l or "protobuf" in ct_l or b"\x00" in c:
            b64_str = "base64:" + base64.b64encode(c).decode('ascii')
            
            # 부하가 상당히 심하므로 response 에서는 base64 디코딩 및 body_protobuf 해석 처리를 생략합니다.
            if is_response:
                return b64_str
                
            decoded = addon.try_pbf_decode(c)
            if decoded: return {"_raw": b64_str, "_decoded": decoded}
            return b64_str
        
        try: return c.decode('utf-8', 'ignore')
        except: return "base64:" + base64.b64encode(c).decode('ascii')

    # [V2.0.5] include trafficjam original body if captured in request phase
    tj_mod = getattr(flow.request, "modified_decoded", None)
    if tj_mod:
        req_body = {
            "_raw": "base64:" + base64.b64encode(flow.request.content).decode('ascii'),
            "_decoded": tj_mod
        }
    else:
        req_body = deep_tparse(flow.request.content, flow.request.headers.get("Content-Type", ""), path, is_response=False)
        
    tj_orig = getattr(flow.request, "trafficjam_original", {})

    full_packet = {
        "index": idx, "timestamp": datetime.datetime.now().isoformat(), "url": flow.request.url,
        "request": {
            "method": m, 
            "headers": dict(flow.request.headers), 
            "body": req_body,
            "original_body": tj_orig if tj_orig else {}
        },
        "response": {"status_code": flow.response.status_code, "headers": dict(flow.response.headers), "body": deep_tparse(flow.response.content, flow.response.headers.get("Content-Type", ""), path, is_response=True)}
    }

    with open(os.path.join(addon.base_log_dir, fn), "w") as f:
        json.dump(full_packet, f, ensure_ascii=False, indent=2)
