#!/bin/bash
# wifi_multi/macro/monitor.sh: V18.4 Packet-File Based Silence Kill

# --- [ADB TIMEOUT WRAPPER] ---
adb() {
    timeout 10 /usr/bin/adb "$@"
}

DEV_ID=$1; LOG_DIR=$2; DEST_ID=$3
[ -z "$DEV_ID" ] || [ -z "$LOG_DIR" ] && exit 1

PKG_NAME="com.nhn.android.nmap"
ADB_KB_IME="com.android.adbkeyboard/.AdbIME"
GPS_PKG="com.rosteam.gpsemulator"
cd "$WIFI_MULTI_ROOT" || exit 1

# --- [전역 설정 로드] ---
if [ -f "config.conf" ]; then
    source "config.conf"
fi

export ABS_LOG_DIR=$(realpath "$LOG_DIR")
export CAPTURE_LOG_DIR="$ABS_LOG_DIR"
EXEC_LOG="$ABS_LOG_DIR/execution.log"
exec >> "$EXEC_LOG" 2>&1

MACRO_EXEC="python3 macro/macro_executor.py"
SCHEDULE_JSON="macro/action_schedule.json"

CURRENT_TASK_JSON="${WIFI_MULTI_LOGS}/${DEV_ID}/current_task.json"

