#!/bin/bash

# ============================================================
# [수동 실행 절차]
# OS 설치 시 OpenSSH Server를 체크한 후, 터미널에서 다음 명령어들을 순서대로 실행하세요.
# 1. sudo apt update && sudo apt install -y git
# 2. git clone https://github.com/service0427/nmap_mini.git
# 3. cd nmap_mini
# 4. chmod +x install_cli_os.sh
# 5. ./install_cli_os.sh
#
# * 참고: 
# - .ssh 폴더 생성 명령어는 폴더가 없을 때만 생성하는 안전 장치입니다.
# - OpenSSH Server는 OS 설치 단계에서 이미 체크 후 설치되었다고 가정합니다.
# ============================================================

# install_cli_os.sh: Server Initial Setup Script (CUI Ready)

echo "============================================================"
echo "   Server Initial Setup Start"
echo "============================================================"

# 1. Sudo 비밀번호 생략 설정 (현재 사용자)
echo "[*] Configuring passwordless sudo for $USER..."
if ! sudo grep -q "^$USER ALL=(ALL) NOPASSWD:ALL" "/etc/sudoers.d/$USER" 2>/dev/null; then
    echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/$USER" >/dev/null
    sudo chmod 0440 "/etc/sudoers.d/$USER"
    echo "  -> Passwordless sudo enabled for $USER."
else
    echo "  -> Passwordless sudo already configured. Skipping."
fi

# 2. SSH 키 설정 (자동 등록)
echo "[*] Configuring SSH Public Keys..."
# .ssh 디렉토리 생성 및 권한 설정
if [ ! -d ~/.ssh ]; then
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
fi

# 집 SSH 키 등록
HOME_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC07UNfs5EPAYS1TSHdoZofg93FFiHzIxmnixPJMFDgaDF6eKfCBrco2t+fxyyKO2IoxrSj79ii+MYaxYV+oPqMoAS5RrUHrVEgeYNxkkvW6LkxdJzUiHZZOesfcV2djnRphPPIEQND0m7b8RacDiH3Cxv6UMZRtWQVi3vxtqF02RikluTux5H6nnzn197wQE7yBs4J55Wuut6lftrE3meHU2i/pnhFOjr0qOuC2GzP3N/aRH3BEeZ78lQbgwFlzvfLsEdF8ebYXVKiT7TAExjWfcicSu+lDBsn50tAY8HsJVD30zKXImSJl5W/A3Nv63/rexaRfI2O5LQpdjx8STsGmtwtuYiHmfH6swy2wEyN5UEvTxF/fuI7EYIoC0ej44paH8mSv73svQUButhcMkI5ZgXgIerWz0gCGXMA1pwjW0oZKPgN9GnhqDKBXYQYjRr3NApjxwTCcJ4jlRH5TrV9+ass96ChSKpCeKg0R1BAKX2HYal08egOoiEBbUkX+yQ+C/BP02iZcGPqX886cmuR2lF97JFpeEdMxEdb6ClBTrdbRlB9PWq5R7erUXS/1YMNTJZHAeoVa5Jr2JW1cZYS424S3i48vjBZyHMF3VCFHQA7B9n1ztOalzyRpRfB8QrpfaItwNnTho28kDW4zaZ/Ugv1zV8/4P+JcvVo9A3EZw== techb@TechB"
if ! grep -q "$HOME_KEY" ~/.ssh/authorized_keys 2>/dev/null; then
    echo "$HOME_KEY" >> ~/.ssh/authorized_keys
    echo "  -> Home SSH Key added."
else
    echo "  -> Home SSH Key already exists. Skipping."
fi

# 가게 SSH 키 등록
STORE_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDrHO2J7IvtUvxry/1jZP/eQfC1CTW2fPUd/x/1xq5A0mNqh7jqM6l1B5jySTCekc4PCHMLqcZFFrsQHVhrKaG2S7ZYtlvDFcxSyWxUcxJUoo5WjhQ7L6OJYy9KvrThbgGhfBx9NVmo0lE/GAYw/RL3JpBfb5mdZr8fFlmm6C9nC2yiQtY+NpnmkeoQnCOL/yFi6uFQpTktpaE0J6tR2JPl0yT524q5J3KV5R4/sPFE1kOmq80C/Gafn6tKaxQ2f7VLX/IYhsxXpq2ymT1UYcH+IDsepYEsNYobEklyod1if2ZuEc0Qr6g76GoR7/3e03p/1vaJJ4Tmge+gIVWmymxzmOJpwQEvDxDBkiWstM2oNqSYYcOc1FC97eA+FqrqJrfYM/LlF70kOQ9KaxJVeZ5dNO99pegYk6DA15tHuWe4RnGtS+A5Sd0Y4V9jIwVDp9PS0oWxjHld7dRMVVqiEUUWcc6fv517OjYkLNg4tXoamYAgDZHDQ4Knjn0Ysusl45lD5Uki+kFbe2yZR8Txr/gwoz7UVarLVxpqmIDyUf0/9D5nWUbLpkYKpVpw8RgTc2G7HALfkzQ28SOX3eMxRTxpVUFQTI/4Y2ys5DEDszHJ0knffLRAPHUUq4f7gcJ8PRWfW8Zs/Yf1ZLpEYV1dcVbyR0mYSOKxC/w9X/6tttR3GQ== moon@DESKTOP-OTKATMO"
if ! grep -q "$STORE_KEY" ~/.ssh/authorized_keys 2>/dev/null; then
    echo "$STORE_KEY" >> ~/.ssh/authorized_keys
    echo "  -> Store SSH Key added."
