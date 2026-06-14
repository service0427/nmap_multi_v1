#!/bin/bash
# K02 모뎀 복구 및 라우팅 설정 전용 스크립트
# 유선 네트워크(enp10s0)를 절대 건드리지 않고, 동글이들만 lte11~lte30으로 이름과 라우팅을 분리합니다.

echo -e "\n[1/3] K02 유선 인터넷 우선순위 재확인..."
# NMCLI를 통해 유선 인터넷(enp10s0)의 우선순위를 50으로 안전하게 고정합니다.
sudo nmcli connection modify $(sudo nmcli -t -f NAME,DEVICE connection show active 2>/dev/null | grep ":enp10s0$" | cut -d: -f1) ipv4.route-metric 50 2>/dev/null || true
sudo nmcli connection up $(sudo nmcli -t -f NAME,DEVICE connection show active 2>/dev/null | grep ":enp10s0$" | cut -d: -f1) 2>/dev/null || true

echo -e "\n[2/3] 모뎀 분리 스크립트(lte-sync) 생성 중..."
sudo bash -c 'cat << "PYEOF" > /usr/local/bin/lte-sync
#!/usr/bin/env python3
import os, subprocess, re, time

def get_gateway_ip(iface):
    try:
        subprocess.run(["dhclient", "-v", iface], timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        res = subprocess.check_output(f"ip -4 route show dev {iface}", shell=True).decode()
        for line in res.split("\n"):
            if "link" in line and "src" in line:
                return line.split()[0].replace("/24", ".1")
    except: return None

def main():
    interfaces = os.listdir("/sys/class/net")
    for iface in interfaces:
        # 모뎀으로 추정되는 이름(enx, eth, usb)만 타겟팅. 절대 enp10s0은 건드리지 않음!
        if re.match(r"^(enx|usb|eth\d+)", iface):
            gw = get_gateway_ip(iface)
            if not gw: continue
            
            try:
                subnet = gw.split(".")[2]
                new_name = f"lte{subnet}"
            except: continue
            
            print(f"Renaming {iface} to {new_name}")
            subprocess.run(["ip", "link", "set", iface, "down"])
            subprocess.run(["ip", "link", "set", iface, "name", new_name])
            subprocess.run(["ip", "link", "set", new_name, "up"])
            
            subprocess.run(["dhclient", "-v", new_name], timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            
            table_id = subnet
            subprocess.run(f"grep -q \"^{table_id} lte{table_id}\" /etc/iproute2/rt_tables || echo \"{table_id} lte{table_id}\" >> /etc/iproute2/rt_tables", shell=True)
            subprocess.run(["ip", "route", "flush", "table", str(table_id)])
            subprocess.run(["ip", "route", "add", "default", "via", gw, "dev", new_name, "table", str(table_id)])
            
            ip_out = subprocess.check_output(f"ip -4 addr show {new_name} | grep inet", shell=True).decode()
            if "inet" in ip_out:
                local_ip = ip_out.split()[1].split("/")[0]
                subprocess.run(["ip", "rule", "del", "from", local_ip, "table", str(table_id)], stderr=subprocess.DEVNULL)
                subprocess.run(["ip", "rule", "add", "from", local_ip, "table", str(table_id)])
            print(f"✅ {new_name} Synced and Isolated")

if __name__ == "__main__":
    time.sleep(2)
    main()
PYEOF'

sudo chmod +x /usr/local/bin/lte-sync

echo -e "\n[3/3] 모뎀 동기화 실행 중..."
sudo /usr/local/bin/lte-sync

echo -e "\n============================================================"
echo -e " ✅ 모든 모뎀 세팅 완료! 이제 ip a 를 쳐보시면 lte11~lte14가 예쁘게 떠있을 것입니다."
echo -e "============================================================"
