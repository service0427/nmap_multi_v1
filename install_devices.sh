#!/usr/bin/env bash

# Base installation path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$SCRIPT_DIR/install"
CERT_PATH="/home/tech/.mitmproxy/mitmproxy-ca-cert.pem"

# Define packages and their files
APPS=(
    "com.nhn.android.nmap:1:$INSTALL_DIR/com.nhn.android.nmap_6.6.1/base.apk $INSTALL_DIR/com.nhn.android.nmap_6.6.1/split_config.arm64_v8a.apk $INSTALL_DIR/com.nhn.android.nmap_6.6.1/split_config.xxhdpi.apk"
    "com.rosteam.gpsemulator:1:$INSTALL_DIR/gpsemulator/base.apk $INSTALL_DIR/gpsemulator/split_config.arm64_v8a.apk $INSTALL_DIR/gpsemulator/split_config.ko.apk $INSTALL_DIR/gpsemulator/split_config.xxhdpi.apk"
    "com.android.adbkeyboard:0:$INSTALL_DIR/ADBKeyboard.apk"
)

# Extract Certificate Hash
CERT_HASH=""
if [ -f "$CERT_PATH" ]; then
    CERT_HASH=$(openssl x509 -inform PEM -subject_hash_old -in "$CERT_PATH" 2>/dev/null | head -1)
fi

# Download Static Curl if not exists
CURL_BIN="$INSTALL_DIR/curl-aarch64"
if [ ! -f "$CURL_BIN" ]; then
    echo "[*] Downloading statically compiled curl for aarch64..."
    mkdir -p "$INSTALL_DIR"
    curl -sL "https://github.com/moparisthebest/static-curl/releases/latest/download/curl-aarch64" -o "$CURL_BIN"
    chmod +x "$CURL_BIN"
fi

# Get target device from argument (optional)
TARGET_DEVICE=$1

# Get connected devices
if [ -z "$TARGET_DEVICE" ]; then
    echo "[*] No target device specified. Checking all connected devices..."
    DEVICES=$(adb devices | grep -w "device" | awk '{print $1}')
else
    echo "[*] Targeting specific device: $TARGET_DEVICE"
    DEVICES=$TARGET_DEVICE
fi

if [ -z "$DEVICES" ]; then
    echo "No devices connected."
    exit 1
fi

