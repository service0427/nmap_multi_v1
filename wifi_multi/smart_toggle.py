#!/usr/bin/env python3
"""
스마트 토글 시스템
진단 → 단계별 복구로 안정적인 토글 보장

작성자: Claude Code
작성일: 2025-01-15
"""

import sys
import json
import time
import subprocess
import os
from datetime import datetime, timezone, timedelta
from huawei_lte_api.Client import Client
from huawei_lte_api.Connection import Connection

# 설정
USERNAME = "admin"
PASSWORD = "KdjLch!@7024"
TIMEOUT = 10
MAPPING_FILE = "/home/proxy/scripts/usb_mapping.json"

# 결과 전송 설정
RESULT_CALLBACK_URLS = [
    ("http://61.84.75.37:10002/toggle/start", "http://61.84.75.37:10002/toggle/result"),  # 운영
    ("http://61.84.75.37:44010/toggle/start", "http://61.84.75.37:44010/toggle/result"),  # 개발
]
RESULT_CALLBACK_ENABLED = False

def get_server_ip():
    """메인 이더넷 인터페이스(eno1)에서 서버 IP 추출"""
    try:
        result = subprocess.run(
            "ip addr show eno1 | grep 'inet ' | awk '{print $2}' | cut -d/ -f1",
            shell=True, capture_output=True, text=True, timeout=5
        )
        ip = result.stdout.strip()
        if ip and ip.split('.')[0].isdigit():
            return ip
    except:
        pass

    # eno1 실패 시 첫 번째 공인 IP를 가진 인터페이스 찾기
    try:
        result = subprocess.run(
            "ip route get 8.8.8.8 | grep -oP 'src \\K[0-9.]+'",
            shell=True, capture_output=True, text=True, timeout=5
        )
        ip = result.stdout.strip()
        if ip and ip.split('.')[0].isdigit():
            return ip
    except:
        pass

    return None

def send_start_callback(subnet):
    """토글 시작을 외부 서버로 전송"""
    if not RESULT_CALLBACK_ENABLED:
        return

    try:
        import requests

        payload = {
            'server_ip': get_server_ip(),
            'port': 10000 + subnet
        }

        for start_url, _ in RESULT_CALLBACK_URLS:
            try:
                requests.post(start_url, json=payload, timeout=5)
            except Exception:
                pass
    except Exception:
        pass

def send_result_callback(subnet, output):
    """토글 결과를 외부 서버로 전송"""
    if not RESULT_CALLBACK_ENABLED:
        return

    try:
        import requests

        payload = output.copy()
        payload['server_ip'] = get_server_ip()
        payload['port'] = 10000 + subnet

        for _, result_url in RESULT_CALLBACK_URLS:
            try:
                requests.post(result_url, json=payload, timeout=5)
            except Exception:
                pass
    except Exception:
        # 콜백 실패해도 무시 (메인 기능에 영향 없음)
        pass

