HTML_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
    <title>{{ hostname }} - WiFi Monitor</title>
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
        .live-task-dest { color: #4CAF50; font-weight: bold; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; margin-bottom: 2px; display: flex; justify-content: space-between; }
        .live-task-status { background: #4CAF50; color: #fff; padding: 1px 4px; border-radius: 3px; font-size: 0.75em; font-weight: normal; }
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
                    <button id="btn-task-{{ dev.id }}" onclick="toggleTask('{{ dev.id }}')" style="background: {{ '#d32f2f' if dev.excluded else '#2E7D32' }}; min-width: 38px; font-weight: bold;" title="Toggle Task Allocation">{{ 'OFF' if dev.excluded else 'ON' }}</button>
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
                    <div class="live-task-dest" title="{{ dev.current_task.dest_name }}">
                        🎯 {{ dev.current_task.dest_name }} 
                        <span class="live-task-status">{{ dev.current_task.status }}</span>
                    </div>
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

        function toggleTask(devId) {
            const btn = document.getElementById('btn-task-' + devId);
            fetch(`/toggle_task/${devId}`)
                .then(r => r.json())
                .then(data => {
                    if (data.status === 'ok') {
                        if (data.excluded) {
                            btn.style.background = '#d32f2f';
                            btn.innerText = 'OFF';
                        } else {
                            btn.style.background = '#2E7D32';
                            btn.innerText = 'ON';
                        }
                    }
                }).catch(e => console.error("Toggle task error", e));
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

                    const taskBtn = document.getElementById('btn-task-' + dev.id);
                    if (taskBtn) {
                        if (dev.excluded) {
                            taskBtn.style.background = '#d32f2f';
                            taskBtn.innerText = 'OFF';
                        } else {
                            taskBtn.style.background = '#2E7D32';
                            taskBtn.innerText = 'ON';
                        }
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
                                    <div class="live-task-dest" title="${t.dest_name}">
                                        🎯 ${t.dest_name} ${destIdStr}
                                        <span class="live-task-status">${t.status || 'WORKING'}</span>
                                    </div>
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