import os
import json
import datetime

NOISE_HOSTS = ["tivan.naver.com", "map.pstatic.net"]
NOISE_EXTS = [".mvt", ".png", ".jpg", ".jpeg", ".woff", ".ttf", ".svg", ".js", ".css", ".sdf"]

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
    host_lower = host.lower()
    path_lower = path.lower()

    # 1. 확장자 필터: 지정된 확장자가 경로에 포함되면 제외
    for ext in NOISE_EXTS:
        if ext in path_lower:
            log_filtered_url(host, path, f"EXTENSION_{ext.strip('.').upper()}")
            return False

    # 2. 도메인(노이즈) 필터: 특정 노이즈 도메인이 포함되면 제외
    for nh in NOISE_HOSTS:
        if nh in host_lower:
            log_filtered_url(host, path, f"NOISE_HOST_{nh.upper().replace('.', '_')}")
            return False

    return True

