#!/bin/bash
# Smart Multi-Device Orchestrator (V19.1 - Dynamic SSID Mapping)
# Automatically maps devices to modems based on current Wi-Fi SSID suffix

# --- [CONFIGURATION] ---
MANUAL_COUNTS=(5 5 5 5)
API_SERVER="114.207.112.245:8011"

# --- [CACHING] ---
declare -A SSID_CACHE
declare -A DEVICE_MODEL_CACHE
declare -A SUBNET_CACHE
declare -A DEV_EXCLUDE_UNTIL

# --- [PATH SETUP] ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR" || exit 1

# Override configuration from external file if exists
if [ -f "$SCRIPT_DIR/config.conf" ]; then
    source "$SCRIPT_DIR/config.conf"
elif [ -f "$SCRIPT_DIR/manual_counts.conf" ]; then
    source "$SCRIPT_DIR/manual_counts.conf"
fi

export WIFI_MULTI_ROOT="$SCRIPT_DIR"
export WIFI_MULTI_LOGS="$SCRIPT_DIR/logs"
export WIFI_MULTI_LIB="$SCRIPT_DIR/lib"
export API_SERVER

pkill -9 -f "main.sh"
pkill -9 -f "mitmdump"
sleep 2

get_ip() {
    ip -4 addr show "$1" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n 1
}

get_device_ssid() {
    local SERIAL=$1
    local SSID=$(timeout 3 adb -s "$SERIAL" shell "cmd wifi status | grep -oE 'SSID: [^,]+' | head -n 1" | sed 's/SSID: //g' | tr -d '\"\r\n')
    if [ -z "$SSID" ] || [ "$SSID" = "SSID" ]; then
        SSID=$(timeout 3 adb -s "$SERIAL" shell "dumpsys connectivity | grep -oE 'SSID: \"[^\"]+\"' | head -n 1" | cut -d'"' -f2 | tr -d '\r\n')
    fi
    echo "$SSID"
}

get_device_wifi_subnet() {
    local SERIAL=$1
    local IP=$(timeout 3 adb -s "$SERIAL" shell "ip route get 1.1.1.1 2>/dev/null" | grep -oE "src [0-9.]+" | awk '{print $2}')
    if [ -z "$IP" ]; then
        IP=$(timeout 3 adb -s "$SERIAL" shell "ip addr show wlan0 2>/dev/null" | grep -oE 'inet [0-9./]+' | head -n 1 | awk '{print $2}' | cut -d/ -f1)
    fi
    if [ -n "$IP" ]; then
        echo "$IP" | cut -d. -f3
    fi
}

