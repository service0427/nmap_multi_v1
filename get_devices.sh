#!/bin/bash
# /home/tech/nmap_multi_v1/wifi_multi/get_devices.sh
# 현재 adb devices 순서를 긁어서 JSON 정렬 설정 파일로 고정 저장합니다.

CONF_DIR="/home/tech/nmap_multi_v1/wifi_multi/config"
CONF_FILE="$CONF_DIR/device_order.json"

mkdir -p "$CONF_DIR"

# adb devices 결과에서 시리얼만 정렬하여 추출
devices=$(adb devices | awk 'NR>1 {print $1}' | grep -v '^$' | sort)

if [ -z "$devices" ]; then
    echo "[!] 에러: 연결된 adb 기기가 없습니다. JSON을 생성하지 않습니다."
    exit 1
fi

# JSON array 형식으로 변환
json_array="["
first=true
for dev in $devices; do
    if [ "$first" = true ]; then
        json_array="$json_array\"$dev\""
        first=false
    else
        json_array="$json_array, \"$dev\""
    fi
done
json_array="$json_array]"

echo "$json_array" > "$CONF_FILE"
echo "[✓] 현재 adb 순서가 $CONF_FILE 에 성공적으로 고정되었습니다!"
echo "    - 저장된 기기 수: $(echo "$devices" | wc -l)대"
