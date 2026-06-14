#!/usr/bin/env python3
"""
Multi-Modem IP Rotator (LTE IP 갱신 자동화)
- 4개의 모뎀(lte11 ~ lte14)을 독립적으로 120~180분마다 랜덤하게 토글합니다.
- 토글 시 smart_toggle.py를 호출하여 IP를 변경합니다.
"""

import time
import random
import subprocess
import threading
import os
import sys

SUBNETS = [11, 12, 13, 14]
MIN_MINUTES = 120
MAX_MINUTES = 180

def get_now():
    return time.strftime("%Y-%m-%d %H:%M:%S")

def rotate_modem(subnet):
    # 각 모뎀이 동시에 재시작되지 않도록 초기 시작 시간을 다르게 분산 (10분 ~ 60분)
    initial_stagger = random.randint(10, 60) * 60
    print(f"[{get_now()}] [Subnet {subnet}] 대기: 초기 랜덤 분산 {initial_stagger // 60}분 후 첫 토글 시작", flush=True)
    time.sleep(initial_stagger)

    script_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "smart_toggle.py")

    while True:
        print(f"[{get_now()}] [Subnet {subnet}] IP 토글 진행 중...", flush=True)
        try:
            result = subprocess.run(
                [sys.executable, script_path, str(subnet)],
                capture_output=True, text=True, timeout=120
            )
            print(f"[{get_now()}] [Subnet {subnet}] 토글 완료: {result.stdout.strip()}", flush=True)
        except subprocess.TimeoutExpired:
            print(f"[{get_now()}] [Subnet {subnet}] [!] 토글 타임아웃 (120s 초과)", flush=True)
        except Exception as e:
            print(f"[{get_now()}] [Subnet {subnet}] [!] 토글 스크립트 실행 실패: {e}", flush=True)
        
        sleep_mins = random.randint(MIN_MINUTES, MAX_MINUTES)
        print(f"[{get_now()}] [Subnet {subnet}] 다음 토글은 {sleep_mins}분 뒤에 실행됩니다.", flush=True)
        time.sleep(sleep_mins * 60)

if __name__ == "__main__":
    print(f"[{get_now()}] Multi-Modem IP Rotator 시작됨 (Subnets: {SUBNETS})", flush=True)
    
    threads = []
    for s in SUBNETS:
        t = threading.Thread(target=rotate_modem, args=(s,))
        t.daemon = True
        t.start()
        threads.append(t)
    
    try:
        while True:
            time.sleep(60)
    except KeyboardInterrupt:
        print(f"[{get_now()}] IP Rotator 종료됨.", flush=True)