for serial in $DEVICES; do
    echo "--------------------------------------------------"
    echo "Checking device: $serial"
    
    # 0. Root Check
    HAS_SU=$(adb -s "$serial" shell "which su" 2>/dev/null | tr -d '\r')
    if [ -z "$HAS_SU" ]; then
        HAS_SU=$(adb -s "$serial" shell "ls /system/bin/su /system/xbin/su /sbin/su 2>/dev/null" | head -1 | tr -d '\r')
    fi

    if [ -z "$HAS_SU" ]; then
        echo "[$serial] [!] 'su' command not found. Root actions will fail."
    else
        echo "[$serial] [✓] Found 'su' at: $HAS_SU"
    fi

    # 0.5. Curl Check & Installation
    HAS_CURL=$(adb -s "$serial" shell "which curl" 2>/dev/null | tr -d '\r')
    if [ -z "$HAS_CURL" ]; then
        if [ -n "$HAS_SU" ]; then
            echo "[$serial] 'curl' not found. Installing static curl..."
            adb -s "$serial" push "$CURL_BIN" /data/local/tmp/curl >/dev/null 2>&1
            adb -s "$serial" shell "$HAS_SU -c 'mount -o rw,remount / 2>/dev/null || mount -o rw,remount /system 2>/dev/null'"
            adb -s "$serial" shell "$HAS_SU -c 'cp /data/local/tmp/curl /system/bin/curl 2>/dev/null || cp /data/local/tmp/curl /system/xbin/curl 2>/dev/null'"
            adb -s "$serial" shell "$HAS_SU -c 'chmod 755 /system/bin/curl 2>/dev/null || chmod 755 /system/xbin/curl 2>/dev/null'"
            adb -s "$serial" shell "$HAS_SU -c 'rm -f /data/local/tmp/curl'"
            echo "[$serial] [✓] 'curl' installed successfully."
        else
            echo "[$serial] [!] 'curl' not found, but no root. Cannot install."
        fi
    else
        echo "[$serial] [✓] Found 'curl' at: $HAS_CURL"
    fi

    # 1. App Installation with Pass Logic
    INSTALLED_PACKAGES=$(adb -s "$serial" shell pm list packages | cut -d':' -f2)
    for app in "${APPS[@]}"; do
        IFS=':' read -r pkg type files <<< "$app"
        if echo "$INSTALLED_PACKAGES" | grep -qx "$pkg"; then
            echo "[$serial] $pkg is already installed. Skipping."
        else
            echo "[$serial] $pkg not found. Installing..."
            if [ "$type" -eq "0" ]; then
                adb -s "$serial" install $files
            else
                adb -s "$serial" install-multiple $files
            fi
            [ $? -eq 0 ] && echo "[$serial] $pkg installed successfully." || echo "[$serial] Failed to install $pkg."
        fi
    done

    # 2. Magisk Modules Pass Logic
    echo "[$serial] Checking Magisk modules..."
    if [ -d "$INSTALL_DIR/Magisk_Module" ]; then
        NEED_PUSH=false
        for f in "$INSTALL_DIR/Magisk_Module"/*.zip; do
            [ -e "$f" ] || continue
            fname=$(basename "$f")
            if ! adb -s "$serial" shell "[ -f /sdcard/Download/$fname ]" >/dev/null 2>&1; then
                NEED_PUSH=true; break
            fi
        done
        if [ "$NEED_PUSH" = true ]; then
            echo "[$serial] Pushing Magisk modules to /sdcard/Download..."
            adb -s "$serial" push "$INSTALL_DIR/Magisk_Module/." /sdcard/Download/
        else
            echo "[$serial] Magisk modules already exist or no modules found. Skipping."
        fi
    fi

    # 3. ROOT Certificate Injection
    if [ -n "$CERT_HASH" ] && [ -n "$HAS_SU" ]; then
        echo "[$serial] Injecting/Updating system certificate everywhere..."
        adb -s "$serial" push "$CERT_PATH" "/data/local/tmp/$CERT_HASH.0" >/dev/null 2>&1
        
        cat << 'EOF' > /tmp/cert_inject_$serial.sh
CERT_FILE=$1
# Ensure the user store has it
mkdir -p /data/misc/user/0/cacerts-added
cp /data/local/tmp/$CERT_FILE /data/misc/user/0/cacerts-added/$CERT_FILE
chown system:system /data/misc/user/0/cacerts-added/$CERT_FILE
chmod 644 /data/misc/user/0/cacerts-added/$CERT_FILE

# Hunt down and overwrite any existing copies in /data (Magisk modules like trustusercerts)
    # If trustusercerts module exists, force copy the cert into it
    if [ -d "/data/adb/modules/trustusercerts/system/etc/security/cacerts" ]; then
        cp /data/local/tmp/$CERT_FILE /data/adb/modules/trustusercerts/system/etc/security/cacerts/$CERT_FILE
        chown root:root /data/adb/modules/trustusercerts/system/etc/security/cacerts/$CERT_FILE
        chmod 644 /data/adb/modules/trustusercerts/system/etc/security/cacerts/$CERT_FILE
        chcon u:object_r:system_security_cacerts_file:s0 /data/adb/modules/trustusercerts/system/etc/security/cacerts/$CERT_FILE 2>/dev/null
    fi

find /data -name "$CERT_FILE" 2>/dev/null | while read cert_path; do
    cp /data/local/tmp/$CERT_FILE "$cert_path"
    chown root:root "$cert_path" 2>/dev/null || chown system:system "$cert_path"
    chmod 644 "$cert_path"
    chcon u:object_r:system_security_cacerts_file:s0 "$cert_path" 2>/dev/null
done

# Try physical system partition as a fallback
mount -o rw,remount / 2>/dev/null || mount -o rw,remount /system 2>/dev/null
cp /data/local/tmp/$CERT_FILE /system/etc/security/cacerts/$CERT_FILE 2>/dev/null
chown root:root /system/etc/security/cacerts/$CERT_FILE 2>/dev/null
chmod 644 /system/etc/security/cacerts/$CERT_FILE 2>/dev/null

rm -f /data/local/tmp/$CERT_FILE
EOF
        adb -s "$serial" push /tmp/cert_inject_$serial.sh /data/local/tmp/cert_inject.sh >/dev/null 2>&1
        adb -s "$serial" shell "$HAS_SU -c 'sh /data/local/tmp/cert_inject.sh $CERT_HASH.0'"
        adb -s "$serial" shell "$HAS_SU -c 'rm -f /data/local/tmp/cert_inject.sh'"
        rm -f /tmp/cert_inject_$serial.sh
        
        echo "[$serial] Certificate injected safely. PLEASE REBOOT after Magisk module installation."
    fi

    # 4. System Tweak & MTP Lockout
    echo "[$serial] Applying System Tweaks & MTP Lockout..."
    # 4.1 USB Stability: Set Persistent USB to ADB Only (No MTP)
    adb -s "$serial" shell "su -c 'setprop persist.sys.usb.config adb && setprop sys.usb.config adb && svc usb setFunctions adb'" 2>/dev/null
    
    # 4.2 Disable Bloatware & MTP packages
    adb -s "$serial" shell pm uninstall com.google.android.webview >/dev/null 2>&1
    adb -s "$serial" shell pm disable-user --user 0 com.android.vending >/dev/null 2>&1
    adb -s "$serial" shell pm disable-user --user 0 com.samsung.android.mtp >/dev/null 2>&1 || true
    adb -s "$serial" shell pm disable-user --user 0 com.samsung.android.mtpapplication >/dev/null 2>&1 || true
    adb -s "$serial" shell pm disable-user --user 0 com.android.mtp >/dev/null 2>&1 || true

    # 4.3 UI Settings
    adb -s "$serial" shell settings put system accelerometer_rotation 0 >/dev/null 2>&1
    adb -s "$serial" shell settings put global ota_disable_automatic_update 1 >/dev/null 2>&1

    # 5. [EXPERIMENTAL] Automatic Magisk Module Installation
    echo "[$serial] Attempting automatic Magisk module installation..."
    for mod in /sdcard/Download/*.zip; do
        [ -e "$mod" ] || continue
        echo "    -> Installing module: $(basename "$mod")"
        adb -s "$serial" shell "$HAS_SU -c 'magisk --install-module \"$mod\"'" >/dev/null 2>&1
    done
done

echo "--------------------------------------------------"
echo "Installation & Provisioning complete."
