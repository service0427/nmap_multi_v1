"""
Payload Codec Module for MITM Proxy (Autonomous & Self-Contained)
=================================================================
Handles payload format detection, original audit capture, wire-level decoding,
and exact 1:1 wire re-encoding (preserving Protobuf schemas, JSON compactness,
UTF-8 character encodings, and RFC 1952 Gzip compression).

This module is intentionally isolated from business logic (jittering, routing,
identity lookup) to guarantee encoding integrity and prevent regressions.
"""

import os
import json
import gzip
import base64
from dataclasses import dataclass
from typing import Any, Optional, Dict, Tuple

try:
    import blackboxprotobuf
    HAS_BLACKBOX = True
except ImportError:
    HAS_BLACKBOX = False


@dataclass
class PayloadMeta:
    """Metadata describing the wire format and schema of an intercepted payload."""
    encoding: str                      # "protobuf", "json", "raw", "form-urlencoded"
    is_gz: bool                        # True if wire bytes start with \x1f\x8b
    has_gz_header: bool                # True if Content-Encoding header contains gzip
    content_type: str                  # Lowers Content-Type header
    protobuf_typedef: Optional[Dict[str, Any]] = None  # Exact blackboxprotobuf typedef schema
    raw_decompressed: Optional[bytes] = None           # Uncompressed raw bytes


def to_jsonable(d: Any) -> Any:
    """Deep converts complex objects (bytes, dicts with non-str keys) to JSON-serializable structures."""
    if isinstance(d, dict):
        return {str(k): to_jsonable(v) for k, v in d.items()}
    elif isinstance(d, list):
        return [to_jsonable(v) for v in d]
    elif isinstance(d, (bytes, bytearray)):
        try:
            return d.decode('utf-8')
        except Exception:
            return f"hex:{bytes(d).hex()}"
    return d


def get_safe_content(flow_request) -> bytes:
    """Safely retrieves content from flow.request, avoiding strict decompression errors."""
    if hasattr(flow_request, "get_content"):
        try:
            c = flow_request.get_content(strict=False)
            if c is not None:
                return c
        except Exception:
            pass
    return getattr(flow_request, "content", b"") or b""


def capture_original_audit(flow_request, path_lower: str = "") -> Optional[Dict[str, Any]]:
    """Captures original wire content before any modification for audit logging.
    Unpacks Gzip transparently, decodes Protobuf/JSON, and preserves original base64 raw bytes.
    """
    if not flow_request or "driving" in path_lower:
        return None

    raw = get_safe_content(flow_request)
    if not raw:
        return None

    is_gz = raw.startswith(b'\x1f\x8b')
    try:
        work_raw = gzip.decompress(raw) if is_gz else raw
    except Exception:
        work_raw = raw

    orig_ct = flow_request.headers.get("Content-Type", "").lower()
    orig_ce = flow_request.headers.get("Content-Encoding", "").lower()

    if is_gz or "gzip" in orig_ce:
        orig_encoding = "gzip"
    elif "json" in orig_ct:
        orig_encoding = "json"
    elif "protobuf" in orig_ct or "octet-stream" in orig_ct or b"\x00" in raw:
        orig_encoding = "protobuf"
    elif "urlencoded" in orig_ct:
        orig_encoding = "form-urlencoded"
    else:
        orig_encoding = "raw"

    orig_audit = {
        "_encoding": orig_encoding,
        "_raw": "base64:" + base64.b64encode(work_raw).decode('ascii'),
        "_decoded": None
    }

    try:
        work_str = None
        try:
            work_str = work_raw.decode('utf-8')
        except Exception:
            pass

        # 1. Try JSON if content-type has json or text begins with { or [
        if "json" in orig_ct or (work_str and (work_str.strip().startswith('{') or work_str.strip().startswith('['))):
            try:
                orig_audit["_decoded"] = json.loads(work_str if work_str else work_raw.decode('utf-8', 'ignore'))
                orig_audit["_encoding"] = "json"
            except Exception:
                pass

        # 2. Try Protobuf if not already decoded and looks like protobuf/binary
        if orig_audit["_decoded"] is None and HAS_BLACKBOX and ("protobuf" in orig_ct or "octet-stream" in orig_ct or b"\x00" in work_raw):
            try:
                dec, _ = blackboxprotobuf.decode_message(work_raw)
                orig_audit["_decoded"] = to_jsonable(dec)
                orig_audit["_encoding"] = "protobuf"
            except Exception:
                pass

        # 3. Fallback to readable string if UTF-8
        if orig_audit["_decoded"] is None and work_str:
            orig_audit["_decoded"] = work_str
    except Exception:
        pass

    return orig_audit


