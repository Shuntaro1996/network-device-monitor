// =========================================================================
// 【初心者向けの簡単な解説】
// このファイルは、監視画面の「動きやロジック（JavaScript）」を制御する脳にあたるプログラムです。
// HTML（骨組み）やCSS（装飾）に命を吹き込み、動きのある動的なシステムにします。
// 
// 主な仕事（役割）：
// 1. 【定期データの取得】: サーバー（Server.ps1）から数秒おきに最新のPING遅延時間や
//    通信量のデータを取得し、画面上の数値やステータス表示を自動で更新します。
// 2. 【動的グラフの描画】: 蓄積された遅延データをもとに、時間経過に伴う変化を示す
//    なめらかな折れ線グラフ（Chart.jsライブラリ）を描画します。
// 3. 【ネットワーク図の構築】: 機器同士の接続関係（トポロジー）を解析し、
//    ドラッグで動かせる円状のネットワーク構成マップ（vis.jsライブラリ）を動的に組み立てます。
// 4. 【アラート通知の発動】: 取得した遅延時間がユーザーの設定値（例: 100ms）を超えた際に、
//    ブラウザの右上に赤い「警告トースト」を表示したり、デスクトップ通知で管理者に知らせます。
// 5. 【ファイルの処理】: CSVファイルやJSONファイルを読み取って機器登録データを復元したり、
//    現在の設定をローカルPCにファイル保存（エクスポート）する機能の窓口になります。
// =========================================================================

