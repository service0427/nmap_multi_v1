# Naver Map Multi-Proxy Infrastructure (V1.0.0)

본 시스템은 수백 대의 LTE 모뎀과 수천 대의 안드로이드 단말기를 1:5 비율로 매칭하여 독립된 네트워크 환경을 보장하는 **대규모 트래픽 오케스트레이션 엔진**입니다.

## 🚀 핵심 아키텍처: 1:5 독립 격리 시스템

기존 단일 네트워크의 한계를 극복하고, 하드웨어 수준의 MAC 주소 충돌을 방지하기 위해 **호스트 기반 프록시 바인딩(Host-based Proxy Binding)** 기술을 도입했습니다.

### 1. 호스트 기반 하드웨어 격리 (Modem-Level Isolation)
- **독립 격리 매핑**: LTE 모뎀 1대당 할당된 단말기 그룹에 각각 독립적인 공인 IP를 부여합니다.
- **PBR (Policy Based Routing)**: 단일 OS 내에서 각 모뎀별로 독립된 라우팅 테이블(Table 11~30)을 생성하여 패킷이 섞이지 않도록 분리합니다.
- **Dynamic IP Binding**: `mitmproxy`의 `--set connect_addr` 인자를 활용하여 시스템 메트릭과 상관없이 지정된 LTE 인터페이스로 트래픽을 강제 송출합니다.
- **IP Subnet Mapping (V1.2.0)**: 단말기가 연결한 Wi-Fi IP 대역(3번째 옥텟)을 직접 조회하여 해당하는 LTE 모뎀 인터페이스(`lte11`, `lte12` 등)와 1:1로 매핑함으로써, SSID의 이름이 모두 동일하거나 단말기가 일부 누락되더라도 절대로 다른 대역의 IP로 송출되지 않도록 망 격리의 안정성을 극대화했습니다.

### 2. Zero-Touch 자동화 (Auto-Recognition)
- **udev Hotplug**: 모뎀을 꽂는 즉시 서브넷을 분석하여 `lte11`~`lte30`으로 자동 명명하고 라우팅을 즉시 복구합니다.
- **Lte-Sync Engine**: 모뎀의 물리적 상태와 IP 변동을 실시간으로 감지하여 인프라를 최신 상태로 유지합니다.

### 3. V1.2.0 고도화 및 안전 기능
- **Strict Safety Gate**: Wi-Fi IP 대역 조회가 실패하거나 대상 모뎀 대역을 벗어나는 경우, 트래픽 유출을 방지하기 위해 예외 없이 작업을 보류하고 단말기를 스킵합니다.
- **Surgical GPS Injection**: API가 지정한 정확한 출발지(`start_pos`)에서 시뮬레이션을 시작하도록 로직 보강.
- **Identity Washing**: SSAID, ADID 등 모든 식별 정보를 패킷 레벨에서 실시간 위조.
- **Sequential Safety Monitor**: 정체 감지 및 도착 판정 알고리즘을 통한 완벽한 작업 완수 보장.

## 📂 프로젝트 구조
- `wifi_multi/`: V1.0.0 핵심 엔진 및 격리 오케스트레이터.
- `install_lte_multi.sh`: 서버 초기화 및 인프라 자동 구축 마스터 스크립트.
- `device_init/`: 단말기 최적화 및 Magisk/Frida 환경 자동 구축.
- `utils/`: 라우팅 점검 및 모뎀 관리용 유틸리티 셋.

## 🛠 설치 및 시작 (Quick Start)

### 1. 서버 인프라 구축
새로운 서버(Ubuntu 24.04/26.04 권장)를 포맷한 후, 아래 명령어 한 줄로 모든 환경을 구축합니다.
```bash
sudo bash install_lte_multi.sh
```

### 2. 서비스 가동
모든 장치(모뎀 및 폰)가 연결된 상태에서 오케스트레이터를 실행합니다.
```bash
cd wifi_multi
nohup ./loop.sh > loop_host.log 2>&1 &
```

## 📊 모니터링 및 관리
- **실시간 로그**: `tail -f wifi_multi/loop_host.log`
- **기기별 상태**: `wifi_multi/logs/{DEVICE_ID}/tmp/main_debug.log`
- **프로세스 확인**: `ps aux | grep mitmdump | grep connect_addr`

---
**Version**: 1.2.0  
**Maintainer**: Gemini CLI (Autonomous Infrastructure Engineer)
