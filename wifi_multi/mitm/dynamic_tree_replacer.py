"""
wifi_multi/mitm/dynamic_tree_replacer.py
범용 재귀 트리 순회(Universal Dynamic Tree-Walker) 1:1 값 치환 엔진

핵심 원칙:
1. 엔드포인트 URL 및 필드 위치(1.1, 1.3 등)를 하드코딩하지 않고, 데이터 트리를 재귀 순회하여 값 대 값으로 1:1 매칭 치환.
2. 원본 값과 일치하지 않는 값(예: caller 'mapmobileapps_...')은 절대로 훼손하지 않음.
3. 임의의 하이픈 제거('-' stripping)를 하지 않음.
4. 모든 치환 내역을 audit logger에 투명하게 기록.
"""

import os
import re
import json

class IdentityLookup:
    """Pre-compiled lookup tables for exact identity matching and compound token replacement."""
    def __init__(self, target_ids: dict):
        self.exact_map = {}
        self.byte_map = {}
        self.token_pair = None

        orig_token = target_ids.get("orig_token")
        target_token = target_ids.get("token")
        if orig_token and target_token and orig_token != target_token:
            self.token_pair = (str(orig_token), str(target_token))

        pairs = [
            (target_ids.get("orig_ssaid"), target_ids.get("ssaid")),
            (target_ids.get("orig_adid"), target_ids.get("adid")),
            (target_ids.get("orig_idfv"), target_ids.get("idfv")),
            (target_ids.get("orig_ni"), target_ids.get("ni")),
            (target_ids.get("orig_token"), target_ids.get("token"))
        ]

        for o, s in pairs:
            if not o or not s or o == s:
                continue
            o_str = o.decode('utf-8', 'ignore').strip() if isinstance(o, (bytes, bytearray)) else str(o).strip()
            s_str = s.decode('utf-8', 'ignore').strip() if isinstance(s, (bytes, bytearray)) else str(s).strip()
            if len(o_str) <= 3:
                continue

            # 1. Exact string & case variations (NO hyphen stripping!)
            if o_str.lower() != o_str:
                self.exact_map[o_str.lower()] = s_str.lower()
            if o_str.upper() != o_str:
                self.exact_map[o_str.upper()] = s_str.upper()
            self.exact_map[o_str] = s_str

            # 2. Raw hex bytes for SSAID (16 hex -> 8 bytes) and NI (32 hex -> 16 bytes)
            if len(o_str) in [16, 32] and all(c in "0123456789abcdefABCDEF" for c in o_str):
                try:
                    b_o = bytes.fromhex(o_str)
                    b_s = bytes.fromhex(s_str)
                    self.byte_map[b_o] = b_s
                except Exception:
                    pass

            # 3. Handle 31-char hex NI (where leading zero was stripped by DB/integer conversion)
            if len(o_str) == 31 and len(s_str) in [31, 32] and all(c in "0123456789abcdefABCDEF" for c in o_str):
                o_32 = o_str.zfill(32)
                s_32 = s_str.zfill(32)
                if o_32.lower() != o_32:
                    self.exact_map[o_32.lower()] = s_32.lower()
                if o_32.upper() != o_32:
                    self.exact_map[o_32.upper()] = s_32.upper()
                self.exact_map[o_32] = s_32
                try:
                    self.byte_map[bytes.fromhex(o_32)] = bytes.fromhex(s_32)
                except Exception:
                    pass

    def replace_value(self, val):
        """Replaces a primitive string or bytes value. Returns (new_val, replaced_bool, orig_match, spoof_match)."""
        if isinstance(val, str):
            # A. Exact match
            if val in self.exact_map:
                new_v = self.exact_map[val]
                return new_v, True, val, new_v

            # B. Compound token substring (e.g. nlog_id: 'prefix.counter.token')
            if self.token_pair and self.token_pair[0] in val:
                orig_t, spoof_t = self.token_pair
                new_v = val.replace(orig_t, spoof_t)
                return new_v, True, orig_t, spoof_t

        elif isinstance(val, (bytes, bytearray)):
            b = bytes(val)
            # A. Exact raw byte match
            if b in self.byte_map:
                new_b = self.byte_map[b]
                return (new_b if isinstance(val, bytes) else bytearray(new_b)), True, b.hex()[:8], new_b.hex()[:8]

            # B. Exact string encoded in bytes
            for o_str, s_str in self.exact_map.items():
                if len(o_str) >= 8:
                    o_bytes = o_str.encode('utf-8')
                    if o_bytes in b:
                        new_b = b.replace(o_bytes, s_str.encode('utf-8'))
                        return (new_b if isinstance(val, bytes) else bytearray(new_b)), True, o_str[:6], s_str[:6]

        return val, False, None, None