else
    echo "  -> Store SSH Key already exists. Skipping."
fi

chmod 600 ~/.ssh/authorized_keys

# 3. SSH 데몬 설정 (PubkeyAuthentication 활성화)
echo "[*] Enabling PubkeyAuthentication in sshd_config..."
if ! grep -q "^PubkeyAuthentication yes" /etc/ssh/sshd_config; then
    sudo sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    sudo sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    sudo systemctl restart ssh
    echo "  -> PubkeyAuthentication enabled and SSH restarted."
else
    echo "  -> PubkeyAuthentication is already enabled. Skipping."
fi

# SSH 서비스 활성화
sudo systemctl enable ssh

# 4. 타임존 설정 (한국 시간)
echo "[*] Setting timezone to Asia/Seoul..."
sudo timedatectl set-timezone Asia/Seoul
date

# 5. 패키지 리스트 업데이트 및 기본 도구 설치
echo "[*] Updating package list & Installing basic tools..."
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git screen adb curl wget build-essential cron net-tools nano ffmpeg jq openssl libssl-dev zlib1g-dev libffi-dev tcpdump iputils-ping dnsutils quota unzip iptables-persistent lsof

# 6. Python 및 필수 라이브러리 설치
echo "[*] Installing Python3 and required libraries..."
sudo apt install -y python3 python3-pip python3-dev python3-venv
sudo python3 -m pip install --upgrade --ignore-installed pip --break-system-packages
sudo python3 -m pip install --ignore-installed blackboxprotobuf flask frida-tools mitmproxy requests huawei-lte-api --break-system-packages

# [V1.2] Frida & Mitmproxy PATH 안정화 (심볼릭 링크 강제 생성)
# 최신 OS에서 externally-managed-environment 에러 대응 및 PATH 누락 방지
echo "[*] Verifying tool availability and creating symlinks..."
for cmd in frida mitmdump mitmproxy; do
    # 1. 이미 경로에 있는지 확인
    if ! command -v $cmd >/dev/null 2>&1; then
        # 2. 일반적인 pip 설치 경로 탐색
        SEARCH_PATHS=("/usr/local/bin/$cmd" "$HOME/.local/bin/$cmd" "/root/.local/bin/$cmd")
        for path in "${SEARCH_PATHS[@]}"; do
            if [ -f "$path" ]; then
                sudo ln -sf "$path" /usr/bin/$cmd
                echo "  -> Fixed: Symlinked $cmd from $path to /usr/bin/"
                break
            fi
        done
    else
        echo "  -> $cmd is already in PATH."
    fi
done

# 7. Node.js 최신 LTS 버전 설치
echo "[*] Installing Node.js (Latest LTS)..."
if ! command -v node >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt install -y nodejs
else
    echo "  -> Node.js is already installed. Skipping."
fi

# 8. PM2 설치 (글로벌)
echo "[*] Installing PM2..."
if ! command -v pm2 >/dev/null 2>&1; then
    sudo npm install -g pm2
else
    echo "  -> PM2 is already installed. Skipping."
fi

# 9. mitmproxy 인증서 자동 초기 생성
echo "[*] Initializing mitmproxy CA Certificate..."
CERT_PATH="/home/tech/.mitmproxy/mitmproxy-ca-cert.pem"
if [ ! -f "$CERT_PATH" ]; then
    if command -v mitmdump >/dev/null 2>&1; then
        echo "  -> Generating mitmproxy certificates (running mitmdump in background for 2s)..."
        mitmdump &
        MITM_PID=$!
        sleep 2
        kill $MITM_PID 2>/dev/null
        if [ -f "$CERT_PATH" ]; then
            echo "  -> Certificates generated successfully: $CERT_PATH"
        else
            echo "  -> [Warning] Certificate generation might have failed. Please check manually."
        fi
    else
        echo "  -> [Warning] mitmdump not found. Cannot generate certificates."
    fi
