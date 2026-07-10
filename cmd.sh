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
        bash "$CMD_DIR/check_nmap_version.sh"
        ;;
    --imei)
        bash "$CMD_DIR/extract_device_info.sh"
        ;;
    *)
        # 인자 없이 실행 시: 연결된 모든 기기의 화면을 그리드로 정렬하여 띄움
        python3 "$CMD_DIR/open_missing.py" --keep "$@"
        ;;
esac
