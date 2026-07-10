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

# Find initial connected devices count to dynamically set MAX_SLOTS
def get_connected_devices_count():
    try:
        output = subprocess.check_output(["adb", "devices"], timeout=3).decode("utf-8")
        lines = output.strip().split("\n")[1:]
        count = sum(1 for line in lines if line.strip() and "device" in line)
        return max(10, count)
    except:
        return 10

MAX_SLOTS = get_connected_devices_count()
LOG_BASE_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "wifi_multi", "logs")

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
    <link rel="icon" href="data:;base64,iVBORw0KGgo=">
    <style>
        :root {
            --bg-color: #121212;
            --text-color: #eee;
            --card-bg: #1e1e1e;
            --card-border: #333;
            --text-muted: #aaa;
            --timer-color: #ffeb3b;
            --btn-ctrl-bg: #333;
            --btn-ctrl-color: white;
            --badge-idle-bg: #424242;
            --badge-idle-color: #bbb;
        }
        body.light-theme {
            --bg-color: #f5f5f5;
            --text-color: #111;
            --card-bg: #ffffff;
            --card-border: #ddd;
            --text-muted: #555;
            --timer-color: #d32f2f;
            --btn-ctrl-bg: #e0e0e0;
            --btn-ctrl-color: #333;
            --badge-idle-bg: #e0e0e0;
            --badge-idle-color: #555;
        }
        body { background: var(--bg-color); color: var(--text-color); font-family: sans-serif; margin: 0; padding: 10px; transition: background 0.3s, color 0.3s; }
        .container { display: grid; grid-template-columns: repeat(auto-fill, 326px); gap: 15px; max-width: 1800px; margin: 0 auto; justify-content: center; }
        .device-card { background: var(--card-bg); border-radius: 8px; padding: 10px; border: 1px solid var(--card-border); text-align: center; width: 326px; height: 865px; display: flex; flex-direction: column; box-sizing: border-box; overflow: hidden; transition: background 0.3s, border-color 0.3s; }
        .device-card.working { border-color: #4CAF50; box-shadow: 0 0 10px rgba(76, 175, 80, 0.2); }
        .device-card.offline { opacity: 0.5; border-color: #f44336; }
        
        .top-navbar { position: sticky; top: 0; z-index: 1000; background: rgba(30, 30, 30, 0.95); backdrop-filter: blur(5px); padding: 12px 20px; border-bottom: 1px solid #333; margin-bottom: 20px; display: flex; justify-content: space-between; align-items: center; box-sizing: border-box; flex-wrap: wrap; gap: 10px; width: 100%; transition: background 0.3s, border-color 0.3s; }
        body.light-theme .top-navbar { background: rgba(255, 255, 255, 0.95); border-bottom: 1px solid #ddd; }
        body.light-theme .active-screens-badge { background: #e0e0e0 !important; color: #111 !important; }
        body.light-theme #theme-btn { border-color: #bbb; color: #111; }

        .card-header { display: flex; justify-content: space-between; align-items: center; padding: 0 5px; height: 35px; flex-shrink: 0; }
        .device-id { font-weight: bold; color: #4CAF50; font-size: 0.85em; line-height: 1.2; text-align: left; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 170px; }
        .device-id-clickable { cursor: pointer; transition: color 0.2s, opacity 0.2s; }
        .device-id-clickable:hover { color: #81C784; opacity: 0.85; }
        .header-buttons { display: flex; gap: 5px; align-items: center; }
        .header-buttons button { padding: 3px 5px; font-size: 0.75em; border-radius: 4px; border: none; cursor: pointer; color: white; min-width: 24px; }
        .touch-label { background: #333; padding: 4px 6px; border-radius: 4px; display: flex; align-items: center; cursor: pointer; font-size: 0.8em; }
        
        .diag-overlay { background: rgba(0,0,0,0.7); padding: 4px 6px; border-radius: 4px; margin-bottom: 5px; font-size: 0.72em; text-align: left; display: flex; flex-direction: column; gap: 2px; height: 63px; box-sizing: border-box; transition: background 0.3s, border-color 0.3s; }
        body.light-theme .diag-overlay { background: rgba(240, 240, 240, 0.9); border: 1px solid #ddd; }
        .diag-item { display: flex; justify-content: space-between; }
        .status-badge { padding: 2px 6px; border-radius: 10px; font-weight: bold; font-size: 0.8em; }
        .badge-working { background: #2E7D32; color: white; }
        .badge-idle { background: var(--badge-idle-bg); color: var(--badge-idle-color); }
        .badge-offline { background: #d32f2f; color: white; }
        .badge-cooldown { background: #E65100; color: white; }
        .badge-penalty { background: #4A148C; color: white; }
        .badge-unauthorized { background: #555555; color: white; }
        
        .battery-warning { color: #f44336 !important; font-weight: bold; animation: pulse-red 1s infinite; text-shadow: 0 0 5px rgba(244, 67, 54, 0.8); }
        @keyframes pulse-red { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }

        /* [NEW] Live Task Info Styles */
        .live-task-box { background: rgba(76, 175, 80, 0.1); border: 1px solid rgba(76, 175, 80, 0.3); border-radius: 4px; padding: 6px; margin-bottom: 8px; text-align: left; font-size: 0.85em; height: 74px; box-sizing: border-box; }
        .live-task-dest { color: #4CAF50; font-weight: bold; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; margin-bottom: 2px; }
        .live-task-meta { display: flex; flex-direction: column; gap: 1px; color: var(--text-muted); font-size: 0.85em; }
        .live-task-row { display: flex; justify-content: space-between; }
        .elapsed-timer { color: var(--timer-color); font-family: monospace; font-weight: bold; }
        .target-confirmed { color: #4CAF50; font-weight: bold; }

        .screen-container { position: relative; width: 306px; height: 610px; margin: 0 auto; display: flex; align-items: center; justify-content: center; background: #000; border-radius: 4px; overflow: hidden; flex-shrink: 0; }
        .screen-img { width: 306px; height: 610px; object-fit: contain; display: none; }
        
        .offline-placeholder { color: #555; font-size: 1.2em; font-weight: bold; display: flex; flex-direction: column; gap: 10px; }

        .controls { margin-top: auto; display: flex; gap: 8px; justify-content: center; padding: 10px 0; flex-shrink: 0; }
        button.btn-ctrl { padding: 8px 12px; cursor: pointer; background: var(--btn-ctrl-bg); color: var(--btn-ctrl-color); border: none; border-radius: 4px; font-weight: bold; font-size: 1.2em; transition: background 0.3s, color 0.3s; }
        
        .dimmed { opacity: 0.3; pointer-events: none; }
        
        /* Single Device Mode Styles */
        body.single-device {
            margin: 0;
            padding: 0;
            width: 100vw;
            height: 100vh;
            overflow: hidden;
            background: #121212;
        }
        body.single-device .container {
            display: flex;
            width: 100vw;
            height: 100vh;
            max-width: 100vw;
            margin: 0;
            padding: 0;
            justify-content: center;
            align-items: center;
        }
        body.single-device .device-card {
            width: 100vw;
            height: 100vh;
            border: none;
            border-radius: 0;
            padding: 10px;
            box-sizing: border-box;
            background: #121212;
        }
        body.single-device .screen-container {
            width: 100%;
            height: 0;
            flex-grow: 1;
            display: flex;
            align-items: center;
            justify-content: center;
            overflow: hidden;
        }
        body.single-device .screen-img {
            max-width: 100%;
            max-height: 100%;
            width: auto;
            height: auto;
            aspect-ratio: 9 / 19;
            object-fit: contain;
        }
    </style>
</head>
<body class="{{ 'single-device' if target_device_id else '' }}">
    {% if not target_device_id %}
    <div class="top-navbar">
        <h2 style="margin: 0; font-size: 1.05em; color: #4CAF50; display: flex; align-items: center; gap: 4px; flex-wrap: wrap; font-weight: bold;">
            [ {{ hostname }} ]
            <span id="farm-summary" style="font-size: 0.85em; color: #aaa; font-weight: normal; margin-left: 5px;">
                (연결: -대 | 동작: - | 대기: - | 오프라인: -)
            </span>
        </h2>
        <div style="display: flex; gap: 15px; align-items: center; flex-wrap: wrap;">
            <span class="active-screens-badge" style="font-size: 0.9em; background: #333; padding: 6px 12px; border-radius: 4px; color: #ffeb3b; font-weight: bold;">
                📺 활성 화면: <span id="active-screen-count">0</span> (최대 5개 권장)
            </span>
            <button onclick="unlockAllDevices()" style="background: #2196F3; color: white; border: none; padding: 6px 12px; border-radius: 4px; cursor: pointer; font-weight: bold; font-size: 0.9em;">
                🔓 전체 잠금 해제
            </button>
            <button onclick="setThemeAllDevices('dark')" style="background: transparent; border: 1px solid #555; color: white; padding: 6px; border-radius: 50%; cursor: pointer; font-size: 1.1em; display: inline-flex; align-items: center; justify-content: center; width: 34px; height: 34px; box-sizing: border-box;" title="전체 기기 다크모드 일괄 적용">🌙</button>
            <button onclick="setThemeAllDevices('light')" style="background: transparent; border: 1px solid #555; color: white; padding: 6px; border-radius: 50%; cursor: pointer; font-size: 1.1em; display: inline-flex; align-items: center; justify-content: center; width: 34px; height: 34px; box-sizing: border-box;" title="전체 기기 라이트모드 일괄 적용">☀️</button>
            <button onclick="closeAllMonitors()" style="background: #f44336; color: white; border: none; padding: 6px 12px; border-radius: 4px; cursor: pointer; font-weight: bold; font-size: 0.9em;">
                ❌ 전체 화면 닫기
            </button>
        </div>
    </div>
    {% endif %}
    <div class="container" id="device-container">
        {% for i in range(MAX_SLOTS) %}
        {% set dev = slots[i] %}
        {% set is_target = (not target_device_id) or (dev and dev.id == target_device_id) %}
        <div class="device-card {{ 'working' if dev and dev.status == 'WORKING' }} {{ 'offline' if not dev or dev.offline }}" id="slot-{{ i }}" style="display: {{ 'flex' if is_target else 'none' }};">
            <div class="card-header {{ 'dimmed' if not dev or dev.offline }}" id="header-{{ i }}">
                <span class="device-id" id="dev-name-{{ i }}">
                    <span style="color: #ffeb3b; font-weight: bold; margin-right: 5px;">#{{ "%02d" | format(i + 1) }}</span>
                    {% if dev and not dev.offline %}
                    <span class="device-id-clickable" onclick="copyDevId('{{ dev.id }}', 'dev-id-txt-{{ i }}')" id="dev-id-txt-{{ i }}" title="클릭하여 디바이스 ID 복사">{{ dev.id }}</span>
                    {% else %}
                    <span>{{ dev.id if dev else 'EMPTY SLOT' }}</span>
                    {% endif %}
                </span>
                <div class="header-buttons" id="header-btns-{{ i }}" style="display: {{ 'flex' if dev and not dev.offline else 'none' }};">
                    <button id="btn-mon-{{ i }}" onclick="toggleMonitor({{ i }})" style="background: #607D8B;" title="Toggle Monitor">📺</button>
                    <button onclick="unlockDevice({{ i }})" style="background: #2196F3;" title="Wake/Unlock">🔓</button>
                    <button onclick="rebootDevice({{ i }})" style="background: #f44336;" title="Reboot">🔄</button>
                </div>
            </div>
            
            <div class="diag-overlay" style="height: 63px;">
                <div class="diag-item">
                    {% set is_active = dev and dev.status != 'IDLE' and not dev.offline %}
                    <span class="status-badge {{ 'badge-offline' if not dev or dev.offline else ('badge-cooldown' if dev.status in ['IP_COOLDOWN', 'COOLDOWN'] else ('badge-penalty' if dev.status == 'PENALTY' else ('badge-unauthorized' if dev.status == 'UNAUTHORIZED' else ('badge-working' if is_active else 'badge-idle')))) }}" id="badge-{{ i }}">
                        {{ 'OFFLINE' if not dev or dev.offline else (dev.status if dev.status else 'IDLE') }}
                    </span>
                    <span id="model-{{ i }}" style="color: #888; margin-left: auto;">{{ dev.model if dev else 'N/A' }}</span>
                </div>
                <div class="diag-item">
                    <span id="ip-{{ i }}" style="color: #4CAF50;">{{ dev.ip if dev else 'N/A' }}</span>
                    <span style="margin-left: auto; display: flex; gap: 8px;">
                        <span id="temp-{{ i }}" style="color: #ff9800;">🌡️ {{ dev.temp if dev else '??' }}°C</span>
                        {% set b_val = (dev.battery | int(-1)) if dev else -1 %}
                        <span id="battery-{{ i }}" style="color: #2196F3;" class="{{ 'battery-warning' if b_val != -1 and b_val < 80 else '' }}">
                            🔋 {{ dev.battery if dev else '??' }}%
                        </span>
                    </span>
                </div>
                <div class="diag-item" style="overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: #888;">
                    📝 <span id="log-{{ i }}" style="margin-left: 2px;">{{ dev.latest_log if dev else '-' }}</span>
                </div>
            </div>

            <div id="task-container-{{ i }}">
                {% if dev and dev.current_task %}
                {% set is_success = dev.current_task.status == 'SUCCESS' %}
                <div class="live-task-box" style="{{ 'border-color: rgba(76, 175, 80, 0.6); background: rgba(76, 175, 80, 0.05);' if is_success }}">
                    <div class="live-task-dest" title="{{ dev.current_task.dest_name }}">🎯 {{ dev.current_task.dest_name }} {% if dev.dest_id %}<span style="color:#aaa; font-size:0.8em; margin-left:5px;">(#{{ dev.dest_id }})</span>{% endif %}</div>
                    <div class="live-task-meta">
                        <div class="live-task-row">
                            <span>
                                {% if is_success %}
                                    <span style="color: #4CAF50; font-weight: bold;">✅ 완료</span>
                                {% else %}
                                    ⏱️ <span class="elapsed-timer" data-start="{{ dev.current_task.start_ts }}">-</span>
                                {% endif %}
                            </span>
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
                            <span style="color: #2196F3;">🛣️ {{ dev.current_task.total_dist_km }}km {% if dev.current_task.remaining_dist_km and not is_success %}(남음: {{ dev.current_task.remaining_dist_km }}km){% endif %}</span>
                            <span style="color: #ff9800;">🚀 {{ dev.current_task.avg_speed_kmh }}km/h</span>
                        </div>
                        {% endif %}
                    </div>
                </div>
                {% else %}
                <div style="height: 74px; border: 1px dashed #333; border-radius: 4px; display: flex; align-items: center; justify-content: center; font-size: 0.8em; color: #555; margin-bottom: 8px; box-sizing: border-box;">
                    {{ 'Ready for next task' if dev else 'Waiting for device...' }}
                </div>
                {% endif %}
            </div>

            <div class="screen-container">
                <img src="" class="screen-img" id="img-{{ i }}" draggable="false" 
                     onload="adjustAspectRatio(this)" 
                     onpointerdown="handlePointerDown(event, {{ i }})" 
                     onpointerup="handlePointerUp(event, {{ i }})">
                <div id="placeholder-{{ i }}" class="offline-placeholder">
                    {% if dev and not dev.offline %}
                    <span>📺</span>
                    MONITOR OFF
                    {% else %}
                    <span>📵</span>
                    {{ 'DEVICE DISCONNECTED' if dev else 'EMPTY' }}
                    {% endif %}
                </div>
            </div>

            <div class="controls {{ 'dimmed' if not dev or dev.offline }}" id="controls-{{ i }}">
                <button class="btn-ctrl" onclick="sendKey({{ i }}, 3)">🏠</button>
                <button class="btn-ctrl" onclick="sendKey({{ i }}, 4)">⬅️</button>
                <button class="btn-ctrl" onclick="sendKey({{ i }}, 187)">📱</button>
            </div>
        </div>
        {% endfor %}
    </div>

    <script>
        const targetDeviceId = '{{ target_device_id }}';
        function adjustAspectRatio(img) {
            if (img.naturalWidth && img.naturalHeight) {
                img.style.aspectRatio = img.naturalWidth + ' / ' + img.naturalHeight;
            }
        }
        let activePointers = {};
        let slotDeviceIds = [
            {% for i in range(MAX_SLOTS) %}
                {% if slots[i] %}'{{ slots[i].id }}'{% else %}null{% endif %}{% if not loop.last %},{% endif %}
            {% endfor %}
        ];

        function updateActiveScreenCount() {
            let count = 0;
            for (let i = 0; i < slotDeviceIds.length; i++) {
                const img = document.getElementById('img-' + i);
                if (img && img.src && img.src.includes('/stream/')) {
                    count++;
                }
            }
            const el = document.getElementById('active-screen-count');
            if (el) {
                el.innerText = count;
                if (count >= 5) {
                    el.style.color = '#f44336';
                } else {
                    el.style.color = '#ffeb3b';
                }
            }
        }

        function unlockAllDevices() {
            let count = 0;
            for (let i = 0; i < slotDeviceIds.length; i++) {
                const devId = slotDeviceIds[i];
                if (devId) {
                    count++;
                    fetch(`/unlock/${devId}`);
                }
            }
            alert(`총 ${count}대의 기기에 잠금 해제 명령을 보냈습니다.`);
        }

        let activeMonitorsQueue = [];

        function closeAllMonitors() {
            activeMonitorsQueue = [];
            for (let i = 0; i < slotDeviceIds.length; i++) {
                const img = document.getElementById('img-' + i);
                if (img && img.src && img.src.includes('/stream/')) {
                    img.src = '';
                    img.style.display = 'none';
                    const placeholder = document.getElementById('placeholder-' + i);
                    if (placeholder) {
                        placeholder.style.display = 'flex';
                        placeholder.innerHTML = '<span>📺</span>MONITOR OFF';
                    }
                    const btn = document.getElementById('btn-mon-' + i);
                    if (btn) {
                        btn.style.background = '#607D8B';
                        btn.innerText = '📺';
                    }
                }
            }
            updateActiveScreenCount();
        }

        function toggleMonitor(slotIdx) {
            const devId = slotDeviceIds[slotIdx];
            if (!devId) return;
            const img = document.getElementById('img-' + slotIdx);
            const btn = document.getElementById('btn-mon-' + slotIdx);
            const placeholder = document.getElementById('placeholder-' + slotIdx);
            
            if (img.src.includes('/stream/')) {
                img.src = '';
                img.style.display = 'none';
                placeholder.style.display = 'flex';
                placeholder.innerHTML = '<span>📺</span>MONITOR OFF';
                btn.style.background = '#607D8B';
                btn.innerText = '📺';
                
                // Remove from queue
                activeMonitorsQueue = activeMonitorsQueue.filter(idx => idx !== slotIdx);
            } else {
                // Auto-close oldest if limit of 5 is exceeded
                while (activeMonitorsQueue.length >= 5) {
                    const oldestIdx = activeMonitorsQueue.shift();
                    const oldImg = document.getElementById('img-' + oldestIdx);
                    const oldBtn = document.getElementById('btn-mon-' + oldestIdx);
                    const oldPlaceholder = document.getElementById('placeholder-' + oldestIdx);
                    if (oldImg) {
                        oldImg.src = '';
                        oldImg.style.display = 'none';
                    }
                    if (oldPlaceholder) {
                        oldPlaceholder.style.display = 'flex';
                        oldPlaceholder.innerHTML = '<span>📺</span>MONITOR OFF';
                    }
                    if (oldBtn) {
                        oldBtn.style.background = '#607D8B';
                        oldBtn.innerText = '📺';
                    }
                }
                
                img.src = '/stream/' + devId;
                img.style.display = 'block';
                placeholder.style.display = 'none';
                btn.style.background = '#4CAF50';
                btn.innerText = '📡';
                
                // Add to queue
                activeMonitorsQueue.push(slotIdx);
            }
            updateActiveScreenCount();
        }

        function sendKey(slotIdx, code) {
            const devId = slotDeviceIds[slotIdx];
            if(!devId) return;
            fetch(`/key/${devId}?code=${code}`);
        }

        function unlockDevice(slotIdx) {
            const devId = slotDeviceIds[slotIdx];
            if(!devId) return;
            fetch(`/unlock/${devId}`);
        }

        function sleepDevice(slotIdx) {
            const devId = slotDeviceIds[slotIdx];
            if(!devId) return;
            fetch(`/sleep/${devId}`);
        }

        function rebootDevice(slotIdx) {
            const devId = slotDeviceIds[slotIdx];
            if(!devId) return;
            if (confirm(`Reboot device ${devId}?`)) {
                fetch(`/reboot/${devId}`);
            }
        }

        function setThemeAllDevices(mode) {
            const modeText = mode === 'dark' ? '다크(🌙)' : '라이트(☀️)';
            if (confirm(`연결된 모든 단말기 화면을 일괄적으로 ${modeText} 모드로 변경하시겠습니까?`)) {
                fetch(`/set_theme_all/${mode}`);
            }
        }

        function resetDevicePenalty(serial) {
            // 즉시 백그라운드 슛 쏘기 (컨펌 및 알림 팝업 없음)
            fetch('/api/reset_device_penalty', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({ serial: serial })
            });
            
            // 리턴 대기 없이 100ms 뒤 즉각 화면 갱신 (로컬 current_task.json이 리셋되므로 바로 풀림!)
            setTimeout(() => {
                fetchStatus();
            }, 100);
        }

        function copyDevId(devId, elementId) {
            if (!devId || devId === "EMPTY SLOT") return;
            
            const copySuccess = () => {
                const txtEl = document.getElementById(elementId);
                if (!txtEl) return;
                const originalText = txtEl.innerHTML;
                txtEl.innerHTML = `<span style="color: #81C784; font-weight: bold;">✓ 복사완료!</span>`;
                setTimeout(() => {
                    txtEl.innerHTML = originalText;
                }, 800);
            };

            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(devId).then(copySuccess).catch(err => {
                    console.error("Modern copy failed, trying fallback:", err);
                    fallbackCopyText(devId, copySuccess);
                });
            } else {
                fallbackCopyText(devId, copySuccess);
            }
        }

        function fallbackCopyText(text, callback) {
            const textArea = document.createElement("textarea");
            textArea.value = text;
            textArea.style.position = "fixed";
            textArea.style.left = "-999999px";
            textArea.style.top = "-999999px";
            document.body.appendChild(textArea);
            textArea.focus();
            textArea.select();
            try {
                const successful = document.execCommand('copy');
                if (successful) {
                    callback();
                } else {
                    console.error('Fallback copy command failed');
                }
            } catch (err) {
                console.error('Fallback copy exception:', err);
            }
            document.body.removeChild(textArea);
        }

        function handlePointerDown(event, slotIdx) {
            const img = document.getElementById('img-' + slotIdx);
            img.setPointerCapture(event.pointerId);
            const rect = img.getBoundingClientRect();
            activePointers[event.pointerId] = {
                startX: (event.clientX - rect.left) / rect.width,
                startY: (event.clientY - rect.top) / rect.height,
                startTime: Date.now()
            };
        }

        function handlePointerUp(event, slotIdx) {
            const devId = slotDeviceIds[slotIdx];
            if(!devId) return;
            const startData = activePointers[event.pointerId];
            if (!startData) return;

            const img = document.getElementById('img-' + slotIdx);
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

        function createSlotHtml(i) {
            return `
            <div class="device-card offline" id="slot-${i}">
                <div class="card-header dimmed" id="header-${i}">
                    <span class="device-id" id="dev-name-${i}"><span style="color: #ffeb3b; font-weight: bold; margin-right: 5px;">#${String(i + 1).padStart(2, '0')}</span> EMPTY SLOT</span>
                    <div class="header-buttons" id="header-btns-${i}" style="display: none;">
                        <button id="btn-mon-${i}" onclick="toggleMonitor(${i})" style="background: #607D8B;" title="Toggle Monitor">📺</button>
                        <button onclick="unlockDevice(${i})" style="background: #2196F3;" title="Wake/Unlock">🔓</button>
                        <button onclick="rebootDevice(${i})" style="background: #f44336;" title="Reboot">🔄</button>
                    </div>
                </div>
                
                <div class="diag-overlay" style="height: 63px;">
                    <div class="diag-item">
                        <span class="status-badge badge-offline" id="badge-${i}">OFFLINE</span>
                        <span id="model-${i}" style="color: #888; margin-left: auto;">N/A</span>
                    </div>
                    <div class="diag-item">
                        <span id="ip-${i}" style="color: #4CAF50;">N/A</span>
                        <span style="margin-left: auto; display: flex; gap: 8px;">
                            <span id="temp-${i}" style="color: #ff9800;">🌡️ ??°C</span>
                            <span id="battery-${i}" style="color: #2196F3;">🔋 ??%</span>
                        </span>
                    </div>
                    <div class="diag-item" style="overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: #888;">
                        📝 <span id="log-${i}" style="margin-left: 2px;">-</span>
                    </div>
                </div>

                <div id="task-container-${i}">
                    <div style="height: 74px; border: 1px dashed #333; border-radius: 4px; display: flex; align-items: center; justify-content: center; font-size: 0.8em; color: #555; margin-bottom: 8px; box-sizing: border-box;">
                        Ready for next task
                    </div>
                </div>

                <div class="screen-container">
                    <img src="" class="screen-img" id="img-${i}" draggable="false" 
                         onload="adjustAspectRatio(this)" 
                         onpointerdown="handlePointerDown(event, ${i})" 
                         onpointerup="handlePointerUp(event, ${i})">
                    <div id="placeholder-${i}" class="offline-placeholder">
                        <span>📵</span>
                        EMPTY
                    </div>
                </div>

                <div class="controls dimmed" id="controls-${i}">
                    <button class="btn-ctrl" onclick="sendKey(${i}, 3)">🏠</button>
                    <button class="btn-ctrl" onclick="sendKey(${i}, 4)">⬅️</button>
                    <button class="btn-ctrl" onclick="sendKey(${i}, 187)">📱</button>
                </div>
            </div>`;
        }

        // Seamless polling for Status
        function fetchStatus() {
            fetch('/status').then(r => r.json()).then(data => {
                const container = document.getElementById('device-container');
                data.slots.forEach((dev, i) => {
                    // slots 크기 증가 시 dynamic element 생성
                    if (i >= slotDeviceIds.length) {
                        slotDeviceIds.push(null);
                        const newSlotHtml = createSlotHtml(i);
                        container.insertAdjacentHTML('beforeend', newSlotHtml);
                    }
                    
                    const oldDevId = slotDeviceIds[i];
                    const newDevId = dev ? dev.id : null;
                    slotDeviceIds[i] = newDevId;

                    const card = document.getElementById('slot-' + i);
                    
                    // Check if it is the target device
                    const isTarget = !targetDeviceId || (newDevId === targetDeviceId);
                    if (card) {
                        card.style.display = isTarget ? 'flex' : 'none';
                    }
                    const header = document.getElementById('header-' + i);
                    const devName = document.getElementById('dev-name-' + i);
                    const headerBtns = document.getElementById('header-btns-' + i);
                    const badge = document.getElementById('badge-' + i);
                    const modelEl = document.getElementById('model-' + i);
                    const ipEl = document.getElementById('ip-' + i);
                    const tempEl = document.getElementById('temp-' + i);
                    const battEl = document.getElementById('battery-' + i);
                    const taskContainer = document.getElementById('task-container-' + i);
                    const controls = document.getElementById('controls-' + i);
                    const img = document.getElementById('img-' + i);
                    const placeholder = document.getElementById('placeholder-' + i);
                    const logEl = document.getElementById('log-' + i);

                    // 디바이스 변경 감지 시 모니터 초기화
                    if (oldDevId !== newDevId) {
                        if (img) {
                            img.src = '';
                            img.style.display = 'none';
                        }
                        if (placeholder) {
                            placeholder.style.display = 'flex';
                            if (newDevId) {
                                placeholder.innerHTML = '<span>📺</span>MONITOR OFF';
                            } else {
                                placeholder.innerHTML = '<span>📵</span>EMPTY';
                            }
                        }
                        const btnMon = document.getElementById('btn-mon-' + i);
                        if (btnMon) {
                            btnMon.style.background = '#607D8B';
                            btnMon.innerText = '📺';
                        }
                    }

                    // Auto-start stream for target device if it's online
                    if (targetDeviceId && newDevId === targetDeviceId && dev && !dev.offline) {
                        if (img && !img.src.includes('/stream/')) {
                            toggleMonitor(i);
                        }
                    }

                    if (!dev) {
                        // EMPTY SLOT 상태로 만들기
                        if (card) card.className = 'device-card offline';
                        if (header) header.className = 'card-header dimmed';
                        if (devName) devName.innerHTML = `<span style="color: #ffeb3b; font-weight: bold; margin-right: 5px;">#${String(i + 1).padStart(2, '0')}</span> EMPTY SLOT`;
                        if (headerBtns) headerBtns.style.display = 'none';
                        if (badge) {
                            badge.className = 'status-badge badge-offline';
                            badge.innerText = 'OFFLINE';
                        }
                        if (modelEl) modelEl.innerText = 'N/A';
                        if (ipEl) ipEl.innerText = 'N/A';
                        if (tempEl) tempEl.innerText = '🌡️ ??°C';
                        if (battEl) {
                            battEl.innerText = '🔋 ??%';
                            battEl.className = '';
                        }
                        if (taskContainer) {
                            taskContainer.innerHTML = `
                                <div style="height: 74px; border: 1px dashed #333; border-radius: 4px; display: flex; align-items: center; justify-content: center; font-size: 0.8em; color: #555; margin-bottom: 8px; box-sizing: border-box;">
                                    Waiting for device...
                                </div>`;
                        }
                        if (controls) controls.className = 'controls dimmed';
                        if (placeholder) {
                            placeholder.innerHTML = '<span>📵</span>EMPTY';
                        }
                        if (logEl) logEl.innerText = '-';
                        return;
                    }

                    // 디바이스가 있는 경우
                    const isTaskActive = dev.status && dev.status !== 'IDLE' && dev.status !== 'SUCCESS' && dev.status !== 'ARRIVED';
                    if (card) {
                        card.className = 'device-card ' + (dev.offline ? 'offline' : (isTaskActive ? 'working' : ''));
                    }
                    if (header) {
                        header.className = 'card-header ' + (dev.offline ? 'dimmed' : '');
                    }
                    if (devName) {
                        if (dev.offline) {
                            devName.innerHTML = `<span style="color: #ffeb3b; font-weight: bold; margin-right: 5px;">#${String(i + 1).padStart(2, '0')}</span> ${dev.id || 'Unknown'}`;
                        } else {
                            devName.innerHTML = `<span style="color: #ffeb3b; font-weight: bold; margin-right: 5px;">#${String(i + 1).padStart(2, '0')}</span><span class="device-id-clickable" onclick="copyDevId('${dev.id}', 'dev-id-txt-${i}')" id="dev-id-txt-${i}" title="클릭하여 디바이스 ID 복사">${dev.id || 'Unknown'}</span>`;
                        }
                    }
                    if (modelEl) {
                        modelEl.innerText = dev.model || 'N/A';
                    }
                    if (headerBtns) {
                        headerBtns.style.display = dev.offline ? 'none' : 'flex';
                    }
                    if (badge) {
                        let badgeClass = 'badge-idle';
                        if (dev.offline) {
                            badgeClass = 'badge-offline';
                        } else if (dev.status === 'IP_COOLDOWN' || dev.status === 'COOLDOWN') {
                            badgeClass = 'badge-cooldown';
                        } else if (dev.status === 'PENALTY') {
                            badgeClass = 'badge-penalty';
                        } else if (dev.status === 'UNAUTHORIZED') {
                            badgeClass = 'badge-unauthorized';
                        } else if (dev.status && dev.status !== 'IDLE') {
                            badgeClass = 'badge-working';
                        }
                        badge.className = 'status-badge ' + badgeClass;
                        badge.innerText = dev.offline ? 'OFFLINE' : (dev.status || 'IDLE');
                    }
                    if (ipEl) ipEl.innerText = dev.ip || 'N/A';
                    if (tempEl) tempEl.innerText = '🌡️ ' + (dev.temp || '??') + '°C';
                    
                    if (battEl) {
                        const bVal = parseInt(dev.battery);
                        if (!isNaN(bVal)) {
                            if (bVal < 80) {
                                battEl.innerText = '⚠️ ' + dev.battery + '%';
                                battEl.className = 'battery-warning';
                            } else {
                                battEl.innerText = '🔋 ' + dev.battery + '%';
                                battEl.className = '';
                            }
                        } else {
                            battEl.innerText = '🔋 ' + (dev.battery || '??') + '%';
                            battEl.className = '';
                        }
                    }

                    if (logEl) {
                        logEl.innerText = dev.latest_log || '-';
                    }

                    if (taskContainer) {
                        if (dev.current_task) {
                            const t = dev.current_task;
                            const isSuccess = (t.status === 'SUCCESS');
                            
                            const targetSec = parseInt(t.target_sec);
                            const targetHtml = targetSec ? 
                                `<span class="target-confirmed">${Math.floor(targetSec / 60)}m ${targetSec % 60}s</span>` :
                                `${t.target_range || '??'}m`;
                            
                            let distHtml = '';
                            if (t.total_dist_km) {
                                const remDistStr = (t.remaining_dist_km && t.remaining_dist_km > 0 && !isSuccess) ? ` (남음: ${t.remaining_dist_km}km)` : '';
                                distHtml = `<div class="live-task-row" style="margin-top: 2px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 2px; font-size: 0.9em;">
                                    <span style="color: #2196F3;">🛣️ ${t.total_dist_km}km${remDistStr}</span>
                                    <span style="color: #ff9800;">🚀 ${t.avg_speed_kmh || '??'}km/h</span>
                                </div>`;
                            }
                            
                            const destIdStr = dev.dest_id ? `<span style="color:#aaa; font-size:0.8em; margin-left:5px;">(#${dev.dest_id})</span>` : '';
                            const timerHtml = isSuccess ? 
                                `<span style="color: #4CAF50; font-weight: bold;">✅ 완료</span>` : 
                                `⏱️ <span class="elapsed-timer" data-start="${t.start_ts || 0}">-</span>`;

                            taskContainer.innerHTML = `
                                <div class="live-task-box" style="${isSuccess ? 'border-color: rgba(76, 175, 80, 0.6); background: rgba(76, 175, 80, 0.05);' : ''}">
                                    <div class="live-task-dest" title="${t.dest_name || 'N/A'}">🎯 ${t.dest_name || 'N/A'} ${destIdStr}</div>
                                    <div class="live-task-meta">
                                        <div class="live-task-row">
                                            <span>${timerHtml}</span>
                                            <span>🏁 ${targetHtml}</span>
                                        </div>
                                        ${distHtml}
                                    </div>
                                </div>`;
                        } else if (dev.cooldown_info) {
                            const c = dev.cooldown_info;
                            let color = "#ff9800"; // Orange (IP_COOLDOWN, COOLDOWN)
                            let border = "rgba(255, 152, 0, 0.4)";
                            let bg = "rgba(255, 152, 0, 0.05)";
                            if (c.status === "PENALTY") {
                                color = "#9c27b0"; // Purple (PENALTY)
                                border = "rgba(156, 39, 176, 0.4)";
                                bg = "rgba(156, 39, 176, 0.05)";
                            } else if (c.status === "UNAUTHORIZED") {
                                color = "#f44336"; // Red (UNAUTHORIZED)
                                border = "rgba(244, 67, 54, 0.4)";
                                bg = "rgba(244, 67, 54, 0.05)";
                            }
                            
                            taskContainer.innerHTML = `
                                <div class="live-task-box" style="border: 1px solid ${border}; background: ${bg}; padding: 6px; display: flex; flex-direction: column; justify-content: center; height: 74px; box-sizing: border-box;">
                                    <div style="font-weight: bold; color: ${color}; font-size: 0.9em; display: flex; justify-content: space-between; align-items: center;">
                                        <span>⚠️ ${c.status}</span>
                                        <div style="display: flex; gap: 4px; align-items: center;">
                                            <button onclick="resetDevicePenalty('${dev.id}')" style="background: #E65100; color: white; border: none; padding: 2px 6px; font-size: 0.8em; border-radius: 3px; cursor: pointer; font-weight: bold;" title="Reset Penalty & Cooldown">⚡ 리셋</button>
                                            <span style="font-size: 0.85em; background: ${color}; color: black; padding: 1px 6px; border-radius: 3px; font-weight: bold;">
                                                ${c.remain_sec}s
                                            </span>
                                        </div>
                                    </div>
                                    <div style="font-size: 0.78em; color: #aaa; margin-top: 4px; line-height: 1.3;">
                                        <div>• 실패 시각: <span style="color: #ffeb3b;">${c.failed_at}</span></div>
                                        <div style="white-space: nowrap; overflow: hidden; text-overflow: ellipsis;">• 실패 사유: <span style="color: #ff5252;">${c.reason}</span></div>
                                    </div>
                                </div>`;
                        } else {
                            taskContainer.innerHTML = `
                                <div style="height: 74px; border: 1px dashed #333; border-radius: 4px; display: flex; align-items: center; justify-content: center; font-size: 0.8em; color: #555; margin-bottom: 8px; box-sizing: border-box;">
                                    Ready for next task
                                </div>`;
                        }
                    }

                    if (controls) {
                        controls.className = 'controls ' + (dev.offline ? 'dimmed' : '');
                    }
                    
                    if (placeholder) {
                        if (dev.offline) {
                            placeholder.innerHTML = '<span>📵</span>DEVICE DISCONNECTED';
                        }
                    }
                });

                let totalConnected = 0;
                let working = 0;
                let idle = 0;
                let offline = 0;

                data.slots.forEach((dev) => {
                    if (dev) {
                        if (dev.offline) {
                            offline++;
                        } else {
                            totalConnected++;
                            const isTaskActive = dev.status && dev.status !== 'IDLE' && dev.status !== 'SUCCESS' && dev.status !== 'ARRIVED';
                            if (isTaskActive) {
                                working++;
                            } else {
                                idle++;
                            }
                        }
                    }
                });

                const summaryEl = document.getElementById('farm-summary');
                if (summaryEl) {
                    summaryEl.innerHTML = `(연결: <b style="color: #4CAF50;">${totalConnected}대</b> | 동작: <b style="color: #2196F3;">${working}</b> | 대기: <b style="color: #bbb;">${idle}</b> | 오프라인: <b style="color: #f44336;">${offline}</b>)`;
                }

                updateTimers();
                updateActiveScreenCount();
            }).catch(e => console.error("Status fetch error", e));
        }
        setInterval(fetchStatus, 3000);
        fetchStatus();

        // [NEW] Real-time Timer Update
        function updateTimers() {
            const now = Math.floor(Date.now() / 1000);
            document.querySelectorAll('.elapsed-timer').forEach(el => {
                const start = parseInt(el.getAttribute('data-start'));
                if (!isNaN(start) && start > 0) {
                    const elapsed = now - start;
                    const m = Math.floor(elapsed / 60).toString().padStart(2, '0');
                    const s = (elapsed % 60).toString().padStart(2, '0');
                    el.innerText = `${m}:${s}`;
                } else {
                    el.innerText = "-";
                }
            });
        }
        setInterval(updateTimers, 1000);
        updateTimers();

        document.addEventListener('DOMContentLoaded', () => {
            updateActiveScreenCount();
        });
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
        "latest_log": "-",
        "current_task": None
    }
    
    # 1. Check Working Status (Lightweight)
    try:
        subprocess.check_output(["pgrep", "-f", f"lib/main.sh {serial}"])
        info["status"] = "WORKING"
    except:
        info["status"] = "IDLE"
        try:
            task_info_path = os.path.join(LOG_BASE_DIR, serial, "current_task.json")
            if os.path.exists(task_info_path):
                with open(task_info_path, 'r') as f:
                    cdata = json.load(f)
                    cstatus = cdata.get("status")
                    if cstatus in ["IP_COOLDOWN", "COOLDOWN", "PENALTY", "UNAUTHORIZED"]:
                        info["status"] = cstatus
        except:
            pass

    # 2. Get Battery & Temp (Cached)
    try:
        batt_raw = subprocess.check_output(["adb", "-s", serial, "shell", "dumpsys battery"], timeout=5).decode()
        for line in batt_raw.splitlines():
            if "level:" in line: info["battery"] = line.split(":")[1].strip()
            if "temperature:" in line: info["temp"] = int(line.split(":")[1].strip()) / 10
    except:
        pass

    # 3. Find Latest Task Details from execution.log & session files (Safety fallback / Contrast)
    task_data = {
        "dest_name": "Unknown",
        "dest_id": "",
        "start_ts": 0,
        "target_sec": 0,
        "total_dist_km": 0.0,
        "remaining_dist_km": 0.0,
        "avg_speed_kmh": 0.0,
        "status": "IDLE"
    }
    
    # 3-1. Try parsing logs directory structure
    latest_session_dir = None
    latest_date_str = None
    try:
        dev_log_dir = os.path.join(LOG_BASE_DIR, serial)
        if os.path.exists(dev_log_dir):
            dates = sorted([d for d in os.listdir(dev_log_dir) if d.isdigit()], reverse=True)
            if dates:
                latest_date_str = dates[0]
                date_dir = os.path.join(dev_log_dir, latest_date_str)
                sessions = sorted([s for s in os.listdir(date_dir) if "_" in s], reverse=True)
                if sessions:
                    latest_session_dir = os.path.join(date_dir, sessions[0])
                    # Revert latest_log to show the session directory name
                    info["latest_log"] = sessions[0]
                    parts = sessions[0].split("_")
                    if len(parts) >= 2:
                        task_data["dest_id"] = parts[1]
                        
                    time_str = parts[0]
                    try:
                        dt_str = f"{latest_date_str} {time_str}"
                        struct_time = time.strptime(dt_str, "%Y%m%d %H%M%S")
                        task_data["start_ts"] = int(time.mktime(struct_time))
                    except:
                        pass
    except Exception as e:
        print(f"Error resolving latest session dir: {e}", flush=True)

    # 3-2. Load values from session_summary.json (Primary metadata container)
    session_status = None
    if latest_session_dir and os.path.exists(latest_session_dir):
        summary_path = os.path.join(latest_session_dir, "session_summary.json")
        if os.path.exists(summary_path):
            try:
                with open(summary_path, 'r') as f:
                    sdata = json.load(f)
                    info["ip"] = sdata.get("real_ip", info["ip"])
                    session_status = sdata.get("status", None)
                    if sdata.get("total_distance_km"):
                        task_data["total_dist_km"] = sdata.get("total_distance_km")
            except:
                pass

    # 3-3. Load values from current_task.json if available as fallback
    try:
        task_info_path = os.path.join(LOG_BASE_DIR, serial, "current_task.json")
        if os.path.exists(task_info_path):
            with open(task_info_path, 'r') as f:
                cdata = json.load(f)
                for k, v in cdata.items():
                    if v is not None:
                        task_data[k] = v
                info["ip"] = cdata.get("real_ip", info["ip"])
    except:
        pass

    # 3-4. Parse execution.log for live progress
    if latest_session_dir and os.path.exists(latest_session_dir):
        exec_log_path = os.path.join(latest_session_dir, "execution.log")
        if os.path.exists(exec_log_path):
            try:
                with open(exec_log_path, 'r', encoding='utf-8', errors='ignore') as f:
                    log_lines = f.readlines()
                
                dest_name = None
                total_dist = None
                target_sec = None
                latest_progress = None
                
                task_id = None
                for line in log_lines:
                    line_str = line.strip()
                    if not line_str:
                        continue
                    
                    if "TASK STARTED" in line_str and "LogID:" in line_str:
                        try:
                            task_id = line_str.split("LogID:")[-1].replace(")", "").strip()
                        except:
                            pass
                    
                    if "Destination:" in line_str:
                        d_part = line_str.split("Destination:")[-1].strip()
                        if " (ID:" in d_part:
                            dest_name = d_part.split(" (ID:")[0].strip()
                        else:
                            dest_name = d_part
                    
                    if "Initial Path Loaded:" in line_str:
                        try:
                            dist_str = line_str.split("Initial Path Loaded:")[-1].replace("km", "").strip()
                            total_dist = float(dist_str)
                        except:
                            pass
                            
                    if "Exact Server Arrival Time:" in line_str:
                        try:
                            sec_str = line_str.split("Exact Server Arrival Time:")[-1].replace("s", "").strip()
                            target_sec = int(sec_str)
                        except:
                            pass
                    elif "Session Goal :" in line_str:
                        try:
                            sec_str = line_str.split("Session Goal :")[-1].split("s")[0].strip()
                            target_sec = int(sec_str)
                        except:
                            pass

                    if "Progress:" in line_str and "remaining" in line_str:
                        latest_progress = line_str

                if dest_name:
                    task_data["dest_name"] = dest_name
                if total_dist:
                    task_data["total_dist_km"] = total_dist
                if target_sec:
                    task_data["target_sec"] = target_sec
                if task_id and info["latest_log"] == sessions[0]:
                    info["latest_log"] = f"{sessions[0]} (Task:{task_id})"
                
                if latest_progress:
                    try:
                        p_part = latest_progress.split("Progress:")[-1].strip()
                        rem_str = p_part.split("km remaining")[0].strip()
                        task_data["remaining_dist_km"] = float(rem_str)
                        
                        if "Time:" in p_part:
                            t_part = p_part.split("Time:")[-1].strip()
                            parts = t_part.split("/")
                            elapsed_sec = int(parts[0].replace("s", "").strip())
                            total_sec = int(parts[1].replace("s", "").strip())
                            task_data["start_ts"] = int(time.time()) - elapsed_sec
                            task_data["target_sec"] = total_sec
                    except:
                        pass
            except:
                pass
                
    # Determine the task final status based on whether main.sh is running and log messages
    is_working = (info["status"] == "WORKING")
    log_has_success = False
    
    # Double check log for SUCCESS or SUCCESSFUL message
    if latest_session_dir and os.path.exists(latest_session_dir):
        exec_log_path = os.path.join(latest_session_dir, "execution.log")
        if os.path.exists(exec_log_path):
            try:
                with open(exec_log_path, 'r', encoding='utf-8', errors='ignore') as f:
                    lines = f.readlines()[-20:]
                for line in lines:
                    if "SUCCESS" in line or "SUCCESSFUL" in line:
                        log_has_success = True
                        break
            except:
                pass

    if is_working:
        # Resolve detailed status from task_data (enriched by current_task.json / session_summary)
        detailed_status = task_data.get("status", "DRIVING")
        if detailed_status in ["IDLE", "SUCCESS", "ARRIVED", "Unknown", ""]:
            detailed_status = "DRIVING"
            
        info["status"] = detailed_status
        task_data["status"] = detailed_status
        info["current_task"] = task_data
    else:
        # If not running, but session_summary states ARRIVED or logs suggest success, mark as SUCCESS
        if session_status == "ARRIVED" or log_has_success:
            info["status"] = "SUCCESS"
            task_data["status"] = "SUCCESS"
            info["current_task"] = task_data
        else:
            info["status"] = "IDLE"
            info["current_task"] = None

    # 3-5. Resolve failure reason and time for cooldown info if in a penalty or cooldown state
    info["cooldown_info"] = None
    try:
        task_info_path = os.path.join(LOG_BASE_DIR, serial, "current_task.json")
        if os.path.exists(task_info_path):
            with open(task_info_path, 'r') as f:
                cdata = json.load(f)
                cstatus = cdata.get("status")
                if cstatus in ["IP_COOLDOWN", "COOLDOWN", "PENALTY", "UNAUTHORIZED"]:
                    until = cdata.get("exclude_until", 0)
                    diff = int(until - time.time())
                    if diff > 0:
                        cooldown_reason = "UNKNOWN"
                        failed_time_str = "N/A"
                        
                        if cstatus == "IP_COOLDOWN":
                            cooldown_reason = "NETWORK_TIMEOUT"
                            failed_time_str = time.strftime("%H:%M:%S", time.localtime(until - 180))
                        else:
                            # Try parsing latest session logs for details
                            if latest_session_dir and os.path.exists(latest_session_dir):
                                base_name = os.path.basename(latest_session_dir)
                                parts = base_name.split("_")
                                if len(parts) >= 2 and len(parts[0]) == 6:
                                    t = parts[0]
                                    failed_time_str = f"{t[0:2]}:{t[2:4]}:{t[4:6]}"
                                    
                                exec_log_path = os.path.join(latest_session_dir, "execution.log")
                                if os.path.exists(exec_log_path):
                                    try:
                                        with open(exec_log_path, 'r', encoding='utf-8', errors='ignore') as log_f:
                                            log_lines = log_f.readlines()[-100:]
                                            for line in log_lines:
                                                if "Failure Reason Determined:" in line:
                                                    cooldown_reason = line.split("Failure Reason Determined:")[-1].strip()
                                                    break
                                                elif "Terminating. Reason:" in line:
                                                    cooldown_reason = line.split("Terminating. Reason:")[-1].strip()
                                    except:
                                        pass
                            
                            # Fallback estimation
                            if failed_time_str == "N/A":
                                duration = 600 if cstatus == "PENALTY" else (300 if cstatus == "UNAUTHORIZED" else 60)
                                failed_time_str = time.strftime("%H:%M:%S", time.localtime(until - duration))
                        
                        info["cooldown_info"] = {
                            "status": cstatus,
                            "failed_at": failed_time_str,
                            "reason": cooldown_reason,
                            "remain_sec": diff
                        }
                        # ⚠️ 기기가 성공(SUCCESS)으로 완전히 마친 경우, 상태를 강제 PENALTY/COOLDOWN으로 덮어쓰지 않고 SUCCESS를 우선 유지합니다.
                        if info["status"] != "SUCCESS":
                            info["status"] = cstatus
    except Exception as e:
        print(f"Error compiling cooldown_info: {e}", flush=True)
            
    return info

ORDER_FILE_PATH = "/home/tech/nmap_multi_v1/wifi_multi/config/device_order.json"

def refresh_device_slots():
    global device_slots, MAX_SLOTS
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

        # Check if custom order config exists
        order_list = []
        if os.path.exists(ORDER_FILE_PATH):
            try:
                with open(ORDER_FILE_PATH, 'r') as f:
                    order_list = json.load(f)
            except:
                pass

        if order_list:
            # Mode A: Custom Locked Order
            # Append any newly connected devices that aren't defined in the order list
            for serial in current_connected.keys():
                if serial not in order_list:
                    order_list.append(serial)

            MAX_SLOTS = len(order_list)
            while len(device_slots) < MAX_SLOTS:
                device_slots.append(None)
            if len(device_slots) > MAX_SLOTS:
                device_slots = device_slots[:MAX_SLOTS]

            for i, serial in enumerate(order_list):
                if serial in current_connected:
                    diag = get_device_diagnostics(serial)
                    device_slots[i] = {
                        "id": serial,
                        "model": current_connected[serial],
                        "offline": False,
                        **diag
                    }
                else:
                    # Device is offline but slot position is strictly preserved
                    old_slot = device_slots[i]
                    old_model = old_slot.get("model", "Unknown") if old_slot else "Unknown"
                    device_slots[i] = {
                        "id": serial,
                        "model": old_model,
                        "offline": True,
                        "status": "OFFLINE",
                        "ip": "N/A",
                        "temp": "??",
                        "battery": "??",
                        "latest_log": "-",
                        "current_task": None
                    }
        else:
            # Mode B: Dynamic Auto Assignment (Existing style)
            # 1. Update existing slots
            for i in range(MAX_SLOTS):
                slot = device_slots[i]
                if slot:
                    if slot["id"] in current_connected:
                        slot["offline"] = False
                        slot["model"] = current_connected[slot["id"]]
                        diag = get_device_diagnostics(slot["id"])
                        slot.update(diag)
                        del current_connected[slot["id"]]
                    else:
                        slot["offline"] = True

            # 2. Assign new devices to empty or offline slots
            for serial, model in current_connected.items():
                assigned = False
                for i in range(MAX_SLOTS):
                    if device_slots[i] is None or device_slots[i].get("offline"):
                        diag = get_device_diagnostics(serial)
                        device_slots[i] = {"id": serial, "model": model, "offline": False, **diag}
                        assigned = True
                        break
                if not assigned:
                    diag = get_device_diagnostics(serial)
                    device_slots.append({"id": serial, "model": model, "offline": False, **diag})
                    MAX_SLOTS = len(device_slots)
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
    device_id = request.args.get('device_id', '').strip()
    hostname = socket.gethostname()
    return render_template_string(HTML_TEMPLATE, slots=device_slots, MAX_SLOTS=MAX_SLOTS, hostname=hostname, target_device_id=device_id)

@app.route('/status')
def status():
    # Return the current parsed device states for seamless AJAX updates
    return jsonify({"slots": device_slots})

@app.route('/api/reset_device_penalty', methods=['POST'])
def reset_device_penalty():
    try:
        data = request.get_json() or {}
        serial = data.get("serial")
        if not serial:
            return jsonify({"status": "error", "message": "Missing serial"}), 400
            
        # 1. External API 호출 (리턴을 전혀 기다리지 않고 스레드로 백그라운드 격발!)
        def trigger_external_reset(dev_id):
            try:
                import requests
                requests.get(f"http://114.207.112.245:8001/api/v1/admin/device/reset_penalty?device_id={dev_id}", timeout=5)
            except Exception as ex:
                print(f"Async external reset error: {ex}", flush=True)

        threading.Thread(target=trigger_external_reset, args=(serial,), daemon=True).start()
            
        # 2. Local Reset (current_task.json 갱신 또는 삭제)
        task_info_path = os.path.join(LOG_BASE_DIR, serial, "current_task.json")
        if os.path.exists(task_info_path):
            try:
                with open(task_info_path, 'r') as f:
                    cdata = json.load(f)
                cdata["status"] = "IDLE"
                with open(task_info_path, 'w') as f:
                    json.dump(cdata, f, indent=4)
            except:
                try:
                    os.remove(task_info_path)
                except:
                    pass
        
        # 3. 로컬 메모리 상태 즉시 갱신 (반응성 극대화)
        refresh_device_slots()
                   
        return jsonify({"status": "success", "message": "Reset triggered successfully"})
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

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
    code = request.args.get('code')
    try:
        subprocess.Popen(["adb", "-s", dev_id, "shell", "input", "keyevent", str(code)])
    except Exception as e:
        print(f"Key error: {e}", flush=True)
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

@app.route('/set_theme_all/<mode>')
def set_theme_all(mode):
    try:
        res = subprocess.check_output(["adb", "devices"]).decode()
        devices = []
        for line in res.strip().split("\n")[1:]:
            line = line.strip()
            if line and not line.startswith("*"):
                parts = line.split()
                if parts and parts[1] == "device":
                    devices.append(parts[0])
        
        night_val = "yes" if mode == "dark" else "no"
        for dev_id in devices:
            subprocess.Popen(["adb", "-s", dev_id, "shell", "cmd", "uimode", "night", night_val])
    except Exception as e:
        return str(e), 500
    return "OK"

def gen_frames(dev_id):
    try:
        while True:
            try:
                # -p 옵션으로 압축된 png 추출 (대역폭 절약)
                cmd = ["adb", "-s", dev_id, "exec-out", "screencap", "-p"]
                frame = subprocess.check_output(cmd, timeout=5)
                yield (b'--frame\r\n'
                       b'Content-Type: image/png\r\n\r\n' + frame + b'\r\n')
                time.sleep(REFRESH_INTERVAL)
            except subprocess.SubprocessError:
                time.sleep(1)
            except Exception as e:
                time.sleep(1)
    except GeneratorExit:
        # 클라이언트가 연결을 끊은 경우
        pass

@app.route('/stream/<dev_id>')
def stream(dev_id):
    return Response(gen_frames(dev_id),
                    mimetype='multipart/x-mixed-replace; boundary=frame')

if __name__ == "__main__":
    app.run(host='0.0.0.0', port=PORT, threaded=True)