class SmartToggle:
    def __init__(self, subnet):
        self.subnet = subnet
        self.result = {
            'success': False,
            'ip': None,
            'traffic': {'upload': 0, 'download': 0},
            'signal': None,
            'step': 0
        }
        self.start_time = time.time()
        self.diagnosis = {}  # 진단 정보는 내부용으로만 사용

        # 라우팅 테이블 이름 자동 감지
        self.routing_table = self.detect_routing_table()
    
    def detect_routing_table(self):
        """라우팅 테이블 이름/번호 자동 감지"""
        import subprocess
        
        # 1. IP rule이 참조하는 테이블 우선 확인 (가장 중요!)
        result = subprocess.run(
            f"ip rule show | grep 'from 192.168.{self.subnet}.' | awk '{{print $NF}}' | head -n 1",
            shell=True, capture_output=True, text=True
        )
        rule_table = result.stdout.strip()
        if rule_table:
            return rule_table
        
        # 2. subnet 번호 직접 사용 (현재 서버)
        result = subprocess.run(f"ip route show table {self.subnet} 2>/dev/null | head -1",
                              shell=True, capture_output=True, text=True)
        if result.stdout.strip():
            return str(self.subnet)
        
        # 3. dongle{subnet} 이름 사용
        table_name = f"dongle{self.subnet}"
        result = subprocess.run(f"ip route show table {table_name} 2>/dev/null | head -1",
                              shell=True, capture_output=True, text=True)
        if result.stdout.strip():
            return table_name
        
        # 4. 100+subnet 번호 사용
        table_id = 100 + self.subnet
        result = subprocess.run(f"ip route show table {table_id} 2>/dev/null | head -1",
                              shell=True, capture_output=True, text=True)
        if result.stdout.strip():
            return str(table_id)
        
        # 기본값: subnet 번호 (새로 생성될 테이블용)
        return str(self.subnet)
    
    def log_step(self, step, name, result, duration=None, details=None):
        """복구 단계 로깅 (디버깅용, 출력에는 포함 안됨)"""
        # 필요시 로그 파일에 기록
        pass
    
    def diagnose_problem(self):
        """0단계: 문제 진단 (99% 정상 경로 최적화: 외부 통신/핑 테스트 제거하여 병목 차단)"""
        diagnosis = {}
        
        try:
            # 인터페이스 존재 확인
            interface = self.get_interface()
            
            diagnosis['interface_exists'] = bool(interface)
            diagnosis['interface'] = interface
            
            if interface:
                # 99% 정상 시나리오를 위한 초고속 IP 획득 (로컬 캐시용, 최대 1.5초 대기)
                result = subprocess.run(f"curl --interface {interface} -s -m 1.5 http://techb.kr/ip.php",
                                      shell=True, capture_output=True, text=True, timeout=2)
                ip = result.stdout.strip()
                if ip and ip.split('.')[0].isdigit():
                    diagnosis['external_reachable'] = True
                    diagnosis['current_ip'] = ip
                else:
                    diagnosis['external_reachable'] = True
                    diagnosis['current_ip'] = "0.0.0.0"
                
                # Check if routing and ip rules exist in the kernel locally (very fast)
                routing_exists = False
                try:
                    res_route = subprocess.run(f"ip route show table {self.routing_table} default", shell=True, capture_output=True, text=True, timeout=2)
                    if "default via" in res_route.stdout:
                        routing_exists = True
                except:
                    pass
                
                ip_rule_exists = False
                local_ip = self.get_local_ip()
                if local_ip:
                    try:
                        import re
                        res_rule = subprocess.run("ip rule show", shell=True, capture_output=True, text=True, timeout=2)
                        for line in res_rule.stdout.strip().split('\n'):
                            if f"from {local_ip}" in line:
                                if f"lookup {self.routing_table}" in line or f"lookup {self.subnet}" in line:
                                    parts = line.strip().split(':', 1)
                                    if len(parts) > 0:
                                        try:
                                            priority = int(parts[0].strip())
                                            if priority < 5210:
                                                ip_rule_exists = True
                                                break
                                        except ValueError:
                                            pass
                    except:
                        pass
                
                diagnosis['routing_exists'] = routing_exists
                diagnosis['ip_rule_exists'] = ip_rule_exists
                diagnosis['socks5_service_active'] = True
                diagnosis['socks5_issue'] = False
                diagnosis['gateway_reachable'] = True
            else:
                diagnosis['routing_exists'] = False
                diagnosis['ip_rule_exists'] = False
                diagnosis['external_reachable'] = False
                diagnosis['gateway_reachable'] = False
                diagnosis['current_ip'] = None
                diagnosis['socks5_issue'] = False
            
        except Exception as e:
            diagnosis['error'] = str(e)
            diagnosis['interface_exists'] = False
            diagnosis['current_ip'] = None
        
        self.diagnosis = diagnosis  # 내부용으로 저장
        return diagnosis
    
    def restart_socks5(self):
        """긴급 복구: SOCKS5 서비스 재시작 (서비스가 죽었거나 HTTPS 안 될 때)"""
        try:
            # 개별 SOCKS5 서비스 재시작
            result = subprocess.run(f"sudo systemctl restart dongle-socks5-{self.subnet}", 
                                  shell=True, capture_output=True, text=True, timeout=10)
            
            if result.returncode == 0:
                # 재시작 후 서비스 안정화 대기
                time.sleep(3)
                
                # 서비스 상태 확인
                status_check = subprocess.run(f"systemctl is-active dongle-socks5-{self.subnet}",
                                            shell=True, capture_output=True, text=True, timeout=5)
                
                if status_check.stdout.strip() == "active":
                    # 연결 테스트
                    return self.test_connectivity_https()
            
            return False
        except Exception as e:
            return False
    
    def fix_routing(self):
        """1단계: 라우팅 재설정"""
        try:
            interface = self.diagnosis.get('interface')
            if not interface:
                return False
            
            success = True
            
            # 라우팅 테이블 추가 (자동 감지된 테이블 사용)
            if not self.diagnosis.get('routing_exists'):
                cmd = f"ip route add default via 192.168.{self.subnet}.1 dev {interface} table {self.routing_table}"
                result = subprocess.run(f"sudo {cmd}", shell=True, capture_output=True, text=True, timeout=10)
                if result.returncode != 0 and "File exists" not in result.stderr:
                    success = False
            
            # IP rule 추가 (자동 감지된 테이블 사용)
            if not self.diagnosis.get('ip_rule_exists'):
                local_ip = self.get_local_ip()
                if local_ip:
                    # Clean up outdated rules first
                    try:
                        import re
                        rules_output = subprocess.check_output(["ip", "rule", "show"]).decode()
                        for line in rules_output.strip().split('\n'):
                            if f"lookup {self.routing_table}" in line or f"table {self.routing_table}" in line or f"lookup {self.subnet}" in line or f"table {self.subnet}" in line:
                                parts = line.split(':', 1)
                                if len(parts) >= 2:
                                    priority = parts[0].strip()
                                    rule_detail = parts[1].strip()
                                    ip_match = re.search(r'from ([0-9./]+)', rule_detail)
                                    if ip_match:
                                        rule_ip = ip_match.group(1)
                                        if rule_ip != local_ip:
                                            # Outdated rule, delete it
                                            subprocess.run(f"sudo ip rule del from {rule_ip} table {self.routing_table} priority {priority}", shell=True, stderr=subprocess.DEVNULL)
                                            subprocess.run(f"sudo ip rule del from {rule_ip} table {self.subnet} priority {priority}", shell=True, stderr=subprocess.DEVNULL)
                    except:
                        pass
                    
                    cmd = f"ip rule add from {local_ip} table {self.routing_table} priority 5209"
                    result = subprocess.run(f"sudo {cmd}", shell=True, capture_output=True, text=True, timeout=10)
                    if result.returncode != 0 and "File exists" not in result.stderr:
                        # try with subnet number
                        cmd_alt = f"ip rule add from {local_ip} table {self.subnet} priority 5209"
                        res_alt = subprocess.run(f"sudo {cmd_alt}", shell=True, capture_output=True, text=True, timeout=10)
                        if res_alt.returncode != 0 and "File exists" not in res_alt.stderr:
                            success = False
                else:
                    rule_src = f"192.168.{self.subnet}.0/24"
                    cmd = f"ip rule add from {rule_src} table {self.routing_table} priority 5209"
                    result = subprocess.run(f"sudo {cmd}", shell=True, capture_output=True, text=True, timeout=10)
                    if result.returncode != 0 and "File exists" not in result.stderr:
                        cmd_alt = f"ip rule add from {rule_src} table {self.subnet} priority 5209"
                        res_alt = subprocess.run(f"sudo {cmd_alt}", shell=True, capture_output=True, text=True, timeout=10)
                        if res_alt.returncode != 0 and "File exists" not in res_alt.stderr:
                            success = False
            
            if success:
                # 3초 대기 후 연결 테스트
                time.sleep(3)
                if self.test_connectivity():
                    return True
                return False
            
            return False
            
        except Exception as e:
            self.log_step(1, 'routing_fix', 'failed', details={'error': str(e)})
            return False
    
    def normal_toggle(self):
        """2단계: 일반 네트워크 토글"""
        try:
            old_ip = self.diagnosis.get('current_ip')
            
            # Huawei API 연결
            modem_ip = f"192.168.{self.subnet}.1"
            connection = Connection(f'http://{modem_ip}/', username=USERNAME, password=PASSWORD, timeout=TIMEOUT)
            
            # Already login 처리
            try:
                client = Client(connection)
            except Exception as e:
                if "Already login" in str(e):
                    self.logout_modem(modem_ip)
                    time.sleep(1)
                    connection = Connection(f'http://{modem_ip}/', username=USERNAME, password=PASSWORD, timeout=TIMEOUT)
                    client = Client(connection)
                else:
                    raise
            
            # 현재 네트워크 모드
            current_mode = client.net.net_mode()
            
            # AUTO → LTE 전환
            client.net.set_net_mode(
                networkmode='00',  # AUTO
                networkband=current_mode['NetworkBand'],
                lteband=current_mode['LTEBand']
            )
            time.sleep(3)
            
            client.net.set_net_mode(
                networkmode='03',  # LTE only
                networkband=current_mode['NetworkBand'],
                lteband=current_mode['LTEBand']
            )
            
            # IP 변경 대기 (최대 30초)
            for i in range(30):
                time.sleep(1)
                new_ip = self.get_current_ip()
                
                # IP를 가져왔고 변경되었으면 성공
                if new_ip and new_ip != old_ip:
                    self.result['ip'] = new_ip

                    # 트래픽 통계
                    try:
                        stats = client.monitoring.traffic_statistics()
                        self.result['traffic'] = {
                            'upload': int(stats['TotalUpload']),
                            'download': int(stats['TotalDownload'])
                        }
                    except Exception as e:
                        # 실패해도 기본값 유지
                        pass

                    # 신호 정보 수집
                    try:
                        signal = client.device.signal()

                        # 신호 값 파싱 (dBm, dB 제거)
                        def parse_signal_value(value):
                            if value is None or value == 'None':
                                return None
                            try:
                                if isinstance(value, str):
                                    value = value.replace('dBm', '').replace('dB', '').strip()
                                return float(value)
                            except:
                                return None

                        rsrp = parse_signal_value(signal.get('rsrp'))
                        rsrq = parse_signal_value(signal.get('rsrq'))
                        rssi = parse_signal_value(signal.get('rssi'))
                        sinr = parse_signal_value(signal.get('sinr'))

                        self.result['signal'] = {
                            'rsrp': rsrp,
                            'rsrq': rsrq,
                            'rssi': rssi,
                            'sinr': sinr,
                            'band': signal.get('band'),
                            'cell_id': signal.get('cell_id'),
                            'pci': signal.get('pci'),
                            'plmn': signal.get('plmn')
                        }
                    except:
                        pass

                    return True
                
                # 10초 후에도 연결 안되면 조기 종료
                if i >= 10 and not new_ip:
                    # 라우팅 문제일 가능성이 높음
                    return False
            
            # 시간 초과 - 마지막 IP 확인
            final_ip = self.get_current_ip()
            if final_ip and final_ip != old_ip:
                self.result['ip'] = final_ip
                # 마지막으로 트래픽 시도
                try:
                    stats = client.monitoring.traffic_statistics()
                    self.result['traffic'] = {
                        'upload': int(stats['TotalUpload']),
                        'download': int(stats['TotalDownload'])
                    }
                except:
                    pass

                # 마지막으로 신호 정보 시도
                try:
                    signal = client.device.signal()

                    def parse_signal_value(value):
                        if value is None or value == 'None':
                            return None
                        try:
                            if isinstance(value, str):
                                value = value.replace('dBm', '').replace('dB', '').strip()
                            return float(value)
                        except:
                            return None

                    rsrp = parse_signal_value(signal.get('rsrp'))
                    rsrq = parse_signal_value(signal.get('rsrq'))
                    rssi = parse_signal_value(signal.get('rssi'))
                    sinr = parse_signal_value(signal.get('sinr'))

                    self.result['signal'] = {
                        'rsrp': rsrp,
                        'rsrq': rsrq,
                        'rssi': rssi,
                        'sinr': sinr,
                        'band': signal.get('band'),
                        'cell_id': signal.get('cell_id'),
                        'pci': signal.get('pci'),
                        'plmn': signal.get('plmn')
                    }
                except:
                    pass

                return True
                
            return False
            
        except Exception as e:
            self.log_step(2, 'network_toggle', 'failed', details={'error': str(e)})
            return False
    
    def usb_reset(self):
        """3단계: USB unbind/bind"""
        try:
            interface = self.diagnosis.get('interface')
            if not interface:
                return False
            
            # USB 경로 찾기
            cmd = f"ls -la /sys/class/net/{interface}/device/driver/ | grep {interface} | awk '{{print $9}}'"
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=5)
            usb_path = result.stdout.strip()
            
            if not usb_path:
                return False
            
            # USB 매핑 업데이트 (존재할 경우에만 수행)
            if os.path.exists(MAPPING_FILE):
                try:
                    with open(MAPPING_FILE, 'r') as f:
                        mapping = json.load(f)
                    
                    device_info = mapping.get(str(self.subnet))
                    if device_info:
                        device_info['usb_path'] = usb_path
                        device_info['interface'] = interface
                        device_info['last_seen'] = datetime.now().isoformat()
                        
                        with open(MAPPING_FILE, 'w') as f:
                            json.dump(mapping, f, indent=2)
                except Exception as me:
                    sys.stderr.write(f"[{self.subnet}] Warning: Failed to update mapping file: {me}\n")
            
            # unbind
            subprocess.run(f"echo '{usb_path}' | sudo tee /sys/bus/usb/drivers/cdc_ether/unbind > /dev/null",
                          shell=True, timeout=5)
            time.sleep(3)
            
            # bind
            subprocess.run(f"echo '{usb_path}' | sudo tee /sys/bus/usb/drivers/cdc_ether/bind > /dev/null",
                          shell=True, timeout=5)
            
            # [안전 장치] USB 재연결 직후 인터페이스 이름 및 라우팅 복구 실행 (최대 3회 재시도)
            project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            fix_script = os.path.join(project_root, "fix_eth_number.sh")
            
            for attempt in range(3):
                time.sleep(5)  # 디바이스가 커널에 등록되고 IP를 할당받을 대기 시간 부여
                sys.stderr.write(f"[{self.subnet}] Running fix_eth_number.sh (Attempt {attempt+1}/3) to restore interface names and routing...\n")
                try:
                    subprocess.run(["sudo", sys.executable, fix_script], timeout=30)
                except Exception as fe:
                    sys.stderr.write(f"[{self.subnet}] Warning: Failed to run fix_eth_number.sh: {fe}\n")
                
                if self.test_connectivity():
                    return True
            
            return False
            
        except Exception as e:
            self.log_step(3, 'usb_reset', 'failed', details={'error': str(e)})
            return False
    
    def power_cycle(self):
        """4단계: 전원 재시작 (개별 시도 후 실패 시 전체 허브 재시작)"""
        try:
            power_script = "/home/proxy/scripts/power_control.sh"
            if not os.path.exists(power_script):
                sys.stderr.write(f"[{self.subnet}] Power control script {power_script} not found, skipping power cycle.\n")
                return False
                
            # 1차 시도: 개별 포트 재시작
            result = subprocess.run(f"sudo {power_script} off {self.subnet}",
                                   shell=True, capture_output=True, text=True, timeout=10)
            
            if result.returncode != 0:
                # 개별 포트 제어 실패
                self.log_step(4, 'power_cycle', 'individual_failed', 
                            details={'message': 'Individual port control failed, trying full hub reset'})
            else:
                time.sleep(5)
                
                result = subprocess.run(f"sudo {power_script} on {self.subnet}",
                                       shell=True, capture_output=True, text=True, timeout=10)
                
                if result.returncode == 0:
                    # [안전 장치] 개별 포트 전원 ON 직후 인터페이스 이름 및 라우팅 복구 실행 (최대 3회 재시도)
                    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
                    fix_script = os.path.join(project_root, "fix_eth_number.sh")
                    
                    for attempt in range(3):
                        time.sleep(10)  # 모뎀이 켜지고 시스템에 인식될 때까지 충분히 대기 (보통 8~10초 소요)
                        sys.stderr.write(f"[{self.subnet}] Running fix_eth_number.sh (Attempt {attempt+1}/3) to restore interface names and routing...\n")
                        try:
                            subprocess.run(["sudo", sys.executable, fix_script], timeout=30)
                        except Exception as fe:
                            sys.stderr.write(f"[{self.subnet}] Warning: Failed to run fix_eth_number.sh: {fe}\n")
                        
                        if self.test_connectivity():
                            return True
            
            # 2차 시도: 전체 허브 재시작은 활성화된 다른 모뎀들에 치명적이므로 안전하게 비활성화합니다.
            self.log_step(4, 'power_cycle', 'full_reset_disabled', 
                        details={'message': 'Full hub reset is disabled to protect other active modems.'})
            sys.stderr.write(f"[{self.subnet}] Full hub reset is disabled to protect other active modems.\n")
            return False
            
        except Exception as e:
            self.log_step(4, 'power_cycle', 'failed', details={'error': str(e)})
            return False
    
    def test_connectivity(self):
        """외부 연결 테스트 (HTTPS 우선, HTTP 폴백)"""
        try:
            if self.test_connectivity_https():
                return True
            if self.test_connectivity_http():
                return True
            return False
        except:
            return False
    
    def test_connectivity_https(self):
        """항상 HTTPS로 테스트 (다중화)"""
        try:
            interface = self.get_interface()
            if not interface:
                return False
            
            test_urls = ["https://api.ipify.org", "https://ifconfig.me/ip", "https://icanhazip.com", "https://ident.me"]
            for url in test_urls:
                try:
                    result = subprocess.run(f"curl --interface {interface} -s -m 3 {url}",
                                          shell=True, capture_output=True, text=True, timeout=5)
                    ip = result.stdout.strip()
                    if ip and ip.split('.')[0].isdigit():
                        self.result['ip'] = ip
                        return True
                except:
                    continue
            return False
        except:
            return False
    
    def test_connectivity_http(self):
        """폴백용 HTTP 테스트 (다중화)"""
        try:
            interface = self.get_interface()
            if not interface:
                return False
            
            test_urls = ["http://techb.kr/ip.php", "http://ifconfig.me/ip", "http://icanhazip.com", "http://ident.me"]
            for url in test_urls:
                try:
                    result = subprocess.run(f"curl --interface {interface} -s -m 3 {url}",
                                          shell=True, capture_output=True, text=True, timeout=5)
                    ip = result.stdout.strip()
                    if ip and ip.split('.')[0].isdigit():
                        self.result['ip'] = ip
                        return True
                except:
                    continue
            return False
        except:
            return False
    
    def get_current_ip(self):
        """현재 외부 IP 확인 (HTTPS 우선, HTTP 폴백 다중화)"""
        try:
            interface = self.get_interface()
            if not interface:
                return None
            
            # HTTPS 먼저 시도 (다중화)
            test_urls_https = ["https://api.ipify.org", "https://ifconfig.me/ip", "https://icanhazip.com", "https://ident.me"]
            for url in test_urls_https:
                try:
                    result = subprocess.run(f"curl --interface {interface} -s -m 3 {url}",
                                          shell=True, capture_output=True, text=True, timeout=5)
                    ip = result.stdout.strip()
                    if ip and ip.split('.')[0].isdigit():
                        return ip
                except:
                    continue
            
            # HTTPS 실패시 HTTP 시도 (다중화)
            test_urls_http = ["http://techb.kr/ip.php", "http://ifconfig.me/ip", "http://icanhazip.com", "http://ident.me"]
            for url in test_urls_http:
                try:
                    result = subprocess.run(f"curl --interface {interface} -s -m 3 {url}",
                                          shell=True, capture_output=True, text=True, timeout=5)
                    ip = result.stdout.strip()
                    if ip and ip.split('.')[0].isdigit():
                        return ip
                except:
                    continue
            
            return None
        except:
            return None
    
    def get_interface(self):
        """인터페이스명 획득"""
        try:
            # 1. First try lte{subnet}
            iface = f"lte{self.subnet}"
            if os.path.exists(f"/sys/class/net/{iface}"):
                return iface
            
            # 2. Fallback to searching by subnet IP prefix (e.g. 192.168.11.)
            cmd = f"ip addr | grep '192.168.{self.subnet}.' -B2 | head -1 | cut -d: -f2 | tr -d ' '"
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=5)
            iface_found = result.stdout.strip().split('@')[0]
            
            # 만약 다른 이름(eth11 등)으로 변경되어 있다면, fix_eth_number.sh를 즉시 실행하여 원래 이름으로 복구
            if iface_found and iface_found != iface:
                sys.stderr.write(f"[{self.subnet}] Misnamed interface detected: {iface_found}. Running fix_eth_number.sh to restore to {iface}...\n")
                try:
                    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
                    fix_script = os.path.join(project_root, "fix_eth_number.sh")
                    subprocess.run(["sudo", sys.executable, fix_script], timeout=30)
                except Exception as fe:
                    sys.stderr.write(f"[{self.subnet}] Warning: Failed to run fix_eth_number.sh: {fe}\n")
                
                # 복구 후 다시 lte{subnet} 확인
                if os.path.exists(f"/sys/class/net/{iface}"):
                    return iface
            
            if iface_found:
                return iface_found
        except:
            pass
        return None

    def get_local_ip(self):
        """인터페이스에 할당된 실제 IP 획득"""
        try:
            interface = self.get_interface()
            if not interface:
                return None
            cmd = f"ip -4 addr show {interface} | grep inet | awk '{{print $2}}' | cut -d/ -f1"
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=5)
            return result.stdout.strip()
        except:
            return None
    
    def logout_modem(self, modem_ip):
        """모뎀 로그아웃"""
        try:
            import requests
            logout_url = f'http://{modem_ip}/api/user/logout'
            logout_data = '<?xml version="1.0" encoding="UTF-8"?><request><Logout>1</Logout></request>'
            requests.post(logout_url, data=logout_data, 
                         headers={'Content-Type': 'application/xml'}, timeout=2)
        except:
            pass
    
    def get_traffic_info(self):
        """트래픽 정보 및 신호 정보 수집 (복구 완료 후 실행)"""
        try:
            modem_ip = f'192.168.{self.subnet}.1'
            connection = Connection(f'http://{modem_ip}/', username=USERNAME, password=PASSWORD, timeout=TIMEOUT)

            # Already login 처리
            try:
                client = Client(connection)
            except Exception as e:
                if "Already login" in str(e):
                    self.logout_modem(modem_ip)
                    time.sleep(1)
                    connection = Connection(f'http://{modem_ip}/', username=USERNAME, password=PASSWORD, timeout=TIMEOUT)
                    client = Client(connection)
                else:
                    raise

            # 트래픽 통계 가져오기
            stats = client.monitoring.traffic_statistics()
            self.result['traffic'] = {
                'upload': int(stats['TotalUpload']),
                'download': int(stats['TotalDownload'])
            }

            # 신호 정보 가져오기
            try:
                signal = client.device.signal()

                # 신호 값 파싱 (dBm, dB 제거)
                def parse_signal_value(value):
                    if value is None or value == 'None':
                        return None
                    try:
                        # 문자열에서 숫자만 추출
                        if isinstance(value, str):
                            value = value.replace('dBm', '').replace('dB', '').strip()
                        return float(value)
                    except:
                        return None

                rsrp = parse_signal_value(signal.get('rsrp'))
                rsrq = parse_signal_value(signal.get('rsrq'))
                rssi = parse_signal_value(signal.get('rssi'))
                sinr = parse_signal_value(signal.get('sinr'))

                self.result['signal'] = {
                    'rsrp': rsrp,
                    'rsrq': rsrq,
                    'rssi': rssi,
                    'sinr': sinr,
                    'band': signal.get('band'),
                    'cell_id': signal.get('cell_id'),
                    'pci': signal.get('pci'),
                    'plmn': signal.get('plmn')
                }
            except Exception as e:
                # 신호 정보 실패시 None으로 설정
                self.result['signal'] = None

        except Exception as e:
            # 실패시 기본값 유지
            self.result['traffic'] = {'upload': 0, 'download': 0}
            self.result['signal'] = None
    
    def verify_socks5(self):
        """SOCKS5 프록시 작동 확인 (현재 인프라에서 SOCKS5 미사용하므로 항상 True 반환)"""
        return True
    
    def execute(self):
        """스마트 토글 실행"""
        # 토글 시작 콜백
        send_start_callback(self.subnet)

        try:
            # 0단계: 진단
            diagnosis = self.diagnose_problem()
            
            # SOCKS5 서비스가 죽어있거나 SOCKS5 문제가 있으면 빠른 해결
            if not diagnosis.get('socks5_service_active', True) or diagnosis.get('socks5_issue'):
                # SOCKS5 서비스가 비활성이거나 HTTP는 되는데 HTTPS 안 되는 경우
                if self.restart_socks5():
                    # SOCKS5 검증 추가
                    if self.verify_socks5():
                        self.result['success'] = True
                        self.result['step'] = 0  # 간단한 재시작으로 해결
                        # 트래픽 정보 수집
                        self.get_traffic_info()
                        return self.result
            
            # 진단 결과에 따른 시작 단계 결정
            is_normal = False
            if not diagnosis.get('interface_exists'):
                start_step = 3  # USB부터 시작
            elif not diagnosis.get('routing_exists') or not diagnosis.get('ip_rule_exists'):
                start_step = 1  # 라우팅부터 시작
            elif not diagnosis.get('external_reachable'):
                start_step = 2  # 토글부터 시작
            else:
                # 이미 정상 - 토글만 실행
                start_step = 2
                is_normal = True  # 정상 상태 표시
            
            # 단계별 복구 시도
            recovery_methods = [
                (1, 'routing_fix', self.fix_routing),
                (2, 'network_toggle', self.normal_toggle),
                (3, 'usb_reset', self.usb_reset),
                (4, 'power_cycle', self.power_cycle)
            ]
            
            for step, name, method in recovery_methods:
                if step < start_step:
                    continue
                
                try:
                    success = method()
                    
                    if success:
                        # Step 2 (network toggle) 직후는 SOCKS5 검증 스킵
                        if step == 2:
                            self.skip_socks5_verify = True
                            
                        # SOCKS5 검증 추가
                        if self.verify_socks5():
                            self.result['success'] = True
                            # step 번호 설정: 정상 상태에서 토글만 했으면 0, 아니면 해당 단계 번호
                            if is_normal and step == 2:
                                self.result['step'] = 0
                            else:
                                self.result['step'] = step
                            break
                        else:
                            # SOCKS5 검증 실패 시 다음 단계로
                            self.result['step'] = step
                        
                        # 검증 스킵 플래그 리셋
                        if hasattr(self, 'skip_socks5_verify'):
                            del self.skip_socks5_verify
                    else:
                        # 실패했으면 마지막 시도한 단계 저장
                        self.result['step'] = step
                        
                except Exception as e:
                    # 에러 발생 시에도 마지막 시도한 단계 저장
                    self.result['step'] = step
            
            # 최종 결과 설정
            if self.result['success']:
                # 성공 시 트래픽 정보 수집 (이미 normal_toggle에서 가져온 경우 제외)
                if not self.result.get('traffic') or self.result['traffic'] == {'upload': 0, 'download': 0}:
                    self.get_traffic_info()
            
            return self.result
            
        except Exception as e:
            return self.result

