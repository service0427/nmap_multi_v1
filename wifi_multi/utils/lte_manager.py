#!/usr/bin/env python3
import os
import subprocess
import re

def run(cmd):
    return subprocess.getoutput(cmd)

def configure_modems():
    print("🚀 [강력 모드] LTE 모뎀 정렬 및 유선 복구 시작...")
    
    # 1. 유선 메트릭 강제 조정 (가장 높은 우선순위)
    wired_iface = "enp4s0"
    gw_info = run(f"ip route show default dev {wired_iface}")
    if gw_info:
        gw = gw_info.split()[2]
        print(f"🌐 유선 게이트웨이({gw}) 메트릭을 50으로 상향 조정...")
        run(f"sudo ip route del default dev {wired_iface} 2>/dev/null")
        run(f"sudo ip route add default via {gw} dev {wired_iface} metric 50")

    # 2. 모든 lte 인터페이스 탐색
    interfaces = os.listdir('/sys/class/net')
    
    for iface in interfaces:
        if not (iface.startswith('lte') or iface.startswith('eth') or iface.startswith('usb')):
            continue
            
        # 현재 할당된 IP 확인
        addr_info = run(f"ip -4 addr show {iface}")
        match = re.search(r'inet 192\.168\.(\d+)\.', addr_info)
        
        if match:
            subnet = int(match.group(1))
            if 11 <= subnet <= 20:
                correct_name = f"lte{subnet}"
                target_metric = 200 + subnet
                gw = f"192.168.{subnet}.1"
                
                print(f"✨ 탐색됨: {iface} (Subnet: 192.168.{subnet}.x)")
                
                # 이름이 틀리면 변경
                if iface != correct_name:
                    print(f"   -> 이름 교정: {iface} -> {correct_name}")
                    run(f"sudo ip link set {iface} down")
                    run(f"sudo ip link set {iface} name {correct_name} 2>/dev/null")
                    run(f"sudo ip link set {correct_name} up")
                    iface = correct_name

                # 라우팅 설정 (일반 메트릭은 낮게)
                run(f"sudo ip route del default via {gw} dev {iface} 2>/dev/null")
                run(f"sudo ip route add default via {gw} dev {iface} metric {target_metric}")

                # 정책 라우팅 (PBR) 적용: 특정 모뎀 고정 사용용
                table_id = subnet
                run(f"sudo ip rule del from 192.168.{subnet}.0/24 table {table_id} priority 5209 2>/dev/null")
                run(f"sudo ip rule add from 192.168.{subnet}.0/24 table {table_id} priority 5209")
                run(f"sudo ip route replace default via {gw} dev {iface} table {table_id}")
                
                print(f"✅ {iface} 설정 완료! (Metric: {target_metric}, PBR Table: {table_id})")

if __name__ == "__main__":
    if os.getuid() != 0:
        print("❌ sudo 권한으로 실행해 주세요!")
    else:
        configure_modems()
        print("\n📊 현재 기본 라우팅 순위 (Metric 낮은 순):")
        print(run("ip route show | grep default | sort -k 7 -n"))