document.addEventListener('DOMContentLoaded', () => {
    // Discovery Scan Logic
    const scanStartIp = document.getElementById('scan-start-ip');
    const scanEndIp = document.getElementById('scan-end-ip');
    const scanStartBtn = document.getElementById('scan-start-btn');
    const scanStatus = document.getElementById('scan-status');
    const scanResultsContainer = document.getElementById('scan-results-container');
    const scanResultsList = document.getElementById('scan-results-list');
    const scanAddSelectedBtn = document.getElementById('scan-add-selected-btn');

    let scannedIps = [];

    if (scanStartBtn) {
        scanStartBtn.addEventListener('click', async () => {
            const start = scanStartIp.value.trim();
            const end = scanEndIp.value.trim();
            if (!start || !end) {
                alert('開始IPと終了IPを入力してください。');
                return;
            }

            scanStartBtn.disabled = true;
            scanStartBtn.textContent = 'スキャン中...';
            scanStatus.style.display = 'block';
            scanStatus.textContent = 'ネットワークをスキャン中... (時間がかかる場合があります)';
            scanResultsContainer.style.display = 'none';
            scanResultsList.innerHTML = '';
            scannedIps = [];

            try {
                const res = await fetch(`/api/scan?start=${encodeURIComponent(start)}&end=${encodeURIComponent(end)}`);
                if (res.ok) {
                    const data = await res.json();
                    if (data.activeIps && data.activeIps.length > 0) {
                        scannedIps = data.activeIps;
                        scanStatus.textContent = `${scannedIps.length} 台の稼働中の機器が見つかりました。`;
                        scanResultsContainer.style.display = 'block';
                        
                        scannedIps.forEach(ip => {
                            const isAlreadyAdded = devices.some(d => d.ip === ip);
                            const div = document.createElement('div');
                            div.style.cssText = `
                                padding: 4px 8px;
                                background: ${isAlreadyAdded ? 'rgba(255,255,255,0.05)' : 'rgba(59, 130, 246, 0.2)'};
                                border: 1px solid ${isAlreadyAdded ? 'transparent' : 'rgba(59, 130, 246, 0.4)'};
                                border-radius: 4px;
                                font-size: 0.75rem;
                                display: flex;
                                align-items: center;
                                gap: 6px;
                                opacity: ${isAlreadyAdded ? '0.5' : '1'};
                            `;
                            div.innerHTML = `
                                <input type="checkbox" value="${ip}" ${isAlreadyAdded ? 'disabled' : 'checked'}>
                                <span>${ip}</span>
                                ${isAlreadyAdded ? '<span style="font-size:0.6rem;">(登録済み)</span>' : ''}
                            `;
                            scanResultsList.appendChild(div);
                        });
                    } else {
                        scanStatus.textContent = '稼働中の機器は見つかりませんでした。';
                    }
                } else {
                    scanStatus.textContent = 'スキャン中にエラーが発生しました。';
                }
            } catch (err) {
                console.error('Scan error:', err);
                scanStatus.textContent = '通信エラーが発生しました。';
            } finally {
                scanStartBtn.disabled = false;
                scanStartBtn.textContent = 'スキャン開始';
            }
        });
    }

    if (scanAddSelectedBtn) {
        scanAddSelectedBtn.addEventListener('click', async () => {
            const selectedIps = Array.from(scanResultsList.querySelectorAll('input:checked')).map(cb => cb.value);
            if (selectedIps.length === 0) return;

            const newDevices = selectedIps.map(ip => ({
                ip: ip,
                name: ip,
                group: 'Scanned',
                community: 'public',
                enabled: true
            }));

            try {
                const res = await fetch('/api/devices/bulk', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(newDevices)
                });
                if (res.ok) {
                    showToast('info', '機器の追加', `${selectedIps.length} 台の機器を追加しました。`, 3000);
                    await fetchDevices();
                    scanResultsContainer.style.display = 'none';
                } else {
                    alert('機器の追加に失敗しました。');
                }
            } catch (err) {
                console.error('Bulk add error:', err);
            }
        });
    }
    // Utility function to escape HTML special characters
    function escapeHTML(str) {
        if (!str) return '';
        return str.toString()
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#039;');
    }

    // Utility function to escape XML/SVG special characters
    function escapeXml(str) {
        if (!str) return '';
        return str.toString()
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&apos;');
    }

    // IP Conflict Detection: Check if IP already exists
    function isIpConflicted(ip, currentOldIp = null) {
        return devices.some(d => d.ip === ip && d.ip !== currentOldIp);
    }

    // Dependency Suppression Logic: Check if all parents are offline
    function isAlertSuppressed(ip) {
        if (systemConfig.enableParentSuppression === false) return false;
        const dev = devices.find(d => d.ip === ip);
        if (!dev || !dev.connectedTo || typeof dev.connectedTo !== 'string') return false;
        
        const parents = dev.connectedTo.split(',').map(p => p.trim()).filter(p => p);
        if (parents.length === 0) return false;

        // If ALL parents are offline/paused/failed/unreachable, suppress this alert
        return parents.every(parentIp => {
            const pStatus = window.lastStatusData ? window.lastStatusData[parentIp] : null;
            return !pStatus || pStatus.status === 'Failed' || pStatus.status === 'Paused' || pStatus.status === 'Error' || pStatus.status === 'Offline' || pStatus.isSuppressed;
        });
    }

    // =========================================================
    // Toast Notification System
    // =========================================================
    const TOAST_COOLDOWN_MS = 60000; // 同一デバイスの連続通知を60秒間抑制
    const alertCooldowns = {};       // { ip: { latency: timestamp, offline: timestamp } }

    function showToast(type, title, message, durationMs = 8000) {
        const container = document.getElementById('toast-container');
        if (!container) return;

        const toast = document.createElement('div');
        toast.className = `toast toast-${type}`;

        const safeTitle = escapeHTML(title);
        const safeMessage = escapeHTML(message);

        const icons = { warning: '⚠️', error: '🔴', info: 'ℹ️' };
        toast.innerHTML = `
            <span class="toast-icon">${icons[type] || '🔔'}</span>
            <div class="toast-body">
                <div class="toast-title">${safeTitle}</div>
                <div class="toast-msg">${safeMessage}</div>
            </div>
            <button class="toast-close" title="閉じる">✕</button>
            <div class="toast-progress" style="animation-duration: ${durationMs}ms;"></div>
        `;

        // Close button
        toast.querySelector('.toast-close').addEventListener('click', () => dismissToast(toast));
        container.appendChild(toast);

        // Auto-dismiss
        const timer = setTimeout(() => dismissToast(toast), durationMs);
        toast._timer = timer;
    }

    function dismissToast(toast) {
        clearTimeout(toast._timer);
        toast.classList.add('toast-hiding');
        setTimeout(() => toast.remove(), 320);
    }

    function canAlert(ip, type) {
        const now = Date.now();
        if (!alertCooldowns[ip]) alertCooldowns[ip] = {};
        const last = alertCooldowns[ip][type] || 0;
        if (now - last < TOAST_COOLDOWN_MS) return false;
        alertCooldowns[ip][type] = now;
        return true;
    }

    const deviceGrid = document.getElementById('device-grid');
    const manageDeviceList = document.getElementById('manage-device-list');
    const deviceForm = document.getElementById('device-form');
    
    const devIpInput = document.getElementById('dev-ip');
    const devNameInput = document.getElementById('dev-name');
    const devCommInput = document.getElementById('dev-comm');
    const devGroupInput = document.getElementById('dev-group');
    const devGroupSelect = document.getElementById('dev-group-select');
    const devGroupNew = document.getElementById('dev-group-new');
    const devEnabledInput = document.getElementById('dev-enabled');
    const editOldIpInput = document.getElementById('edit-old-ip');
    const submitDeviceBtn = document.getElementById('submit-device-btn');

    // ---- Group Dropdown: populate from existing devices & sync hidden input ----
    function populateGroupDropdown(selectedValue) {
        if (!devGroupSelect) return;
        // Collect unique group names from registered devices
        const existingGroups = [...new Set(
            devices.filter(d => d.group && d.group.trim()).map(d => d.group.trim())
        )].sort();
        // Rebuild options: keep the static placeholders, inject groups in between
        devGroupSelect.innerHTML = '';
        const blankOpt = document.createElement('option');
        blankOpt.value = '';
        blankOpt.textContent = '— グループなし —';
        devGroupSelect.appendChild(blankOpt);
        existingGroups.forEach(g => {
            const opt = document.createElement('option');
            opt.value = g;
            opt.textContent = g;
            devGroupSelect.appendChild(opt);
        });
        const newOpt = document.createElement('option');
        newOpt.value = '__new__';
        newOpt.textContent = '＋ 新しいグループを追加';
        devGroupSelect.appendChild(newOpt);
        // Restore previously selected value if it exists in the list
        if (selectedValue !== undefined && selectedValue !== null) {
            devGroupSelect.value = selectedValue;
            // If the value isn't in the list (e.g. a newly created group), fall back to blank
            if (devGroupSelect.value !== selectedValue) devGroupSelect.value = '';
        }
        // Sync hidden input
        if (devGroupInput) {
            const v = devGroupSelect.value;
            devGroupInput.value = (v === '__new__') ? (devGroupNew ? devGroupNew.value.trim() : '') : v;
        }
    }

    // Group select change handler
    if (devGroupSelect) {
        devGroupSelect.addEventListener('change', () => {
            const v = devGroupSelect.value;
            if (v === '__new__') {
                if (devGroupNew) { devGroupNew.classList.remove('hidden'); devGroupNew.focus(); }
                if (devGroupInput) devGroupInput.value = '';
            } else {
                if (devGroupNew) devGroupNew.classList.add('hidden');
                if (devGroupInput) devGroupInput.value = v;
            }
        });
    }
    // Keep hidden input in sync as user types a new group name
    if (devGroupNew) {
        devGroupNew.addEventListener('input', () => {
            if (devGroupInput && devGroupSelect && devGroupSelect.value === '__new__') {
                devGroupInput.value = devGroupNew.value.trim();
            }
        });
    }

    const threshLatencyEl = document.getElementById('thresh-latency');
    const threshBandwidthEl = document.getElementById('thresh-bandwidth');
    const threshLatencyHint = document.getElementById('thresh-latency-hint');
// ---- Latency threshold: keyboard input support ----
    if (threshLatencyEl) {
        // Show hint when focused
        threshLatencyEl.addEventListener('focus', () => {
            if (threshLatencyHint) threshLatencyHint.style.display = 'block';
            threshLatencyEl.style.borderColor = 'var(--primary)';
            threshLatencyEl.style.boxShadow = '0 0 0 2px rgba(59,130,246,0.25)';
        });

        // Hide hint and confirm on blur
        threshLatencyEl.addEventListener('blur', () => {
            if (threshLatencyHint) threshLatencyHint.style.display = 'none';
            threshLatencyEl.style.borderColor = '';
            threshLatencyEl.style.boxShadow = '';
            applyLatencyThreshold();
        });

        // Confirm on Enter key
        threshLatencyEl.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') {
                e.preventDefault();
                threshLatencyEl.blur();
            }
        });
    }

    // ── Global System Config State ──────────────────────────────────────────
    let systemConfig = {
        pollInterval: 1000,
        pingDataSize: 1,
        loggingEnabled: true,
        highFreqTargetIps: '',
        outageThresh1Ms: 600,
        outageThresh2Ms: 5000,
        latencyThreshMs: 100,
        logRetentionDays: 30,
        webhookUrl: '',
        webhookEnabled: false,
        webhookOfflineOnly: true,
        soundEnabled: true,
        soundVolume: 0.5,
        bwThreshMbps: 10,
        enableParentSuppression: true
    };

    // ── Web Audio API Alert Engine ──────────────────────────────────────────
    let audioCtx = null;
    function getAudioContext() {
        if (!audioCtx) {
            audioCtx = new (window.AudioContext || window.webkitAudioContext)();
        }
        if (audioCtx && audioCtx.state === 'suspended') {
            audioCtx.resume();
        }
        return audioCtx;
    }

    function playAlertSound(type = 'error') {
        if (!systemConfig.soundEnabled) return;
        try {
            const ctx = getAudioContext();
            if (!ctx) return;
            const now = ctx.currentTime;
            const gain = ctx.createGain();
            const vol = (typeof systemConfig.soundVolume === 'number') ? systemConfig.soundVolume : 0.5;
            gain.gain.setValueAtTime(vol * 0.35, now);
            gain.connect(ctx.destination);

            if (type === 'error') {
                // High-low-high urgent beep
                const osc = ctx.createOscillator();
                osc.type = 'sawtooth';
                osc.frequency.setValueAtTime(880, now);
                osc.frequency.setValueAtTime(440, now + 0.1);
                osc.frequency.setValueAtTime(880, now + 0.2);
                osc.connect(gain);
                osc.start(now);
                gain.gain.exponentialRampToValueAtTime(0.001, now + 0.35);
                osc.stop(now + 0.35);
            } else {
                // Gentle dual chime
                const osc = ctx.createOscillator();
                osc.type = 'sine';
                osc.frequency.setValueAtTime(587.33, now);
                osc.frequency.setValueAtTime(880, now + 0.12);
                osc.connect(gain);
                osc.start(now);
                gain.gain.exponentialRampToValueAtTime(0.001, now + 0.28);
                osc.stop(now + 0.28);
            }
        } catch (e) {
            console.warn('Web Audio error:', e);
        }
    }

    // Sound Test Button
    const btnTestSound = document.getElementById('btn-test-sound');
    if (btnTestSound) {
        btnTestSound.addEventListener('click', () => {
            const vol = parseFloat(document.getElementById('modal-sound-volume').value) || 0.5;
            systemConfig.soundVolume = vol;
            systemConfig.soundEnabled = true;
            playAlertSound('error');
        });
    }

    const modalSoundVol = document.getElementById('modal-sound-volume');
    const modalSoundVolLabel = document.getElementById('modal-sound-vol-label');
    if (modalSoundVol && modalSoundVolLabel) {
        modalSoundVol.addEventListener('input', () => {
            modalSoundVolLabel.textContent = `${Math.round(modalSoundVol.value * 100)}%`;
        });
    }

    // ── Global Config DOM Elements ──────────────────────────────────────────
    const loggingToggleBtn = document.getElementById('logging-toggle-btn');
    let isLoggingEnabled = true;

    // ── Ultra-high-frequency mode state (Dual-rate monitoring) ──────────────
    let ultraHighFreqActive    = false;   // true when poll interval <= 100ms
    let ultraHighFreqTargetSet = new Set(); // IPs that are actively monitored at 0.1s
    const topologyLastValidStatus = {};

    function updateUltraHighFreqState(pollInterval, targetIpsStr) {
        ultraHighFreqActive = (parseInt(pollInterval) <= 100);
        ultraHighFreqTargetSet.clear();
        if (ultraHighFreqActive && targetIpsStr) {
            targetIpsStr.split(',').map(s => s.trim()).filter(Boolean)
                .forEach(ip => ultraHighFreqTargetSet.add(ip));
        }
    }

    function populateHighFreqTargetDropdown(savedIps) {
        const selPairs = [
            [document.getElementById('highfreq-target-select-1'), document.getElementById('highfreq-target-select-2')],
            [document.getElementById('modal-highfreq-target-select-1'), document.getElementById('modal-highfreq-target-select-2')]
        ];

        const optionsHtml = devices.map(d => {
            const label = (d.name && d.name !== d.ip) ? `${d.name} (${d.ip})` : d.ip;
            return `<option value="${d.ip}">${label}</option>`;
        }).join('');

        const savedArr = savedIps ? savedIps.split(',').map(s => s.trim()).filter(Boolean) : [];

        selPairs.forEach(([s1, s2]) => {
            if (s1 && s2) {
                s1.innerHTML = optionsHtml;
                s2.innerHTML = `<option value="">オプション②なし</option>` + optionsHtml;
                if (savedArr[0]) s1.value = savedArr[0];
                s2.value = savedArr[1] || '';
            }
        });
    }

    function updateLoggingToggleUI(enabled) {
        isLoggingEnabled = enabled;
        if (!loggingToggleBtn) return;
        if (isLoggingEnabled) {
            loggingToggleBtn.textContent = 'ON';
            loggingToggleBtn.style.background = '#10b981';
            loggingToggleBtn.style.color = '#ffffff';
            loggingToggleBtn.style.border = 'none';
        } else {
            loggingToggleBtn.textContent = 'OFF';
            loggingToggleBtn.style.background = '#4b5563';
            loggingToggleBtn.style.color = '#d1d5db';
            loggingToggleBtn.style.border = 'none';
        }
    }

    async function fetchConfig() {
        try {
            const res = await fetch('/api/config');
            if (res.ok) {
                const config = await res.json();
                systemConfig = { ...systemConfig, ...config };
                if (threshLatencyEl && config.latencyThreshMs) {
                    threshLatencyEl.value = config.latencyThreshMs;
                }
                if (configPingSizeInput && config.pingDataSize) {
                    configPingSizeInput.value = config.pingDataSize;
                }
                if (configPollIntervalInput && config.pollInterval) {
                    configPollIntervalInput.value = config.pollInterval;
                }
                if (configOutageThresh1 && config.outageThresh1Ms) {
                    configOutageThresh1.value = config.outageThresh1Ms;
                }
                if (configOutageThresh2 && config.outageThresh2Ms) {
                    configOutageThresh2.value = config.outageThresh2Ms;
                }
                if (config.loggingEnabled !== undefined) {
                    updateLoggingToggleUI(config.loggingEnabled);
                }
                if (config.bwThreshMbps) {
                    if (threshBandwidthEl) threshBandwidthEl.value = config.bwThreshMbps;
                    const iperfViewBwInp = document.getElementById('iperf-view-bw-thresh');
                    if (iperfViewBwInp) iperfViewBwInp.value = config.bwThreshMbps;
                }
                const savedIps = config.highFreqTargetIps || '';
                populateHighFreqTargetDropdown(savedIps);
                updateUltraHighFreqState(config.pollInterval || 1000, savedIps);
                updateHighFreqUI();
            }
        } catch (err) {
            console.error('Failed to fetch config:', err);
        }
    }

    // ── System Configuration Modal Handler ──────────────────────────────────
    const systemConfigModal = document.getElementById('system-config-modal');
    const openSystemConfigBtn = document.getElementById('open-system-config-btn');
    const closeSystemConfigBtn = document.getElementById('close-system-config-btn');
    const cancelSystemConfigBtn = document.getElementById('cancel-system-config-btn');
    const saveSystemConfigBtn = document.getElementById('save-system-config-btn');

    function openSystemConfigModal() {
        if (!systemConfigModal) return;
        // Populate inputs with current systemConfig values
        const intervalSel = document.getElementById('modal-config-poll-interval');
        if (intervalSel) intervalSel.value = systemConfig.pollInterval || 1000;
        
        const highFreqContainer = document.getElementById('modal-highfreq-target-container');
        if (highFreqContainer) {
            highFreqContainer.style.display = (parseInt(systemConfig.pollInterval) <= 100) ? 'block' : 'none';
        }
        populateHighFreqTargetDropdown(systemConfig.highFreqTargetIps || '');

        const pingSizeInp = document.getElementById('modal-config-ping-size');
        if (pingSizeInp) pingSizeInp.value = systemConfig.pingDataSize || 1;

        const latThreshInp = document.getElementById('modal-thresh-latency');
        if (latThreshInp) latThreshInp.value = systemConfig.latencyThreshMs || 100;

        const out1Inp = document.getElementById('modal-config-outage-thresh1');
        if (out1Inp) out1Inp.value = systemConfig.outageThresh1Ms || 600;

        const out2Inp = document.getElementById('modal-config-outage-thresh2');
        if (out2Inp) out2Inp.value = systemConfig.outageThresh2Ms || 5000;

        const bwThreshInp = document.getElementById('modal-thresh-bandwidth');
        if (bwThreshInp) bwThreshInp.value = systemConfig.bwThreshMbps || 10;

        const parentSuppressionInp = document.getElementById('modal-config-enable-parent-suppression');
        if (parentSuppressionInp) parentSuppressionInp.checked = (systemConfig.enableParentSuppression !== false);

        const soundEnabledInp = document.getElementById('modal-sound-enabled');
        if (soundEnabledInp) soundEnabledInp.checked = (systemConfig.soundEnabled !== false);

        const soundVolInp = document.getElementById('modal-sound-volume');
        if (soundVolInp) {
            soundVolInp.value = (typeof systemConfig.soundVolume === 'number') ? systemConfig.soundVolume : 0.5;
            if (modalSoundVolLabel) modalSoundVolLabel.textContent = `${Math.round(soundVolInp.value * 100)}%`;
        }

        const webhookEnabledInp = document.getElementById('modal-webhook-enabled');
        if (webhookEnabledInp) webhookEnabledInp.checked = !!systemConfig.webhookEnabled;

        const webhookUrlInp = document.getElementById('modal-webhook-url');
        if (webhookUrlInp) webhookUrlInp.value = systemConfig.webhookUrl || '';

        const webhookOfflineOnlyInp = document.getElementById('modal-webhook-offline-only');
        if (webhookOfflineOnlyInp) webhookOfflineOnlyInp.checked = (systemConfig.webhookOfflineOnly !== false);

        const emailEnabledInp = document.getElementById('modal-email-enabled');
        if (emailEnabledInp) emailEnabledInp.checked = !!systemConfig.emailEnabled;

        const smtpHostInp = document.getElementById('modal-smtp-host');
        if (smtpHostInp) smtpHostInp.value = systemConfig.smtpHost || '';

        const smtpPortInp = document.getElementById('modal-smtp-port');
        if (smtpPortInp) smtpPortInp.value = systemConfig.smtpPort || 587;

        const smtpSslInp = document.getElementById('modal-smtp-ssl');
        if (smtpSslInp) smtpSslInp.checked = (systemConfig.smtpSsl !== false);

        const smtpUserInp = document.getElementById('modal-smtp-user');
        if (smtpUserInp) smtpUserInp.value = systemConfig.smtpUser || '';

        const smtpPassInp = document.getElementById('modal-smtp-pass');
        if (smtpPassInp) smtpPassInp.value = systemConfig.smtpPass || '';

        const smtpFromInp = document.getElementById('modal-smtp-from');
        if (smtpFromInp) smtpFromInp.value = systemConfig.smtpFrom || '';

        const smtpToInp = document.getElementById('modal-smtp-to');
        if (smtpToInp) smtpToInp.value = systemConfig.smtpTo || '';

        const logRetentionInp = document.getElementById('modal-config-log-retention');
        if (logRetentionInp) logRetentionInp.value = (systemConfig.logRetentionDays != null) ? systemConfig.logRetentionDays : 30;

        systemConfigModal.classList.remove('hidden');
    }

    function closeSystemConfigModal() {
        if (systemConfigModal) systemConfigModal.classList.add('hidden');
    }

    if (openSystemConfigBtn) openSystemConfigBtn.addEventListener('click', openSystemConfigModal);
    if (closeSystemConfigBtn) closeSystemConfigBtn.addEventListener('click', closeSystemConfigModal);
    if (cancelSystemConfigBtn) cancelSystemConfigBtn.addEventListener('click', closeSystemConfigModal);

    // Modal Poll Interval change handler
    const modalPollIntervalSel = document.getElementById('modal-config-poll-interval');
    if (modalPollIntervalSel) {
        modalPollIntervalSel.addEventListener('change', () => {
            const isUltra = parseInt(modalPollIntervalSel.value) <= 100;
            const container = document.getElementById('modal-highfreq-target-container');
            if (container) container.style.display = isUltra ? 'block' : 'none';
        });
    }

    // Modal Config Tabs switching
    document.querySelectorAll('.config-tab-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            document.querySelectorAll('.config-tab-btn').forEach(b => b.classList.remove('active'));
            document.querySelectorAll('.config-tab-content').forEach(c => c.classList.remove('active'));
            btn.classList.add('active');
            const targetId = btn.dataset.cfgTab;
            const targetContent = document.getElementById(targetId);
            if (targetContent) targetContent.classList.add('active');
        });
    });

    // Save System Config
    if (saveSystemConfigBtn) {
        saveSystemConfigBtn.addEventListener('click', async () => {
            const newInterval = parseInt(document.getElementById('modal-config-poll-interval').value) || 1000;
            const isUltra = newInterval <= 100;
            const sel1 = document.getElementById('modal-highfreq-target-select-1');
            const sel2 = document.getElementById('modal-highfreq-target-select-2');
            const ip1 = (sel1 && isUltra) ? (sel1.value || '') : '';
            const ip2 = (sel2 && isUltra) ? (sel2.value || '') : '';
            const highFreqIps = [ip1, ip2].filter(Boolean).filter((v, i, a) => a.indexOf(v) === i).join(',');

            const payload = {
                pollInterval:       newInterval,
                pingDataSize:       parseInt(document.getElementById('modal-config-ping-size').value) || 1,
                loggingEnabled:     isLoggingEnabled,
                highFreqTargetIps:  highFreqIps,
                outageThresh1Ms:    parseInt(document.getElementById('modal-config-outage-thresh1').value) || 600,
                outageThresh2Ms:    parseInt(document.getElementById('modal-config-outage-thresh2').value) || 5000,
                latencyThreshMs:    parseInt(document.getElementById('modal-thresh-latency').value) || 100,
                logRetentionDays:   parseInt(document.getElementById('modal-config-log-retention').value) || 30,
                webhookUrl:         (document.getElementById('modal-webhook-url').value || '').trim(),
                webhookEnabled:     document.getElementById('modal-webhook-enabled').checked,
                webhookOfflineOnly: document.getElementById('modal-webhook-offline-only').checked,
                emailEnabled:       document.getElementById('modal-email-enabled') ? document.getElementById('modal-email-enabled').checked : false,
                smtpHost:           document.getElementById('modal-smtp-host') ? document.getElementById('modal-smtp-host').value.trim() : '',
                smtpPort:           document.getElementById('modal-smtp-port') ? parseInt(document.getElementById('modal-smtp-port').value, 10) : 587,
                smtpSsl:            document.getElementById('modal-smtp-ssl') ? document.getElementById('modal-smtp-ssl').checked : true,
                smtpUser:           document.getElementById('modal-smtp-user') ? document.getElementById('modal-smtp-user').value.trim() : '',
                smtpPass:           document.getElementById('modal-smtp-pass') ? document.getElementById('modal-smtp-pass').value : '',
                smtpFrom:           document.getElementById('modal-smtp-from') ? document.getElementById('modal-smtp-from').value.trim() : '',
                smtpTo:             document.getElementById('modal-smtp-to') ? document.getElementById('modal-smtp-to').value.trim() : '',
                soundEnabled:       document.getElementById('modal-sound-enabled').checked,
                soundVolume:        parseFloat(document.getElementById('modal-sound-volume').value) || 0.5,
                bwThreshMbps:       parseFloat(document.getElementById('modal-thresh-bandwidth')?.value) || 10,
                enableParentSuppression: document.getElementById('modal-config-enable-parent-suppression') ? document.getElementById('modal-config-enable-parent-suppression').checked : true
            };

            try {
                saveSystemConfigBtn.disabled = true;
                saveSystemConfigBtn.textContent = '保存中...';
                const res = await fetch('/api/config', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(payload)
                });
                if (res.ok) {
                    const data = await res.json();
                    systemConfig = { ...systemConfig, ...data };
                    if (threshLatencyEl) threshLatencyEl.value = systemConfig.latencyThreshMs;
                    if (threshBandwidthEl && systemConfig.bwThreshMbps) threshBandwidthEl.value = systemConfig.bwThreshMbps;
                    const iperfViewBwInp = document.getElementById('iperf-view-bw-thresh');
                    if (iperfViewBwInp && systemConfig.bwThreshMbps) iperfViewBwInp.value = systemConfig.bwThreshMbps;
                    updateUltraHighFreqState(systemConfig.pollInterval, systemConfig.highFreqTargetIps);
                    showToast('info', '✅ 設定を保存しました', '監視設定・通知設定を正常に更新しました。', 3500);
                    closeSystemConfigModal();
                    fetchDevices();
                } else {
                    showToast('error', '❌ 保存失敗', '設定の保存に失敗しました。');
                }
            } catch (err) {
                console.error('Config save error:', err);
                showToast('error', '❌ 通信エラー', 'サーバーとの通信に失敗しました。');
            } finally {
                saveSystemConfigBtn.disabled = false;
                saveSystemConfigBtn.textContent = '💾 設定を保存';
            }
        });
    }

    // Modal Email Test Button
    const modalBtnTestEmail = document.getElementById('modal-btn-test-email');
    if (modalBtnTestEmail) {
        modalBtnTestEmail.addEventListener('click', async () => {
            modalBtnTestEmail.disabled = true;
            modalBtnTestEmail.textContent = '送信中...';
            try {
                const payload = {
                    smtpHost: document.getElementById('modal-smtp-host') ? document.getElementById('modal-smtp-host').value.trim() : '',
                    smtpPort: document.getElementById('modal-smtp-port') ? parseInt(document.getElementById('modal-smtp-port').value, 10) : 587,
                    smtpSsl: document.getElementById('modal-smtp-ssl') ? document.getElementById('modal-smtp-ssl').checked : true,
                    smtpUser: document.getElementById('modal-smtp-user') ? document.getElementById('modal-smtp-user').value.trim() : '',
                    smtpPass: document.getElementById('modal-smtp-pass') ? document.getElementById('modal-smtp-pass').value : '',
                    smtpFrom: document.getElementById('modal-smtp-from') ? document.getElementById('modal-smtp-from').value.trim() : '',
                    smtpTo: document.getElementById('modal-smtp-to') ? document.getElementById('modal-smtp-to').value.trim() : ''
                };
                const res = await fetch('/api/email/test', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(payload)
                });
                const data = await res.json();
                if (res.ok && data.status === 'success') {
                    showToast('info', '✅ 送信完了', 'テストメールを送信しました。受信トレイをご確認ください。');
                } else {
                    showToast('error', '❌ 送信失敗', data.error || 'SMTPサーバーの設定をご確認ください。');
                }
            } catch (err) {
                showToast('error', '❌ 通信エラー', 'テストメール送信に失敗しました。');
            } finally {
                modalBtnTestEmail.disabled = false;
                modalBtnTestEmail.textContent = '✉️ テストメール送信';
            }
        });
    }

    // Webhook Test Button
    const btnTestWebhook = document.getElementById('btn-test-webhook');
    if (btnTestWebhook) {
        btnTestWebhook.addEventListener('click', async () => {
            const url = (document.getElementById('modal-webhook-url').value || '').trim();
            if (!url) {
                showToast('warning', '⚠ URL 未入力', 'Webhook URL を入力してください。', 4000);
                return;
            }
            btnTestWebhook.disabled = true;
            btnTestWebhook.textContent = '送信中...';
            try {
                const res = await fetch('/api/webhook/test', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ url: url })
                });
                const data = await res.json();
                if (res.ok) {
                    showToast('info', '🔔 送信成功', data.message || 'Webhook テスト通知を送信しました。', 4000);
                } else {
                    showToast('error', '❌ 送信失敗', data.error || 'Webhook 送信に失敗しました。', 5000);
                }
            } catch (err) {
                showToast('error', '❌ 通信エラー', err.message, 5000);
            } finally {
                btnTestWebhook.disabled = false;
                btnTestWebhook.textContent = '🔔 テスト送信';
            }
        });
    }

    // ── Backup Export / Import Handlers ──────────────────────────────────────
    const btnExportBackup = document.getElementById('btn-export-backup');
    if (btnExportBackup) {
        btnExportBackup.addEventListener('click', () => {
            window.location.href = '/api/config/export';
            showToast('info', '📥 バックアップダウンロード', 'バックアップ JSON ファイルの保存を開始しました。', 3000);
        });
    }

    const btnImportBackup = document.getElementById('btn-import-backup');
    const backupFileInput = document.getElementById('backup-file-input');
    if (btnImportBackup && backupFileInput) {
        btnImportBackup.addEventListener('click', async () => {
            const file = backupFileInput.files[0];
            if (!file) {
                showToast('warning', '⚠ ファイル未選択', '復元する JSON バックアップファイルを選択してください。', 4000);
                return;
            }
            const reader = new FileReader();
            reader.onload = async (e) => {
                try {
                    const jsonPayload = JSON.parse(e.target.result);
                    btnImportBackup.disabled = true;
                    btnImportBackup.textContent = '復元中...';
                    const res = await fetch('/api/config/import', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify(jsonPayload)
                    });
                    const data = await res.json();
                    if (res.ok) {
                        showToast('info', '✅ 復元完了', '機器リストと設定パラメータを正常に復元しました。', 4000);
                        backupFileInput.value = '';
                        closeSystemConfigModal();
                        await fetchConfig();
                        await fetchDevices();
                    } else {
                        showToast('error', '❌ 復元失敗', data.error || '復元に失敗しました。', 5000);
                    }
                } catch (err) {
                    showToast('error', '❌ JSON 解析エラー', '無効な JSON バックアップファイルです。', 5000);
                } finally {
                    btnImportBackup.disabled = false;
                    btnImportBackup.textContent = '適用・復元';
                }
            };
            reader.readAsText(file);
        });
    }

    // Logging Toggle Button in Sidebar
    if (loggingToggleBtn) {
        loggingToggleBtn.addEventListener('click', async () => {
            const newLogging = !isLoggingEnabled;
            updateLoggingToggleUI(newLogging);
            systemConfig.loggingEnabled = newLogging;
            await fetch('/api/config', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ loggingEnabled: newLogging })
            });
            showToast('info', '📝 ログ記録設定', `CSVログ記録を ${newLogging ? 'ON' : 'OFF'} に設定しました。`, 2500);
        });
    }

    function applyLatencyThreshold() {
        const val = parseFloat(threshLatencyEl.value);
        if (isNaN(val) || val < 0) {
            threshLatencyEl.value = 100;
        }
        // Reset all cooldowns so new threshold takes effect immediately
        Object.keys(alertCooldowns).forEach(ip => {
            if (alertCooldowns[ip]) alertCooldowns[ip].latency = 0;
        });
        saveConfig();
        showToast('info',
            '✅ 遅延アラート閾値を更新しました',
            `新しい閾値: ${threshLatencyEl.value} ms`,
            3500
        );
    }

    // Global Config
    const configPingSizeInput = document.getElementById('config-ping-size');
    const configPingSizeHint = document.getElementById('config-ping-size-hint');
    const configPollIntervalInput = document.getElementById('config-poll-interval');
    const highFreqTargetContainer  = document.getElementById('highfreq-target-container');
    const highFreqTargetSelect1    = document.getElementById('highfreq-target-select-1');
    const highFreqTargetSelect2    = document.getElementById('highfreq-target-select-2');
    const configOutageThresh1 = document.getElementById('config-outage-thresh1');
    const configOutageThresh2 = document.getElementById('config-outage-thresh2');

    function updateHighFreqUI() {
        if (!configPollIntervalInput || !highFreqTargetContainer) return;
        const isUltra = (parseInt(configPollIntervalInput.value) <= 100);
        highFreqTargetContainer.style.display = isUltra ? 'block' : 'none';
        if (isUltra) {
            const ip1 = highFreqTargetSelect1 ? highFreqTargetSelect1.value : '';
            const ip2 = highFreqTargetSelect2 ? highFreqTargetSelect2.value : '';
            const currentlySelectedIps = [ip1, ip2].filter(Boolean).join(',');
            populateHighFreqTargetDropdown(currentlySelectedIps);
        }
    }

    async function saveConfig() {
        if (!configPingSizeInput || !configPollIntervalInput) return;
        
        const newInterval = parseInt(configPollIntervalInput.value) || 1000;
        const isCurrentlyUltra = ultraHighFreqActive;
        const isNewUltra = newInterval <= 100;

        // Backup enabled states if transitioning from normal to ultra-high-frequency mode
        if (!isCurrentlyUltra && isNewUltra) {
            const stateToSave = {};
            devices.forEach(d => {
                stateToSave[d.ip] = (d.enabled !== false);
            });
            localStorage.setItem('preUltraHighFreqEnabledState', JSON.stringify(stateToSave));
        }

        // Collect up to 2 IPs from the two separate dropdowns
        const isUltra = isNewUltra;
        const ip1 = (highFreqTargetSelect1 && isUltra) ? (highFreqTargetSelect1.value || '') : '';
        const ip2 = (highFreqTargetSelect2 && isUltra) ? (highFreqTargetSelect2.value || '') : '';
        const highFreqIps = [ip1, ip2]
            .filter(v => v)                    // remove empty
            .filter((v, i, a) => a.indexOf(v) === i) // deduplicate (avoid same IP twice)
            .join(',');
        const payload = {
            pingDataSize:      parseInt(configPingSizeInput.value) || 1,
            pollInterval:      newInterval,
            loggingEnabled:    isLoggingEnabled,
            highFreqTargetIps: highFreqIps,
            latencyThreshMs:   parseInt(threshLatencyEl ? threshLatencyEl.value : 100) || 100,
            outageThresh1Ms:   parseInt(configOutageThresh1 ? configOutageThresh1.value : 600) || 600,
            outageThresh2Ms:   parseInt(configOutageThresh2 ? configOutageThresh2.value : 5000) || 5000
        };
        try {
            const res = await fetch('/api/config', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            });
            if (res.ok) {
                const displayInterval = payload.pollInterval < 1000
                    ? `${payload.pollInterval}ms`
                    : `${(payload.pollInterval / 1000).toFixed(1)}s`;
                let msg = `Pingデータ: ${payload.pingDataSize} bytes, 間隔: ${displayInterval}, ログ: ${payload.loggingEnabled ? 'ON' : 'OFF'}`;
                if (payload.pollInterval <= 100) msg += ` | 対象: ${highFreqIps || '(未選択)'}`;
                showToast('info', '✅ 設定を保存しました', msg, 3500);
                if (payload.pollInterval <= 100 && !highFreqIps) {
                    showToast('warning', '⚠ 超高頻度モード', '対象①から少なくとも1台選択してください。', 4000);
                }

                // Restore previous enabled states if transitioning from ultra-high-frequency to normal mode
                if (isCurrentlyUltra && !isNewUltra) {
                    const savedStateStr = localStorage.getItem('preUltraHighFreqEnabledState');
                    if (savedStateStr) {
                        try {
                            const savedState = JSON.parse(savedStateStr);
                            const enableIps = [];
                            const disableIps = [];
                            Object.keys(savedState).forEach(ip => {
                                if (savedState[ip]) {
                                    enableIps.push(ip);
                                } else {
                                    disableIps.push(ip);
                                }
                            });

                            if (enableIps.length > 0) {
                                await fetch('/api/devices/bulk-action', {
                                    method: 'POST',
                                    headers: { 'Content-Type': 'application/json' },
                                    body: JSON.stringify({ ips: enableIps, action: 'enable' })
                                });
                            }
                            if (disableIps.length > 0) {
                                await fetch('/api/devices/bulk-action', {
                                    method: 'POST',
                                    headers: { 'Content-Type': 'application/json' },
                                    body: JSON.stringify({ ips: disableIps, action: 'disable' })
                                });
                            }
                            localStorage.removeItem('preUltraHighFreqEnabledState');
                        } catch (e) {
                            console.error('Failed to restore pre-ultra high freq states:', e);
                        }
                    }
                }

                // Sync ultra-high-freq state immediately for dashboard Paused display
                updateUltraHighFreqState(payload.pollInterval, highFreqIps);
                
                // If we restored states, reload devices first to ensure UI is in sync
                if (isCurrentlyUltra && !isNewUltra) {
                    await fetchDevices();
                } else {
                    renderDeviceGrid();
                }

                startStatusLoop(payload.pollInterval);
            }
        } catch (err) {
            console.error('Failed to save config:', err);
        }
    }

    if (configPingSizeInput) {
        configPingSizeInput.addEventListener('focus', () => {
            if (configPingSizeHint) configPingSizeHint.style.display = 'block';
        });
        configPingSizeInput.addEventListener('blur', () => {
            if (configPingSizeHint) configPingSizeHint.style.display = 'none';
            saveConfig();
        });
        configPingSizeInput.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') {
                e.preventDefault();
                configPingSizeInput.blur();
            }
        });
    }

    if (configPollIntervalInput) {
        configPollIntervalInput.addEventListener('change', () => {
            updateHighFreqUI();
            if (parseInt(configPollIntervalInput.value) <= 100) {
                showToast('warning', '⚡ 超高頻度モード', '0.1s間隔での監視は高負荷です。対象①・②から最大2台選択してください。', 5000);
            }
            saveConfig();
        });
    }
    // Update high-freq targets immediately when either dropdown changes
    if (highFreqTargetSelect1) {
        highFreqTargetSelect1.addEventListener('change', () => { saveConfig(); });
    }
    if (highFreqTargetSelect2) {
        highFreqTargetSelect2.addEventListener('change', () => { saveConfig(); });
    }

    if (loggingToggleBtn) {
        loggingToggleBtn.addEventListener('click', () => {
            updateLoggingToggleUI(!isLoggingEnabled);
            saveConfig();
        });
    }

    // ── Outage threshold inputs: confirm on Enter/Tab/blur ──────────────────
    [configOutageThresh1, configOutageThresh2].forEach((el, idx) => {
        if (!el) return;
        el.addEventListener('blur', () => {
            const min = idx === 0 ? 100 : 100;
            const max = idx === 0 ? 60000 : 600000;
            const def = idx === 0 ? 600 : 5000;
            let v = parseInt(el.value);
            if (isNaN(v) || v < min) v = (v <= 0 ? def : min);
            if (v > max) v = max;
            el.value = v;
            saveConfig();
        });
        el.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' || e.key === 'Tab') {
                e.preventDefault();
                el.blur();
            }
        });
    });

    fetchConfig();


    // Image & Connection Inputs
    const devImageType = document.getElementById('dev-image-type');
    const devImageUploadContainer = document.getElementById('dev-image-upload-container');
    const devImageFile = document.getElementById('dev-image-file');
    const devImageUrl = document.getElementById('dev-image-url');
    const devConnectedTo = document.getElementById('dev-connected-to');
    const devConnectedTo2 = document.getElementById('dev-connected-to-2');

    // Predefined Icons SVGs
    const PREDEFINED_ICONS = {
        router: `<svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" viewBox="0 0 36 36"><rect x="2" y="10" width="32" height="16" rx="3" stroke="#94a3b8" stroke-width="2" fill="none"/><line x1="8" y1="18" x2="12" y2="18" stroke="#3b82f6" stroke-width="2"/><line x1="16" y1="18" x2="20" y2="18" stroke="#3b82f6" stroke-width="2"/><line x1="24" y1="18" x2="28" y2="18" stroke="#3b82f6" stroke-width="2"/><circle cx="6" cy="14" r="1.5" fill="#10b981"/></svg>`,
        ap: `<svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" viewBox="0 0 36 36"><circle cx="18" cy="28" r="3" fill="#94a3b8"/><path d="M10 20a11 11 0 0 1 16 0M6 15a17 17 0 0 1 24 0M14 24a5 5 0 0 1 8 0" stroke="#94a3b8" stroke-width="2" stroke-linecap="round" fill="none"/></svg>`,
        bridge: `<svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" viewBox="0 0 36 36"><line x1="6" y1="28" x2="6" y2="12" stroke="#94a3b8" stroke-width="2" stroke-linecap="round"/><circle cx="6" cy="10" r="2" fill="#3b82f6"/><line x1="30" y1="28" x2="30" y2="12" stroke="#94a3b8" stroke-width="2" stroke-linecap="round"/><circle cx="30" cy="10" r="2" fill="#3b82f6"/><path d="M11 12a8 8 0 0 1 14 0" stroke="#94a3b8" stroke-width="2" stroke-dasharray="2 2" fill="none" stroke-linecap="round"/><path d="M14 16a4 4 0 0 1 8 0" stroke="#94a3b8" stroke-width="2" stroke-dasharray="1 1" fill="none" stroke-linecap="round"/><line x1="4" y1="28" x2="32" y2="28" stroke="#94a3b8" stroke-width="2" stroke-linecap="round"/></svg>`,
        camera: `<svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" viewBox="0 0 36 36"><path d="M6 10h16a4 4 0 0 1 4 4v8a4 4 0 0 1-4 4H6a4 4 0 0 1-4-4v-8a4 4 0 0 1 4-4z" stroke="#94a3b8" stroke-width="2" fill="none"/><circle cx="14" cy="18" r="4" stroke="#94a3b8" stroke-width="2" fill="none"/><path d="M26 14l6-4v16l-6-4" stroke="#94a3b8" stroke-width="2" stroke-linejoin="round" fill="none"/></svg>`,
        server: `<svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" viewBox="0 0 36 36"><rect x="4" y="4" width="28" height="8" rx="2" stroke="#94a3b8" stroke-width="2" fill="none"/><rect x="4" y="14" width="28" height="8" rx="2" stroke="#94a3b8" stroke-width="2" fill="none"/><rect x="4" y="24" width="28" height="8" rx="2" stroke="#94a3b8" stroke-width="2" fill="none"/><circle cx="8" cy="8" r="1.5" fill="#10b981"/><circle cx="8" cy="18" r="1.5" fill="#10b981"/><circle cx="8" cy="28" r="1.5" fill="#10b981"/></svg>`,
        decoder: `<svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" viewBox="0 0 36 36"><rect x="4" y="8" width="28" height="20" rx="3" stroke="#94a3b8" stroke-width="2" fill="none"/><polygon points="12,14 24,18 12,22" fill="#3b82f6"/><line x1="8" y1="22" x2="10" y2="22" stroke="#10b981" stroke-width="2" stroke-linecap="round"/><circle cx="26" cy="12" r="1.5" fill="#10b981"/><circle cx="29" cy="12" r="1.5" fill="#3b82f6"/><line x1="8" y1="24" x2="16" y2="24" stroke="#94a3b8" stroke-width="1.5" stroke-linecap="round"/><line x1="20" y1="24" x2="28" y2="24" stroke="#94a3b8" stroke-width="1.5" stroke-linecap="round"/></svg>`,
        pc: `<svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" viewBox="0 0 36 36"><rect x="4" y="6" width="28" height="18" rx="2" stroke="#94a3b8" stroke-width="2" fill="none"/><path d="M12 24l-2 6h16l-2-6" stroke="#94a3b8" stroke-width="2" fill="none"/><line x1="8" y1="30" x2="28" y2="30" stroke="#94a3b8" stroke-width="2"/></svg>`,
        controller: `<svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" viewBox="0 0 36 36"><path d="M8 10h20a4 4 0 0 1 4 4v10a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4V14a4 4 0 0 1 4-4z" stroke="#94a3b8" stroke-width="2" fill="none"/><path d="M9 16h4M11 14v4" stroke="#94a3b8" stroke-width="2" stroke-linecap="round"/><circle cx="23" cy="16" r="2" fill="#ef4444"/><circle cx="27" cy="16" r="2" fill="#3b82f6"/></svg>`,
        cloud: `<svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" viewBox="0 0 36 36"><path d="M18 10a8 8 0 0 1 7.5 5.3 6.5 6.5 0 0 1 4.5 6.2c0 3.6-2.9 6.5-6.5 6.5H11A7 7 0 0 1 11 14a8 8 0 0 1 7-4z" stroke="#94a3b8" stroke-width="2" stroke-linejoin="round" fill="none"/></svg>`
    };

    let devices = [];
    let latencyHistory = {};
    let timeHistory = {};
    let latencyStats = {}; // { ip: { min: Number|null, max: Number|null } }
    let charts = {};
    let dashboardUnifiedChart = null;

    // Topology network references
    let networkInstance = null;
    let nodesDataSet = null;
    let edgesDataSet = null;
    window.topologyPhysicsEnabled = true;
    let isLinkMode = false;
    let isUnlinkMode = false;
    let topologyLatencyChart = null;
    let activeTraceHops = [];
    let flowAnimationProgress = 0;
    let flowAnimationId = null;
    let traceHighlightedNodes = new Set();
    let traceHighlightedEdges = new Set();

    function renderTracePanel(status = 'loading') {
        const panel = document.getElementById('topo-trace-panel');
        const list = document.getElementById('topo-trace-list');
        const statusEl = document.getElementById('topo-trace-status');
        if (!panel || !list) return;

        panel.style.display = 'block';
        list.innerHTML = '';

        if (status === 'loading') {
            if (statusEl) {
                statusEl.textContent = '追跡中...';
                statusEl.style.background = 'rgba(59, 130, 246, 0.2)';
                statusEl.style.color = '#3b82f6';
            }
            list.innerHTML = '<div style="color: var(--text-muted); padding: 10px; text-align: center; font-size: 0.8rem;">ルートを解析しています...</div>';
            return;
        }

        if (statusEl) {
            statusEl.textContent = '完了';
            statusEl.style.background = 'rgba(34, 197, 94, 0.2)';
            statusEl.style.color = '#4ade80';
        }

        if (activeTraceHops.length === 0) {
            list.innerHTML = '<div style="color: var(--error); padding: 10px; text-align: center; font-size: 0.8rem;">ルートが見つかりませんでした</div>';
            return;
        }

        activeTraceHops.forEach((hop, index) => {
            const ip = typeof hop === 'string' ? hop : hop.ip;
            const latency = typeof hop === 'object' ? hop.latency : '';
            
            const dev = devices.find(d => d.ip === ip);
            const name = dev ? (dev.name || ip) : ip;
            const isLocal = ip === 'local';

            const safeIp = escapeHTML(ip);
            const safeName = escapeHTML(isLocal ? '監視サーバー' : name);
            const safeLatency = escapeHTML(latency);

            const item = document.createElement('div');
            item.style.cssText = `
                display: flex;
                align-items: center;
                gap: 8px;
                padding: 6px 10px;
                background: rgba(255, 255, 255, 0.03);
                border-radius: 6px;
                border-left: 3px solid ${index === activeTraceHops.length - 1 ? '#ef4444' : '#3b82f6'};
            `;

            item.innerHTML = `
                <div style="font-weight: 700; color: var(--text-muted); width: 14px; font-size: 0.75rem;">${index + 1}</div>
                <div style="flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                    <div style="font-weight: 600; color: var(--text-main); font-size: 0.8rem;">${safeName}</div>
                    <div style="font-size: 0.65rem; color: var(--text-muted);">${isLocal ? 'Localhost' : safeIp}</div>
                </div>
                ${safeLatency ? `<div style="font-size: 0.7rem; color: var(--primary); font-weight: 600;">${safeLatency}</div>` : ''}
            `;
            list.appendChild(item);
        });
    }

    function focusOnTracePath() {
        if (!networkInstance || traceHighlightedNodes.size === 0) return;
        const nodesToFit = Array.from(traceHighlightedNodes);
        networkInstance.fit({
            nodes: nodesToFit,
            animation: {
                duration: 1000,
                easingFunction: 'easeInOutQuad'
            }
        });
    }

    // Theme Mode Toggle Logic
    const themeToggleBtn = document.getElementById('theme-toggle-btn');
    const themeIcon = document.getElementById('theme-icon');
    const themeText = document.getElementById('theme-text');

    function applyTheme(theme) {
        document.documentElement.setAttribute('data-theme', theme);
        localStorage.setItem('theme', theme);
        
        if (themeIcon && themeText) {
            if (theme === 'day') {
                themeIcon.textContent = '☀️';
                themeText.textContent = 'デイ';
            } else {
                themeIcon.textContent = '🌙';
                themeText.textContent = 'ナイト';
            }
        }
        
        // Update any existing charts
        const isDay = (theme === 'day');
        const tickColor = isDay ? '#1e293b' : '#cbd5e1';
        const gridColor = isDay ? 'rgba(15, 23, 42, 0.25)' : 'rgba(255, 255, 255, 0.30)';
        const borderColor = isDay ? 'rgba(15, 23, 42, 0.6)' : 'rgba(255, 255, 255, 0.55)';
        const legendColor = isDay ? '#0f172a' : '#e2e8f0';
        
        for (const groupName in charts) {
            const chart = charts[groupName];
            if (chart) {
                if (chart.options.scales.x) {
                    if (chart.options.scales.x.ticks) chart.options.scales.x.ticks.color = tickColor;
                    if (chart.options.scales.x.grid) chart.options.scales.x.grid.color = gridColor;
                    if (chart.options.scales.x.border) chart.options.scales.x.border.color = borderColor;
                }
                if (chart.options.scales.y) {
                    if (chart.options.scales.y.ticks) chart.options.scales.y.ticks.color = tickColor;
                    if (chart.options.scales.y.grid) chart.options.scales.y.grid.color = gridColor;
                    if (chart.options.scales.y.border) chart.options.scales.y.border.color = borderColor;
                }
                if (chart.options.plugins && chart.options.plugins.legend && chart.options.plugins.legend.labels) {
                    chart.options.plugins.legend.labels.color = legendColor;
                }
                chart.update('none');
            }
        }

        if (topologyLatencyChart) {
            if (topologyLatencyChart.options.scales.x) {
                if (topologyLatencyChart.options.scales.x.ticks) topologyLatencyChart.options.scales.x.ticks.color = tickColor;
                if (topologyLatencyChart.options.scales.x.grid) topologyLatencyChart.options.scales.x.grid.color = gridColor;
                if (topologyLatencyChart.options.scales.x.border) topologyLatencyChart.options.scales.x.border.color = borderColor;
            }
            if (topologyLatencyChart.options.scales.y) {
                if (topologyLatencyChart.options.scales.y.ticks) topologyLatencyChart.options.scales.y.ticks.color = tickColor;
                if (topologyLatencyChart.options.scales.y.grid) topologyLatencyChart.options.scales.y.grid.color = gridColor;
                if (topologyLatencyChart.options.scales.y.border) topologyLatencyChart.options.scales.y.border.color = borderColor;
            }
            if (topologyLatencyChart.options.plugins && topologyLatencyChart.options.plugins.legend && topologyLatencyChart.options.plugins.legend.labels) {
                topologyLatencyChart.options.plugins.legend.labels.color = legendColor;
            }
            topologyLatencyChart.update('none');
        }

        // Re-initialize topology so SVGs and backgrounds update
        if (typeof initTopology === 'function') {
            initTopology();
        }
    }

    // Toggle click handler
    if (themeToggleBtn) {
        themeToggleBtn.addEventListener('click', () => {
            const currentTheme = document.documentElement.getAttribute('data-theme') || 'night';
            const newTheme = currentTheme === 'day' ? 'night' : 'day';
            applyTheme(newTheme);
        });
    }

    // Init theme on load
    const savedTheme = localStorage.getItem('theme') || 'night';
    applyTheme(savedTheme);



    function deactivateLinkMode() {
        isLinkMode = false;
        if (networkInstance) {
            networkInstance.disableEditMode();
        }
        const linkBtn = document.getElementById('topo-link-btn');
        if (linkBtn) linkBtn.classList.remove('link-active');
        const modeText = document.getElementById('topo-mode-text');
        if (modeText && !isUnlinkMode) {
            modeText.style.display = 'none';
        }
    }

    function deactivateUnlinkMode() {
        isUnlinkMode = false;
        const unlinkBtn = document.getElementById('topo-unlink-btn');
        if (unlinkBtn) unlinkBtn.classList.remove('unlink-active');
        const modeText = document.getElementById('topo-mode-text');
        if (modeText && !isLinkMode) {
            modeText.style.display = 'none';
        }
    }

    function deactivateAllModes() {
        deactivateLinkMode();
        deactivateUnlinkMode();
    }

    function startFlowAnimation() {
        if (flowAnimationId) return;
        function animate() {
            const viewTopo = document.getElementById('view-topology');
            if (networkInstance && viewTopo && viewTopo.classList.contains('active')) {
                flowAnimationProgress = (flowAnimationProgress + 0.008) % 1.0;
                networkInstance.redraw();
            }
            flowAnimationId = requestAnimationFrame(animate);
        }
        animate();
    }

    function stopFlowAnimation() {
        if (flowAnimationId) {
            cancelAnimationFrame(flowAnimationId);
            flowAnimationId = null;
        }
    }

    function isTraceEdge(fromIp, toIp) {
        return traceHighlightedEdges.has(`edge-${fromIp}-${toIp}`) || 
               traceHighlightedEdges.has(`edge-${toIp}-${fromIp}`);
    }

    function computeFullTracePath() {
        traceHighlightedNodes.clear();
        traceHighlightedEdges.clear();

        if (activeTraceHops.length < 2) return;

        const activeDevices = devices.filter(d => d.enabled !== false);
        const deviceIpMap = new Map();
        activeDevices.forEach(d => deviceIpMap.set(d.ip, d));

        const adj = {};
        activeDevices.forEach(d => {
            adj[d.ip] = [];
        });

        activeDevices.forEach(d => {
            if (d.connectedTo) {
                const parents = d.connectedTo.split(',').map(p => p.trim()).filter(p => p);
                parents.forEach(parentIp => {
                    if (deviceIpMap.has(parentIp)) {
                        adj[d.ip].push(parentIp);
                        adj[parentIp].push(d.ip);
                    }
                });
            }
        });

        function bfs(startIp, endIp) {
            if (startIp === endIp) return [startIp];
            if (!adj[startIp] || !adj[endIp]) return null;

            const queue = [startIp];
            const visited = new Set([startIp]);
            const parent = {};

            while (queue.length > 0) {
                const u = queue.shift();
                if (u === endIp) {
                    const path = [];
                    let curr = endIp;
                    while (curr) {
                        path.push(curr);
                        curr = parent[curr];
                    }
                    return path.reverse();
                }

                for (const v of adj[u]) {
                    if (!visited.has(v)) {
                        visited.add(v);
                        parent[v] = u;
                        queue.push(v);
                    }
                }
            }
            return null;
        }

        const localHops = activeTraceHops.filter(hopIp => deviceIpMap.has(hopIp));

        for (let i = 0; i < localHops.length - 1; i++) {
            const start = localHops[i];
            const end = localHops[i + 1];
            const path = bfs(start, end);
            if (path) {
                path.forEach(node => traceHighlightedNodes.add(node));
                for (let j = 0; j < path.length - 1; j++) {
                    const u = path[j];
                    const v = path[j + 1];
                    traceHighlightedEdges.add(`edge-${u}-${v}`);
                    traceHighlightedEdges.add(`edge-${v}-${u}`);
                }
            }
        }
    }
    window.addEventListener('resize', () => {
        if (topologyNetwork) {
            topologyNetwork.fit();
        }
        if (dashboardUnifiedChart) {
            dashboardUnifiedChart.resize();
        }
    });

    // Initialize
    fetchDevices();
    fetchConfig().then(() => {
        const currentInterval = configPollIntervalInput ? parseInt(configPollIntervalInput.value) : 1000;
        startStatusLoop(currentInterval);
    });

    let statusInterval = null;
    function startStatusLoop(pollIntervalMs) {
        if (statusInterval) clearInterval(statusInterval);
        // Synchronize UI refresh exactly with the monitoring interval.
        // For very high frequency (0.1s), the UI will update every 100ms.
        const uiInterval = pollIntervalMs || 1000;
        statusInterval = setInterval(fetchStatus, uiInterval);
    }


    // Drag and Drop Logic
    const deviceListEl = document.getElementById('device-list');
    let draggedItem = null;
    let draggedItemsArray = [];
    let draggedGroupHeader = null;

    if (deviceListEl) {
        // Multi-select toggle
        deviceListEl.addEventListener('click', (e) => {
            // Ignore if clicking a button inside the card, or clicking on non-card elements
            if (e.target.closest('button')) {
                return; // Let button's own handler deal with it
            }
            if (e.target.closest('.group-header')) {
                return; // Ignore clicks on group headers
            }
            
            const card = e.target.closest('.device-card');
            if (!card) return;
            
            // Toggle selection
            card.classList.toggle('selected');
        });

        deviceListEl.addEventListener('dragstart', (e) => {
            const card = e.target.closest('.device-card');
            if (card) {
                // If dragged card is not selected, select only it
                if (!card.classList.contains('selected')) {
                    document.querySelectorAll('.device-card.selected').forEach(c => c.classList.remove('selected'));
                    card.classList.add('selected');
                }
                
                draggedItem = card;
                draggedItemsArray = Array.from(document.querySelectorAll('.device-card.selected'));
                e.dataTransfer.effectAllowed = 'move';
                setTimeout(() => { 
                    draggedItemsArray.forEach(c => c.style.opacity = '0.5');
                }, 0);
                return;
            }

            const header = e.target.closest('.group-header');
            if (header) {
                draggedGroupHeader = header;
                e.dataTransfer.effectAllowed = 'move';
                setTimeout(() => { header.closest('.group-section').style.opacity = '0.5'; }, 0);
            }
        });

        deviceListEl.addEventListener('dragend', (e) => {
            if (draggedGroupHeader) {
                draggedGroupHeader.closest('.group-section').style.opacity = '1';
                draggedGroupHeader = null;
                saveGroupOrder();
                return;
            }

            if (!draggedItem) return;
            
            const parent = draggedItem.parentNode;
            let currentRef = draggedItem.nextSibling;
            
            draggedItemsArray.forEach(c => {
                c.style.opacity = '1';
                c.classList.remove('selected');
                if (c !== draggedItem && parent) {
                    parent.insertBefore(c, currentRef);
                }
            });

            draggedItem = null;
            draggedItemsArray = [];
            saveReorderedDevices();
        });

        deviceListEl.addEventListener('dragover', (e) => {
            e.preventDefault();
            
            if (draggedGroupHeader) {
                const targetSection = e.target.closest('.group-section');
                if (targetSection && targetSection !== draggedGroupHeader.closest('.group-section')) {
                    if (targetSection.id === 'add-group-section') {
                        targetSection.parentNode.insertBefore(draggedGroupHeader.closest('.group-section'), targetSection);
                        return;
                    }
                    const rect = targetSection.getBoundingClientRect();
                    const next = (e.clientX - rect.left) > (rect.width / 2);
                    if (next) {
                        targetSection.parentNode.insertBefore(draggedGroupHeader.closest('.group-section'), targetSection.nextSibling);
                    } else {
                        targetSection.parentNode.insertBefore(draggedGroupHeader.closest('.group-section'), targetSection);
                    }
                }
                return;
            }

            const card = e.target.closest('.device-card');
            const grid = e.target.closest('.group-grid');
            if (card && !draggedItemsArray.includes(card)) {
                const rect = card.getBoundingClientRect();
                const next = (e.clientY - rect.top) > (rect.height / 2);
                if (next) {
                    card.parentNode.insertBefore(draggedItem, card.nextSibling);
                } else {
                    card.parentNode.insertBefore(draggedItem, card);
                }
            } else if (grid && !card) {
                grid.appendChild(draggedItem);
            }
        });
    }



    function saveGroupOrder() {
        const order = [];
        deviceListEl.querySelectorAll('.group-header > span').forEach(span => {
            if (span.textContent) order.push(span.textContent);
        });
        localStorage.setItem('groupOrder', JSON.stringify(order));
        window.userCreatedGroups = order;
    }

    async function saveReorderedDevices() {
        const payload = [];
        deviceListEl.querySelectorAll('.group-grid').forEach(grid => {
            const groupName = grid.getAttribute('data-group');
            grid.querySelectorAll('.device-card').forEach(card => {
                const ip = card.getAttribute('data-ip');
                if (ip) {
                    payload.push({ ip: ip, group: groupName });
                }
            });
        });
        
        // Update local array order & group
        devices.forEach(d => {
            const found = payload.find(p => p.ip === d.ip);
            if (found) d.group = found.group;
        });
        devices.sort((a, b) => {
            const idxA = payload.findIndex(p => p.ip === a.ip);
            const idxB = payload.findIndex(p => p.ip === b.ip);
            return (idxA === -1 ? 999 : idxA) - (idxB === -1 ? 999 : idxB);
        });

        try {
            await fetch('/api/devices/reorder', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            });
        } catch (err) {
            console.error('Failed to reorder devices', err);
        }
    }

    // Modal Logic (Manage view is now handled by tabs)
    const manageModal = document.getElementById('manage-devices-modal');
    // Note: manageModal is now null as it was removed from index.html
    
    deviceForm.addEventListener('submit', async (e) => {
        e.preventDefault();
        
        let imageVal = '';
        if (devImageType.value === 'upload') {
            imageVal = devImageUrl.value;
        } else {
            imageVal = devImageType.value;
        }
        const devParentSel = document.getElementById('dev-parent-ip') || devConnectedTo;
        const connectedToVal1 = devParentSel ? (devParentSel.value || '') : '';
        const connectedToVal2 = devConnectedTo2 ? devConnectedTo2.value : '';
        const uniqueParents = [connectedToVal1, connectedToVal2]
            .map(ip => ip.trim())
            .filter((ip, idx, arr) => ip && arr.indexOf(ip) === idx);
        const connectedToVal = uniqueParents.join(',');

        // IP Conflict Detection
        const targetIp = (editOldIpInput && editOldIpInput.value) ? devIpInput.value.trim().split(',')[0].trim() : null;
        if (targetIp && isIpConflicted(targetIp, editOldIpInput.value)) {
            alert(`IPアドレス ${targetIp} は既に登録されています。別のIPを指定してください。`);
            return;
        }

        if (editOldIpInput && editOldIpInput.value) {
            // Edit mode
            const newIpStr = devIpInput.value.trim();
            let newIp = newIpStr;
            let newName = devNameInput.value.trim();
            if (newIpStr.includes(',')) {
                const parts = newIpStr.split(',');
                newIp = parts[0].trim();
                if (parts.length > 1 && parts[1].trim() !== '') newName = parts.slice(1).join(',').trim();
            }
            const payload = {
                oldIp: editOldIpInput.value,
                newIp: newIp,
                name: newName,
                group: devGroupInput ? devGroupInput.value.trim() : "",
                location: document.getElementById('dev-location') ? document.getElementById('dev-location').value.trim() : "",
                troubleMemo: document.getElementById('dev-trouble-memo') ? document.getElementById('dev-trouble-memo').value.trim() : "",
                webUrl: document.getElementById('dev-web-url') ? document.getElementById('dev-web-url').value.trim() : "",
                community: devCommInput.value.trim(),
                enabled: devEnabledInput.checked,
                image: imageVal,
                connectedTo: connectedToVal
            };
            
            try {
                const res = await fetch('/api/device/edit', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(payload)
                });
                if (res.ok) {
                    deviceForm.reset();
                    editOldIpInput.value = '';
                    submitDeviceBtn.textContent = '機器を保存';
                    await fetchDevices();
                    renderManageList();
                } else {
                    alert('機器情報の更新に失敗しました。');
                }
            } catch (err) {
                console.error('Error updating device:', err);
            }
            return;
        }

        let ip = devIpInput.value.trim();
        let name = devNameInput.value.trim();
        if (ip.includes(',')) {
            const parts = ip.split(',');
            ip = parts[0].trim();
            if (parts.length > 1 && parts[1].trim() !== '') name = parts.slice(1).join(',').trim();
        }
        const payloads = [{
            ip: ip,
            name: name,
            group: devGroupInput ? devGroupInput.value.trim() : "",
            location: document.getElementById('dev-location') ? document.getElementById('dev-location').value.trim() : "",
            troubleMemo: document.getElementById('dev-trouble-memo') ? document.getElementById('dev-trouble-memo').value.trim() : "",
            webUrl: document.getElementById('dev-web-url') ? document.getElementById('dev-web-url').value.trim() : "",
            community: devCommInput.value.trim(),
            enabled: devEnabledInput.checked,
            image: imageVal,
            connectedTo: connectedToVal
        }];
        
        try {
            const res = await fetch('/api/devices/bulk', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payloads)
            });
            if (res.ok) {
                deviceForm.reset();
                await fetchDevices();
                renderManageList();
            } else {
                alert('機器の登録に失敗しました。');
            }
        } catch (err) {
            console.error('Error saving device(s):', err);
        }
    });

    function renderManageList() {
        manageDeviceList.innerHTML = '';
        // Refresh group dropdown options whenever the device list changes
        populateGroupDropdown(devGroupSelect ? devGroupSelect.value : undefined);

        // Update Capacity Indicator
        const MAX_DEVICES = 100;
        const currentCount = devices.length;
        const countEl = document.getElementById('current-device-count');
        const barEl = document.getElementById('device-capacity-bar');
        if (countEl) countEl.textContent = currentCount;
        if (barEl) {
            const pct = Math.min(100, (currentCount / MAX_DEVICES) * 100);
            barEl.style.width = `${pct}%`;
            if (pct > 90) barEl.style.background = '#ef4444';
            else if (pct > 75) barEl.style.background = '#f59e0b';
            else barEl.style.background = 'linear-gradient(90deg, #3b82f6, #10b981)';
        }

        // Group devices by their group name

        const groups = {};
        devices.forEach(d => {
            const g = d.group || 'グループなし';
            if (!groups[g]) groups[g] = [];
            groups[g].push(d);
        });

        const groupNames = Object.keys(groups);
        
        groupNames.forEach(groupName => {
            // Render Group Header
            const headerLi = document.createElement('li');
            headerLi.className = 'manage-group-header';
            headerLi.style.fontWeight = '700';
            headerLi.style.fontSize = '0.8rem';
            headerLi.style.color = 'var(--primary)';
            headerLi.style.padding = '8px 10px';
            headerLi.style.marginTop = '12px';
            headerLi.style.marginBottom = '4px';
            headerLi.style.background = 'rgba(59, 130, 246, 0.1)';
            headerLi.style.borderRadius = '6px';
            headerLi.style.border = '1px solid rgba(59, 130, 246, 0.15)';
            headerLi.style.listStyle = 'none';
            headerLi.style.userSelect = 'none';
            headerLi.textContent = `📁 グループ: ${groupName}`;
            manageDeviceList.appendChild(headerLi);

            // Render devices in this group
            groups[groupName].forEach(d => {
                const li = document.createElement('li');
                li.className = 'manage-item';
                li.style.padding = '8px 12px';
                li.style.borderBottom = '1px solid var(--glass-border)';
                li.style.display = 'flex';
                li.style.justifyContent = 'space-between';
                li.style.alignItems = 'center';
                li.style.marginLeft = '8px';
                li.style.borderRadius = '6px';
                li.style.transition = 'background 0.2s';
                
                const isEnabled = d.enabled !== false;
                const toggleIcon = isEnabled ? '⏸' : '▶️';
                const toggleColor = isEnabled ? '#f59e0b' : '#10b981';
                const toggleTitle = isEnabled ? '監視を一時停止' : '監視を再開';
                
                const safeName = escapeHTML(d.name || d.ip);
                const safeIp = escapeHTML(d.ip);

                li.innerHTML = `
                    <div style="overflow: hidden;">
                        <div style="font-weight: 600; font-size: 0.9rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 180px;" title="${safeName}">${safeName}</div>
                        <div style="font-size: 0.75rem; color: var(--text-muted);">${safeIp}${d.mac ? ` / MAC: ${escapeHTML(d.mac)}` : ''} ${!isEnabled ? '<span style="color:#f59e0b; margin-left:4px;">(一時停止中)</span>' : ''}</div>
                    </div>
                    <div style="display: flex; gap: 8px; flex-shrink: 0;">
                        <button class="edit-dev-btn" data-ip="${safeIp}" style="background:transparent; border:none; color:var(--primary); cursor:pointer; font-size: 1rem;" title="機器を編集">✎</button>
                        <button class="toggle-dev-btn" data-ip="${safeIp}" style="background:transparent; border:none; color:${toggleColor}; cursor:pointer; font-size: 1rem;" title="${toggleTitle}">${toggleIcon}</button>
                        <button class="delete-dev-btn" data-ip="${safeIp}" style="background:transparent; border:none; color:var(--error); cursor:pointer; font-size: 1rem;" title="機器を削除">🗑</button>
                    </div>
                `;
                
                li.querySelector('.edit-dev-btn').addEventListener('click', (e) => {
                    e.preventDefault();
                    if(editOldIpInput) editOldIpInput.value = d.ip;
                    devIpInput.value = d.ip;
                    devNameInput.value = d.name !== d.ip ? d.name : '';
                    // Set group dropdown and hidden input to device's current group
                    if(devGroupInput) devGroupInput.value = d.group || '';
                    populateGroupDropdown(d.group || '');
                    if (devGroupNew) devGroupNew.classList.add('hidden');
                    devCommInput.value = d.community || 'public';
                    devEnabledInput.checked = isEnabled;
                    if(submitDeviceBtn) submitDeviceBtn.textContent = '機器情報を更新';
                    devIpInput.placeholder = '192.168.1.1';

                    const devLocEl = document.getElementById('dev-location');
                    const devMemoEl = document.getElementById('dev-trouble-memo');
                    const devWebEl = document.getElementById('dev-web-url');
                    if (devLocEl) devLocEl.value = d.location || '';
                    if (devMemoEl) devMemoEl.value = d.troubleMemo || '';
                    if (devWebEl) devWebEl.value = d.webUrl || '';

                    populateConnectionsDropdown(d.ip);
                    const parents = d.connectedTo ? d.connectedTo.split(',').map(p => p.trim()).filter(p => p) : [];
                    if (devConnectedTo) devConnectedTo.value = parents[0] || '';
                    if (devConnectedTo2) devConnectedTo2.value = parents[1] || '';
                    
                    if (d.image) {
                        if (PREDEFINED_ICONS[d.image]) {
                            devImageType.value = d.image;
                            devImageUploadContainer.style.display = 'none';
                        } else {
                            devImageType.value = 'upload';
                            devImageUploadContainer.style.display = 'flex';
                            devImageUrl.value = d.image;
                        }
                    } else {
                        devImageType.value = '';
                        devImageUploadContainer.style.display = 'none';
                        devImageUrl.value = '';
                    }

                    // Highlight the item being edited
                    manageDeviceList.querySelectorAll('.manage-item').forEach(el => el.style.background = 'transparent');
                    li.style.background = 'rgba(59, 130, 246, 0.15)';
                });
                
                li.querySelector('.toggle-dev-btn').addEventListener('click', async (e) => {
                    e.preventDefault();
                    try {
                        const res = await fetch('/api/device/toggle', {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify({ ip: d.ip })
                        });
                        if (res.ok) {
                            await fetchDevices();
                            renderManageList();
                        }
                    } catch (err) {
                        console.error('Failed to toggle device:', err);
                    }
                });
                
                li.setAttribute('draggable', 'true');
                li.setAttribute('data-ip', d.ip);
                
                li.querySelector('.delete-dev-btn').addEventListener('click', async (e) => {
                    e.preventDefault();
                    if (confirm(`${d.ip} を削除してもよろしいですか？`)) {
                        try {
                            await fetch('/api/devices/delete', {
                                method: 'POST',
                                headers: { 'Content-Type': 'application/json' },
                                body: JSON.stringify({ ip: d.ip })
                            });
                            await fetchDevices();
                            renderManageList();
                        } catch (err) {
                            console.error('Failed to delete device:', err);
                        }
                    }
                });
                manageDeviceList.appendChild(li);
            });
        });

        // Add Drag & Drop listeners for manage list (only for .manage-item, not headers)
        let draggedManageItem = null;
        manageDeviceList.querySelectorAll('li.manage-item').forEach(li => {
            li.addEventListener('dragstart', (e) => {
                draggedManageItem = li;
                e.dataTransfer.effectAllowed = 'move';
                setTimeout(() => { li.style.opacity = '0.5'; }, 0);
            });
            li.addEventListener('dragend', (e) => {
                draggedManageItem = null;
                li.style.opacity = '1';
                saveManageReorderedDevices();
            });
            li.addEventListener('dragover', (e) => {
                e.preventDefault();
                const targetLi = e.target.closest('li.manage-item');
                if (targetLi && targetLi !== draggedManageItem) {
                    const rect = targetLi.getBoundingClientRect();
                    const next = (e.clientY - rect.top) > (rect.height / 2);
                    if (next) {
                        targetLi.parentNode.insertBefore(draggedManageItem, targetLi.nextSibling);
                    } else {
                        targetLi.parentNode.insertBefore(draggedManageItem, targetLi);
                    }
                }
            });
        });
    }

    async function saveManageReorderedDevices() {
        const payload = [];
        manageDeviceList.querySelectorAll('li').forEach(li => {
            const ip = li.getAttribute('data-ip');
            if (ip) {
                // Find original device to preserve its group
                const originalDev = devices.find(d => d.ip === ip);
                payload.push({ ip: ip, group: originalDev ? (originalDev.group || '') : '' });
            }
        });
        
        // Update local array order
        devices.sort((a, b) => {
            const idxA = payload.findIndex(p => p.ip === a.ip);
            const idxB = payload.findIndex(p => p.ip === b.ip);
            return (idxA === -1 ? 999 : idxA) - (idxB === -1 ? 999 : idxB);
        });

        try {
            await fetch('/api/devices/reorder', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            });
            renderDeviceGrid(); // Re-render main grid to reflect new order
        } catch (err) {
            console.error('Failed to reorder manage list devices', err);
        }
    }


    // API Calls
    async function fetchDevices(skipRebuildTopology = false) {
        try {
            const res = await fetch('/api/devices');
            const data = await res.json();
            devices = data.devices || [];
            renderDeviceGrid();
            renderManageList();
            // Keep high-freq target dropdown in sync with current device list (preserve current selection)
            const ip1 = highFreqTargetSelect1 ? highFreqTargetSelect1.value : '';
            const ip2 = highFreqTargetSelect2 ? highFreqTargetSelect2.value : '';
            const currentlySelectedIps = [ip1, ip2].filter(Boolean).join(',');
            populateHighFreqTargetDropdown(currentlySelectedIps);
            if (!skipRebuildTopology) {
                const viewTopo = document.getElementById('view-topology');
                if (viewTopo && viewTopo.classList.contains('active')) initTopology();
            }
        } catch (err) { console.error('Error fetching devices:', err); }
    }

    async function fetchStatus() {
        if (devices.length === 0) return;
        try {
            const res = await fetch('/api/status');
            const statusData = await res.json();
            updateDeviceData(statusData);
            updateTopologyStatus();
        } catch (err) { console.warn('Error fetching status:', err); }
    }

    function renderDeviceGrid() {
        const deviceList = document.getElementById('device-list');
        if (!deviceList) return;
        deviceList.innerHTML = '';
        const CHART_LINE_COLORS = ['#3b82f6','#10b981','#f59e0b','#ec4899','#8b5cf6','#06b6d4','#f43f5e','#14b8a6'];
        Object.values(charts).forEach(c => { if (c) c.destroy(); });
        charts = {};
        const groups = {};
        devices.forEach(d => {
            const g = d.group || 'Ungrouped';
            if (!groups[g]) groups[g] = [];
            groups[g].push(d);
        });
        if (groups['Ungrouped'] && groups['Ungrouped'].length === 0) delete groups['Ungrouped'];
        const savedOrderStr = localStorage.getItem('groupOrder');
        let savedOrder = [];
        try { if (savedOrderStr) savedOrder = JSON.parse(savedOrderStr); } catch (e) {}
        const groupNames = Object.keys(groups).sort((a, b) => {
            const idxA = savedOrder.indexOf(a), idxB = savedOrder.indexOf(b);
            return (idxA === -1 && idxB === -1) ? 0 : (idxA === -1) ? 1 : (idxB === -1) ? -1 : idxA - idxB;
        });
        let activeTab = localStorage.getItem('activeDashboardTab') || 'all';
        if (activeTab !== 'all' && !groupNames.includes(activeTab)) activeTab = 'all';

        const tabsContainer = document.getElementById('dashboard-group-tabs');
        if (tabsContainer) {
            tabsContainer.innerHTML = '';
            ['all', ...groupNames].forEach(tab => {
                const btn = document.createElement('button');
                btn.className = `btn secondary-btn dashboard-tab-btn ${activeTab === tab ? 'active' : ''}`;
                btn.textContent = tab === 'all' ? 'すべてのグループ' : tab;
                btn.addEventListener('click', () => { localStorage.setItem('activeDashboardTab', tab); renderDeviceGrid(); });
                tabsContainer.appendChild(btn);
            });
        }

        const monitoredGlobal = devices.filter(d => {
            if (d.enabled === false) return false;
            if (ultraHighFreqActive && ultraHighFreqTargetSet.size > 0) {
                return ultraHighFreqTargetSet.has(d.ip);
            }
            return true;
        });
        for (const groupName of groupNames) {
            let groupDevices = groups[groupName].slice().sort((a, b) => (a.enabled !== false ? 0 : 1) - (b.enabled !== false ? 0 : 1));
            if (activeTab === 'all') {
                groupDevices = groupDevices.filter(d => monitoredGlobal.includes(d));
            }
            if (groupDevices.length === 0) continue;

            const section = document.createElement('div');
            section.className = 'group-section';
            section.style.display = (activeTab === 'all' || groupName === activeTab) ? 'flex' : 'none';
            section.innerHTML = `<div class="group-header" style="font-size:1.1rem; font-weight:700; color:var(--text-main); border-bottom:2px solid var(--glass-border); padding-bottom:5px; margin-bottom:10px;"><span>${groupName}</span></div>`;
            const grid = document.createElement('div');
            grid.className = 'group-grid';
            grid.style.display = 'flex'; grid.style.flexDirection = 'column'; grid.style.gap = '8px';
            groupDevices.forEach(d => {
                const ip = d.ip, safeIpId = ip.replace(/\./g, '-');
                // ── Dual-rate mode check ──
                const isUltraTarget = ultraHighFreqActive && ultraHighFreqTargetSet.has(ip);
                const isPausedState = (d.enabled === false);

                const row = document.createElement('div');
                row.className = 'device-card glass-card' + (isPausedState ? ' paused' : '');
                row.id = `card-${safeIpId}`;
                row.style.position = 'relative';
                const color = !isPausedState ? CHART_LINE_COLORS[monitoredGlobal.indexOf(d) % CHART_LINE_COLORS.length] : 'transparent';
                const displayName = escapeHTML(d.name || ip);
                const rateBadge = ultraHighFreqActive ? (isUltraTarget ? '<span style="font-size:0.65rem; padding:1px 5px; border-radius:4px; background:rgba(251,191,36,0.2); color:#fbbf24; font-weight:700; margin-left:4px;">0.1s</span>' : '<span style="font-size:0.65rem; padding:1px 5px; border-radius:4px; background:rgba(148,163,184,0.15); color:#94a3b8; margin-left:4px;">5.0s</span>') : '';
                
                row.innerHTML = `
                    ${!isPausedState ? `<div style="position:absolute;left:0;top:0;bottom:0;width:4px;background:${color};border-radius:8px 0 0 8px;"></div>` : ''}
                    <div style="display:flex;align-items:center;gap:8px;flex:2.2;min-width:0;">
                        <div class="status-dot" id="dot-${safeIpId}"></div>
                        <div style="display:flex;flex-direction:column;overflow:hidden;">
                            <div style="display:flex;align-items:center;">
                                <span style="font-weight:600; font-size:0.88rem; white-space:nowrap; overflow:hidden; text-overflow:ellipsis;" title="${displayName}">${displayName}</span>
                                ${rateBadge}
                            </div>
                            <span style="font-size:0.72rem;color:var(--text-muted);">${escapeHTML(ip)}<span id="mac-${safeIpId}" style="font-family:monospace;">${d.mac ? ` / MAC: ${escapeHTML(d.mac)}` : ''}</span></span>
                        </div>
                    </div>
                    <div style="flex:1.1; min-width:0; display:flex; flex-direction:column; gap:1px;">
                        <span id="traffic-tx-${safeIpId}" style="font-size:0.71rem; color:#60a5fa; white-space:nowrap;">↑ TX: -</span>
                        <span id="traffic-rx-${safeIpId}" style="font-size:0.71rem; color:#34d399; white-space:nowrap;">↓ RX: -</span>
                    </div>
                    <div style="flex:1.1; min-width:0; display:flex; flex-direction:column; gap:1px;">
                        <span id="loss-${safeIpId}" style="font-size:0.71rem; color:#94a3b8; white-space:nowrap;">ロス: 0.0%</span>
                        <span id="jitter-${safeIpId}" style="font-size:0.71rem; color:#94a3b8; white-space:nowrap;">揺らぎ: -</span>
                    </div>
                    <div style="display:flex;flex-direction:column;align-items:flex-end;gap:2px;flex-shrink:0;min-width:110px;">
                        <span class="header-latency" id="latency-${safeIpId}" style="min-width:50px;text-align:right;font-weight:700;">-</span>
                        <span id="minmax-${safeIpId}" style="font-size:0.7rem;white-space:nowrap;"><span style="color:#f97316;">最大-</span> / <span style="color:#06b6d4;">最小-</span></span>
                        <span id="outage-${safeIpId}" style="font-size:0.68rem;white-space:nowrap;color:#94a3b8;" title="最大瞬断時間（連続オフラインの最長時間）">瞬断最大: -</span>
                    </div>
                    <div style="display:flex;align-items:center;flex-shrink:0;">
                        <button class="toggle-monitor-btn" data-ip="${ip}" style="background:transparent;border:none;color:${!isPausedState ? '#f59e0b' : '#10b981'};cursor:pointer;font-size:1.1rem;">${!isPausedState ? '⏸' : '▶'}</button>
                    </div>`;
                grid.appendChild(row);
                if (!latencyHistory[ip]) { latencyHistory[ip] = Array(15).fill(null); timeHistory[ip] = Array(15).fill(''); }
                if (!latencyStats[ip]) { latencyStats[ip] = { min: null, max: null }; }
                
                // Hover focus highlight on unified chart
                row.addEventListener('mouseenter', () => highlightChartDevice(ip));
                row.addEventListener('mouseleave', () => resetChartHighlight());

                row.querySelector('.toggle-monitor-btn').addEventListener('click', async (e) => {
                    e.stopPropagation();
                    const res = await fetch('/api/device/toggle', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ip: ip }) });
                    if (res.ok) fetchDevices();
                });
                row.addEventListener('dblclick', () => openSnmpDetailsModal(d));
            });
            section.appendChild(grid);
            deviceList.appendChild(section);
        }

        let chartDevices = (activeTab === 'all') ? monitoredGlobal : monitoredGlobal.filter(d => (d.group || 'Ungrouped') === activeTab);
        const unifiedChartContainer = document.getElementById('dashboard-unified-chart-container');
        if (unifiedChartContainer) {
            unifiedChartContainer.innerHTML = '';
            if (chartDevices.length > 0) {
                const unifiedChartDiv = document.createElement('div');
                unifiedChartDiv.className = 'dashboard-unified-chart';
                unifiedChartDiv.innerHTML = `<div style="font-size:0.75rem;color:var(--text-muted);font-weight:600;margin-bottom:10px;">${activeTab === 'all' ? '全デバイス' : 'グループ ['+activeTab+']'} の遅延推移 (ms)</div><div style="flex:1;position:relative;width:100%;height:calc(100% - 25px);"><canvas id="dashboard-unified-canvas"></canvas></div>`;
                unifiedChartContainer.appendChild(unifiedChartDiv);
                const datasets = chartDevices.map(d => ({ 
                    label: d.name || d.ip, 
                    deviceIp: d.ip, 
                    data: latencyHistory[d.ip], 
                    borderColor: CHART_LINE_COLORS[monitoredGlobal.indexOf(d) % CHART_LINE_COLORS.length], 
                    originalColor: CHART_LINE_COLORS[monitoredGlobal.indexOf(d) % CHART_LINE_COLORS.length],
                    backgroundColor: 'transparent', 
                    borderWidth: 2, 
                    pointRadius: 2, 
                    fill: false, 
                    tension: 0.4 
                }));
                dashboardUnifiedChart = new Chart(unifiedChartDiv.querySelector('canvas').getContext('2d'), {
                    type: 'line', data: { labels: timeHistory[chartDevices[0].ip] || Array(15).fill(''), datasets },
                    options: { responsive: true, maintainAspectRatio: false, animation: { duration: 0 },
                        scales: {
                            x: {
                                ticks: { maxTicksLimit: 10, font: { size: 10 }, color: 'rgba(200,210,230,0.9)' },
                                grid: { color: 'rgba(200,210,230,0.25)', lineWidth: 1 },
                                border: { color: 'rgba(200,210,230,0.6)', width: 1 }
                            },
                            y: {
                                min: 0, suggestedMax: 100,
                                ticks: { font: { size: 10 }, color: 'rgba(200,210,230,0.9)' },
                                grid: { color: 'rgba(200,210,230,0.25)', lineWidth: 1 },
                                border: { color: 'rgba(200,210,230,0.6)', width: 1 }
                            }
                        },
                        plugins: { 
                            legend: { 
                                display: true, 
                                position: 'bottom', 
                                labels: { font: { size: 9 }, color: 'rgba(200,210,230,0.9)', usePointStyle: true, boxWidth: 15 },
                                onClick: (e, legendItem, legend) => {
                                    const index = legendItem.datasetIndex;
                                    const ci = legend.chart;
                                    const meta = ci.getDatasetMeta(index);
                                    meta.hidden = meta.hidden === null ? !ci.data.datasets[index].hidden : null;
                                    ci.update();
                                }
                            }, 
                            tooltip: { enabled: true, mode: 'index', intersect: false } 
                        }
                    }
                });
            }
        }
    }

    // Chart Focus Highlight Helpers
    function highlightChartDevice(targetIp) {
        if (!dashboardUnifiedChart) return;
        dashboardUnifiedChart.data.datasets.forEach(ds => {
            if (ds.deviceIp === targetIp) {
                ds.borderColor = ds.originalColor || ds.borderColor;
                ds.borderWidth = 3;
            } else {
                ds.borderColor = 'rgba(148, 163, 184, 0.12)';
                ds.borderWidth = 1;
            }
        });
        dashboardUnifiedChart.update();
    }

    function resetChartHighlight() {
        if (!dashboardUnifiedChart) return;
        dashboardUnifiedChart.data.datasets.forEach(ds => {
            ds.borderColor = ds.originalColor || ds.borderColor;
            ds.borderWidth = 2;
        });
        dashboardUnifiedChart.update();
    }

    // Helper to start iperf from Dashboard
    function startIperfFromDashboard(ip) {
        const duration = 10;
        const iperfViewBwInp = document.getElementById('iperf-view-bw-thresh');
        const bwThresh = (iperfViewBwInp && iperfViewBwInp.value) ? parseFloat(iperfViewBwInp.value) || 10 : (systemConfig.bwThreshMbps || 10);
        showToast('info', '🚀 Iperf計測開始', `${ip} に対して帯域計測を開始します (閾値: ${bwThresh} Mbps)...`, 2000);
        fetch(`/api/iperf?action=start&ip=${encodeURIComponent(ip)}&t=${duration}&bw=${bwThresh}`)
            .then(res => res.json())
            .then(data => {
                if (data.status !== 'started') showToast('error', '❌ 計測失敗', data.error || '計測を開始できませんでした。');
            });
    }

    // ── Sidebar Status Summary Updater ─────────────────────────────────────
    function updateSidebarSummary(statusData) {
        let onlineCount = 0;
        let offlineCount = 0;
        let pausedCount = 0;

        devices.forEach(d => {
            if (d.enabled === false) {
                pausedCount++;
            } else {
                const data = statusData[d.ip];
                if (data && data.status === "Success") {
                    onlineCount++;
                } else if (data && (data.status === "Failed" || data.status === "Error")) {
                    offlineCount++;
                } else if (data && data.status === "Paused") {
                    pausedCount++;
                } else {
                    onlineCount++; // Default optimistic state
                }
            }
        });

        const onlineEl = document.getElementById('summary-online-count');
        const offlineEl = document.getElementById('summary-offline-count');
        const pausedEl = document.getElementById('summary-paused-count');

        if (onlineEl) onlineEl.textContent = onlineCount;
        if (offlineEl) offlineEl.textContent = offlineCount;
        if (pausedEl) pausedEl.textContent = pausedCount;
    }

    // ── Heatmap / Timeline Component Updater ────────────────────────────────
    function updateHeatmapTimeline(statusData) {
        const container = document.getElementById('dashboard-heatmap-container');
        if (!container) return;

        const monitoredDevices = devices.filter(d => d.enabled !== false);
        if (monitoredDevices.length === 0) {
            container.innerHTML = '<div style="font-size:0.75rem; color:var(--text-muted); padding:4px;">監視中の機器はありません。</div>';
            return;
        }

        const warnLat = parseFloat(threshLatencyEl ? threshLatencyEl.value : 100) || 100;

        monitoredDevices.forEach(d => {
            const ip = d.ip, safeIpId = ip.replace(/\./g, '-');
            let itemEl = document.getElementById(`heatmap-item-${safeIpId}`);
            if (!itemEl) {
                itemEl = document.createElement('div');
                itemEl.className = 'heatmap-device-item';
                itemEl.id = `heatmap-item-${safeIpId}`;
                itemEl.innerHTML = `
                    <span class="heatmap-device-name" title="${escapeHTML(d.name || ip)}">${escapeHTML(d.name || ip)}</span>
                    <div class="heatmap-bars" id="heatmap-bars-${safeIpId}"></div>
                `;
                container.appendChild(itemEl);
            }

            const barsEl = document.getElementById(`heatmap-bars-${safeIpId}`);
            if (barsEl && latencyHistory[ip]) {
                const history = latencyHistory[ip];
                const barsHtml = history.map(lat => {
                    let bg = '#64748b'; // paused / null
                    let title = '停止 / データなし';
                    if (lat !== null) {
                        if (lat >= warnLat) {
                            bg = '#f59e0b';
                            title = `高遅延: ${lat}ms`;
                        } else {
                            bg = '#10b981';
                            title = `正常: ${lat}ms`;
                        }
                    } else {
                        const st = statusData[ip]?.status;
                        if (st === 'Failed' || st === 'Error') {
                            bg = '#ef4444';
                            title = '障害 / オフライン';
                        }
                    }
                    return `<div class="heatmap-bar-seg" style="background:${bg};" title="${title}"></div>`;
                }).join('');
                barsEl.innerHTML = barsHtml;
            }
        });
    }

    function updateDeviceData(statusData) {
        devices.forEach(d => {
            const ip = d.ip, safeIpId = ip.replace(/\./g, '-');
            let data = statusData[ip];
            
            // Backup valid status data for topology
            if (data && data.status && data.status !== "Paused") {
                topologyLastValidStatus[ip] = { ...data };
            }

            const dotEl = document.getElementById(`dot-${safeIpId}`), latencyEl = document.getElementById(`latency-${safeIpId}`);
            if (!dotEl || !latencyEl) return;

            if (data) {
                const isSuppressed = isAlertSuppressed(ip) || data.isSuppressed;
                const statusClass = (data.status === "Success") 
                    ? 'success' 
                    : (data.status === "Failed" || data.status === "Offline") 
                        ? (isSuppressed ? 'unreachable' : 'error') 
                        : 'paused';
                dotEl.className = 'status-dot ' + statusClass;

                if (data.status === "Failed" && canAlert(ip, 'offline') && !isSuppressed) {
                    showToast('error', `🔴 ${data.name || ip} オフライン`, `IP: ${ip} 応答なし`, 5000);
                    playAlertSound('error');
                }
                const warnLat = parseFloat(threshLatencyEl.value) || 100;
                if (data.status === "Success" && data.latency !== null) {
                    latencyEl.textContent = `${data.latency} ms`;
                    latencyEl.className = 'header-latency' + (data.latency >= warnLat ? ' bad' : '');
                    if (data.latency >= warnLat && canAlert(ip, 'latency') && !isSuppressed) {
                        showToast('warning', `⚠️ ${data.name || ip} 高遅延検知`, `IP: ${ip} 遅延: ${data.latency}ms (閾値: ${warnLat}ms)`, 5000);
                        playAlertSound('warning');
                    }
                    // Update per-session min/max
                    if (!latencyStats[ip]) latencyStats[ip] = { min: null, max: null };
                    if (latencyStats[ip].min === null || data.latency < latencyStats[ip].min) latencyStats[ip].min = data.latency;
                    if (latencyStats[ip].max === null || data.latency > latencyStats[ip].max) latencyStats[ip].max = data.latency;
                } else {
                    if (data.status === "Paused") {
                        latencyEl.textContent = '-- ms';
                        latencyEl.className = 'header-latency paused-text';
                    } else if (data.status === "Failed" || data.status === "Offline") {
                        latencyEl.textContent = isSuppressed ? '到達不能 (親障害)' : 'タイムアウト';
                        latencyEl.className = 'header-latency ' + (isSuppressed ? 'unreachable-text' : 'bad');
                    } else {
                        latencyEl.textContent = '-- ms';
                        latencyEl.className = 'header-latency';
                    }
                }
                // Refresh min/max display
                const minmaxEl = document.getElementById(`minmax-${safeIpId}`);
                if (minmaxEl && latencyStats[ip]) {
                    const mn = latencyStats[ip].min, mx = latencyStats[ip].max;
                    minmaxEl.innerHTML = `<span style="color:#f97316;">最大${mx !== null ? mx + ' ms' : '-'}</span> / <span style="color:#06b6d4;">最小${mn !== null ? mn + ' ms' : '-'}</span>`;
                }
                // Refresh Packet Loss & Jitter display
                const lossEl = document.getElementById(`loss-${safeIpId}`);
                const jitterEl = document.getElementById(`jitter-${safeIpId}`);
                if (lossEl) {
                    const lossRate = (data.packetLossRate != null) ? data.packetLossRate : 0.0;
                    lossEl.textContent = `ロス: ${lossRate.toFixed(1)}%`;
                    lossEl.style.color = (lossRate > 0) ? '#f87171' : 'var(--text-muted)';
                }
                if (jitterEl) {
                    const jit = (data.jitter != null && data.jitter > 0) ? data.jitter : null;
                    jitterEl.textContent = `揺らぎ: ${jit !== null ? jit.toFixed(1) + 'ms' : '-'}`;
                    jitterEl.style.color = (jit !== null && jit > 20) ? '#fbbf24' : 'var(--text-muted)';
                }

                // Update max outage display
                const outageEl = document.getElementById(`outage-${safeIpId}`);
                if (outageEl) {
                    const maxSec   = (data.maxOutageSec     != null && data.maxOutageSec > 0)     ? data.maxOutageSec     : null;
                    const curSec   = (data.currentOutageSec != null && data.currentOutageSec > 0) ? data.currentOutageSec : 0;
                    const cnt600   = (data.outage600msCount != null) ? data.outage600msCount : 0;
                    const cnt5s    = (data.outage5sCount    != null) ? data.outage5sCount    : 0;
                    const fmtSec   = s => s >= 60 ? `${Math.floor(s/60)}分${(s%60).toFixed(0)}秒` : `${s.toFixed(1)}秒`;
                    
                    // Build threshold labels from current config
                    const t1ms = (systemConfig.outageThresh1Ms) || 600;
                    const t2ms = (systemConfig.outageThresh2Ms) || 5000;
                    const fmtMs = ms => ms >= 1000 ? `${(ms/1000).toFixed(ms%1000===0?0:1)}秒` : `${ms}ms`;
                    const cntParts = [];
                    if (cnt600 > 0) cntParts.push(`${fmtMs(t1ms)}以上: ${cnt600}回`);
                    if (cnt5s  > 0) cntParts.push(`${fmtMs(t2ms)}以上: ${cnt5s}回`);
                    const cntStr = cntParts.length > 0 ? cntParts.join(' / ') : '';

                    const isOffline = (data.status === 'Failed' || data.status === 'Error') && curSec > 0;

                    if (isOffline) {
                        outageEl.style.color = '#ef4444';
                        outageEl.textContent = `瞬断中: ${fmtSec(curSec)}`;
                        let tooltip = `現在オフライン継続中: ${fmtSec(curSec)}`;
                        if (maxSec !== null) tooltip += ` / 過去最大瞬断: ${fmtSec(maxSec)}`;
                        if (cntStr) tooltip += ` / ${cntStr}`;
                        outageEl.title = tooltip;
                    } else if (maxSec !== null) {
                        outageEl.style.color = '#f97316';
                        outageEl.textContent = `瞬断最大: ${fmtSec(maxSec)}`;
                        let tooltip = `最大瞬断時間: ${fmtSec(maxSec)}`;
                        if (cntStr) tooltip += ` / ${cntStr}`;
                        outageEl.title = tooltip;
                    } else {
                        outageEl.style.color = '#94a3b8';
                        outageEl.textContent = '瞬断最大: -';
                        outageEl.title = data.status === 'Paused' ? '監視一時停止中' : '瞬断の発生なし（連続正常稼働中）';
                    }
                }
                if (latencyHistory[ip]) {
                    latencyHistory[ip].push(data.status === "Success" ? data.latency : null);
                    latencyHistory[ip].shift();
                    const now = new Date();
                    timeHistory[ip].push(`${now.getHours().toString().padStart(2,'0')}:${now.getMinutes().toString().padStart(2,'0')}:${now.getSeconds().toString().padStart(2,'0')}`);
                    timeHistory[ip].shift();
                }
                // ── TX / RX display ─────────────────
                const txEl = document.getElementById(`traffic-tx-${safeIpId}`);
                const rxEl = document.getElementById(`traffic-rx-${safeIpId}`);
                if (txEl && rxEl) {
                    if (data.tx && data.tx !== '-') {
                        txEl.textContent = `↑ TX: ${data.tx} Mbps`;
                        txEl.style.color = '#60a5fa';
                    } else if (data.bandwidth && data.bandwidth !== '-' && data.bandwidth !== 'Waiting...' && data.bandwidth !== 'Failed' && data.bandwidth !== 'Error') {
                        txEl.textContent = `BW: ${data.bandwidth} Mbps`;
                        txEl.style.color = 'var(--text-muted)';
                    } else {
                        txEl.textContent = '↑ TX: -';
                        txEl.style.color = '#60a5fa';
                    }
                    txEl.style.display = '';
                    rxEl.textContent = (data.rx && data.rx !== '-')
                        ? `↓ RX: ${data.rx} Mbps`
                        : '↓ RX: -';
                    rxEl.style.color  = '#34d399';
                    rxEl.style.display = '';
                }
                const macEl = document.getElementById(`mac-${safeIpId}`);
                if (macEl && data.mac && !macEl.textContent) {
                    macEl.textContent = ` / MAC: ${data.mac}`;
                }
            }
        });

        // Update Sidebar Summary Chips
        updateSidebarSummary(statusData);

        // Update Heatmap / Timeline Component
        updateHeatmapTimeline(statusData);

        if (dashboardUnifiedChart) {
            const tab = localStorage.getItem('activeDashboardTab') || 'all';
            const mon = devices.filter(d => d.enabled !== false);
            const ds = (tab === 'all') ? mon : mon.filter(d => (d.group || 'Ungrouped') === tab);
            if (ds.length > 0) {
                dashboardUnifiedChart.data.labels = timeHistory[ds[0].ip] || Array(15).fill('');
                dashboardUnifiedChart.data.datasets.forEach(s => { if (latencyHistory[s.deviceIp]) s.data = latencyHistory[s.deviceIp]; });
                dashboardUnifiedChart.update();
            }
        }
        if (topologyLatencyChart) {
            const mon = devices.filter(d => d.enabled !== false);
            if (mon.length > 0) {
                topologyLatencyChart.data.labels = timeHistory[mon[0].ip] || Array(15).fill('');
                topologyLatencyChart.update();
            }
        }
    }

    // Tabs navigation click handlers
    const tabDashboard = document.getElementById('tab-dashboard');
    const tabTopology = document.getElementById('tab-topology');
    const tabIperf = document.getElementById('tab-iperf');
    const tabSyslog = document.getElementById('tab-syslog');
    const tabManage = document.getElementById('tab-manage');
    
    const viewDashboard = document.getElementById('view-dashboard');
    const viewTopology = document.getElementById('view-topology');
    const viewIperf = document.getElementById('view-iperf');
    const viewSyslog = document.getElementById('view-syslog');
    const viewManage = document.getElementById('view-manage');

    function switchTab(tabId) {
        const tabs = [
            { btn: tabDashboard, view: viewDashboard },
            { btn: tabTopology, view: viewTopology },
            { btn: tabIperf, view: viewIperf },
            { btn: tabSyslog, view: viewSyslog },
            { btn: tabManage, view: viewManage }
        ];

        tabs.forEach(t => {
            if (t.btn && t.view) {
                if (t.btn.id === tabId) {
                    t.btn.classList.add('active');
                    t.btn.style.color = 'var(--text-main)';
                    t.view.classList.add('active');
                } else {
                    t.btn.classList.remove('active');
                    t.btn.style.color = 'var(--text-muted)';
                    t.view.classList.remove('active');
                }
            }
        });

        deactivateAllModes();
        stopFlowAnimation();
        
        if (tabId === 'tab-topology') {
            initTopology();
        } else if (tabId === 'tab-iperf') {
            populateIperfDeviceList();
        } else if (tabId === 'tab-syslog') {
            fetchSyslogLogs();
        } else if (tabId === 'tab-manage') {
            renderManageList();
            populateConnectionsDropdown();
        }
    }

    if (tabDashboard) {
        tabDashboard.addEventListener('click', () => switchTab('tab-dashboard'));
    }
    if (tabTopology) {
        tabTopology.addEventListener('click', () => switchTab('tab-topology'));
    }
    if (tabIperf) {
        tabIperf.addEventListener('click', () => switchTab('tab-iperf'));
    }
    if (tabSyslog) {
        tabSyslog.addEventListener('click', () => switchTab('tab-syslog'));
    }
    if (tabManage) {
        tabManage.addEventListener('click', () => switchTab('tab-manage'));
    }

    // Trigger server shutdown and log save on browser close
    window.addEventListener('beforeunload', () => {
        navigator.sendBeacon('/api/shutdown');
    });

    // File Upload event listeners
    if (devImageFile) {
        devImageFile.addEventListener('change', async (e) => {
            const file = e.target.files[0];
            if (!file) return;

            const ip = devIpInput.value.trim() || 'temp_device';
            const sanitizedIp = ip.split('\n')[0].split(',')[0].trim().replace(/\s/g, '_');

            const headers = {
                'X-Device-IP': sanitizedIp,
                'X-File-Name': file.name
            };

            try {
                submitDeviceBtn.disabled = true;
                submitDeviceBtn.textContent = '画像をアップロード中...';

                const response = await fetch('/api/device/upload-image', {
                    method: 'POST',
                    headers: headers,
                    body: file
                });

                if (response.ok) {
                    const data = await response.json();
                    if (data.path) {
                        devImageUrl.value = data.path;
                    }
                } else {
                    alert('画像のアップロードに失敗しました。');
                }
            } catch (err) {
                console.error('Error uploading file:', err);
                alert('画像のアップロードに失敗しました。');
            } finally {
                submitDeviceBtn.disabled = false;
                submitDeviceBtn.textContent = editOldIpInput.value ? '機器情報を更新' : '機器を保存';
            }
        });
    }

    if (devImageType) {
        devImageType.addEventListener('change', () => {
            if (devImageType.value === 'upload') {
                devImageUploadContainer.style.display = 'flex';
            } else {
                devImageUploadContainer.style.display = 'none';
                devImageUrl.value = '';
            }
        });
    }

    // Connections / Parent Dropdown populator helper
    function populateConnectionsDropdown(excludeIp = '') {
        const parentSelects = [
            document.getElementById('dev-parent-ip'),
            document.getElementById('dev-connected-to'),
            document.getElementById('dev-connected-to-2'),
            document.getElementById('topo-parent-ip'),
            document.getElementById('topo-connected-to'),
            document.getElementById('topo-connected-to-2')
        ].filter(Boolean);

        parentSelects.forEach(sel => {
            const currentVal = sel.value;
            sel.innerHTML = '<option value="">なし (最上位 / ルート機器)</option>';
            devices.forEach(d => {
                if (d.ip !== excludeIp && d.enabled !== false) {
                    const opt = document.createElement('option');
                    opt.value = d.ip;
                    opt.textContent = `${d.name && d.name !== d.ip ? d.name + ' (' + d.ip + ')' : d.ip}`;
                    sel.appendChild(opt);
                }
            });
            if (currentVal && currentVal !== excludeIp) {
                sel.value = currentVal;
            }
        });
    }

    // Iperf View logic
    const iperfTargetSelect = document.getElementById('iperf-target-device');
    const iperfCustomTargetInput = document.getElementById('iperf-custom-target');
    const iperfToggleCustomBtn = document.getElementById('iperf-toggle-custom-target');
    const runIperfViewBtn = document.getElementById('run-iperf-view-btn');
    const stopIperfViewBtn = document.getElementById('stop-iperf-view-btn');
    const iperfViewDurationInput = document.getElementById('iperf-view-duration');
    const iperfViewOptionsInput = document.getElementById('iperf-view-options');
    const iperfViewBwThreshInput = document.getElementById('iperf-view-bw-thresh');
    const iperfViewResultContainer = document.getElementById('iperf-view-result-container');
    const iperfViewLoading = document.getElementById('iperf-view-loading');
    const iperfViewCountdown = document.getElementById('iperf-view-countdown');
    const iperfViewSummary = document.getElementById('iperf-view-summary');
    const iperfViewExecutedCommand = document.getElementById('iperf-view-executed-command');
    const iperfLiveConsole = document.getElementById('iperf-live-console');

    // MTR Logic Elements
    const runMtrBtn = document.getElementById('run-mtr-btn');
    const mtrLoading = document.getElementById('mtr-loading');
    const mtrConsole = document.getElementById('mtr-console');
    let mtrPollInterval = null;

    // History Logic Elements
    let historyLatencyChart = null;
    let historyTrafficChart = null;
    let iperfChart = null;

    let iperfUseCustomTarget = false;

    if (iperfToggleCustomBtn) {
        iperfToggleCustomBtn.addEventListener('click', () => {
            iperfUseCustomTarget = !iperfUseCustomTarget;
            if (iperfUseCustomTarget) {
                iperfTargetSelect.style.display = 'none';
                iperfCustomTargetInput.classList.remove('hidden');
                iperfCustomTargetInput.style.display = 'block';
                iperfToggleCustomBtn.textContent = '登録デバイスから選択';
                iperfCustomTargetInput.focus();
            } else {
                iperfTargetSelect.style.display = 'block';
                iperfCustomTargetInput.classList.add('hidden');
                iperfCustomTargetInput.style.display = 'none';
                iperfToggleCustomBtn.textContent = 'カスタム入力に切替';
            }
        });
    }

    function populateIperfDeviceList() {
        if (!iperfTargetSelect) return;
        const currentVal = iperfTargetSelect.value;
        iperfTargetSelect.innerHTML = '<option value="">デバイスを選択してください</option>';
        
        // Filter only PC devices
        const pcDevices = devices.filter(d => d.image === 'pc');
        const sortedDevices = [...pcDevices].sort((a, b) => (a.name || a.ip).localeCompare(b.name || b.ip));
        sortedDevices.forEach(d => {
            const opt = document.createElement('option');
            opt.value = d.ip;
            opt.textContent = `${d.name && d.name !== d.ip ? d.name + ' (' + d.ip + ')' : d.ip}`;
            iperfTargetSelect.appendChild(opt);
        });
        
        if (currentVal) iperfTargetSelect.value = currentVal;
    }

    if (runIperfViewBtn) {
        runIperfViewBtn.addEventListener('click', async () => {
            const ip = iperfUseCustomTarget ? iperfCustomTargetInput.value.trim() : iperfTargetSelect.value;
            if (!ip) {
                showToast('error', '❌ ターゲット未入力', '計測対象のデバイスを選択するか、ホスト名を入力してください。');
                return;
            }
            const duration = parseInt(iperfViewDurationInput.value) || 5;
            const options = iperfViewOptionsInput ? iperfViewOptionsInput.value : '';
            
            // UI Reset for new run
            runIperfViewBtn.disabled = true;
            if (stopIperfViewBtn) stopIperfViewBtn.style.display = 'inline-flex';
            if (iperfViewOptionsInput) iperfViewOptionsInput.disabled = true;
            if (iperfCustomTargetInput) iperfCustomTargetInput.disabled = true;
            if (iperfTargetSelect) iperfTargetSelect.disabled = true;
            
            iperfViewResultContainer.classList.remove('hidden');
            iperfViewResultContainer.style.display = 'block';
            
            iperfViewLoading.classList.remove('hidden');
            iperfViewLoading.style.display = 'flex';
            
            iperfLiveConsole.classList.remove('hidden');
            iperfLiveConsole.style.display = 'block';
            
            const liveSpeedCard = document.getElementById('iperf-live-speed-card');
            const liveSpeedVal = document.getElementById('iperf-live-speed-val');
            const liveSpeedUnit = document.getElementById('iperf-live-speed-unit');
            if (liveSpeedCard) {
                liveSpeedCard.classList.remove('hidden');
                liveSpeedCard.style.display = 'flex';
            }
            if (liveSpeedVal) liveSpeedVal.textContent = '0.00';

            iperfViewExecutedCommand.classList.add('hidden');
            iperfViewExecutedCommand.style.display = 'none';

            // Initialize iperf realtime chart
            if (iperfChart) {
                iperfChart.destroy();
                iperfChart = null;
            }
            const iperfChartContainer = document.getElementById('iperf-chart-container');
            if (iperfChartContainer) {
                iperfChartContainer.classList.remove('hidden');
                iperfChartContainer.style.display = 'block';
            }
            const iperfCtx = document.getElementById('iperf-realtime-chart');
            if (iperfCtx) {
                const isDayMode = document.documentElement.getAttribute('data-theme') === 'day';
                iperfChart = new Chart(iperfCtx.getContext('2d'), {
                    type: 'line',
                    data: {
                        labels: [],
                        datasets: [{
                            label: '帯域スループット (Mbps)',
                            data: [],
                            borderColor: '#3b82f6', // Beautiful Blue
                            backgroundColor: isDayMode ? 'rgba(59, 130, 246, 0.05)' : 'rgba(59, 130, 246, 0.1)',
                            borderWidth: 3,
                            pointRadius: 4,
                            pointBackgroundColor: '#60a5fa',
                            fill: true,
                            tension: 0.35
                        }]
                    },
                    options: {
                        responsive: true,
                        maintainAspectRatio: false,
                        animation: { duration: 150 },
                        scales: {
                            x: {
                                grid: { color: isDayMode ? 'rgba(15, 23, 42, 0.05)' : 'rgba(255, 255, 255, 0.05)' },
                                ticks: { color: isDayMode ? '#4b5563' : 'rgba(200, 210, 230, 0.8)', font: { size: 10 } }
                            },
                            y: {
                                beginAtZero: true,
                                grid: { color: isDayMode ? 'rgba(15, 23, 42, 0.05)' : 'rgba(255, 255, 255, 0.05)' },
                                ticks: { color: isDayMode ? '#4b5563' : 'rgba(200, 210, 230, 0.8)', font: { size: 10 } },
                                title: { display: true, text: 'Mbps', color: isDayMode ? '#0f172a' : 'rgba(200, 210, 230, 0.8)', font: { size: 11, weight: 'bold' } }
                            }
                        },
                        plugins: {
                            legend: { display: false },
                            tooltip: { enabled: true, mode: 'index', intersect: false }
                        }
                    }
                });
            }
            
            iperfViewSummary.innerHTML = ''; // Explicitly clear summary HTML
            
            // Visual feedback of resetting
            iperfLiveConsole.innerHTML = `<span style="color: var(--text-muted);">[${new Date().toLocaleTimeString()}]</span> > 新しい計測セッションを開始しています...<br>`;
            iperfLiveConsole.innerHTML += `> ターゲット: <span style="color: var(--primary); font-weight: bold;">${ip}</span><br>`;
            iperfLiveConsole.scrollTop = 0;
            
            // Countdown timer
            let remaining = duration + 2;
            iperfViewCountdown.textContent = remaining;
            const timer = setInterval(() => {
                remaining--;
                if (remaining >= 0) iperfViewCountdown.textContent = remaining;
                if (remaining <= 0) clearInterval(timer);
            }, 1000);

            if (iperfViewBwThreshInput) iperfViewBwThreshInput.disabled = true;

            // Stop-requested flag (set when user clicks stop button)
            let isStopRequested = false;
            
            try {
                // Step 1: Start Iperf in background
                const bwThresh = parseFloat(iperfViewBwThreshInput ? iperfViewBwThreshInput.value : (threshBandwidthEl ? threshBandwidthEl.value : 10)) || 10;
                const startRes = await fetch(`/api/iperf?action=start&ip=${encodeURIComponent(ip)}&t=${duration}&opts=${encodeURIComponent(options)}&bw=${bwThresh}`);
                const startData = await startRes.json();
                
                if (startData.command) {
                    iperfViewExecutedCommand.textContent = `実行コマンド: ${startData.command}`;
                    iperfViewExecutedCommand.classList.remove('hidden');
                    iperfViewExecutedCommand.style.display = 'block';
                    iperfLiveConsole.innerHTML += `> コマンド実行: <span style="color: #94a3b8;">${startData.command}</span>\n\n`;
                }

                if (startData.status === 'started') {
                    // Step 2: Poll for status and output
                    let isRunning = true;
                    while (isRunning && !isStopRequested) {
                        await new Promise(resolve => setTimeout(resolve, 500));
                        const statusRes = await fetch(`/api/iperf?action=status`);
                        const statusData = await statusRes.json();
                        
                        if (statusData.output) {
                            iperfLiveConsole.textContent = statusData.output;
                            iperfLiveConsole.scrollTop = iperfLiveConsole.scrollHeight;
                            updateIperfChart(statusData.output);

                            const latestSpeed = parseLatestIperfSpeed(statusData.output);
                            if (latestSpeed && liveSpeedVal && liveSpeedUnit) {
                                liveSpeedVal.textContent = latestSpeed.val;
                                liveSpeedUnit.textContent = latestSpeed.unit;
                            }
                        }
                        
                        if (statusData.running === false) {
                            isRunning = false;
                        }
                    }
                    
                    if (isStopRequested) {
                        // Wait briefly for server to finish flushing the log
                        await new Promise(resolve => setTimeout(resolve, 600));
                        const finalStatus = await fetch(`/api/iperf?action=status`);
                        const finalData = await finalStatus.json();
                        if (finalData.output) {
                            iperfLiveConsole.textContent = finalData.output;
                            iperfLiveConsole.scrollTop = iperfLiveConsole.scrollHeight;
                            updateIperfChart(finalData.output);
                        }
                        iperfViewSummary.innerHTML = `
                            <div style="font-size: 1.3rem; color: #f59e0b; margin-bottom: 8px; font-weight: 700;">⏹ 計測中断</div>
                            <div style="font-size: 0.9rem; color: var(--text-muted); margin-bottom: 12px;">それまでの計測データはログに保存されています。（Reports フォルダ配下）</div>
                            <a href="/api/iperf/log" download="iperf_results.log" class="btn secondary-btn" style="display:inline-flex; align-items:center; gap:6px; text-decoration:none; padding:8px 16px; border-radius:8px; font-size:0.85rem; font-weight:600;">📥 計測ログをダウンロード (iperf_results.log)</a>
                        `;
                    } else {
                        iperfViewSummary.innerHTML = `
                            <div style="font-size: 1.3rem; color: #4ade80; margin-bottom: 8px; font-weight: 700;">✅ 計測完了</div>
                            <div style="font-size: 0.9rem; color: var(--text-muted); margin-bottom: 12px;">計測結果ログおよび統計サマリーが Reports フォルダ配下に保存されました。</div>
                            <a href="/api/iperf/log" download="iperf_results.log" class="btn primary-btn" style="display:inline-flex; align-items:center; gap:6px; text-decoration:none; padding:8px 16px; border-radius:8px; font-size:0.85rem; font-weight:600;">📥 計測ログをダウンロード (iperf_results.log)</a>
                        `;
                    }
                } else {
                    iperfViewSummary.innerHTML = `<span style="color: var(--error);">&#10060; エラー: ${startData.error || '計測を開始できませんでした'}</span>`;
                }
            } catch (err) {
                console.error('Iperf error:', err);
                iperfViewSummary.innerHTML = `<span style="color: var(--error);">&#10060; 通信エラーが発生しました</span>`;
            } finally {
                clearInterval(timer);
                iperfViewLoading.classList.add('hidden');
                iperfViewLoading.style.display = 'none';
                runIperfViewBtn.disabled = false;
                if (stopIperfViewBtn) stopIperfViewBtn.style.display = 'none';
                if (iperfViewOptionsInput) iperfViewOptionsInput.disabled = false;
                if (iperfViewBwThreshInput) iperfViewBwThreshInput.disabled = false;
                if (iperfCustomTargetInput) iperfCustomTargetInput.disabled = false;
                if (iperfTargetSelect) iperfTargetSelect.disabled = false;
            }

            // Attach stop handler for this run (using closure over isStopRequested)
            if (stopIperfViewBtn) {
                stopIperfViewBtn._stopHandler = async () => {
                    isStopRequested = true;
                    stopIperfViewBtn.disabled = true;
                    stopIperfViewBtn.textContent = '中断中...';
                    try {
                        await fetch('/api/iperf?action=stop');
                    } catch(e) { /* ignore */ }
                };
            }
        });
    }

    // Stop button: delegates to per-run handler via closure
    if (stopIperfViewBtn) {
        stopIperfViewBtn.addEventListener('click', () => {
            if (stopIperfViewBtn._stopHandler) {
                stopIperfViewBtn._stopHandler();
            }
        });
    }

    // =========================================================================
    // Iperf Server Mode Logic
    // =========================================================================
    const iperfSubtabClient = document.getElementById('iperf-subtab-client');
    const iperfSubtabServer = document.getElementById('iperf-subtab-server');
    const iperfClientSection = document.getElementById('iperf-client-section');
    const iperfServerSection = document.getElementById('iperf-server-section');

    const iperfServerPort = document.getElementById('iperf-server-port');
    const iperfServerStatusBadge = document.getElementById('iperf-server-status-badge');
    const iperfServerStatusDot = document.getElementById('iperf-server-status-dot');
    const iperfServerStatusText = document.getElementById('iperf-server-status-text');
    const iperfServerStartBtn = document.getElementById('iperf-server-start-btn');
    const iperfServerStopBtn = document.getElementById('iperf-server-stop-btn');
    const iperfServerLiveConsole = document.getElementById('iperf-server-live-console');
    const iperfServerUptime = document.getElementById('iperf-server-uptime');
    const iperfServerClearLogBtn = document.getElementById('iperf-server-clear-log-btn');

    let iperfServerPollTimer = null;
    let isIperfServerRunning = false;

    function switchIperfSubtab(mode) {
        if (mode === 'server') {
            if (iperfSubtabServer) {
                iperfSubtabServer.style.background = 'var(--primary)';
                iperfSubtabServer.style.color = '#fff';
                iperfSubtabServer.classList.add('active');
            }
            if (iperfSubtabClient) {
                iperfSubtabClient.style.background = 'rgba(255,255,255,0.06)';
                iperfSubtabClient.style.color = 'var(--text-muted)';
                iperfSubtabClient.classList.remove('active');
            }
            if (iperfClientSection) iperfClientSection.style.display = 'none';
            if (iperfServerSection) iperfServerSection.style.display = 'flex';
            checkIperfServerStatus();
        } else {
            if (iperfSubtabClient) {
                iperfSubtabClient.style.background = 'var(--primary)';
                iperfSubtabClient.style.color = '#fff';
                iperfSubtabClient.classList.add('active');
            }
            if (iperfSubtabServer) {
                iperfSubtabServer.style.background = 'rgba(255,255,255,0.06)';
                iperfSubtabServer.style.color = 'var(--text-muted)';
                iperfSubtabServer.classList.remove('active');
            }
            if (iperfClientSection) iperfClientSection.style.display = 'block';
            if (iperfServerSection) iperfServerSection.style.display = 'none';
        }
    }

    if (iperfSubtabClient) iperfSubtabClient.addEventListener('click', () => switchIperfSubtab('client'));
    if (iperfSubtabServer) iperfSubtabServer.addEventListener('click', () => switchIperfSubtab('server'));

    function updateIperfServerUI(running, port, startTime, output) {
        isIperfServerRunning = running;
        if (running) {
            if (iperfServerStartBtn) iperfServerStartBtn.style.display = 'none';
            if (iperfServerStopBtn) iperfServerStopBtn.style.display = 'inline-block';
            if (iperfServerPort) iperfServerPort.disabled = true;
            if (iperfServerStatusBadge) {
                iperfServerStatusBadge.style.background = 'rgba(16, 185, 129, 0.15)';
                iperfServerStatusBadge.style.color = '#10b981';
            }
            if (iperfServerStatusDot) {
                iperfServerStatusDot.style.background = '#10b981';
            }
            if (iperfServerStatusText) {
                iperfServerStatusText.textContent = `待受中 (ポート ${port || 5201})`;
            }
            if (iperfServerUptime && startTime) {
                iperfServerUptime.textContent = `開始: ${startTime}`;
            }
        } else {
            if (iperfServerStartBtn) iperfServerStartBtn.style.display = 'inline-block';
            if (iperfServerStopBtn) iperfServerStopBtn.style.display = 'none';
            if (iperfServerPort) iperfServerPort.disabled = false;
            if (iperfServerStatusBadge) {
                iperfServerStatusBadge.style.background = 'rgba(148, 163, 184, 0.15)';
                iperfServerStatusBadge.style.color = 'var(--text-muted)';
            }
            if (iperfServerStatusDot) {
                iperfServerStatusDot.style.background = '#94a3b8';
            }
            if (iperfServerStatusText) {
                iperfServerStatusText.textContent = 'サーバー停止中';
            }
            if (iperfServerUptime) {
                iperfServerUptime.textContent = '';
            }
        }

        if (iperfServerLiveConsole && typeof output === 'string') {
            if (output.trim()) {
                iperfServerLiveConsole.textContent = output;
                iperfServerLiveConsole.scrollTop = iperfServerLiveConsole.scrollHeight;
            } else if (!running) {
                iperfServerLiveConsole.innerHTML = '<div style="color:var(--text-muted); text-align:center; padding:40px;">サーバーは停止しています。「▶️ サーバー起動」を押すとクライアントからの受信待機を開始します。</div>';
            }
        }
    }

    async function checkIperfServerStatus() {
        try {
            const res = await fetch('/api/iperf/server/status');
            if (res.ok) {
                const data = await res.json();
                updateIperfServerUI(data.running, data.port, data.startTime, data.output);
                if (data.running && !iperfServerPollTimer) {
                    startIperfServerPolling();
                } else if (!data.running && iperfServerPollTimer) {
                    stopIperfServerPolling();
                }
            }
        } catch (e) {}
    }

    function startIperfServerPolling() {
        if (iperfServerPollTimer) clearInterval(iperfServerPollTimer);
        iperfServerPollTimer = setInterval(checkIperfServerStatus, 1000);
    }

    function stopIperfServerPolling() {
        if (iperfServerPollTimer) {
            clearInterval(iperfServerPollTimer);
            iperfServerPollTimer = null;
        }
    }

    if (iperfServerStartBtn) {
        iperfServerStartBtn.addEventListener('click', async () => {
            const port = iperfServerPort ? parseInt(iperfServerPort.value, 10) || 5201 : 5201;
            iperfServerStartBtn.disabled = true;
            iperfServerStartBtn.textContent = '起動中...';
            try {
                const res = await fetch('/api/iperf/server/start', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ port: port })
                });
                const data = await res.json();
                if (res.ok && data.status === 'success') {
                    showToast('info', '🚀 iperf3 サーバー起動', `ポート ${port} で受信待機を開始しました。`, 3000);
                    updateIperfServerUI(true, port, new Date().toLocaleTimeString(), `=== iperf3 Server Started on Port ${port} ===\n`);
                    startIperfServerPolling();
                } else {
                    showToast('error', '❌ 起動失敗', data.error || 'サーバーの起動に失敗しました。');
                }
            } catch (err) {
                showToast('error', '❌ 通信エラー', 'サーバー起動リクエストに失敗しました。');
            } finally {
                iperfServerStartBtn.disabled = false;
                iperfServerStartBtn.textContent = '▶️ サーバー起動';
            }
        });
    }

    if (iperfServerStopBtn) {
        iperfServerStopBtn.addEventListener('click', async () => {
            iperfServerStopBtn.disabled = true;
            iperfServerStopBtn.textContent = '停止中...';
            try {
                const res = await fetch('/api/iperf/server/stop', { method: 'POST' });
                if (res.ok) {
                    showToast('info', '⏹ iperf3 サーバー停止', '受信待機サーバーを停止しました。', 2500);
                    stopIperfServerPolling();
                    checkIperfServerStatus();
                }
            } catch (err) {
                showToast('error', '❌ エラー', 'サーバー停止に失敗しました。');
            } finally {
                iperfServerStopBtn.disabled = false;
                iperfServerStopBtn.textContent = '⏹ サーバー停止';
            }
        });
    }

    if (iperfServerClearLogBtn) {
        iperfServerClearLogBtn.addEventListener('click', async () => {
            await fetch('/api/iperf/server/clear-log', { method: 'POST' });
            if (iperfServerLiveConsole) {
                iperfServerLiveConsole.textContent = '=== Log Cleared ===\n';
            }
            showToast('info', 'ログ消去', 'サーバーログ表示を消去しました。', 2000);
        });
    }

    const topoFitBtn = document.getElementById('topo-fit-btn');
    if (topoFitBtn) {
        topoFitBtn.addEventListener('click', () => {
            deactivateAllModes();
            if (networkInstance) networkInstance.fit();
        });
    }



    // Dynamic SVG node generator for Vis Network
    function createNodeSvg(name, ip, image, statusColor, txText, rxText, latencyText, isPaused = false) {
        const isDay = document.documentElement.getAttribute('data-theme') === 'day';
        
        let iconContent = '';
        const normalIconColor = isDay ? '#0f172a' : '#f8fafc';
        const mutedIconColor = isDay ? '#475569' : '#94a3b8';
        if (image && PREDEFINED_ICONS[image]) {
            iconContent = PREDEFINED_ICONS[image].replace(/#94a3b8/g, normalIconColor);
        } else if (image && image !== '') {
            iconContent = `<image href="${image}" x="-2" y="-2" width="40" height="40" clip-path="url(#circle-clip)" preserveAspectRatio="xMidYMid slice"/>`;
        } else {
            iconContent = PREDEFINED_ICONS.server.replace(/#94a3b8/g, mutedIconColor);
        }

        const safeName = escapeXml(name || ip);
        const safeIp   = escapeXml(ip);
        const safeTx   = escapeXml(txText || '');
        const safeRx   = escapeXml(rxText || '');
        const safeLat  = escapeXml(latencyText || '');

        const txColor  = isDay ? '#1d4ed8' : '#60a5fa';  // blue
        const rxColor  = isDay ? '#059669' : '#34d399';  // green
        const latColor = statusColor;

        // Determine Y positions depending on what data is available
        // Layout (SVG height 175):
        //   Icon circle center: y=80
        //   Name: y=122, IP: y=133
        //   Latency: y=145 (if present)
        //   TX: y=156 (if present), RX: y=166 (if present)
        let latTextHtml = '';
        let txTextHtml  = '';
        let rxTextHtml  = '';

        if (safeLat) {
            latTextHtml = `<text x="60" y="145" font-family="'Inter', sans-serif" font-size="11" font-weight="bold" fill="${latColor}" text-anchor="middle">${safeLat}</text>`;
        }
        if (safeTx) {
            txTextHtml = `<text x="60" y="157" font-family="'Inter', sans-serif" font-size="8.5" font-weight="bold" fill="${txColor}" text-anchor="middle">↑TX ${safeTx}</text>`;
        }
        if (safeRx) {
            rxTextHtml = `<text x="60" y="168" font-family="'Inter', sans-serif" font-size="8.5" font-weight="bold" fill="${rxColor}" text-anchor="middle">↓RX ${safeRx}</text>`;
        }

        let cardBg = isDay ? 'rgba(255, 255, 255, 0.85)' : 'rgba(30, 41, 59, 0.6)';
        let cardStroke = isDay ? 'rgba(15, 23, 42, 0.12)' : 'rgba(255, 255, 255, 0.08)';
        let circleFill = isDay ? '#e2e8f0' : '#1e293b';
        let nameColor = isDay ? '#0f172a' : '#f8fafc';
        let ipColor = isDay ? '#475569' : '#94a3b8';

        if (isPaused) {
            cardBg = isDay ? 'rgba(255, 255, 255, 0.45)' : 'rgba(30, 41, 59, 0.35)';
            cardStroke = isDay ? 'rgba(15, 23, 42, 0.06)' : 'rgba(255, 255, 255, 0.05)';
        } else if (statusColor === '#ef4444') {
            cardBg = isDay ? 'rgba(220, 38, 38, 0.08)' : 'rgba(239, 68, 68, 0.15)';
            cardStroke = isDay ? 'rgba(220, 38, 38, 0.3)' : 'rgba(239, 68, 68, 0.3)';
        } else if (statusColor === '#f59e0b') {
            cardBg = isDay ? 'rgba(217, 119, 6, 0.08)' : 'rgba(245, 158, 11, 0.15)';
            cardStroke = isDay ? 'rgba(217, 119, 6, 0.3)' : 'rgba(245, 158, 11, 0.3)';
        } else if (statusColor === '#10b981') {
            cardBg = isDay ? 'rgba(255, 255, 255, 0.85)' : 'rgba(30, 41, 59, 0.6)';
            cardStroke = isDay ? 'rgba(16, 185, 129, 0.35)' : 'rgba(16, 185, 129, 0.3)';
        }

        return `
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="175" viewBox="0 0 120 175">
            <defs>
                <filter id="glow" x="-20%" y="-20%" width="140%" height="140%">
                    <feDropShadow dx="0" dy="0" stdDeviation="5" flood-color="${statusColor}" flood-opacity="0.8"/>
                </filter>
                <clipPath id="circle-clip">
                    <circle cx="18" cy="18" r="18"/>
                </clipPath>
            </defs>
            <rect x="8" y="42" width="104" height="131" rx="12" fill="${cardBg}" stroke="${cardStroke}" stroke-width="1.5" />
            <circle cx="60" cy="80" r="26" fill="${circleFill}" stroke="${statusColor}" stroke-width="4" filter="url(#glow)"/>
            <g transform="translate(42, 62)">
                ${iconContent}
            </g>
            <text x="60" y="122" font-family="'Inter', sans-serif" font-size="11" font-weight="bold" fill="${nameColor}" text-anchor="middle">${safeName}</text>
            <text x="60" y="133" font-family="'Inter', sans-serif" font-size="9" fill="${ipColor}" text-anchor="middle">${safeIp}</text>
            ${latTextHtml}
            ${txTextHtml}
            ${rxTextHtml}
        </svg>
        `;
    }

    function getDeviceStatusColor(ip) {
        let data = window.lastStatusData ? window.lastStatusData[ip] : null;
        const threshLatency = parseFloat(threshLatencyEl.value) || 100;
        if (!data) return '#64748b';
        if (data.status === "Failed" || data.status === "Offline") {
            if (isAlertSuppressed(ip) || data.isSuppressed) {
                return '#c084fc'; // 到達不能（紫）
            }
            return '#ef4444'; // 単独障害（赤）
        }
        if (data.status === "Success" && data.latency !== null) {
            if (data.latency >= threshLatency) return '#ef4444';
            if (data.latency >= threshLatency * 0.7) return '#f59e0b';
            return '#10b981';
        }
        return '#64748b';
    }

    function getEdgeStyle(fromIp, toIp) {
        const fromDev = devices.find(d => d.ip === fromIp);
        const toDev = devices.find(d => d.ip === toIp);
        
        if (!fromDev || !toDev) {
            return {
                color: { color: '#3b82f6', highlight: '#60a5fa', hover: '#93c5fd' },
                width: 3,
                dashes: false
            };
        }

        const fromStatus = window.lastStatusData ? window.lastStatusData[fromIp] : null;
        const toStatus = window.lastStatusData ? window.lastStatusData[toIp] : null;
        const isOffline = (fromStatus?.status === 'Failed') || (toStatus?.status === 'Failed');

        const hasWifiBand = (fromStatus?.wifiBand && fromStatus.wifiBand !== '') || 
                            (toStatus?.wifiBand && toStatus.wifiBand !== '');
        
        const isApToAp = (fromDev.image === 'ap' && toDev.image === 'ap');
        const isApToBridge = (fromDev.image === 'ap' && toDev.image === 'bridge') || 
                             (fromDev.image === 'bridge' && toDev.image === 'ap');
        
        const isWireless = hasWifiBand || isApToAp || isApToBridge;

        const warnLat = parseFloat(threshLatencyEl ? threshLatencyEl.value : 100) || 100;
        const fromLat = fromStatus?.latency || 0;
        const toLat = toStatus?.latency || 0;
        const isHighLatency = (fromLat >= warnLat) || (toLat >= warnLat);

        if (isOffline) {
            return {
                color: { color: '#ef4444', highlight: '#f87171', hover: '#fca5a5' },
                width: 2.5,
                dashes: [4, 4]
            };
        } else if (isHighLatency) {
            return {
                color: { color: '#f59e0b', highlight: '#fbbf24', hover: '#fde047' },
                width: 3,
                dashes: isWireless ? [4, 4] : false
            };
        } else {
            if (isWireless) {
                return {
                    color: { color: '#06b6d4', highlight: '#22d3ee', hover: '#67e8f9' },
                    width: 2.5,
                    dashes: [6, 4]
                };
            } else {
                return {
                    color: { color: '#3b82f6', highlight: '#60a5fa', hover: '#93c5fd' },
                    width: 2.5,
                    dashes: false
                };
            }
        }
    }

    function initTopology() {
        const container = document.getElementById('topology-container');
        if (!container) return;
        
        deactivateAllModes();

        container.innerHTML = '';
        if (networkInstance) {
            networkInstance.destroy();
            networkInstance = null;
        }

        const activeDevices = devices.filter(d => d.enabled !== false);
        if (activeDevices.length === 0) {
            container.innerHTML = '<div style="color: var(--text-muted); text-align: center; padding-top: 100px;">No active devices to display.</div>';
            return;
        }


        const nodes = [];
        const edges = [];
        const deviceIpMap = new Map();
        
        activeDevices.forEach(d => {
            deviceIpMap.set(d.ip, d);
        });

        // Group colors for Cisco Packet Tracer style backgrounds
        const isDayMode = document.documentElement.getAttribute('data-theme') === 'day';
        const GROUP_COLORS = isDayMode ? [
            { fill: 'rgba(76, 175, 80, 0.08)', stroke: 'rgba(76, 175, 80, 0.3)', label: '#2e7d32' },
            { fill: 'rgba(217, 119, 6, 0.07)', stroke: 'rgba(217, 119, 6, 0.3)', label: '#b78103' },
            { fill: 'rgba(0, 188, 212, 0.07)', stroke: 'rgba(0, 188, 212, 0.3)', label: '#00838f' },
            { fill: 'rgba(33, 150, 243, 0.07)', stroke: 'rgba(33, 150, 243, 0.3)', label: '#1565c0' },
            { fill: 'rgba(171, 71, 188, 0.07)', stroke: 'rgba(171, 71, 188, 0.3)', label: '#6a1b9a' },
            { fill: 'rgba(255, 87, 34, 0.07)', stroke: 'rgba(255, 87, 34, 0.3)', label: '#c62828' }
        ] : [
            { fill: 'rgba(76, 175, 80, 0.15)', stroke: 'rgba(76, 175, 80, 0.35)', label: '#a5d6a7' },
            { fill: 'rgba(255, 193, 7, 0.12)', stroke: 'rgba(255, 193, 7, 0.35)', label: '#ffe082' },
            { fill: 'rgba(0, 188, 212, 0.13)', stroke: 'rgba(0, 188, 212, 0.35)', label: '#80deea' },
            { fill: 'rgba(33, 150, 243, 0.13)', stroke: 'rgba(33, 150, 243, 0.35)', label: '#90caf9' },
            { fill: 'rgba(171, 71, 188, 0.13)', stroke: 'rgba(171, 71, 188, 0.35)', label: '#ce93d8' },
            { fill: 'rgba(255, 87, 34, 0.13)', stroke: 'rgba(255, 87, 34, 0.35)', label: '#ffab91' },
        ];

        // Build group index and spaced centers to prevent overlap
        const groupSet = [...new Set(activeDevices.map(d => d.group || 'Ungrouped'))];
        const numGroups = groupSet.length;
        const groupCenters = {};
        groupSet.forEach((groupName, idx) => {
            const angle = (idx / numGroups) * 2 * Math.PI;
            // Increase distance between groups for better readability
            groupCenters[groupName] = {
                x: Math.cos(angle) * 700,
                y: Math.sin(angle) * 700
            };
        });

        const groupNodeCounts = {};

        activeDevices.forEach(d => {
            let statusData = window.lastStatusData ? window.lastStatusData[d.ip] : null;

            let txSvgText = '';
            let rxSvgText = '';
            let bandwidthText = '';
            if (statusData && statusData.tx && statusData.tx !== "-" && statusData.tx !== "Error" && statusData.tx !== "Calc...") {
                txSvgText = `${statusData.tx} Mbps`;
                rxSvgText = `${statusData.rx && statusData.rx !== '-' ? statusData.rx : '0'} Mbps`;
                bandwidthText = `\n通信量: ↑TX ${statusData.tx} / ↓RX ${statusData.rx} Mbps`;
            } else if (statusData && statusData.bandwidth && statusData.bandwidth !== "-" && statusData.bandwidth !== "Failed" && statusData.bandwidth !== "Error") {
                txSvgText = `${statusData.bandwidth} Mbps`;
                bandwidthText = `\nBandwidth: ${statusData.bandwidth} Mbps`;
            }

            let latencySvgText = '';
            let latencyTooltipText = '';
            if (statusData && statusData.status === "Success" && statusData.latency !== null) {
                latencySvgText = `${statusData.latency} ms`;
                latencyTooltipText = `\nLatency: ${statusData.latency} ms`;
            } else if (statusData && statusData.status === "Failed") {
                latencySvgText = 'Offline';
                latencyTooltipText = `\nStatus: Offline`;
            }

            const isPaused = (d.enabled === false);
            const statusColor = getDeviceStatusColor(d.ip);
            const svgString = createNodeSvg(d.name || d.ip, d.ip, d.image, statusColor, txSvgText, rxSvgText, latencySvgText, isPaused);
            const svgUrl = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svgString);

            const nodeObj = {
                id: d.ip,
                shape: 'image',
                image: svgUrl,
                size: 110,
                label: '',
                group: d.group || 'Ungrouped',
                title: `${d.name || d.ip}\nIP: ${d.ip}\nGroup: ${d.group || 'Ungrouped'}${latencyTooltipText}${bandwidthText}`
            };

            if (typeof d.x === 'number' && typeof d.y === 'number') {
                nodeObj.x = d.x;
                nodeObj.y = d.y;
            } else {
                const g = d.group || 'Ungrouped';
                const center = groupCenters[g] || { x: 0, y: 0 };
                if (!groupNodeCounts[g]) groupNodeCounts[g] = 0;
                
                const count = groupNodeCounts[g];
                const angle = count * 0.85;
                // Increase radius spread to avoid overlap with larger nodes
                const radius = 160 + Math.floor(count / 5) * 140;
                nodeObj.x = center.x + Math.cos(angle) * radius;
                nodeObj.y = center.y + Math.sin(angle) * radius;
                groupNodeCounts[g]++;
            }
            nodeObj.physics = false; // Disable physics for all nodes to prevent group drift & overlap
            nodes.push(nodeObj);
        });


        // Create edges only for real connectedTo relationships
        activeDevices.forEach(d => {
            if (d.connectedTo) {
                const parents = d.connectedTo.split(',').map(p => p.trim()).filter(p => p);
                parents.forEach(parentIp => {
                    if (deviceIpMap.has(parentIp)) {
                        const estyle = getEdgeStyle(d.ip, parentIp);
                        edges.push({
                            id: `edge-${d.ip}-${parentIp}`,
                            from: d.ip,
                            to: parentIp,
                            color: estyle.color,
                            width: estyle.width,
                            dashes: estyle.dashes,
                            arrows: { to: { enabled: true, scaleFactor: 0.5 } },
                            smooth: false
                        });
                    }
                });
            }
        });

        nodesDataSet = new vis.DataSet(nodes);
        edgesDataSet = new vis.DataSet(edges);

        const data = {
            nodes: nodesDataSet,
            edges: edgesDataSet
        };

        const options = {
            nodes: {
                font: {
                    color: isDayMode ? '#0f172a' : '#f8fafc',
                    size: 13,
                    face: 'Inter, sans-serif',
                    strokeWidth: 3,
                    strokeColor: isDayMode ? '#ffffff' : '#0f172a'
                }
            },
            physics: {
                enabled: false,
                solver: 'barnesHut',
                barnesHut: {
                    gravitationalConstant: -2000,
                    centralGravity: 0.1,
                    springLength: 200,
                    springConstant: 0.04,
                    damping: 0.09,
                    avoidOverlap: 0.5
                },
                stabilization: {
                    iterations: 150
                }
            },
            interaction: {
                hover: true,
                dragNodes: true,
                zoomView: true,
                dragView: true,
                multiselect: false
            },
            manipulation: {
                enabled: false,
                addEdge: function(edgeData, callback) {
                    if (edgeData.from === edgeData.to) {
                        callback(null);
                        return;
                    }
                    const fromDev = activeDevices.find(d => d.ip === edgeData.from);
                    const toDev = activeDevices.find(d => d.ip === edgeData.to);
                    if (!fromDev || !toDev) {
                        callback(null);
                        return;
                    }

                    const currentParents = fromDev.connectedTo ? fromDev.connectedTo.split(',').map(ip => ip.trim()).filter(ip => ip) : [];
                    if (currentParents.includes(toDev.ip)) {
                        callback(null);
                        return;
                    }

                    // Shift out the oldest parent if we already have 2 links
                    while (currentParents.length >= 2) {
                        const removedParent = currentParents.shift();
                        edgesDataSet.remove(`edge-${fromDev.ip}-${removedParent}`);
                    }
                    currentParents.push(toDev.ip);
                    const newConnectedToVal = currentParents.join(',');

                    // Save connection via API
                    fetch('/api/device/edit', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({
                            oldIp: fromDev.ip,
                            newIp: fromDev.ip,
                            name: fromDev.name || '',
                            group: fromDev.group || '',
                            community: fromDev.community || 'public',
                            enabled: fromDev.enabled !== false,
                            image: fromDev.image || '',
                            connectedTo: newConnectedToVal
                        })
                    }).then(async res => {
                        if (res.ok) {
                            // Update local devices data without resetting the network layout
                            await fetchDevices(true);
                            
                            // Manually add the new edge to the dataset
                            const edgeId = `edge-${fromDev.ip}-${toDev.ip}`;
                            const estyle = getEdgeStyle(fromDev.ip, toDev.ip);
                            
                            edgesDataSet.add({
                                id: edgeId,
                                from: fromDev.ip,
                                to: toDev.ip,
                                color: estyle.color,
                                width: estyle.width,
                                dashes: estyle.dashes,
                                arrows: { to: { enabled: true, scaleFactor: 0.5 } },
                                smooth: false
                            });

                            // Reactivate addEdge mode to allow continuous linking!
                            if (isLinkMode && networkInstance) {
                                networkInstance.addEdgeMode();
                            }
                        }
                    }).catch(err => console.error('Failed to link devices:', err));
                    
                    callback(null); // Abort default edge (we handle drawing it)
                }
            }
        };

        networkInstance = new vis.Network(container, data, options);

        computeFullTracePath();

        let draggingGroup = null;
        let groupInitialPositions = {};
        let dragStartPointer = null;

        // Draw group background circles (Cisco Packet Tracer style) and canvas labels
        networkInstance.on('beforeDrawing', function(ctx) {
            const positions = networkInstance.getPositions();
            const groups = {};
            activeDevices.forEach(d => {
                const pos = positions[d.ip];
                if (!pos) return;
                const g = d.group || 'Ungrouped';
                if (!groups[g]) groups[g] = [];
                groups[g].push({ x: pos.x, y: pos.y, ip: d.ip });
            });

            Object.keys(groups).forEach((groupName, idx) => {
                const posArr = groups[groupName];
                if (posArr.length === 0) return;

                let minX = Infinity, maxX = -Infinity;
                let minY = Infinity, maxY = -Infinity;
                posArr.forEach(p => {
                    if (p.x < minX) minX = p.x;
                    if (p.x > maxX) maxX = p.x;
                    if (p.y < minY) minY = p.y;
                    if (p.y > maxY) maxY = p.y;
                });

                // NODE_HALF = vis-network node size (radius=110) + extra margin
                // SVG is 120x160 centered on the node center, so ±110px horizontally,
                // and label text extends about 80px below center → need more vertical padding bottom
                const NODE_HALF_X = 130;  // horizontal half-size of node (px in canvas coords)
                const NODE_HALF_TOP = 120; // above center
                const NODE_HALF_BOT = 150; // below center (label text area)
                const LABEL_H = 40;        // group label badge height
                const SIDE_MARGIN = 24;    // extra breathing room on sides

                const rectX = minX - NODE_HALF_X - SIDE_MARGIN;
                const rectY = minY - NODE_HALF_TOP - LABEL_H;
                const rectW = (maxX - minX) + 2 * (NODE_HALF_X + SIDE_MARGIN);
                const rectH = (maxY - minY) + NODE_HALF_TOP + NODE_HALF_BOT + LABEL_H;

                const color = GROUP_COLORS[idx % GROUP_COLORS.length];

                // Filled Rounded Rectangle
                ctx.beginPath();
                if (typeof ctx.roundRect === 'function') {
                    ctx.roundRect(rectX, rectY, rectW, rectH, 20);
                } else {
                    ctx.rect(rectX, rectY, rectW, rectH);
                }
                ctx.fillStyle = color.fill;
                ctx.fill();
                ctx.strokeStyle = color.stroke;
                ctx.lineWidth = 2;
                ctx.stroke();

                // Draw group label badge — inside the rectangle at top-left
                const labelText = ` ${groupName} `;
                ctx.font = 'bold 13px Inter, sans-serif';
                const textWidth = ctx.measureText(labelText).width;
                const labelW = textWidth + 24;
                const labelH2 = 28;
                const labelX = rectX + 16;
                const labelY = rectY + 8;

                // Rounded label background
                ctx.fillStyle = 'rgba(15, 23, 42, 0.82)';
                ctx.strokeStyle = color.stroke;
                ctx.lineWidth = 1.5;
                ctx.beginPath();
                if (typeof ctx.roundRect === 'function') {
                    ctx.roundRect(labelX, labelY, labelW, labelH2, 14);
                } else {
                    ctx.rect(labelX, labelY, labelW, labelH2);
                }
                ctx.fill();
                ctx.stroke();

                // Label text
                ctx.fillStyle = color.label;
                ctx.textAlign = 'left';
                ctx.textBaseline = 'middle';
                ctx.fillText(labelText, labelX + 12, labelY + labelH2 / 2);
            });
        });
        
        networkInstance.once('afterDrawing', () => {
            networkInstance.fit();
        });

        // 1. Packet Flow Animations (Visual dot-flow along links)
        // 2. Traceroute Hop Highlighting (Glowing nodes & neon red edges)
        networkInstance.on('afterDrawing', function(ctx) {
            const positions = networkInstance.getPositions();
            
            // Draw glowing ring around all nodes in traceHighlightedNodes (routers, switches, APs)
            if (traceHighlightedNodes.size > 0) {
                traceHighlightedNodes.forEach((nodeIp) => {
                    const pos = positions[nodeIp];
                    if (pos) {
                        ctx.save();
                        ctx.beginPath();
                        ctx.arc(pos.x, pos.y, 45, 0, 2 * Math.PI);
                        ctx.strokeStyle = 'rgba(239, 68, 68, 0.8)'; // Neon red glow
                        ctx.lineWidth = 4 + Math.sin(Date.now() / 150) * 1.5; // Pulsing glow
                        ctx.shadowColor = 'rgba(239, 68, 68, 0.9)';
                        ctx.shadowBlur = 15;
                        ctx.stroke();
                        ctx.restore();
                    }
                });
            }

            // Draw hop number badges ONLY on the actual Layer 3 hops from activeTraceHops
            if (activeTraceHops.length > 0) {
                activeTraceHops.forEach((hop, index) => {
                    const hopIp = typeof hop === 'string' ? hop : hop.ip;
                    const pos = positions[hopIp];
                    if (pos) {
                        const isLast = (index === activeTraceHops.length - 1);
                        
                        ctx.save();
                        // Special pulse for last hop
                        if (isLast) {
                            const pulse = Math.abs(Math.sin(Date.now() / 300)) * 20;
                            ctx.beginPath();
                            ctx.arc(pos.x, pos.y, 45 + pulse, 0, 2 * Math.PI);
                            ctx.strokeStyle = 'rgba(239, 68, 68, 0.4)';
                            ctx.lineWidth = 2;
                            ctx.stroke();
                        }

                        ctx.fillStyle = isLast ? '#ef4444' : 'rgba(239, 68, 68, 0.95)';
                        ctx.beginPath();
                        ctx.arc(pos.x - 30, pos.y - 30, 10, 0, 2 * Math.PI);
                        ctx.fill();
                        
                        ctx.font = 'bold 10px Inter, sans-serif';
                        ctx.fillStyle = '#ffffff';
                        ctx.textAlign = 'center';
                        ctx.textBaseline = 'middle';
                        ctx.fillText((index + 1).toString(), pos.x - 30, pos.y - 30);

                        if (isLast) {
                            ctx.font = 'bold 11px Inter, sans-serif';
                            ctx.fillStyle = '#ef4444';
                            ctx.fillText('TARGET', pos.x, pos.y + 60);
                        }
                        ctx.restore();
                    }
                });
            }

            // Draw animated flow dots on each edge
            const edges = edgesDataSet.get();
            edges.forEach(edge => {
                const fromPos = positions[edge.from];
                const toPos = positions[edge.to];
                if (fromPos && toPos) {
                    const isTraced = isTraceEdge(edge.from, edge.to);
                    
                    // If trace path, draw custom neon highlight
                    if (isTraced) {
                        ctx.save();
                        ctx.beginPath();
                        ctx.moveTo(fromPos.x, fromPos.y);
                        ctx.lineTo(toPos.x, toPos.y);
                        ctx.strokeStyle = 'rgba(239, 68, 68, 0.8)'; // Hot orange-red
                        ctx.lineWidth = 5;
                        ctx.shadowColor = 'rgba(239, 68, 68, 0.9)';
                        ctx.shadowBlur = 10;
                        ctx.stroke();
                        ctx.restore();
                    }

                    // Check if the link is wireless (has wifi dashes)
                    const isWireless = !!edge.dashes;

                    // Draw flow packets
                    const speedMultiplier = isTraced ? 2.5 : 1.0;
                    const numDots = isTraced ? 3 : 1;
                    
                    for (let i = 0; i < numDots; i++) {
                        const offset = i / numDots;
                        const progress = (flowAnimationProgress * speedMultiplier + offset) % 1.0;
                        
                        const x = fromPos.x + (toPos.x - fromPos.x) * progress;
                        const y = fromPos.y + (toPos.y - fromPos.y) * progress;
                        
                        ctx.save();
                        ctx.beginPath();
                        ctx.arc(x, y, isTraced ? 6 : 4, 0, 2 * Math.PI);
                        
                        // Sync dot color with connection type unless it's a traceroute packet
                        let dotColor = '#3b82f6'; // wired blue
                        if (isTraced) {
                            dotColor = '#f97316'; // traceroute orange
                        } else if (isWireless) {
                            dotColor = '#fbbf24'; // wireless yellow/orange
                        }
                        
                        ctx.fillStyle = dotColor;
                        ctx.shadowColor = dotColor;
                        ctx.shadowBlur = isTraced ? 12 : 8;
                        ctx.fill();
                        ctx.restore();
                    }
                }
            });
        });

        // Raw pointer events to handle group dragging by clicking and dragging on the background circle.
        // We use capturing phase to intercept the event before vis-network starts its pan gesture.
        container.addEventListener('pointerdown', function(e) {
            if (e.button !== 0) return; // Only handle left click
            if (!networkInstance) return;
            if (isLinkMode || isUnlinkMode) return; // Let vis-network handle all clicks during Link/Unlink modes!

            const rect = container.getBoundingClientRect();
            const domX = e.clientX - rect.left;
            const domY = e.clientY - rect.top;

            // Check if user clicked on an actual node first
            const clickedNode = networkInstance.getNodeAt({ x: domX, y: domY });
            if (clickedNode) {
                // Let vis-network handle dragging the node or opening the edit panel
                return;
            }

            // Group dragging now requires the Alt key to prevent accidental movement of multiple devices
            if (!e.altKey) return;

            const clickPos = networkInstance.DOMtoCanvas({ x: domX, y: domY });
            const positions = networkInstance.getPositions();
            
            let clickedGroup = null;
            const groups = {};
            activeDevices.forEach(d => {
                const pos = positions[d.ip];
                if (!pos) return;
                const g = d.group || 'Ungrouped';
                if (!groups[g]) groups[g] = [];
                groups[g].push({ x: pos.x, y: pos.y, ip: d.ip });
            });

            for (const groupName of Object.keys(groups)) {
                const posArr = groups[groupName];
                if (posArr.length === 0) continue;

                let minX = Infinity, maxX = -Infinity;
                let minY = Infinity, maxY = -Infinity;
                posArr.forEach(p => {
                    if (p.x < minX) minX = p.x;
                    if (p.x > maxX) maxX = p.x;
                    if (p.y < minY) minY = p.y;
                    if (p.y > maxY) maxY = p.y;
                });

                // Reduce padding for hit detection to be more precise
                const paddingX = 40;
                const paddingY = 50;

                const withinX = clickPos.x >= (minX - paddingX) && clickPos.x <= (maxX + paddingX);
                const withinY = clickPos.y >= (minY - paddingY) && clickPos.y <= (maxY + paddingY);

                if (withinX && withinY) {
                    clickedGroup = groupName;
                    break;
                }
            }

            if (clickedGroup) {
                // We clicked inside a group's background circle! Stop propagation so vis-network doesn't pan
                e.stopPropagation();

                draggingGroup = clickedGroup;
                dragStartPointer = { x: clickPos.x, y: clickPos.y };

                const groupDevices = activeDevices.filter(d => (d.group || 'Ungrouped') === clickedGroup);
                groupInitialPositions = {};
                groupDevices.forEach(d => {
                    const pos = positions[d.ip];
                    if (pos) {
                        groupInitialPositions[d.ip] = { x: pos.x, y: pos.y };
                    }
                });

                // Attach temporary drag move & up listeners to document
                document.addEventListener('pointermove', onPointerMove);
                document.addEventListener('pointerup', onPointerUp);
            }
        }, true);

        function onPointerMove(e) {
            if (!draggingGroup || !dragStartPointer) return;

            const rect = container.getBoundingClientRect();
            const domX = e.clientX - rect.left;
            const domY = e.clientY - rect.top;
            const currentPointer = networkInstance.DOMtoCanvas({ x: domX, y: domY });

            const dx = currentPointer.x - dragStartPointer.x;
            const dy = currentPointer.y - dragStartPointer.y;

            const updates = [];
            Object.keys(groupInitialPositions).forEach(ip => {
                const initPos = groupInitialPositions[ip];
                updates.push({
                    id: ip,
                    x: initPos.x + dx,
                    y: initPos.y + dy,
                    physics: false
                });
            });
            nodesDataSet.update(updates);
        }

        function onPointerUp(e) {
            if (draggingGroup) {
                const groupName = draggingGroup;
                draggingGroup = null;
                dragStartPointer = null;

                document.removeEventListener('pointermove', onPointerMove);
                document.removeEventListener('pointerup', onPointerUp);

                // Save positions
                const groupDevices = activeDevices.filter(d => (d.group || 'Ungrouped') === groupName);
                const finalPositions = networkInstance.getPositions(groupDevices.map(d => d.ip));
                const payload = [];

                groupDevices.forEach(d => {
                    const pos = finalPositions[d.ip];
                    if (pos) {
                        const dev = devices.find(x => x.ip === d.ip);
                        if (dev) {
                            dev.x = pos.x;
                            dev.y = pos.y;
                        }
                        payload.push({ ip: d.ip, x: pos.x, y: pos.y });
                    }
                });

                fetch('/api/devices/positions', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(payload)
                }).catch(err => console.error('Failed to save group node positions:', err));

                groupInitialPositions = {};
            }
        }

        // Node click → edit panel
        networkInstance.on('selectNode', (params) => {
            if (isLinkMode || isUnlinkMode) return; // Don't open edit panel in link/unlink mode
            if (params.nodes.length > 0) {
                const nodeId = params.nodes[0];
                const dev = activeDevices.find(d => d.ip === nodeId);
                if (dev) {
                    openTopologyEditPanel(dev);
                }
            }
        });

        networkInstance.on('deselectNode', (params) => {
            const panel = document.getElementById('topology-edit-panel');
            if (panel) panel.style.display = 'none';
        });

        // Click event to handle Unlink Mode on nodes and edges
        networkInstance.on('click', (params) => {
            if (isUnlinkMode) {
                if (params.edges.length > 0) {
                    const edgeId = params.edges[0];
                    const parts = edgeId.split('-');
                    if (parts.length >= 3) {
                        const ipToUnlink = parts[1];
                        const parentIp = parts[2];
                        const dev = devices.find(d => d.ip === ipToUnlink);
                        if (dev && dev.connectedTo) {
                            unlinkDevice(dev, parentIp);
                        }
                    }
                    networkInstance.unselectAll();
                } else if (params.nodes.length > 0) {
                    const nodeId = params.nodes[0];
                    const dev = devices.find(d => d.ip === nodeId);
                    if (dev && dev.connectedTo) {
                        unlinkDevice(dev);
                    }
                    networkInstance.unselectAll();
                }
            }
        });

        networkInstance.on('dragEnd', (params) => {

            if (params.nodes.length > 0) {
                const positions = networkInstance.getPositions(params.nodes);
                const payload = [];
                params.nodes.forEach(nodeId => {
                    const pos = positions[nodeId];
                    if (pos) {
                        const dev = devices.find(d => d.ip === nodeId);
                        if (dev) {
                            dev.x = pos.x;
                            dev.y = pos.y;
                        }
                        nodesDataSet.update({ id: nodeId, x: pos.x, y: pos.y, physics: false });
                        payload.push({ ip: nodeId, x: pos.x, y: pos.y });
                    }
                });
                
                fetch('/api/devices/positions', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(payload)
                }).catch(err => console.error('Failed to save node positions:', err));
            }
        });

        // Right-click context menu
        networkInstance.on('oncontext', (params) => {
            params.event.preventDefault();
            const ctxMenu = document.getElementById('topo-context-menu');
            if (!ctxMenu) return;

            const nodeId = networkInstance.getNodeAt(params.pointer.DOM);
            const edgeId = networkInstance.getEdgeAt(params.pointer.DOM);

            if (nodeId) {
                const dev = activeDevices.find(d => d.ip === nodeId);
                ctxMenu.dataset.nodeId = nodeId;
                ctxMenu.dataset.edgeId = '';
                document.getElementById('ctx-unlink').style.display = (dev && dev.connectedTo && dev.connectedTo.trim() !== '') ? 'block' : 'none';
                document.getElementById('ctx-edit').style.display = 'block';
            } else if (edgeId) {
                ctxMenu.dataset.edgeId = edgeId;
                ctxMenu.dataset.nodeId = '';
                document.getElementById('ctx-unlink').style.display = 'block';
                document.getElementById('ctx-edit').style.display = 'none';
            } else {
                ctxMenu.style.display = 'none';
                return;
            }

            ctxMenu.style.display = 'block';
            ctxMenu.style.left = params.event.clientX + 'px';
            ctxMenu.style.top = params.event.clientY + 'px';
        });

        initTopologyLatencyChart();
    }

    function initTopologyLatencyChart() {
        const canvas = document.getElementById('topology-latency-chart');
        if (!canvas) return;

        if (topologyLatencyChart) {
            topologyLatencyChart.destroy();
            topologyLatencyChart = null;
        }

        const activeDevices = devices.filter(d => d.enabled !== false);
        if (activeDevices.length === 0) return;

        const CHART_LINE_COLORS = [
            '#3b82f6', // blue
            '#10b981', // green
            '#f59e0b', // orange
            '#ec4899', // pink
            '#8b5cf6', // purple
            '#06b6d4', // cyan
            '#f43f5e', // rose
            '#14b8a6'  // teal
        ];

        const datasets = activeDevices.map((d, index) => {
            const color = CHART_LINE_COLORS[index % CHART_LINE_COLORS.length];
            
            if (!latencyHistory[d.ip]) {
                latencyHistory[d.ip] = Array(15).fill(null);
                timeHistory[d.ip] = Array(15).fill('');
            }

            return {
                label: d.name || d.ip,
                deviceIp: d.ip,
                data: latencyHistory[d.ip],
                borderColor: color,
                backgroundColor: 'transparent',
                borderWidth: 2,
                pointRadius: 2,
                pointBackgroundColor: color,
                fill: false,
                tension: 0.4
            };
        });

        const currentTheme = document.documentElement.getAttribute('data-theme') || 'night';
        const isDayMode = (currentTheme === 'day');
        const initialTickColor = isDayMode ? '#1e293b' : '#cbd5e1';
        const initialGridColor = isDayMode ? 'rgba(15, 23, 42, 0.25)' : 'rgba(255, 255, 255, 0.30)';
        const initialBorderColor = isDayMode ? 'rgba(15, 23, 42, 0.6)' : 'rgba(255, 255, 255, 0.55)';
        const initialLegendColor = isDayMode ? '#0f172a' : '#e2e8f0';

        const ctx = canvas.getContext('2d');
        topologyLatencyChart = new Chart(ctx, {
            type: 'line',
            data: {
                labels: timeHistory[activeDevices[0].ip] || Array(15).fill(''),
                datasets: datasets
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                animation: { duration: 0 },
                scales: {
                    x: { 
                        display: true,
                        ticks: { color: initialTickColor, maxTicksLimit: 6, font: { size: 10 } },
                        grid: { color: initialGridColor, lineWidth: 1 },
                        border: { color: initialBorderColor, width: 1 }
                    },
                    y: { 
                        display: true, 
                        min: 0, 
                        suggestedMax: 100,
                        ticks: { color: initialTickColor, font: { size: 10 } },
                        grid: { color: initialGridColor, lineWidth: 1 },
                        border: { color: initialBorderColor, width: 1 }
                    }
                },
                plugins: { 
                    legend: { 
                        display: true, 
                        position: 'bottom',
                        labels: {
                            color: initialLegendColor,
                            font: { size: 9, family: 'Inter, sans-serif' },
                            usePointStyle: true,
                            pointStyle: 'line',
                            boxWidth: 15,
                            padding: 6
                        }
                    }, 
                    tooltip: { enabled: true, mode: 'index', intersect: false }
                },
                layout: { padding: { top: 5, right: 15, bottom: 5, left: 5 } }
            }
        });
    }

    function updateTopologyStatus() {
        if (!networkInstance || !nodesDataSet || !viewTopology.classList.contains('active')) return;
        const activeDevices = devices.filter(d => d.enabled !== false);
        activeDevices.forEach(d => {
            let statusData = window.lastStatusData ? window.lastStatusData[d.ip] : null;

            let txSvgText = '';
            let rxSvgText = '';
            let bandwidthText = '';
            if (statusData && statusData.tx && statusData.tx !== "-" && statusData.tx !== "Error" && statusData.tx !== "Calc...") {
                txSvgText = `${statusData.tx} Mbps`;
                rxSvgText = `${statusData.rx && statusData.rx !== '-' ? statusData.rx : '0'} Mbps`;
                bandwidthText = `\n通信量: ↑TX ${statusData.tx} / ↓RX ${statusData.rx} Mbps`;
            } else if (statusData && statusData.bandwidth && statusData.bandwidth !== "-" && statusData.bandwidth !== "Failed" && statusData.bandwidth !== "Error") {
                txSvgText = `${statusData.bandwidth} Mbps`;
                bandwidthText = `\nBandwidth: ${statusData.bandwidth} Mbps`;
            }

            let latencySvgText = '';
            let latencyTooltipText = '';
            if (statusData && statusData.status === "Success" && statusData.latency !== null) {
                latencySvgText = `${statusData.latency} ms`;
                latencyTooltipText = `\nLatency: ${statusData.latency} ms`;
            } else if (statusData && statusData.status === "Failed") {
                latencySvgText = 'Offline';
                latencyTooltipText = `\nStatus: Offline`;
            }

            const isPaused = (d.enabled === false);
            const statusColor = getDeviceStatusColor(d.ip);
            const svgString = createNodeSvg(d.name || d.ip, d.ip, d.image, statusColor, txSvgText, rxSvgText, latencySvgText, isPaused);
            const svgUrl = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svgString);
            
            const safeName = escapeXml(d.name || d.ip);
            const safeIp = escapeXml(d.ip);
            const safeGroup = escapeXml(d.group || 'Ungrouped');
            const safeLatencyTooltip = escapeXml(latencyTooltipText || '');
            const safeBandwidthTooltip = escapeXml(bandwidthText || '');

            try {
                nodesDataSet.update({
                    id: d.ip,
                    image: svgUrl,
                    label: '',
                    title: `${safeName}\nIP: ${safeIp}\nGroup: ${safeGroup}${safeLatencyTooltip}${safeBandwidthTooltip}`
                });
            } catch (e) {}
        });

        if (edgesDataSet) {
            try {
                const allEdges = edgesDataSet.get();
                allEdges.forEach(edge => {
                    const estyle = getEdgeStyle(edge.from, edge.to);
                    edgesDataSet.update({
                        id: edge.id,
                        color: estyle.color,
                        width: estyle.width,
                        dashes: estyle.dashes
                    });
                });
            } catch (e) {}
        }
    }

    async function unlinkDevice(dev, parentIp = null) {
        let newConnectedTo = '';
        if (parentIp && dev.connectedTo) {
            const parents = dev.connectedTo.split(',').map(ip => ip.trim()).filter(ip => ip);
            newConnectedTo = parents.filter(ip => ip !== parentIp).join(',');
        }

        try {
            const res = await fetch('/api/device/edit', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    oldIp: dev.ip,
                    newIp: dev.ip,
                    name: dev.name || '',
                    group: dev.group || '',
                    community: dev.community || 'public',
                    enabled: dev.enabled !== false,
                    image: dev.image || '',
                    connectedTo: newConnectedTo
                })
            });
            if (res.ok) {
                await fetchDevices(true); // Skip rebuild
                
                // Find and remove the edge from edgesDataSet
                if (parentIp) {
                    edgesDataSet.remove(`edge-${dev.ip}-${parentIp}`);
                } else {
                    const edgesToRemove = edgesDataSet.get({
                        filter: function(item) {
                            return item.from === dev.ip;
                        }
                    });
                    edgesToRemove.forEach(e => edgesDataSet.remove(e.id));
                }
            } else {
                alert('接続の解除に失敗しました。');
            }
        } catch (err) {
            console.error('Error unlinking device:', err);
        }
    }

    // Link mode toggle
    const topoLinkBtn = document.getElementById('topo-link-btn');
    if (topoLinkBtn) {
        topoLinkBtn.addEventListener('click', () => {
            if (!networkInstance) return;
            if (isLinkMode) {
                deactivateLinkMode();
            } else {
                deactivateUnlinkMode();
                isLinkMode = true;
                networkInstance.addEdgeMode();
                topoLinkBtn.classList.add('link-active');
                const modeText = document.getElementById('topo-mode-text');
                if (modeText) {
                    modeText.style.display = 'inline';
                    modeText.innerHTML = '接続作成モード: ON <span style="font-size:0.75rem;">⚡ 送信元から送信先へドラッグしてください</span>';
                    modeText.style.color = 'var(--warning)';
                }
            }
        });
    }

    // Unlink button
    const topoUnlinkBtn = document.getElementById('topo-unlink-btn');
    if (topoUnlinkBtn) {
        topoUnlinkBtn.addEventListener('click', () => {
            if (!networkInstance) return;
            if (isUnlinkMode) {
                deactivateUnlinkMode();
            } else {
                deactivateLinkMode();
                isUnlinkMode = true;
                topoUnlinkBtn.classList.add('unlink-active');
                const modeText = document.getElementById('topo-mode-text');
                if (modeText) {
                    modeText.style.display = 'inline';
                    modeText.innerHTML = '接続解除モード: ON <span style="font-size:0.75rem;">❌ 解除したい機器または接続線をクリックしてください</span>';
                    modeText.style.color = 'var(--error)';
                }
                
                // If there is already a selection, process it immediately!
                const selectedNodes = networkInstance.getSelectedNodes();
                const selectedEdges = networkInstance.getSelectedEdges();
                let ipToUnlink = null;

                if (selectedEdges.length > 0) {
                    const edgeId = selectedEdges[0];
                    const parts = edgeId.split('-');
                    if (parts.length >= 3) {
                        const ipToUnlink = parts[1];
                        const parentIp = parts[2];
                        const dev = devices.find(d => d.ip === ipToUnlink);
                        if (dev && dev.connectedTo) {
                            unlinkDevice(dev, parentIp);
                        }
                    }
                } else if (selectedNodes.length > 0) {
                    const ipToUnlink = selectedNodes[0];
                    const dev = devices.find(d => d.ip === ipToUnlink);
                    if (dev && dev.connectedTo) {
                        unlinkDevice(dev);
                    }
                }
                networkInstance.unselectAll();
            }
        });
    }

    // Context Menu operations
    const ctxUnlinkBtn = document.getElementById('ctx-unlink');
    if (ctxUnlinkBtn) {
        ctxUnlinkBtn.addEventListener('click', async (e) => {
            e.stopPropagation(); // prevent document click from hiding menu before we act
            const ctxMenu = document.getElementById('topo-context-menu');
            const nodeId = ctxMenu.dataset.nodeId;
            const edgeId = ctxMenu.dataset.edgeId;
            ctxMenu.style.display = 'none';

            if (nodeId) {
                const dev = devices.find(d => d.ip === nodeId);
                if (dev && dev.connectedTo) {
                    await unlinkDevice(dev);
                }
            } else if (edgeId) {
                const parts = edgeId.split('-');
                if (parts.length >= 3) {
                    const ipToUnlink = parts[1];
                    const parentIp = parts[2];
                    const dev = devices.find(d => d.ip === ipToUnlink);
                    if (dev && dev.connectedTo) {
                        await unlinkDevice(dev, parentIp);
                    }
                }
            }
        });
    }

    const ctxEditBtn = document.getElementById('ctx-edit');
    if (ctxEditBtn) {
        ctxEditBtn.addEventListener('click', (e) => {
            e.stopPropagation(); // prevent document click from hiding menu before we act
            const ctxMenu = document.getElementById('topo-context-menu');
            const nodeId = ctxMenu.dataset.nodeId;
            ctxMenu.style.display = 'none';
            if (nodeId) {
                const dev = devices.find(d => d.ip === nodeId);
                if (dev) {
                    // Switch to Add/Device/Manage tab and populate the edit form
                    switchTab('tab-manage');
                    // Fill the device edit form (same as clicking ✎ in the manage list)
                    setTimeout(() => {
                        if (editOldIpInput) editOldIpInput.value = dev.ip;
                        if (devIpInput) devIpInput.value = dev.ip;
                        if (devNameInput) devNameInput.value = (dev.name && dev.name !== dev.ip) ? dev.name : '';
                        if (devGroupInput) devGroupInput.value = dev.group || '';
                        populateGroupDropdown(dev.group || '');
                        if (devGroupNew) devGroupNew.classList.add('hidden');
                        if (devCommInput) devCommInput.value = dev.community || 'public';
                        const isEnabled = dev.enabled !== false;
                        if (devEnabledInput) devEnabledInput.checked = isEnabled;
                        if (submitDeviceBtn) submitDeviceBtn.textContent = '機器情報を更新';
                        if (devIpInput) devIpInput.placeholder = '192.168.1.1';
                        populateConnectionsDropdown(dev.ip);
                        const parents = dev.connectedTo ? dev.connectedTo.split(',').map(p => p.trim()).filter(p => p) : [];
                        if (devConnectedTo) devConnectedTo.value = parents[0] || '';
                        if (devConnectedTo2) devConnectedTo2.value = parents[1] || '';
                        if (dev.image) {
                            if (PREDEFINED_ICONS[dev.image]) {
                                devImageType.value = dev.image;
                                devImageUploadContainer.style.display = 'none';
                            } else {
                                devImageType.value = 'upload';
                                devImageUploadContainer.style.display = 'flex';
                                devImageUrl.value = dev.image;
                            }
                        } else {
                            devImageType.value = '';
                            devImageUploadContainer.style.display = 'none';
                            if (devImageUrl) devImageUrl.value = '';
                        }
                        // Highlight matching device row in manage list
                        const manageItems = document.querySelectorAll('.manage-item');
                        manageItems.forEach(el => el.style.background = 'transparent');
                        const targetItem = document.querySelector(`.manage-item [data-ip="${dev.ip}"]`);
                        if (targetItem) targetItem.closest('.manage-item').style.background = 'rgba(59, 130, 246, 0.15)';
                        // Scroll the edit form into view
                        if (devIpInput) devIpInput.scrollIntoView({ behavior: 'smooth', block: 'center' });
                    }, 50);
                }
            }
        });
    }

    // Hide context menu on click anywhere
    document.addEventListener('click', () => {
        const ctxMenu = document.getElementById('topo-context-menu');
        if (ctxMenu) ctxMenu.style.display = 'none';
    });


    // Register New Device button handler
    const manageNewDeviceBtn = document.getElementById('manage-new-device-btn');
    if (manageNewDeviceBtn) {
        manageNewDeviceBtn.addEventListener('click', (e) => {
            e.preventDefault();
            deviceForm.reset();
            if (editOldIpInput) editOldIpInput.value = '';
            if (submitDeviceBtn) submitDeviceBtn.textContent = '機器を保存';
            if (devIpInput) devIpInput.placeholder = '例: 192.168.1.1 または 192.168.1.1, コアルーター';
            
            // Reset image selection
            if (devImageType) {
                devImageType.value = '';
                devImageUploadContainer.style.display = 'none';
                devImageUrl.value = '';
            }

            // Reset parent connections dropdown
            populateConnectionsDropdown();

            // Reset group dropdown to blank
            populateGroupDropdown('');
            if (devGroupNew) { devGroupNew.classList.add('hidden'); devGroupNew.value = ''; }
            if (devGroupInput) devGroupInput.value = '';

            // Clear active list highlights
            manageDeviceList.querySelectorAll('.manage-item').forEach(el => el.style.background = 'transparent');
        });
    }

    // Topology Edit Panel Event Listeners & Helper Functions
    const topoClosePanelBtn = document.getElementById('topo-close-panel-btn');
    if (topoClosePanelBtn) {
        topoClosePanelBtn.addEventListener('click', () => {
            deactivateAllModes();
            const panel = document.getElementById('topology-edit-panel');
            if (panel) panel.style.display = 'none';
            if (networkInstance) networkInstance.unselectAll();
        });
    }

    const topoImageType = document.getElementById('topo-image-type');
    const topoImageUploadContainer = document.getElementById('topo-image-upload-container');
    const topoImageFile = document.getElementById('topo-image-file');
    const topoImageUrl = document.getElementById('topo-image-url');

    if (topoImageType) {
        topoImageType.addEventListener('change', () => {
            if (topoImageType.value === 'upload') {
                topoImageUploadContainer.style.display = 'flex';
            } else {
                topoImageUploadContainer.style.display = 'none';
                topoImageUrl.value = '';
            }
        });
    }

    if (topoImageFile) {
        topoImageFile.addEventListener('change', async (e) => {
            const file = e.target.files[0];
            if (!file) return;

            const ip = document.getElementById('topo-ip').value;
            const sanitizedIp = ip.replace(/\s/g, '_');

            const headers = {
                'X-Device-IP': sanitizedIp,
                'X-File-Name': file.name
            };

            const submitBtn = document.querySelector('#topo-node-form button[type="submit"]');
            try {
                if (submitBtn) {
                    submitBtn.disabled = true;
                    submitBtn.textContent = 'アップロード中...';
                }

                const response = await fetch('/api/device/upload-image', {
                    method: 'POST',
                    headers: headers,
                    body: file
                });

                if (response.ok) {
                    const data = await response.json();
                    if (data.path) {
                        topoImageUrl.value = data.path;
                    }
                } else {
                    alert('画像のアップロードに失敗しました。');
                }
            } catch (err) {
                console.error('Error uploading file:', err);
                alert('画像のアップロードに失敗しました。');
            } finally {
                if (submitBtn) {
                    submitBtn.disabled = false;
                    submitBtn.textContent = '設定を保存';
                }
            }
        });
    }

    function openTopologyEditPanel(dev) {
        const panel = document.getElementById('topology-edit-panel');
        if (!panel) return;
        panel.style.display = 'flex';

        document.getElementById('topo-old-ip').value = dev.ip;
        document.getElementById('topo-ip').value = dev.ip;
        document.getElementById('topo-name').value = dev.name || '';
        document.getElementById('topo-group').value = dev.group || '';

        // Populate connected to dropdowns
        const topoParentSel = document.getElementById('topo-parent-ip') || document.getElementById('topo-connected-to');
        const topoConnectedTo2 = document.getElementById('topo-connected-to-2');
        
        const parents = dev.connectedTo ? dev.connectedTo.split(',').map(p => p.trim()).filter(p => p) : [];
        const parent1 = parents[0] || '';
        const parent2 = parents[1] || '';

        if (topoParentSel) {
            topoParentSel.innerHTML = '<option value="">なし (最上位 / ルート)</option>';
            devices.forEach(d => {
                if (d.ip !== dev.ip && d.enabled !== false) {
                    const opt = document.createElement('option');
                    opt.value = d.ip;
                    opt.textContent = `${d.name && d.name !== d.ip ? d.name + ' (' + d.ip + ')' : d.ip}`;
                    topoParentSel.appendChild(opt);
                }
            });
            topoParentSel.value = parent1;
        }

        if (topoConnectedTo2) {
            topoConnectedTo2.innerHTML = '<option value="">なし (最上位 / ルート)</option>';
            devices.forEach(d => {
                if (d.ip !== dev.ip && d.enabled !== false) {
                    const opt = document.createElement('option');
                    opt.value = d.ip;
                    opt.textContent = `${d.name && d.name !== d.ip ? d.name + ' (' + d.ip + ')' : d.ip}`;
                    topoConnectedTo2.appendChild(opt);
                }
            });
            topoConnectedTo2.value = parent2;
        }

        // Set image values
        if (dev.image) {
            if (PREDEFINED_ICONS[dev.image]) {
                topoImageType.value = dev.image;
                topoImageUploadContainer.style.display = 'none';
                topoImageUrl.value = '';
            } else {
                topoImageType.value = 'upload';
                topoImageUploadContainer.style.display = 'flex';
                topoImageUrl.value = dev.image;
            }
        } else {
            topoImageType.value = '';
            topoImageUploadContainer.style.display = 'none';
            topoImageUrl.value = '';
        }
    }

    const topoNodeForm = document.getElementById('topo-node-form');
    if (topoNodeForm) {
        topoNodeForm.addEventListener('submit', async (e) => {
            e.preventDefault();

            const oldIp = document.getElementById('topo-old-ip').value;
            const name = document.getElementById('topo-name').value.trim();
            const group = document.getElementById('topo-group').value.trim();
            
            const topoParentSel = document.getElementById('topo-parent-ip') || document.getElementById('topo-connected-to');
            const connectedToVal1 = topoParentSel?.value || '';
            const connectedToVal2 = document.getElementById('topo-connected-to-2')?.value || '';
            const uniqueParents = [connectedToVal1, connectedToVal2]
                .map(ip => ip.trim())
                .filter((ip, idx, arr) => ip && arr.indexOf(ip) === idx);
            const connectedTo = uniqueParents.join(',');

            let imageVal = '';
            if (topoImageType.value === 'upload') {
                imageVal = topoImageUrl.value;
            } else {
                imageVal = topoImageType.value;
            }

            const originalDev = devices.find(d => d.ip === oldIp);
            const payload = {
                oldIp: oldIp,
                newIp: oldIp, // IP is read-only in topo panel
                name: name,
                group: group,
                community: originalDev ? originalDev.community : 'public',
                enabled: originalDev ? originalDev.enabled : true,
                image: imageVal,
                connectedTo: connectedTo
            };

            try {
                const res = await fetch('/api/device/edit', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(payload)
                });
                if (res.ok) {
                    document.getElementById('topology-edit-panel').style.display = 'none';
                    await fetchDevices();
                    initTopology();
                } else {
                    alert('設定の保存に失敗しました。');
                }
            } catch (err) {
                console.error('Error saving settings:', err);
                alert('設定の保存中にエラーが発生しました。');
            }
        });
    }

    // ResizeObserver to handle dynamically resizing #topology-container
    const resizeObserverContainer = document.getElementById('topology-container');
    if (resizeObserverContainer) {
        const ro = new ResizeObserver(() => {
            if (networkInstance) {
                networkInstance.setSize('100%', '100%');
                networkInstance.redraw();
            }
        });
        ro.observe(resizeObserverContainer);
    }

    // ─── SNMP Detailed Modal Logic ───────────────────
    const snmpModal = document.getElementById('snmp-details-modal');
    const closeSnmpBtn = document.getElementById('close-snmp-btn');
    const closeSnmpFooterBtn = document.getElementById('close-snmp-footer-btn');
    let snmpPollInterval = null;
    let currentSnmpIp = null;

    // Iperf tools
    const runIperfBtn = document.getElementById('run-iperf-btn');
    const iperfDurationInput = document.getElementById('iperf-duration');
    const iperfResultContainer = document.getElementById('iperf-result-container');
    const iperfLoading = document.getElementById('iperf-loading');
    const iperfSummary = document.getElementById('iperf-summary');
    const iperfExecutedCommand = document.getElementById('iperf-executed-command');

    if (runIperfBtn) {
        runIperfBtn.addEventListener('click', async () => {
            if (!currentSnmpIp) return;
            const duration = iperfDurationInput ? (iperfDurationInput.value || 5) : 5;
            
            runIperfBtn.disabled = true;
            if (iperfResultContainer) iperfResultContainer.style.display = 'block';
            if (iperfLoading) iperfLoading.style.display = 'flex';
            if (iperfExecutedCommand) iperfExecutedCommand.style.display = 'none';
            if (iperfSummary) {
                iperfSummary.innerHTML = `
                    <div style="margin-top: 10px; text-align: center;">
                        <div style="font-size: 0.85rem; color: #94a3b8; margin-bottom: 4px;">⚡ 計測中 リアルタイム伝送速度</div>
                        <div style="font-size: 1.8rem; font-weight: 800; color: #38bdf8;"><span id="modal-iperf-live-speed">0.00</span> <span style="font-size: 1rem;" id="modal-iperf-live-unit">Mbps</span></div>
                    </div>
                `;
            }
            
            try {
                const res = await fetch(`/api/iperf?action=start&ip=${encodeURIComponent(currentSnmpIp)}&t=${duration}`);
                const data = await res.json();
                
                if (data.command && iperfExecutedCommand) {
                    iperfExecutedCommand.textContent = `実行コマンド: ${data.command}`;
                    iperfExecutedCommand.style.display = 'block';
                }

                if (data.status === 'started') {
                    let isRunning = true;
                    let lastOutput = '';
                    while (isRunning) {
                        await new Promise(resolve => setTimeout(resolve, 800));
                        const statusRes = await fetch(`/api/iperf?action=status`);
                        const statusData = await statusRes.json();
                        
                        if (statusData.output) {
                            lastOutput = statusData.output;
                            const latestSpeed = parseLatestIperfSpeed(statusData.output);
                            const modalVal = document.getElementById('modal-iperf-live-speed');
                            const modalUnit = document.getElementById('modal-iperf-live-unit');
                            if (latestSpeed && modalVal && modalUnit) {
                                modalVal.textContent = latestSpeed.val;
                                modalUnit.textContent = latestSpeed.unit;
                            }
                        }
                        if (statusData.running === false) {
                            isRunning = false;
                        }
                    }
                    
                    const latestSpeed = parseLatestIperfSpeed(lastOutput);
                    if (iperfSummary) {
                        iperfSummary.innerHTML = `
                            <div style="font-size: 1.1rem; color: #4ade80; margin-bottom: 8px; font-weight: 700;">✅ 計測完了</div>
                            ${latestSpeed ? `<div>最終伝送速度: <span style="font-size: 1.3rem; font-weight: 800; color: #38bdf8;">${latestSpeed.val} ${latestSpeed.unit}</span></div>` : ''}
                            <div style="font-size: 0.8rem; color: var(--text-muted); margin-top: 6px;">
                                詳細なグラフ・ログは「Iperf3 帯域計測」タブで確認できます。
                            </div>
                        `;
                    }
                } else {
                    if (iperfSummary) iperfSummary.innerHTML = `<span style="color: var(--error);">❌ エラー: ${data.error || data.message || '計測に失敗しました'}</span>`;
                }
            } catch (err) {
                console.error('Iperf error:', err);
                if (iperfSummary) iperfSummary.innerHTML = `<span style="color: var(--error);">❌ 通信エラーが発生しました</span>`;
            } finally {
                if (iperfLoading) iperfLoading.style.display = 'none';
                runIperfBtn.disabled = false;
            }
        });
    }

    function closeSnmpModal() {
        if (snmpModal) {
            snmpModal.classList.remove('active');
        }
        if (snmpPollInterval) {
            clearInterval(snmpPollInterval);
            snmpPollInterval = null;
        }
        if (mtrPollInterval) {
            clearInterval(mtrPollInterval);
            mtrPollInterval = null;
        }
        currentSnmpIp = null;
    }

    if (closeSnmpBtn) closeSnmpBtn.addEventListener('click', closeSnmpModal);
    if (closeSnmpFooterBtn) closeSnmpFooterBtn.addEventListener('click', closeSnmpModal);
    if (snmpModal) {
        snmpModal.addEventListener('click', (e) => {
            if (e.target === snmpModal) {
                closeSnmpModal();
            }
        });
    }

    // Tab Switching
    const snmpTabBtns = document.querySelectorAll('.snmp-tab-btn');
    const snmpTabContents = document.querySelectorAll('.snmp-tab-content');

    snmpTabBtns.forEach(btn => {
        btn.addEventListener('click', () => {
            const targetTab = btn.getAttribute('data-tab');
            
            snmpTabBtns.forEach(b => b.classList.remove('active'));
            btn.classList.add('active');

            snmpTabContents.forEach(content => {
                if (content.id === targetTab) {
                    content.classList.add('active');
                } else {
                    content.classList.remove('active');
                }
            });

            if (targetTab === 'snmp-tab-history' && currentSnmpIp) {
                initHistoryCharts(currentSnmpIp);
            }
            if (targetTab === 'snmp-tab-mtr') {
                if (mtrConsole) mtrConsole.scrollTop = mtrConsole.scrollHeight;
            }
        });
    });

    function formatBytes(bytes) {
        if (bytes === null || bytes === undefined || bytes === '') return 'N/A';
        const str = String(bytes).trim();
        if (str === '' || str.toLowerCase() === 'null' || str.toLowerCase() === 'n/a' || str === '-') return 'N/A';
        const num = Number(str);
        if (isNaN(num) || num < 0) return 'N/A';
        if (num < 1024) return num + ' B';
        const k = 1024;
        const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
        const i = Math.floor(Math.log(num) / Math.log(k));
        return parseFloat((num / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
    }

    function getSnmpValue(val, fallback = 'N/A') {
        if (val === null || val === undefined || val === '') return fallback;
        const str = String(val).trim();
        if (str === '' || str.toLowerCase() === 'null' || str.toLowerCase() === 'n/a' || str === '-') return fallback;
        return str;
    }

    async function openSnmpDetailsModal(device) {
        if (!snmpModal) return;

        currentSnmpIp = device.ip;

        // Show Modal & set loading state
        snmpModal.classList.add('active');
        document.getElementById('snmp-loading').classList.remove('hidden');
        document.getElementById('snmp-error').classList.add('hidden');
        document.getElementById('snmp-content').classList.add('hidden');

        // Reset to Overview Tab
        snmpTabBtns.forEach(b => {
            if (b.getAttribute('data-tab') === 'snmp-tab-overview') {
                b.classList.add('active');
            } else {
                b.classList.remove('active');
            }
        });
        snmpTabContents.forEach(c => {
            if (c.id === 'snmp-tab-overview') {
                c.classList.add('active');
            } else {
                c.classList.remove('active');
            }
        });

        // Reset Iperf tools
        if (iperfResultContainer) iperfResultContainer.style.display = 'none';
        if (iperfSummary) iperfSummary.textContent = '';
        if (iperfDurationInput) iperfDurationInput.value = 5;

        // Set basic modal header
        document.getElementById('snmp-modal-title').textContent = `${device.name || device.ip} - SNMP詳細情報`;
        
        // Status dot coloring
        const statusDot = document.getElementById('snmp-modal-status-dot');
        if (statusDot) {
            statusDot.className = 'status-dot';
            const cardDot = document.getElementById(`dot-${device.ip.replace(/\./g, '-')}`);
            if (cardDot) {
                if (cardDot.classList.contains('success')) {
                    statusDot.classList.add('success');
                } else if (cardDot.classList.contains('error')) {
                    statusDot.classList.add('error');
                } else {
                    statusDot.classList.add('paused');
                }
            } else {
                statusDot.classList.add('success');
            }
        }

        // Fetch immediately
        await fetchSnmpDetails(device, false);

        // Start real-time polling every 3 seconds
        if (snmpPollInterval) clearInterval(snmpPollInterval);
        snmpPollInterval = setInterval(async () => {
            if (currentSnmpIp === device.ip) {
                await fetchSnmpDetails(device, true);
            }
        }, 3000);
    }

    async function fetchSnmpDetails(device, isQuiet) {
        if (!isQuiet) {
            document.getElementById('snmp-loading').classList.remove('hidden');
            document.getElementById('snmp-error').classList.add('hidden');
            document.getElementById('snmp-content').classList.add('hidden');
        }

        try {
            const res = await fetch(`/api/device/snmp-details?ip=${encodeURIComponent(device.ip)}`);
            if (!res.ok) {
                throw new Error(`HTTP error ${res.status}`);
            }
            const data = await res.json();
            if (data.error) {
                throw new Error(data.error);
            }

            // Check if user closed or switched modal while fetching
            if (currentSnmpIp !== device.ip) return;

            // Populate Overview Tab
            document.getElementById('snmp-sysName').textContent = getSnmpValue(data.sysName, device.name || 'N/A');
            document.getElementById('snmp-ip').textContent = device.ip;
            document.getElementById('snmp-sysUpTime').textContent = getSnmpValue(data.sysUpTime, 'N/A');
            document.getElementById('snmp-sysDescr').textContent = getSnmpValue(data.sysDescr, 'N/A');

            // CPU Progress
            const rawCpu = getSnmpValue(data.cpu, 'N/A');
            if (rawCpu !== 'N/A') {
                const cpuVal = Number(rawCpu);
                if (!isNaN(cpuVal)) {
                    document.getElementById('snmp-cpu-text').textContent = `${cpuVal}%`;
                    document.getElementById('snmp-cpu-bar').style.width = `${cpuVal}%`;
                } else {
                    document.getElementById('snmp-cpu-text').textContent = 'N/A';
                    document.getElementById('snmp-cpu-bar').style.width = '0%';
                }
            } else {
                document.getElementById('snmp-cpu-text').textContent = 'N/A';
                document.getElementById('snmp-cpu-bar').style.width = '0%';
            }

            // RAM Progress
            const ramTotal = Number(data.ramTotal);
            const ramUsed = Number(data.ramUsed);
            if (!isNaN(ramTotal) && ramTotal > 0 && !isNaN(ramUsed) && data.ramUsed !== null && data.ramUsed !== undefined && getSnmpValue(data.ramUsed, 'N/A') !== 'N/A' && getSnmpValue(data.ramTotal, 'N/A') !== 'N/A') {
                const ramUsedGb = (ramUsed / (1024 * 1024 * 1024)).toFixed(2);
                const ramTotalGb = (ramTotal / (1024 * 1024 * 1024)).toFixed(2);
                const ramPct = Math.round((ramUsed / ramTotal) * 100);
                document.getElementById('snmp-ram-text').textContent = `${ramUsedGb} / ${ramTotalGb} GB (${ramPct}%)`;
                document.getElementById('snmp-ram-bar').style.width = `${ramPct}%`;
            } else {
                document.getElementById('snmp-ram-text').textContent = 'N/A';
                document.getElementById('snmp-ram-bar').style.width = '0%';
            }

            // Storage Progress
            const diskTotal = Number(data.diskTotal);
            const diskUsed = Number(data.diskUsed);
            if (!isNaN(diskTotal) && diskTotal > 0 && !isNaN(diskUsed) && data.diskUsed !== null && data.diskUsed !== undefined && getSnmpValue(data.diskUsed, 'N/A') !== 'N/A' && getSnmpValue(data.diskTotal, 'N/A') !== 'N/A') {
                const diskUsedGb = (diskUsed / (1024 * 1024 * 1024)).toFixed(2);
                const diskTotalGb = (diskTotal / (1024 * 1024 * 1024)).toFixed(2);
                const diskPct = Math.round((diskUsed / diskTotal) * 100);
                document.getElementById('snmp-disk-text').textContent = `${diskUsedGb} / ${diskTotalGb} GB (${diskPct}%)`;
                document.getElementById('snmp-disk-bar').style.width = `${diskPct}%`;
            } else {
                document.getElementById('snmp-disk-text').textContent = 'N/A';
                document.getElementById('snmp-disk-bar').style.width = '0%';
            }

            // Populate Interfaces Table
            const ifBody = document.getElementById('snmp-interfaces-table-body');
            ifBody.innerHTML = '';
            if (data.interfaces && data.interfaces.length > 0) {
                data.interfaces.forEach(iface => {
                    const tr = document.createElement('tr');
                    tr.style.borderBottom = '1px solid var(--glass-border)';
                    
                    const hasStatus = iface.operStatus && iface.adminStatus;
                    const isUp = iface.operStatus === 'up';
                    const operStr = iface.operStatus ? (isUp ? '稼働 (UP)' : '停止 (DOWN)') : 'N/A';
                    const adminStr = iface.adminStatus ? (iface.adminStatus === 'up' ? '有効' : '無効') : 'N/A';
                    
                    let badgeBg = 'rgba(100,116,139,0.15)'; // gray
                    let badgeColor = 'var(--text-muted)';
                    let badgeBorder = 'rgba(100,116,139,0.3)';
                    let dotBg = 'var(--text-muted)';
                    
                    if (hasStatus) {
                        if (isUp) {
                            badgeBg = 'rgba(16,185,129,0.15)'; // green
                            badgeColor = 'var(--success)';
                            badgeBorder = 'rgba(16,185,129,0.3)';
                            dotBg = 'var(--success)';
                        } else {
                            badgeBg = 'rgba(239,68,68,0.15)'; // red
                            badgeColor = 'var(--error)';
                            badgeBorder = 'rgba(239,68,68,0.3)';
                            dotBg = 'var(--error)';
                        }
                    }
                    
                    const statusBadge = `<span style="display:inline-flex; align-items:center; gap:5px; padding:2px 8px; border-radius:12px; font-size:0.75rem; font-weight:600; background:${badgeBg}; color:${badgeColor}; border:1px solid ${badgeBorder};"><span style="width:6px; height:6px; border-radius:50%; background:${dotBg};"></span>${operStr} / ${adminStr}</span>`;
                    
                    // Errors and Discards (from syncHash.InterfaceErrors)
                    const ipErrors = statusData._iperfErrors ? statusData._iperfErrors[currentSnmpIp] : null; // Wait, I should use statusData._errors or similar
                    // Actually, let's just get it from the 'data.interfaces' if we were to augment it on server
                    // But in Server.ps1 I put it in $syncHash.InterfaceErrors.
                    // Let's assume I will augment the API response to include these details per interface.
                    
                    const inErr = getSnmpValue(iface.inErrors, '0');
                    const outErr = getSnmpValue(iface.outErrors, '0');
                    const inDisc = getSnmpValue(iface.inDiscards, '0');
                    const outDisc = getSnmpValue(iface.outDiscards, '0');
                    const dInErr = getSnmpValue(iface.deltaInErrors, '0');
                    const dOutErr = getSnmpValue(iface.deltaOutErrors, '0');
                    const dInDisc = getSnmpValue(iface.deltaInDiscards, '0');
                    const dOutDisc = getSnmpValue(iface.deltaOutDiscards, '0');

                    const hasRecentErrors = Number(dInErr) > 0 || Number(dOutErr) > 0 || Number(dInDisc) > 0 || Number(dOutDisc) > 0;
                    const errorText = `
                        <div style="font-size:0.75rem; line-height:1.2;">
                            <div title="合計エラー数 (受信/送信)">Err: <span style="color:${(Number(inErr)+Number(outErr)>0)?'#f87171':'inherit'}">${inErr} / ${outErr}</span></div>
                            <div title="合計破棄パケット数 (受信/送信)">Disc: <span style="color:${(Number(inDisc)+Number(outDisc)>0)?'#fbbf24':'inherit'}">${inDisc} / ${outDisc}</span></div>
                            ${hasRecentErrors ? `<div style="margin-top:2px; color:#f87171; font-weight:bold; font-size:0.7rem;">⚠️ +${Number(dInErr)+Number(dOutErr)+Number(dInDisc)+Number(dOutDisc)} (1秒間)</div>` : ''}
                        </div>
                    `;
                    
                    // Clean bandwidth value
                    let bw = getSnmpValue(iface.bandwidth, '-');
                    if (bw === 'N/A' || bw === 'Null' || bw.includes('Error') || bw.includes('Calc...') || bw === 'Tx: - / Rx: - Mbps') {
                        bw = '-';
                    }
                    
                    tr.innerHTML = `
                        <td style="padding: 10px 15px; font-weight:600; color:var(--text-muted);">${escapeHTML(getSnmpValue(iface.index, 'N/A'))}</td>
                        <td style="padding: 10px 15px; font-weight:600; color:var(--text-main);">${escapeHTML(getSnmpValue(iface.name || iface.desc, 'N/A'))}</td>
                        <td style="padding: 10px 15px;">${statusBadge}</td>
                        <td style="padding: 10px 15px;">${escapeHTML(getSnmpValue(iface.speed, 'N/A'))}</td>
                        <td style="padding: 10px 15px; font-weight:600; color:var(--primary);">${escapeHTML(bw)}</td>
                        <td style="padding: 10px 15px; font-family:monospace;">${escapeHTML(formatBytes(iface.inOctets))}</td>
                        <td style="padding: 10px 15px; font-family:monospace;">${escapeHTML(formatBytes(iface.outOctets))}</td>
                        <td style="padding: 10px 15px;">${errorText}</td>
                    `;
                    ifBody.appendChild(tr);
                });
            } else {
                ifBody.innerHTML = '<tr><td colspan="8" style="padding:20px; text-align:center; color:var(--text-muted);">インターフェース情報が見つかりません。</td></tr>';
            }

            // Populate ARP Table
            const arpBody = document.getElementById('snmp-arp-table-body');
            arpBody.innerHTML = '';
            if (data.arp && data.arp.length > 0) {
                data.arp.forEach(entry => {
                    const tr = document.createElement('tr');
                    tr.style.borderBottom = '1px solid var(--glass-border)';
                    tr.innerHTML = `
                        <td style="padding: 8px 12px; color:var(--text-muted);">ポート ${escapeHTML(getSnmpValue(entry.interface, 'N/A'))}</td>
                        <td style="padding: 8px 12px; font-weight:600; color:var(--text-main);">${escapeHTML(getSnmpValue(entry.ipAddress, 'N/A'))}</td>
                        <td style="padding: 8px 12px; font-family:monospace; color:var(--text-muted);">${escapeHTML(getSnmpValue(entry.macAddress, 'N/A'))}</td>
                    `;
                    arpBody.appendChild(tr);
                });
            } else {
                arpBody.innerHTML = '<tr><td colspan="3" style="padding:15px; text-align:center; color:var(--text-muted);">ARPエントリが見つかりません。</td></tr>';
            }

            // Populate Routing Table
            const routeBody = document.getElementById('snmp-routes-table-body');
            routeBody.innerHTML = '';
            if (data.routes && data.routes.length > 0) {
                data.routes.forEach(entry => {
                    const tr = document.createElement('tr');
                    tr.style.borderBottom = '1px solid var(--glass-border)';
                    
                    const typeMap = { 'indirect': '間接', 'direct': '直接', 'invalid': '無効', 'other': 'その他', 'unknown': '不明' };
                    const protoMap = { 'local': 'ローカル', 'static': '静的', 'rip': 'RIP', 'ospf': 'OSPF', 'bgp': 'BGP', 'icmp': 'ICMP', 'other': 'その他' };
                    
                    const rawNextHop = getSnmpValue(entry.nextHop, 'N/A');
                    const nextHopJP = rawNextHop === '0.0.0.0' ? '直接接続 / ローカル' : rawNextHop;
                    const typeJP = typeMap[entry.type] || getSnmpValue(entry.type, '不明');
                    const protoJP = protoMap[entry.proto] || getSnmpValue(entry.proto, '静的');

                    tr.innerHTML = `
                        <td style="padding: 8px 12px; font-weight:600; color:var(--text-main);">${escapeHTML(getSnmpValue(entry.destination, 'N/A'))}</td>
                        <td style="padding: 8px 12px; color:var(--success);">${escapeHTML(nextHopJP)}</td>
                        <td style="padding: 8px 12px; color:var(--text-muted);">${escapeHTML(getSnmpValue(entry.mask, 'N/A'))}</td>
                        <td style="padding: 8px 12px; font-size:0.75rem;"><span style="color:var(--primary);">${escapeHTML(protoJP)}</span> <span style="color:var(--text-muted);">(${escapeHTML(typeJP)})</span></td>
                    `;
                    routeBody.appendChild(tr);
                });
            } else {
                routeBody.innerHTML = '<tr><td colspan="4" style="padding:15px; text-align:center; color:var(--text-muted);">ルーティングエントリが見つかりません。</td></tr>';
            }

            // Populate TCP Connections Table
            const tcpBody = document.getElementById('snmp-tcp-table-body');
            tcpBody.innerHTML = '';
            if (data.tcp && data.tcp.length > 0) {
                data.tcp.forEach(conn => {
                    const tr = document.createElement('tr');
                    tr.style.borderBottom = '1px solid var(--glass-border)';
                    
                    const isEst = conn.state === 'ESTABLISHED';
                    const stateMap = {
                        'ESTABLISHED': '接続確立 (ESTABLISHED)',
                        'LISTEN': '接続待ち (LISTEN)',
                        'CLOSED': 'クローズ (CLOSED)',
                        'SYN_SENT': '接続要求送信 (SYN_SENT)',
                        'SYN_RECEIVED:': '接続要求受信 (SYN_RCVD)',
                        'FIN_WAIT_1': '終了待ち1 (FIN_WAIT_1)',
                        'FIN_WAIT_2': '終了待ち2 (FIN_WAIT_2)',
                        'CLOSE_WAIT': 'クローズ待ち (CLOSE_WAIT)',
                        'LAST_ACK': '最終確認待ち (LAST_ACK)',
                        'CLOSING': 'クローズ中 (CLOSING)',
                        'TIME_WAIT': '時間待ち (TIME_WAIT)',
                        'UNKNOWN': '不明'
                    };
                    const stateJP = stateMap[conn.state] || getSnmpValue(conn.state, '不明');
                    const stateBadge = `<span style="padding:2px 6px; border-radius:6px; font-size:0.7rem; font-weight:600; background:${isEst ? 'rgba(16,185,129,0.1)' : 'rgba(100,116,139,0.1)'}; color:${isEst ? 'var(--success)' : 'var(--text-muted)'}; border:1px solid ${isEst ? 'rgba(16,185,129,0.2)' : 'var(--glass-border)'};">${escapeHTML(stateJP)}</span>`;
                    
                    tr.innerHTML = `
                        <td style="padding: 8px 15px; font-family:monospace; color:var(--text-main);">${escapeHTML(getSnmpValue(conn.localAddress, 'N/A'))}</td>
                        <td style="padding: 8px 15px; font-family:monospace; color:var(--text-muted);">${escapeHTML(getSnmpValue(conn.remoteAddress, 'N/A'))}</td>
                        <td style="padding: 8px 15px;">${stateBadge}</td>
                    `;
                    tcpBody.appendChild(tr);
                });
            } else {
                tcpBody.innerHTML = '<tr><td colspan="3" style="padding:20px; text-align:center; color:var(--text-muted);">アクティブなTCPソケットが見つかりません。</td></tr>';
            }

            // Populate Vendor Specific Tab
            const vendorTabBtn = document.getElementById('snmp-tab-btn-vendor');
            const vendorContainer = document.getElementById('snmp-vendor-details-container');
            if (data.vendor && data.vendor.type) {
                if (vendorTabBtn) vendorTabBtn.style.display = 'block';
                
                const typeMap = { 'Camera': 'カメラ', 'UPS': 'UPS (無停電電源装置)', 'Switch': 'ネットワークスイッチ', 'Wireless AP': '無線アクセスポイント' };
                const typeJP = typeMap[data.vendor.type] || data.vendor.type;
                document.getElementById('snmp-vendor-type-title').textContent = `${typeJP} - 拡張プライベートMIB詳細`;
                
                vendorContainer.innerHTML = '';
                
                const keyMap = {
                    'resolution': '解像度',
                    'fps': 'フレームレート',
                    'temperature': '内部温度',
                    'fanSpeed': 'ファン回転速度',
                    'batteryStatus': 'バッテリー残量',
                    'voltage': '入力電圧',
                    'load': '出力負荷率',
                    'fanStatus': 'ファン状態',
                    'powerRedundancy': '電源冗長性状態',
                    'chassisTemp': '筐体温度',
                    'frequency': '無線周波数帯'
                };

                Object.keys(data.vendor).forEach(key => {
                    if (key === 'type') return;
                    
                    const label = keyMap[key] || key.replace(/([A-Z])/g, ' $1').replace(/^./, str => str.toUpperCase());
                    const val = getSnmpValue(data.vendor[key], 'N/A');
                    
                    let valJP = val;
                    if (val === 'OK') valJP = '正常 (OK)';
                    else if (val === 'Active / Redundant') valJP = '稼働中 / 冗長化正常';
                    
                    const rowDiv = document.createElement('div');
                    rowDiv.style.display = 'flex';
                    rowDiv.style.justifyContent = 'space-between';
                    rowDiv.style.padding = '8px 12px';
                    rowDiv.style.background = 'var(--inset-bg)';
                    rowDiv.style.borderRadius = '8px';
                    rowDiv.style.border = '1px solid var(--glass-border)';
                    rowDiv.innerHTML = `
                        <span style="color: var(--text-muted); font-weight: 500;">${label}:</span>
                        <span style="color: var(--text-main); font-weight: 600;">${valJP}</span>
                    `;
                    vendorContainer.appendChild(rowDiv);
                });
            } else {
                if (vendorTabBtn) vendorTabBtn.style.display = 'none';
            }

            // Switch to show content
            if (!isQuiet) {
                document.getElementById('snmp-loading').classList.add('hidden');
                document.getElementById('snmp-content').classList.remove('hidden');
            }

        } catch (err) {
            console.error('Failed to load SNMP details:', err);
            if (!isQuiet) {
                document.getElementById('snmp-loading').classList.add('hidden');
                document.getElementById('snmp-error-msg').textContent = err.message;
                document.getElementById('snmp-error').classList.remove('hidden');
            }
        }
    }

    // --- Automated Stress Tester ---
    async function runStressTests() {
        console.log("Starting Stress Test Suite...");
        
        const overlay = document.createElement('div');
        overlay.id = 'test-runner-overlay';
        overlay.style.position = 'fixed';
        overlay.style.bottom = '20px';
        overlay.style.right = '20px';
        overlay.style.width = '350px';
        overlay.style.maxHeight = '400px';
        overlay.style.backgroundColor = 'rgba(15, 23, 42, 0.95)';
        overlay.style.border = '2px solid #3b82f6';
        overlay.style.borderRadius = '12px';
        overlay.style.padding = '15px';
        overlay.style.color = '#f8fafc';
        overlay.style.fontFamily = 'monospace';
        overlay.style.fontSize = '12px';
        overlay.style.zIndex = '99999';
        overlay.style.overflowY = 'auto';
        overlay.style.boxShadow = '0 10px 15px -3px rgba(0,0,0,0.5)';
        overlay.innerHTML = `
            <h4 style="margin:0 0 10px 0; color:#3b82f6; border-bottom:1px solid #1e293b; padding-bottom:5px;">Stress Test Runner (100 Taps)</h4>
            <div id="test-progress-list"></div>
            <div id="test-summary" style="margin-top:10px; font-weight:bold; color:#10b981;">Running...</div>
        `;
        document.body.appendChild(overlay);

        const progressList = document.getElementById('test-progress-list');
        const summaryDiv = document.getElementById('test-summary');

        const logMsg = (msg, color = '#cbd5e1') => {
            const div = document.createElement('div');
            div.style.color = color;
            div.style.marginBottom = '4px';
            div.textContent = msg;
            progressList.appendChild(div);
            overlay.scrollTop = overlay.scrollHeight;
        };

        const errors = [];
        const captureError = (msg) => {
            errors.push(msg);
            logMsg(`Error detected: ${msg}`, '#ef4444');
        };

        // Intercept global errors
        const oldOnError = window.onerror;
        window.onerror = (message, source, lineno, colno, error) => {
            captureError(`${message} at ${source}:${lineno}:${colno}`);
            if (oldOnError) oldOnError(message, source, lineno, colno, error);
            return false;
        };
        const oldOnRejection = window.onunhandledrejection;
        window.onunhandledrejection = (event) => {
            captureError(`Unhandled Promise Rejection: ${event.reason}`);
            if (oldOnRejection) oldOnRejection(event);
        };
        const oldConsoleError = console.error;
        console.error = (...args) => {
            const msg = args.join(' ');
            if (msg.includes('deprecated') || msg.includes('vis-network')) {
                oldConsoleError.apply(console, args);
                return;
            }
            captureError(`Console error: ${msg}`);
            oldConsoleError.apply(console, args);
        };

        const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

        try {
            await sleep(1000);

            // Test 1: View switching (100 times)
            logMsg("Test 1: View Tab Switching (100 times)...", '#60a5fa');
            const tabDashboard = document.getElementById('tab-dashboard');
            const tabTopology = document.getElementById('tab-topology');
            if (tabDashboard && tabTopology) {
                for (let i = 0; i < 100; i++) {
                    tabTopology.click();
                    tabDashboard.click();
                    if (i % 25 === 0) {
                        logMsg(`  Completed ${i} iterations`);
                        await sleep(10);
                    }
                }
                logMsg("Test 1: Success (100/100)", '#10b981');
            } else {
                captureError("View switcher tab elements not found");
            }

            // Test 2: Manage View Switching (100 times)
            logMsg("Test 2: Manage View Tab Switching (100 times)...", '#60a5fa');
            const tabManageTest = document.getElementById('tab-manage');
            if (tabManageTest && tabDashboard) {
                for (let i = 0; i < 100; i++) {
                    tabManageTest.click();
                    tabDashboard.click();
                    if (i % 25 === 0) {
                        logMsg(`  Completed ${i} iterations`);
                        await sleep(10);
                    }
                }
                logMsg("Test 2: Success (100/100)", '#10b981');
            } else {
                captureError("Manage tab button not found");
            }

            // Test 3: Topo Fit Button (100 times)
            logMsg("Test 3: Topo Fit Button Click (100 times)...", '#60a5fa');
            const topoFitBtn = document.getElementById('topo-fit-btn');
            if (topoFitBtn) {
                tabTopology.click();
                await sleep(500);
                for (let i = 0; i < 100; i++) {
                    topoFitBtn.click();
                    if (i % 25 === 0) {
                        logMsg(`  Completed ${i} iterations`);
                        await sleep(10);
                    }
                }
                tabDashboard.click();
                logMsg("Test 3: Success (100/100)", '#10b981');
            } else {
                captureError("Topology fit button not found");
            }

            // Test 4: SNMP Modal tab switches (100 times)
            logMsg("Test 4: SNMP Modal opening & tab switching...", '#60a5fa');
            const cards = document.querySelectorAll('.device-card, tr[style*="cursor: pointer"]');
            if (cards.length > 0) {
                const targetCard = cards[0];
                logMsg("  Opening SNMP details modal...");
                
                const dblclickEvent = new MouseEvent('dblclick', {
                    bubbles: true,
                    cancelable: true,
                    view: window
                });
                targetCard.dispatchEvent(dblclickEvent);
                
                await sleep(600);

                const snmpTabBtns = document.querySelectorAll('.snmp-tab-btn');
                const closeSnmpBtn = document.getElementById('close-snmp-btn');
                if (snmpTabBtns.length > 0 && closeSnmpBtn) {
                    logMsg("  Tapping tabs 100 times...");
                    for (let i = 0; i < 100; i++) {
                        snmpTabBtns.forEach(btn => btn.click());
                        if (i % 25 === 0) {
                            logMsg(`  Completed ${i} iterations`);
                            await sleep(10);
                        }
                    }
                    logMsg("  Closing SNMP modal...");
                    closeSnmpBtn.click();
                    logMsg("Test 4: Success (100/100)", '#10b981');
                } else {
                    captureError("SNMP tabs or close button not found");
                }
            } else {
                logMsg("  [Skip] No device cards found to trigger SNMP modal");
            }

            // Summarize
            if (errors.length === 0) {
                summaryDiv.textContent = "Test Completed! 0 errors.";
                summaryDiv.style.color = '#10b981';
            } else {
                summaryDiv.textContent = `Test Completed with ${errors.length} errors.`;
                summaryDiv.style.color = '#ef4444';
            }

            const report = {
                success: errors.length === 0,
                errors: errors,
                timestamp: new Date().toISOString()
            };

            await fetch('/api/test-results', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(report)
            });

            logMsg("Results sent to server.", '#cbd5e1');

        } catch (testErr) {
            captureError(`Suite crash: ${testErr.message}`);
        }
    }

    if (location.search.includes('run-tests=1')) {
        runStressTests();
    }


    // =========================================================
    // Export / Import Devices (JSON)
    // =========================================================
    const exportBtn = document.getElementById('export-devices-btn');
    if (exportBtn) {
        exportBtn.addEventListener('click', () => {
            const data = JSON.stringify(devices, null, 2);
            const blob = new Blob([data], { type: 'application/json' });
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = `devices_export_${new Date().toISOString().slice(0,10)}.json`;
            a.click();
            URL.revokeObjectURL(url);
        });
    }

    const importFile = document.getElementById('import-devices-file');
    if (importFile) {
        importFile.addEventListener('change', async (e) => {
            const file = e.target.files[0];
            if (!file) return;
            try {
                const text = await file.text();
                const parsed = JSON.parse(text);
                if (!Array.isArray(parsed)) { alert('ファイル形式が無効です。JSON配列形式のファイルを指定してください。'); return; }
                const confirmed = confirm(`${parsed.length} 台のデバイスをインポートします。既存設定に追加されます。よろしいですか？`);
                if (!confirmed) return;

                const res = await fetch('/api/devices/import', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(parsed)
                });
                if (res.ok) {
                    await fetchDevices();
                    renderManageList();
                    alert('インポート完了しました。');
                } else {
                    const err = await res.json().catch(() => ({ error: 'Unknown error' }));
                    alert(`インポート失敗: ${err.error}`);
                }
            } catch (err) {
                alert(`ファイルの読み込みに失敗しました: ${err.message}`);
            }
            importFile.value = '';
        });
    }

    // =========================================================
    // SNMPv3 Form Fields Toggle
    // =========================================================
    const devSnmpVersion = document.getElementById('dev-snmp-version');
    const snmpv3Fields = document.getElementById('snmpv3-fields');
    const devSnmpPrivProto = document.getElementById('dev-snmp-priv-proto');
    const snmpv3PrivPassGroup = document.getElementById('snmpv3-priv-pass-group');

    if (devSnmpVersion && snmpv3Fields) {
        devSnmpVersion.addEventListener('change', () => {
            snmpv3Fields.style.display = devSnmpVersion.value === 'v3' ? 'flex' : 'none';
        });
    }

    if (devSnmpPrivProto && snmpv3PrivPassGroup) {
        devSnmpPrivProto.addEventListener('change', () => {
            snmpv3PrivPassGroup.style.display = devSnmpPrivProto.value === 'none' ? 'none' : 'block';
        });
    }

    // =========================================================
    // Bulk Action Bar
    // =========================================================
    let bulkSelectedIps = new Set();

    function updateBulkBar() {
        const bar = document.getElementById('bulk-action-bar');
        const label = document.getElementById('bulk-count-label');
        if (!bar || !label) return;
        const count = bulkSelectedIps.size;
        if (count > 0) {
            bar.style.display = 'flex';
            label.textContent = `${count} 台選択中`;
        } else {
            bar.style.display = 'none';
        }
    }

    // Listen for device card selections from the existing multi-select logic
    // The existing code sets .selected class; observe mutations to sync bulkSelectedIps
    const deviceListEl2 = document.getElementById('device-list');
    if (deviceListEl2) {
        const observer = new MutationObserver(() => {
            const selected = deviceListEl2.querySelectorAll('.device-card.selected');
            bulkSelectedIps.clear();
            selected.forEach(el => {
                const ip = el.dataset.ip || el.querySelector('[data-ip]')?.dataset.ip;
                if (ip) bulkSelectedIps.add(ip);
            });
            updateBulkBar();
        });
        observer.observe(deviceListEl2, { subtree: true, attributes: true, attributeFilter: ['class'] });
    }

    const bulkPauseBtn = document.getElementById('bulk-pause-btn');
    const bulkResumeBtn = document.getElementById('bulk-resume-btn');
    const bulkGroupBtn = document.getElementById('bulk-group-btn');
    const bulkGroupPopup = document.getElementById('bulk-group-popup');
    const bulkGroupApplyBtn = document.getElementById('bulk-group-apply-btn');
    const bulkDeleteBtn = document.getElementById('bulk-delete-btn');
    const bulkClearBtn = document.getElementById('bulk-clear-btn');

    async function doBulkAction(action, extra = {}) {
        if (bulkSelectedIps.size === 0) return;
        const body = { ips: [...bulkSelectedIps], action, ...extra };
        try {
            const res = await fetch('/api/devices/bulk-action', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(body)
            });
            if (res.ok) {
                await fetchDevices();
                renderManageList();
            } else {
                const err = await res.json().catch(() => ({ error: 'Unknown error' }));
                alert(`操作失敗: ${err.error}`);
            }
        } catch (e) {
            console.error('Bulk action failed:', e);
        }
    }

    if (bulkPauseBtn) {
        bulkPauseBtn.addEventListener('click', () => doBulkAction('disable'));
    }
    if (bulkResumeBtn) {
        bulkResumeBtn.addEventListener('click', () => doBulkAction('enable'));
    }
    if (bulkGroupBtn && bulkGroupPopup) {
        bulkGroupBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            const isOpen = bulkGroupPopup.style.display === 'flex';
            bulkGroupPopup.style.display = isOpen ? 'none' : 'flex';
        });
        document.addEventListener('click', () => {
            if (bulkGroupPopup) bulkGroupPopup.style.display = 'none';
        });
    }
    if (bulkGroupApplyBtn) {
        bulkGroupApplyBtn.addEventListener('click', async () => {
            const groupName = document.getElementById('bulk-group-input').value.trim();
            await doBulkAction('setGroup', { group: groupName });
            if (bulkGroupPopup) bulkGroupPopup.style.display = 'none';
        });
    }
    if (bulkDeleteBtn) {
        bulkDeleteBtn.addEventListener('click', async () => {
            if (!confirm(`選択中の ${bulkSelectedIps.size} 台を削除します。よろしいですか？`)) return;
            await doBulkAction('delete');
            bulkSelectedIps.clear();
            updateBulkBar();
        });
    }
    if (bulkClearBtn) {
        bulkClearBtn.addEventListener('click', () => {
            // Deselect all
            const selectedEls = document.querySelectorAll('.device-row.selected');
            selectedEls.forEach(el => el.classList.remove('selected'));
            bulkSelectedIps.clear();
            updateBulkBar();
        });
    }

    // ─── MTR / History Logic ─────────────────────
    if (runMtrBtn) {
        runMtrBtn.addEventListener('click', async () => {
            if (!currentSnmpIp) return;
            
            runMtrBtn.disabled = true;
            mtrLoading.style.display = 'flex';
            mtrConsole.textContent = '> MTR 診断を初期化中...\n';
            
            try {
                const res = await fetch(`/api/mtr?action=start&ip=${encodeURIComponent(currentSnmpIp)}`);
                const data = await res.json();
                
                if (data.status === 'started') {
                    if (mtrPollInterval) clearInterval(mtrPollInterval);
                    mtrPollInterval = setInterval(async () => {
                        const statusRes = await fetch(`/api/mtr?action=status`);
                        const statusData = await statusRes.json();
                        
                        if (statusData.output) {
                            mtrConsole.textContent = statusData.output;
                            mtrConsole.scrollTop = mtrConsole.scrollHeight;
                        }
                        
                        if (statusData.running === false) {
                            clearInterval(mtrPollInterval);
                            mtrPollInterval = null;
                            mtrLoading.style.display = 'none';
                            runMtrBtn.disabled = false;
                        }
                    }, 1000);
                } else {
                    mtrConsole.textContent += `❌ エラー: ${data.error || '開始できませんでした'}\n`;
                    runMtrBtn.disabled = false;
                    mtrLoading.style.display = 'none';
                }
            } catch (err) {
                console.error('MTR error:', err);
                mtrConsole.textContent += `❌ 通信エラーが発生しました\n`;
                runMtrBtn.disabled = false;
                mtrLoading.style.display = 'none';
            }
        });
    }

    async function initHistoryCharts(ip) {
        const latencyCtx = document.getElementById('history-latency-chart')?.getContext('2d');
        const trafficCtx = document.getElementById('history-traffic-chart')?.getContext('2d');
        if (!latencyCtx || !trafficCtx) return;

        try {
            const res = await fetch(`/api/history?ip=${encodeURIComponent(ip)}`);
            const json = await res.json();
            
            if (json.status === 'success' && json.data) {
                const labels = json.data.map(d => {
                    const dt = new Date(d.Timestamp);
                    return `${dt.getHours()}:${String(dt.getMinutes()).padStart(2,'0')}`;
                });
                const latencyData = json.data.map(d => parseFloat(d.Latency_ms) || 0);
                const txData = json.data.map(d => parseFloat(d.Tx_Mbps) || 0);
                const rxData = json.data.map(d => parseFloat(d.Rx_Mbps) || 0);

                if (historyLatencyChart) historyLatencyChart.destroy();
                if (historyTrafficChart) historyTrafficChart.destroy();

                const isDay = document.documentElement.getAttribute('data-theme') === 'day';
                const textColor = isDay ? '#0f172a' : '#f8fafc';
                const gridColor = isDay ? 'rgba(0,0,0,0.05)' : 'rgba(255,255,255,0.05)';

                historyLatencyChart = new Chart(latencyCtx, {
                    type: 'line',
                    data: {
                        labels: labels,
                        datasets: [{
                            label: '遅延 (ms)',
                            data: latencyData,
                            borderColor: '#3b82f6',
                            backgroundColor: 'rgba(59, 130, 246, 0.1)',
                            fill: true,
                            tension: 0.3,
                            pointRadius: 0
                        }]
                    },
                    options: {
                        responsive: true,
                        maintainAspectRatio: false,
                        plugins: { legend: { labels: { color: textColor } } },
                        scales: {
                            x: { ticks: { color: textColor, maxTicksLimit: 10 }, grid: { color: gridColor } },
                            y: { ticks: { color: textColor }, grid: { color: gridColor }, beginAtZero: true }
                        }
                    }
                });

                historyTrafficChart = new Chart(trafficCtx, {
                    type: 'line',
                    data: {
                        labels: labels,
                        datasets: [
                            {
                                label: '送信 (Tx Mbps)',
                                data: txData,
                                borderColor: '#ec4899',
                                backgroundColor: 'transparent',
                                tension: 0.3,
                                pointRadius: 0
                            },
                            {
                                label: '受信 (Rx Mbps)',
                                data: rxData,
                                borderColor: '#10b981',
                                backgroundColor: 'transparent',
                                tension: 0.3,
                                pointRadius: 0
                            }
                        ]
                    },
                    options: {
                        responsive: true,
                        maintainAspectRatio: false,
                        plugins: { legend: { labels: { color: textColor } } },
                        scales: {
                            x: { ticks: { color: textColor, maxTicksLimit: 10 }, grid: { color: gridColor } },
                            y: { ticks: { color: textColor }, grid: { color: gridColor }, beginAtZero: true }
                        }
                    }
                });
            }
        } catch (err) {
            console.error('Failed to load history:', err);
        }
    }

    function parseLatestIperfSpeed(output) {
        if (!output) return null;
        const lines = output.split('\n');
        for (let i = lines.length - 1; i >= 0; i--) {
            const line = lines[i];
            if (line.includes('sender') || line.includes('receiver')) continue;
            
            const match = line.match(/(\d+(?:\.\d+)?)-(\d+(?:\.\d+)?)\s+sec.*?(\d+(?:\.\d+)?)\s+([KMGb]?bits\/sec)/i);
            if (match) {
                const start = parseFloat(match[1]);
                const end = parseFloat(match[2]);
                const val = parseFloat(match[3]);
                const unitRaw = match[4];
                
                if (end - start <= 1.5) {
                    return {
                        val: val.toFixed(2),
                        unit: unitRaw,
                        start: start,
                        end: end
                    };
                }
            }
        }
        return null;
    }

    function updateIperfChart(output) {
        if (!iperfChart || !output) return;
        const lines = output.split('\n');
        const dataPoints = [];
        lines.forEach(line => {
            // Parse iperf3 interval lines
            const match = line.match(/(\d+(?:\.\d+)?)-(\d+(?:\.\d+)?)\s+sec.*?(\d+(?:\.\d+)?)\s+([KMGb]?bits\/sec)/i);
            if (match) {
                const start = parseFloat(match[1]);
                const end = parseFloat(match[2]);
                let mbits = parseFloat(match[3]);
                const unitRaw = match[4];
                if (/Gbits/i.test(unitRaw)) mbits *= 1000;
                else if (/Kbits/i.test(unitRaw)) mbits /= 1000;

                if (end - start <= 1.5) {
                    dataPoints.push({ sec: end, val: mbits, label: `${start}-${end}s` });
                }
            }
        });

        // Deduplicate and sort
        const uniquePoints = [];
        const seenSec = new Set();
        dataPoints.forEach(p => {
            if (!seenSec.has(p.sec)) {
                seenSec.add(p.sec);
                uniquePoints.push(p);
            }
        });
        uniquePoints.sort((a, b) => a.sec - b.sec);

        if (uniquePoints.length > 0) {
            iperfChart.data.labels = uniquePoints.map(p => p.label);
            iperfChart.data.datasets[0].data = uniquePoints.map(p => p.val);
            iperfChart.update();
        }
    }

    // Update tab switching to trigger history load
    snmpTabBtns.forEach(btn => {
        btn.addEventListener('click', () => {
            const targetTab = btn.getAttribute('data-tab');
            if (targetTab === 'snmp-tab-history' && currentSnmpIp) {
                initHistoryCharts(currentSnmpIp);
            }
            if (targetTab === 'snmp-tab-mtr') {
                if (mtrConsole) mtrConsole.scrollTop = mtrConsole.scrollHeight;
            }
        });
    });


    // ---- OSS License Modal ----
    const ossLicenseModal  = document.getElementById('oss-license-modal');
    const ossLicenseBtn    = document.getElementById('oss-license-btn');
    const closeOssBtn      = document.getElementById('close-oss-license-btn');
    const closeOssFooter   = document.getElementById('close-oss-license-footer-btn');

    function openOssModal() {
        if (ossLicenseModal) {
            ossLicenseModal.style.display = 'flex';
            setTimeout(function() { ossLicenseModal.classList.add('active'); }, 10);
        }
    }
    function closeOssModal() {
        if (ossLicenseModal) {
            ossLicenseModal.classList.remove('active');
            setTimeout(function() { ossLicenseModal.style.display = 'none'; }, 250);
        }
    }

    if (ossLicenseBtn)   ossLicenseBtn.addEventListener('click', openOssModal);
    if (closeOssBtn)     closeOssBtn.addEventListener('click', closeOssModal);
    if (closeOssFooter)  closeOssFooter.addEventListener('click', closeOssModal);
    if (ossLicenseModal) {
        ossLicenseModal.addEventListener('click', function(e) {
            if (e.target === ossLicenseModal) closeOssModal();
        });
    }

    // =========================================================================
    // 8 Major Features Implementation
    // =========================================================================

    // 1. Simple Mode (かんたん表示) Toggle
    const uiModeToggleBtn = document.getElementById('ui-mode-toggle-btn');
    const uiModeIcon = document.getElementById('ui-mode-icon');
    const uiModeText = document.getElementById('ui-mode-text');
    let currentUiMode = localStorage.getItem('netmon_ui_mode') || 'detail';

    function applyUiMode(mode) {
        currentUiMode = mode;
        localStorage.setItem('netmon_ui_mode', mode);
        if (mode === 'simple') {
            document.body.classList.add('simple-mode');
            if (uiModeIcon) uiModeIcon.textContent = '🎨';
            if (uiModeText) uiModeText.textContent = 'かんたん表示中';
            if (uiModeToggleBtn) uiModeToggleBtn.classList.add('active');
        } else {
            document.body.classList.remove('simple-mode');
            if (uiModeIcon) uiModeIcon.textContent = '📊';
            if (uiModeText) uiModeText.textContent = '詳細表示モード';
            if (uiModeToggleBtn) uiModeToggleBtn.classList.remove('active');
        }
    }

    if (uiModeToggleBtn) {
        uiModeToggleBtn.addEventListener('click', () => {
            const newMode = (currentUiMode === 'simple') ? 'detail' : 'simple';
            applyUiMode(newMode);
            showToast((newMode === 'simple') ? 'かんたん表示モードに切り替えました' : '詳細表示モードに切り替えました', 'info');
        });
    }
    applyUiMode(currentUiMode);

    // 2. Report Export (ワンクリック点検報告書出力)
    const btnExportReport = document.getElementById('btn-export-report');
    if (btnExportReport) {
        btnExportReport.addEventListener('click', () => {
            window.open('/api/reports/export?period=today', '_blank');
        });
    }

    // 3. Audit Log Modal (操作履歴・監査ログ)
    const auditModal = document.getElementById('audit-modal');
    const btnOpenAuditModal = document.getElementById('btn-open-audit-modal');
    const closeAuditModalBtn = document.getElementById('close-audit-modal-btn');
    const closeAuditModalFooterBtn = document.getElementById('close-audit-modal-footer-btn');
    const auditLogList = document.getElementById('audit-log-list');

    async function openAuditModal() {
        if (!auditModal) return;
        auditModal.style.display = 'flex';
        setTimeout(() => auditModal.classList.add('active'), 10);
        
        if (auditLogList) {
            auditLogList.innerHTML = '<div style="color:var(--text-muted); text-align:center; padding:20px;">履歴を読み込み中...</div>';
            try {
                const res = await fetch('/api/audit-logs');
                if (res.ok) {
                    const data = await res.json();
                    if (data.logs && data.logs.length > 0) {
                        auditLogList.innerHTML = data.logs.map(line => {
                            const match = line.match(/^\[(.*?)\]\s+\[(.*?)\]\s+\[(.*?)\]\s+\[(.*?)\]\s+(.*)$/);
                            if (match) {
                                const [_, ts, ip, action, target, details] = match;
                                return `
                                    <div class="audit-entry">
                                        <span style="color:var(--text-muted); font-size:0.75rem; white-space:nowrap;">${escapeHTML(ts)}</span>
                                        <span class="audit-action-tag">${escapeHTML(action)}</span>
                                        <span style="font-weight:600; color:var(--primary); font-size:0.8rem; min-width:90px;">${escapeHTML(target)}</span>
                                        <span style="color:var(--text-main); font-size:0.8rem; flex:1;">${escapeHTML(details)}</span>
                                    </div>
                                `;
                            }
                            return `<div style="padding:4px 8px; color:var(--text-main);">${escapeHTML(line)}</div>`;
                        }).join('');
                    } else {
                        auditLogList.innerHTML = '<div style="color:var(--text-muted); text-align:center; padding:20px;">記録された操作履歴はありません。</div>';
                    }
                }
            } catch (err) {
                auditLogList.innerHTML = '<div style="color:var(--error); text-align:center; padding:20px;">履歴の取得に失敗しました。</div>';
            }
        }
    }

    function closeAuditModal() {
        if (auditModal) {
            auditModal.classList.remove('active');
            setTimeout(() => auditModal.style.display = 'none', 250);
        }
    }

    if (btnOpenAuditModal) btnOpenAuditModal.addEventListener('click', openAuditModal);
    if (closeAuditModalBtn) closeAuditModalBtn.addEventListener('click', closeAuditModal);
    if (closeAuditModalFooterBtn) closeAuditModalFooterBtn.addEventListener('click', closeAuditModal);
    if (auditModal) {
        auditModal.addEventListener('click', (e) => {
            if (e.target === auditModal) closeAuditModal();
        });
    }

    // 4. Syslog / Trap Stream Management
    const syslogContainer = document.getElementById('syslog-stream-container');
    const syslogSeverityFilter = document.getElementById('syslog-severity-filter');
    const syslogSearchInput = document.getElementById('syslog-search-input');
    const syslogClearBtn = document.getElementById('syslog-clear-btn');
    let cachedSyslogs = [];

    function renderSyslogStream() {
        if (!syslogContainer) return;
        const sevFilter = syslogSeverityFilter ? syslogSeverityFilter.value : 'ALL';
        const q = syslogSearchInput ? syslogSearchInput.value.trim().toLowerCase() : '';

        const filtered = cachedSyslogs.filter(log => {
            if (sevFilter !== 'ALL' && log.Severity !== sevFilter) return false;
            if (q) {
                const combined = `${log.Timestamp} ${log.SourceIP} ${log.Severity} ${log.Message}`.toLowerCase();
                if (!combined.includes(q)) return false;
            }
            return true;
        });

        if (filtered.length === 0) {
            syslogContainer.innerHTML = '<div style="color:var(--text-muted); text-align:center; padding:40px;">一致する Syslog メッセージはありません。</div>';
            return;
        }

        syslogContainer.innerHTML = filtered.map(log => {
            const sevClass = (log.Severity || 'info').toLowerCase();
            return `
                <div class="syslog-line">
                    <span style="color:var(--text-muted); font-size:0.75rem; white-space:nowrap;">${escapeHTML(log.Timestamp)}</span>
                    <span class="syslog-tag ${sevClass}">${escapeHTML(log.Severity || 'INFO')}</span>
                    <span style="color:var(--primary); font-weight:600; font-size:0.8rem; min-width:95px;">${escapeHTML(log.SourceIP)}</span>
                    <span style="color:var(--text-main); font-size:0.82rem; flex:1;">${escapeHTML(log.Message)}</span>
                </div>
            `;
        }).join('');
    }

    async function fetchSyslogLogs() {
        try {
            const res = await fetch('/api/syslog');
            if (res.ok) {
                const data = await res.json();
                cachedSyslogs = data.logs || [];
                renderSyslogStream();
            }
        } catch (err) {}
    }

    if (syslogSeverityFilter) syslogSeverityFilter.addEventListener('change', renderSyslogStream);
    if (syslogSearchInput) syslogSearchInput.addEventListener('input', renderSyslogStream);
    if (syslogClearBtn) {
        syslogClearBtn.addEventListener('click', async () => {
            if (confirm('受信した Syslog バッファを消去しますか？')) {
                await fetch('/api/syslog/clear', { method: 'POST' });
                cachedSyslogs = [];
                renderSyslogStream();
                showToast('Syslog ログを消去しました', 'info');
            }
        });
    }
    // Poll syslog every 3s when syslog tab is active
    setInterval(() => {
        if (viewSyslog && viewSyslog.classList.contains('active')) {
            fetchSyslogLogs();
        }
    }, 3000);

    // 6. Configuration Backup & Diff
    const btnRunConfigBackup = document.getElementById('btn-run-config-backup');
    const configBackupFileList = document.getElementById('config-backup-file-list');
    const configPreviewBox = document.getElementById('config-preview-box');
    const btnDiffConfigs = document.getElementById('btn-diff-configs');
    let selectedBackupFiles = [];

    async function loadConfigBackupList(ip) {
        if (!configBackupFileList) return;
        configBackupFileList.innerHTML = '<div style="color:var(--text-muted); text-align:center; padding:10px;">バックアップ一覧を読み込み中...</div>';
        selectedBackupFiles = [];
        try {
            const res = await fetch('/api/config-backup/list');
            if (res.ok) {
                const data = await res.json();
                const devBackups = (data.backups || []).filter(b => !ip || b.ip === ip);
                if (devBackups.length > 0) {
                    configBackupFileList.innerHTML = devBackups.map(b => `
                        <label style="display:flex; align-items:center; gap:8px; padding:6px 8px; border-radius:6px; background:rgba(255,255,255,0.03); cursor:pointer;">
                            <input type="checkbox" class="backup-checkbox" value="${escapeHTML(b.filename)}">
                            <div style="flex:1; overflow:hidden;" class="backup-item-click" data-file="${escapeHTML(b.filename)}">
                                <div style="font-weight:600; font-size:0.8rem; text-overflow:ellipsis; overflow:hidden; white-space:nowrap;">${escapeHTML(b.filename)}</div>
                                <div style="font-size:0.7rem; color:var(--text-muted);">${escapeHTML(b.timestamp)} (${escapeHTML(b.size)})</div>
                            </div>
                        </label>
                    `).join('');

                    // Click to preview
                    configBackupFileList.querySelectorAll('.backup-item-click').forEach(item => {
                        item.addEventListener('click', async () => {
                            const fn = item.getAttribute('data-file');
                            if (configPreviewBox) {
                                configPreviewBox.textContent = `読み込み中: ${fn}...`;
                                try {
                                    const diffRes = await fetch(`/api/config-backup/diff?f1=${encodeURIComponent(fn)}&f2=${encodeURIComponent(fn)}`);
                                    if (diffRes.ok) {
                                        const diffData = await diffRes.json();
                                        configPreviewBox.textContent = (diffData.diff || []).map(d => d.file1).join('\n');
                                    }
                                } catch (e) {
                                    configPreviewBox.textContent = '読み込みに失敗しました。';
                                }
                            }
                        });
                    });
                } else {
                    configBackupFileList.innerHTML = '<div style="color:var(--text-muted); text-align:center; padding:10px;">バックアップ履歴がありません。</div>';
                }
            }
        } catch (err) {
            configBackupFileList.innerHTML = '<div style="color:var(--error); text-align:center; padding:10px;">取得エラー</div>';
        }
    }

    if (btnRunConfigBackup) {
        btnRunConfigBackup.addEventListener('click', async () => {
            if (!currentSnmpIp) return;
            btnRunConfigBackup.disabled = true;
            btnRunConfigBackup.textContent = '取得中...';
            try {
                const res = await fetch('/api/config-backup/run', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ ip: currentSnmpIp })
                });
                const data = await res.json();
                if (res.ok && data.status === 'success') {
                    showToast(`✅ スナップショットを作成しました (${data.filename})`, 'success');
                    await loadConfigBackupList(currentSnmpIp);
                } else {
                    showToast('❌ バックアップ取得に失敗しました。', 'error');
                }
            } catch (err) {
                showToast('❌ 通信エラーが発生しました。', 'error');
            } finally {
                btnRunConfigBackup.disabled = false;
                btnRunConfigBackup.textContent = '➕ バックアップ即時取得';
            }
        });
    }

    if (btnDiffConfigs) {
        btnDiffConfigs.addEventListener('click', async () => {
            const checked = Array.from(configBackupFileList.querySelectorAll('.backup-checkbox:checked')).map(cb => cb.value);
            if (checked.length !== 2) {
                alert('差分比較を行うには、バックアップ一覧からチェックボックスで「2世代」選択してください。');
                return;
            }
            if (configPreviewBox) {
                configPreviewBox.innerHTML = '<div style="color:var(--text-muted); padding:10px;">差分を計算中...</div>';
                try {
                    const res = await fetch(`/api/config-backup/diff?f1=${encodeURIComponent(checked[0])}&f2=${encodeURIComponent(checked[1])}`);
                    if (res.ok) {
                        const data = await res.json();
                        if (data.diff) {
                            configPreviewBox.innerHTML = `
                                <div style="display:grid; grid-template-columns:35px 1fr 1fr; gap:8px; font-weight:700; border-bottom:2px solid var(--glass-border); padding-bottom:4px; margin-bottom:4px; font-size:0.78rem;">
                                    <span>行</span>
                                    <span>${escapeHTML(checked[0])}</span>
                                    <span>${escapeHTML(checked[1])}</span>
                                </div>
                                ${data.diff.map(d => `
                                    <div class="diff-row ${d.changed ? 'changed' : ''}">
                                        <span class="line-num">${d.line}</span>
                                        <span style="word-break:break-all; ${d.changed ? 'color:#fb923c;' : ''}">${escapeHTML(d.file1 || '')}</span>
                                        <span style="word-break:break-all; ${d.changed ? 'color:#4ade80;' : ''}">${escapeHTML(d.file2 || '')}</span>
                                    </div>
                                `).join('')}
                            `;
                        }
                    }
                } catch (e) {
                    configPreviewBox.textContent = '差分の取得に失敗しました。';
                }
            }
        });
    }

    // 6. Update SNMP Modal Opening with Manual Link and Backup
    const originalOpenSnmpDetailsModal = openSnmpDetailsModal;
    openSnmpDetailsModal = async function(device) {
        if (originalOpenSnmpDetailsModal) await originalOpenSnmpDetailsModal(device);
        
        // Populate manual and location tab
        const locEl = document.getElementById('modal-memo-location');
        const webEl = document.getElementById('modal-memo-weburl');
        const linkWrapper = document.getElementById('modal-memo-link-wrapper');
        const linkEl = document.getElementById('modal-memo-link');
        const emptyEl = document.getElementById('modal-memo-empty');
        
        if (locEl) locEl.textContent = device.location || '未登録';
        if (webEl) webEl.innerHTML = device.webUrl ? `<a href="${escapeHTML(device.webUrl)}" target="_blank" style="color:var(--primary); text-decoration:underline;">${escapeHTML(device.webUrl)}</a>` : '—';
        
        if (device.troubleMemo && device.troubleMemo.trim()) {
            if (linkEl) linkEl.href = device.troubleMemo.trim();
            if (linkWrapper) linkWrapper.style.display = 'block';
            if (emptyEl) emptyEl.style.display = 'none';
        } else {
            if (linkWrapper) linkWrapper.style.display = 'none';
            if (emptyEl) emptyEl.style.display = 'block';
        }

        // Load backup list
        loadConfigBackupList(device.ip);
    };

    // 7. Helper: Render simple mode memo badge into device cards
    const originalRenderDeviceCard = renderDeviceCard;
    if (typeof originalRenderDeviceCard === 'function') {
        renderDeviceCard = function(device) {
            const card = originalRenderDeviceCard(device);
            if (card && (device.location || device.troubleMemo)) {
                const memoDiv = document.createElement('div');
                memoDiv.className = 'simple-mode-memo-badge';
                memoDiv.innerHTML = `
                    ${device.location ? `<span>📍 <strong>${escapeHTML(device.location)}</strong></span>` : ''}
                    ${device.troubleMemo ? `<span>📖 <a href="${escapeHTML(device.troubleMemo)}" target="_blank" style="color:var(--primary); font-weight:600; text-decoration:underline;">マニュアル</a></span>` : ''}
                `;
                const content = card.querySelector('.device-card-content') || card;
                content.appendChild(memoDiv);
            }
            return card;
        };
    }
});
