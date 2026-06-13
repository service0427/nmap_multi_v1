#!/usr/bin/env bash

# test_nmap_v2/run_scheduler.sh: Optimized runner for PM2 management
# This wrapper ensures the correct working directory and environment for the loop.

# 1. 고정 경로 이동 (test_nmap_v2 폴더 내에서 실행 보장)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR" || exit 1

echo "[$(date)] Starting Nmap Orchestrator via PM2 Runner..."
echo "[*] Working Directory: $(pwd)"

# 2. 기존 loop.sh를 직접 실행 (환경 변수 유지)
# exec를 사용하여 쉘 프로세스를 loop.sh로 완전히 교체함으로써 PM2가 직접 제어하게 함
exec bash loop.sh
