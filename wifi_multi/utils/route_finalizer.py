import subprocess
import os

def run(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)

print("🚀 최종 네트워크 최적화 시작...")

# 1. 유선 메트릭 상향 (50)
run("sudo ip route del default dev enp4s0")
run("sudo ip route add default via 220.121.110.126 dev enp4s0 metric 50")

# 2. 이름 교정 (존재할 때만 스왑 진행)
if os.path.exists("/sys/class/net/lte11") and os.path.exists("/sys/class/net/lte12"):
    run("sudo ip link set lte11 down")
    run("sudo ip link set lte12 down")
    run("sudo ip link set lte11 name lte_tmp")
    run("sudo ip link set lte12 name lte11")
    run("sudo ip link set lte_tmp name lte12")
    run("sudo ip link set lte11 up")
    run("sudo ip link set lte12 up")
    print("🔄 lte11 ↔ lte12 이름 교정 완료")

# 3. 메트릭 및 PBR 정렬 (실제 존재하는 lte 인터페이스만 대상)
for i in range(11, 21):
    iface = f"lte{i}"
    if os.path.exists(f"/sys/class/net/{iface}"):
        metric = 200 + i
        table = i
        gw = f"192.168.{i}.1"
        
        # 기본 라우팅 제거 후 새 메트릭 추가
        run(f"sudo ip route del default via {gw} dev {iface}")
        run(f"sudo ip route add default via {gw} dev {iface} metric {metric}")
        
        # 정책 라우팅 설정
        run(f"sudo ip rule del from 192.168.{i}.0/24 table {table} priority 5209 2>/dev/null")
        run(f"sudo ip rule add from 192.168.{i}.0/24 table {table} priority 5209")
        run(f"sudo ip route replace default via {gw} dev {iface} table {table}")
        
        print(f"✅ {iface} 설정 완료 (Metric: {metric})")

print("\n📊 최종 라우팅 테이블:")
print(run("ip route show | grep default | sort").stdout)
