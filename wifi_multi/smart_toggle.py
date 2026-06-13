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
RESULT_CALLBACK_ENABLED = True

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
            f"ip rule show | grep 'from 192.168.{self.subnet}.100' | awk '{{print $NF}}'",
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
        """0단계: 문제 진단"""
        diagnosis = {}
        
        try:
            # 인터페이스 존재 확인
            cmd = f"ip addr | grep '192.168.{self.subnet}.100' -B2 | head -1 | cut -d: -f2 | tr -d ' '"
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=5)
            interface = result.stdout.strip()
            
            diagnosis['interface_exists'] = bool(interface)
            diagnosis['interface'] = interface
            
            if interface:
                # 라우팅 테이블 확인 (자동 감지된 테이블 사용)
                result = subprocess.run(f"ip route show table {self.routing_table}", 
                                      shell=True, capture_output=True, text=True, timeout=5)
                diagnosis['routing_exists'] = "default" in result.stdout
                
                # IP rule 확인 (어떤 테이블을 참조하든 존재 여부만 확인)
                result = subprocess.run(f"ip rule show | grep 'from 192.168.{self.subnet}.100'",
                                      shell=True, capture_output=True, text=True, timeout=5)
                diagnosis['ip_rule_exists'] = bool(result.stdout.strip())
                
                # 외부 연결 테스트 (HTTP와 HTTPS 병렬 체크)
                import concurrent.futures
                
                def check_http():
                    result = subprocess.run(f"curl --interface {interface} -s -m 3 http://techb.kr/ip.php",
                                          shell=True, capture_output=True, text=True, timeout=5)
                    return result.stdout.strip()
                
                def check_https():
                    result = subprocess.run(f"curl --interface {interface} -s -m 3 https://api.ipify.org",
                                          shell=True, capture_output=True, text=True, timeout=5)
                    return result.stdout.strip()
                
                # 병렬로 두 체크 실행
                with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
                    future_http = executor.submit(check_http)
                    future_https = executor.submit(check_https)
                    
                    http_ip = future_http.result(timeout=5)
                    https_ip = future_https.result(timeout=5)
                
                diagnosis['http_reachable'] = bool(http_ip and http_ip.split('.')[0].isdigit())
                diagnosis['https_reachable'] = bool(https_ip and https_ip.split('.')[0].isdigit())
                
                # SOCKS5 서비스 상태 확인 (중요!)
                socks5_check = subprocess.run(f"systemctl is-active dongle-socks5-{self.subnet}",
                                             shell=True, capture_output=True, text=True, timeout=5)
                diagnosis['socks5_service_active'] = socks5_check.stdout.strip() == "active"
                
                # 외부 연결 판단 (HTTPS 우선, HTTP 폴백)
                if diagnosis['https_reachable']:
                    diagnosis['external_reachable'] = True
                    diagnosis['current_ip'] = https_ip
                elif diagnosis['http_reachable']:
                    diagnosis['external_reachable'] = True
                    diagnosis['current_ip'] = http_ip
                    diagnosis['socks5_issue'] = True  # HTTP는 되는데 HTTPS 안 되면 SOCKS5 문제
                else:
                    diagnosis['external_reachable'] = False
                    diagnosis['current_ip'] = None
                    diagnosis['socks5_issue'] = False
                
                # 게이트웨이 연결 확인
                result = subprocess.run(f"ping -c 1 -W 2 -I {interface} 192.168.{self.subnet}.1",
                                      shell=True, capture_output=True, text=True, timeout=5)
                diagnosis['gateway_reachable'] = result.returncode == 0
                
            else:
                diagnosis['routing_exists'] = False
                diagnosis['ip_rule_exists'] = False
                diagnosis['external_reachable'] = False
                diagnosis['http_reachable'] = False
                diagnosis['https_reachable'] = False
                diagnosis['gateway_reachable'] = False
                diagnosis['current_ip'] = None
                diagnosis['socks5_issue'] = False
            
        except Exception as e:
            diagnosis['error'] = str(e)
        
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
                cmd = f"ip rule add from 192.168.{self.subnet}.100 table {self.routing_table}"
                result = subprocess.run(f"sudo {cmd}", shell=True, capture_output=True, text=True, timeout=10)
                if result.returncode != 0 and "File exists" not in result.stderr:
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
            # USB 매핑 로드
            with open(MAPPING_FILE, 'r') as f:
                mapping = json.load(f)
            
            device_info = mapping.get(str(self.subnet))
            if not device_info:
                return False
            
            interface = self.diagnosis.get('interface')
            if not interface:
                return False
            
            # USB 경로 찾기
            cmd = f"ls -la /sys/class/net/{interface}/device/driver/ | grep {interface} | awk '{{print $9}}'"
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=5)
            usb_path = result.stdout.strip()
            
            if not usb_path:
                return False
            
            # USB 매핑 업데이트
            device_info['usb_path'] = usb_path
            device_info['interface'] = interface
            device_info['last_seen'] = datetime.now().isoformat()
            
            with open(MAPPING_FILE, 'w') as f:
                json.dump(mapping, f, indent=2)
            
            # unbind
            subprocess.run(f"echo '{usb_path}' | sudo tee /sys/bus/usb/drivers/cdc_ether/unbind > /dev/null",
                          shell=True, timeout=5)
            time.sleep(3)
            
            # bind
            subprocess.run(f"echo '{usb_path}' | sudo tee /sys/bus/usb/drivers/cdc_ether/bind > /dev/null",
                          shell=True, timeout=5)
            
            # 인터페이스 재연결 대기 (최대 15초)
            for i in range(15):
                time.sleep(1)
                if self.test_connectivity():
                    return True
            
            return False
            
        except Exception as e:
            self.log_step(3, 'usb_reset', 'failed', details={'error': str(e)})
            return False
    
    def power_cycle(self):
        """4단계: 전원 재시작 (개별 시도 후 실패 시 전체 허브 재시작)"""
        try:
            # 1차 시도: 개별 포트 재시작
            result = subprocess.run(f"sudo /home/proxy/scripts/power_control.sh off {self.subnet}",
                                  shell=True, capture_output=True, text=True, timeout=10)
            
            if result.returncode != 0:
                # 개별 포트 제어 실패
                self.log_step(4, 'power_cycle', 'individual_failed', 
                            details={'message': 'Individual port control failed, trying full hub reset'})
            else:
                time.sleep(5)
                
                result = subprocess.run(f"sudo /home/proxy/scripts/power_control.sh on {self.subnet}",
                                      shell=True, capture_output=True, text=True, timeout=10)
                
                if result.returncode == 0:
                    # 복구 대기 (최대 30초)
                    for i in range(30):
                        time.sleep(1)
                        if self.test_connectivity():
                            return True
            
            # 2차 시도: 전체 허브 재시작
            self.log_step(4, 'power_cycle', 'trying_full_reset', 
                        details={'message': 'Individual reset failed, attempting full hub reset'})
            
            # dongle_config.json에서 허브 정보 가져오기
            try:
                with open('/home/proxy/config/dongle_config.json', 'r') as f:
                    config = json.load(f)
                    
                if 'port_mapping' in config and str(self.subnet) in config['port_mapping']:
                    hub = config['port_mapping'][str(self.subnet)]['hub']
                else:
                    # 기본값: 서브넷 번호로 추정
                    if self.subnet >= 11 and self.subnet <= 14:
                        hub = "1-3.4"
                    elif self.subnet >= 15 and self.subnet <= 18:
                        hub = "1-3.1"
                    else:
                        hub = "1-3.3"
                
                # 전체 허브 재시작
                result = subprocess.run(f"sudo uhubctl -a cycle -l {hub} -p 1,2,3,4",
                                      shell=True, capture_output=True, text=True, timeout=15)
                
                if result.returncode == 0:
                    # 복구 대기 (최대 60초)
                    time.sleep(10)  # 허브 재시작 대기
                    for i in range(50):
                        time.sleep(1)
                        if self.test_connectivity():
                            return True
                            
            except Exception as e:
                self.log_step(4, 'power_cycle', 'hub_reset_failed', 
                            details={'error': str(e)})
            
            return False
            
        except Exception as e:
            self.log_step(4, 'power_cycle', 'failed', details={'error': str(e)})
            return False
    
    def test_connectivity(self):
        """외부 연결 테스트 (HTTPS 우선, HTTP 폴백)"""
        try:
            # HTTPS 먼저 시도
            ip = self.test_connectivity_https()
            if ip:
                return True
            
            # HTTPS 실패시 HTTP 시도
            ip = self.test_connectivity_http()
            if ip:
                # HTTP는 되는데 HTTPS 안 되면 개별 SOCKS5 재시작
                subprocess.run(f"sudo systemctl restart dongle-socks5-{self.subnet}", shell=True, timeout=10)
                time.sleep(2)
                # 다시 HTTPS 시도
                ip = self.test_connectivity_https()
                if ip:
                    return True
            
            return False
        except:
            return False
    
    def test_connectivity_https(self):
        """항상 HTTPS로 테스트"""
        try:
            interface = self.get_interface()
            if not interface:
                return False
            
            result = subprocess.run(f"curl --interface {interface} -s -m 3 https://api.ipify.org",
                                  shell=True, capture_output=True, text=True, timeout=5)
            ip = result.stdout.strip()
            
            if ip and ip.split('.')[0].isdigit():
                self.result['ip'] = ip
                return True
            
            return False
        except:
            return False
    
    def test_connectivity_http(self):
        """폴백용 HTTP 테스트"""
        try:
            interface = self.get_interface()
            if not interface:
                return False
            
            result = subprocess.run(f"curl --interface {interface} -s -m 3 http://techb.kr/ip.php",
                                  shell=True, capture_output=True, text=True, timeout=5)
            ip = result.stdout.strip()
            
            if ip and ip.split('.')[0].isdigit():
                self.result['ip'] = ip
                return True
            
            return False
        except:
            return False
    
    def get_current_ip(self):
        """현재 외부 IP 확인 (HTTPS 우선, HTTP 폴백)"""
        try:
            interface = self.get_interface()
            if not interface:
                return None
            
            # HTTPS 먼저 시도
            result = subprocess.run(f"curl --interface {interface} -s -m 3 https://api.ipify.org",
                                  shell=True, capture_output=True, text=True, timeout=5)
            ip = result.stdout.strip()
            
            if ip and ip.split('.')[0].isdigit():
                return ip
            
            # HTTPS 실패시 HTTP 시도
            result = subprocess.run(f"curl --interface {interface} -s -m 3 http://techb.kr/ip.php",
                                  shell=True, capture_output=True, text=True, timeout=5)
            ip = result.stdout.strip()
            
            if ip and ip.split('.')[0].isdigit():
                return ip
            
            return None
        except:
            return None
    
    def get_interface(self):
        """인터페이스명 획득"""
        try:
            cmd = f"ip addr | grep '192.168.{self.subnet}.100' -B2 | head -1 | cut -d: -f2 | tr -d ' '"
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
        """SOCKS5 프록시 작동 확인"""
        try:
            # Step 0, 2는 SOCKS5 검증 불필요 (네트워크 토글 직후)
            if hasattr(self, 'skip_socks5_verify') and self.skip_socks5_verify:
                return True
                
            port = 10000 + self.subnet
            # SOCKS5를 통한 HTTPS 연결 테스트
            result = subprocess.run(
                f"curl --socks5 127.0.0.1:{port} -s -m 3 https://api.ipify.org",
                shell=True, capture_output=True, text=True, timeout=5
            )
            ip = result.stdout.strip()
            
            if ip and ip.split('.')[0].isdigit():
                return True
            
            # SOCKS5가 작동하지 않으면 개별 서비스 재시작
            subprocess.run(f"sudo systemctl restart dongle-socks5-{self.subnet}", shell=True, timeout=10)
            time.sleep(2)
            
            # 재시도
            result = subprocess.run(
                f"curl --socks5 127.0.0.1:{port} -s -m 3 https://api.ipify.org",
                shell=True, capture_output=True, text=True, timeout=5
            )
            ip = result.stdout.strip()
            
            return ip and ip.split('.')[0].isdigit()
        except:
            return False
    
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