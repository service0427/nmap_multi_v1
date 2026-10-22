#!/bin/bash

TECH_USER="tech"
TECH_ANDROID_DIR="/home/$TECH_USER/.android"
ROOT_ANDROID_DIR="/root/.android"

echo "============================================================"
echo " Starting ADB Key Synchronization & Device Persistence Pin  "
echo "============================================================"

# 1. Sync tech user's keys to root account and install /usr/bin/adb wrapper
if [ -f "$TECH_ANDROID_DIR/adbkey" ] && [ -f "$TECH_ANDROID_DIR/adbkey.pub" ]; then
    echo "[*] Synchronizing ADB keys from $TECH_USER to root account..."
    sudo -n sh -c "
        mkdir -p '$ROOT_ANDROID_DIR'
        cp '$TECH_ANDROID_DIR/adbkey' '$ROOT_ANDROID_DIR/adbkey'
        cp '$TECH_ANDROID_DIR/adbkey.pub' '$ROOT_ANDROID_DIR/adbkey.pub'
        chmod 600 '$ROOT_ANDROID_DIR/adbkey'
        chmod 644 '$ROOT_ANDROID_DIR/adbkey.pub'
        if [ -x '/usr/lib/android-sdk/platform-tools/adb' ] && ! grep -q 'runuser -u tech' /usr/bin/adb 2>/dev/null; then
            rm -f /usr/bin/adb
            cat << 'WRAP_EOF' > /usr/bin/adb
#!/bin/sh
if [ \"\$(id -u)\" -eq 0 ] && id -u tech >/dev/null 2>&1; then
    exec runuser -u tech -- env HOME=/home/tech /usr/lib/android-sdk/platform-tools/adb \"\$@\"
fi
export HOME=\"/home/tech\"
exec /usr/lib/android-sdk/platform-tools/adb \"\$@\"
WRAP_EOF
            chmod 755 /usr/bin/adb
        fi
    " 2>/dev/null || true
    echo "[✓] ADB keys synchronized & /usr/bin/adb tech wrapper verified."
else
    echo "[⚠️] Warning: Tech user's ADB keys not found at $TECH_ANDROID_DIR."
fi

if [ "$(id -u)" -eq 0 ] && id -u tech >/dev/null 2>&1; then
    exec sudo -H -u tech HOME=/home/tech "$0" "$@"
fi
export HOME="/home/tech"

# 2. Get list of attached devices
DEVICES=$(adb devices | grep -w "device" | awk '{print $1}')
if [ -z "$DEVICES" ]; then
    echo "[⚠️] No active devices detected via ADB. Exiting."
    exit 0
fi

PUB_CONTENT=$(cat "$TECH_ANDROID_DIR/adbkey.pub" 2>/dev/null | tr -d '\r\n')
KEY_BODY=$(awk '{print $1}' "$TECH_ANDROID_DIR/adbkey.pub" 2>/dev/null)
CUR_HOST=$(hostname 2>/dev/null | tr -d '\r\n')
[ -z "$CUR_HOST" ] && CUR_HOST="localhost"
KEY_TECH="${KEY_BODY} tech@${CUR_HOST}"
KEY_ROOT="${KEY_BODY} root@${CUR_HOST}"

echo "[*] Found $(echo "$DEVICES" | wc -w) devices. Pinning keys..."

for dev in $DEVICES; do
    echo "  -> Pinning shared public keys on $dev..."
    adb -s "$dev" shell "settings put global adb_allowed_connection_time 0" >/dev/null 2>&1
    adb -s "$dev" shell "su -c '
        setprop persist.sys.usb.config adb 2>/dev/null
        mkdir -p /data/misc/adb
        touch /data/misc/adb/adb_keys
        for k in \"$KEY_TECH\" \"$KEY_ROOT\" \"$PUB_CONTENT\"; do
            if [ -n \"\$k\" ] && ! grep -qxF \"\$k\" /data/misc/adb/adb_keys 2>/dev/null; then
                echo \"\$k\" >> /data/misc/adb/adb_keys
            fi
        done
        chown system:shell /data/misc/adb /data/misc/adb/adb_keys
        chmod 2750 /data/misc/adb
        chmod 640 /data/misc/adb/adb_keys
        restorecon -R /data/misc/adb 2>/dev/null || chcon u:object_r:adb_keys_file:s0 /data/misc/adb/adb_keys 2>/dev/null || true
    '" >/dev/null 2>&1
    echo "  [✓] Device $dev keys pinned."
done

echo "============================================================"
echo " Key pinning complete on all connected devices."
echo "============================================================"
