#!/bin/bash
# screen.sh: Capture screenshot and UI XML for a specific device index

INDEX=${1:-0}
# 1. Get device ID from adb devices list (skipping header)
DEV_ID=$(adb devices | grep -v "List" | grep "device$" | sed -n "$((INDEX + 1))p" | awk '{print $1}')

if [ -z "$DEV_ID" ]; then
    echo "[-] Error: Device at index $INDEX not found."
    adb devices
    exit 1
fi

# 2. Setup path (MMDD/HHMMSS_DEVICEID)
DATE_DIR=$(date +%m%d)
TIME_STR=$(date +%H%M%S)
BASE_PATH="$(dirname "$0")/screenshot/${DATE_DIR}/${TIME_STR}_${DEV_ID}"

mkdir -p "$BASE_PATH"

echo "[*] Target Device: $DEV_ID"
echo "[*] Saving to: $BASE_PATH"

# 3. Capture Screen and XML
echo "[*] Capturing Screenshot..."
adb -s "$DEV_ID" shell screencap -p /sdcard/screen.png
adb -s "$DEV_ID" pull /sdcard/screen.png "${BASE_PATH}/screen.png" >/dev/null 2>&1

echo "[*] Dumping UI XML..."
adb -s "$DEV_ID" shell uiautomator dump /sdcard/view.xml >/dev/null 2>&1
adb -s "$DEV_ID" pull /sdcard/view.xml "${BASE_PATH}/view.xml" >/dev/null 2>&1

# 4. Pretty-print XML for readability
if command -v python3 >/dev/null 2>&1; then
    python3 -c "import xml.dom.minidom; dom = xml.dom.minidom.parse('${BASE_PATH}/view.xml'); open('${BASE_PATH}/view.xml', 'w').write(dom.toprettyxml(indent='  '))" >/dev/null 2>&1
fi

# 5. Cleanup on device
adb -s "$DEV_ID" shell rm /sdcard/screen.png /sdcard/view.xml

echo "[✓] Capture Complete"
