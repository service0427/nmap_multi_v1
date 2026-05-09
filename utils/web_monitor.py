import os
import subprocess
import time
import threading
import socket
import json
from flask import Flask, Response, render_template_string, request, jsonify

app = Flask(__name__)

# --- CONFIGURATION ---
PORT = 5000
REFRESH_INTERVAL = 0.12  # 약 8fps (모니터링 최적, ADB 부하 최소화)
MAX_SLOTS = 5
LOG_BASE_DIR = "/home/tech/nmap/test_nmap_v2/logs"

# 기기 위치 고정 및 진단 캐시
device_slots = [None] * MAX_SLOTS
diag_cache = {}

# --- HTML TEMPLATE ---
HTML_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
    <title>{{ hostname }} - Monitor</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        body { background: #121212; color: #eee; font-family: sans-serif; margin: 0; padding: 10px; }
        .container { display: grid; grid-template-columns: repeat(auto-fill, 326px); gap: 15px; max-width: 1800px; margin: 0 auto; justify-content: center; }
        .device-card { background: #1e1e1e; border-radius: 8px; padding: 10px; border: 1px solid #333; text-align: center; width: 326px; height: 920px; display: flex; flex-direction: column; box-sizing: border-box; overflow: hidden; }
        .device-card.working { border-color: #4CAF50; box-shadow: 0 0 10px rgba(76, 175, 80, 0.2); }
        .device-card.offline { opacity: 0.5; border-color: #f44336; }
        
        .card-header { display: flex; justify-content: space-between; align-items: center; padding: 0 5px; height: 50px; flex-shrink: 0; }
        .device-id { font-weight: bold; color: #4CAF50; font-size: 0.9em; line-height: 1.2; text-align: left; }
        .header-buttons { display: flex; gap: 5px; align-items: center; }
        .header-buttons button { padding: 4px 6px; font-size: 0.8em; border-radius: 4px; border: none; cursor: pointer; color: white; min-width: 28px; }
        .touch-label { background: #333; padding: 4px 6px; border-radius: 4px; display: flex; align-items: center; cursor: pointer; font-size: 0.8em; }
        
        .diag-overlay { background: rgba(0,0,0,0.7); padding: 5px; border-radius: 4px; margin-bottom: 5px; font-size: 0.75em; text-align: left; display: flex; flex-direction: column; gap: 2px; height: 65px; }
        .diag-item { display: flex; justify-content: space-between; }
        .status-badge { padding: 2px 6px; border-radius: 10px; font-weight: bold; font-size: 0.8em; }
        .badge-working { background: #2E7D32; color: white; }
        .badge-idle { background: #424242; color: #bbb; }
        .badge-offline { background: #d32f2f; color: white; }
        
        .battery-warning { color: #f44336 !important; font-weight: bold; animation: pulse-red 1s infinite; text-shadow: 0 0 5px rgba(244, 67, 54, 0.8); }
        @keyframes pulse-red { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }

        /* [NEW] Live Task Info Styles */
        .live-task-box { background: rgba(76, 175, 80, 0.1); border: 1px solid rgba(76, 175, 80, 0.3); border-radius: 4px; padding: 6px; margin-bottom: 8px; text-align: left; font-size: 0.85em; height: 92px; box-sizing: border-box; }
        .live-task-dest { color: #4CAF50; font-weight: bold; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; margin-bottom: 2px; }
        .live-task-meta { display: flex; flex-direction: column; gap: 1px; color: #aaa; font-size: 0.85em; }
        .live-task-row { display: flex; justify-content: space-between; }
        .elapsed-timer { color: #ffeb3b; font-family: monospace; font-weight: bold; }
        .target-confirmed { color: #4CAF50; font-weight: bold; }

        .screen-container { position: relative; width: 306px; height: 610px; margin: 0 auto; display: flex; align-items: center; justify-content: center; background: #000; border-radius: 4px; overflow: hidden; flex-shrink: 0; }
        .screen-img { width: 306px; height: 610px; object-fit: contain; display: none; }
        
        .offline-placeholder { color: #555; font-size: 1.2em; font-weight: bold; display: flex; flex-direction: column; gap: 10px; }

        .controls { margin-top: auto; display: flex; gap: 8px; justify-content: center; padding: 10px 0; flex-shrink: 0; }
        button.btn-ctrl { padding: 8px 12px; cursor: pointer; background: #333; color: white; border: none; border-radius: 4px; font-weight: bold; font-size: 1.2em; }
        
        .dimmed { opacity: 0.3; pointer-events: none; }
    </style>
</head>
<body>
    <div class="container" id="device-container">
        {% for i in range(MAX_SLOTS) %}
        {% set dev = slots[i] %}
        <div class="device-card {{ 'working' if dev and dev.status == 'WORKING' }} {{ 'offline' if not dev or dev.offline }}" id="slot-{{ i }}">
            <div class="card-header {{ 'dimmed' if not dev or dev.offline }}">
                <span class="device-id">
                    {{ dev.model if dev else 'EMPTY SLOT' }}
                    {% if dev %}<br><small style="font-size: 0.7em; color: #888;">{{ dev.id }}</small>{% endif %}
                </span>
                {% if dev and not dev.offline %}
                <div class="header-buttons">
                    <button id="btn-mon-{{ dev.id }}" onclick="toggleMonitor('{{ dev.id }}')" style="background: #607D8B;" title="Toggle Monitor">📺</button>
                    <button onclick="unlockDevice('{{ dev.id }}')" style="background: #2196F3;" title="Wake/Unlock">🔓</button>
                    <button onclick="sleepDevice('{{ dev.id }}')" style="background: #9C27B0;" title="Sleep">🌙</button>
                    <button onclick="rebootDevice('{{ dev.id }}')" style="background: #f44336;" title="Reboot">🔄</button>
                    <label class="touch-label" title="Enable Touch">
                        <input type="checkbox" id="touch-{{ dev.id }}" checked> 🖐️
                    </label>
                </div>
                {% endif %}
            </div>
            
            <div class="diag-overlay">
                {% if dev %}
                <div class="diag-item">
                    <span class="status-badge {{ 'badge-working' if dev.status == 'WORKING' else ('badge-offline' if dev.offline else 'badge-idle') }}" id="badge-{{ dev.id }}">
                        {{ 'OFFLINE' if dev.offline else dev.status }}
                    </span>
                    <span id="ip-{{ dev.id }}" style="color: #4CAF50; font-family: monospace;">{{ dev.ip }}</span>
                </div>
                <div class="diag-item">
                    <span id="temp-{{ dev.id }}" style="color: #ff9800;">🌡️ {{ dev.temp }}°C</span>
                    {% set b_val = dev.battery | int(-1) %}
                    <span id="battery-{{ dev.id }}" style="color: #2196F3;" class="{{ 'battery-warning' if b_val != -1 and b_val < 80 else '' }}">
                        {{ '⚠️' if b_val != -1 and b_val < 80 else '🔋' }} {{ dev.battery }}%
                    </span>
                </div>
                {% else %}
                <div style="color: #444; text-align: center; margin-top: 15px;">Waiting for device...</div>
                {% endif %}
            </div>

            <div id="task-container-{{ dev.id if dev else 'empty-' ~ i }}">
                {% if dev and dev.current_task %}
                <div class="live-task-box">
                    <div class="live-task-dest" title="{{ dev.current_task.dest_name }}">🎯 {{ dev.current_task.dest_name }} {% if dev.dest_id %}<span style="color:#aaa; font-size:0.8em; margin-left:5px;">(#{{ dev.dest_id }})</span>{% endif %}</div>
                    <div class="live-task-meta">
                        <div class="live-task-row">
                            <span>⏱️ <span class="elapsed-timer" data-start="{{ dev.current_task.start_ts }}">-</span></span>
                            <span>🏁 
                                {% if dev.current_task.target_sec %}
                                    <span class="target-confirmed">{{ (dev.current_task.target_sec / 60) | int }}m {{ dev.current_task.target_sec % 60 }}s</span>
                                {% else %}
                                    {{ dev.current_task.target_range }}m
                                {% endif %}
                            </span>
                        </div>
                        {% if dev.current_task.total_dist_km %}
                        <div class="live-task-row" style="margin-top: 2px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 2px; font-size: 0.9em;">
                            <span style="color: #2196F3;">🛣️ {{ dev.current_task.total_dist_km }}km</span>
                            <span style="color: #ff9800;">🚀 {{ dev.current_task.avg_speed_kmh }}km/h</span>
                        </div>
                        {% endif %}
                    </div>
                </div>
                {% elif dev %}
                <div style="height: 92px; border: 1px dashed #333; border-radius: 4px; display: flex; align-items: center; justify-content: center; font-size: 0.8em; color: #555; margin-bottom: 8px; box-sizing: border-box;">
                    Ready for next task
                </div>
                {% endif %}
            </div>

            <div class="screen-container">
                {% if dev and not dev.offline %}
                <img src="" class="screen-img" id="img-{{ dev.id }}" draggable="false" 
                     onpointerdown="handlePointerDown(event, '{{ dev.id }}')" 
                     onpointerup="handlePointerUp(event, '{{ dev.id }}')">
                <div id="placeholder-{{ dev.id }}" class="offline-placeholder">
                    <span>📺</span>
                    MONITOR OFF
                </div>
                {% else %}
                <div class="offline-placeholder">
                    <span>📵</span>
                    {{ 'DEVICE DISCONNECTED' if dev else 'EMPTY' }}
                </div>
                {% endif %}
            </div>

            <div class="controls {{ 'dimmed' if not dev or dev.offline }}">
                <button class="btn-ctrl" onclick="sendKey('{{ dev.id if dev else '' }}', 3)">🏠</button>
                <button class="btn-ctrl" onclick="sendKey('{{ dev.id if dev else '' }}', 4)">⬅️</button>
                <button class="btn-ctrl" onclick="sendKey('{{ dev.id if dev else '' }}', 187)">📱</button>
            </div>
        </div>
        {% endfor %}
    </div>

    <script>
        let activePointers = {};

        function toggleMonitor(devId) {
            const img = document.getElementById('img-' + devId);
            const btn = document.getElementById('btn-mon-' + devId);
            const placeholder = document.getElementById('placeholder-' + devId);
            
            if (img.src.includes('/stream/')) {
                img.src = '';
                img.style.display = 'none';
                placeholder.style.display = 'flex';
                btn.style.background = '#607D8B';
                btn.innerText = '📺';
            } else {
                img.src = '/stream/' + devId;
                img.style.display = 'block';
                placeholder.style.display = 'none';
                btn.style.background = '#4CAF50';
                btn.innerText = '📡';
            }
        }

        function sendKey(devId, code) {
            if(!devId) return;
            fetch(`/key/${devId}?code=${code}`);
        }

        function unlockDevice(devId) {
            fetch(`/unlock/${devId}`);
        }

        function sleepDevice(devId) {
            fetch(`/sleep/${devId}`);
        }

        function rebootDevice(devId) {
            if (confirm(`Reboot device ${devId}?`)) {
                fetch(`/reboot/${devId}`);
            }
        }

        function handlePointerDown(event, devId) {
            const touchCheck = document.getElementById('touch-' + devId);
            if (!touchCheck || !touchCheck.checked) return;
            const img = document.getElementById('img-' + devId);
            img.setPointerCapture(event.pointerId);
            const rect = img.getBoundingClientRect();
            activePointers[event.pointerId] = {
                startX: (event.clientX - rect.left) / rect.width,
                startY: (event.clientY - rect.top) / rect.height,
                startTime: Date.now()
            };
        }

        function handlePointerUp(event, devId) {
            const touchCheck = document.getElementById('touch-' + devId);
            if (!touchCheck || !touchCheck.checked) return;
            const startData = activePointers[event.pointerId];
            if (!startData) return;

            const img = document.getElementById('img-' + devId);
            const rect = img.getBoundingClientRect();
            const endX = (event.clientX - rect.left) / rect.width;
            const endY = (event.clientY - rect.top) / rect.height;
            const duration = Date.now() - startData.startTime;

            const dist = Math.sqrt(Math.pow(endX - startData.startX, 2) + Math.pow(endY - startData.startY, 2));

            if (dist < 0.01 || duration < 100) {
                fetch(`/click/${devId}?x_pct=${endX}&y_pct=${endY}`);
            } else {
                fetch(`/swipe/${devId}?x1_pct=${startData.startX}&y1_pct=${startData.startY}&x2_pct=${endX}&y2_pct=${endY}`);
            }
            delete activePointers[event.pointerId];
        }

        // Seamless polling for Status
        function fetchStatus() {
            fetch('/status').then(r => r.json()).then(data => {
                data.slots.forEach((dev, i) => {
                    if (!dev) return;
                    
                    const card = document.getElementById('slot-' + i);
                    if (card) {
                        card.className = 'device-card ' + (dev.offline ? 'offline' : (dev.status === 'WORKING' ? 'working' : ''));
                    }

                    const badge = document.getElementById('badge-' + dev.id);
                    if (badge) {
                        badge.className = 'status-badge ' + (dev.offline ? 'badge-offline' : (dev.status === 'WORKING' ? 'badge-working' : 'badge-idle'));
                        badge.innerText = dev.offline ? 'OFFLINE' : dev.status;
                    }
                    
                    const ipEl = document.getElementById('ip-' + dev.id);
                    if (ipEl) ipEl.innerText = dev.ip || 'N/A';
                    
                    const tempEl = document.getElementById('temp-' + dev.id);
                    if (tempEl) tempEl.innerText = '🌡️ ' + dev.temp + '°C';
                    
                    const battEl = document.getElementById('battery-' + dev.id);
                    if (battEl) {
                        const bVal = parseInt(dev.battery);
                        if (!isNaN(bVal) && bVal < 80) {
                            battEl.innerText = '⚠️ ' + dev.battery + '%';
                            battEl.className = 'battery-warning';
                        } else {
                            battEl.innerText = '🔋 ' + dev.battery + '%';
                            battEl.className = '';
                        }
                    }

                    const taskContainer = document.getElementById('task-container-' + dev.id);
                    if (taskContainer) {
                        if (dev.current_task) {
                            const t = dev.current_task;
                            const targetSec = parseInt(t.target_sec);
                            const targetHtml = targetSec ? 
                                `<span class="target-confirmed">${Math.floor(targetSec / 60)}m ${targetSec % 60}s</span>` :
                                `${t.target_range}m`;
                            
                            let distHtml = '';
                            if (t.total_dist_km) {
                                distHtml = `<div class="live-task-row" style="margin-top: 2px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 2px; font-size: 0.9em;">
                                    <span style="color: #2196F3;">🛣️ ${t.total_dist_km}km</span>
                                    <span style="color: #ff9800;">🚀 ${t.avg_speed_kmh}km/h</span>
                                </div>`;
                            }
                            
                            const destIdStr = dev.dest_id ? `<span style="color:#aaa; font-size:0.8em; margin-left:5px;">(#${dev.dest_id})</span>` : '';

                            taskContainer.innerHTML = `
                                <div class="live-task-box">
                                    <div class="live-task-dest" title="${t.dest_name}">🎯 ${t.dest_name} ${destIdStr}</div>
                                    <div class="live-task-meta">
                                        <div class="live-task-row">
                                            <span>⏱️ <span class="elapsed-timer" data-start="${t.start_ts}">-</span></span>
                                            <span>🏁 ${targetHtml}</span>
                                        </div>
                                        ${distHtml}
                                    </div>
                                </div>`;
                        } else {
                            taskContainer.innerHTML = `
                                <div style="height: 92px; border: 1px dashed #333; border-radius: 4px; display: flex; align-items: center; justify-content: center; font-size: 0.8em; color: #555; margin-bottom: 8px; box-sizing: border-box;">
                                    Ready for next task
                                </div>`;
                        }
                    }
                });
                updateTimers();
            }).catch(e => console.error("Status fetch error", e));
        }
        setInterval(fetchStatus, 3000);

        // [NEW] Real-time Timer Update
        function updateTimers() {
            const now = Math.floor(Date.now() / 1000);
            document.querySelectorAll('.elapsed-timer').forEach(el => {
                const start = parseInt(el.getAttribute('data-start'));
                if (!isNaN(start)) {
                    const elapsed = now - start;
                    const m = Math.floor(elapsed / 60).toString().padStart(2, '0');
                    const s = (elapsed % 60).toString().padStart(2, '0');
                    el.innerText = `${m}:${s}`;
                }
            });
        }
        setInterval(updateTimers, 1000);
        updateTimers();
    </script>
</body>
</html>
"""

def get_device_diagnostics(serial):
    info = {
        "status": "IDLE",
        "ip": "N/A",
        "temp": "??",
        "battery": "??",
        "latest_log": "No Log",
        "current_task": None
    }
    
    # 1. Check Working Status (Lightweight)
    try:
        subprocess.check_output(["pgrep", "-f", f"lib/main.sh {serial}"])
        info["status"] = "WORKING"
    except:
        info["status"] = "IDLE"

    # 2. Get Battery & Temp (Cached)
    try:
        batt_raw = subprocess.check_output(["adb", "-s", serial, "shell", "dumpsys battery"], timeout=5).decode()
        for line in batt_raw.splitlines():
            if "level:" in line: info["battery"] = line.split(":")[1].strip()
            if "temperature:" in line: info["temp"] = int(line.split(":")[1].strip()) / 10
    except:
        pass

    # 3. Find Latest Task Badge (current_task.json)
    try:
        task_info_path = os.path.join(LOG_BASE_DIR, serial, "current_task.json")
        if os.path.exists(task_info_path):
            with open(task_info_path, 'r') as f:
                task_data = json.load(f)
                info["current_task"] = task_data
                info["ip"] = task_data.get("real_ip", "N/A")
                sp = task_data.get("session_path", "")
                if "_" in sp:
                    info["dest_id"] = sp.split("_")[-1]
    except:
        pass
        
    return info

def refresh_device_slots():
    global device_slots
    try:
        output = subprocess.check_output(["adb", "devices", "-l"], timeout=5).decode("utf-8")
        lines = output.strip().split("\n")[1:]
        current_connected = {}
        for line in lines:
            if not line.strip() or "device" not in line: continue
            parts = line.split()
            serial = parts[0]
            model = "Unknown"
            for p in parts:
                if p.startswith("model:"): model = p.split(":")[1]; break
            current_connected[serial] = model

        # 1. Update existing slots
        for i in range(MAX_SLOTS):
            slot = device_slots[i]
            if slot:
                if slot["id"] in current_connected:
                    slot["offline"] = False
                    slot["model"] = current_connected[slot["id"]]
                    # Update diagnostics
                    diag = get_device_diagnostics(slot["id"])
                    slot.update(diag)
                    del current_connected[slot["id"]]
                else:
                    slot["offline"] = True

        # 2. Assign new devices to empty or offline slots
        for serial, model in current_connected.items():
            # Find first None or Offline slot
            assigned = False
            for i in range(MAX_SLOTS):
                if device_slots[i] is None or device_slots[i].get("offline"):
                    diag = get_device_diagnostics(serial)
                    device_slots[i] = {"id": serial, "model": model, "offline": False, **diag}
                    assigned = True
                    break
    except:
        pass

def diag_background_thread():
    while True:
        refresh_device_slots()
        time.sleep(10) # 10초마다 무거운 진단 갱신

# 초기 1회 실행 후 스레드 시작
refresh_device_slots()
threading.Thread(target=diag_background_thread, daemon=True).start()

@app.route('/')
def index():
    hostname = socket.gethostname()
    return render_template_string(HTML_TEMPLATE, slots=device_slots, MAX_SLOTS=MAX_SLOTS, hostname=hostname)

@app.route('/status')
def status():
    # Return the current parsed device states for seamless AJAX updates
    return jsonify({"slots": device_slots})

@app.route('/click/<dev_id>')
def click(dev_id):
    x_pct = float(request.args.get('x_pct', 0))
    y_pct = float(request.args.get('y_pct', 0))
    try:
        out = subprocess.check_output(["adb", "-s", dev_id, "shell", "wm size"], timeout=5).decode("utf-8")
        size = out.split(":")[-1].strip().split("x")
        w, h = int(size[0]), int(size[1])
        tx, ty = int(w * x_pct), int(h * y_pct)
        subprocess.Popen(["adb", "-s", dev_id, "shell", "input", "tap", str(tx), str(ty)])
    except: pass
    return "OK"

@app.route('/swipe/<dev_id>')
def swipe(dev_id):
    x1_pct = float(request.args.get('x1_pct', 0))
    y1_pct = float(request.args.get('y1_pct', 0))
    x2_pct = float(request.args.get('x2_pct', 0))
    y2_pct = float(request.args.get('y2_pct', 0))
    try:
        out = subprocess.check_output(["adb", "-s", dev_id, "shell", "wm size"], timeout=5).decode("utf-8")
        size = out.split(":")[-1].strip().split("x")
        w, h = int(size[0]), int(size[1])
        tx1, ty1 = int(w * x1_pct), int(h * y1_pct)
        tx2, ty2 = int(w * x2_pct), int(h * y2_pct)
        subprocess.Popen(["adb", "-s", dev_id, "shell", "input", "swipe", str(tx1), str(ty1), str(tx2), str(ty2), "300"])
    except: pass
    return "OK"

@app.route('/key/<dev_id>')
def key(dev_id):
    code = request.args.get('code', 3)
    subprocess.Popen(["adb", "-s", dev_id, "shell", "input", "keyevent", str(code)])
    return "OK"

@app.route('/unlock/<dev_id>')
def unlock(dev_id):
    subprocess.Popen(["adb", "-s", dev_id, "shell", "input", "keyevent", "224"])
    subprocess.Popen(["adb", "-s", dev_id, "shell", "wm", "dismiss-keyguard"])
    subprocess.Popen(["adb", "-s", dev_id, "shell", "input", "swipe", "500", "1500", "500", "200", "300"])
    return "OK"

@app.route('/sleep/<dev_id>')
def sleep(dev_id):
    subprocess.Popen(["adb", "-s", dev_id, "shell", "input", "keyevent", "223"])
    return "OK"

@app.route('/reboot/<dev_id>')
def reboot(dev_id):
    subprocess.Popen(["adb", "-s", dev_id, "reboot"])
    return "OK"

def gen_frames(dev_id):
    while True:
        try:
            # -p 옵션으로 압축된 png 추출 (대역폭 절약)
            cmd = ["adb", "-s", dev_id, "exec-out", "screencap", "-p"]
            frame = subprocess.check_output(cmd, timeout=5)
            yield (b'--frame\r\n'
                   b'Content-Type: image/png\r\n\r\n' + frame + b'\r\n')
            time.sleep(REFRESH_INTERVAL)
        except:
            time.sleep(1) # 에러 시 잠시 대기
            continue

@app.route('/stream/<dev_id>')
def stream(dev_id):
    return Response(gen_frames(dev_id),
                    mimetype='multipart/x-mixed-replace; boundary=frame')

if __name__ == "__main__":
    app.run(host='0.0.0.0', port=PORT, threaded=True)
