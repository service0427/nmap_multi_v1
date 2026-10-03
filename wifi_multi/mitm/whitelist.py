import os
import json
import datetime

# 1. 허용할 타겟 도메인 (Suffix 기준 엄격한 화이트리스트)
ALLOWED_DOMAINS = [
    "naver.com",
    "navercorp.com",
    "naver.net",
    "clova.ai"
]

# 2. 네이버 내부 대용량 미디어 및 스트리밍 노이즈 호스트
INTERNAL_NOISE_HOSTS = [
    "tivan.naver.com",
    "pstatic.net"
]

# 3. 정적 리소스 확장자 필터
NOISE_EXTS = [".mvt", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".zip", ".woff", ".ttf", ".svg", ".js", ".css", ".sdf"]

def log_filtered_url(host: str, path: str, reason: str):
    """Logs the filtered URL into the session log directory for future reference"""
    log_dir = os.environ.get("CAPTURE_LOG_DIR")
    if not log_dir or not os.path.exists(log_dir):
        return

    log_file = os.path.join(log_dir, "filtered_urls.jsonl")
    data = {
        "timestamp": datetime.datetime.now().isoformat(),
        "reason": reason,
        "host": host,
        "path": path
    }

    try:
        with open(log_file, "a", encoding="utf-8") as f:
            f.write(json.dumps(data, ensure_ascii=False) + "\n")
    except:
        pass

def should_process(host: str, path: str) -> bool:
    host_clean = host.lower().split(':')[0].strip()
    path_lower = path.lower()

    # 1. [True Whitelist Gate] 네이버 공식 도메인이 아닌 모든 외부 도메인은 즉시 차단/스킵
    if not any(host_clean == d or host_clean.endswith("." + d) for d in ALLOWED_DOMAINS):
        log_filtered_url(host, path, f"EXTERNAL_DOMAIN_{host_clean.replace('.', '_')}")
        return False

    # 2. Exclude blocked client-logger/errorLog from being logged to disk
    if os.environ.get("ERRORLOG_FILTER", "true").lower() == "true" and "client-logger/errorLog" in path_lower:
        return False

    # 3. 네이버 내부 대용량 미디어 및 스트리밍 호스트 필터
    for nh in INTERNAL_NOISE_HOSTS:
        if nh in host_clean:
            log_filtered_url(host, path, f"INTERNAL_NOISE_{nh.upper().replace('.', '_')}")
            return False

    # 4. 확장자 필터: 지정된 정적 확장자가 경로에 포함되면 제외
    for ext in NOISE_EXTS:
        if ext in path_lower:
            log_filtered_url(host, path, f"EXTENSION_{ext.strip('.').upper()}")
            return False

    return True

