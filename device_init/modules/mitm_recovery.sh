#!/usr/bin/env bash

# ============================================================
# MITM Certificate Recovery & Fix Module
# ============================================================

init_mitm_recovery() {
    local serial=$1
    local has_su=$2
    local force_reboot=$3  # "true" or "false"
    local YELLOW="\e[1;33m"
    local GREEN="\e[1;32m"
    local NC="\e[0m"

    local CERT_PATH="/home/tech/.mitmproxy/mitmproxy-ca-cert.pem"

    # 1. Ensure mitmproxy cert exists on the host
    if [ ! -f "$CERT_PATH" ]; then
        echo -e "    - mitmproxy certificate not found. Attempting generation..."
        if command -v mitmdump >/dev/null 2>&1; then
            mitmdump &
            local mitm_pid=$!
            sleep 2
            kill $mitm_pid 2>/dev/null
        fi
    fi

    if [ ! -f "$CERT_PATH" ]; then
        echo -e "    [!] Error: mitmproxy certificate not found on host: $CERT_PATH"
        return 1
    fi

    # Extract hash
    local cert_hash=$(openssl x509 -inform PEM -subject_hash_old -in "$CERT_PATH" 2>/dev/null | head -1)
    if [ -z "$cert_hash" ]; then
        echo -e "    [!] Error: Failed to extract old hash from certificate."
        return 1
    fi

    echo -e "\n[*] Running MITM certificate recovery & script validation..."

    # 2. Hash and script check for skip condition
    local host_md5=$(md5sum "$CERT_PATH" 2>/dev/null | awk '{print $1}')
    local user_cert_path="/data/misc/user/0/cacerts-added/$cert_hash.0"
    local user_md5=$(adb -s "$serial" shell "$has_su -c 'md5sum $user_cert_path'" 2>/dev/null | awk '{print $1}')

    local module_dir_exists=$(adb -s "$serial" shell "$has_su -c '[ -d /data/adb/modules/trustusercerts ] && echo YES || echo NO'" 2>/dev/null | tr -d '\r')
    local module_cert_match=true
    local script_correct=true

    if [ "$module_dir_exists" = "YES" ]; then
        local module_cert_path="/data/adb/modules/trustusercerts/system/etc/security/cacerts/$cert_hash.0"
        local module_md5=$(adb -s "$serial" shell "$has_su -c 'md5sum $module_cert_path'" 2>/dev/null | awk '{print $1}')
        if [ "$module_md5" != "$host_md5" ]; then
            module_cert_match=false
        fi

        local active_script="/data/adb/modules/trustusercerts/post-fs-data.sh"
        local check_active=$(adb -s "$serial" shell "$has_su -c \"[ -f $active_script ] && (grep -q 'SELinux' $active_script && echo 1 || echo 0) || echo 0\"" 2>/dev/null | tr -d '\r')
        if [ "$check_active" = "0" ] || [ -z "$check_active" ]; then
            script_correct=false
        fi
    else
        # Both module dirs are missing. We cannot recover if module is completely missing.
        local update_dir_exists=$(adb -s "$serial" shell "$has_su -c '[ -d /data/adb/modules_update/trustusercerts ] && echo YES || echo NO'" 2>/dev/null | tr -d '\r')
        if [ "$update_dir_exists" = "NO" ]; then
            script_correct=false
        fi
    fi

    local update_dir_exists=$(adb -s "$serial" shell "$has_su -c '[ -d /data/adb/modules_update/trustusercerts ] && echo YES || echo NO'" 2>/dev/null | tr -d '\r')
    if [ "$update_dir_exists" = "YES" ]; then
        local update_script="/data/adb/modules_update/trustusercerts/post-fs-data.sh"
        local check_update=$(adb -s "$serial" shell "$has_su -c \"[ -f $update_script ] && (grep -q 'SELinux' $update_script && echo 1 || echo 0) || echo 0\"" 2>/dev/null | tr -d '\r')
        if [ "$check_update" = "0" ] || [ -z "$check_update" ]; then
            script_correct=false
        fi
    fi

    # If everything is matching, not forced, and script is correct, skip reboot.
    if [ "$force_reboot" = "false" ] && [ "$user_md5" = "$host_md5" ] && [ "$module_cert_match" = true ] && [ "$script_correct" = true ]; then
        echo -e "    [✓] MITM certificate and Magisk post-fs script are already up to date. Skipping recovery & reboot."
        return 0
    fi

    # 3. Write correction script and wipe certificates
    echo -e "    - Recovering/injecting certificate and correcting script..."
    
    local SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local HOST_TMP="$(cd "$SCRIPT_DIR/.." && pwd)/tmp"
    mkdir -p "$HOST_TMP"
    
    # 3.1 Correcting post-fs-data.sh
    cat << 'EOF' > "$HOST_TMP/fix_script_$serial.sh"
#!/system/bin/sh
MOD_SCRIPT_ACTIVE="/data/adb/modules/trustusercerts/post-fs-data.sh"
MOD_SCRIPT_UPDATE="/data/adb/modules_update/trustusercerts/post-fs-data.sh"
MODIFIED_ANY=false

write_corrected_script() {
    local target=$1
    echo "Correcting trustusercerts script: $target"
    cat << 'INNER_EOF' > "$target"
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

    # [교정됨] 복사된 모든 인증서의 SELinux 컨텍스트를 올바르게 지정
    chcon -R u:object_r:system_security_cacerts_file:s0 $MODDIR$SYS_CERT_DIR 2>/dev/null || true
}

main(){
    echo "" > $MODDIR/log.txt
    log "MagiskTrustUserCerts - post-fs-data.sh"
    collect_user_certs
}
main
INNER_EOF
    chmod 755 "$target"
}

