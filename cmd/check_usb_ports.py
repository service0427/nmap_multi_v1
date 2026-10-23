#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cmd/check_usb_ports.py
lsusb -t 트리 구조 및 포트 속도(480M/5000M/12M)를 adb devices 정보와 결합하여 출력하는 진단 도구
"""

import os
import re
import sys
import glob
import subprocess

CYAN = "\033[1;36m"
GREEN = "\033[1;32m"
YELLOW = "\033[1;33m"
RED = "\033[1;31m"
MAGENTA = "\033[1;35m"
BOLD = "\033[1m"
DIM = "\033[2m"
NC = "\033[0m"


def read_file_str(path):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            return f.read().strip()
    except Exception:
        return ""


def scan_sysfs_usb():
    """
    Scans /sys/bus/usb/devices/* and returns:
    - by_bus_dev: {(busnum_int, devnum_int): info_dict}
    - by_serial:  {serial_str: info_dict}
    - by_usbpath: {usb_path_str: info_dict}
    """
    by_bus_dev = {}
    by_serial = {}
    by_usbpath = {}

    for dev_dir in sorted(glob.glob("/sys/bus/usb/devices/*")):
        base = os.path.basename(dev_dir)
        # Skip interface subdirs like 1-1.2.1:1.0
        if ":" in base:
            continue
        busnum_str = read_file_str(os.path.join(dev_dir, "busnum"))
        devnum_str = read_file_str(os.path.join(dev_dir, "devnum"))
        if not busnum_str.isdigit() or not devnum_str.isdigit():
            continue

        busnum = int(busnum_str)
        devnum = int(devnum_str)
        speed = read_file_str(os.path.join(dev_dir, "speed"))
        serial = read_file_str(os.path.join(dev_dir, "serial"))
        product = read_file_str(os.path.join(dev_dir, "product"))
        manufacturer = read_file_str(os.path.join(dev_dir, "manufacturer"))
        id_vendor = read_file_str(os.path.join(dev_dir, "idVendor"))
        id_product = read_file_str(os.path.join(dev_dir, "idProduct"))
        max_child = read_file_str(os.path.join(dev_dir, "maxchild"))

        # Check if this USB device has a network interface (e.g. lte11..lte14)
        net_ifaces = []
        for net_dir in glob.glob(os.path.join(dev_dir, "*:*/net/*")):
            net_ifaces.append(os.path.basename(net_dir))

        info = {
            "usb_path": base,
            "busnum": busnum,
            "devnum": devnum,
            "speed": f"{speed}M" if speed else "N/A",
            "speed_num": float(speed) if speed.replace(".", "", 1).isdigit() else 0.0,
            "serial": serial,
            "product": product,
            "manufacturer": manufacturer,
            "vid_pid": f"{id_vendor}:{id_product}" if id_vendor else "",
            "is_hub": bool(max_child and int(max_child) > 0),
            "net_ifaces": net_ifaces,
        }
        by_bus_dev[(busnum, devnum)] = info
        by_usbpath[base] = info
        if serial and ":" not in serial and len(serial) >= 6:
            by_serial[serial] = info

    return by_bus_dev, by_serial, by_usbpath


def get_adb_devices():
    """
    Runs `adb devices -l` and returns:
    - adb_by_serial: {serial: {"state": state, "usb_path": usb_path, "model": model, "product": product, "transport_id": tid}}
    - adb_by_usbpath: {usb_path: serial}
    """
    adb_by_serial = {}
    adb_by_usbpath = {}
    try:
        res = subprocess.run(
            ["adb", "devices", "-l"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        for line in res.stdout.splitlines()[1:]:
            line = line.strip()
            if not line or line.startswith("*"):
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            serial = parts[0]
            if ":" in serial:
                continue
            state = parts[1]
            usb_path = ""
            model = ""
            product = ""
            transport_id = ""
            for token in parts[2:]:
                if token.startswith("usb:"):
                    usb_path = token.split("usb:", 1)[1]
                elif token.startswith("model:"):
                    model = token.split("model:", 1)[1]
                elif token.startswith("product:"):
                    product = token.split("product:", 1)[1]
                elif token.startswith("transport_id:"):
                    transport_id = token.split("transport_id:", 1)[1]

            adb_by_serial[serial] = {
                "serial": serial,
                "state": state,
                "usb_path": usb_path,
                "model": model,
                "product": product,
                "transport_id": transport_id,
            }
            if usb_path:
                adb_by_usbpath[usb_path] = serial
    except Exception as e:
        print(f"{RED}[!] adb devices 조회 실패: {e}{NC}", file=sys.stderr)

    return adb_by_serial, adb_by_usbpath


def format_speed(speed_str):
    if not speed_str or speed_str == "N/A":
        return f"{DIM}N/A{NC}"
    num_str = speed_str.rstrip("M")
    try:
        val = float(num_str)
    except ValueError:
        return speed_str
    if val >= 5000:
        return f"{CYAN}{speed_str}{NC}"
    elif val >= 480:
        return f"{GREEN}{speed_str}{NC}"
    else:
        return f"{RED}{speed_str} (SLOW!){NC}"


def format_state(state):
    if state == "device":
        return f"{GREEN}device      {NC}"
    elif state == "offline":
        return f"{RED}offline     {NC}"
    elif state == "unauthorized":
        return f"{YELLOW}unauthorized{NC}"
    elif state == "sysfs-only":
        return f"{MAGENTA}no-adb(usb) {NC}"
    else:
        return f"{RED}{state:<12}{NC}"


def get_hub_chain_speeds(usb_path, by_usbpath):
    """Returns the chain of speeds from root hub down to the device's parent hub, e.g. '480M > 480M > 480M'."""
    if not usb_path or "-" not in usb_path:
        return "-"
    bus_prefix, port_chain = usb_path.split("-", 1)
    parts = port_chain.split(".")
    chain_speeds = []
    # Root hub
    root_info = by_usbpath.get(f"usb{bus_prefix}")
    if root_info:
        chain_speeds.append(root_info["speed"])
    # Intermediate hubs (all except last element which is the device itself)
    for i in range(1, len(parts)):
        hub_path = f"{bus_prefix}-{'.'.join(parts[:i])}"
        hub_info = by_usbpath.get(hub_path)
        if hub_info:
            chain_speeds.append(hub_info["speed"])
    return " -> ".join(chain_speeds) if chain_speeds else "-"


def print_annotated_lsusb_tree(by_bus_dev, adb_by_serial, adb_by_usbpath, filter_serial=None):
    print(f"\n{CYAN}========================================================================================================{NC}")
    print(f" 🌳 {BOLD}lsusb -t 포트 트리 & ADB 디바이스 실시간 매핑{NC}")
    print(f"{CYAN}========================================================================================================{NC}")

    try:
        res = subprocess.run(["lsusb", "-t"], capture_output=True, text=True, timeout=5)
        lines = res.stdout.splitlines()
    except Exception as e:
        print(f"{RED}[!] lsusb -t 실행 실패: {e}{NC}")
        return

    current_bus = None
    seen_bus_dev_in_tree = set()

    for line in lines:
        # Root hub line: /:  Bus 001.Port 001: Dev 001, Class=root_hub, Driver=xhci_hcd/10p, 480M
        m_root = re.search(r"Bus\s+(\d+)\.Port\s+\d+:\s+Dev\s+(\d+).*,\s+(\d+M)", line)
        if m_root:
            current_bus = int(m_root.group(1))
            if not filter_serial:
                print(f"{BOLD}{line}{NC}")
            continue

        m_dev = re.search(r"Port\s+(\d+):\s+Dev\s+(\d+),\s+If\s+(\d+),\s+Class=([^,]+),\s+Driver=([^,]*),\s+(\d+M)", line)
        if m_dev and current_bus is not None:
            devnum = int(m_dev.group(2))
            ifnum = int(m_dev.group(3))
            dev_class = m_dev.group(4).strip()
            speed = m_dev.group(6).strip()

            sys_info = by_bus_dev.get((current_bus, devnum))
            annotation = ""
            matched_serial = None

            if sys_info:
                usb_path = sys_info["usb_path"]
                serial = sys_info["serial"] or adb_by_usbpath.get(usb_path, "")
                if serial and serial in adb_by_serial:
                    matched_serial = serial
                    adb_info = adb_by_serial[serial]
                    st = adb_info["state"]
                    mdl = adb_info["model"] or sys_info["product"] or "-"
                    st_color = GREEN if st == "device" else (YELLOW if st == "unauthorized" else RED)
                    spd_color = GREEN if speed in ("480M", "5000M", "10000M") else RED
                    annotation = f"  { st_color }➜ [{serial}] ({st}) {NC}| {mdl} | usb:{usb_path} | {spd_color}{speed}{NC}"
                elif serial and not sys_info["is_hub"] and not sys_info["net_ifaces"]:
                    matched_serial = serial
                    mdl = sys_info["product"] or "-"
                    annotation = f"  {MAGENTA}➜ [{serial}] (USB 연결됨 / ADB 미응답) {NC}| {mdl} | usb:{usb_path} | {speed}"
                elif sys_info["net_ifaces"]:
                    ifaces = ",".join(sys_info["net_ifaces"])
                    annotation = f"  {CYAN}➜ [LTE 모뎀: {ifaces}] {NC}| {sys_info['product'] or 'CDC_Ether'} | usb:{usb_path} | {speed}"
                elif sys_info["is_hub"]:
                    annotation = f"  {DIM}(Hub: usb:{usb_path}){NC}"

            if filter_serial:
                if matched_serial and filter_serial.lower() in matched_serial.lower():
                    print(f"Bus {current_bus:03d}: {line.strip()}{annotation}")
                continue

            # Avoid duplicate interface lines for the same ADB device if multiple interfaces exist
            if matched_serial and (current_bus, devnum) in seen_bus_dev_in_tree and ifnum > 0:
                continue
            if matched_serial:
                seen_bus_dev_in_tree.add((current_bus, devnum))

            print(f"{line}{annotation}")
        else:
            if not filter_serial:
                print(line)


def main():
    filter_serial = None
    tree_only = False
    table_only = False

    args = sys.argv[1:]
    for arg in args:
        if arg in ("-t", "--tree"):
            tree_only = True
        elif arg in ("-l", "--list", "--table"):
            table_only = True
        elif arg in ("-h", "--help"):
            print("사용법: ./cmd.sh --usb [옵션] [<기기ID>]")
            print("  옵션 없음        : lsusb -t 트리 매핑 + 기기별 포트 속도 요약표 전체 출력")
            print("  -t, --tree       : lsusb -t 트리 매핑만 출력")
            print("  -l, --list       : 기기별 USB 포트 속도 요약표만 출력")
            print("  <기기ID>         : 특정 기기(Serial)의 USB 포트 및 속도만 필터링")
            sys.exit(0)
        elif not arg.startswith("-"):
            filter_serial = arg.strip()

    by_bus_dev, by_serial, by_usbpath = scan_sysfs_usb()
    adb_by_serial, adb_by_usbpath = get_adb_devices()

    if not table_only:
        print_annotated_lsusb_tree(by_bus_dev, adb_by_serial, adb_by_usbpath, filter_serial=filter_serial)

    if tree_only:
        print()
        return

    # Build unified device list (all ADB devices + any Android device in sysfs missing from ADB)
    all_serials = set(adb_by_serial.keys())
    for s, info in by_serial.items():
        if not info["is_hub"] and not info["net_ifaces"]:
            # Exclude non-phone USB serials if any (e.g. root hubs have pci serials with ':')
            if info["vid_pid"].startswith("04e8:") or s in adb_by_serial or "Android" in info["product"] or "SAMSUNG" in info["manufacturer"].upper():
                all_serials.add(s)

    if filter_serial:
        all_serials = {s for s in all_serials if filter_serial.lower() in s.lower()}

    sorted_serials = sorted(all_serials)

    print(f"\n{CYAN}========================================================================================================{NC}")
    print(f" 📊 {BOLD}ADB 디바이스별 USB 포트 경로 & 링크 속도 상세 조회 (총 {len(sorted_serials)}대){NC}")
    print(f"{CYAN}========================================================================================================{NC}")
    print(f"  {'No.':<4} {'Device ID':<15} | {'ADB Status':<12} | {'Model':<10} | {'USB Path':<12} | {'Bus/Dev':<11} | {'Speed':<8} | {'Hub Speed Chain'}")
    print(f"--------------------------------------------------------------------------------------------------------")

    cnt_device = 0
    cnt_offline = 0
    cnt_unauth = 0
    cnt_noadb = 0
    slow_devices = []

    for idx, serial in enumerate(sorted_serials, 1):
        adb_info = adb_by_serial.get(serial)
        sys_info = by_serial.get(serial)
        if not sys_info and adb_info and adb_info.get("usb_path"):
            sys_info = by_usbpath.get(adb_info["usb_path"])

        state = adb_info["state"] if adb_info else "sysfs-only"
        if state == "device":
            cnt_device += 1
        elif state == "offline":
            cnt_offline += 1
        elif state == "unauthorized":
            cnt_unauth += 1
        else:
            cnt_noadb += 1

        model = (adb_info.get("model") if adb_info else "") or (sys_info.get("product") if sys_info else "") or "-"
        usb_path = (sys_info.get("usb_path") if sys_info else "") or (adb_info.get("usb_path") if adb_info else "") or "-"
        bus_dev = f"{sys_info['busnum']:03d}/{sys_info['devnum']:03d}" if sys_info else "-/-"
        speed = sys_info["speed"] if sys_info else "N/A"
        hub_chain = get_hub_chain_speeds(usb_path, by_usbpath)

        if sys_info and 0 < sys_info["speed_num"] < 480:
            slow_devices.append((serial, usb_path, speed))

        print(
            f"  {idx:02d}.  {serial:<15} | {format_state(state)} | {model:<10.10} | "
            f"{('usb:' + usb_path) if usb_path != '-' else '-':<12} | {bus_dev:<11} | {format_speed(speed):<19} | {hub_chain}"
        )

    print(f"{CYAN}========================================================================================================{NC}")
    summary = (
        f" 📌 요약: 정상(device) {GREEN}{cnt_device}대{NC} | "
        f"오프라인(offline) {RED if cnt_offline else DIM}{cnt_offline}대{NC} | "
        f"미승인(unauthorized) {YELLOW if cnt_unauth else DIM}{cnt_unauth}대{NC}"
    )
    if cnt_noadb > 0:
        summary += f" | ADB미응답(USB연결됨) {MAGENTA}{cnt_noadb}대{NC}"
    print(summary)

    if slow_devices:
        print(f" {RED}[⚠️ 경고] USB 2.0(480M) 미만 저속 포트로 연결된 기기 ({len(slow_devices)}대):{NC}")
        for s, p, spd in slow_devices:
            print(f"    - {s} (usb:{p}) -> {RED}{spd}{NC} (케이블 불량 또는 허브 포트 재연결 권장)")
    else:
        print(f" {GREEN}[✓] 모든 연결 기기가 정상 고속 포트(480M 이상)로 연결되어 있습니다.{NC}")
    print(f"{CYAN}========================================================================================================{NC}\n")


if __name__ == "__main__":
    main()