def main():
    if len(sys.argv) != 2:
        print(json.dumps({'error': 'Usage: smart_toggle.py <subnet>'}))
        sys.exit(1)

    try:
        subnet = int(sys.argv[1])
        if subnet < 11 or subnet > 30:
            raise ValueError('Subnet must be between 11 and 30')

        toggle = SmartToggle(subnet)
        result = toggle.execute()
        # 간소화된 출력만 반환
        output = {
            'success': result.get('success', False),
            'ip': result.get('ip'),
            'traffic': result.get('traffic', {'upload': 0, 'download': 0}),
            'signal': result.get('signal'),
            'step': result.get('step', 0)
        }
        print(json.dumps(output, ensure_ascii=False))

        # 결과 전송
        send_result_callback(subnet, output)

    except Exception as e:
        # 실패 시에도 동일한 형식으로 출력
        output = {
            'success': False,
            'ip': None,
            'traffic': {'upload': 0, 'download': 0},
            'signal': None,
            'step': 4  # 마지막 단계까지 시도했다고 가정
        }
        print(json.dumps(output, ensure_ascii=False))

        # 실패 결과도 전송
        try:
            subnet = int(sys.argv[1])
            send_result_callback(subnet, output)
        except:
            pass

        sys.exit(1)

if __name__ == '__main__':
    main()