if [ -f "$MOD_SCRIPT_ACTIVE" ]; then
    write_corrected_script "$MOD_SCRIPT_ACTIVE"
    MODIFIED_ANY=true
fi

if [ -f "$MOD_SCRIPT_UPDATE" ]; then
    write_corrected_script "$MOD_SCRIPT_UPDATE"
    MODIFIED_ANY=true
fi

if [ "$MODIFIED_ANY" = "true" ]; then
    echo "post-fs-data.sh script corrected successfully."
else
    echo "No trustusercerts active or update script found. Skipping script correction."
fi
EOF

    # 3.2 Wipe certificate cache
    cat << EOF2 > "$HOST_TMP/wipe_cert_$serial.sh"
#!/system/bin/sh
CERT_FILE="$cert_hash.0"
echo "Wiping user and module cert caches..."
rm -f /data/misc/user/0/cacerts-added/*
rm -f /data/adb/modules/trustusercerts/system/etc/security/cacerts/\$CERT_FILE
EOF2

    # Push and execute scripts
    adb -s "$serial" push "$HOST_TMP/fix_script_$serial.sh" /data/local/tmp/fix_script.sh >/dev/null 2>&1
    adb -s "$serial" push "$HOST_TMP/wipe_cert_$serial.sh" /data/local/tmp/wipe_cert.sh >/dev/null 2>&1

    adb -s "$serial" shell "$has_su -c 'sh /data/local/tmp/fix_script.sh'" >/dev/null 2>&1
    adb -s "$serial" shell "$has_su -c 'sh /data/local/tmp/wipe_cert.sh'" >/dev/null 2>&1

    adb -s "$serial" shell "rm -f /data/local/tmp/fix_script.sh /data/local/tmp/wipe_cert.sh"
    rm -f "$HOST_TMP/fix_script_$serial.sh" "$HOST_TMP/wipe_cert_$serial.sh"

    # 3.3 Certificate Injection
    adb -s "$serial" push "$CERT_PATH" "/data/local/tmp/$cert_hash.0" >/dev/null 2>&1
    cat << 'EOF3' > "$HOST_TMP/cert_inject_$serial.sh"
CERT_FILE=$1
mkdir -p /data/misc/user/0/cacerts-added
cp /data/local/tmp/$CERT_FILE /data/misc/user/0/cacerts-added/$CERT_FILE
chown system:system /data/misc/user/0/cacerts-added/$CERT_FILE
chmod 644 /data/misc/user/0/cacerts-added/$CERT_FILE

inject_module_cert() {
    local mod_dir=$1
    if [ -d "$mod_dir" ]; then
        mkdir -p "$mod_dir/system/etc/security/cacerts"
        cp /data/local/tmp/$CERT_FILE "$mod_dir/system/etc/security/cacerts/$CERT_FILE"
        chown root:root "$mod_dir/system/etc/security/cacerts/$CERT_FILE"
        chmod 644 "$mod_dir/system/etc/security/cacerts/$CERT_FILE"
        chcon u:object_r:system_security_cacerts_file:s0 "$mod_dir/system/etc/security/cacerts/$CERT_FILE" 2>/dev/null
    fi
}

inject_module_cert "/data/adb/modules/trustusercerts"
inject_module_cert "/data/adb/modules_update/trustusercerts"

rm -f /data/local/tmp/$CERT_FILE
EOF3

    adb -s "$serial" push "$HOST_TMP/cert_inject_$serial.sh" /data/local/tmp/cert_inject.sh >/dev/null 2>&1
    adb -s "$serial" shell "$has_su -c 'sh /data/local/tmp/cert_inject.sh $cert_hash.0'" >/dev/null 2>&1
    adb -s "$serial" shell "rm -f /data/local/tmp/cert_inject.sh"
    rm -f "$HOST_TMP/cert_inject_$serial.sh"

    # 4. Reboot Device
    echo -e "    - Recovery complete. Rebooting device to apply system cert mounting..."
    adb -s "$serial" reboot
    adb -s "$serial" wait-for-device
    echo -e "    [✓] Device is back online."
}
