# Naver Map Auto-Simulation Infrastructure (V2)

## 🚀 V2 Core Architecture

V2는 V1의 물리적 의존성을 탈피하여, 실시간 패킷 검증과 순수 동적 UI 분석을 기반으로 하는 완전 무인 주행 오케스트레이션 시스템입니다.

### 🛠 V2 핵심 원칙
*   **Pure Dynamic UI (NO Hardcoding)**: 모든 UI 조작은 실시간 XML 덤프 분석을 통해 이루어집니다. 고정 좌표(`golden_bounds`)는 절대 사용하지 않으며, 텍스트와 리소스 ID 매칭으로만 작동합니다.
*   **Atomic Packet Verification**: 모든 액션(클릭 등)은 앱이 서버로 보고하는 패킷을 확인한 뒤에만 성공으로 간주하고 전진합니다. (예: `nonloginterm.checkmapservice` 감지 시에만 체크 완료 판정)
*   **Strict Session Isolation**: 모든 주행 데이터, XML 덤프, 스크린샷은 각 세션의 고유 로그 폴더(`logs/{DEV_ID}/{DATE}/{TIME}_{DEST_ID}/`) 내부에 격리 저장됩니다. 공용 폴더(`/tmp`, `screenshot/`) 사용은 엄격히 금지됩니다.
*   **Visual-Structural Audit Pair**: 모든 클릭 시점의 화면은 `.png`와 멀티라인 `.xml` 쌍으로 기록되어 사후 분석을 완벽하게 보장합니다.

### 📂 Directory Structure (V2 Isolation)
*   `test_nmap_v2/`: 핵심 엔진 및 매크로 로직.
*   `test_nmap_v2/logs/{DEV_ID}/.../`:
    *   `execution.log`: 스케줄러 흐름.
    *   `mitm.log`: 세탁된 패킷 로그.
    *   `screenshot/01.{Category}/`: 시점별 스크린샷 및 멀티라인 XML 세트.

## 🛡️ Safety & Self-Healing (V2.9.6+)

시스템의 무인 운영 안정성을 위해 최상위 오케스트레이터(`loop.sh`) 레벨에서 다중 안전장치를 운용합니다.

### 1. Global Session Timeout (15-Min Rule)
*   **작동 원리**: 작업 시작 시 생성되는 `current_task.json`의 `start_ts`를 기준으로 합니다.
*   **강제 조치**: 세션 시작 후 **15분(900초)**이 경과하면 세션 스크립트(`main.sh`)뿐만 아니라 **안드로이드 앱 패키지까지 강제 종료**(`am force-stop`)하여 좀비 세션을 원천 차단합니다.

### 2. Ghost App & Stale Session Detection
*   **Ghost App**: 스크립트 프로세스는 없으나 앱이 포그라운드에 떠 있는 경우, `loop.sh`가 이를 감지하여 앱을 종료하고 새 작업을 할당할 수 있도록 기기를 비웁니다.
*   **Stale Session**: 하트비트(Lock 파일) 갱신이 45초 이상 지연되면 해당 세션을 실패로 간주하고 프로세스를 Purge합니다.

### 3. ADB Offline Recovery
*   **소프트웨어 리셋**: 기기가 `offline` 상태로 감지되면 `adb reconnect`를 통해 재연결을 시도합니다.
*   **물리적 리셋 (USB Unbind/Bind)**: 하드웨어 레벨의 복구가 필요할 경우 다음 절차를 따릅니다 (Root 권한 필요).
     1.  `adb devices -l`로 대상 기기의 USB 버스 경로 확인 (예: `usb:1-3.3.2`)
     2.  포트 해제: `echo '1-3.3.2' | sudo tee /sys/bus/usb/drivers/usb/unbind`
     3.  포트 재연결: `echo '1-3.3.2' | sudo tee /sys/bus/usb/drivers/usb/bind`

### 4. Modular Device Initialization & Cert Recovery
*   **Modular Setup**: [device_init.sh](file:///home/tech/nmap_mini/device_init.sh)는 `device_init/modules/` 하위 모듈(`bluetooth.sh`, `sound.sh`, `disaster_alerts.sh`, `magisk_setup.sh`)을 통해 독립적으로 환경 설정을 제어합니다.
*   **Cert & Reboot Optimization**: [mitm_recovery.sh](file:///home/tech/nmap_mini/mitm_recovery.sh)는 Magisk 사용자 인증서 모듈의 MD5 해시를 대조하여 변경 사항이 없을 경우 인증서 재생성 및 기기 재부팅 단계를 건너뛰어 대기 시간을 단축합니다.

### 5. PM2 Automation Setup
*   **Wi-Fi Scheduler**: `mode_wifi/run_scheduler.sh`는 [pm2_setup.sh](file:///home/tech/nmap_mini/pm2_setup.sh)를 통해 `wifi-scheduler`라는 이름으로 PM2에 등록되며, 스케줄러 중복 방지를 위해 기본적으로 **중지(STOPPED)** 상태로 저장됩니다.

## 🔧 CLI Utilities (cmd.sh)

*   **`--light`**: 화면 밝기 복구(127), 시스템/미디어 볼륨 기본값(7) 설정, 화면 전환 애니메이션 배율 복구(1.0) 및 방해 금지 모드(Zen) 해제.
*   **`--wifi`**: 기기 주변의 Moon 및 U26- 와이파이 네트워크를 탐색하여 호스트네임에 대응하는 SSID를 기본값으로 추천 및 선택 연결합니다. 연결 과정에서 기존 저장된 와이파이 구성을 초기화(Forget)하고 `cmd wifi`로 패스워드 `13241324` 접속을 실행하며, 간헐적으로 뜨는 안드로이드 "인터넷 연결이 불안정함" 승인 팝업은 백그라운드 UI 크롤러(`wifi_clicker.py`)를 기동하여 자동 해결("항상 허용")합니다.

