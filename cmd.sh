#!/usr/bin/env bash
# cmd.sh: 핵심 기능(Home, Dark, Portrait, Reboot, IP) 중심 최적화 버전

CMD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/cmd" &> /dev/null && pwd)"

case "$1" in
    --home)
        bash "$CMD_DIR/home.sh"
        ;;
    --dark)
        bash "$CMD_DIR/dark.sh"
        ;;
    --light)
        bash "$CMD_DIR/light.sh"
        ;;
    --portrait|--portait)
        bash "$CMD_DIR/portrait.sh"
        ;;
    --reboot)
        bash "$CMD_DIR/reboot.sh"
        ;;
    --ip)
        bash "$CMD_DIR/ip.sh"
        ;;
    --wifi)
        shift
        bash "$CMD_DIR/wifi.sh" "$@"
        ;;
    --nmap)
        shift
        bash "$CMD_DIR/check_nmap_version.sh" "$@"
        ;;
    --imei)
        bash "$CMD_DIR/extract_device_info.sh"
        ;;
    --adid)
        bash "$CMD_DIR/extract_adid.sh"
        ;;
    --idfv)
        shift
        bash "$CMD_DIR/extract_real_idfv.sh" "$@"
        ;;
    --reset)
        shift
        bash "$CMD_DIR/reset_penalty.sh" "$@"
        ;;
    --lte|--lte-check)
        shift
        bash "$CMD_DIR/check_lte.sh" "$@"
        ;;
    --help|-h)
        echo -e "\n============================================================"
        echo -e " 📱 Nmap Multi Control CLI (cmd.sh)"
        echo -e "============================================================"
        echo -e "  --lte [<인터페이스>]   : LTE 모뎀 종합 진단 및 자동 최적화/치료"
        echo -e "                            - SIP ALG 자동 비활성화 (모뎀 멈춤/ACK 누락 방지)"
        echo -e "                            - LTE 인터페이스 MTU 1420 최적화 (패킷 손실 방지)"
        echo -e "                            - 커널 TCP 소켓 회수 튜닝 (FIN-WAIT-1/TIME-WAIT 정리)"
        echo -e "                            - 라우팅 테이블/규칙 점검 및 복구"
        echo -e "                            (옵션: ./cmd.sh --lte [lte11|11], --reboot [lte11], --check-only)"
        echo -e "  --reset [<기기ID>]     : 벌점(Penalty) 리셋 및 작업 재개"
        echo -e "                            - 전체 리셋: ./cmd.sh --reset"
        echo -e "                            - 단일 리셋: ./cmd.sh --reset <기기ID>"
        echo -e "  --nmap [<기기ID>] [-u]  : 네이버 지도 버전 검수 및 패치"
        echo -e "                            - 전체 검수: ./cmd.sh --nmap"
        echo -e "                            - 전체 패치: ./cmd.sh --nmap -u"
        echo -e "                            - 단일 검수: ./cmd.sh --nmap <기기ID>"
        echo -e "                            - 단일 패치: ./cmd.sh --nmap -u <기기ID>"
        echo -e "                            (예: ./cmd.sh --nmap -u R3CR70JFFWD)"
        echo -e "  --home                 : 전체 기기 홈 화면 복귀"
        echo -e "  --dark                 : 전체 기기 다크모드 적용"
        echo -e "  --light                : 전체 기기 라이트모드 적용"
        echo -e "  --portrait             : 전체 기기 세로모드 고정"
        echo -e "  --reboot               : 전체 기기 재부팅"
        echo -e "  --ip                   : 전체 기기 Wi-Fi IP 확인"
        echo -e "  --wifi                 : Wi-Fi 재연결 및 상태 설정"
        echo -e "  --imei                 : 기기 IMEI 추출"
        echo -e "  --adid                 : 기기 ADID 추출"
        echo -e "  --idfv                 : 기기 IDFV 추출"
        echo -e "  인자 없음              : 전체 기기 화면 그리드 실행"
        echo -e "============================================================\n"
        ;;
    *)
        # 인자 없이 실행 시: 연결된 모든 기기의 화면을 그리드로 정렬하여 띄움
        python3 "$CMD_DIR/open_missing.py" --keep "$@"
        ;;
esac