def decode_request_payload(flow_request) -> Tuple[Any, PayloadMeta]:
    """Decodes the request body based on Content-Type, path, and wire magic bytes.
    Returns: (decoded_object, payload_meta)
    
    - For Protobuf: Returns parsed dict and preserves mt typedef in meta.protobuf_typedef.
    - For JSON: Returns parsed JSON dict/list.
    - For Fallback/Raw: Returns uncompressed bytes.
    """
    raw = get_safe_content(flow_request)
    is_gz = raw.startswith(b'\x1f\x8b')
    if is_gz:
        try:
            raw = gzip.decompress(raw)
        except Exception:
            pass

    content_type = flow_request.headers.get("Content-Type", "").lower()
    content_encoding = flow_request.headers.get("Content-Encoding", "").lower()
    has_gz_header = "gzip" in content_encoding
    path_lower = flow_request.path.lower()
    host = flow_request.pretty_host.lower()

    is_json = "json" in content_type
    is_pb_target = ("trafficjam" in path_lower or "receiver" in path_lower or 
                    "log-receiver" in host or "protobuf" in content_type or 
                    "octet-stream" in content_type)

    meta = PayloadMeta(
        encoding="raw",
        is_gz=is_gz,
        has_gz_header=has_gz_header,
        content_type=content_type,
        raw_decompressed=raw
    )

    # A. Protobuf Processing
    if not is_json and (is_pb_target or HAS_BLACKBOX):
        if HAS_BLACKBOX:
            try:
                dec, mt = blackboxprotobuf.decode_message(raw)
                if dec and isinstance(dec, dict):
                    meta.encoding = "protobuf"
                    meta.protobuf_typedef = mt
                    return dec, meta
            except Exception:
                pass

    # B. JSON Processing (nlog, nelo, graphql, etc.)
    if is_json or "nlog" in path_lower or "nelo" in path_lower:
        try:
            body_json = json.loads(raw.decode('utf-8', 'ignore'))
            meta.encoding = "json"
            return body_json, meta
        except Exception:
            pass

    # C. Non-target / Fallback Payload
    meta.encoding = "raw"
    return raw, meta


def encode_request_payload(decoded_obj: Any, meta: PayloadMeta) -> bytes:
    """Re-encodes the decoded object back into wire bytes, strictly matching the
    exact original encoding method, wire types, compact delimiters, and compression.
    """
    if meta.encoding == "protobuf" and HAS_BLACKBOX and meta.protobuf_typedef is not None:
        work = blackboxprotobuf.encode_message(decoded_obj, meta.protobuf_typedef)
        return bytes(gzip.compress(work) if meta.is_gz else work)

    elif meta.encoding == "json":
        work = json.dumps(decoded_obj, separators=(',', ':'), ensure_ascii=False).encode('utf-8')
        return bytes(gzip.compress(work) if meta.is_gz else work)

    else:
        # Raw / fallback bytes
        raw_bytes = decoded_obj if isinstance(decoded_obj, (bytes, bytearray)) else str(decoded_obj).encode('utf-8')
        return bytes(gzip.compress(raw_bytes) if meta.is_gz else raw_bytes)