while true; do
    # --- [STALE PROCESS SELF-HEALING CLEANER] ---
    # 20분(1200초) 이상 구동 중인 main.sh 프로세스가 있다면 15분 안전장치가 정상 동작하지 못한 좀비 상태로 판정하여 강제 킬 및 락 초기화 진행
    while read -r pid etime args; do
        [ -z "$pid" ] && continue
        # args에서 DEV_ID 추출 (예: 'bash /home/tech/.../main.sh R3CN807BQXA')
        DEV_ID=$(echo "$args" | awk '{print $NF}')
        if [ "$etime" -gt 1200 ] && [ -n "$DEV_ID" ]; then
            echo "[⚠️] [$(date +%T)] [$DEV_ID] DETECTED STALE PROCESS (PID: $pid, Elapsed: ${etime}s). Force killing..."
            
            # 포트 파싱 및 미트덤프/프리다 정리 (current_task.json에서 고유 device_seq를 조회하여 복원)
            # [원칙] DB 고유의 불변값인 device_seq를 기반으로 포트를 지정하므로 충돌이 없습니다.
            # 절대 cksum 방식으로 롤백하지 마십시오.
            SEQ=$(jq -r '.device_seq // empty' "logs/${DEV_ID}/current_task.json" 2>/dev/null)
            if [ -n "$SEQ" ] && [ "$SEQ" != "null" ]; then
                FRIDA_PORT=$((10000 + SEQ))
                MITM_PORT=$((20000 + SEQ))
            else
                # Fallback: 만약 current_task.json에 없고 최근 api_response.json이 존재한다면 탐색
                LATEST_API_RESP=$(find "logs/${DEV_ID}" -name "api_response.json" 2>/dev/null | sort | tail -n 1)
                if [ -n "$LATEST_API_RESP" ]; then
                    SEQ=$(jq -r '.device_seq // empty' "$LATEST_API_RESP" 2>/dev/null)
                fi
                if [ -n "$SEQ" ] && [ "$SEQ" != "null" ]; then
                    FRIDA_PORT=$((10000 + SEQ))
                    MITM_PORT=$((20000 + SEQ))
                else
                    FRIDA_PORT=""
                    MITM_PORT=""
                fi
            fi

            # 프로세스 강제 종료
            pkill -9 -f "main.sh $DEV_ID"
            pkill -9 -f "monitor.sh $DEV_ID"
            pkill -9 -f "auto_reloader.py .* $DEV_ID"
            
            if [ -n "$FRIDA_PORT" ]; then
                pkill -9 -f "mitmdump -p $MITM_PORT"
                pkill -9 -f "frida -H localhost:$FRIDA_PORT"
                
                # ADB 터널 및 프록시 설정 원복
                timeout 10 adb -s "$DEV_ID" forward --remove tcp:"$FRIDA_PORT" 2>/dev/null
                timeout 10 adb -s "$DEV_ID" reverse --remove tcp:"$MITM_PORT" 2>/dev/null
            else
                # 혹시라도 포트 조회가 실패한 비상 상황의 경우, 기기명을 인자로 갖는 mitmdump 등을 킬
                pkill -9 -f "mitmdump .* $DEV_ID"
            fi
            
            timeout 10 adb -s "$DEV_ID" shell am force-stop com.nhn.android.nmap 2>/dev/null
            timeout 10 adb -s "$DEV_ID" shell settings put global http_proxy :0 2>/dev/null
            
            # 락 파일 및 태스크 메타파일 정리
            rm -f "logs/${DEV_ID}/tmp/nmap_lock" "logs/${DEV_ID}/current_task.json" "logs/${DEV_ID}/tmp/guidance_started" 2>/dev/null
            
            # API 서버에 실패 결과 보고
            curl -s -X POST "http://${API_SERVER}/api/v1/report_result" \
                 -H "Content-Type: application/json" \
                 -d "{\"task_id\": \"stale_kill\", \"device_id\": \"$DEV_ID\", \"status\": \"FAIL\", \"message\": \"STALE_PROCESS_KILLED_ELAPSED_${etime}s\"}" > /dev/null
        fi
    done < <(ps -eo pid,etimes,args | grep -E "bash .*/main\.sh " | grep -v grep)

    DEVICES=$(timeout 5 adb devices | grep -w "device" | awk '{print $1}')
    [ -z "$DEVICES" ] && sleep 10 && continue

    IP_LIST=()
    MODEM_STR=""
    for i in "${!MANUAL_COUNTS[@]}"; do
        modem_num=$((11 + i))
        ip_val=$(get_ip "lte$modem_num")
        IP_LIST+=("$ip_val")
        MODEM_STR="$MODEM_STR lte$modem_num:$ip_val,"
    done
    MODEM_STR=${MODEM_STR%,}

    echo "------------------------------------------------------------"
    echo "[$(date +%T)] Scanning $(echo $DEVICES | wc -w) devices..."
    echo "Current Modems:$MODEM_STR"

    DEV_INDEX=0
    for DEV_ID in $DEVICES; do
        if pgrep -f "main.sh $DEV_ID" > /dev/null; then 
            DEV_INDEX=$((DEV_INDEX + 1))
            continue
        fi

        # --- IP Failure Cooldown Shield (180s) ---
        if [ -f "logs/${DEV_ID}/tmp/ip_failed_gate" ]; then
            CURRENT_TIME=$(date +%s)
            DEV_EXCLUDE_UNTIL[$DEV_ID]=$((CURRENT_TIME + 180))
            rm -f "logs/${DEV_ID}/tmp/ip_failed_gate"
            echo "[IP_BLOCKED] [$DEV_ID] IP lookup failed. Applying heavy 180s cooldown to save modem bandwidth."
            mkdir -p "logs/${DEV_ID}"
            echo "{\"status\": \"IP_COOLDOWN\", \"exclude_until\": ${DEV_EXCLUDE_UNTIL[$DEV_ID]}}" > "logs/${DEV_ID}/current_task.json"
            DEV_INDEX=$((DEV_INDEX + 1))
            continue
        fi

        # --- Pre-Cleanup: Ensure stale Naver Map app is closed if loop is idle ---
        if [ ! -f "logs/${DEV_ID}/tmp/nmap_lock" ]; then
            timeout 5 adb -s "$DEV_ID" shell "am force-stop com.nhn.android.nmap; settings put global http_proxy :0" >/dev/null 2>&1
        fi

        # Ensure ADBKeyboard is enabled and set as default IME
        CURRENT_IME=$(timeout 3 adb -s "$DEV_ID" shell settings get secure default_input_method 2>/dev/null | tr -d '\r\n')
        if [ "$CURRENT_IME" != "com.android.adbkeyboard/.AdbIME" ]; then
            echo "[*] [$DEV_ID] Setting ADBKeyboard as default input method..."
            timeout 3 adb -s "$DEV_ID" shell ime enable com.android.adbkeyboard/.AdbIME >/dev/null 2>&1
            timeout 3 adb -s "$DEV_ID" shell ime set com.android.adbkeyboard/.AdbIME >/dev/null 2>&1
        fi

        # --- [NEW] Dynamic SSID-to-Modem Mapping with Caching & Z Flip Override ---
        BIND_IP=""
        MODEM_IDX=""
        
        # 1. Device Initial Scan: Cache model and override state for Z Flip models if CLOSED
        if [ -z "${DEVICE_MODEL_CACHE[$DEV_ID]}" ]; then
            MODEL=$(timeout 3 adb -s "$DEV_ID" shell "getprop ro.product.model" | tr -d '\r\n')
            if [ -n "$MODEL" ]; then
                DEVICE_MODEL_CACHE["$DEV_ID"]="$MODEL"
                echo "[INITIALIZE] [$DEV_ID] Detected Model: $MODEL"
                if [[ "$MODEL" == "SM-F711N" || "$MODEL" == "SM-F721N" ]]; then
                    if adb -s "$DEV_ID" shell cmd device_state state 2>/dev/null | grep -q "Committed state:.*CLOSE"; then
                        echo "[INITIALIZE] [$DEV_ID] Z Flip is CLOSED. Overriding to state 3 (OPEN)..."
                        adb -s "$DEV_ID" shell cmd device_state state 3 >/dev/null 2>&1
                    fi
                fi
            fi
        fi

        # 2. Get Wi-Fi IP Subnet with caching to prevent excessive adb queries
        SUBNET_IDX="${SUBNET_CACHE[$DEV_ID]}"
        if [ -z "$SUBNET_IDX" ]; then
            SUBNET_IDX=$(get_device_wifi_subnet "$DEV_ID")
            if [ -n "$SUBNET_IDX" ]; then
                SUBNET_CACHE["$DEV_ID"]="$SUBNET_IDX"
                echo "[DYNAMICS] [$DEV_ID] Cached Wi-Fi IP Subnet: 192.168.${SUBNET_IDX}.x"
            fi
        fi
        
        # 3. Map Wi-Fi IP Subnet to Modem interface (e.g. 192.168.11.x -> lte11)
        if [ -n "$SUBNET_IDX" ]; then
            MODEM_IDX=$SUBNET_IDX
            modem_idx_offset=$((MODEM_IDX - 11))
            if [ "$modem_idx_offset" -ge 0 ] && [ "$modem_idx_offset" -lt "${#MANUAL_COUNTS[@]}" ]; then
                BIND_IP="${IP_LIST[$modem_idx_offset]}"
                if [ -n "$BIND_IP" ]; then
                    echo "[DYNAMICS] [$DEV_ID] Matched IP Subnet '192.168.${SUBNET_IDX}.x' to Modem lte$MODEM_IDX ($BIND_IP)"
                fi
            fi
        fi

        # --- Strict Safety Gate: Prevent execution if mapping fails (NO FALLBACK) ---
        if [ -z "$BIND_IP" ]; then
            # Clear cache in case the device changed Wi-Fi AP
            unset "SUBNET_CACHE[$DEV_ID]"
            SSID=$(get_device_ssid "$DEV_ID")
            echo "[⚠️] [$DEV_ID] SKIPPED: Wi-Fi IP subnet ($SUBNET_IDX) has no active matching modem. (SSID: $SSID)"
            continue
        fi

        # --- Cooldown & Penalty Skip Check ---
        CURRENT_TIME=$(date +%s)
        
        # [NEW] 로컬 current_task.json이 리셋되었거나(IDLE/READY) 존재하지 않으면 메모리 쿨다운 강제 해제하여 즉시 할당 유도
        TASK_JSON="logs/${DEV_ID}/current_task.json"
        is_reset=false
        if [ ! -f "$TASK_JSON" ]; then
            is_reset=true
        else
            T_STATUS=$(jq -r '.status // empty' "$TASK_JSON" 2>/dev/null)
            if [ "$T_STATUS" = "IDLE" ] || [ "$T_STATUS" = "READY" ]; then
                is_reset=true
            fi
        fi
        
        if [ "$is_reset" = true ]; then
            DEV_EXCLUDE_UNTIL[$DEV_ID]=0
        fi

        EXCLUDE_UNTIL=${DEV_EXCLUDE_UNTIL[$DEV_ID]}
        if [ -n "$EXCLUDE_UNTIL" ] && [ "$CURRENT_TIME" -lt "$EXCLUDE_UNTIL" ]; then
            # Silent skip, no heavy polling
            continue
        fi

        RESPONSE=$(curl -s -X POST "http://$API_SERVER/api/v1/request_task" \
             -H "Content-Type: application/json" \
             -d "{\"device_id\":\"$DEV_ID\"}")
        
        if [ -z "$RESPONSE" ]; then
            # Temporary server/network error, wait 10s before retry
            DEV_EXCLUDE_UNTIL[$DEV_ID]=$((CURRENT_TIME + 10))
            continue
        fi

        STATUS=$(echo "$RESPONSE" | jq -r '.status')
        if [ "$STATUS" != "ok" ]; then
            MSG=$(echo "$RESPONSE" | jq -r '.msg')
            CURRENT_TIME=$(date +%s)
            
            mkdir -p "logs/${DEV_ID}"
            if [ "$MSG" = "COOLDOWN_ACTIVE" ]; then
                DEV_EXCLUDE_UNTIL[$DEV_ID]=$((CURRENT_TIME + 60))
                echo "[COOLDOWN] [$DEV_ID] Cooldown active. Excluding for 60 seconds."
                echo "{\"status\": \"COOLDOWN\", \"exclude_until\": ${DEV_EXCLUDE_UNTIL[$DEV_ID]}}" > "logs/${DEV_ID}/current_task.json"
            elif [ "$MSG" = "PENALTY_ACTIVE" ]; then
                DEV_EXCLUDE_UNTIL[$DEV_ID]=$((CURRENT_TIME + 600))
                echo "[🚨] [$DEV_ID] Penalty active (60+ fails). Excluding for 10 minutes."
                echo "{\"status\": \"PENALTY\", \"exclude_until\": ${DEV_EXCLUDE_UNTIL[$DEV_ID]}}" > "logs/${DEV_ID}/current_task.json"
            elif [ "$MSG" = "UNAUTHORIZED_DEVICE" ]; then
                DEV_EXCLUDE_UNTIL[$DEV_ID]=$((CURRENT_TIME + 300))
                echo "[⚠️] [$DEV_ID] Unauthorized device. Excluding for 5 minutes."
                echo "{\"status\": \"UNAUTHORIZED\", \"exclude_until\": ${DEV_EXCLUDE_UNTIL[$DEV_ID]}}" > "logs/${DEV_ID}/current_task.json"
            elif [ "$MSG" = "NO_TASK_AVAILABLE" ]; then
                # Temporary no tasks, fast polling but slight delay to prevent CPU spam
                DEV_EXCLUDE_UNTIL[$DEV_ID]=$((CURRENT_TIME + 10))
                echo "{\"status\": \"IDLE\"}" > "logs/${DEV_ID}/current_task.json"
            else
                DEV_EXCLUDE_UNTIL[$DEV_ID]=$((CURRENT_TIME + 10))
                echo "{\"status\": \"IDLE\"}" > "logs/${DEV_ID}/current_task.json"
            fi
            continue
        fi

        TASK_ID=$(echo "$RESPONSE" | jq -r '.task_id')
        DEST_NAME=$(echo "$RESPONSE" | jq -r '.destination.target_name')
        DEVICE_SEQ=$(echo "$RESPONSE" | jq -r '.device_seq')

        # =================================================================================
        # [포트 할당 설계 원칙 - 절대 수정 및 롤백 금지]
        # - device_seq는 DB 서버에서 각 device_id에 1:1로 할당되어 절대 변하지 않는 고유 Sequence ID입니다.
        # - FRIDA_PORT = 10000 + device_seq
        # - MITM_PORT = 20000 + device_seq
        # - 이 정적 매핑 방식은 전체 인프라(수십 대의 PC, 수백 대의 폰)에서 포트 충돌 가능성이 0%입니다.
        # - 이전의 cksum 해시 방식(6000 + cksum % 1000)은 해시 충돌(예: R3CR70M3FZH와 R3CRB0ETRZJ 충돌)로 인해
        #   서로의 프로세스를 강제 종료(pkill)시키는 무한 재시작 루프가 발생하였으므로 절대 롤백하지 마십시오.
        # =================================================================================
        FRIDA_PORT=$((10000 + DEVICE_SEQ))
        
        echo "[🚀] [$DEV_ID] ALLOCATED: $DEST_NAME (Task:$TASK_ID) -> Modem lte$MODEM_IDX ($BIND_IP)"

        # Ensure log directory exists before redirecting output
        mkdir -p "logs/${DEV_ID}/tmp"

        # Pre-create current_task.json with basic metadata to prevent N/A screens before verification
        # device_seq도 함께 기록하여 stale_cleaner가 포트를 올바르게 복원하도록 합니다.
        echo "{\"status\": \"ALLOCATED\", \"device_seq\": $DEVICE_SEQ, \"dest_name\": \"$DEST_NAME\", \"dest_id\": \"$(echo "$RESPONSE" | jq -r '.destination.id')\", \"real_ip\": \"$BIND_IP\"}" > "logs/${DEV_ID}/current_task.json"

        # [Security Warning] NMAP_ORIG_TOKEN and NMAP_ID_TOKEN are crucial for identity washing.
        # Ensure these are passed properly to prevent raw tracking token leaks.
        NMAP_BIND_IP="$BIND_IP" \
        NMAP_API_RESPONSE="$RESPONSE" \
        NMAP_TASK_ID="$TASK_ID" \
        NMAP_LOG_ID="$TASK_ID" \
        NMAP_DEST_ID=$(echo "$RESPONSE" | jq -r '.destination.id') \
        NMAP_DEST_LAT=$(echo "$RESPONSE" | jq -r '.destination.lat') \
        NMAP_DEST_LNG=$(echo "$RESPONSE" | jq -r '.destination.lng') \
        NMAP_DEST_NAME="$DEST_NAME" \
        NMAP_DEST_ADDR="$(echo "$RESPONSE" | jq -r '.destination.address' | sed "s/\"/\\\"/g")" \
        NMAP_START_LAT=$(echo "$RESPONSE" | jq -r '.start_pos.lat') \
        NMAP_START_LNG=$(echo "$RESPONSE" | jq -r '.start_pos.lng') \
        NMAP_START_SPEED=$(echo "$RESPONSE" | jq -r '.start_pos.speed_kmh') \
        NMAP_ARRIVAL_TIME=$(echo "$RESPONSE" | jq -r '.arrival_time') \
        NMAP_FRIDA_PORT="$FRIDA_PORT" \
        NMAP_ORIG_SSAID=$(echo "$RESPONSE" | jq -r '.identity.original.ssaid') \
        NMAP_ORIG_ADID=$(echo "$RESPONSE" | jq -r '.identity.original.adid') \
        NMAP_ORIG_IDFV=$(echo "$RESPONSE" | jq -r '.identity.original.idfv') \
        NMAP_ORIG_NI=$(echo "$RESPONSE" | jq -r '.identity.original.ni') \
        NMAP_ORIG_TOKEN=$(echo "$RESPONSE" | jq -r '.identity.original.token') \
        NMAP_ID_ADID=$(echo "$RESPONSE" | jq -r '.identity.spoofed.adid') \
        NMAP_ID_SSAID=$(echo "$RESPONSE" | jq -r '.identity.spoofed.ssaid') \
        NMAP_ID_IDFV=$(echo "$RESPONSE" | jq -r '.identity.spoofed.idfv') \
        NMAP_ID_NI=$(echo "$RESPONSE" | jq -r '.identity.spoofed.ni') \
        NMAP_ID_TOKEN=$(echo "$RESPONSE" | jq -r '.identity.spoofed.token') \
        setsid bash "$WIFI_MULTI_LIB/main.sh" "$DEV_ID" > "logs/${DEV_ID}/tmp/main_debug.log" 2>&1 &
        
        DEV_INDEX=$((DEV_INDEX + 1))
        sleep 2
    done
    sleep 20
done
