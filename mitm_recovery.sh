#!/usr/bin/env bash

# ==============================================================================
# mitm_recovery.sh (Mitmproxy Certificate Recovery & Fix Script)
# ==============================================================================
# [스크립트 설명]
# 기기를 다른 서버로 옮겼을 때, 이전 서버의 인증서(해시가 같고 크기가 다른 경우 등)가 
# Magisk 모듈에 캐싱되어 패킷 캡처가 안 되는(TLS Handshake Failed) 현상을 완벽 복구합니다.
#
# [근본적 원인]
# Magisk의 'trustusercerts' (또는 AlwaysTrustUserCerts) 모듈은 부팅 시 스크립트(post-fs-data.sh)를 통해 
# 유저 인증서를 시스템 영역에 강제 마운트합니다. 하지만 기존 스크립트는 
# 1) 유저 인증서 복사 -> 2) 물리적 시스템 인증서 복사 순서로 되어 있어, 
# 만약 물리적 시스템 영역(/system)에 과거 인증서가 영구적으로 남아있다면 
# 방금 주입한 새 인증서를 덮어씌워 버리는(우선순위 역전) 치명적인 버그가 있습니다.
#
# [해결 스크립트 동작]
# 1. 타겟 기기의 'post-fs-data.sh' 스크립트의 인증서 복사 순서를 교정 (시스템 먼저 -> 유저 나중에)
# 2. 현재 활성화된 Magisk 인증서 캐시와 유저 인증서를 전부 Wipe (초기화)
# 3. 현재 서버의 올바른 mitmproxy 인증서를 다시 주입
# 4. 기기 자동 재부팅을 통한 마운트 트리거
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_PATH="/home/tech/.mitmproxy/mitmproxy-ca-cert.pem"

# [V2.0] 최초 실행 시 mitmproxy 인증서 자동 생성 자동화
if [ ! -f "$CERT_PATH" ]; then
    echo "[*] mitmproxy 인증서를 찾을 수 없습니다. 자동 생성을 시도합니다..."
    if command -v mitmdump >/dev/null 2>&1; then
        # mitmdump를 백그라운드에서 실행하고 2초 후 종료하여 인증서를 생성합니다.
        mitmdump &
        MITM_PID=$!
        sleep 2
        kill $MITM_PID 2>/dev/null
        # 인증서 생성 여부 재확인
        if [ -f "$CERT_PATH" ]; then
            echo "  -> mitmproxy 인증서 자동 생성 완료: $CERT_PATH"
        fi
    else
        echo "[-] mitmdump 명령어를 찾을 수 없어 인증서를 자동 생성할 수 없습니다."
    fi
fi

# 인증서 해시 추출
CERT_HASH=""
if [ -f "$CERT_PATH" ]; then
    CERT_HASH=$(openssl x509 -inform PEM -subject_hash_old -in "$CERT_PATH" 2>/dev/null | head -1)
else
    echo "[-] 서버에 mitmproxy 인증서를 찾을 수 없습니다: $CERT_PATH"
    exit 1
fi

TARGET_DEVICE=$1

if [ -z "$TARGET_DEVICE" ]; then
    echo "[*] 대상 기기가 지정되지 않았습니다. 연결된 전체 기기를 대상으로 복구를 시작합니다."
    DEVICES=$(adb devices | grep -w "device" | awk '{print $1}')
else
    echo "[*] 단일 기기 복구를 시작합니다: $TARGET_DEVICE"
    DEVICES=$TARGET_DEVICE
fi

if [ -z "$DEVICES" ]; then
    echo "[-] 연결된 기기가 없습니다."
    exit 1
fi

for serial in $DEVICES; do
    echo "=================================================="
    echo "🚀 [$serial] Mitmproxy 인증서 복구 및 Magisk 스크립트 교정 시작..."
    
    HAS_SU=$(adb -s "$serial" shell "which su" 2>/dev/null | tr -d '\r')
    if [ -z "$HAS_SU" ]; then
        echo "[$serial] [!] 'su' 명령어를 찾을 수 없습니다. 루팅(Magisk) 환경이 아닙니다."
        continue
    fi

    # [인증서 일치 여부 사전 검증 - PASS 최적화]
    SERVER_MD5=$(md5sum "$CERT_PATH" | awk '{print $1}')
    USER_MD5=$(adb -s "$serial" shell "$HAS_SU -c 'md5sum /data/misc/user/0/cacerts-added/$CERT_HASH.0 2>/dev/null'" | tr -d '\r' | awk '{print $1}')
    
    HAS_MAGISK_DIR=$(adb -s "$serial" shell "$HAS_SU -c '[ -d /data/adb/modules/trustusercerts/system/etc/security/cacerts ] && echo yes || echo no'" | tr -d '\r')
    if [ "$HAS_MAGISK_DIR" = "yes" ]; then
        MAGISK_MD5=$(adb -s "$serial" shell "$HAS_SU -c 'md5sum /data/adb/modules/trustusercerts/system/etc/security/cacerts/$CERT_HASH.0 2>/dev/null'" | tr -d '\r' | awk '{print $1}')
    else
        MAGISK_MD5="MISSING"
    fi

    echo "[$serial] 인증서 대조: Server=$SERVER_MD5 | PhoneUser=$USER_MD5 | Magisk=$MAGISK_MD5"
    
    if [ -n "$SERVER_MD5" ] && [ "$SERVER_MD5" = "$USER_MD5" ] && [ "$SERVER_MD5" = "$MAGISK_MD5" ]; then
        echo "[$serial] [✓] 인증서가 이미 최신 상태이며 서버와 완전히 일치합니다. 복구를 생략하고 [PASS] 합니다."
        echo "=================================================="
        continue
    fi

    # 1. Magisk 모듈 post-fs-data.sh 복사 순서 교정 스크립트 작성
    cat << 'EOF' > /tmp/fix_script_$serial.sh
