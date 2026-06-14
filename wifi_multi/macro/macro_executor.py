import json
import sys
import os
import time
from ui_clicker import click_element, chain_click

# [V11.6] Advanced Macro Definitions (including Modal handling)
MACRO_MAP = {
    "entry_search_field": {
        "queries": ["exact:네이버지도 검색"],
        "padding": 0,
        "desc": "메인 화면 검색창 진입"
    },
    "btn_start_guidance": {
        "queries": ["exact:안내시작"],
        "padding": 15,
        "desc": "자동차 길찾기 시작"
    },
    "btn_start_guidance_modal": {
        "queries": ["exact:안내시작"],
        "padding": 10,
        "desc": "영업시간 알림 모달 내 안내시작"
    },
    "btn_end_guidance": {
        "queries": ["text:안내종료"],
        "padding": 15,
        "desc": "목적지 도착 후 안내 종료"
    }
}

def run_step(device_id, step_id, category="default"):
    if any(step_id.startswith(prefix) for prefix in ["text:", "exact:", "id:", "desc:", "contains:"]):
        print(f"[*] Executing Direct Query: {step_id}")
        return click_element(device_id, step_id, category=category)

    if step_id in MACRO_MAP:
        cfg = MACRO_MAP[step_id]
        print(f"[*] Macro [{step_id}] Started: {cfg['desc']}")
        queries = cfg["queries"]
        padding = cfg.get("padding", 10)
        
        if len(queries) == 1:
            return click_element(device_id, queries[0], padding=padding, category=category)
        else:
            return chain_click(device_id, queries, padding=padding, category=category)

    print(f" [-] Error: Unknown Macro ID or Query Format: '{step_id}'")
    return False

if __name__ == "__main__":
    if len(sys.argv) < 3: sys.exit(1)
    dev_id = sys.argv[1]
    steps = sys.argv[2].split(',')
    cat = sys.argv[3] if len(sys.argv) >= 4 else "default"
    
    success = True
    for s in steps:
        if not run_step(dev_id, s.strip(), category=cat):
            success = False
            break
            
    sys.exit(0 if success else 1)
