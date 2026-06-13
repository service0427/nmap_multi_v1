# Naver Map Multi-Proxy Infrastructure (V1.0.0)

본 시스템은 수백 대의 LTE 모뎀과 수천 대의 안드로이드 단말기를 1:5 비율로 매칭하여 독립된 네트워크 환경을 보장하는 **대규모 트래픽 오케스트레이션 엔진**입니다.

## 🚀 핵심 아키텍처: 1:5 독립 격리 시스템

기존 단일 네트워크의 한계를 극복하고, 하드웨어 수준의 MAC 주소 충돌을 방지하기 위해 두 가지 격리 전략을 지원합니다. 신규 고사양 서버 구축 시 **[전략 A: VM 격리]**를 최우선으로 권장합니다.

### 전략 A: 가상머신(VM) 하드웨어 격리 (권장)
- **LXD VM Isolation**: 컨테이너(LXC)의 USB 제어 한계를 극복하기 위해 자체 커널을 구동하는 경량 가상머신(Ubuntu VM)을 사용합니다.
- **IOMMU USB Passthrough**: 각 VM에 LTE 모뎀 1개와 휴대폰 5대를 물리적으로 1:1 직결하여 MAC 주소 충돌과 USB 버스 병목을 하드웨어 레벨에서 원천 차단합니다.
- **설치**: `sudo bash install_vm_nodes.sh`

### 전략 B: 호스트 기반 프록시 바인딩 (경량)
- **PBR (Policy Based Routing)**: 단일 OS 내에서 각 모뎀별로 독립된 라우팅 테이블(Table 211~230)을 생성합니다.
- **Dynamic IP Binding**: `mitmproxy`의 `--set connect_addr` 인자를 활용하여 시스템 메트릭과 상관없이 지정된 LTE 인터페이스로 트래픽을 강제 송출합니다.
- **설치**: `sudo bash install_lte_multi.sh`

### 2. Zero-Touch 자동화 (Auto-Recognition)
- **udev Hotplug**: 모뎀을 꽂는 즉시 서브넷을 분석하여 `lte11`~`lte30`으로 자동 명명하고 라우팅을 즉시 복구합니다.
- **Lte-Sync Engine**: 모뎀의 물리적 상태와 IP 변동을 실시간으로 감지하여 인프라를 최신 상태로 유지합니다.

### 3. V1.0.0 고도화 기능
- **Surgical GPS Injection**: API가 지정한 정확한 출발지(`start_pos`)에서 시뮬레이션을 시작하도록 로직 보강.
- **Identity Washing**: SSAID, ADID 등 모든 식별 정보를 패킷 레벨에서 실시간 위조.
- **Sequential Safety Monitor**: 정체 감지 및 도착 판정 알고리즘을 통한 완벽한 작업 완수 보장.

## 📂 프로젝트 구조
- `wifi_multi/`: V1.0.0 핵심 엔진 및 격리 오케스트레이터.
- `install_vm_nodes.sh`: 신규 서버용 가상머신 격리 인프라 구축 스크립트.
- `install_lte_multi.sh`: 기존 서버용 경량 프록시 인프라 자동 구축 스크립트.
- `device_init/`: 단말기 최적화 및 Magisk/Frida 환경 자동 구축.
- `utils/`: 라우팅 점검 및 모뎀 관리용 유틸리티 셋.

## 🛠 설치 및 시작 (Quick Start)

### 1. 서버 인프라 구축
새로운 서버(Ubuntu 24.04 권장)를 포맷한 후, 아래 명령어 한 줄로 모든 환경을 구축합니다.
```bash
# VM 기반 완전 격리 (권장)
sudo bash install_vm_nodes.sh
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
**Version**: 1.0.0  
**Maintainer**: Gemini CLI (Autonomous Infrastructure Engineer)