#!/system/bin/sh
MOD_SCRIPT="/data/adb/modules/trustusercerts/post-fs-data.sh"

if [ -f "$MOD_SCRIPT" ]; then
    echo "[*] trustusercerts 모듈 스크립트를 교정합니다..."
    
    # 올바른 순서의 스크립트로 덮어쓰기
    cat << 'INNER_EOF' > $MOD_SCRIPT
# Certificates are collected during post-fs-data so that they are auto-mounted on top of /system for non-conscrypt devices
MODDIR=${0%/*}
SYS_CERT_DIR=/system/etc/security/cacerts

log() {
    echo "$(date '+%m-%d %H:%M:%S ')" "$@" >> $MODDIR/log.txt
}

collect_user_certs(){
    mkdir -p $MODDIR$SYS_CERT_DIR

    # Clean directory so that deleted certs actually disappear
    rm -rf $MODDIR$SYS_CERT_DIR/*

    # [교정됨] 시스템 인증서를 먼저 복사
    log "Grabbing /system certs"
    cp -f $SYS_CERT_DIR/* $MODDIR$SYS_CERT_DIR/ 2>/dev/null || true

    # [교정됨] 유저 인증서를 나중에 복사하여 시스템 인증서를 강제 덮어쓰기 (우선권 부여)
    log "Grabbing user certs"
    for dir in /data/misc/user/*; do
        if [ -d "$dir/cacerts-added" ]; then
            for cert in "$dir/cacerts-added"/*; do
                cp -f "$cert" $MODDIR$SYS_CERT_DIR/
                log "Grabbing user cert: $(basename "$cert")"
            done
        fi
    done
}

main(){
    echo "" > $MODDIR/log.txt
    log "MagiskTrustUserCerts - post-fs-data.sh"
    collect_user_certs
}
main
INNER_EOF

    chmod 755 $MOD_SCRIPT
    echo "[*] 스크립트 교정 완료."
else
    echo "[*] trustusercerts 모듈을 찾을 수 없습니다. 무시하고 진행합니다."
fi
EOF

    # 2. 기기 내 이전 인증서 강제 Wipe 스크립트 작성
    cat << EOF2 > /tmp/wipe_cert_$serial.sh
#!/system/bin/sh
CERT_FILE="$CERT_HASH.0"

echo "[*] 기존 유저 및 Magisk 캐시 인증서를 삭제합니다..."
rm -f /data/misc/user/0/cacerts-added/*
rm -f /data/adb/modules/trustusercerts/system/etc/security/cacerts/\$CERT_FILE
EOF2

    # 스크립트 기기로 푸시 후 실행
    adb -s "$serial" push /tmp/fix_script_$serial.sh /data/local/tmp/fix_script.sh >/dev/null 2>&1
    adb -s "$serial" push /tmp/wipe_cert_$serial.sh /data/local/tmp/wipe_cert.sh >/dev/null 2>&1
    
    adb -s "$serial" shell "$HAS_SU -c 'sh /data/local/tmp/fix_script.sh'"
    adb -s "$serial" shell "$HAS_SU -c 'sh /data/local/tmp/wipe_cert.sh'"
    
    adb -s "$serial" shell "rm -f /data/local/tmp/fix_script.sh /data/local/tmp/wipe_cert.sh"
    rm -f /tmp/fix_script_$serial.sh /tmp/wipe_cert_$serial.sh

    # 3. 새로운 인증서 주입 (install_devices.sh 로직 재사용)
    echo "[$serial] 현재 서버의 올바른 인증서 주입 중..."
    adb -s "$serial" push "$CERT_PATH" "/data/local/tmp/$CERT_HASH.0" >/dev/null 2>&1
    
    cat << 'EOF3' > /tmp/cert_inject_$serial.sh
CERT_FILE=$1
mkdir -p /data/misc/user/0/cacerts-added
cp /data/local/tmp/$CERT_FILE /data/misc/user/0/cacerts-added/$CERT_FILE
chown system:system /data/misc/user/0/cacerts-added/$CERT_FILE
chmod 644 /data/misc/user/0/cacerts-added/$CERT_FILE

if [ -d "/data/adb/modules/trustusercerts/system/etc/security/cacerts" ]; then
    cp /data/local/tmp/$CERT_FILE /data/adb/modules/trustusercerts/system/etc/security/cacerts/$CERT_FILE
    chown root:root /data/adb/modules/trustusercerts/system/etc/security/cacerts/$CERT_FILE
    chmod 644 /data/adb/modules/trustusercerts/system/etc/security/cacerts/$CERT_FILE
    chcon u:object_r:system_security_cacerts_file:s0 /data/adb/modules/trustusercerts/system/etc/security/cacerts/$CERT_FILE 2>/dev/null
fi

rm -f /data/local/tmp/$CERT_FILE
EOF3

    adb -s "$serial" push /tmp/cert_inject_$serial.sh /data/local/tmp/cert_inject.sh >/dev/null 2>&1
    adb -s "$serial" shell "$HAS_SU -c 'sh /data/local/tmp/cert_inject.sh $CERT_HASH.0'"
    adb -s "$serial" shell "rm -f /data/local/tmp/cert_inject.sh"
    rm -f /tmp/cert_inject_$serial.sh

    # 4. 재부팅 트리거
    echo "[$serial] 복구가 완료되었습니다. 새로운 마운트 적용을 위해 재부팅합니다..."
    adb -s "$serial" reboot
    echo "=================================================="

done

echo "[*] 모든 작업이 종료되었습니다. 기기가 켜지면 pm2를 시작해주세요."
