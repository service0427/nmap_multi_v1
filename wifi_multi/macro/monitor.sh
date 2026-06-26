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

export ABS_LOG_DIR=$(realpath "$LOG_DIR")
export CAPTURE_LOG_DIR="$ABS_LOG_DIR"
EXEC_LOG="$ABS_LOG_DIR/execution.log"
exec >> "$EXEC_LOG" 2>&1

MACRO_EXEC="python3 macro/macro_executor.py"
SCHEDULE_JSON="macro/action_schedule.json"

CURRENT_TASK_JSON="${WIFI_MULTI_LOGS}/${DEV_ID}/current_task.json"

# --- [CORE] Functions ---
NOW() { date +"%H:%M:%S.%3N"; }

send_api_request() {
    local endpoint=$1
    local payload=$2
    echo "[$(NOW)] [API_REQ] $endpoint -> $payload"
    local response=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST "http://${API_SERVER:-localhost:8000}${endpoint}" \
         -H "Content-Type: application/json" -d "$payload")
    echo "[$(NOW)] [API_RES] $response"
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

# [NEW] Transition Timeout Variables
NAVI_START_TS=0

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
        send_api_request "/api/v1/report_result" "{\"task_id\": $NMAP_LOG_ID, \"status\": \"FAIL\", \"device_id\": \"$DEV_ID\", \"message\": \"GLOBAL_TIMEOUT\"}"
        adb -s "$DEV_ID" shell am force-stop "$PKG_NAME"; exit 1
    fi

    # 2. Process Survival Check
    if [ $ELAPSED -gt 30 ]; then
        if ! adb -s "$DEV_ID" shell pidof "$PKG_NAME" >/dev/null 2>&1; then
            echo "[$(NOW)] [!] App process dead. Stopping scheduler."; exit 1
        fi
    fi

    # [NEW] Fast Fatal UI Error Detection (No Route Found, etc.)
    if [ "$IS_DRIVING" = false ] && [ $ELAPSED -gt 30 ]; then
        local CUR_TS
        CUR_TS=$(date +%s)
        local SEC_SINCE_CHECK=$(( CUR_TS - LAST_UI_CHECK_TS ))
        if [ $SEC_SINCE_CHECK -ge 30 ]; then
            LAST_UI_CHECK_TS=$CUR_TS
            # Dump UI XML
            adb -s "$DEV_ID" shell "uiautomator dump /sdcard/ui.xml" >/dev/null 2>&1
            local XML_CONTENT
            XML_CONTENT=$(adb -s "$DEV_ID" shell "cat /sdcard/ui.xml" 2>/dev/null)
            if [ -n "$XML_CONTENT" ]; then
                local FATAL_PATTERN="길찾기 결과가 없습니다|결과를 제공할 수 없습니다|검색 결과가 없습니다|장소를 찾을 수 없습니다|길찾기 결과를 제공할 수 없습니다|검색 결과가 없어요|출발지와 도착지가 같습니다|출발지와 목적지가 같습니다|주변에 도로가 없습니다|안내할 수 없는 경로입니다|네트워크 연결이 원활하지 않습니다|네트워크 연결 상태를 확인|네트워크가 연결되어 있지 않습니다|알 수 없는 에러가 발생했습니다"
                if echo "$XML_CONTENT" | grep -q -E "$FATAL_PATTERN"; then
                    local MATCHED_MSG
                    MATCHED_MSG=$(echo "$XML_CONTENT" | grep -o -E "$FATAL_PATTERN" | head -n 1)
                    echo "[$(NOW)] [🚨] Fatal UI State Detected ('$MATCHED_MSG'). Fail-fast."
                    send_api_request "/api/v1/report_result" "{\"task_id\": $NMAP_LOG_ID, \"status\": \"FAIL\", \"device_id\": \"$DEV_ID\", \"message\": \"NO_ROUTE_FOUND: $MATCHED_MSG\"}"
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
                        send_api_request "/api/v1/report_result" "{\"task_id\": $NMAP_LOG_ID, \"status\": \"FAIL\", \"device_id\": \"$DEV_ID\", \"message\": \"ROUTE_CALCULATION_FAILED_OR_HUNG\"}"
                        echo "[$(NOW)] [*] Immediate Exit for FAIL due to Route Calculation Fail/Hang. Letting main.sh handle cleanup."
                        exit 0
                    fi
                fi
            fi
        fi
    fi

    # [NEW] Proactive Popup Killer & UI Home screen detector if Home Screen is delayed
    if [[ "${STATE_FLAGS[STEP_02_HOME]}" != "1" ]]; then
        # Check UI to see if Home screen is already visible
        adb -s "$DEV_ID" shell "uiautomator dump /sdcard/ui_home_check.xml" >/dev/null 2>&1
        local CHECK_XML
        CHECK_XML=$(adb -s "$DEV_ID" shell "cat /sdcard/ui_home_check.xml" 2>/dev/null)
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
    
    # [NEW] Fail-Fast: Guidance Transition Timeout (e.g. Toast message blocked routing)
    # Transition timeout removed to emulate stable main branch behavior

    # 3. Packet-File Silence Kill (Global Check for Frida/App Health)
    # 개별 요청 JSON 파일들이 새로 생성되고 있는지 숫자로 체크
    CUR_JSON_COUNT=$(ls -1 "$ABS_LOG_DIR"/*.json 2>/dev/null | grep -v -E "heartbeat|location|sdk_log|log_batch|geojson|metadata|my_notices|weather" | wc -l)
    if [ $CUR_JSON_COUNT -gt $LAST_JSON_COUNT ]; then
        STUCK_COUNT=0; LAST_JSON_COUNT=$CUR_JSON_COUNT
    else
        ((STUCK_COUNT++))
        
        # [NEW] Dynamic Silence Tolerance: Give driving cars much more time to recover from drops
        local MAX_STUCK=18 # Default 90s (18 * 5s)
        if [ "$IS_DRIVING" = true ]; then
            MAX_STUCK=60 # 300s (5 minutes) resilience during driving
        fi
        
        if [ $STUCK_COUNT -ge $MAX_STUCK ]; then
            echo "[$(NOW)] [🚨] SILENCE DETECTED ($((MAX_STUCK * 5))s). No new packet JSONs. Killing session."
            send_api_request "/api/v1/report_result" "{\"task_id\": $NMAP_LOG_ID, \"status\": \"FAIL\", \"device_id\": \"$DEV_ID\", \"message\": \"PACKET_STUCK\"}"
            stop_gps; adb -s "$DEV_ID" shell am force-stop "$PKG_NAME"; exit 1
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
    echo "    > Waiting 4s for recommendation list..."; sleep 4
}

echo "[$(NOW)] [Scheduler:$DEV_ID] V18.4 Strict Mode Started."

# === Main Loop ===
while true; do
    check_app_survival
    
    # [NEW] Auto-Recovery for Stuck Navigation / Resume Guidance State
    if [[ "${STATE_FLAGS[STEP_02_HOME]}" != "1" ]]; then
        if grep -q -E "v3/global/driving|trafficjam/location" "$ABS_LOG_DIR/events.log" 2>/dev/null; then
            # Verify if we are actually in navigation vs on Home screen
            adb -s "$DEV_ID" shell "uiautomator dump /sdcard/ui_recovery.xml" >/dev/null 2>&1
            RECOVERY_XML=$(adb -s "$DEV_ID" shell "cat /sdcard/ui_recovery.xml" 2>/dev/null)
            
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
                "STEP_07_2_DRIVING_STARTED") update_live_status "DRIVING" ;;
                "STEP_08_DRIVING_GOAL") update_live_status "ARRIVED" ;;
                "STEP_09_FINISH") update_live_status "SUCCESS" ;;
            esac

            # 주행 시작 시점 마킹
            if [ "$ID" == "STEP_07_2_DRIVING_STARTED" ] || [ "$ID" == "STEP_08_DRIVING" ]; then IS_DRIVING=true; fi

            ACTION=$(echo "$step" | jq -r '.action // empty' | tr -d '\r\n')
            if [ -n "$ACTION" ]; then
                if [ "$ACTION" == "TYPE_DESTINATION" ]; then type_destination_only
                elif [ "$ACTION" == "SELECT_ADDR_LIST" ]; then
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
                            send_api_request "/api/v1/report_result" "{\"task_id\": $NMAP_LOG_ID, \"status\": \"FAIL\", \"device_id\": \"$DEV_ID\", \"message\": \"ADDRESS_NOT_FOUND\"}"
                            echo "[$(NOW)] [*] Immediate Exit for FAIL. Letting main.sh handle cleanup."
                            exit 0
                        fi
                    fi
                elif [ "$ACTION" == "CLICK_ARRIVAL" ]; then
                    echo "[$(NOW)] [Action] Clicking '도착' (Arrival)..."
                    $MACRO_EXEC "$DEV_ID" "exact:도착" "$CAT"
                    [ $? -eq 0 ] && sleep 5 || break
                elif [ "$ACTION" == "btn_start_guidance" ]; then
                    echo "[$(NOW)] [Action] Clicking '안내시작' (Guidance Start)..."
                    $MACRO_EXEC "$DEV_ID" "$ACTION" "$CAT"
                    if [ $? -ne 0 ]; then
                        send_api_request "/api/v1/report_result" "{\"task_id\": $NMAP_LOG_ID, \"status\": \"FAIL\", \"device_id\": \"$DEV_ID\", \"message\": \"GUIDANCE_NOT_FOUND\"}"
                        echo "[$(NOW)] [*] Immediate Exit for FAIL. Letting main.sh handle cleanup."
                        exit 0
                    else
                        NAVI_START_TS=$(date +%s)
                        # Signal auto_reloader.py to start GPS
                        touch "logs/${DEV_ID}/tmp/guidance_started" 2>/dev/null
                    fi
                elif [ "$ACTION" == "EXIT_SUCCESS" ]; then
                    echo "[$(NOW)] [Action] GOAL REACHED. EXTRACTING ACTUAL STATS AND VALIDATING IDENTITY..."
                    ACTUAL_DIST=0; ACTUAL_TIME=0
                    for f in $(ls -1v "$ABS_LOG_DIR"/*_trafficjam_log.json 2>/dev/null); do
                        DIST_VAL=$(jq -r '.request.body._decoded."1"."12" // 0' "$f" 2>/dev/null)
                        TIME_VAL=$(jq -r '.request.body._decoded."1"."13" // 0' "$f" 2>/dev/null)
                        if [ "$DIST_VAL" != "0" ] && [ "$TIME_VAL" != "0" ]; then
                            ACTUAL_DIST=$DIST_VAL; ACTUAL_TIME=$TIME_VAL
                            echo "    > Found Stats in $(basename "$f"): ${ACTUAL_DIST}m | ${ACTUAL_TIME}s"
                            break
                        fi
                    done
                    
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
                        
                        [ "$LOG_ADID" != "$NMAP_ID_ADID" ] && IDENTITY_VALID=false && IDENTITY_ERROR="ADID mismatch: Req($NMAP_ID_ADID) vs Log($LOG_ADID)"
                        [ "$LOG_SSAID" != "$NMAP_ID_SSAID" ] && IDENTITY_VALID=false && IDENTITY_ERROR="SSAID mismatch: Req($NMAP_ID_SSAID) vs Log($LOG_SSAID)"
                        [ "$LOG_IDFV" != "$NMAP_ID_IDFV" ] && IDENTITY_VALID=false && IDENTITY_ERROR="IDFV mismatch: Req($NMAP_ID_IDFV) vs Log($LOG_IDFV)"
                        [ "$LOG_NI" != "$NMAP_ID_NI" ] && IDENTITY_VALID=false && IDENTITY_ERROR="NI mismatch: Req($NMAP_ID_NI) vs Log($LOG_NI)"
                    fi

                    if [ "$IDENTITY_VALID" = true ]; then
                        echo "[$(NOW)] [✓] Identity Validation Passed. All target values matched."
                        
                        # Calculate final average speed to report to server
                        FINAL_CALC_SPEED=0
                        if [ "$ACTUAL_TIME" -gt 0 ]; then
                            FINAL_CALC_SPEED=$(awk "BEGIN {printf \"%.2f\", ($ACTUAL_DIST / 1000) / ($ACTUAL_TIME / 3600)}")
                        fi
                        
                        send_api_request "/api/v1/report_result" "{\"task_id\": $NMAP_LOG_ID, \"status\": \"SUCCESS\", \"device_id\": \"$DEV_ID\", \"drive_dist\": $ACTUAL_DIST, \"drive_time\": $ACTUAL_TIME, \"calc_speed\": $FINAL_CALC_SPEED, \"message\": \"정상 도착 및 클릭 완료\"}"
                    else
                        echo "[$(NOW)] [🚨] IDENTITY VALIDATION FAILED: $IDENTITY_ERROR"
                        send_api_request "/api/v1/report_result" "{\"task_id\": $NMAP_LOG_ID, \"status\": \"FAIL\", \"device_id\": \"$DEV_ID\", \"message\": \"IDENTITY_MISMATCH: $IDENTITY_ERROR\"}"
                    fi

                    # Exit immediately to avoid crashes overwriting status
                    echo "[$(NOW)] [*] Immediate Exit for SUCCESS. Letting main.sh handle cleanup."
                    echo "{\"status\":\"SUCCESS\"}" > "$CURRENT_TASK_JSON"
                    exit 0
                else
                    [ "$ID" == "STEP_02_HOME" ] && human_random_sleep
                    echo "[$(NOW)] [Action] Executing: $ACTION"
                    $MACRO_EXEC "$DEV_ID" "$ACTION" "$CAT"
                    if [ $? -ne 0 ]; then
                        if [ "$ACTION" == "entry_search_field" ]; then
                            send_api_request "/api/v1/report_result" "{\"task_id\": $NMAP_LOG_ID, \"status\": \"FAIL\", \"device_id\": \"$DEV_ID\", \"message\": \"SEARCH_FIELD_NOT_FOUND\"}"
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
        
        IS_REQUIRED=$(echo "$step" | jq -r '.control.required // true')
        if [ "$IS_REQUIRED" == "false" ]; then PREV_STEP_DONE=true; continue; fi
        PREV_STEP_DONE=false
    done < <(jq -c '.steps[]' "$SCHEDULE_JSON")

    sleep 5
done