def dynamic_walk_and_replace(data, lookup: IdentityLookup, path="", url="", logger=None):
    """
    Recursively walks any JSON or Protobuf dictionary/list and replaces matching identities 1:1.
    Modifies in-place where possible and returns the sanitized object.
    """
    if isinstance(data, dict):
        for k in list(data.keys()):
            v = data[k]
            cur_path = f"{path}.{k}" if path else str(k)
            if isinstance(v, (dict, list)):
                dynamic_walk_and_replace(v, lookup, cur_path, url, logger)
            else:
                new_v, replaced, orig_m, spoof_m = lookup.replace_value(v)
                if replaced:
                    data[k] = new_v
                    if logger:
                        logger.record(url, "dynamic_walker", "tree_node", cur_path, orig_m, spoof_m)
        return data

    elif isinstance(data, list):
        for i in range(len(data)):
            item = data[i]
            cur_path = f"{path}[{i}]"
            if isinstance(item, (dict, list)):
                dynamic_walk_and_replace(item, lookup, cur_path, url, logger)
            else:
                new_v, replaced, orig_m, spoof_m = lookup.replace_value(item)
                if replaced:
                    data[i] = new_v
                    if logger:
                        logger.record(url, "dynamic_walker", "list_item", cur_path, orig_m, spoof_m)
        return data

    else:
        new_v, replaced, orig_m, spoof_m = lookup.replace_value(data)
        if replaced and logger:
            logger.record(url, "dynamic_walker", "primitive", path or "root", orig_m, spoof_m)
        return new_v


def dynamic_replace_headers(headers, lookup: IdentityLookup, url="", logger=None, protected_headers=None):
    """Dynamically replaces matching identity values in HTTP headers and Cookies."""
    prot = set(h.lower() for h in (protected_headers or []))
    prot.update(["authorization", "host", "content-length", "content-type", "accept-encoding"])
    for k in list(headers.keys()):
        if k.lower() in prot:
            continue
        val = headers[k]
        new_v, replaced, orig_m, spoof_m = lookup.replace_value(val)
        if replaced:
            headers[k] = new_v
            if logger:
                logger.record(url, "dynamic_walker", "header", k, orig_m, spoof_m)
        elif k.lower() == "cookie" and isinstance(val, str):
            # Check for cookie substrings like NAPP_DI=...
            mod_cookie = val
            cookie_modified = False
            for o_str, s_str in lookup.exact_map.items():
                if len(o_str) >= 16 and o_str in mod_cookie:
                    mod_cookie = mod_cookie.replace(o_str, s_str)
                    cookie_modified = True
                    if logger:
                        logger.record(url, "dynamic_walker", "cookie", "cookie_substring", o_str[:8], s_str[:8])
            if cookie_modified:
                headers[k] = mod_cookie


def dynamic_replace_url_query(url_str: str, lookup: IdentityLookup, logger=None, protected_query=None) -> str:
    """Dynamically replaces matching identity values in URL query parameters."""
    if "?" not in url_str:
        return url_str

    prot = set(q.lower() for q in (protected_query or []))
    base_part, query_part = url_str.split("?", 1)
    q_items = query_part.split("&")
    new_q_items = []
    modified = False

    for item in q_items:
        if "=" in item:
            k, v = item.split("=", 1)
            if k.lower() in prot:
                new_q_items.append(item)
                continue
            new_v, replaced, orig_m, spoof_m = lookup.replace_value(v)
            if replaced:
                item = f"{k}={new_v}"
                modified = True
                if logger:
                    logger.record(url_str, "dynamic_walker", "query_param", k, orig_m, spoof_m)
        new_q_items.append(item)

    return f"{base_part}?{'&'.join(new_q_items)}" if modified else url_str

