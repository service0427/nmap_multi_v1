#!/bin/bash

# repair_environment.sh: Fix missing Frida, mitmproxy, and other critical dependencies.
# Usage: chmod +x repair_environment.sh && ./repair_environment.sh

CYAN="\e[1;36m"; GREEN="\e[1;32m"; YELLOW="\e[1;33m"; RED="\e[1;31m"; NC="\e[0m"

echo -e "${CYAN}============================================================"
echo "   Nmap-Mini Environment Repair Tool"
echo -e "============================================================${NC}"

# 1. Identify pip break system packages flag
PIP_BREAK_FLAGS=""
if pip3 install --help 2>/dev/null | grep -q "break-system-packages"; then
    PIP_BREAK_FLAGS="--break-system-packages"
fi

echo -e "${CYAN}[*] Installing/Repairing Python dependencies...${NC}"
# Reinstall core tools to ensure they are present and functional
sudo python3 -m pip install --upgrade --ignore-installed pip $PIP_BREAK_FLAGS
sudo python3 -m pip install --ignore-installed \
    blackboxprotobuf \
    flask \
    frida-tools \
    mitmproxy \
    requests \
    huawei-lte-api \
    $PIP_BREAK_FLAGS

# 2. Verify and Symlink
echo -e "${CYAN}[*] Verifying tool paths and creating symlinks...${NC}"
for cmd in frida mitmdump mitmproxy; do
    # Check if command is already working
    if command -v $cmd >/dev/null 2>&1; then
        echo -e "  -> ${GREEN}[✓] $cmd is already in PATH: $(which $cmd)${NC}"
    else
        # Search in common pip installation paths
        SEARCH_PATHS=(
            "/usr/local/bin/$cmd"
            "$HOME/.local/bin/$cmd"
            "/root/.local/bin/$cmd"
        )
        FOUND=false
        for path in "${SEARCH_PATHS[@]}"; do
            if [ -f "$path" ]; then
                sudo ln -sf "$path" /usr/bin/$cmd
                echo -e "  -> ${GREEN}[✓] Fixed: Symlinked $cmd from $path to /usr/bin/${NC}"
                FOUND=true
                break
            fi
        done
        if [ "$FOUND" = false ]; then
            echo -e "  -> ${RED}[!] Failed: Could not find $cmd binary.${NC}"
        fi
    fi
done

# 3. Final Verification
echo -e "${CYAN}============================================================"
echo "   Verification Results"
echo -e "============================================================${NC}"

if command -v frida >/dev/null 2>&1; then
    echo -e "Frida version: ${GREEN}$(frida --version)${NC}"
else
    echo -e "${RED}Frida is NOT installed properly.${NC}"
fi

if command -v mitmdump >/dev/null 2>&1; then
    echo -e "Mitmproxy version: ${GREEN}$(mitmdump --version | head -n 1)${NC}"
else
    echo -e "${RED}Mitmproxy is NOT installed properly.${NC}"
fi

echo -e "${CYAN}============================================================"
echo -e "   Repair Complete!${NC}"
echo -e "============================================================${NC}"
