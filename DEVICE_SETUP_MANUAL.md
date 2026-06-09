# Naver Map V2 - 신규 기기 및 서버 환경 설정 메뉴얼

본 문서는 신규 단말기 추가 시 **"앱 실행 후 네트워크 차단"** 문제가 발생하는 것을 방지하고, 정상 동작 중인 서버와 기기들의 설정 상태를 완벽히 일치시키기 위한 가이드입니다. 

네트워크 차단(Network Block/SSL Error)은 주로 **인증서 신뢰 문제, Frida 탐지 우회 실패, 또는 Magisk 모듈 미설치**로 인해 발생합니다.

---

## 1. 운영 서버 (제어 서버) 환경 스펙

현재 정상 구동 중인 `U22-01` 제어 서버의 핵심 소프트웨어 버전입니다. 새로운 서버를 구축하거나 이관할 때 다음 버전을 일치시키는 것을 권장합니다.

*   **OS**: Ubuntu 22.04.1 LTS (Kernel: 6.8.0-90-generic)
*   **Python**: 3.13.9
*   **Mitmproxy**: 12.2.2
*   **Frida (Host)**: 17.9.1
*   **ADB/Fastboot**: 최신 버전 유지 권장

---

## 2. 자동화 스크립트 실행 (`device_init.sh`)

`/home/tech/nmap_mini/device_init.sh` 스크립트는 기기 초기 세팅과 최적화를 일괄 자동화합니다. 기기를 USB 디버깅 상태로 연결하고 실행합니다.

**스크립트가 수행하는 작업:**
1. **Root 권한 사전 검증**: 모든 기기의 Root(su) 획득 여부를 미리 검사하여 팝업 승인 단계를 일괄 확인합니다.
2. **앱 자동 설치 (`device_init/modules/app_installation.sh`)**: `com.nhn.android.nmap` (네이버 지도splits) 및 GPS Emulator, ADBKeyboard가 미설치된 상태라면 자동으로 APK를 설치합니다.
3. **시스템 환경 최적화**: 
   - 안드로이드 WebView 비활성화 및 Google Play Store 자동 업데이트 비활성화.
   - USB 안정성을 위해 persistent USB를 ADB 전용으로 고정 (MTP 완전 차단).
   - 화면 자동 회전 차단(세로 고정) 및 OTA 자동 업데이트 비활성화.
4. **Magisk & Zygisk 모듈 자동 설치 (`device_init/modules/magisk_setup.sh`)**: Zygisk 활성화 상태를 확인/수정하고, `/sdcard/Download/` 경로에 배치된 필수 모듈(`MagiskFrida`, `AlwaysTrustUserCerts`, `LSPosed`)을 수동 조작 없이 자동 설치합니다.
5. **MITM 인증서 복구 및 재부팅 바이패스 (`mitm_recovery.sh`)**: 신뢰할 수 있는 사용자 인증서 모듈의 MD5 해시를 대조해 스크립트 교정 후 자동 재부팅을 유도하여 설치된 모듈을 완전히 적용시킵니다 (기기에 변경사항이 없는 경우 재부팅 단계를 건너뛰어 속도를 최적화합니다).

---


## 4. 3단계: USB 안정성 및 MTP 차단 설정 (매우 중요 ⭐️)

여러 대의 기기를 연결할 때 발생하는 **USB 미세 끊김(Bus Reset)**을 방지하기 위해 다음 설정을 반드시 확인합니다.

1.  **MTP 완전 차단**: `device_init.sh` 실행 시 자동으로 처리되지만, 수동 확인이 필요할 경우 기기 상단 바를 내려 USB 모드를 **'휴대전화 충전만(Charging Only)'**으로 변경합니다.
2.  **워치독 작동 확인**: V2 엔진(`main.sh`)에는 터널 단절 시 **1초 내로 복구**하는 워치독이 포함되어 있습니다. 실행 로그(`execution.log`)에 `[⚠️] Tunnel lost! Restoring...` 메시지가 뜨더라도 주행이 멈추지 않는다면 정상입니다.

## 5. 4단계: NLOG 패킷 수집 및 HostnameVerifier 우회

네이버 지도의 분석 로그(NLOG) 수집을 위해 `network_hook.js`에 **HostnameVerifier 우회 로직**이 포함되어 있습니다.

*   **기능**: 인증서의 호스트 이름 불일치를 무시하여 `nlogapp` 패킷을 강제로 Mitmproxy로 끌어옵니다.
*   **확인**: `logs/.../mitm.log` 또는 `.json` 파일 목록에 `019_POST_nlogapp.json` 등이 생성되는지 확인하세요.

---

## 💡 요약: 트러블슈팅 체크리스트

신규 기기에서 네트워크가 차단되거나 패킷이 안 쌓일 때 확인해야 할 4가지:

1.  **Magisk 모듈이 활성화되어 있는가?**
    *   `magisk --install-module` 명령으로 자동 설치되지만, 기기 재부팅 후 Magisk 앱에서 '활성화' 상태인지 꼭 확인하세요.
2.  **USB 모드가 '충전 전용'인가?**
    *   MTP가 켜져 있으면 데이터 전송 대역폭 문제로 터널이 자주 끊길 수 있습니다.
3.  **인증서가 시스템 단에 주입되었는가?**
    *   `mitmproxy` 인증서가 시스템 자격증명 목록에 있어야 NLOG 네이티브 통신이 뚫립니다.
4.  **최신 Frida 후킹 스크립트인가?**
    *   `HostnameVerifier.verify.implementation = function(...) { return true; }` 코드가 `network_hook.js`에 있는지 확인하세요.