else
    echo "  -> mitmproxy certificates already exist. Skipping."
fi

# 9.1. IP Forwarding 활성화 및 영구 설정
echo "[*] Enabling IP Forwarding permanently..."
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-ip-forward.conf >/dev/null

# 9.2. ADB Key 루트 디렉토리 동기화 및 권한 설정
echo "[*] Synchronizing ADB Keys to root directory..."
if [ -f "$HOME/.android/adbkey" ]; then
    sudo mkdir -p /root/.android
    sudo cp "$HOME/.android/adbkey" /root/.android/adbkey
    sudo cp "$HOME/.android/adbkey.pub" /root/.android/adbkey.pub
    sudo chmod 600 /root/.android/adbkey
    sudo chmod 644 /root/.android/adbkey.pub
    sudo chown root:root /root/.android/adbkey /root/.android/adbkey.pub
    if [ -f "$HOME/.android/adbkey_k17" ]; then
        sudo cp "$HOME/.android/adbkey_k17" /root/.android/adbkey_k17
        sudo cp "$HOME/.android/adbkey_k17.pub" /root/.android/adbkey_k17.pub
        sudo chmod 600 /root/.android/adbkey_k17
        sudo chmod 644 /root/.android/adbkey_k17.pub
        sudo chown root:root /root/.android/adbkey_k17 /root/.android/adbkey_k17.pub
    fi
    echo "  -> ADB Keys successfully copied and secured under /root/.android/"
fi

# 9.5. 자동 업데이트(unattended-upgrades) 비활성화 (재부팅/서비스 재시작 방지)
echo "[*] Disabling automatic background updates (unattended-upgrades)..."
sudo systemctl stop unattended-upgrades 2>/dev/null || true
sudo systemctl disable unattended-upgrades 2>/dev/null || true
if [ -d /etc/apt/apt.conf.d ]; then
    echo 'APT::Periodic::Update-Package-Lists "0";' | sudo tee /etc/apt/apt.conf.d/10periodic >/dev/null
    echo 'APT::Periodic::Unattended-Upgrade "0";' | sudo tee -a /etc/apt/apt.conf.d/10periodic >/dev/null
    echo 'APT::Periodic::Update-Package-Lists "0";' | sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null
    echo 'APT::Periodic::Unattended-Upgrade "0";' | sudo tee -a /etc/apt/apt.conf.d/20auto-upgrades >/dev/null
    echo "  -> Automatic updates disabled in APT configs."
fi

# 9.6. USB Autosuspend (자동 절전) 비활성화 설정 (기기 오프라인 방지)
echo "[*] Disabling USB Autosuspend (To prevent devices from going offline)..."
# 1) GRUB 커널 부팅 파라미터 등록 (재부팅 후에도 영구 적용)
if [ -f /etc/default/grub ]; then
    if ! grep -q "usbcore.autosuspend=-1" /etc/default/grub; then
        sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="usbcore.autosuspend=-1 /' /etc/default/grub
        sudo update-grub 2>/dev/null || echo "  -> [Warning] Failed to update-grub. Please run sudo update-grub manually."
        echo "  -> Added usbcore.autosuspend=-1 to GRUB cmdline."
    else
        echo "  -> GRUB already has usbcore.autosuspend=-1."
    fi
fi

# 2) udev 규칙 파일 생성 (기기 연결 시 전원 control을 'on'으로 상시 유지)
UDEV_RULE_PATH="/etc/udev/rules.d/99-disable-usb-autosuspend.rules"
if [ ! -f "$UDEV_RULE_PATH" ]; then
    echo 'ACTION=="add", SUBSYSTEM=="usb", TEST=="power/control", ATTR{power/control}="on"' | sudo tee "$UDEV_RULE_PATH" >/dev/null
    sudo udevadm control --reload-rules
    echo "  -> Created permanent udev rule to disable USB autosuspend."
else
    echo "  -> udev rule already exists. Skipping."
fi

# 3) 현재 세션에 즉시 적용
sudo sh -c 'echo -1 > /sys/module/usbcore/parameters/autosuspend' 2>/dev/null || true
for dev in /sys/bus/usb/devices/*/power/control; do
    echo "on" | sudo tee "$dev" >/dev/null 2>&1
done
echo "  -> USB Autosuspend disabled for active session."

# 10. 설치 확인
echo "============================================================"
echo "   Installation Summary"
echo "============================================================"
git --version
screen -v
adb --version
python3 --version
node -v
pm2 -v
sudo systemctl status ssh | grep -i active || echo "SSH Service is not running"
echo "Timezone: $(date)"
echo "============================================================"
echo "   OS Setup Complete!"
echo "============================================================"
