#!/usr/bin/env bash

# USIM 번호등록 등 시스템 화면에 갇혔을 때 홈 화면으로 강제 전환하는 스크립트

SERIAL="$1"

if [ -z "$SERIAL" ]; then
    echo "Usage: ./cmd/exit_usim.sh [DEVICE_SERIAL]"
    exit 1
fi

echo "[$SERIAL] 홈 화면 전환 시도 중..."

# 1. 홈 화면 인텐트 강제 호출 (바탕화면으로 이동 시도)
adb -s "$SERIAL" shell am start -a android.intent.action.MAIN -c android.intent.category.HOME > /dev/null 2>&1

# 2. 뒤로가기 버튼 2회 실행 (번호등록 팝업 및 시스템 오버레이 해제)
adb -s "$SERIAL" shell input keyevent 4
sleep 0.5
adb -s "$SERIAL" shell input keyevent 4

# 3. 홈 버튼 최종 실행
adb -s "$SERIAL" shell input keyevent 3

# 상태 확인
CURRENT_FOCUS=$(adb -s "$SERIAL" shell dumpsys window | grep mCurrentFocus)
echo "[$SERIAL] 현재 포커스: $CURRENT_FOCUS"