# --- [SUBNET LOCK SETUP] ---
SUBNET_IDX=""
HAS_SUBNET_LOCK="false"
if [ -n "$NMAP_BIND_IP" ] && [[ "$NMAP_BIND_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SUBNET_IDX=$(echo "$NMAP_BIND_IP" | cut -d. -f3)
fi

# [🔒 Robust Lock Janitor] Force release subnet lock when monitor.sh exits under any conditions
release_lock_on_exit() {
    if [ "$HAS_SUBNET_LOCK" == "true" ]; then
        echo "[$(date +'%H:%M:%S.%3N')] [🔓] Clean Up: Force releasing Subnet Lock on subnet_${SUBNET_IDX} due to exit."
        exec 9>&-
        HAS_SUBNET_LOCK="false"
    fi
}
trap release_lock_on_exit EXIT INT TERM

# --- [CORE] Functions ---
NOW() { date +"%H:%M:%S.%3N"; }

log_api_backup() {
    local endpoint=$1
    local payload=$2
    local response=$3
    local today=$(date +%Y%m%d)
    local backup_dir="/home/tech/nmap_multi_v1/api_backup/${today}/${DEV_ID}"
    mkdir -p "$backup_dir"
    local backup_file="${backup_dir}/api.log"
    echo "[$(date +'%Y-%m-%d %H:%M:%S.%3N')] [Task: ${NMAP_LOG_ID:-N/A}]" >> "$backup_file"
    echo "  - REQ: ${endpoint} -> ${payload}" >> "$backup_file"
    echo "  - RES: ${response}" >> "$backup_file"
    echo "------------------------------------------------------------" >> "$backup_file"
}

send_api_request() {
    local endpoint=$1
    local payload=$2
    echo "[$(NOW)] [API_REQ] $endpoint -> $payload"
    local response=$(curl --connect-timeout 10 --max-time 15 -s -w "\nHTTP_CODE:%{http_code}" -X POST "http://${API_SERVER:-localhost:8000}${endpoint}" \
         -H "Content-Type: application/json" -d "$payload")
    echo "[$(NOW)] [API_RES] $response"
    
    # Save a persistent local backup of the API transmission
    log_api_backup "$endpoint" "$payload" "$response"
}

send_report_result() {
    local status=$1
    local message=$2
    local extra_fields=$3
    local payload
    if [ -n "$extra_fields" ]; then
        payload=$(jq -n \
            --argjson task_id "$NMAP_LOG_ID" \
            --arg status "$status" \
            --arg device_id "$DEV_ID" \
            --arg message "$message" \
            --argjson extra "{$extra_fields}" \
            '{task_id: $task_id, status: $status, device_id: $device_id, message: $message} + $extra')
    else
        payload=$(jq -n \
            --argjson task_id "$NMAP_LOG_ID" \
            --arg status "$status" \
            --arg device_id "$DEV_ID" \
            --arg message "$message" \
            '{task_id: $task_id, status: $status, device_id: $device_id, message: $message}')
    fi

    # [💡 NEW] Record result to persistent CSV file (Isolated from log cleaner)
    local history_file="logs/rotator_history/session_history.csv"
    if [ ! -f "$history_file" ]; then
        mkdir -p "$(dirname "$history_file")"
        echo "Timestamp,DeviceID,Subnet,TaskID,Status,Message" > "$history_file"
    fi
    local clean_message=$(echo "$message" | tr -d '"\r\n' | tr ',' ';')
    echo "$(date +'%Y-%m-%d %H:%M:%S'),$DEV_ID,$SUBNET_IDX,$NMAP_LOG_ID,$status,$clean_message" >> "$history_file"

    send_api_request "/api/v1/report_result" "$payload"
}

update_live_status() {
    local msg=$1
    if [ -f "$CURRENT_TASK_JSON" ]; then
        # Use jq to update only the status field
        tmp_file=$(mktemp)
        if jq --arg status "$msg" '.status = $status' "$CURRENT_TASK_JSON" > "$tmp_file" 2>/dev/null; then
            mv "$tmp_file" "$CURRENT_TASK_JSON"
        else
            echo "{\"status\": \"$msg\"}" > "$CURRENT_TASK_JSON"
        fi
    else
        echo "{\"status\": \"$msg\"}" > "$CURRENT_TASK_JSON"
    fi
    # Send live status to API server
    send_api_request "/api/v1/update_status" "{\"task_id\": $NMAP_LOG_ID, \"status\": \"$msg\", \"device_id\": \"$DEV_ID\"}"
}
START_TS=$(date +%s)
GLOBAL_TIMEOUT=$(jq -r '.config.global_timeout // 1200' "$SCHEDULE_JSON")

# [V18.4] Silence Kill Variables (JSON File Count Based)
LAST_JSON_COUNT=0
STUCK_COUNT=0
IS_DRIVING=false
POPUP_CHECKED=false
LAST_UI_CHECK_TS=0
LAST_HOME_CHECK_TS=0
LAST_SURVIVAL_CHECK_TS=0

# [NEW] Transition Timeout Variables
NAVI_START_TS=0
LOCK_ACQUIRED_TS=0

declare -A STATE_FLAGS

stop_gps() {
    echo "[$(NOW)] [🛑] Stopping GPS Movement (Speed: 0.0m/s)"
    local su_path=$(adb -s "$DEV_ID" shell "which su" 2>/dev/null | tr -d '\r')
    if [ -z "$su_path" ]; then
        su_path=$(adb -s "$DEV_ID" shell "ls /system/bin/su /system/xbin/su /sbin/su 2>/dev/null" | head -1 | tr -d '\r')
    fi
    [ -z "$su_path" ] && su_path="su"
    adb -s "$DEV_ID" shell "$su_path -c 'am start-foreground-service -n $GPS_PKG/.servicex2484 -a ACTION_START_CONTINUOUS --ef velocidad 0.0'" > /dev/null 2>&1
}

check_app_survival() {
    local ELAPSED=$(( $(date +%s) - START_TS ))
    
    # 1. Global Timeout
    if [ $ELAPSED -gt "$GLOBAL_TIMEOUT" ]; then
        echo "[$(NOW)] [🚨] GLOBAL TIMEOUT EXCEEDED (${ELAPSED}s / ${GLOBAL_TIMEOUT}s). Force killing..."
        send_report_result "FAIL" "GLOBAL_TIMEOUT"
        adb -s "$DEV_ID" shell am force-stop "$PKG_NAME"; exit 1
    fi

    # 2. Process Survival Check (Robust check against transient ADB/USB drops)
    if [ $ELAPSED -gt 30 ]; then
        local NOW_SEC=$(date +%s)
        local SEC_SINCE_SURVIVAL_CHECK=$(( NOW_SEC - LAST_SURVIVAL_CHECK_TS ))
        if [ $SEC_SINCE_SURVIVAL_CHECK -ge 15 ]; then
            LAST_SURVIVAL_CHECK_TS=$NOW_SEC
            
            local APP_RUNNING=false
            if ! adb devices | grep -q -w "$DEV_ID"; then
                # Device is temporarily disconnected/offline. Assume the app is still running to prevent false exit.
                APP_RUNNING=true
            else
                for r in {1..3}; do
                    if adb -s "$DEV_ID" shell pidof "$PKG_NAME" >/dev/null 2>&1; then
                        APP_RUNNING=true
                        break
                    fi
                    sleep 1
                done
            fi
            
            if [ "$APP_RUNNING" = false ]; then
                echo "[$(NOW)] [!] App process dead. Stopping scheduler."; exit 1
            fi

            # [NEW] Galaxy Finder (삼성 파인더) overlay detection & recovery
            local CURRENT_FOCUS
            CURRENT_FOCUS=$(adb -s "$DEV_ID" shell "dumpsys window | grep -E 'mCurrentFocus'" 2>/dev/null)
            if echo "$CURRENT_FOCUS" | grep -q "com.samsung.android.app.galaxyfinder"; then
                echo "[$(NOW)] [⚠️] Galaxy Finder detected on screen! Force closing it to return to Naver Map..."
                adb -s "$DEV_ID" shell "am force-stop com.samsung.android.app.galaxyfinder" >/dev/null 2>&1
                adb -s "$DEV_ID" shell "input keyevent 4" >/dev/null 2>&1
                adb -s "$DEV_ID" shell "monkey -p com.nhn.android.nmap -c android.intent.category.LAUNCHER 1" >/dev/null 2>&1
            fi
        fi
    fi

    # [NEW] Fast Fatal UI Error Detection (No Route Found, Network Error, etc.)
    if [ "$IS_DRIVING" = false ]; then
        local CUR_TS
        CUR_TS=$(date +%s)
        local SEC_SINCE_CHECK=$(( CUR_TS - LAST_UI_CHECK_TS ))
        
        # Trigger check if 30s elapsed (after 30s elapsed from start) OR if we detect packet silence of 15s, 30s, or 45s (stuck count 3, 6, 9)
        local TRIGGER_CHECK=false
        if [ $SEC_SINCE_CHECK -ge 30 ] && [ $ELAPSED -gt 30 ]; then
            TRIGGER_CHECK=true
        elif [ $STUCK_COUNT -eq 3 ] || [ $STUCK_COUNT -eq 6 ] || [ $STUCK_COUNT -eq 9 ]; then
            TRIGGER_CHECK=true
        fi

        if [ "$TRIGGER_CHECK" = true ]; then
            LAST_UI_CHECK_TS=$CUR_TS
            # Dump UI XML (with safety timeout)
            timeout 15 adb -s "$DEV_ID" shell "uiautomator dump /sdcard/ui.xml" >/dev/null 2>&1
            local XML_CONTENT
            XML_CONTENT=$(timeout 10 adb -s "$DEV_ID" shell "cat /sdcard/ui.xml" 2>/dev/null)
            if [ -n "$XML_CONTENT" ]; then
                local FATAL_PATTERN="길찾기 결과가 없습니다|결과를 제공할 수 없습니다|검색 결과가 없습니다|장소를 찾을 수 없습니다|길찾기 결과를 제공할 수 없습니다|검색 결과가 없어요|출발지와 도착지가 같습니다|출발지와 목적지가 같습니다|주변에 도로가 없습니다|안내할 수 없는 경로입니다|네트워크 연결이 원활하지 않습니다|네트워크 연결 상태를 확인|네트워크가 연결되어 있지 않습니다|네트워크 연결 상태가 불안정|네트워크 오류|연결 상태가 좋지 않습니다|연결 상태를 확인|인터넷 연결|인터넷에 연결|알 수 없는 에러가 발생했습니다"
                if echo "$XML_CONTENT" | grep -q -E "$FATAL_PATTERN"; then
                    local MATCHED_MSG
                    MATCHED_MSG=$(echo "$XML_CONTENT" | grep -o -E "$FATAL_PATTERN" | head -n 1)
                    echo "[$(NOW)] [🚨] Fatal UI State Detected ('$MATCHED_MSG'). Fail-fast."
                    send_report_result "FAIL" "NO_ROUTE_FOUND: $MATCHED_MSG"
                    echo "[$(NOW)] [*] Immediate Exit for FAIL due to Fatal UI. Letting main.sh handle cleanup."
                    exit 0
                fi
            fi
        fi
    fi

    # [NEW] Links-to-Driving Watchdog (Check if driving route response is missing after links response)
    if [ "$IS_DRIVING" = false ]; then
        local LINKS_FILE
        LINKS_FILE=$(ls -1 "$ABS_LOG_DIR"/*_global_links.json 2>/dev/null | head -n 1)
        if [ -n "$LINKS_FILE" ]; then
            local LINKS_TIME
            LINKS_TIME=$(stat -c %Y "$LINKS_FILE" 2>/dev/null)
            if [ -n "$LINKS_TIME" ]; then
                local NOW_SEC
                NOW_SEC=$(date +%s)
                local AGE=$(( NOW_SEC - LINKS_TIME ))
                if [ $AGE -gt 30 ]; then
                    local DRIVING_FILE
                    DRIVING_FILE=$(ls -1 "$ABS_LOG_DIR"/*_global_driving.json 2>/dev/null | head -n 1)
                    local DRIVING_SIZE=0
                    if [ -n "$DRIVING_FILE" ]; then
                        DRIVING_SIZE=$(stat -c %s "$DRIVING_FILE" 2>/dev/null || echo 0)
                    fi
                    if [ $DRIVING_SIZE -lt 5000 ]; then
                        echo "[$(NOW)] [🚨] Route calculation failed/hung! links.json exists for ${AGE}s but driving.json is missing or invalid (Size: ${DRIVING_SIZE}B). Fail-fast."
                        send_report_result "FAIL" "ROUTE_CALCULATION_FAILED_OR_HUNG"
                        echo "[$(NOW)] [*] Immediate Exit for FAIL due to Route Calculation Fail/Hang. Letting main.sh handle cleanup."
                        exit 0
                    fi
                fi
            fi
        fi
    fi

    # [NEW] Proactive Popup Killer & UI Home screen detector if Home Screen is delayed
    if [[ "${STATE_FLAGS[STEP_02_HOME]}" != "1" ]]; then
        local NOW_SEC=$(date +%s)
        local SEC_SINCE_HOME_CHECK=$(( NOW_SEC - LAST_HOME_CHECK_TS ))
        if [ $SEC_SINCE_HOME_CHECK -ge 20 ]; then
            LAST_HOME_CHECK_TS=$NOW_SEC
            # Check UI to see if Home screen is already visible (with safety timeout)
            timeout 15 adb -s "$DEV_ID" shell "uiautomator dump /sdcard/ui_home_check.xml" >/dev/null 2>&1
            local CHECK_XML
            CHECK_XML=$(timeout 10 adb -s "$DEV_ID" shell "cat /sdcard/ui_home_check.xml" 2>/dev/null)
            if echo "$CHECK_XML" | grep -q -E "집으로|회사로|v_home_container|entry_search_field"; then
                echo "[$(NOW)] [✓] Home screen UI elements detected. Appending virtual home screenview."
                if ! grep -q "home" "$ABS_LOG_DIR/events.log" 2>/dev/null; then
                    echo "[screenview] home" >> "$ABS_LOG_DIR/events.log"
                fi
            elif [ $ELAPSED -gt 15 ] && [ "$POPUP_CHECKED" = false ]; then
                echo "[$(NOW)] [?] Home screen delayed. Proactively checking for blocking popups..."
                # Call ui_clicker with a dummy query just to trigger check_and_dismiss_popups()
                python3 macro/ui_clicker.py "$DEV_ID" "exact:DUMMY_POPUP_CHECK" "PopupCheck" >/dev/null 2>&1
                POPUP_CHECKED=true
            fi
        fi
    fi
    
    # [NEW] Fail-Fast: Guidance Transition Timeout (e.g. Toast message blocked routing)
    # Transition timeout removed to emulate stable main branch behavior

    # 3. Packet-File Silence Kill (Global Check for Frida/App Health)
    # 개별 요청 JSON 파일들이 새로 생성되고 있는지 숫자로 체크
    if [ "$IS_DRIVING" = true ]; then
        # 주행 중에는 전체 통신망 감시를 위해 heartbeat, location 패킷도 집계에 포함
        CUR_JSON_COUNT=$(ls -1 "$ABS_LOG_DIR"/*.json 2>/dev/null | grep -v -E "sdk_log|geojson|metadata|my_notices|weather" | wc -l)
    else
        # 진입 단계에서는 웹뷰 UI 전송 진척률만 체크하기 위해 heartbeat, location 등은 제외
        CUR_JSON_COUNT=$(ls -1 "$ABS_LOG_DIR"/*.json 2>/dev/null | grep -v -E "heartbeat|location|sdk_log|log_batch|geojson|metadata|my_notices|weather" | wc -l)
    fi

    if [ $CUR_JSON_COUNT -gt $LAST_JSON_COUNT ]; then
        STUCK_COUNT=0; LAST_JSON_COUNT=$CUR_JSON_COUNT
    else
        ((STUCK_COUNT++))
        
        # 패킷 전송 침묵 최종 마한선 설정 (전역 설정 SILENCE_TIMEOUT_SECONDS 연동)
        local TIMEOUT_SEC=${SILENCE_TIMEOUT_SECONDS:-70}
        local MAX_STUCK=$((TIMEOUT_SEC / 5)) 
        
        if [ $STUCK_COUNT -ge $MAX_STUCK ]; then
            echo "[$(NOW)] [🚨] SILENCE DETECTED ($((MAX_STUCK * 5))s). No new packet JSONs. Killing session."
            send_report_result "FAIL" "PACKET_STUCK"
            stop_gps; adb -s "$DEV_ID" shell am force-stop "$PKG_NAME"; exit 1
        fi
    fi

    # [🛡️ Strict Fail-Fast on any client-logger POST errorLog with message]
     if [ "${ERRORLOG_FAIL_FAST:-true}" = "true" ] && [ "$IS_DRIVING" = false ]; then
         local ERROR_POST_FILE=$(ls -1 "$ABS_LOG_DIR"/*_POST_client-logger_errorLog.json 2>/dev/null | head -n 1)
         if [ -n "$ERROR_POST_FILE" ]; then
             local ERR_MSG=$(jq -r '.request.body.message // empty' "$ERROR_POST_FILE" 2>/dev/null)
             # Exclude harmless browser lifecycle events (PAGE_HIDE, INCOMPLETE_REQUEST) from fail-fast abort
             if [ -n "$ERR_MSG" ] && [[ "$ERR_MSG" != *"INCOMPLETE_REQUEST"* ]] && [[ "$ERR_MSG" != *"PAGE_HIDE"* ]]; then
                 echo "[$(NOW)] [🚨] Strict Fail-Fast: Real errorLog payload detected in $(basename "$ERROR_POST_FILE"): $ERR_MSG"
                 send_report_result "FAIL" "ERROR_LOG_DETECTED: $ERR_MSG"
                 stop_gps; adb -s "$DEV_ID" shell am force-stop "$PKG_NAME"; exit 1
             fi
         fi
     fi
}

human_random_sleep() {
    local sleep_sec=$(awk "BEGIN {srand(); print 1.0 + rand() * 2.0}")
    echo "[$(NOW)] [Delay] Humanizing for ${sleep_sec}s..."
    sleep "$sleep_sec"
}

type_destination_only() {
    if [ -z "$NMAP_DEST_NAME" ]; then
        echo "[$(NOW)] [!] ERROR: NMAP_DEST_NAME is empty. Skipping typing."
        return 1
    fi
    echo "[$(NOW)] [Action] Typing: $NMAP_DEST_NAME (via Python Helper)"
    python3 macro/type_helper.py "$DEV_ID" "$NMAP_DEST_NAME"
    echo "    > Waiting 8s for recommendation list..."; sleep 8
}

echo "[$(NOW)] [Scheduler:$DEV_ID] V18.4 Strict Mode Started."

# === Main Loop ===
while true; do
    check_app_survival
    
    # [NEW] Dynamic Subnet Lock Release Checker
    if [ "$HAS_SUBNET_LOCK" == "true" ]; then
        ELAPSED_FROM_LOCK=$(( $(date +%s) - LOCK_ACQUIRED_TS ))
        
        # 1. Release if OPTIONS_graphql is detected after guidance start (with 5s buffer)
        if [ "$NAVI_START_TS" -gt 0 ]; then
            NEWEST_OPT_GRAPHQL=$(ls -1t "$ABS_LOG_DIR"/*_OPTIONS_graphql.json 2>/dev/null | head -n 1)
            if [ -n "$NEWEST_OPT_GRAPHQL" ]; then
                GRAPHQL_TS=$(date -r "$NEWEST_OPT_GRAPHQL" +%s)
                if [ $GRAPHQL_TS -ge $NAVI_START_TS ]; then
                    sleep 5
                    exec 9>&-
                    echo "[$(NOW)] [🔓] Dynamic Lock released (OPTIONS_graphql detected, waited 5s. Hold time: ${ELAPSED_FROM_LOCK}s)."
                    HAS_SUBNET_LOCK="false"
                fi
            fi
        fi
        
        # 2. Fallback safety cap (80s)
        if [ "$HAS_SUBNET_LOCK" == "true" ] && [ $ELAPSED_FROM_LOCK -ge 80 ]; then
            exec 9>&-
            echo "[$(NOW)] [🔓] Dynamic Lock released by timeout cap (80s)."
            HAS_SUBNET_LOCK="false"
        fi
    fi
    
    # [NEW] Universal Home Entry Recovery for Startup Popups/Keyboards/Hangs
    if [[ "${STATE_FLAGS[STEP_02_HOME]}" != "1" ]]; then
        HOME_WAIT_TIME=$(( $(date +%s) - START_TS ))
        if [ $HOME_WAIT_TIME -gt 25 ]; then
            NOW_SEC=$(date +%s)
            SEC_SINCE_HOME_RECOVERY=$(( NOW_SEC - LAST_HOME_CHECK_TS ))
            if [ $SEC_SINCE_HOME_RECOVERY -ge 15 ]; then
                LAST_HOME_CHECK_TS=$NOW_SEC
                echo "[$(NOW)] [⚠️] Failed to reach Home screen within ${HOME_WAIT_TIME}s. Dismissing popups/keyboards..."
                adb -s "$DEV_ID" shell input keyevent 4
                sleep 2
                python3 macro/ui_clicker.py "$DEV_ID" "exact:닫기" "DismissPopup" >/dev/null 2>&1
                python3 macro/ui_clicker.py "$DEV_ID" "exact:확인" "DismissPopup" >/dev/null 2>&1
                python3 macro/ui_clicker.py "$DEV_ID" "exact:나중에 하기" "DismissPopup" >/dev/null 2>&1
                adb -s "$DEV_ID" shell monkey -p com.nhn.android.nmap -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
            fi
        fi
    fi

    # [NEW] Auto-Recovery for Stuck Navigation / Resume Guidance State
    if [[ "${STATE_FLAGS[STEP_02_HOME]}" != "1" ]]; then
        if grep -q -E "v3/global/driving|trafficjam/location" "$ABS_LOG_DIR/events.log" 2>/dev/null; then
            # Verify if we are actually in navigation vs on Home screen (with safety timeout)
            timeout 15 adb -s "$DEV_ID" shell "uiautomator dump /sdcard/ui_recovery.xml" >/dev/null 2>&1
            RECOVERY_XML=$(timeout 10 adb -s "$DEV_ID" shell "cat /sdcard/ui_recovery.xml" 2>/dev/null)
            
            # If Home screen indicators are visible, we are NOT in navigation! Just write virtual home screenview.
            if echo "$RECOVERY_XML" | grep -q -E "집으로|회사로|v_home_container|entry_search_field"; then
                echo "[$(NOW)] [✓] Home screen UI elements detected during recovery check. Appending virtual home screenview."
                if ! grep -q "home" "$ABS_LOG_DIR/events.log" 2>/dev/null; then
                    echo "[screenview] home" >> "$ABS_LOG_DIR/events.log"
                fi
            else
                echo "[$(NOW)] [⚠️] Active driving/trafficjam packets detected while waiting for Home screen!"
                if [ -z "$RECOVERY_TRY" ]; then RECOVERY_TRY=0; fi
                if [ "$RECOVERY_TRY" -lt 2 ]; then
                    ((RECOVERY_TRY++))
                    echo "      > [Attempt $RECOVERY_TRY/2] Sending Back key and attempting to exit navigation..."
                    adb -s "$DEV_ID" shell input keyevent 4
                    sleep 2
                    # Attempt to click standard exit/confirm dialog buttons
                    python3 macro/ui_clicker.py "$DEV_ID" "exact:종료" "ExitNavi" >/dev/null 2>&1
                    python3 macro/ui_clicker.py "$DEV_ID" "exact:확인" "ExitNavi" >/dev/null 2>&1
                    python3 macro/ui_clicker.py "$DEV_ID" "exact:안내종료" "ExitNavi" >/dev/null 2>&1
                    sleep 3
                else
                    # Fallback: Bypass to driving state to prevent infinite hangs
                    echo "      > Fallback: Bypassing initial setup steps and transitioning directly to driving state."
                    STATE_FLAGS[STEP_02_HOME]=1
                    STATE_FLAGS[STEP_03_TYPING]=1
                    STATE_FLAGS[STEP_04_SELECT_ADDR]=1
                    STATE_FLAGS[STEP_05_POI_ARRIVAL]=1
                    STATE_FLAGS[STEP_07_NAVI_START]=1
                    STATE_FLAGS[STEP_07_1_BUSINESS_MODAL]=1
                    STATE_FLAGS[STEP_07_2_DRIVING_STARTED]=1
                    IS_DRIVING=true
                    update_live_status "DRIVING"
                    touch "logs/${DEV_ID}/tmp/guidance_started" 2>/dev/null
                fi
            fi
        fi
    fi

    # routeend 감지
    if [[ "${STATE_FLAGS[STEP_08_DRIVING_GOAL]}" != "1" ]]; then
        if grep -q "routeend" "$ABS_LOG_DIR/events.log" 2>/dev/null; then
            echo "[$(NOW)] [🌟] CASE: routeend detected! Finalizing session."
            stop_gps 
            STATE_FLAGS[STEP_07_2_DRIVING_STARTED]=1
            STATE_FLAGS[STEP_08_DRIVING_GOAL]=1
            MATCHED_IDX="BYPASS"; ID="STEP_09_FINISH"
        fi
    fi

    PREV_STEP_DONE=true
    while read -r step; do
        [ -z "$step" ] && continue
        ID=$(echo "$step" | jq -r '.id')
        if [[ "${STATE_FLAGS[$ID]}" == "1" ]]; then PREV_STEP_DONE=true; continue; fi
        if [ "$PREV_STEP_DONE" = false ]; then break; fi
        if [ "$MATCHED_IDX" == "BYPASS" ] && [ "$ID" != "STEP_09_FINISH" ]; then continue; fi

        T_PAT=$(echo "$step" | jq -r '.type // empty' | tr -d '\r\n')
        N_PAT=$(echo "$step" | jq -r '.screen_name // empty' | tr -d '\r\n')
        U_PAT=$(echo "$step" | jq -r '.url // empty' | tr -d '\r\n')
        CAT=$(echo "$step" | jq -r '.category // "AutoV2"' | tr -d '\r\n')

        # --- [QoS 안전장치 전역 설정 연동 데드락 극복 동적 오버라이드] ---
        if [ "$ID" == "STEP_07_2_DRIVING_STARTED" ]; then
            if [ "$USE_GPS_QOS_GUARD" == "true" ]; then
                # QoS 안전장치가 켜진 경우: 패킷 감지 대신 화면(navi.drivemode) 진입 감지
                T_PAT="screenview"
                N_PAT="navi.drivemode"
                U_PAT=""
            else
                # QoS 안전장치가 꺼진 경우: 기존 v3/global/driving 패킷 기준 감지
                T_PAT=""
                N_PAT=""
                U_PAT="v3/global/driving.*rptype=[02]"
            fi
        fi

        if [ "$MATCHED_IDX" != "BYPASS" ]; then
            MATCHED_IDX=""
            if [ -n "$T_PAT" ] && [ -n "$N_PAT" ]; then
                grep -q -E "\[.*\] $N_PAT" "$ABS_LOG_DIR/events.log" 2>/dev/null && MATCHED_IDX="events.log"
            elif [ -n "$U_PAT" ]; then
                grep -q "$U_PAT" "$ABS_LOG_DIR/events.log" 2>/dev/null && MATCHED_IDX="events.log"
            else
                MATCHED_IDX="IMMEDIATE"
            fi
        fi

        if [ -n "$MATCHED_IDX" ]; then
            [ "$MATCHED_IDX" != "IMMEDIATE" ] && [ "$MATCHED_IDX" != "BYPASS" ] && echo "[$(NOW)] [✓] Detected Step: $ID"

            # [STATUS UPDATE] Update current_task.json based on ID
            case "$ID" in
                "STEP_02_HOME") update_live_status "HOME_READY" ;;
                "STEP_03_TYPING") update_live_status "SEARCHING" ;;
                "STEP_04_SELECT_ADDR") update_live_status "SELECTING_DEST" ;;
                "STEP_05_POI_ARRIVAL") update_live_status "CONFIRM_ARRIVAL" ;;
                "STEP_07_NAVI_START") update_live_status "STARTING_NAVI" ;;
                "STEP_07_2_DRIVING_STARTED") 
                    update_live_status "DRIVING" 
                    if [ "$USE_GPS_QOS_GUARD" == "true" ]; then
                        # QoS 안전장치 활성화 상태: 네비 진입 확정 감지 후 지연 출발 처리
                        echo "[$(NOW)] [🚀] GPS QoS Guard active. Waking up GPS Emulator..."
                        touch "logs/${DEV_ID}/tmp/guidance_started" 2>/dev/null
                    fi
                    ;;
                "STEP_08_DRIVING_GOAL") update_live_status "ARRIVED" ;;
                "STEP_09_FINISH") update_live_status "FINISHING" ;;
            esac

            # 주행 시작 시점 마킹
            if [ "$ID" == "STEP_07_2_DRIVING_STARTED" ] || [ "$ID" == "STEP_08_DRIVING" ]; then IS_DRIVING=true; fi

            ACTION=$(echo "$step" | jq -r '.action // empty' | tr -d '\r\n')
            if [ -n "$ACTION" ]; then
                if [ "$ACTION" == "TYPE_DESTINATION" ]; then
                    type_destination_only
                elif [ "$ACTION" == "SELECT_ADDR_LIST" ]; then
                    # [🔒 Subnet Lock Control] 전역 설정(USE_SUBNET_LOCK)에 의거하여 모뎀 대역폭 락 집행 여부 결정
                    if [ "$USE_SUBNET_LOCK" == "true" ] && [ -n "$SUBNET_IDX" ] && [ "$HAS_SUBNET_LOCK" != "true" ]; then
                        echo "[$(NOW)] [🔒] Subnet Lock is enabled. Waiting for lock on subnet_${SUBNET_IDX}..."
                        exec 9>>"logs/subnet_${SUBNET_IDX}.lock"
                        flock -w 1500 -x 9
                        if [ $? -ne 0 ]; then
                            echo "[$(NOW)] [⚠️] Subnet Lock wait timed out (1500s). Previous device might be hung. Proceeding anyway..."
                            HAS_SUBNET_LOCK="false"
                        else
                            HAS_SUBNET_LOCK="true"
                            LOCK_ACQUIRED_TS=$(date +%s)
                            echo "[$(NOW)] [🔓] Subnet Lock acquired on subnet_${SUBNET_IDX} at ${LOCK_ACQUIRED_TS}!"
                        fi
                    else
                        HAS_SUBNET_LOCK="false"
                        echo "[$(NOW)] [🔓] Subnet Lock bypassed (Global Config: USE_SUBNET_LOCK=false)."
                    fi
                    # Clean the address (remove detail suite/floor/room numbers)
                    CLEANED_ADDR=""
                    for word in $NMAP_DEST_ADDR; do
                        if [[ "$word" =~ [0-9]+층$ || "$word" =~ [0-9]+호$ || "$word" =~ [0-9]+실$ || "$word" =~ [0-9]+동$ || "$word" =~ ^\( ]]; then
                            break
                        fi
                        CLEANED_ADDR="$CLEANED_ADDR $word"
                    done
                    CLEANED_ADDR=$(echo "$CLEANED_ADDR" | sed 's/,$//' | xargs)

                    echo "[$(NOW)] [Action] Selecting Address: $CLEANED_ADDR (Original: $NMAP_DEST_ADDR)"
                    $MACRO_EXEC "$DEV_ID" "contains:$CLEANED_ADDR" "$CAT"
                    if [ $? -ne 0 ]; then
                        # Fallback to original address just in case
                        echo "[$(NOW)] [Action] Cleaned address not found. Retrying with original: $NMAP_DEST_ADDR"
                        $MACRO_EXEC "$DEV_ID" "contains:$NMAP_DEST_ADDR" "$CAT"
                        if [ $? -ne 0 ]; then
                            # [CROSS VALIDATION] Determine specific cause of failure from instantSearchV2 packets
                            FAIL_REASON=$(python3 macro/ui_clicker.py "$DEV_ID" "CHECK_FAILURE" "$ABS_LOG_DIR" 2>/dev/null | xargs)
                            if [ -z "$FAIL_REASON" ]; then
                                FAIL_REASON="ADDRESS_NOT_FOUND"
                            fi
                            echo "[$(NOW)] [🚨] Failure Reason Determined: $FAIL_REASON"
                             if [ "$FAIL_REASON" = "ADDRESS_NOT_FOUND" ]; then
                                 # ADDRESS_NOT_FOUND는 API 할당 키워드 문제이므로 단말기 패널티 방지를 위해 status를 API_ERROR로 우회 보고
                                 send_report_result "API_ERROR" "$FAIL_REASON"
                             else
                                 send_report_result "FAIL" "$FAIL_REASON"
                             fi
                            echo "[$(NOW)] [*] Immediate Exit for FAIL. Letting main.sh handle cleanup."
                            exit 0
                        fi
                    fi
                    ADDR_CLICK_TS=$(date +%s)
                elif [ "$ACTION" == "CLICK_ARRIVAL" ]; then
                    echo "[$(NOW)] [Action] Clicking '도착' (Arrival)..."
                    $MACRO_EXEC "$DEV_ID" "exact:도착" "$CAT"
                    [ $? -eq 0 ] && sleep 5 || break
                elif [ "$ACTION" == "btn_start_guidance" ]; then
                    echo "[$(NOW)] [Action] Clicking '안내시작' (Guidance Start)..."
                    $MACRO_EXEC "$DEV_ID" "$ACTION" "$CAT"
                    if [ $? -ne 0 ]; then
                        send_report_result "FAIL" "GUIDANCE_NOT_FOUND"
                        echo "[$(NOW)] [*] Immediate Exit for FAIL. Letting main.sh handle cleanup."
                        exit 0
                    else
                        NAVI_START_TS=$(date +%s)
                        if [ "$USE_GPS_QOS_GUARD" != "true" ]; then
                            # Signal auto_reloader.py to start GPS immediately after clicking guidance start (QoS Guard disabled)
                            echo "[$(NOW)] [🚀] GPS QoS Guard is FALSE. Starting GPS Emulator immediately..."
                            touch "logs/${DEV_ID}/tmp/guidance_started" 2>/dev/null
                        else
                            echo "[$(NOW)] [🛰️] GPS QoS Guard is TRUE. Delaying GPS Emulator start until driving screen is active."
                        fi
                    fi
                elif [ "$ACTION" == "EXIT_SUCCESS" ]; then
                    WAIT_SEC=${END_ROUTE_WAIT_SECONDS:-10}
                    echo "[$(NOW)] [Action] GOAL REACHED. Waiting ${WAIT_SEC}s for transition to safety driving mode..."
                    sleep "$WAIT_SEC"
                    echo "[$(NOW)] [Action] EXTRACTING ACTUAL STATS AND VALIDATING IDENTITY..."
                    
                    # Verify captured packets existence (routeend is mandatory, trafficjam is optional)
                    ROUTEEND_FILE=$(ls -1 "$ABS_LOG_DIR"/*routeend*.json 2>/dev/null | head -n 1)
                    TRAFFICJAM_FILE=$(ls -1 "$ABS_LOG_DIR"/*_trafficjam_log.json 2>/dev/null | head -n 1)
                    
                    if [ -z "$ROUTEEND_FILE" ]; then
                        echo "[$(NOW)] [🚨] SUCCESS VERIFICATION FAILED: Missing routeend packet."
                        send_report_result "FAIL" "MISSING_ARRIVAL_PACKETS: routeend log missing"
                        exit 1
                    fi

                    ACTUAL_DIST=0; ACTUAL_TIME=0
                    
                    # 1. Try legacy trafficjam_log first (for Naver Map 6.7.x)
                    for f in $(ls -1v "$ABS_LOG_DIR"/*_trafficjam_log.json 2>/dev/null); do
                        DIST_VAL=$(jq -r '.request.body._decoded."1"."12" // 0' "$f" 2>/dev/null)
                        TIME_VAL=$(jq -r '.request.body._decoded."1"."13" // 0' "$f" 2>/dev/null)
                        if [ "$DIST_VAL" != "0" ] && [ "$TIME_VAL" != "0" ]; then
                            ACTUAL_DIST=$DIST_VAL; ACTUAL_TIME=$TIME_VAL
                            echo "    > Found Stats in legacy trafficjam_log ($(basename "$f")): ${ACTUAL_DIST}m | ${ACTUAL_TIME}s"
                            break
                        fi
                    done
                    
                    # 2. Try new log-receiver POST_log if legacy is missing (for Naver Map 6.8.x)
                    if [ "$ACTUAL_DIST" = "0" ] || [ "$ACTUAL_TIME" = "0" ]; then
                        for f in $(ls -1v "$ABS_LOG_DIR"/*_POST_log.json 2>/dev/null); do
                            URL_CHECK=$(jq -r '.url // empty' "$f" 2>/dev/null)
                            if [[ "$URL_CHECK" == *"log-receiver"* ]]; then
                                DIST_VAL=$(jq -r '.request.body._decoded."1"."12" // 0' "$f" 2>/dev/null)
                                TIME_VAL=$(jq -r '.request.body._decoded."1"."13" // 0' "$f" 2>/dev/null)
                                if [ "$DIST_VAL" != "0" ] && [ "$TIME_VAL" != "0" ]; then
                                    ACTUAL_DIST=$DIST_VAL; ACTUAL_TIME=$TIME_VAL
                                    echo "    > Found Stats in new log-receiver ($(basename "$f")): ${ACTUAL_DIST}m | ${ACTUAL_TIME}s"
                                    break
                                fi
                            fi
                        done
                    fi

                    # 3. Fallback: Parse from routeend URL query parameters if both log files are missing
                    if [ "$ACTUAL_DIST" = "0" ] || [ "$ACTUAL_TIME" = "0" ]; then
                        echo "    > Fallback: Extracting stats from routeend URL..."
                        RE_URL=$(jq -r '.url // empty' "$ROUTEEND_FILE" 2>/dev/null)
                        if [ -n "$RE_URL" ]; then
                            START_TS=$(echo "$RE_URL" | grep -oE 'startts=[0-9]+' | cut -d= -f2)
                            END_TS=$(echo "$RE_URL" | grep -oE 'endts=[0-9]+' | cut -d= -f2)
                            MILEAGE=$(echo "$RE_URL" | grep -oE 'mileage=[0-9.]+' | cut -d= -f2)
                            
                            if [ -n "$START_TS" ] && [ -n "$END_TS" ]; then
                                ACTUAL_TIME=$(( (END_TS - START_TS) / 1000 ))
                            fi
                            if [ -n "$MILEAGE" ]; then
                                ACTUAL_DIST=$(awk "BEGIN {printf \"%.0f\", $MILEAGE * 1000}")
                            fi
                            echo "    > Extracted from routeend: ${ACTUAL_DIST}m | ${ACTUAL_TIME}s"
                        fi
                    fi
                    
                    # [NEW] Mandatory Identity Validation Check
                    IDENTITY_VALID=true
                    IDENTITY_ERROR=""
                    LATEST_NLOG=$(ls -1t "$ABS_LOG_DIR"/*_POST_nlogapp.json 2>/dev/null | head -n 1)
                    if [ -z "$LATEST_NLOG" ]; then
                        IDENTITY_VALID=false
                        IDENTITY_ERROR="No nlogapp packet found to verify identity."
                    else
                        LOG_ADID=$(jq -r '.request.body.usr.adid // empty' "$LATEST_NLOG" 2>/dev/null)
                        LOG_SSAID=$(jq -r '.request.body.usr.ssaid // empty' "$LATEST_NLOG" 2>/dev/null)
                        LOG_IDFV=$(jq -r '.request.body.usr.idfv // empty' "$LATEST_NLOG" 2>/dev/null)
                        LOG_NI=$(jq -r '.request.body.usr.ni // empty' "$LATEST_NLOG" 2>/dev/null)
                        LOG_FULL_TOKEN=$(jq -r '.request.body.evts[0].nlog_id // empty' "$LATEST_NLOG" 2>/dev/null)
                        LOG_TOKEN=$(echo "$LOG_FULL_TOKEN" | awk -F'.' '{print $NF}')
                        
                        [ "$LOG_ADID" != "$NMAP_ID_ADID" ] && IDENTITY_VALID=false && IDENTITY_ERROR="ADID mismatch: Req($NMAP_ID_ADID) vs Log($LOG_ADID)"
                        [ "$LOG_SSAID" != "$NMAP_ID_SSAID" ] && IDENTITY_VALID=false && IDENTITY_ERROR="SSAID mismatch: Req($NMAP_ID_SSAID) vs Log($LOG_SSAID)"
                        [ "$LOG_IDFV" != "$NMAP_ID_IDFV" ] && IDENTITY_VALID=false && IDENTITY_ERROR="IDFV mismatch: Req($NMAP_ID_IDFV) vs Log($LOG_IDFV)"
                        [ "$LOG_NI" != "$NMAP_ID_NI" ] && IDENTITY_VALID=false && IDENTITY_ERROR="NI mismatch: Req($NMAP_ID_NI) vs Log($LOG_NI)"
                        [ "$LOG_TOKEN" != "$NMAP_ID_TOKEN" ] && IDENTITY_VALID=false && IDENTITY_ERROR="TOKEN mismatch: Req($NMAP_ID_TOKEN) vs Log($LOG_TOKEN)"
                    fi

                    if [ "$IDENTITY_VALID" = true ]; then
                        echo "[$(NOW)] [✓] Identity Validation Passed. All target values matched."
                        
                        # Calculate final average speed to report to server
                        FINAL_CALC_SPEED=0
                        if [ "$ACTUAL_TIME" -gt 0 ]; then
                            FINAL_CALC_SPEED=$(awk "BEGIN {printf \"%.2f\", ($ACTUAL_DIST / 1000) / ($ACTUAL_TIME / 3600)}")
                        fi
                        
                        extra_json="\"drive_dist\": $ACTUAL_DIST, \"drive_time\": $ACTUAL_TIME, \"calc_speed\": $FINAL_CALC_SPEED"
                        send_report_result "SUCCESS" "정상 도착 및 클릭 완료" "$extra_json"
                    else
                        echo "[$(NOW)] [🚨] IDENTITY VALIDATION FAILED: $IDENTITY_ERROR"
                        send_report_result "FAIL" "IDENTITY_MISMATCH: $IDENTITY_ERROR"
                    fi

                    # Exit immediately to avoid crashes overwriting status
                    echo "[$(NOW)] [*] Immediate Exit for SUCCESS. Letting main.sh handle cleanup."
                    echo "{\"status\":\"SUCCESS\"}" > "$CURRENT_TASK_JSON"
                    exit 0
                else
                    if [ "$ID" == "STEP_02_HOME" ]; then
                        human_random_sleep
                    elif [ "$ID" == "STEP_05_POI_ARRIVAL" ]; then
                        # [⚡ 통계 기반 정밀 제어] 주소 클릭 후 캡차 검증 완료까지 평균 10.2초 소요 (95% 확률로 11초 이내 발생)
                        # 주소 클릭 시점(ADDR_CLICK_TS)으로부터 정확히 11초가 경과할 때까지 동적으로 슬립
                        if [ -n "$ADDR_CLICK_TS" ]; then
                            local ADDR_ELAPSED=$(( $(date +%s) - ADDR_CLICK_TS ))
                            if [ $ADDR_ELAPSED -lt 11 ]; then
                                local req_sleep=$(( 11 - ADDR_ELAPSED ))
                                echo "[$(NOW)] [Delay] Dynamic Captcha Buffer sleep for ${req_sleep}s (Total: 11s since Address Click)..."
                                sleep $req_sleep
                            else
                                echo "[$(NOW)] [Delay] Dynamic Captcha Buffer bypassed (already elapsed ${ADDR_ELAPSED}s since Address Click)..."
                            fi
                        else
                            echo "[$(NOW)] [Delay] Default Captcha Buffer sleep for 5s..."
                            sleep 5
                        fi
                        
                        # [🚨 신규 방어선] 도착 클릭 직전 에러로그 재검사 (대기 도중 발생한 캡차 타임아웃 사전 차단)
                        local TEMP_ERR_FILE=$(ls -1 "$ABS_LOG_DIR"/*_POST_client-logger_errorLog.json 2>/dev/null | head -n 1)
                        if [ -n "$TEMP_ERR_FILE" ]; then
                            local TEMP_ERR_MSG=$(jq -r '.request.body.message // empty' "$TEMP_ERR_FILE" 2>/dev/null)
                            if [ -n "$TEMP_ERR_MSG" ]; then
                                echo "[$(NOW)] [🚨] Pre-Arrival Fail-Fast: errorLog detected during captcha buffer sleep: $TEMP_ERR_MSG"
                                send_report_result "FAIL" "ERROR_LOG_DETECTED: $TEMP_ERR_MSG"
                                stop_gps; adb -s "$DEV_ID" shell am force-stop "$PKG_NAME"; exit 1
                            fi
                        fi
                    fi
                    echo "[$(NOW)] [Action] Executing: $ACTION"
                    $MACRO_EXEC "$DEV_ID" "$ACTION" "$CAT"
                    if [ $? -ne 0 ]; then
                        if [ "$ACTION" == "entry_search_field" ]; then
                            send_report_result "FAIL" "SEARCH_FIELD_NOT_FOUND"
                            echo "[$(NOW)] [*] Immediate Exit for FAIL. Letting main.sh handle cleanup."
                            exit 0
                        else
                            break
                        fi
                    fi
                fi
            fi
            STATE_FLAGS[$ID]=1; PREV_STEP_DONE=true; continue 
        fi
        
        IS_REQUIRED=$(echo "$step" | jq -r 'if .control.required == null then true else .control.required end')
        if [ "$IS_REQUIRED" == "false" ]; then PREV_STEP_DONE=true; continue; fi
        PREV_STEP_DONE=false
    done < <(jq -c '.steps[]' "$SCHEDULE_JSON")

    sleep 5
done
