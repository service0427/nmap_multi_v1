#!/usr/bin/env bash

# ============================================================
# Naver Map Auto-Simulation Infrastructure (V2)
# Device BoringSSL Curl Recovery Script
# ============================================================

TARGET_DEVICE=$1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURL_BIN="$SCRIPT_DIR/install/curl-aarch64"

if [ ! -f "$CURL_BIN" ]; then
    echo "[-] Error: Local BoringSSL curl binary not found at $CURL_BIN"
    exit 1
fi

# Get connected devices
if [ -z "$TARGET_DEVICE" ]; then
    echo "[*] No target device specified. Checking all connected devices..."
    DEVICES=$(adb devices | grep -w "device" | awk '{print $1}')
else
    echo "[*] Targeting specific device: $TARGET_DEVICE"
    DEVICES=$TARGET_DEVICE
fi

if [ -z "$DEVICES" ]; then
    echo "[-] No devices connected."
    exit 1
fi

GREEN="\e[1;32m"
YELLOW="\e[1;33m"
RED="\e[1;31m"
NC="\e[0m"

for serial in $DEVICES; do
    echo "--------------------------------------------------"
    echo -e "Checking/Restoring BoringSSL curl on device: ${GREEN}$serial${NC}"
    
    # 1. Backup and disable HTTP Proxy to ensure direct connection to verification server
    OLD_PROXY=$(adb -s "$serial" shell "settings get global http_proxy" 2>/dev/null | tr -d '\r\n')
    if [ "$OLD_PROXY" != ":0" ] && [ "$OLD_PROXY" != "null" ] && [ -n "$OLD_PROXY" ]; then
        echo "  - Temporarily disabling device proxy ($OLD_PROXY)..."
        adb -s "$serial" shell "settings put global http_proxy :0" >/dev/null 2>&1
    fi

    # 2. Check if BoringSSL curl is already active and working
    has_device_curl=$(adb -s "$serial" shell "which curl" 2>/dev/null | tr -d '\r')
    is_boring="NO"
    if [ -n "$has_device_curl" ]; then
        is_boring=$(adb -s "$serial" shell "curl --version 2>/dev/null" | grep -q "BoringSSL" && echo "YES" || echo "NO")
    fi
    
    is_working="NO"
    if [ "$is_boring" = "YES" ]; then
        # Check standard HTTPS first (without --resolve) in case DNS is working
        test_ip=$(adb -s "$serial" shell "curl -s -4 --connect-timeout 3 https://ifconfig.me" 2>/dev/null | tr -d '\r\n')
        if [[ "$test_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            is_working="YES"
        else
            # Try resolve fallback using ping
            resolved_ip=$(adb -s "$serial" shell "ping -c 1 -W 2 ifconfig.me | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'" 2>/dev/null | tr -d '\r\n')
            if [ -z "$resolved_ip" ]; then
                resolved_ip="34.160.111.145" # Fallback to known static IP of ifconfig.me
            fi
            test_ip=$(adb -s "$serial" shell "curl -s -4 --connect-timeout 3 --resolve ifconfig.me:443:$resolved_ip https://ifconfig.me" 2>/dev/null | tr -d '\r\n')
            if [[ "$test_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                is_working="YES"
            fi
        fi
    fi
    
    if [ "$is_working" = "YES" ]; then
        # Clean up residual resolv.conf files if any exist on an already working device
        adb -s "$serial" shell "su -c 'rm -f /system/etc/resolv.conf /etc/resolv.conf'" >/dev/null 2>&1
        echo -e "  ${GREEN}[✓] Device already has fully functional BoringSSL curl. Skipping.${NC}"
        
        # Restore proxy
        if [ "$OLD_PROXY" != ":0" ] && [ "$OLD_PROXY" != "null" ] && [ -n "$OLD_PROXY" ]; then
            adb -s "$serial" shell "settings put global http_proxy $OLD_PROXY" >/dev/null 2>&1
        fi
        continue
    fi

    # 3. Find su
    HAS_SU=$(adb -s "$serial" shell "which su" 2>/dev/null | tr -d '\r')
    if [ -z "$HAS_SU" ]; then
        HAS_SU=$(adb -s "$serial" shell "ls /system/bin/su /system/xbin/su /sbin/su 2>/dev/null" | head -1 | tr -d '\r')
    fi
    
    if [ -z "$HAS_SU" ]; then
        echo -e "  ${RED}[!] Root (su) not found. Cannot overwrite system curl.${NC}"
        # Restore proxy
        if [ "$OLD_PROXY" != ":0" ] && [ "$OLD_PROXY" != "null" ] && [ -n "$OLD_PROXY" ]; then
            adb -s "$serial" shell "settings put global http_proxy $OLD_PROXY" >/dev/null 2>&1
        fi
        continue
    fi
    
    # 4. Push and deploy native BoringSSL curl
    echo "  - Pushing BoringSSL curl to /data/local/tmp/curl..."
    adb -s "$serial" push "$CURL_BIN" /data/local/tmp/curl >/dev/null 2>&1
    
    echo "  - Remounting system and deploying curl to /system/bin/curl..."
    # 4.1 Unmount Zygisk file-level overlay (if active)
    adb -s "$serial" shell "$HAS_SU -c 'umount /system/bin/curl'" >/dev/null 2>&1
    
    # 4.2 Remount /, /system, and /system/bin (Zygisk tmpfs overlay) as read-write
    adb -s "$serial" shell "$HAS_SU -c 'mount -o rw,remount / 2>/dev/null || mount -o rw,remount /system 2>/dev/null; mount -o rw,remount /system/bin 2>/dev/null'" >/dev/null 2>&1
    
    # 4.3 Copy binary, set permission, clean up temporary resolv.conf and local tmp curl
    adb -s "$serial" shell "$HAS_SU -c 'cp /data/local/tmp/curl /system/bin/curl && chmod 755 /system/bin/curl; rm -f /system/etc/resolv.conf; rm -f /etc/resolv.conf; rm -f /data/local/tmp/curl'" >/dev/null 2>&1
    
    # 5. Verify native BoringSSL curl via HTTPS
    echo "  - Verifying HTTPS connection (without -k)..."
    TEST_IP=$(adb -s "$serial" shell "curl -sS -4 --connect-timeout 5 https://ifconfig.me 2>&1" | tr -d '\r\n')
    
    if [[ ! "$TEST_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # Try resolve fallback using ping
        resolved_ip=$(adb -s "$serial" shell "ping -c 1 -W 2 ifconfig.me | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'" 2>/dev/null | tr -d '\r\n')
        if [ -z "$resolved_ip" ]; then
            resolved_ip="34.160.111.145" # Fallback to known static IP
        fi
        TEST_IP=$(adb -s "$serial" shell "curl -sS -4 --connect-timeout 5 --resolve ifconfig.me:443:$resolved_ip https://ifconfig.me 2>&1" | tr -d '\r\n')
    fi
    
    if [[ "$TEST_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "  ${GREEN}[✓] Recovery SUCCESS! Real IP detected: $TEST_IP${NC}"
    else
        # Try fallback check using -k in case it's a certificate issue
        resolved_ip=$(adb -s "$serial" shell "ping -c 1 -W 2 ifconfig.me | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'" 2>/dev/null | tr -d '\r\n')
        if [ -z "$resolved_ip" ]; then
            resolved_ip="34.160.111.145"
        fi
        TEST_IP_K=$(adb -s "$serial" shell "curl -k -sS -4 --connect-timeout 5 --resolve ifconfig.me:443:$resolved_ip https://ifconfig.me 2>&1" | tr -d '\r\n')
        
        if [[ "$TEST_IP_K" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo -e "  ${YELLOW}[⚠️] curl works with -k, but standard HTTPS failed. Output: $TEST_IP_K${NC}"
        else
            echo -e "  ${RED}[!] Verification FAILED. Output: $TEST_IP (Fallback: $TEST_IP_K)${NC}"
            
            # Print diagnostic information
            device_proxy=$(adb -s "$serial" shell "settings get global http_proxy" 2>/dev/null | tr -d '\r\n')
            cert_details=$(adb -s "$serial" shell "curl -Iv -4 --connect-timeout 5 --resolve ifconfig.me:443:$resolved_ip https://ifconfig.me 2>&1" | grep -E 'Server certificate|subject|issuer|subjectAltName|SSL connection|expire date' | sed 's/^/      /')
            echo -e "  ${YELLOW}[Diagnostics]${NC}"
            echo -e "    - Resolved IP: $resolved_ip"
            echo -e "    - Device Global Proxy: $device_proxy"
            echo -e "    - Certificate Details:"
            if [ -n "$cert_details" ]; then
                echo "$cert_details"
            else
                echo "      (Could not retrieve certificate details)"
            fi
        fi
    fi

    # Restore proxy at the end of loop
    if [ "$OLD_PROXY" != ":0" ] && [ "$OLD_PROXY" != "null" ] && [ -n "$OLD_PROXY" ]; then
        adb -s "$serial" shell "settings put global http_proxy $OLD_PROXY" >/dev/null 2>&1
    fi
done

echo "--------------------------------------------------"
echo -e "${GREEN}[✓] BoringSSL Curl Recovery complete.${NC}"
