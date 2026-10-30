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

    // リンク先として使ってよいURLだけを返す (javascript: など、クリックで任意の処理が動くURLは無効にする)
    // 「\\サーバー\共有」や「C:\フォルダ」のようなパスは file: のURLに直す
    function safeLinkUrl(url) {
        const u = (url || '').toString().trim();
        if (!u) return '';
        if (/^(https?|file):/i.test(u)) return u;
        if (/^\\\\/.test(u)) return 'file:' + u.replace(/\\/g, '/');            // \\server\share → file://server/share
        if (/^[a-zA-Z]:[\\/]/.test(u)) return 'file:///' + u.replace(/\\/g, '/'); // C:\docs → file:///C:/docs
        if (/^[a-zA-Z][a-zA-Z0-9+.\-]*:/.test(u)) return '';
        return 'http://' + u;
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

        const icons = { warning: '⚠️', error: '🔴', info: 'ℹ️', success: '✅' };
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

    // ---- Remote Management Form Controls (Milestone 2) ----
    const devRemoteEnabled = document.getElementById('dev-remote-enabled');
    const devRemoteCollapsible = document.getElementById('remote-settings-collapsible');
    const devRemoteProtocol = document.getElementById('dev-remote-protocol');
    const devRemoteHost = document.getElementById('dev-remote-host');
    const devRemotePort = document.getElementById('dev-remote-port');
    const devRemoteAuthType = document.getElementById('dev-remote-auth-type');
    const devRemoteUser = document.getElementById('dev-remote-user');
    const devRemotePass = document.getElementById('dev-remote-pass');
    const devRemoteKeyPath = document.getElementById('dev-remote-key-path');
    const devRemoteRebootCmd = document.getElementById('dev-remote-reboot-cmd');
    const devRemoteCommandsList = document.getElementById('dev-remote-commands-list');
    const devCmdNameInput = document.getElementById('dev-cmd-name-input');
    const devCmdDescInput = document.getElementById('dev-cmd-desc-input');
    const devCmdStringInput = document.getElementById('dev-cmd-string-input');
    const btnAddRemoteCmd = document.getElementById('btn-add-remote-cmd');

    let currentFormRemoteCommands = [];

    function renderFormRemoteCommands() {
        if (!devRemoteCommandsList) return;
        devRemoteCommandsList.innerHTML = '';
        if (!currentFormRemoteCommands || currentFormRemoteCommands.length === 0) {
            devRemoteCommandsList.innerHTML = '<div style="color:var(--text-muted); font-size:0.75rem; padding:4px 0;">登録されたカスタムコマンドはありません。</div>';
            return;
        }
        currentFormRemoteCommands.forEach((cmd, idx) => {
            const item = document.createElement('div');
            item.className = 'remote-cmd-item';
            item.innerHTML = `
                <div style="overflow:hidden; flex:1;">
                    <div><strong>${escapeHTML(cmd.name || 'コマンド')}</strong> ${cmd.description ? `<span style="color:var(--text-muted); font-size:0.72rem;">(${escapeHTML(cmd.description)})</span>` : ''}</div>
                    <code>${escapeHTML(cmd.command || '')}</code>
                </div>
                <button type="button" class="btn secondary-btn small danger-text" data-idx="${idx}" style="padding:2px 6px; font-size:0.75rem;" title="コマンドを削除">🗑</button>
            `;
            item.querySelector('button').addEventListener('click', (e) => {
                e.preventDefault();
                currentFormRemoteCommands.splice(idx, 1);
                renderFormRemoteCommands();
            });
            devRemoteCommandsList.appendChild(item);
        });
    }

    function updateRemoteFormVisibility() {
        const proto = devRemoteProtocol ? devRemoteProtocol.value : 'ssh';
        const auth = devRemoteAuthType ? devRemoteAuthType.value : 'password';

        // Auto-update port if port matches default or is empty
        if (devRemotePort) {
            const currentPort = parseInt(devRemotePort.value, 10);
            if (!currentPort || currentPort === 22 || currentPort === 5985) {
                devRemotePort.value = (proto === 'winrm') ? 5985 : (proto === 'ssh' ? 22 : '');
            }
        }

        // Toggle auth input groups
        const keyGroup = document.getElementById('remote-key-path-group');
        const passGroup = document.getElementById('remote-pass-group');
        const userGroup = document.getElementById('remote-user-group');

        if (keyGroup) keyGroup.classList.toggle('hidden', auth !== 'key');
        if (passGroup) passGroup.classList.toggle('hidden', auth === 'none' || auth === 'windows_current');
        if (userGroup) userGroup.classList.toggle('hidden', auth === 'windows_current');
    }

    if (devRemoteEnabled) {
        devRemoteEnabled.addEventListener('change', () => {
            if (devRemoteCollapsible) {
                devRemoteCollapsible.classList.toggle('hidden', !devRemoteEnabled.checked);
            }
        });
    }
    if (devRemoteProtocol) {
        devRemoteProtocol.addEventListener('change', updateRemoteFormVisibility);
    }
    if (devRemoteAuthType) {
        devRemoteAuthType.addEventListener('change', updateRemoteFormVisibility);
    }

    if (btnAddRemoteCmd) {
        btnAddRemoteCmd.addEventListener('click', () => {
            const name = devCmdNameInput ? devCmdNameInput.value.trim() : '';
            const cmdStr = devCmdStringInput ? devCmdStringInput.value.trim() : '';
            const desc = devCmdDescInput ? devCmdDescInput.value.trim() : '';
            if (!cmdStr) {
                alert('実行コマンドを入力してください。');
                return;
            }
            const newCmd = {
                id: 'cmd-' + Date.now() + '-' + Math.random().toString(36).substr(2, 4),
                name: name || cmdStr,
                command: cmdStr,
                description: desc
            };
            currentFormRemoteCommands.push(newCmd);
            if (devCmdNameInput) devCmdNameInput.value = '';
            if (devCmdStringInput) devCmdStringInput.value = '';
            if (devCmdDescInput) devCmdDescInput.value = '';
            renderFormRemoteCommands();
        });
    }

    // SNMP の入力欄に機器の値を入れる (device が null なら新規登録用に初期値へ戻す)
    // ※ 保存済みのパスワードは画面に出さない。空欄のまま保存すると、今のパスワードをそのまま使い続ける
    function fillSnmpFields(device) {
        const setVal = (id, val) => { const el = document.getElementById(id); if (el) el.value = val; };
        setVal('dev-snmp-version', (device && device.snmpVersion) || 'v2c');
        setVal('dev-snmp-user', (device && device.snmpUser) || '');
        setVal('dev-snmp-auth-proto', (device && device.snmpAuthProto) || 'none');
        setVal('dev-snmp-priv-proto', (device && device.snmpPrivProto) || 'none');
        setVal('dev-snmp-auth-pass', '');
        setVal('dev-snmp-priv-pass', '');
        const authPassEl = document.getElementById('dev-snmp-auth-pass');
        if (authPassEl) authPassEl.placeholder = (device && device.snmpAuthPass) ? '保存済み（変更するときだけ入力）' : 'authpassphrase';
        const privPassEl = document.getElementById('dev-snmp-priv-pass');
        if (privPassEl) privPassEl.placeholder = (device && device.snmpPrivPass) ? '保存済み（変更するときだけ入力）' : 'privpassphrase';
        const fieldsEl = document.getElementById('snmpv3-fields');
        if (fieldsEl) fieldsEl.classList.toggle('hidden', ((device && device.snmpVersion) || 'v2c') !== 'v3');
        const privGroupEl = document.getElementById('snmpv3-priv-pass-group');
        if (privGroupEl) privGroupEl.style.display = ((device && device.snmpPrivProto) || 'none') === 'none' ? 'none' : 'block';
    }

    // 入力欄から、保存する SNMP の設定を作る
    function readSnmpFields() {
        const val = (id) => { const el = document.getElementById(id); return el ? el.value.trim() : ''; };
        const authProto = val('dev-snmp-auth-proto') || 'none';
        const privProto = val('dev-snmp-priv-proto') || 'none';
        const fields = {
            snmpVersion: val('dev-snmp-version') || 'v2c',
            snmpUser: val('dev-snmp-user'),
            snmpAuthProto: authProto,
            snmpPrivProto: privProto
        };
        // パスワードは入力されたときだけ送る (送らなければサーバー側で今の値を保つ)。「なし」にしたら消す
        const authPass = document.getElementById('dev-snmp-auth-pass');
        const privPass = document.getElementById('dev-snmp-priv-pass');
        if (authProto === 'none') fields.snmpAuthPass = '';
        else if (authPass && authPass.value) fields.snmpAuthPass = authPass.value;
        if (privProto === 'none') fields.snmpPrivPass = '';
        else if (privPass && privPass.value) fields.snmpPrivPass = privPass.value;
        return fields;
    }

    function openDeviceModal(device = null) {
        if (!device) fillSnmpFields(null);
        if (device) {
            // Edit mode: populate existing device info
            if (editOldIpInput) editOldIpInput.value = device.ip;
            if (devIpInput) {
                devIpInput.value = device.ip;
                devIpInput.placeholder = '192.168.1.1';
            }
            if (devNameInput) devNameInput.value = (device.name && device.name !== device.ip) ? device.name : '';
            if (devGroupInput) devGroupInput.value = device.group || '';
            populateGroupDropdown(device.group || '');
            if (devGroupNew) devGroupNew.classList.add('hidden');
            if (devCommInput) devCommInput.value = device.community || 'public';
            if (devEnabledInput) devEnabledInput.checked = device.enabled !== false;
            if (submitDeviceBtn) submitDeviceBtn.textContent = '機器情報を更新';

            const devLocEl = document.getElementById('dev-location');
            const devMemoEl = document.getElementById('dev-trouble-memo');
            const devWebEl = document.getElementById('dev-web-url');
            const devCheckTypeEl = document.getElementById('dev-check-type');
            const devPortEl = document.getElementById('dev-port');
            const devPortGroup = document.getElementById('dev-tcp-port-group');
            if (devLocEl) devLocEl.value = device.location || '';
            if (devMemoEl) devMemoEl.value = device.troubleMemo || '';
            if (devWebEl) devWebEl.value = device.webUrl || '';
            if (devCheckTypeEl) {
                devCheckTypeEl.value = device.checkType || 'icmp';
                if (devPortGroup) {
                    devPortGroup.classList.toggle('hidden', devCheckTypeEl.value !== 'tcp');
                }
            }
            if (devPortEl) devPortEl.value = device.port || 80;
            fillSnmpFields(device);

            if (typeof populateConnectionsDropdown === 'function') {
                populateConnectionsDropdown(device.ip);
            }
            const parents = device.connectedTo ? device.connectedTo.split(',').map(p => p.trim()).filter(p => p) : [];
            const devConn1 = document.getElementById('dev-parent-ip') || (typeof devConnectedTo !== 'undefined' ? devConnectedTo : null);
            const devConn2 = typeof devConnectedTo2 !== 'undefined' ? devConnectedTo2 : null;
            if (devConn1) devConn1.value = parents[0] || '';
            if (devConn2) devConn2.value = parents[1] || '';

            const imgTypeEl = typeof devImageType !== 'undefined' ? devImageType : document.getElementById('dev-image-type');
            const imgUploadCont = typeof devImageUploadContainer !== 'undefined' ? devImageUploadContainer : document.getElementById('dev-image-upload-container');
            const imgUrlEl = typeof devImageUrl !== 'undefined' ? devImageUrl : document.getElementById('dev-image-url');

            if (imgTypeEl && device.image) {
                if (typeof PREDEFINED_ICONS !== 'undefined' && PREDEFINED_ICONS[device.image]) {
                    imgTypeEl.value = device.image;
                    if (imgUploadCont) imgUploadCont.style.display = 'none';
                } else {
                    imgTypeEl.value = 'upload';
                    if (imgUploadCont) imgUploadCont.style.display = 'flex';
                    if (imgUrlEl) imgUrlEl.value = device.image;
                }
            } else if (imgTypeEl) {
                imgTypeEl.value = '';
                if (imgUploadCont) imgUploadCont.style.display = 'none';
                if (imgUrlEl) imgUrlEl.value = '';
            }

            // Remote settings populate
            if (devRemoteEnabled) {
                devRemoteEnabled.checked = !!(device.remote && device.remote.enabled);
            }
            if (devRemoteCollapsible) {
                devRemoteCollapsible.classList.toggle('hidden', !(device.remote && device.remote.enabled));
            }
            if (device.remote) {
                if (devRemoteProtocol) devRemoteProtocol.value = device.remote.protocol || 'ssh';
                if (devRemoteHost) devRemoteHost.value = device.remote.host || '';
                if (devRemotePort) devRemotePort.value = device.remote.port || (device.remote.protocol === 'winrm' ? 5985 : 22);
                if (devRemoteAuthType) devRemoteAuthType.value = device.remote.authType || 'password';
                if (devRemoteUser) devRemoteUser.value = device.remote.user || '';
                if (devRemotePass) devRemotePass.value = '';
                if (devRemoteKeyPath) devRemoteKeyPath.value = device.remote.keyPath || '';
                if (devRemoteRebootCmd) devRemoteRebootCmd.value = device.remote.rebootCommand || '';
                currentFormRemoteCommands = Array.isArray(device.remote.commands) ? JSON.parse(JSON.stringify(device.remote.commands)) : [];
            } else {
                if (devRemoteProtocol) devRemoteProtocol.value = 'ssh';
                if (devRemoteHost) devRemoteHost.value = '';
                if (devRemotePort) devRemotePort.value = 22;
                if (devRemoteAuthType) devRemoteAuthType.value = 'password';
                if (devRemoteUser) devRemoteUser.value = '';
                if (devRemotePass) devRemotePass.value = '';
                if (devRemoteKeyPath) devRemoteKeyPath.value = '';
                if (devRemoteRebootCmd) devRemoteRebootCmd.value = '';
                currentFormRemoteCommands = [];
            }
            updateRemoteFormVisibility();
            renderFormRemoteCommands();
        } else {
            // New device / reset mode
            if (editOldIpInput) editOldIpInput.value = '';
            if (devIpInput) {
                devIpInput.value = '';
                devIpInput.placeholder = '例: 192.168.1.1 または 192.168.1.1, コアルーター';
            }
            if (devNameInput) devNameInput.value = '';
            if (devGroupInput) devGroupInput.value = '';
            populateGroupDropdown('');
            if (devGroupNew) devGroupNew.classList.add('hidden');
            if (devCommInput) devCommInput.value = 'public';
            if (devEnabledInput) devEnabledInput.checked = true;
            if (submitDeviceBtn) submitDeviceBtn.textContent = '機器を保存';

            const devLocEl = document.getElementById('dev-location');
            const devMemoEl = document.getElementById('dev-trouble-memo');
            const devWebEl = document.getElementById('dev-web-url');
            const devCheckTypeEl = document.getElementById('dev-check-type');
            const devPortEl = document.getElementById('dev-port');
            const devPortGroup = document.getElementById('dev-tcp-port-group');
            if (devLocEl) devLocEl.value = '';
            if (devMemoEl) devMemoEl.value = '';
            if (devWebEl) devWebEl.value = '';
            if (devCheckTypeEl) devCheckTypeEl.value = 'icmp';
            if (devPortGroup) devPortGroup.classList.add('hidden');
            if (devPortEl) devPortEl.value = 80;

            const imgTypeEl = typeof devImageType !== 'undefined' ? devImageType : document.getElementById('dev-image-type');
            const imgUploadCont = typeof devImageUploadContainer !== 'undefined' ? devImageUploadContainer : document.getElementById('dev-image-upload-container');
            const imgUrlEl = typeof devImageUrl !== 'undefined' ? devImageUrl : document.getElementById('dev-image-url');
            if (imgTypeEl) {
                imgTypeEl.value = '';
                if (imgUploadCont) imgUploadCont.style.display = 'none';
                if (imgUrlEl) imgUrlEl.value = '';
            }

            if (devRemoteEnabled) devRemoteEnabled.checked = false;
            if (devRemoteCollapsible) devRemoteCollapsible.classList.add('hidden');
            if (devRemoteProtocol) devRemoteProtocol.value = 'ssh';
            if (devRemoteHost) devRemoteHost.value = '';
            if (devRemotePort) devRemotePort.value = 22;
            if (devRemoteAuthType) devRemoteAuthType.value = 'password';
            if (devRemoteUser) devRemoteUser.value = '';
            if (devRemotePass) devRemotePass.value = '';
            if (devRemoteKeyPath) devRemoteKeyPath.value = '';
            if (devRemoteRebootCmd) devRemoteRebootCmd.value = '';
            currentFormRemoteCommands = [];
            updateRemoteFormVisibility();
            renderFormRemoteCommands();
        }
    }
    window.openDeviceModal = openDeviceModal;

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

    // ── 10分間アラート一時消音 (Mute) 制御 ──────────────────────────────────────
    let muteUntilTimestamp = 0;
    let muteTimerInterval = null;

    function isAlertMuted() {
        return Date.now() < muteUntilTimestamp;
    }

    function updateMuteButtonUI() {
        const btn = document.getElementById('btn-mute-alert');
        const icon = document.getElementById('mute-icon');
        const text = document.getElementById('mute-text');
        if (!btn || !icon || !text) return;

        if (isAlertMuted()) {
            btn.classList.add('btn-mute-active');
            const remainingSec = Math.max(0, Math.ceil((muteUntilTimestamp - Date.now()) / 1000));
            const m = Math.floor(remainingSec / 60);
            const s = remainingSec % 60;
            const timeStr = `${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
            icon.textContent = '🔇';
            text.textContent = `消音中 (${timeStr})`;
            btn.title = `現在アラート音を消音しています。クリックで即時解除 (${timeStr})`;
        } else {
            btn.classList.remove('btn-mute-active');
            icon.textContent = '🔊';
            text.textContent = '消音 (10分)';
            btn.title = 'クリックすると10分間アラート警告音を一時消音します';
            if (muteTimerInterval) {
                clearInterval(muteTimerInterval);
                muteTimerInterval = null;
            }
        }
    }

    function toggleMuteAlert() {
        if (isAlertMuted()) {
            muteUntilTimestamp = 0;
            if (muteTimerInterval) { clearInterval(muteTimerInterval); muteTimerInterval = null; }
            updateMuteButtonUI();
            showToast('info', '🔊 音声通知再開', 'アラート警告音の消音を解除しました。', 3000);
        } else {
            muteUntilTimestamp = Date.now() + 10 * 60 * 1000; // 10分
            updateMuteButtonUI();
            if (muteTimerInterval) clearInterval(muteTimerInterval);
            muteTimerInterval = setInterval(() => {
                if (!isAlertMuted()) {
                    updateMuteButtonUI();
                    showToast('info', '🔊 消音時間終了', 'アラート警告音の消音期間が終了しました。通常モードに復帰します。', 3000);
                } else {
                    updateMuteButtonUI();
                }
            }, 1000);
            showToast('warning', '🔇 10分間消音', 'アラート警告音を10分間一時消音しました。画面の通知表示は継続します。', 4000);
        }
    }

    const btnMuteAlert = document.getElementById('btn-mute-alert');
    if (btnMuteAlert) {
        btnMuteAlert.addEventListener('click', toggleMuteAlert);
    }

    function playAlertSound(type = 'error') {
        if (!systemConfig.soundEnabled || isAlertMuted()) return;
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

    // ── 障害機器の最上部自動ピン留め・ソート制御 ──────────────────────────────
    let isSortFailuresActive = localStorage.getItem('sortFailuresActive') === 'true';

    function updateSortFailuresButtonUI() {
        const btn = document.getElementById('btn-toggle-sort-failures');
        const text = document.getElementById('sort-failures-text');
        if (!btn || !text) return;

        if (isSortFailuresActive) {
            btn.classList.add('btn-sort-active');
            text.textContent = '障害優先表示: ON';
            btn.title = '障害（赤）や警告（黄）の機器を最上部に固定しています。クリックで通常順に戻します';
        } else {
            btn.classList.remove('btn-sort-active');
            text.textContent = '障害優先表示: OFF';
            btn.title = 'クリックすると障害（赤）や警告（黄）の機器をリスト最上部に自動固定します';
        }
    }

    function applyFailureSort() {
        if (!devices || devices.length === 0) return;
        devices.forEach(d => {
            const safeIpId = d.ip.replace(/\./g, '-');
            const cardEl = document.getElementById(`card-${safeIpId}`);
            if (!cardEl) return;

            if (!isSortFailuresActive) {
                cardEl.style.order = '';
                return;
            }

            const data = topologyLastValidStatus[d.ip];
            const isPausedState = (d.enabled === false);

            if (isPausedState) {
                cardEl.style.order = '90';
            } else if (data && (data.status === 'Failed' || data.status === 'Error' || data.status === 'Offline')) {
                cardEl.style.order = '10'; // 最優先（最上部）
            } else if (data && data.status === 'Warning') {
                cardEl.style.order = '20'; // 警告（2番目）
            } else if (data && (data.status === 'Success' || data.status === 'Online')) {
                cardEl.style.order = '50'; // 正常
            } else {
                cardEl.style.order = '60'; // 不明・待機中
            }
        });
    }

    function toggleSortFailures() {
        isSortFailuresActive = !isSortFailuresActive;
        localStorage.setItem('sortFailuresActive', isSortFailuresActive ? 'true' : 'false');
        updateSortFailuresButtonUI();
        applyFailureSort();
        showToast('info', isSortFailuresActive ? '📌 障害優先表示: ON' : '📌 障害優先表示: OFF', 
            isSortFailuresActive ? '障害・警告が発生している機器をリスト最上部に固定表示します。' : '通常のグループ登録順で表示します。', 3000);
    }

    const btnToggleSortFailures = document.getElementById('btn-toggle-sort-failures');
    if (btnToggleSortFailures) {
        btnToggleSortFailures.addEventListener('click', toggleSortFailures);
    }

    // ── 監視終了＆報告書オープン制御 ──────────────────────────────────────────
    const btnShutdownSession = document.getElementById('btn-shutdown-session');
    const shutdownModal = document.getElementById('shutdown-confirm-modal');
    const closeShutdownBtn = document.getElementById('close-shutdown-modal-btn');
    const cancelShutdownBtn = document.getElementById('cancel-shutdown-btn');
    const confirmShutdownBtn = document.getElementById('confirm-shutdown-btn');
    const shutdownCompleteOverlay = document.getElementById('shutdown-complete-overlay');

    if (btnShutdownSession && shutdownModal) {
        btnShutdownSession.addEventListener('click', () => {
            shutdownModal.style.display = 'flex';
        });
    }

    function closeShutdownConfirmModal() {
        if (shutdownModal) shutdownModal.style.display = 'none';
    }

    if (closeShutdownBtn) closeShutdownBtn.addEventListener('click', closeShutdownConfirmModal);
    if (cancelShutdownBtn) cancelShutdownBtn.addEventListener('click', closeShutdownConfirmModal);

    if (confirmShutdownBtn) {
        confirmShutdownBtn.addEventListener('click', async () => {
            closeShutdownConfirmModal();
            // 1. 最新の点検報告書を新規タブで開く
            window.open('/api/reports/export', '_blank');
            // 2. 終了オーバーレイを表示
            if (shutdownCompleteOverlay) {
                shutdownCompleteOverlay.style.display = 'flex';
            }
            // 3. サーバーにシャットダウンリクエストを送信
            try {
                await fetch('/api/shutdown', { method: 'POST' });
            } catch (e) {
                console.log('Shutdown signal dispatched');
            }
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
            return `<option value="${escapeHTML(d.ip)}">${escapeHTML(label)}</option>`;
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

        const warnLatInp = document.getElementById('modal-config-latency-warning');
        if (warnLatInp) warnLatInp.value = systemConfig.latencyWarningMs || 80;

        const consecFailInp = document.getElementById('modal-config-consecutive-fails');
        if (consecFailInp) consecFailInp.value = systemConfig.consecutiveFailThresh || 2;

        const lossWarnInp = document.getElementById('modal-config-loss-warning');
        if (lossWarnInp) lossWarnInp.value = (typeof systemConfig.lossWarningThreshPercent === 'number') ? systemConfig.lossWarningThreshPercent : 5.0;

        const jitterWarnInp = document.getElementById('modal-config-jitter-warning');
        if (jitterWarnInp) jitterWarnInp.value = (typeof systemConfig.jitterWarningThreshMs === 'number') ? systemConfig.jitterWarningThreshMs : 20.0;

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
        if (logRetentionInp) {
            const rDays = (systemConfig.logRetentionDays != null) ? systemConfig.logRetentionDays : 30;
            logRetentionInp.value = rDays;
            const presets = document.querySelectorAll('.btn-retention-preset');
            presets.forEach(b => {
                b.classList.toggle('active', b.dataset.days === String(rDays));
            });
        }

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
            if (targetId === 'cfg-tab-backup') {
                loadSnapshotsList();
            } else if (targetId === 'cfg-tab-prereq') {
                fetchPrerequisites();
            }
        });
    });

    // ── 自動スナップショット履歴＆ロールバック ──
    async function loadSnapshotsList() {
        const listEl = document.getElementById('snapshot-history-list');
        if (!listEl) return;
        listEl.innerHTML = '<div style="font-size:0.75rem; color:var(--text-muted); text-align:center; padding:10px;">スナップショットを読み込み中...</div>';
        try {
            const res = await fetch('/api/snapshots/list');
            if (!res.ok) throw new Error('Failed to fetch snapshots');
            const data = await res.json();
            const snapshots = data.snapshots || [];
            if (snapshots.length === 0) {
                listEl.innerHTML = '<div style="font-size:0.75rem; color:var(--text-muted); text-align:center; padding:10px;">自動保存されたスナップショットはまだありません。</div>';
                return;
            }

            let html = '';
            snapshots.forEach(s => {
                const typeBadge = s.type === 'devices' 
                    ? '<span style="background:rgba(59,130,246,0.2); color:#60a5fa; border:1px solid rgba(59,130,246,0.3); font-size:0.7rem; padding:1px 5px; border-radius:4px; font-weight:600;">機器構成</span>'
                    : '<span style="background:rgba(168,85,247,0.2); color:#c084fc; border:1px solid rgba(168,85,247,0.3); font-size:0.7rem; padding:1px 5px; border-radius:4px; font-weight:600;">システム設定</span>';
                const sizeKb = (s.sizeBytes / 1024).toFixed(1);
                
                html += `
                    <div style="display:flex; justify-content:space-between; align-items:center; padding:6px 8px; border-bottom:1px solid rgba(255,255,255,0.05); font-size:0.75rem;">
                        <div style="display:flex; align-items:center; gap:8px;">
                            ${typeBadge}
                            <span style="font-family:monospace; color:var(--text-light); font-weight:500;">${s.createdAt}</span>
                            <span style="color:var(--text-muted); font-size:0.7rem;">(${sizeKb} KB)</span>
                        </div>
                        <button type="button" class="btn secondary-btn btn-rollback-snapshot" data-file="${s.fileName}" style="padding:2px 8px; font-size:0.7rem; color:#f59e0b; border-color:rgba(245,158,11,0.3);">
                            ↺ この時点に戻す
                        </button>
                    </div>
                `;
            });
            listEl.innerHTML = html;

            listEl.querySelectorAll('.btn-rollback-snapshot').forEach(btn => {
                btn.addEventListener('click', async (e) => {
                    const fName = e.currentTarget.getAttribute('data-file');
                    if (!fName) return;
                    if (!confirm(`【確認】スナップショット「${fName}」の状態にロールバックしますか？\n（安全のため、現在の状態も自動スナップショットとして退避されます）`)) {
                        return;
                    }
                    try {
                        btn.disabled = true;
                        btn.textContent = '復元中...';
                        const restoreRes = await fetch('/api/snapshots/restore', {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify({ fileName: fName })
                        });
                        const resData = await restoreRes.json();
                        if (restoreRes.ok && resData.status === 'success') {
                            showToast('success', '🔄 ロールバック完了', `スナップショット「${fName}」から正常に復元しました。`, 4000);
                            await fetchConfig();
                            await fetchDevices();
                            await loadSnapshotsList();
                        } else {
                            showToast('error', 'ロールバック失敗', resData.error || '復元処理に失敗しました。');
                            btn.disabled = false;
                            btn.textContent = '↺ この時点に戻す';
                        }
                    } catch (err) {
                        showToast('error', 'エラー', err.message);
                        btn.disabled = false;
                        btn.textContent = '↺ この時点に戻す';
                    }
                });
            });
        } catch (err) {
            listEl.innerHTML = `<div style="font-size:0.75rem; color:#ef4444; text-align:center; padding:10px;">スナップショット取得エラー: ${escapeHTML(err.message)}</div>`;
        }
    }

    const btnRefreshSnapshots = document.getElementById('btn-refresh-snapshots');
    if (btnRefreshSnapshots) {
        btnRefreshSnapshots.addEventListener('click', () => {
            loadSnapshotsList();
            showToast('info', 'スナップショット更新', '最新のスナップショット履歴を取得しました。', 2000);
        });
    }

    // ── システム前提環境・モジュール診断 ──
    async function fetchPrerequisites() {
        const bannerEl = document.getElementById('prereq-overall-banner');
        const iconEl = document.getElementById('prereq-overall-icon');
        const textEl = document.getElementById('prereq-overall-text');
        
        if (!bannerEl) return;
        bannerEl.style.background = 'rgba(255,255,255,0.05)';
        bannerEl.style.borderColor = 'var(--glass-border)';
        iconEl.textContent = '⏳';
        textEl.textContent = '前提環境を診断中...';

        try {
            const res = await fetch('/api/system/prerequisites');
            if (!res.ok) throw new Error('診断情報の取得に失敗しました');
            const data = await res.json();

            // 総合バナー
            if (data.allReady) {
                bannerEl.style.background = 'rgba(16,185,129,0.15)';
                bannerEl.style.borderColor = 'rgba(16,185,129,0.4)';
                bannerEl.style.color = '#34d399';
                iconEl.textContent = '✅';
                textEl.textContent = '必須コンポーネント（SNMP / PowerShell / Iperf3）はすべて正常に認識されています。';
            } else {
                bannerEl.style.background = 'rgba(239,68,68,0.15)';
                bannerEl.style.borderColor = 'rgba(239,68,68,0.4)';
                bannerEl.style.color = '#f87171';
                iconEl.textContent = '⚠️';
                textEl.textContent = '一部の前提モジュールまたはツールが未検出です。下記のボタンからインストールできます。';
            }

            // SNMP
            const snmpStatus = document.getElementById('prereq-status-snmp');
            const snmpBadge = document.getElementById('prereq-badge-snmp');
            const snmpDetail = document.getElementById('prereq-detail-snmp');
            const btnInstallSnmp = document.getElementById('btn-install-snmp');
            if (data.snmpModule && data.snmpModule.installed) {
                snmpStatus.textContent = '✅';
                snmpBadge.textContent = `インストール済み (v${data.snmpModule.version})`;
                snmpBadge.style.background = 'rgba(16,185,129,0.2)';
                snmpBadge.style.color = '#34d399';
                snmpBadge.style.border = '1px solid rgba(16,185,129,0.3)';
                snmpDetail.textContent = `Path: ${data.snmpModule.path}`;
                if (btnInstallSnmp) btnInstallSnmp.style.display = 'none';
            } else {
                snmpStatus.textContent = '❌';
                snmpBadge.textContent = '未インストール';
                snmpBadge.style.background = 'rgba(239,68,68,0.2)';
                snmpBadge.style.color = '#f87171';
                snmpBadge.style.border = '1px solid rgba(239,68,68,0.3)';
                snmpDetail.textContent = 'PowerShell Gallery からの導入が必要です。';
                if (btnInstallSnmp) {
                    btnInstallSnmp.style.display = 'inline-block';
                    btnInstallSnmp.disabled = false;
                    btnInstallSnmp.textContent = '⚡ 今すぐインストール';
                }
            }

            // Iperf3
            const iperfStatus = document.getElementById('prereq-status-iperf');
            const iperfBadge = document.getElementById('prereq-badge-iperf');
            const iperfDetail = document.getElementById('prereq-detail-iperf');
            if (data.iperf3 && data.iperf3.available) {
                iperfStatus.textContent = '✅';
                iperfBadge.textContent = '利用可能';
                iperfBadge.style.background = 'rgba(16,185,129,0.2)';
                iperfBadge.style.color = '#34d399';
                iperfBadge.style.border = '1px solid rgba(16,185,129,0.3)';
                iperfDetail.textContent = `Path: ${data.iperf3.path}`;
            } else {
                iperfStatus.textContent = '⚠️';
                iperfBadge.textContent = '未配置';
                iperfBadge.style.background = 'rgba(245,158,11,0.2)';
                iperfBadge.style.color = '#fbbf24';
                iperfBadge.style.border = '1px solid rgba(245,158,11,0.3)';
                iperfDetail.textContent = 'tools\\iperf3.exe を配置すると帯域計測が有効化されます。';
            }

            // Pester
            const pesterStatus = document.getElementById('prereq-status-pester');
            const pesterBadge = document.getElementById('prereq-badge-pester');
            const pesterDetail = document.getElementById('prereq-detail-pester');
            const btnInstallPester = document.getElementById('btn-install-pester');
            if (data.pesterModule && data.pesterModule.installed) {
                pesterStatus.textContent = '✅';
                pesterBadge.textContent = `インストール済み (v${data.pesterModule.version})`;
                pesterBadge.style.background = 'rgba(16,185,129,0.2)';
                pesterBadge.style.color = '#34d399';
                pesterBadge.style.border = '1px solid rgba(16,185,129,0.3)';
                pesterDetail.textContent = '自動テストフレームワークが利用可能です。';
                if (btnInstallPester) btnInstallPester.style.display = 'none';
            } else {
                pesterStatus.textContent = '➖';
                pesterBadge.textContent = '未インストール (任意)';
                pesterBadge.style.background = 'rgba(255,255,255,0.1)';
                pesterBadge.style.color = 'var(--text-muted)';
                pesterBadge.style.border = '1px solid var(--glass-border)';
                pesterDetail.textContent = 'テスト実行時のみ必要（通常監視では不要）';
                if (btnInstallPester) {
                    btnInstallPester.style.display = 'inline-block';
                    btnInstallPester.disabled = false;
                    btnInstallPester.textContent = '⚡ インストール';
                }
            }

            // PowerShell Runtime
            const psStatus = document.getElementById('prereq-status-ps');
            const psBadge = document.getElementById('prereq-badge-ps');
            const psDetail = document.getElementById('prereq-detail-ps');
            if (data.isPsCompatible) {
                psStatus.textContent = '✅';
                psBadge.textContent = `適合 (PS v${data.psVersion})`;
                psBadge.style.background = 'rgba(16,185,129,0.2)';
                psBadge.style.color = '#34d399';
                psBadge.style.border = '1px solid rgba(16,185,129,0.3)';
                psDetail.textContent = `ExecutionPolicy: ${data.executionPolicy} | NuGet: ${data.hasNuGet ? '利用可能' : '未検出'}`;
            } else {
                psStatus.textContent = '❌';
                psBadge.textContent = `不適合 (PS v${data.psVersion})`;
                psBadge.style.background = 'rgba(239,68,68,0.2)';
                psBadge.style.color = '#f87171';
                psBadge.style.border = '1px solid rgba(239,68,68,0.3)';
                psDetail.textContent = 'PowerShell 5.1 以上が必要です。';
            }

        } catch (err) {
            bannerEl.style.background = 'rgba(239,68,68,0.15)';
            bannerEl.style.color = '#f87171';
            iconEl.textContent = '❌';
            textEl.textContent = `診断エラー: ${err.message}`;
        }
    }

    // インストール処理
    async function installModuleFromWeb(modName, btnEl) {
        if (!confirm(`PowerShell Gallery から「${modName}」モジュールをインストールしますか？\n（インターネット接続が必要です）`)) {
            return;
        }
        try {
            if (btnEl) {
                btnEl.disabled = true;
                btnEl.textContent = '⏳ インストール中...';
            }
            showToast('info', 'モジュール導入開始', `${modName} モジュールをダウンロード＆インストールしています...`, 4000);
            
            const res = await fetch('/api/system/install-module', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ module: modName })
            });
            const data = await res.json();
            if (res.ok && data.status === 'success') {
                showToast('success', 'インストール完了', `${modName} モジュールが正常に導入されました！`, 4000);
                await fetchPrerequisites();
            } else {
                showToast('error', 'インストール失敗', data.error || 'モジュールのインストールに失敗しました。');
                if (btnEl) {
                    btnEl.disabled = false;
                    btnEl.textContent = '⚡ 再試行';
                }
            }
        } catch (err) {
            showToast('error', 'エラー', err.message);
            if (btnEl) {
                btnEl.disabled = false;
                btnEl.textContent = '⚡ 再試行';
            }
        }
    }

    const btnRefreshPrereq = document.getElementById('btn-refresh-prereq');
    if (btnRefreshPrereq) {
        btnRefreshPrereq.addEventListener('click', () => {
            fetchPrerequisites();
            showToast('info', '再診断実行', '最新のモジュール・前提環境状態を取得しました。', 2000);
        });
    }

    const btnInstallSnmp = document.getElementById('btn-install-snmp');
    if (btnInstallSnmp) {
        btnInstallSnmp.addEventListener('click', () => installModuleFromWeb('SNMP', btnInstallSnmp));
    }

    const btnInstallPester = document.getElementById('btn-install-pester');
    if (btnInstallPester) {
        btnInstallPester.addEventListener('click', () => installModuleFromWeb('Pester', btnInstallPester));
    }

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
                latencyWarningMs:   parseInt(document.getElementById('modal-config-latency-warning')?.value) || 80,
                consecutiveFailThresh: parseInt(document.getElementById('modal-config-consecutive-fails')?.value) || 2,
                lossWarningThreshPercent: parseFloat(document.getElementById('modal-config-loss-warning')?.value) || 5.0,
                jitterWarningThreshMs: parseFloat(document.getElementById('modal-config-jitter-warning')?.value) || 20.0,
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

    // =========================================================================
    // Operation Guide & Glossary Modal Setup
    // =========================================================================
    const guideModal = document.getElementById('guide-modal');
    const btnOpenGuideModal = document.getElementById('btn-open-guide-modal');
    const openGuideBtnSidebar = document.getElementById('open-guide-btn-sidebar');
    const closeGuideModalBtn = document.getElementById('close-guide-modal-btn');
    const closeGuideModalFooterBtn = document.getElementById('close-guide-modal-footer-btn');

    function openGuideModal(defaultTab = 'guide-tab-basics') {
        if (!guideModal) return;
        guideModal.style.display = 'flex';
        switchGuideTab(defaultTab);
    }

    function closeGuideModal() {
        if (!guideModal) return;
        guideModal.style.display = 'none';
    }

    function switchGuideTab(targetTabId) {
        if (!guideModal) return;
        const tabBtns = guideModal.querySelectorAll('[data-guide-tab]');
        const tabContents = guideModal.querySelectorAll('.guide-tab-content');
        tabBtns.forEach(btn => {
            btn.classList.toggle('active', btn.dataset.guideTab === targetTabId);
        });
        tabContents.forEach(content => {
            content.style.display = (content.id === targetTabId) ? 'block' : 'none';
        });
    }

    if (btnOpenGuideModal) btnOpenGuideModal.addEventListener('click', () => openGuideModal());
    if (openGuideBtnSidebar) openGuideBtnSidebar.addEventListener('click', () => openGuideModal());
    if (closeGuideModalBtn) closeGuideModalBtn.addEventListener('click', closeGuideModal);
    if (closeGuideModalFooterBtn) closeGuideModalFooterBtn.addEventListener('click', closeGuideModal);
    if (guideModal) {
        guideModal.addEventListener('click', (e) => {
            if (e.target === guideModal) closeGuideModal();
        });
        guideModal.querySelectorAll('[data-guide-tab]').forEach(btn => {
            btn.addEventListener('click', () => {
                switchGuideTab(btn.dataset.guideTab);
            });
        });
    }

    // =========================================================================
    // Log Retention Presets & Manual Cleanup
    // =========================================================================
    const retentionPresets = document.querySelectorAll('.btn-retention-preset');
    const logRetentionInp = document.getElementById('modal-config-log-retention');
    if (retentionPresets.length > 0 && logRetentionInp) {
        retentionPresets.forEach(btn => {
            btn.addEventListener('click', () => {
                const days = btn.dataset.days;
                logRetentionInp.value = days;
                retentionPresets.forEach(b => b.classList.remove('active'));
                btn.classList.add('active');
            });
        });

        logRetentionInp.addEventListener('input', () => {
            const currentVal = logRetentionInp.value;
            retentionPresets.forEach(b => {
                b.classList.toggle('active', b.dataset.days === currentVal);
            });
        });
    }

    const btnManualCleanup = document.getElementById('btn-manual-cleanup-reports');
    const manualCleanupStatus = document.getElementById('manual-cleanup-status');
    if (btnManualCleanup) {
        btnManualCleanup.addEventListener('click', async () => {
            const days = parseInt(logRetentionInp ? logRetentionInp.value : 30) || 30;
            const confirmMsg = days > 0
                ? `${days} 日以上前の過去レポートフォルダを削除しますか？\n（現在実行中のセッションは保護されます）`
                : `保持日数が「無期限(0)」のため、安全のため30日以上前の過去ログを削除します。よろしいですか？`;
            if (!confirm(confirmMsg)) return;

            btnManualCleanup.disabled = true;
            btnManualCleanup.innerHTML = '<span>⏳</span> クリーンアップ実行中...';
            if (manualCleanupStatus) manualCleanupStatus.textContent = 'スキャン＆削除中...';

            try {
                const res = await fetch('/api/system/cleanup-reports', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ retentionDays: days })
                });
                const data = await res.json();
                if (res.ok && data.status === 'success') {
                    const msg = data.deletedCount > 0
                        ? `${data.deletedCount} 件の古いセッションを削除し、${data.freedMb} MB を解放しました。`
                        : `削除対象の古いレポートはありませんでした（ディスクは正常です）。`;
                    showToast('info', '🧹 クリーンアップ完了', msg, 5000);
                    if (manualCleanupStatus) manualCleanupStatus.textContent = `完了: ${msg}`;
                } else {
                    showToast('error', '❌ エラー', data.error || 'クリーンアップ処理に失敗しました。', 5000);
                    if (manualCleanupStatus) manualCleanupStatus.textContent = 'エラーが発生しました。';
                }
            } catch (err) {
                showToast('error', '❌ 通信エラー', 'サーバーとの通信に失敗しました。', 5000);
                if (manualCleanupStatus) manualCleanupStatus.textContent = '通信エラー';
            } finally {
                btnManualCleanup.disabled = false;
                btnManualCleanup.innerHTML = '<span>🧹</span> 今すぐ古いレポートをクリーンアップ';
            }
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

        // ※ 超高頻度モードは「対象機器を0.1秒・その他を5秒」で監視し続ける方式で、他の機器を一時停止しない。
        //   そのため以前ここで行っていた「全機器の監視ON/OFF状態の退避」と、通常モードへ戻すときの「復元」は削除した
        //   (復元が残っていたため、超高頻度モード中に⏸/▶で切り替えた監視状態が、通常モードに戻すと元に戻されていた)
        try { localStorage.removeItem('preUltraHighFreqEnabledState'); } catch (e) {}

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

                // Sync ultra-high-freq state immediately for dashboard Paused display
                updateUltraHighFreqState(payload.pollInterval, highFreqIps);

                // 超高頻度モードから戻るときは機器一覧を読み直して、カード表示 (対象機器のみ → 全機器) を作り直す
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
    let statusHistory = {}; // ヒートマップ用: 各サンプル時点のステータス (Success / Warning / Failed ...)

    // 遅延グラフの保持期間: 更新間隔にかかわらず約30秒分を保持する
    // (0.1秒更新でも15点=1.5秒で消えてしまわないように点数を間隔から算出)
    const HISTORY_WINDOW_MS = 30000;
    const HEATMAP_BAR_COUNT = 15;
    // 画面の更新間隔の下限: 0.1秒監視でもサーバーへの状態問い合わせは0.2秒ごとに抑え、
    // サーバー (1窓口で順番に処理) が問い合わせで埋まって止まるのを防ぐ
    // ※ Ping自体は0.1秒ごとに行われ、ロス率・瞬断の判定もサーバー側で0.1秒単位のまま
    const UI_MIN_REFRESH_MS = 200;
    function getHistoryLength() {
        const iv = Math.max(UI_MIN_REFRESH_MS, parseInt(systemConfig.pollInterval) || 1000);
        return Math.min(300, Math.max(15, Math.ceil(HISTORY_WINDOW_MS / iv)));
    }
    // 履歴配列を生成し、更新間隔の変更に合わせて長さを調整する (配列参照は維持)
    function ensureHistory(ip) {
        const len = getHistoryLength();
        if (!latencyHistory[ip]) {
            latencyHistory[ip] = Array(len).fill(null);
            timeHistory[ip] = Array(len).fill('');
            statusHistory[ip] = Array(len).fill(null);
            return;
        }
        if (!statusHistory[ip]) statusHistory[ip] = Array(latencyHistory[ip].length).fill(null);
        const lh = latencyHistory[ip], th = timeHistory[ip], sh = statusHistory[ip];
        while (lh.length > len) lh.shift();
        while (th.length > len) th.shift();
        while (sh.length > len) sh.shift();
        while (lh.length < len) lh.unshift(null);
        while (th.length < len) th.unshift('');
        while (sh.length < len) sh.unshift(null);
    }
    // 1回分の状態をグラフ用の履歴に追加する (古い値は押し出す)
    function pushLatencyHistory(ip, data) {
        ensureHistory(ip);
        // 警告 (遅延・揺らぎ) 中も応答があれば値を描画し、無応答のみ空白にする
        const hasLatency = (data.status === "Success" || data.status === "Warning") && data.latency !== null && data.latency !== undefined;
        latencyHistory[ip].push(hasLatency ? data.latency : null);
        latencyHistory[ip].shift();
        statusHistory[ip].push(data.status || null);
        statusHistory[ip].shift();
        const now = new Date();
        timeHistory[ip].push(`${now.getHours().toString().padStart(2,'0')}:${now.getMinutes().toString().padStart(2,'0')}:${now.getSeconds().toString().padStart(2,'0')}`);
        timeHistory[ip].shift();
    }
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
    let animationFxEnabled = (localStorage.getItem('ndm_topo_fx') !== 'false');
    let isTheaterMode = false;
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

        if (status === 'error') {
            if (statusEl) {
                statusEl.textContent = '失敗';
                statusEl.style.background = 'rgba(239, 68, 68, 0.2)';
                statusEl.style.color = '#f87171';
            }
            list.innerHTML = '<div style="color: var(--error); padding: 10px; text-align: center; font-size: 0.8rem;">経路を調べられませんでした</div>';
            return;
        }

        if (status === 'unreached' && statusEl) {
            statusEl.textContent = '未到達';
            statusEl.style.background = 'rgba(245, 158, 11, 0.2)';
            statusEl.style.color = '#f59e0b';
        }

        if (activeTraceHops.length === 0) {
            list.innerHTML = '<div style="color: var(--error); padding: 10px; text-align: center; font-size: 0.8rem;">ルートが見つかりませんでした</div>';
            return;
        }

        activeTraceHops.forEach((hop, index) => {
            const ip = typeof hop === 'string' ? hop : hop.ip;
            const latency = typeof hop === 'object' ? hop.latency : '';
            
            const dev = ip ? devices.find(d => d.ip === ip) : null;
            const name = dev ? (dev.name || ip) : (ip || '応答なし');
            const isLocal = ip === 'local';

            const safeIp = escapeHTML(ip || '* * *');
            const safeName = escapeHTML(isLocal ? 'このPC（監視サーバー）' : name);
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

    // 機器までの経路を調べて、一覧と構成図に表示する
    let traceRequestSeq = 0;
    async function startRouteTrace(targetIp) {
        const seq = ++traceRequestSeq;
        activeTraceHops = [];
        computeFullTracePath();
        renderTracePanel('loading');
        const titleEl = document.getElementById('topo-trace-target');
        if (titleEl) {
            const dev = devices.find(d => d.ip === targetIp);
            titleEl.textContent = dev ? `${dev.name || targetIp} (${targetIp})` : targetIp;
        }
        if (networkInstance) networkInstance.redraw();
        try {
            const res = await fetch(`/api/traceroute?target=${encodeURIComponent(targetIp)}`);
            const data = await res.json();
            if (seq !== traceRequestSeq) return;   // 途中で別の機器のトレースを始めたら、古い結果は使わない
            if (!res.ok) throw new Error(data.error || 'traceroute failed');
            activeTraceHops = [{ ip: 'local', latency: '' }, ...(Array.isArray(data.hops) ? data.hops : [])];
            computeFullTracePath();
            renderTracePanel(data.reached ? 'done' : 'unreached');
            focusOnTracePath();
            if (networkInstance) networkInstance.redraw();
        } catch (err) {
            if (seq !== traceRequestSeq) return;
            console.warn('Route trace failed:', err);
            activeTraceHops = [];
            renderTracePanel('error');
        }
    }

    function clearRouteTrace() {
        traceRequestSeq++;
        activeTraceHops = [];
        computeFullTracePath();
        const panel = document.getElementById('topo-trace-panel');
        if (panel) panel.style.display = 'none';
        if (networkInstance) networkInstance.redraw();
    }

    const traceCloseBtn = document.getElementById('topo-trace-close');
    if (traceCloseBtn) traceCloseBtn.addEventListener('click', clearRouteTrace);

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

        // ダッシュボード統合グラフも配色を切り替える (デイモードで目盛りが見えなくなるのを防止)
        if (dashboardUnifiedChart) {
            ['x', 'y'].forEach(axis => {
                const sc = dashboardUnifiedChart.options.scales[axis];
                if (!sc) return;
                if (sc.ticks) sc.ticks.color = tickColor;
                if (sc.grid) sc.grid.color = gridColor;
                if (sc.border) sc.border.color = borderColor;
            });
            const lg = dashboardUnifiedChart.options.plugins && dashboardUnifiedChart.options.plugins.legend;
            if (lg && lg.labels) lg.labels.color = legendColor;
            dashboardUnifiedChart.update('none');
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
        if (linkBtn) {
            linkBtn.classList.remove('link-active');
            linkBtn.textContent = '🔗 リンク追加';
        }
        const modeText = document.getElementById('topo-mode-text');
        if (modeText && !isUnlinkMode) {
            modeText.classList.add('hidden');
            modeText.style.display = 'none';
        }
    }

    function deactivateUnlinkMode() {
        isUnlinkMode = false;
        const unlinkBtn = document.getElementById('topo-unlink-btn');
        if (unlinkBtn) {
            unlinkBtn.classList.remove('unlink-active');
            unlinkBtn.textContent = '✖ リンク削除';
        }
        const modeText = document.getElementById('topo-mode-text');
        if (modeText && !isLinkMode) {
            modeText.classList.add('hidden');
            modeText.style.display = 'none';
        }
    }

    function deactivateAllModes() {
        deactivateLinkMode();
        deactivateUnlinkMode();
    }

    function startFlowAnimation() {
        if (flowAnimationId) return;
        const viewTopo = document.getElementById('view-topology');
        if (!viewTopo || !viewTopo.classList.contains('active') || document.hidden) {
            return;
        }
        let lastFrameTime = performance.now();
        const FRAME_INTERVAL_MS = 1000 / 30; // ~33.3ms for 30 FPS
        function animate(timestamp) {
            const currentViewTopo = document.getElementById('view-topology');
            if (!currentViewTopo || !currentViewTopo.classList.contains('active') || document.hidden) {
                flowAnimationId = null;
                return;
            }
            const now = timestamp || performance.now();
            const elapsed = now - lastFrameTime;
            if (networkInstance && animationFxEnabled) {
                if (elapsed >= FRAME_INTERVAL_MS) {
                    flowAnimationProgress = (flowAnimationProgress + 0.016) % 1.0;
                    networkInstance.redraw();
                    lastFrameTime = now - (elapsed % FRAME_INTERVAL_MS);
                }
            }
            flowAnimationId = requestAnimationFrame(animate);
        }
        flowAnimationId = requestAnimationFrame(animate);
    }

    function stopFlowAnimation() {
        if (flowAnimationId) {
            cancelAnimationFrame(flowAnimationId);
            flowAnimationId = null;
        }
    }

    function drawCometParticle(ctx, p1, p2, progress, color, isTraced) {
        const dx = p2.x - p1.x;
        const dy = p2.y - p1.y;
        const dist = Math.hypot(dx, dy);
        if (dist < 12) return;

        const ux = dx / dist;
        const uy = dy / dist;

        // Head position
        const hx = p1.x + dx * progress;
        const hy = p1.y + dy * progress;

        // 4 decaying tail segments
        const tailSegments = 4;
        const tailLength = Math.min(26, dist * 0.22);
        const stepDist = tailLength / tailSegments;

        ctx.save();
        for (let s = tailSegments; s >= 1; s--) {
            const segDist = s * stepDist;
            const sx = hx - ux * segDist;
            const sy = hy - uy * segDist;

            const dot = (sx - p1.x) * ux + (sy - p1.y) * uy;
            if (dot < 0 || dot > dist) continue;

            const alpha = (1 - s / (tailSegments + 1)) * 0.45;
            const r = (isTraced ? 5.5 : 4.0) * (1 - s * 0.16);

            ctx.beginPath();
            ctx.arc(sx, sy, Math.max(1, r), 0, 2 * Math.PI);
            ctx.fillStyle = color;
            ctx.globalAlpha = alpha;
            ctx.fill();
        }

        // Glowing head (optimized shadowBlur)
        ctx.globalAlpha = 1.0;
        ctx.beginPath();
        ctx.arc(hx, hy, isTraced ? 5.5 : 4.2, 0, 2 * Math.PI);
        ctx.fillStyle = '#ffffff';
        ctx.shadowColor = color;
        ctx.shadowBlur = isTraced ? 6 : 4;
        ctx.fill();
        ctx.shadowBlur = 0;

        ctx.beginPath();
        ctx.arc(hx, hy, isTraced ? 6.5 : 5.0, 0, 2 * Math.PI);
        ctx.strokeStyle = color;
        ctx.lineWidth = 1.5;
        ctx.stroke();

        ctx.restore();
    }

    function formatMbps(m) {
        if (!m || isNaN(m) || m <= 0) return '0M';
        if (m >= 100) return Math.round(m) + 'M';
        if (m >= 1) return m.toFixed(1) + 'M';
        if (m >= 0.01) return (m * 1000 >= 100 ? Math.round(m * 1000) + 'K' : (m * 1000).toFixed(0) + 'K');
        return '0M';
    }

    async function applyHierarchicalTreeLayout() {
        const activeDevices = devices.filter(d => d.enabled !== false);
        if (activeDevices.length === 0 || !networkInstance || !nodesDataSet) return;

        function getBaseTier(d) {
            const img = (d.image || '').toLowerCase();
            const name = (d.name || '').toLowerCase();
            const ip = d.ip || '';

            if (img === 'cloud' || ip === '8.8.8.8') return 0;
            if (img === 'router' || /router|gateway|ルーター|ゲートウェイ|ルータ|gw/i.test(name) || ip.endsWith('.1')) return 0;
            if (img === 'bridge' || /core|コア|l3|distrib/i.test(name)) return 1;
            if (img === 'ap' || img === 'switch' || /ap|switch|sw|hub/i.test(name)) return 2;
            if (img === 'camera' || img === 'decoder' || img === 'controller' || img === 'server' || img === 'pc') return 3;
            return 3;
        }

        const tierMap = {};
        activeDevices.forEach(d => {
            tierMap[d.ip] = getBaseTier(d);
        });

        // Refine tiers using connectedTo (parent -> child)
        for (let pass = 0; pass < 3; pass++) {
            activeDevices.forEach(d => {
                if (d.connectedTo) {
                    const parents = d.connectedTo.split(',').map(p => p.trim()).filter(p => p);
                    parents.forEach(parentIp => {
                        if (tierMap[parentIp] !== undefined) {
                            const minChildTier = Math.min(4, tierMap[parentIp] + 1);
                            if (tierMap[d.ip] < minChildTier) {
                                tierMap[d.ip] = minChildTier;
                            }
                        }
                    });
                }
            });
        }

        const tiers = { 0: [], 1: [], 2: [], 3: [], 4: [] };
        activeDevices.forEach(d => {
            const t = tierMap[d.ip] || 0;
            tiers[t].push(d);
        });

        const tierY = {
            0: -340,
            1: -120,
            2: 120,
            3: 360,
            4: 560
        };

        const payload = [];

        Object.keys(tiers).forEach(tStr => {
            const t = parseInt(tStr, 10);
            const list = tiers[t];
            if (list.length === 0) return;

            list.sort((a, b) => {
                const ga = a.group || '';
                const gb = b.group || '';
                if (ga !== gb) return ga.localeCompare(gb);
                return (a.name || a.ip).localeCompare(b.name || b.ip);
            });

            const count = list.length;
            const spacingX = Math.max(160, Math.min(260, 1400 / Math.max(count, 1)));

            list.forEach((d, idx) => {
                const x = (idx - (count - 1) / 2) * spacingX;
                const y = tierY[t] || (t * 200);
                d.x = x;
                d.y = y;
                payload.push({ ip: d.ip, x, y });
            });
        });

        nodesDataSet.update(payload.map(p => ({ id: p.ip, x: p.x, y: p.y, physics: false })));

        try {
            await fetch('/api/devices/positions', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            });
        } catch (e) {
            console.error('Failed to save layout positions:', e);
        }

        networkInstance.fit({ animation: { duration: 600, easingFunction: 'easeInOutQuad' } });
    }

    function toggleTheaterMode() {
        const topoLayout = document.querySelector('.topology-layout');
        const fsBtn = document.getElementById('topo-fullscreen-btn');
        if (!topoLayout) return;

        isTheaterMode = !isTheaterMode;
        if (isTheaterMode) {
            topoLayout.classList.add('theater-mode');
            if (fsBtn) {
                fsBtn.textContent = '🖥️ 通常表示';
                fsBtn.classList.add('topo-btn-theater-active');
            }
        } else {
            topoLayout.classList.remove('theater-mode');
            if (fsBtn) {
                fsBtn.textContent = '🖥️ シアターモード';
                fsBtn.classList.remove('topo-btn-theater-active');
            }
        }

        setTimeout(() => {
            if (networkInstance) {
                networkInstance.redraw();
                networkInstance.fit();
            }
        }, 150);
    }

    function toggleAnimationFx() {
        animationFxEnabled = !animationFxEnabled;
        localStorage.setItem('ndm_topo_fx', animationFxEnabled ? 'true' : 'false');
        updateFxButtonState();
        if (animationFxEnabled) {
            startFlowAnimation();
        }
        if (networkInstance) {
            networkInstance.redraw();
        }
    }

    function updateFxButtonState() {
        const fxBtn = document.getElementById('topo-fx-toggle-btn');
        if (!fxBtn) return;
        if (animationFxEnabled) {
            fxBtn.textContent = '⚡ FX: ON';
            fxBtn.classList.add('topo-btn-fx-on');
            fxBtn.classList.remove('topo-btn-fx-off');
            fxBtn.title = 'アニメーションFX 有効 (彗星粒子・レーダー波紋 ON)';
        } else {
            fxBtn.textContent = '⚡ FX: OFF';
            fxBtn.classList.remove('topo-btn-fx-on');
            fxBtn.classList.add('topo-btn-fx-off');
            fxBtn.title = 'アニメーションFX 無効 (静止描画モード)';
        }
    }

    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && isTheaterMode) {
            toggleTheaterMode();
        }
    });

    function isTraceEdge(fromIp, toIp) {
        return traceHighlightedEdges.has(`edge-${fromIp}-${toIp}`) || 
               traceHighlightedEdges.has(`edge-${toIp}-${fromIp}`);
    }

    function computeFullTracePath() {
        traceHighlightedNodes.clear();
        traceHighlightedEdges.clear();

        if (activeTraceHops.length < 2) return;

        // ホップの一覧から IP だけを取り出す (応答がなかった区間は IP なし)
        const hopIps = activeTraceHops.map(hop => (typeof hop === 'string' ? hop : hop.ip)).filter(Boolean);
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

        const localHops = hopIps.filter(hopIp => deviceIpMap.has(hopIp));
        // 構成図にある機器は、線でつながっていなくても光らせる
        localHops.forEach(hopIp => traceHighlightedNodes.add(hopIp));

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
    let resizeDebounceTimer = null;
    window.addEventListener('resize', () => {
        clearTimeout(resizeDebounceTimer);
        resizeDebounceTimer = setTimeout(() => {
            if (typeof topologyNetwork !== 'undefined' && topologyNetwork) {
                topologyNetwork.fit();
            }
            if (typeof networkInstance !== 'undefined' && networkInstance) {
                networkInstance.fit();
            }
            if (dashboardUnifiedChart) {
                dashboardUnifiedChart.resize();
            }
            if (typeof topologyLatencyChart !== 'undefined' && topologyLatencyChart) {
                topologyLatencyChart.resize();
            }
        }, 150);
    });

    // Initialize
    updateMuteButtonUI();
    updateSortFailuresButtonUI();
    fetchDevices();
    fetchConfig().then(() => {
        const currentInterval = configPollIntervalInput ? parseInt(configPollIntervalInput.value) : 1000;
        startStatusLoop(currentInterval);
    });

    let consecutiveFetchErrors = 0;
    let isOfflineBannerShown = false;
    let statusAbortController = null;
    let configuredPollInterval = 1000;
    let statusInterval = null;

    function startStatusLoop(pollIntervalMs) {
        if (pollIntervalMs) {
            configuredPollInterval = pollIntervalMs;
        }
        if (statusInterval) clearInterval(statusInterval);
        // Synchronize UI refresh exactly with the monitoring interval.
        // For very high frequency (0.1s), the UI refresh is floored at UI_MIN_REFRESH_MS (200ms).
        // If offline banner is currently displayed, throttle to 3500ms backoff.
        const uiInterval = isOfflineBannerShown ? 3500 : Math.max(UI_MIN_REFRESH_MS, configuredPollInterval || 1000);
        statusInterval = setInterval(fetchStatus, uiInterval);
    }

    function throttleStatusLoop(throttledIntervalMs = 3500) {
        if (statusInterval) clearInterval(statusInterval);
        statusInterval = setInterval(fetchStatus, throttledIntervalMs);
    }

    function restoreStatusLoop() {
        if (statusInterval) clearInterval(statusInterval);
        const uiInterval = Math.max(UI_MIN_REFRESH_MS, configuredPollInterval || 1000);
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
    
    const devCheckTypeGlobal = document.getElementById('dev-check-type');
    const devPortGroupGlobal = document.getElementById('dev-tcp-port-group');
    if (devCheckTypeGlobal && devPortGroupGlobal) {
        devCheckTypeGlobal.addEventListener('change', () => {
            devPortGroupGlobal.classList.toggle('hidden', devCheckTypeGlobal.value !== 'tcp');
        });
    }

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

        // Remote Management Configuration Serialization (Milestone 2)
        const remoteConfig = {
            enabled: !!(devRemoteEnabled && devRemoteEnabled.checked),
            protocol: devRemoteProtocol ? devRemoteProtocol.value : 'ssh',
            host: devRemoteHost ? devRemoteHost.value.trim() : '',
            port: devRemotePort ? (parseInt(devRemotePort.value, 10) || (devRemoteProtocol && devRemoteProtocol.value === 'winrm' ? 5985 : 22)) : 22,
            authType: devRemoteAuthType ? devRemoteAuthType.value : 'password',
            user: devRemoteUser ? devRemoteUser.value.trim() : '',
            keyPath: devRemoteKeyPath ? devRemoteKeyPath.value.trim() : '',
            rebootCommand: devRemoteRebootCmd ? devRemoteRebootCmd.value.trim() : '',
            commands: currentFormRemoteCommands || []
        };
        const passVal = devRemotePass ? devRemotePass.value : '';
        if (passVal) {
            remoteConfig.password = passVal;
        } else if (editOldIpInput && editOldIpInput.value) {
            const existingDev = devices.find(x => x.ip === editOldIpInput.value);
            if (existingDev && existingDev.remote && existingDev.remote.password) {
                remoteConfig.password = existingDev.remote.password;
            }
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
                checkType: document.getElementById('dev-check-type') ? document.getElementById('dev-check-type').value : "icmp",
                port: document.getElementById('dev-port') ? parseInt(document.getElementById('dev-port').value, 10) || 0 : 0,
                community: devCommInput.value.trim(),
                enabled: devEnabledInput.checked,
                image: imageVal,
                connectedTo: connectedToVal,
                remote: remoteConfig,
                ...readSnmpFields()
            };
            
            try {
                const res = await fetch('/api/device/edit', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(payload)
                });
                if (res.ok) {
                    deviceForm.reset();
                    openDeviceModal(null);
                    await fetchDevices();
                    renderManageList();
                } else if (res.status === 409) {
                    alert(`IPアドレス ${payload.newIp} は別の機器で既に使われています。別のIPアドレスを指定してください。`);
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
            checkType: document.getElementById('dev-check-type') ? document.getElementById('dev-check-type').value : "icmp",
            port: document.getElementById('dev-port') ? parseInt(document.getElementById('dev-port').value, 10) || 0 : 0,
            community: devCommInput.value.trim(),
            enabled: devEnabledInput.checked,
            image: imageVal,
            connectedTo: connectedToVal,
            remote: remoteConfig,
            ...readSnmpFields()
        }];
        
        try {
            const res = await fetch('/api/devices/bulk', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payloads)
            });
            if (res.ok) {
                deviceForm.reset();
                openDeviceModal(null);
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
                    openDeviceModal(d);
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

    let isFetchingStatus = false;
    let dismissedConflicts = new Set();

    function updateIpConflicts(conflicts) {
        const banner = document.getElementById('ip-conflict-banner');
        const detailsEl = document.getElementById('ip-conflict-details');
        if (!banner || !detailsEl) return;

        // サーバーからは配列で届く想定だが、0件や1件のときに {} や単体の値で届いても動くようにそろえる
        if (conflicts && !Array.isArray(conflicts)) {
            conflicts = conflicts.ip ? [conflicts] : Object.values(conflicts);
        }

        if (!conflicts || conflicts.length === 0) {
            banner.style.display = 'none';
            dismissedConflicts.clear();
            return;
        }

        const activeConflicts = conflicts.filter(c => !dismissedConflicts.has(c.ip));
        if (activeConflicts.length === 0) {
            banner.style.display = 'none';
            return;
        }

        banner.style.display = 'block';
        detailsEl.innerHTML = activeConflicts.map(c => `
            <div style="margin-top:2px;">
                <strong>${escapeHTML(c.deviceName || c.ip)} (${escapeHTML(c.ip)})</strong>: 
                <span style="color:#fca5a5;">${escapeHTML(c.reason || '競合')}</span>
                <span style="color:var(--text-muted); font-size:0.75rem; margin-left:6px;">[検知: ${escapeHTML(c.detectedAt || '')}]</span>
            </div>
        `).join('');

        const dismissBtn = document.getElementById('btn-dismiss-conflict');
        if (dismissBtn && !dismissBtn._hasListener) {
            dismissBtn._hasListener = true;
            dismissBtn.addEventListener('click', () => {
                activeConflicts.forEach(c => dismissedConflicts.add(c.ip));
                banner.style.display = 'none';
            });
        }
    }

    async function fetchStatus() {
        if (devices.length === 0) return;
        if (isFetchingStatus) return; // prevent parallel requests when server is slow
        isFetchingStatus = true;

        if (statusAbortController) {
            try { statusAbortController.abort(); } catch (e) {}
        }
        statusAbortController = new AbortController();
        const currentController = statusAbortController;
        const timeoutId = setTimeout(() => {
            try { currentController.abort(); } catch (e) {}
        }, 4000);

        try {
            const res = await fetch('/api/status', { signal: currentController.signal });
            clearTimeout(timeoutId);
            if (!res.ok) {
                throw new Error(`HTTP ${res.status} ${res.statusText}`);
            }
            const statusData = await res.json();

            // Reconnection recovery handling
            if (isOfflineBannerShown || consecutiveFetchErrors >= 3) {
                const banner = document.getElementById('network-offline-banner');
                if (banner) {
                    banner.style.display = 'none';
                }
                document.body.classList.remove('backend-offline');
                isOfflineBannerShown = false;
                restoreStatusLoop();
                showToast('success', '再接続完了', '✅ サーバーとの再接続が完了しました', 4000);
            }
            consecutiveFetchErrors = 0;

            // 画面描画中の例外はサーバー切断ではないため、通信エラーとして数えない
            // (数えると3回で「サーバーとの接続が途切れています」と誤表示され、更新も3.5秒間隔に落ちる)
            try {
                updateDeviceData(statusData);
                updateTopologyStatus();
                updateIpConflicts(statusData._ipConflicts);
            } catch (renderErr) {
                console.error('Error rendering status:', renderErr);
            }
        } catch (err) {
            clearTimeout(timeoutId);
            console.warn('Error fetching status:', err);
            consecutiveFetchErrors++;
            if (consecutiveFetchErrors >= 3 && !isOfflineBannerShown) {
                isOfflineBannerShown = true;
                throttleStatusLoop(3500);
                document.body.classList.add('backend-offline');
                const banner = document.getElementById('network-offline-banner');
                if (banner) {
                    banner.style.display = 'flex';
                }
            }
        } finally {
            if (statusAbortController === currentController) {
                statusAbortController = null;
            }
            isFetchingStatus = false;
        }
    }

    const bannerReconnectBtn = document.getElementById('btn-banner-reconnect');
    if (bannerReconnectBtn) {
        bannerReconnectBtn.addEventListener('click', () => {
            if (statusAbortController) {
                try { statusAbortController.abort(); } catch (e) {}
                statusAbortController = null;
            }
            isFetchingStatus = false;
            fetchStatus();
        });
    }

    function renderDeviceGrid() {
        const deviceList = document.getElementById('device-list');
        if (!deviceList) return;
        deviceList.innerHTML = '';
        const CHART_LINE_COLORS = ['#3b82f6','#10b981','#f59e0b','#ec4899','#8b5cf6','#06b6d4','#f43f5e','#14b8a6'];
        Object.values(charts).forEach(c => { if (c) c.destroy(); });
        charts = {};
        if (dashboardUnifiedChart) {
            try { dashboardUnifiedChart.destroy(); } catch (e) {}
            dashboardUnifiedChart = null;
        }
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
        // グラフに描く機器: 超高頻度モードでも、5.0s間隔で監視を続けている機器を含めて表示する
        // (0.1s対象機器を先頭にして、カードの色とグラフの線の色をそろえる)
        const chartGlobal = monitoredGlobal.concat(devices.filter(d => d.enabled !== false && !monitoredGlobal.includes(d)));
        const chartColorOf = (d) => CHART_LINE_COLORS[Math.max(0, chartGlobal.indexOf(d)) % CHART_LINE_COLORS.length] || '#3b82f6';
        for (const groupName of groupNames) {
            let groupDevices = groups[groupName].slice().sort((a, b) => (a.enabled !== false ? 0 : 1) - (b.enabled !== false ? 0 : 1));
            if (activeTab === 'all') {
                groupDevices = groupDevices.filter(d => monitoredGlobal.includes(d));
            }
            if (groupDevices.length === 0) continue;

            const section = document.createElement('div');
            section.className = 'group-section';
            section.style.display = (activeTab === 'all' || groupName === activeTab) ? 'flex' : 'none';
            section.innerHTML = `<div class="group-header" style="font-size:1.1rem; font-weight:700; color:var(--text-main); border-bottom:2px solid var(--glass-border); padding-bottom:5px; margin-bottom:10px;"><span>${escapeHTML(groupName)}</span></div>`;
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
                const color = !isPausedState ? chartColorOf(d) : 'transparent';
                const displayName = escapeHTML(d.name || ip);
                const rateBadge = ultraHighFreqActive ? (isUltraTarget ? '<span style="font-size:0.65rem; padding:1px 5px; border-radius:4px; background:rgba(251,191,36,0.2); color:#fbbf24; font-weight:700; margin-left:4px;">0.1s</span>' : '<span style="font-size:0.65rem; padding:1px 5px; border-radius:4px; background:rgba(148,163,184,0.15); color:#94a3b8; margin-left:4px;">5.0s</span>') : '';
                const checkBadge = (d.checkType === 'tcp' && d.port > 0) ? `<span style="font-size:0.65rem; padding:1px 5px; border-radius:4px; background:rgba(99,102,241,0.2); color:#818cf8; font-weight:700; margin-left:4px;" title="TCPポート ${d.port} 死活監視">TCP:${d.port}</span>` : '';
                const conflictBadge = `<span id="conflict-badge-${safeIpId}" style="display:none; font-size:0.65rem; padding:1px 6px; border-radius:4px; background:rgba(239,68,68,0.25); color:#f87171; border:1px solid rgba(239,68,68,0.4); font-weight:700; margin-left:4px;" title="IPアドレス競合を検知中">🚨 IP競合</span>`;
                
                row.innerHTML = `
                    ${!isPausedState ? `<div style="position:absolute;left:0;top:0;bottom:0;width:4px;background:${color};border-radius:8px 0 0 8px;"></div>` : ''}
                    <div style="display:flex;align-items:center;gap:8px;flex:2.2;min-width:0;">
                        <div class="status-dot" id="dot-${safeIpId}"></div>
                        <div style="display:flex;flex-direction:column;overflow:hidden;">
                            <div style="display:flex;align-items:center;">
                                <span style="font-weight:600; font-size:0.88rem; white-space:nowrap; overflow:hidden; text-overflow:ellipsis;" title="${displayName}">${displayName}</span>
                                ${rateBadge}
                                ${checkBadge}
                                ${conflictBadge}
                            </div>
                            <span style="font-size:0.72rem;color:var(--text-muted);">${escapeHTML(ip)}<span id="mac-${safeIpId}" style="font-family:monospace;">${d.mac ? ` / MAC: ${escapeHTML(d.mac)}` : ''}</span></span>
                        </div>
                    </div>
                    <div style="flex:1.1; min-width:0; display:flex; flex-direction:column; gap:1px;">
                        <span id="traffic-tx-${safeIpId}" style="font-size:0.71rem; color:#60a5fa; white-space:nowrap;" title="SNMP 送信トラフィック速度 (Tx Mbps)">↑ TX: -</span>
                        <span id="traffic-rx-${safeIpId}" style="font-size:0.71rem; color:#34d399; white-space:nowrap;" title="SNMP 受信トラフィック速度 (Rx Mbps)">↓ RX: -</span>
                    </div>
                    <div style="flex:1.1; min-width:0; display:flex; flex-direction:column; gap:1px;">
                        <span id="loss-${safeIpId}" style="font-size:0.71rem; color:#94a3b8; white-space:nowrap;" title="パケット損失率: 直近30回のPing送信に対する失敗割合 (%)">ロス: 0.0%</span>
                        <span id="jitter-${safeIpId}" style="font-size:0.71rem; color:#94a3b8; white-space:nowrap;" title="ジッター (ms): 応答時間のブレ・揺らぎ (RFC 3550)。5ms未満が理想">揺らぎ: -</span>
                    </div>
                    <div style="display:flex;flex-direction:column;align-items:flex-end;gap:2px;flex-shrink:0;min-width:110px;">
                        <span class="header-latency" id="latency-${safeIpId}" style="min-width:50px;text-align:right;font-weight:700;" title="現在のPing応答遅延時間 (ms)">-</span>
                        <span id="minmax-${safeIpId}" style="font-size:0.7rem;white-space:nowrap;" title="セッション中の最大応答遅延 / 最小応答遅延 (ms)"><span style="color:#f97316;">最大-</span> / <span style="color:#06b6d4;">最小-</span></span>
                        <span id="outage-${safeIpId}" style="font-size:0.68rem;white-space:nowrap;color:#94a3b8;" title="最大瞬断時間: 連続してPingが途絶えた最長ミリ秒数 (ms)">瞬断最大: -</span>
                    </div>
                    <div style="display:flex;align-items:center;gap:6px;flex-shrink:0;">
                        <button class="device-detail-btn" data-ip="${ip}" title="ポート通信量・MTR経路・24h履歴の詳細診断を開きます">🔍 詳細</button>
                        <button class="toggle-monitor-btn" data-ip="${ip}" style="background:transparent;border:none;color:${!isPausedState ? '#f59e0b' : '#10b981'};cursor:pointer;font-size:1.1rem;" title="${!isPausedState ? '監視を一時停止' : '監視を再開'}">${!isPausedState ? '⏸' : '▶'}</button>
                    </div>`;
                grid.appendChild(row);
                ensureHistory(ip);
                if (!latencyStats[ip]) { latencyStats[ip] = { min: null, max: null }; }
                
                // Hover focus highlight on unified chart
                row.addEventListener('mouseenter', () => highlightChartDevice(ip));
                row.addEventListener('mouseleave', () => resetChartHighlight());

                const detailBtn = row.querySelector('.device-detail-btn');
                if (detailBtn) {
                    detailBtn.addEventListener('click', (e) => {
                        e.stopPropagation();
                        openSnmpDetailsModal(d);
                    });
                }

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

        applyFailureSort();

        // グラフ描画: 'all' なら全監視デバイス、個別グループ選択中ならそのグループのデバイスを表示
        let chartDevices = (activeTab === 'all')
            ? chartGlobal
            : chartGlobal.filter(d => ((d.group && d.group.trim()) ? d.group.trim() : 'Ungrouped') === activeTab);
        
        // グループ内に有効な監視デバイスがない場合のフォールバック（グループ内の全機器または全監視機器）
        if (chartDevices.length === 0) {
            if (activeTab !== 'all') {
                const inGroup = devices.filter(d => ((d.group && d.group.trim()) ? d.group.trim() : 'Ungrouped') === activeTab);
                chartDevices = inGroup.length > 0 ? inGroup : monitoredGlobal;
            } else {
                chartDevices = devices;
            }
        }

        const unifiedChartContainer = document.getElementById('dashboard-unified-chart-container');
        if (unifiedChartContainer) {
            unifiedChartContainer.innerHTML = '';
            if (chartDevices.length > 0) {
                const chartTitle = (activeTab === 'all') ? '全デバイス の遅延推移 (ms)' : `グループ [${activeTab}] の遅延推移 (ms)`;
                const unifiedChartDiv = document.createElement('div');
                unifiedChartDiv.className = 'dashboard-unified-chart';
                unifiedChartDiv.innerHTML = `<div style="font-size:0.75rem;color:var(--text-muted);font-weight:600;margin-bottom:10px;">${escapeHTML(chartTitle)}</div><div style="flex:1;position:relative;width:100%;height:calc(100% - 25px);"><canvas id="dashboard-unified-canvas"></canvas></div>`;
                unifiedChartContainer.appendChild(unifiedChartDiv);
                // 超高頻度モードで5.0s間隔の機器は、点線と「(5.0s)」の表記で0.1s対象と見分けられるようにする
                const isSlowRate = (d) => ultraHighFreqActive && ultraHighFreqTargetSet.size > 0 && !ultraHighFreqTargetSet.has(d.ip);
                const datasets = chartDevices.map(d => ({
                    label: (d.name || d.ip) + (isSlowRate(d) ? ' (5.0s)' : ''),
                    deviceIp: d.ip,
                    data: (latencyHistory[d.ip] && latencyHistory[d.ip].length > 0) ? latencyHistory[d.ip].slice() : Array(getHistoryLength()).fill(null),
                    borderColor: chartColorOf(d),
                    originalColor: chartColorOf(d),
                    borderDash: isSlowRate(d) ? [6, 4] : [],
                    backgroundColor: 'transparent', 
                    borderWidth: 2, 
                    pointRadius: getHistoryLength() > 30 ? 0 : 2, 
                    fill: false, 
                    spanGaps: false,
                    tension: getHistoryLength() > 30 ? 0.2 : 0.4 
                }));
                const labelIp = (chartDevices[0] && chartDevices[0].ip && timeHistory[chartDevices[0].ip]) ? chartDevices[0].ip : (monitoredGlobal[0] ? monitoredGlobal[0].ip : null);
                const chartLabels = (labelIp && timeHistory[labelIp]) ? timeHistory[labelIp] : Array(getHistoryLength()).fill('');
                const isDayTheme = (document.documentElement.getAttribute('data-theme') === 'day');
                const uTick = isDayTheme ? '#1e293b' : 'rgba(200,210,230,0.9)';
                const uGrid = isDayTheme ? 'rgba(15, 23, 42, 0.25)' : 'rgba(200,210,230,0.25)';
                const uBorder = isDayTheme ? 'rgba(15, 23, 42, 0.6)' : 'rgba(200,210,230,0.6)';
                const uLegend = isDayTheme ? '#0f172a' : 'rgba(200,210,230,0.9)';
                dashboardUnifiedChart = new Chart(unifiedChartDiv.querySelector('canvas').getContext('2d'), {
                    type: 'line', data: { labels: chartLabels, datasets },
                    options: { responsive: true, maintainAspectRatio: false, animation: { duration: 0 },
                        scales: {
                            x: {
                                ticks: { maxTicksLimit: 10, font: { size: 10 }, color: uTick },
                                grid: { color: uGrid, lineWidth: 1 },
                                border: { color: uBorder, width: 1 }
                            },
                            y: {
                                min: 0, grace: '15%',
                                ticks: { font: { size: 10 }, color: uTick },
                                grid: { color: uGrid, lineWidth: 1 },
                                border: { color: uBorder, width: 1 }
                            }
                        },
                        plugins: { 
                            legend: { 
                                display: true, 
                                position: 'bottom', 
                                labels: { font: { size: 9 }, color: uLegend, usePointStyle: true, boxWidth: 15 },
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
        dashboardUnifiedChart.update('none');
    }

    function resetChartHighlight() {
        if (!dashboardUnifiedChart) return;
        dashboardUnifiedChart.data.datasets.forEach(ds => {
            ds.borderColor = ds.originalColor || ds.borderColor;
            ds.borderWidth = 2;
        });
        dashboardUnifiedChart.update('none');
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

        // Prune stale device elements that are no longer active
        const activeSafeIds = new Set(monitoredDevices.map(d => `heatmap-item-${d.ip.replace(/\./g, '-')}`));
        Array.from(container.children).forEach(child => {
            if (!child.id || !child.id.startsWith('heatmap-item-')) {
                child.remove();
            } else if (!activeSafeIds.has(child.id)) {
                child.remove();
            }
        });

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
                const history = latencyHistory[ip].slice(-HEATMAP_BAR_COUNT);
                const stHist = (statusHistory[ip] || []).slice(-HEATMAP_BAR_COUNT);
                const barsHtml = history.map((lat, idx) => {
                    let bg = '#64748b'; // paused / null
                    let title = '停止 / データなし';
                    if (lat !== null) {
                        // 遅延は閾値未満でも、揺らぎ・ロス率で「警告」判定された時点は黄色で表示する
                        if (lat >= warnLat || stHist[idx] === 'Warning') {
                            bg = '#f59e0b';
                            title = (lat >= warnLat) ? `高遅延: ${lat}ms` : `警告 (揺らぎ/ロス): ${lat}ms`;
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

    // 機器の状態に応じて画面の通知 (トースト) と警告音を出す
    // (カードを表示していない機器 = 超高頻度モードの5.0s間隔の機器 にも通知が出るよう、カード更新とは分けている)
    // ※ 状態データ (data) には機器名が含まれないため、名前は機器一覧 (d.name) から取る (以前は常にIPが表示されていた)
    function raiseDeviceAlerts(d, data) {
        const ip = d.ip;
        const label = d.name || ip;
        const isSuppressed = isAlertSuppressed(ip) || data.isSuppressed;
        if (isSuppressed) return;
        if ((data.status === "Failed" || data.status === "Error") && canAlert(ip, 'offline')) {
            showToast('error', `🔴 ${label} オフライン`, `IP: ${ip} 応答なし`, 5000);
            playAlertSound('error');
        } else if (data.status === "Warning" && canAlert(ip, 'warning')) {
            showToast('warning', `⚠️ ${label} 警告状態 (遅延/瞬断)`, `IP: ${ip} 遅延: ${data.latency != null ? data.latency + 'ms' : '単発断'}`, 4000);
            playAlertSound('warning');
        }
        const warnLat = parseFloat(threshLatencyEl.value) || 100;
        if ((data.status === "Success" || data.status === "Warning") && data.latency !== null && data.latency >= warnLat && canAlert(ip, 'latency')) {
            showToast('warning', `⚠️ ${label} 高遅延検知`, `IP: ${ip} 遅延: ${data.latency}ms (閾値: ${warnLat}ms)`, 5000);
            playAlertSound('warning');
        }
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
            if (!dotEl || !latencyEl) {
                // 画面にカードがない機器 (超高頻度モードで5.0s間隔の機器など) も、グラフ用の履歴だけは記録する
                if (data && d.enabled !== false) {
                    pushLatencyHistory(ip, data);
                    raiseDeviceAlerts(d, data);
                }
                return;
            }

            if (data) {
                const isSuppressed = isAlertSuppressed(ip) || data.isSuppressed;
                const statusClass = (data.status === "Success" || data.status === "Online") 
                    ? 'success' 
                    : (data.status === "Warning")
                        ? 'warning'
                        : (data.status === "Failed" || data.status === "Error" || data.status === "Offline") 
                            ? (isSuppressed ? 'unreachable' : 'error') 
                            : 'paused';
                dotEl.className = 'status-dot ' + statusClass;

                raiseDeviceAlerts(d, data);

                const warnLat = parseFloat(threshLatencyEl.value) || 100;
                if ((data.status === "Success" || data.status === "Warning") && data.latency !== null) {
                    latencyEl.textContent = `${data.latency} ms`;
                    latencyEl.className = 'header-latency' + (data.status === "Warning" || data.latency >= warnLat ? ' bad' : '');
                    // Update per-session min/max
                    if (!latencyStats[ip]) latencyStats[ip] = { min: null, max: null };
                    if (latencyStats[ip].min === null || data.latency < latencyStats[ip].min) latencyStats[ip].min = data.latency;
                    if (latencyStats[ip].max === null || data.latency > latencyStats[ip].max) latencyStats[ip].max = data.latency;
                } else {
                    if (data.status === "Paused") {
                        latencyEl.textContent = '-- ms';
                        latencyEl.className = 'header-latency paused-text';
                    } else if (data.status === "Failed" || data.status === "Error" || data.status === "Offline") {
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
                    const jit = (data.avgJitter != null && data.avgJitter > 0) ? data.avgJitter : null;
                    jitterEl.textContent = `揺らぎ: ${jit !== null ? jit.toFixed(1) + 'ms' : '-'}`;
                    jitterEl.title = jit !== null ? `平均ジッター: ${jit.toFixed(2)}ms` : '';
                    jitterEl.style.color = (jit !== null && jit > 20) ? '#fbbf24' : 'var(--text-muted)';
                }

                // Update max outage display
                const outageEl = document.getElementById(`outage-${safeIpId}`);
                if (outageEl) {
                    const maxSec   = (data.maxOutageSec     != null && data.maxOutageSec > 0)     ? data.maxOutageSec     : null;
                    const curSec   = (data.currentOutageSec != null && data.currentOutageSec > 0) ? data.currentOutageSec : 0;
                    const cnt600   = (data.outage600msCount != null) ? data.outage600msCount : 0;
                    const cnt5s    = (data.outage5sCount    != null) ? data.outage5sCount    : 0;
                    const fmtOutageMs = s => {
                        if (s == null || s <= 0) return '-';
                        const ms = Math.round(s * 1000);
                        return `${ms}ms`;
                    };
                    
                    // Build threshold labels from current config
                    const t1ms = (systemConfig.outageThresh1Ms) || 600;
                    const t2ms = (systemConfig.outageThresh2Ms) || 5000;
                    const fmtMs = ms => `${ms}ms`;
                    const cntParts = [];
                    if (cnt600 > 0) cntParts.push(`${fmtMs(t1ms)}以上: ${cnt600}回`);
                    if (cnt5s  > 0) cntParts.push(`${fmtMs(t2ms)}以上: ${cnt5s}回`);
                    const cntStr = cntParts.length > 0 ? cntParts.join(' / ') : '';

                    const isOffline = (data.status === 'Failed' || data.status === 'Error') && curSec > 0;
                    const evs = data.outageEvents || [];
                    let lastEvStr = '';
                    if (evs.length > 0) {
                        const lastEv = evs[evs.length - 1];
                        const sTime = (lastEv.StartTime || '').substring(11);
                        const eTime = (lastEv.EndTime || '').substring(11);
                        lastEvStr = `直近瞬断: ${sTime}～${eTime} (${lastEv.DurationMs}ms)`;
                    }

                    if (isOffline) {
                        outageEl.style.color = '#ef4444';
                        outageEl.textContent = `瞬断中: ${fmtOutageMs(curSec)}`;
                        let tooltip = `現在オフライン継続中: ${fmtOutageMs(curSec)}${curSec >= 1 ? ` (${curSec.toFixed(1)}秒)` : ''}`;
                        if (maxSec !== null) tooltip += ` / 過去最大瞬断: ${fmtOutageMs(maxSec)}`;
                        if (cntStr) tooltip += ` / ${cntStr}`;
                        if (lastEvStr) tooltip += ` / ${lastEvStr}`;
                        outageEl.title = tooltip;
                    } else if (maxSec !== null) {
                        outageEl.style.color = '#f97316';
                        outageEl.textContent = `瞬断最大: ${fmtOutageMs(maxSec)}`;
                        let tooltip = `最大瞬断時間: ${fmtOutageMs(maxSec)}${maxSec >= 1 ? ` (${maxSec.toFixed(1)}秒)` : ''}`;
                        if (cntStr) tooltip += ` / ${cntStr}`;
                        if (lastEvStr) tooltip += ` / ${lastEvStr}`;
                        outageEl.title = tooltip;
                    } else {
                        outageEl.style.color = '#94a3b8';
                        outageEl.textContent = '瞬断最大: -';
                        outageEl.title = data.status === 'Paused' ? '監視一時停止中' : '瞬断の発生なし（連続正常稼働中）';
                    }
                }
                pushLatencyHistory(ip, data);
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

                // ── IP競合バッジ・枠線警告の更新 ──
                const conflictBadgeEl = document.getElementById(`conflict-badge-${safeIpId}`);
                const cardEl = document.getElementById(`card-${safeIpId}`);
                if (data.ipConflict) {
                    if (conflictBadgeEl) {
                        conflictBadgeEl.style.display = 'inline-block';
                        conflictBadgeEl.title = `【IP競合検知】${data.ipConflict.reason} (検出MAC: ${data.ipConflict.detectedMac})`;
                    }
                    if (cardEl) {
                        cardEl.style.border = '1px solid rgba(239,68,68,0.6)';
                        cardEl.style.boxShadow = '0 0 12px rgba(239,68,68,0.2)';
                    }
                } else {
                    if (conflictBadgeEl) conflictBadgeEl.style.display = 'none';
                    if (cardEl && !cardEl.classList.contains('paused')) {
                        cardEl.style.border = '';
                        cardEl.style.boxShadow = '';
                    }
                }
            }
        });

        // 障害優先ソートが有効ならリアルタイムに順序更新
        applyFailureSort();

        // Update Sidebar Summary Chips
        updateSidebarSummary(statusData);

        // Update Heatmap / Timeline Component
        updateHeatmapTimeline(statusData);

        if (dashboardUnifiedChart) {
            const tab = localStorage.getItem('activeDashboardTab') || 'all';
            const mon = devices.filter(d => d.enabled !== false);
            const inTab = (tab === 'all') ? mon : mon.filter(d => ((d.group && d.group.trim()) ? d.group.trim() : 'Ungrouped') === tab);
            const targetDevices = inTab.length > 0 ? inTab : (mon.length > 0 ? mon : devices);
            const labelIp = (targetDevices[0] && targetDevices[0].ip && timeHistory[targetDevices[0].ip]) ? targetDevices[0].ip : (mon[0] ? mon[0].ip : null);
            if (labelIp && timeHistory[labelIp]) {
                dashboardUnifiedChart.data.labels = timeHistory[labelIp];
            }
            dashboardUnifiedChart.data.datasets.forEach(s => {
                if (latencyHistory[s.deviceIp]) {
                    s.data = latencyHistory[s.deviceIp];
                }
            });
            const vDash = document.getElementById('view-dashboard');
            if (vDash && vDash.classList.contains('active') && !document.hidden) {
                dashboardUnifiedChart.update('none');
            }
        }
        if (topologyLatencyChart) {
            const mon = devices.filter(d => d.enabled !== false);
            if (mon.length > 0) {
                topologyLatencyChart.data.labels = timeHistory[mon[0].ip] || Array(getHistoryLength()).fill('');
                const vTopo = document.getElementById('view-topology');
                if (vTopo && vTopo.classList.contains('active') && !document.hidden) {
                    topologyLatencyChart.update('none');
                }
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
        if (tabId !== 'tab-topology' && isTheaterMode) {
            toggleTheaterMode();
        }
        
        if (tabId === 'tab-dashboard') {
            if (dashboardUnifiedChart && !document.hidden) {
                dashboardUnifiedChart.update('none');
            }
        } else if (tabId === 'tab-topology') {
            initTopology();
            if (animationFxEnabled && !document.hidden) {
                startFlowAnimation();
            }
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

    // ── Client Heartbeat & Auto-shutdown on browser close ──
    // Send periodic heartbeat every 2.5s to keep server alive.
    // Uses a Web Worker timer so Chrome/Edge background tab throttling (60s+) never interrupts heartbeats during long-term runs.
    const triggerHeartbeatFetch = () => {
        if (navigator.onLine !== false) {
            fetch('/api/heartbeat', { method: 'GET', cache: 'no-store' }).catch(() => {});
        }
    };
    let heartbeatWorkerStarted = false;
    try {
        if (window.Worker && window.Blob && window.URL) {
            const workerCode = 'setInterval(function(){ postMessage("hb"); }, 2500);';
            const blob = new Blob([workerCode], { type: 'application/javascript' });
            const hbWorker = new Worker(URL.createObjectURL(blob));
            hbWorker.onmessage = triggerHeartbeatFetch;
            heartbeatWorkerStarted = true;
        }
    } catch (e) {}
    if (!heartbeatWorkerStarted) {
        setInterval(triggerHeartbeatFetch, 2500);
    }

    // Send immediate heartbeat & refresh status when tab becomes visible or focused
    const sendImmediateHeartbeat = () => {
        if (navigator.onLine !== false && !document.hidden) {
            fetch('/api/heartbeat', { method: 'GET', cache: 'no-store' }).catch(() => {});
            if (typeof fetchStatus === 'function') {
                fetchStatus();
            }
        }
    };
    document.addEventListener('visibilitychange', () => {
        if (!document.hidden) {
            sendImmediateHeartbeat();
            const viewTopo = document.getElementById('view-topology');
            if (viewTopo && viewTopo.classList.contains('active') && animationFxEnabled) {
                startFlowAnimation();
            }
            const viewDash = document.getElementById('view-dashboard');
            if (viewDash && viewDash.classList.contains('active') && dashboardUnifiedChart) {
                dashboardUnifiedChart.update('none');
            }
        } else {
            stopFlowAnimation();
        }
    });
    window.addEventListener('focus', sendImmediateHeartbeat);

    // Trigger server shutdown and log save when browser window/tab is closed
    const sendShutdownBeacon = (e) => {
        if (e && e.persisted) return;
        try {
            if (navigator.sendBeacon) {
                // reason=unload: ブラウザを閉じた・再読み込みしたときの合図 (無人運用モードではサーバー側で無視される)
                navigator.sendBeacon('/api/shutdown?reason=unload');
            } else {
                fetch('/api/shutdown?reason=unload', { method: 'POST', keepalive: true }).catch(() => {});
            }
        } catch (err) {}
    };

    window.addEventListener('beforeunload', sendShutdownBeacon);
    window.addEventListener('pagehide', (e) => {
        if (e && e.persisted) return;
        sendShutdownBeacon(e);
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
                'X-File-Name': encodeURIComponent(file.name)  // 日本語のファイル名もヘッダーで送れるようにする
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
                    let reason = '';
                    try { reason = (await response.json()).error || ''; } catch (_) {}
                    alert('画像のアップロードに失敗しました。' + (reason ? '\n' + reason : ''));
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
            const duration = Math.min(3600, Math.max(1, parseInt(iperfViewDurationInput.value) || 5));   // サーバー側の上限 (1〜3600秒) に合わせる
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
            iperfLiveConsole.innerHTML += `> ターゲット: <span style="color: var(--primary); font-weight: bold;">${escapeHTML(ip)}</span><br>`;
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
            let pollAbortController = null;

            // Attach stop handler BEFORE the polling loop starts so the button works immediately
            if (stopIperfViewBtn) {
                stopIperfViewBtn.disabled = false;
                stopIperfViewBtn._stopHandler = async () => {
                    if (isStopRequested) return; // prevent double-fire
                    isStopRequested = true;
                    stopIperfViewBtn.disabled = true;
                    stopIperfViewBtn.textContent = '中断中...';
                    // Abort any in-flight status fetch so the loop exits immediately
                    if (pollAbortController) {
                        try { pollAbortController.abort(); } catch(e) {}
                    }
                    try {
                        await fetch('/api/iperf?action=stop');
                    } catch(e) { /* ignore */ }
                };
            }

            try {
                // Step 1: Start Iperf in background
                const bwThresh = parseFloat(iperfViewBwThreshInput ? iperfViewBwThreshInput.value : (threshBandwidthEl ? threshBandwidthEl.value : 10)) || 10;
                const startRes = await fetch(`/api/iperf?action=start&ip=${encodeURIComponent(ip)}&t=${duration}&opts=${encodeURIComponent(options)}&bw=${bwThresh}`);
                const startData = await startRes.json();
                
                if (startData.command) {
                    iperfViewExecutedCommand.textContent = `実行コマンド: ${startData.command}`;
                    iperfViewExecutedCommand.classList.remove('hidden');
                    iperfViewExecutedCommand.style.display = 'block';
                    iperfLiveConsole.innerHTML += `> コマンド実行: <span style="color: #94a3b8;">${escapeHTML(startData.command)}</span>\n\n`;
                }

                if (startData.status === 'started') {
                    // Step 2: Poll for status and output (200ms interval for snappier stop response)
                    let isRunning = true;
                    while (isRunning && !isStopRequested) {
                        await new Promise(resolve => setTimeout(resolve, 200));
                        if (isStopRequested) break;
                        try {
                            pollAbortController = new AbortController();
                            const statusRes = await fetch(`/api/iperf?action=status`, { signal: pollAbortController.signal });
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
                        } catch (fetchErr) {
                            if (isStopRequested) break; // aborted by stop button — normal
                            throw fetchErr;             // real network error — propagate
                        }
                    }
                    
                    if (isStopRequested) {
                        // Wait briefly for server to finish flushing the log
                        await new Promise(resolve => setTimeout(resolve, 600));
                        try {
                            const finalStatus = await fetch(`/api/iperf?action=status`);
                            const finalData = await finalStatus.json();
                            if (finalData.output) {
                                iperfLiveConsole.textContent = finalData.output;
                                iperfLiveConsole.scrollTop = iperfLiveConsole.scrollHeight;
                                updateIperfChart(finalData.output);
                            }
                        } catch(e) { /* ignore final-flush errors */ }
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
                    iperfViewSummary.innerHTML = `<span style="color: var(--error);">&#10060; エラー: ${escapeHTML(startData.error || '計測を開始できませんでした')}</span>`;
                }
            } catch (err) {
                if (!isStopRequested) {
                    console.error('Iperf error:', err);
                    iperfViewSummary.innerHTML = `<span style="color: var(--error);">&#10060; 通信エラーが発生しました</span>`;
                }
            } finally {
                pollAbortController = null;
                clearInterval(timer);
                iperfViewLoading.classList.add('hidden');
                iperfViewLoading.style.display = 'none';
                runIperfViewBtn.disabled = false;
                if (stopIperfViewBtn) {
                    stopIperfViewBtn.style.display = 'none';
                    stopIperfViewBtn.disabled = false;
                    stopIperfViewBtn.textContent = '⏹ 計測を停止';
                    stopIperfViewBtn._stopHandler = null;
                }
                if (iperfViewOptionsInput) iperfViewOptionsInput.disabled = false;
                if (iperfViewBwThreshInput) iperfViewBwThreshInput.disabled = false;
                if (iperfCustomTargetInput) iperfCustomTargetInput.disabled = false;
                if (iperfTargetSelect) iperfTargetSelect.disabled = false;
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
            iconContent = `<image href="${escapeXml(image)}" x="-2" y="-2" width="40" height="40" clip-path="url(#circle-clip)" preserveAspectRatio="xMidYMid slice"/>`;
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
        if (data.status === "Failed" || data.status === "Error" || data.status === "Offline") {
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
                width: 2.5,
                dashes: false,
                tx: 0, rx: 0, totalMbps: 0, isOffline: false
            };
        }

        const fromStatus = window.lastStatusData ? window.lastStatusData[fromIp] : null;
        const toStatus = window.lastStatusData ? window.lastStatusData[toIp] : null;
        const isOffline = ['Failed', 'Error'].includes(fromStatus?.status) || ['Failed', 'Error'].includes(toStatus?.status);

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

        // Throughput calculation for dynamic traffic heatmap
        let tx = 0, rx = 0;
        if (fromStatus) {
            if (fromStatus.tx && !isNaN(parseFloat(fromStatus.tx))) tx = parseFloat(fromStatus.tx);
            if (fromStatus.rx && !isNaN(parseFloat(fromStatus.rx))) rx = parseFloat(fromStatus.rx);
            if (tx === 0 && rx === 0 && fromStatus.bandwidth && !isNaN(parseFloat(fromStatus.bandwidth))) {
                tx = parseFloat(fromStatus.bandwidth);
            }
        }
        if (toStatus) {
            if (rx === 0 && toStatus.tx && !isNaN(parseFloat(toStatus.tx))) rx = parseFloat(toStatus.tx);
        }
        const totalMbps = tx + rx;

        if (isOffline) {
            return {
                color: { color: '#ef4444', highlight: '#f87171', hover: '#fca5a5' },
                width: 2.5,
                dashes: [4, 4],
                tx, rx, totalMbps, isOffline: true
            };
        } else if (isHighLatency && totalMbps === 0) {
            return {
                color: { color: '#f59e0b', highlight: '#fbbf24', hover: '#fde047' },
                width: 3.0,
                dashes: isWireless ? [4, 4] : false,
                tx, rx, totalMbps, isOffline: false
            };
        } else {
            // Dynamic traffic heatmap coloring on edges (cyan/blue -> green -> orange -> magenta)
            let edgeColor, hlColor, hvColor, edgeWidth;

            if (totalMbps >= 75) {
                // Saturated / very heavy traffic: Magenta Glow
                edgeColor = '#d946ef';
                hlColor   = '#e879f9';
                hvColor   = '#f0abfc';
                edgeWidth = 4.0;
            } else if (totalMbps >= 25) {
                // Heavy traffic: Orange
                edgeColor = '#f97316';
                hlColor   = '#fb923c';
                hvColor   = '#fdba74';
                edgeWidth = 3.5;
            } else if (totalMbps >= 5) {
                // Moderate traffic: Green
                edgeColor = '#10b981';
                hlColor   = '#34d399';
                hvColor   = '#6ee7b7';
                edgeWidth = 3.0;
            } else {
                // Low / idle traffic: Cyan (wireless) or Blue (wired)
                edgeColor = isWireless ? '#06b6d4' : '#3b82f6';
                hlColor   = isWireless ? '#22d3ee' : '#60a5fa';
                hvColor   = isWireless ? '#67e8f9' : '#93c5fd';
                edgeWidth = 2.5;
            }

            return {
                color: { color: edgeColor, highlight: hlColor, hover: hvColor },
                width: edgeWidth,
                dashes: isWireless ? [6, 4] : false,
                tx, rx, totalMbps, isOffline: false
            };
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
            if (statusData && (statusData.status === "Success" || statusData.status === "Warning") && statusData.latency !== null && statusData.latency !== undefined) {
                latencySvgText = `${statusData.latency} ms`;
                latencyTooltipText = `\nLatency: ${statusData.latency} ms`;
            } else if (statusData && (statusData.status === "Failed" || statusData.status === "Error")) {
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

        // 0. Cyberpunk / CAD Tech Grid & Group Enclosure Backgrounds
        networkInstance.on('beforeDrawing', function(ctx) {
            const isDay = document.documentElement.getAttribute('data-theme') === 'day';
            const positions = networkInstance.getPositions();

            // Cyberpunk/CAD-like Tech Grid Background (scales with pan & zoom)
            try {
                const cWidth = container.clientWidth || 800;
                const cHeight = container.clientHeight || 600;
                const tl = networkInstance.DOMtoCanvas({ x: 0, y: 0 });
                const br = networkInstance.DOMtoCanvas({ x: cWidth, y: cHeight });
                const minX = Math.min(tl.x, br.x);
                const maxX = Math.max(tl.x, br.x);
                const minY = Math.min(tl.y, br.y);
                const maxY = Math.max(tl.y, br.y);

                const scale = (typeof networkInstance.getScale === 'function') ? networkInstance.getScale() : 1;
                ctx.save();
                const minorGrid = 50;
                const majorGrid = 250;

                const startMinorX = Math.floor(minX / minorGrid) * minorGrid;
                const endMinorX = Math.ceil(maxX / minorGrid) * minorGrid;
                const startMinorY = Math.floor(minY / minorGrid) * minorGrid;
                const endMinorY = Math.ceil(maxY / minorGrid) * minorGrid;

                const countMinorX = Math.round((endMinorX - startMinorX) / minorGrid);
                const countMinorY = Math.round((endMinorY - startMinorY) / minorGrid);

                // Minor Grid Lines (throttle/skip if zoomed out or excessive lines)
                if (scale >= 0.45 && countMinorX <= 80 && countMinorY <= 80) {
                    ctx.beginPath();
                    for (let gx = startMinorX; gx <= endMinorX; gx += minorGrid) {
                        ctx.moveTo(gx, minY);
                        ctx.lineTo(gx, maxY);
                    }
                    for (let gy = startMinorY; gy <= endMinorY; gy += minorGrid) {
                        ctx.moveTo(minX, gy);
                        ctx.lineTo(maxX, gy);
                    }
                    ctx.strokeStyle = isDay ? 'rgba(100, 116, 139, 0.06)' : 'rgba(56, 189, 248, 0.04)';
                    ctx.lineWidth = 1;
                    ctx.stroke();
                }

                // Major Grid Lines (capped)
                const startMajorX = Math.floor(minX / majorGrid) * majorGrid;
                const endMajorX = Math.ceil(maxX / majorGrid) * majorGrid;
                const startMajorY = Math.floor(minY / majorGrid) * majorGrid;
                const endMajorY = Math.ceil(maxY / majorGrid) * majorGrid;

                const countMajorX = Math.round((endMajorX - startMajorX) / majorGrid);
                const countMajorY = Math.round((endMajorY - startMajorY) / majorGrid);

                if (countMajorX <= 60 && countMajorY <= 60) {
                    ctx.beginPath();
                    for (let gx = startMajorX; gx <= endMajorX; gx += majorGrid) {
                        ctx.moveTo(gx, minY);
                        ctx.lineTo(gx, maxY);
                    }
                    for (let gy = startMajorY; gy <= endMajorY; gy += majorGrid) {
                        ctx.moveTo(minX, gy);
                        ctx.lineTo(maxX, gy);
                    }
                    ctx.strokeStyle = isDay ? 'rgba(100, 116, 139, 0.14)' : 'rgba(56, 189, 248, 0.09)';
                    ctx.lineWidth = 1.2;
                    ctx.stroke();

                    // Precision Crosshairs at major intersections (only if reasonable count)
                    if (countMajorX * countMajorY <= 150) {
                        ctx.beginPath();
                        const crossSize = 5;
                        for (let gx = startMajorX; gx <= endMajorX; gx += majorGrid) {
                            for (let gy = startMajorY; gy <= endMajorY; gy += majorGrid) {
                                ctx.moveTo(gx - crossSize, gy);
                                ctx.lineTo(gx + crossSize, gy);
                                ctx.moveTo(gx, gy - crossSize);
                                ctx.lineTo(gx, gy + crossSize);
                            }
                        }
                        ctx.strokeStyle = isDay ? 'rgba(71, 85, 105, 0.28)' : 'rgba(56, 189, 248, 0.28)';
                        ctx.lineWidth = 1.5;
                        ctx.stroke();
                    }
                }

                ctx.restore();
            } catch (err) {}

            // Group background rounded rectangles
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

        // 1. Radar Ripple Rings on Failed / Warning Nodes
        // 2. Traceroute Hop Highlighting
        // 3. Dynamic Traffic Heatmap Glow & Directional Comet-Tail Animation
        // 4. Center Throughput Badges
        networkInstance.on('afterDrawing', function(ctx) {
            const positions = networkInstance.getPositions();
            const isDay = document.documentElement.getAttribute('data-theme') === 'day';
            const now = Date.now();

            // 🫀 Radar Ripple Rings around Failed (red) and Warning (yellow) nodes
            activeDevices.forEach(d => {
                const pos = positions[d.ip];
                if (!pos) return;
                const statusColor = getDeviceStatusColor(d.ip);
                const isFailed = (statusColor === '#ef4444');
                const isWarning = (statusColor === '#f59e0b');

                if (isFailed) {
                    ctx.save();
                    if (animationFxEnabled) {
                        // 3 concentric expanding radar ripple rings (optimized blur)
                        for (let w = 0; w < 3; w++) {
                            const wavePhase = ((now + w * 600) % 1800) / 1800;
                            const waveRadius = 40 + wavePhase * 50;
                            const waveAlpha = (1 - wavePhase) * 0.75;
                            ctx.beginPath();
                            ctx.arc(pos.x, pos.y, waveRadius, 0, 2 * Math.PI);
                            ctx.strokeStyle = `rgba(239, 68, 68, ${waveAlpha})`;
                            ctx.lineWidth = 2.0 * (1 - wavePhase * 0.5);
                            ctx.shadowColor = 'rgba(239, 68, 68, 0.8)';
                            ctx.shadowBlur = 4;
                            ctx.stroke();
                            ctx.shadowBlur = 0;
                        }
                        // Breathing halo core ring
                        const pulse = Math.sin(now / 180) * 4;
                        ctx.beginPath();
                        ctx.arc(pos.x, pos.y, 42 + pulse, 0, 2 * Math.PI);
                        ctx.strokeStyle = 'rgba(239, 68, 68, 0.95)';
                        ctx.lineWidth = 3.0;
                        ctx.shadowColor = 'rgba(239, 68, 68, 1.0)';
                        ctx.shadowBlur = 5;
                        ctx.stroke();
                        ctx.shadowBlur = 0;
                    } else {
                        // Static alert halo
                        ctx.beginPath();
                        ctx.arc(pos.x, pos.y, 44, 0, 2 * Math.PI);
                        ctx.strokeStyle = 'rgba(239, 68, 68, 0.85)';
                        ctx.lineWidth = 3;
                        ctx.stroke();
                    }
                    ctx.restore();
                } else if (isWarning) {
                    ctx.save();
                    if (animationFxEnabled) {
                        // 2 concentric expanding radar ripple rings (optimized blur)
                        for (let w = 0; w < 2; w++) {
                            const wavePhase = ((now + w * 1200) % 2400) / 2400;
                            const waveRadius = 40 + wavePhase * 40;
                            const waveAlpha = (1 - wavePhase) * 0.65;
                            ctx.beginPath();
                            ctx.arc(pos.x, pos.y, waveRadius, 0, 2 * Math.PI);
                            ctx.strokeStyle = `rgba(245, 158, 11, ${waveAlpha})`;
                            ctx.lineWidth = 1.8 * (1 - wavePhase * 0.4);
                            ctx.shadowColor = 'rgba(245, 158, 11, 0.8)';
                            ctx.shadowBlur = 4;
                            ctx.stroke();
                            ctx.shadowBlur = 0;
                        }
                        // Breathing halo core ring
                        const pulse = Math.sin(now / 260) * 3;
                        ctx.beginPath();
                        ctx.arc(pos.x, pos.y, 42 + pulse, 0, 2 * Math.PI);
                        ctx.strokeStyle = 'rgba(245, 158, 11, 0.9)';
                        ctx.lineWidth = 2.5;
                        ctx.shadowColor = 'rgba(245, 158, 11, 0.9)';
                        ctx.shadowBlur = 5;
                        ctx.stroke();
                        ctx.shadowBlur = 0;
                    } else {
                        // Static warning halo
                        ctx.beginPath();
                        ctx.arc(pos.x, pos.y, 43, 0, 2 * Math.PI);
                        ctx.strokeStyle = 'rgba(245, 158, 11, 0.8)';
                        ctx.lineWidth = 2.5;
                        ctx.stroke();
                    }
                    ctx.restore();
                }
            });

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
                        ctx.shadowBlur = 6;
                        ctx.stroke();
                        ctx.shadowBlur = 0;
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

            // Edges: Dynamic Glow, Directional Comet-Tail Animation & Center Badges
            const edges = edgesDataSet.get();
            edges.forEach(edge => {
                const fromPos = positions[edge.from];
                const toPos = positions[edge.to];
                if (!fromPos || !toPos) return;

                const isTraced = isTraceEdge(edge.from, edge.to);
                const estyle = getEdgeStyle(edge.from, edge.to);
                const isWireless = !!edge.dashes;
                const isOffline = estyle.isOffline;
                const tx = estyle.tx || 0;
                const rx = estyle.rx || 0;
                const totalMbps = estyle.totalMbps || 0;

                // If trace path, draw custom neon highlight (optimized blur)
                if (isTraced) {
                    ctx.save();
                    ctx.beginPath();
                    ctx.moveTo(fromPos.x, fromPos.y);
                    ctx.lineTo(toPos.x, toPos.y);
                    ctx.strokeStyle = 'rgba(239, 68, 68, 0.85)';
                    ctx.lineWidth = 5;
                    ctx.shadowColor = 'rgba(239, 68, 68, 0.95)';
                    ctx.shadowBlur = 6;
                    ctx.stroke();
                    ctx.shadowBlur = 0;
                    ctx.restore();
                } else if (totalMbps >= 75) {
                    // Magenta glow for saturated lines
                    ctx.save();
                    ctx.beginPath();
                    ctx.moveTo(fromPos.x, fromPos.y);
                    ctx.lineTo(toPos.x, toPos.y);
                    ctx.strokeStyle = 'rgba(217, 70, 239, 0.45)';
                    ctx.lineWidth = 6.5;
                    ctx.shadowColor = '#d946ef';
                    ctx.shadowBlur = 6;
                    ctx.stroke();
                    ctx.shadowBlur = 0;
                    ctx.restore();
                } else if (totalMbps >= 25) {
                    // Orange glow for heavy lines
                    ctx.save();
                    ctx.beginPath();
                    ctx.moveTo(fromPos.x, fromPos.y);
                    ctx.lineTo(toPos.x, toPos.y);
                    ctx.strokeStyle = 'rgba(249, 115, 22, 0.35)';
                    ctx.lineWidth = 5.5;
                    ctx.shadowColor = '#f97316';
                    ctx.shadowBlur = 4;
                    ctx.stroke();
                    ctx.shadowBlur = 0;
                    ctx.restore();
                }

                // 🌊 Directional packet particle comet-tail animation
                if (animationFxEnabled && !isOffline) {
                    if (isTraced) {
                        const numDots = 3;
                        for (let i = 0; i < numDots; i++) {
                            const offset = i / numDots;
                            const prog = (flowAnimationProgress * 2.5 + offset) % 1.0;
                            drawCometParticle(ctx, fromPos, toPos, prog, '#f97316', true);
                        }
                    } else if (tx > 0 || rx > 0) {
                        // Forward flow: TX (fromPos -> toPos)
                        if (tx > 0) {
                            const txSpeed = 1.0 + Math.min(tx / 60, 2.5);
                            const txCount = tx >= 50 ? 3 : (tx >= 10 ? 2 : 1);
                            const txColor = tx >= 75 ? '#ec4899' : (tx >= 25 ? '#fb923c' : (isWireless ? '#38bdf8' : '#60a5fa'));
                            for (let i = 0; i < txCount; i++) {
                                const offset = i / txCount;
                                const prog = (flowAnimationProgress * txSpeed + offset) % 1.0;
                                drawCometParticle(ctx, fromPos, toPos, prog, txColor, false);
                            }
                        }
                        // Reverse flow: RX (toPos -> fromPos)
                        if (rx > 0) {
                            const rxSpeed = 1.0 + Math.min(rx / 60, 2.5);
                            const rxCount = rx >= 50 ? 3 : (rx >= 10 ? 2 : 1);
                            const rxColor = rx >= 75 ? '#d946ef' : (rx >= 25 ? '#f97316' : '#34d399');
                            for (let i = 0; i < rxCount; i++) {
                                const offset = i / rxCount;
                                const prog = (flowAnimationProgress * rxSpeed + offset) % 1.0;
                                drawCometParticle(ctx, toPos, fromPos, prog, rxColor, false);
                            }
                        }
                    } else {
                        // Idle baseline heartbeat ping packet
                        const idleColor = isWireless ? '#fbbf24' : '#38bdf8';
                        const prog = flowAnimationProgress % 1.0;
                        drawCometParticle(ctx, fromPos, toPos, prog, idleColor, false);
                    }
                }

                // 🎨 Small throughput pill badge at edge center (e.g. ↑12.4M / ↓45.8M)
                const mx = (fromPos.x + toPos.x) / 2;
                const my = (fromPos.y + toPos.y) / 2;

                let badgeText = '';
                if (isOffline) {
                    badgeText = '⚡ OFFLINE';
                } else if (tx > 0 || rx > 0) {
                    badgeText = `↑${formatMbps(tx)} / ↓${formatMbps(rx)}`;
                } else if (totalMbps > 0) {
                    badgeText = `↑${formatMbps(totalMbps)}`;
                } else {
                    badgeText = '↑0M / ↓0M';
                }

                ctx.save();
                ctx.font = "bold 10px 'Inter', monospace, sans-serif";
                const textMetrics = ctx.measureText(badgeText);
                const pillW = textMetrics.width + 16;
                const pillH = 19;
                const pillX = mx - pillW / 2;
                const pillY = my - pillH / 2;

                ctx.fillStyle = isDay ? 'rgba(248, 250, 252, 0.94)' : 'rgba(15, 23, 42, 0.88)';
                ctx.strokeStyle = estyle.color.color || '#3b82f6';
                ctx.lineWidth = 1.3;
                ctx.shadowColor = 'rgba(0, 0, 0, 0.45)';
                ctx.shadowBlur = 3;

                ctx.beginPath();
                if (typeof ctx.roundRect === 'function') {
                    ctx.roundRect(pillX, pillY, pillW, pillH, 9);
                } else {
                    ctx.rect(pillX, pillY, pillW, pillH);
                }
                ctx.fill();
                ctx.shadowBlur = 0;
                ctx.stroke();

                ctx.fillStyle = isOffline ? '#ef4444' : (isDay ? '#0f172a' : '#f8fafc');
                ctx.textAlign = 'center';
                ctx.textBaseline = 'middle';
                ctx.fillText(badgeText, mx, my + 0.5);

                ctx.restore();
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
                document.getElementById('ctx-trace').style.display = 'block';
            } else if (edgeId) {
                ctxMenu.dataset.edgeId = edgeId;
                ctxMenu.dataset.nodeId = '';
                document.getElementById('ctx-unlink').style.display = 'block';
                document.getElementById('ctx-edit').style.display = 'none';
                document.getElementById('ctx-trace').style.display = 'none';
            } else {
                ctxMenu.style.display = 'none';
                return;
            }

            ctxMenu.style.display = 'block';
            // メニューの位置は親要素が基準なので、画面上の座標から親要素の位置を引く (そのままだと右下にずれて表示される)
            const ctxParentRect = ctxMenu.offsetParent ? ctxMenu.offsetParent.getBoundingClientRect() : { left: 0, top: 0 };
            ctxMenu.style.left = (params.event.clientX - ctxParentRect.left) + 'px';
            ctxMenu.style.top = (params.event.clientY - ctxParentRect.top) + 'px';
        });

        // Setup visual topology controls
        const treeLayoutBtn = document.getElementById('topo-tree-layout-btn');
        if (treeLayoutBtn) {
            treeLayoutBtn.onclick = () => applyHierarchicalTreeLayout();
        }
        const fullscreenBtn = document.getElementById('topo-fullscreen-btn');
        if (fullscreenBtn) {
            fullscreenBtn.onclick = () => toggleTheaterMode();
        }
        const fxToggleBtn = document.getElementById('topo-fx-toggle-btn');
        if (fxToggleBtn) {
            fxToggleBtn.onclick = () => toggleAnimationFx();
            updateFxButtonState();
        }

        startFlowAnimation();

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
            
            ensureHistory(d.ip);

            return {
                label: d.name || d.ip,
                deviceIp: d.ip,
                data: latencyHistory[d.ip],
                borderColor: color,
                backgroundColor: 'transparent',
                borderWidth: 2,
                pointRadius: getHistoryLength() > 30 ? 0 : 2,
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
                labels: timeHistory[activeDevices[0].ip] || Array(getHistoryLength()).fill(''),
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
                        grace: '15%',
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

    const topoNodeRenderCache = {};
    const topoEdgeRenderCache = {};

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
            if (statusData && (statusData.status === "Success" || statusData.status === "Warning") && statusData.latency !== null && statusData.latency !== undefined) {
                latencySvgText = `${statusData.latency} ms`;
                latencyTooltipText = `\nLatency: ${statusData.latency} ms`;
            } else if (statusData && (statusData.status === "Failed" || statusData.status === "Error")) {
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
            const newTitle = `${safeName}\nIP: ${safeIp}\nGroup: ${safeGroup}${safeLatencyTooltip}${safeBandwidthTooltip}`;

            // Diff check: only update nodesDataSet if SVG or tooltip has changed
            const cacheKey = d.ip;
            const prev = topoNodeRenderCache[cacheKey];
            if (!prev || prev.svgUrl !== svgUrl || prev.title !== newTitle) {
                topoNodeRenderCache[cacheKey] = { svgUrl: svgUrl, title: newTitle };
                try {
                    nodesDataSet.update({
                        id: d.ip,
                        image: svgUrl,
                        label: '',
                        title: newTitle
                    });
                } catch (e) {}
            }
        });

        if (edgesDataSet) {
            try {
                const allEdges = edgesDataSet.get();
                allEdges.forEach(edge => {
                    const estyle = getEdgeStyle(edge.from, edge.to);
                    const edgeKey = edge.id;
                    const prevE = topoEdgeRenderCache[edgeKey];
                    const eColor = estyle.color;
                    const eWidth = estyle.width;
                    const eDashes = estyle.dashes;

                    const eColorHex = eColor.color;
                    if (!prevE || prevE.colorHex !== eColorHex || prevE.width !== eWidth || JSON.stringify(prevE.dashes) !== JSON.stringify(eDashes)) {
                        topoEdgeRenderCache[edgeKey] = { colorHex: eColorHex, width: eWidth, dashes: eDashes };
                        edgesDataSet.update({
                            id: edge.id,
                            color: eColor,
                            width: eWidth,
                            dashes: eDashes
                        });
                    }
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
                topoLinkBtn.textContent = '🔗 リンク追加中（もう一度押すと終了）';
                const modeText = document.getElementById('topo-mode-text');
                if (modeText) {
                    modeText.classList.remove('hidden');
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
                topoUnlinkBtn.textContent = '✖ リンク削除中（もう一度押すと終了）';
                const modeText = document.getElementById('topo-mode-text');
                if (modeText) {
                    modeText.classList.remove('hidden');
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

    const ctxTraceBtn = document.getElementById('ctx-trace');
    if (ctxTraceBtn) {
        ctxTraceBtn.addEventListener('click', () => {
            const ctxMenu = document.getElementById('topo-context-menu');
            const nodeId = ctxMenu ? ctxMenu.dataset.nodeId : '';
            if (ctxMenu) ctxMenu.style.display = 'none';
            if (nodeId) startRouteTrace(nodeId);
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
                'X-File-Name': encodeURIComponent(file.name)  // 日本語のファイル名もヘッダーで送れるようにする
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
                    let reason = '';
                    try { reason = (await response.json()).error || ''; } catch (_) {}
                    alert('画像のアップロードに失敗しました。' + (reason ? '\n' + reason : ''));
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
                    if (iperfSummary) iperfSummary.innerHTML = `<span style="color: var(--error);">❌ エラー: ${escapeHTML(data.error || data.message || '計測に失敗しました')}</span>`;
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
        if (historyLatencyChart) {
            try { historyLatencyChart.destroy(); } catch (e) {}
            historyLatencyChart = null;
        }
        if (historyTrafficChart) {
            try { historyTrafficChart.destroy(); } catch (e) {}
            historyTrafficChart = null;
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
            // 前回の取得 (全インターフェース・経路表の走査で数秒〜数十秒かかる) が終わるまで次を送らない
            // 重なるとサーバーの作業スレッドを占有し、機器にも問い合わせが殺到して取得失敗の原因になる
            if (currentSnmpIp === device.ip && !snmpFetchInFlight) {
                await fetchSnmpDetails(device, true);
            }
        }, 3000);
    }

    let snmpFetchInFlight = false;
    async function fetchSnmpDetails(device, isQuiet) {
        snmpFetchInFlight = true;
        try {
            return await fetchSnmpDetailsInner(device, isQuiet);
        } finally {
            snmpFetchInFlight = false;
        }
    }

    async function fetchSnmpDetailsInner(device, isQuiet) {
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
            // SNMP取得失敗時はサーバーが返す原因 (snmpError) を表示する
            document.getElementById('snmp-sysDescr').textContent = data.snmpError ? `⚠ ${data.snmpError}` : getSnmpValue(data.sysDescr, 'N/A');

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
                    
                    // Errors and Discards (サーバーが data.interfaces の各要素に付与済み)
                    // ※ 以前ここで未定義の statusData を参照しており、インターフェースが1つでもあると
                    //   ReferenceError で SNMP詳細画面の描画全体が失敗していた
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
                // サーバー側のインポートは「現在の機器一覧をすべて置き換える」動作 (追加ではない) なので、その通りに確認する
                // (以前は「既存設定に追加されます」と表示され、登録済みの機器が消えることが分からなかった)
                const confirmed = confirm(`${parsed.length} 台のデバイスをインポートします。\n\n⚠ 現在登録されている ${devices.length} 台の機器一覧は、すべてこのファイルの内容に置き換わります（ファイルにない機器は削除されます）。\n\nよろしいですか？`);
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
    // Export / Import Devices (CSV)
    // Excel で編集できる形式。パスワードは含めない
    // =========================================================
    const CSV_COLUMNS = [
        { key: 'ip', label: 'IPアドレス' },
        { key: 'name', label: '機器名' },
        { key: 'group', label: 'グループ' },
        { key: 'enabled', label: '監視' },
        { key: 'checkType', label: '監視方式' },
        { key: 'port', label: 'ポート' },
        { key: 'community', label: 'コミュニティ名' },
        { key: 'connectedTo', label: '接続先' },
        { key: 'location', label: '設置場所' },
        { key: 'vendorContact', label: '保守連絡先' },
        { key: 'troubleMemo', label: 'マニュアル' },
        { key: 'webUrl', label: '管理画面URL' },
        { key: 'deviceType', label: '機器種別' },
        { key: 'snmpVersion', label: 'SNMPバージョン' },
        { key: 'snmpUser', label: 'SNMPユーザー' },
        { key: 'snmpAuthProto', label: 'SNMP認証方式' },
        { key: 'snmpPrivProto', label: 'SNMP暗号化方式' }
    ];

    // 1 項目を CSV の形にする。=,+,-,@ で始まる文字は Excel が数式として実行するので、先頭に ' を付けて防ぐ
    function toCsvCell(value) {
        let text = (value === null || value === undefined) ? '' : String(value);
        if (/^[=+\-@\t\r]/.test(text)) text = "'" + text;
        return /[",\r\n]/.test(text) ? '"' + text.replace(/"/g, '""') + '"' : text;
    }

    // CSV の文字列を行と項目に分ける (""で囲まれた中のカンマ・改行も正しく扱う)
    function parseCsvText(text) {
        const rows = [];
        let row = [], cell = '', inQuotes = false;
        for (let i = 0; i < text.length; i++) {
            const ch = text[i];
            if (inQuotes) {
                if (ch === '"') {
                    if (text[i + 1] === '"') { cell += '"'; i++; }
                    else inQuotes = false;
                } else {
                    cell += ch;
                }
            } else if (ch === '"' && cell === '') {
                inQuotes = true;
            } else if (ch === ',') {
                row.push(cell); cell = '';
            } else if (ch === '\n' || ch === '\r') {
                if (ch === '\r' && text[i + 1] === '\n') i++;
                row.push(cell); cell = '';
                rows.push(row); row = [];
            } else {
                cell += ch;
            }
        }
        if (cell !== '' || row.length > 0) { row.push(cell); rows.push(row); }
        return rows.filter(r => r.some(c => c.trim() !== ''));
    }

    // CSV の行を機器データにする。問題のある行は errors に理由を入れる
    function csvRowsToDevices(rows) {
        const errors = [];
        if (rows.length < 2) return { items: [], errors: ['データ行がありません'] };
        const keyOf = {};
        CSV_COLUMNS.forEach(c => { keyOf[c.label] = c.key; keyOf[c.key.toLowerCase()] = c.key; });
        const headers = rows[0].map(h => keyOf[h.replace(/^﻿/, '').trim()] || keyOf[h.replace(/^﻿/, '').trim().toLowerCase()] || null);
        if (!headers.includes('ip')) return { items: [], errors: ['1行目に「IPアドレス」の列が見つかりません'] };

        const ipRegex = /^(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)$/;
        const items = [], seen = new Set();
        rows.slice(1).forEach((cells, index) => {
            const lineNo = index + 2;
            const item = {};
            headers.forEach((key, col) => {
                if (!key || cells[col] === undefined) return;
                // エクスポート時に付けた先頭の ' を取り除く
                item[key] = cells[col].trim().replace(/^'(?=[=+\-@])/, '');
            });
            if (!ipRegex.test(item.ip || '')) { errors.push(`${lineNo}行目: IPアドレスが正しくありません (${item.ip || '空欄'})`); return; }
            if (seen.has(item.ip)) { errors.push(`${lineNo}行目: IPアドレス ${item.ip} が重複しています`); return; }

            if (item.enabled !== undefined) {
                const flag = item.enabled.toLowerCase();
                if (['有効', 'on', 'true', '1', ''].includes(flag)) item.enabled = true;
                else if (['無効', 'off', 'false', '0'].includes(flag)) item.enabled = false;
                else { errors.push(`${lineNo}行目: 「監視」は 有効 / 無効 で指定してください (${item.enabled})`); return; }
            }
            if (item.checkType !== undefined) {
                item.checkType = item.checkType.toLowerCase() || 'icmp';
                if (!['icmp', 'tcp'].includes(item.checkType)) { errors.push(`${lineNo}行目: 「監視方式」は icmp / tcp で指定してください`); return; }
            }
            if (item.port !== undefined) {
                const port = item.port === '' ? 0 : Number(item.port);
                if (!Number.isInteger(port) || port < 0 || port > 65535) { errors.push(`${lineNo}行目: ポート番号が正しくありません (${item.port})`); return; }
                item.port = port;
            }
            if (item.checkType === 'tcp' && !item.port) {
                const current = devices.find(d => d.ip === item.ip);
                if (!current || !current.port) { errors.push(`${lineNo}行目: TCP 監視にはポート番号が必要です`); return; }
            }
            seen.add(item.ip);
            items.push(item);
        });
        return { items, errors };
    }

    // Excel で保存した CSV は Shift_JIS のことがあるので、UTF-8 として読めなければ Shift_JIS で読む
    async function readCsvFileText(file) {
        const buffer = await file.arrayBuffer();
        try {
            return new TextDecoder('utf-8', { fatal: true }).decode(buffer);
        } catch (e) {
            return new TextDecoder('shift_jis').decode(buffer);
        }
    }

    const exportCsvBtn = document.getElementById('export-devices-csv-btn');
    if (exportCsvBtn) {
        exportCsvBtn.addEventListener('click', () => {
            const lines = [CSV_COLUMNS.map(c => c.label).join(',')];
            devices.forEach(d => {
                lines.push(CSV_COLUMNS.map(c => {
                    if (c.key === 'enabled') return d.enabled === false ? '無効' : '有効';
                    return toCsvCell(d[c.key]);
                }).join(','));
            });
            // 先頭の BOM は、Excel が日本語を文字化けさせずに開くための印
            const blob = new Blob(['﻿' + lines.join('\r\n') + '\r\n'], { type: 'text/csv;charset=utf-8' });
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = `devices_export_${new Date().toISOString().slice(0, 10)}.csv`;
            a.click();
            URL.revokeObjectURL(url);
        });
    }

    const importCsvFile = document.getElementById('import-devices-csv-file');
    if (importCsvFile) {
        importCsvFile.addEventListener('change', async (e) => {
            const file = e.target.files[0];
            if (!file) return;
            try {
                const { items, errors } = csvRowsToDevices(parseCsvText(await readCsvFileText(file)));
                const errorText = errors.length > 0
                    ? `\n\n⚠ 次の ${errors.length} 行は取り込みません:\n${errors.slice(0, 10).join('\n')}${errors.length > 10 ? '\n…ほか' : ''}`
                    : '';
                if (items.length === 0) {
                    alert(`取り込める機器がありません。${errorText}`);
                    return;
                }
                const updateCount = items.filter(item => devices.some(d => d.ip === item.ip)).length;
                const message = `CSV を取り込みます。\n\n・新しく追加: ${items.length - updateCount} 台\n・登録済みを更新: ${updateCount} 台\n\nCSV にない機器はそのまま残ります。パスワードなど CSV にない項目も変わりません。${errorText}\n\nよろしいですか？`;
                if (!confirm(message)) return;

                const res = await fetch('/api/devices/bulk', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(items)
                });
                if (res.ok) {
                    await fetchDevices();
                    renderManageList();
                    showToast('success', 'CSV インポート', `${items.length} 台を取り込みました。`);
                } else {
                    const err = await res.json().catch(() => ({ error: 'Unknown error' }));
                    alert(`インポート失敗: ${err.error}`);
                }
            } catch (err) {
                alert(`ファイルの読み込みに失敗しました: ${err.message}`);
            } finally {
                importCsvFile.value = '';
            }
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
            snmpv3Fields.classList.toggle('hidden', devSnmpVersion.value !== 'v3');
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
    const stopMtrBtn = document.getElementById('stop-mtr-btn');

    function mtrResetUI() {
        runMtrBtn.disabled = false;
        if (stopMtrBtn) stopMtrBtn.style.display = 'none';
        mtrLoading.style.display = 'none';
    }

    if (runMtrBtn) {
        runMtrBtn.addEventListener('click', async () => {
            if (!currentSnmpIp) return;

            runMtrBtn.disabled = true;
            if (stopMtrBtn) {
                stopMtrBtn.style.display = 'inline-flex';
                stopMtrBtn.disabled = false;
                stopMtrBtn.textContent = '⏹ 診断を停止';
            }
            mtrLoading.style.display = 'flex';
            mtrConsole.textContent = '> MTR 診断を初期化中...\n';

            try {
                const res = await fetch(`/api/mtr?action=start&ip=${encodeURIComponent(currentSnmpIp)}`);
                const data = await res.json();

                if (data.status === 'started') {
                    if (mtrPollInterval) clearInterval(mtrPollInterval);
                    mtrPollInterval = setInterval(async () => {
                        try {
                            const statusRes = await fetch(`/api/mtr?action=status`);
                            const statusData = await statusRes.json();

                            if (statusData.output) {
                                mtrConsole.textContent = statusData.output;
                                mtrConsole.scrollTop = mtrConsole.scrollHeight;
                            }

                            if (statusData.running === false) {
                                clearInterval(mtrPollInterval);
                                mtrPollInterval = null;
                                mtrResetUI();
                            }
                        } catch (pollErr) {
                            // Network error during polling — stop the interval and restore UI
                            console.warn('MTR poll error:', pollErr);
                            clearInterval(mtrPollInterval);
                            mtrPollInterval = null;
                            mtrConsole.textContent += `\n⚠️ ポーリング中に通信エラーが発生しました\n`;
                            mtrResetUI();
                        }
                    }, 1000);
                } else {
                    mtrConsole.textContent += `❌ エラー: ${data.error || '開始できませんでした'}\n`;
                    mtrResetUI();
                }
            } catch (err) {
                console.error('MTR error:', err);
                mtrConsole.textContent += `❌ 通信エラーが発生しました\n`;
                mtrResetUI();
            }
        });
    }

    if (stopMtrBtn) {
        stopMtrBtn.addEventListener('click', async () => {
            stopMtrBtn.disabled = true;
            stopMtrBtn.textContent = '中断中...';
            // Stop the client-side polling loop
            if (mtrPollInterval) {
                clearInterval(mtrPollInterval);
                mtrPollInterval = null;
            }
            // Ask server to kill the tracert process
            try { await fetch('/api/mtr?action=stop'); } catch(e) {}
            mtrConsole.textContent += '\n⏹ 診断を中断しました\n';
            mtrResetUI();
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
                    const timeVal = d.Timestamp || d['タイムスタンプ'] || '';
                    const dt = new Date(timeVal);
                    if (isNaN(dt.getTime())) return '';
                    return `${dt.getHours()}:${String(dt.getMinutes()).padStart(2,'0')}`;
                });
                const latencyData = json.data.map(d => parseFloat(d.Latency_ms || d['遅延_ms']) || 0);
                const txData = json.data.map(d => parseFloat(d.Tx_Mbps || d['送信_Mbps'] || d['帯域_Mbps']) || 0);
                const rxData = json.data.map(d => parseFloat(d.Rx_Mbps || d['受信_Mbps']) || 0);

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
        let hasUdpJitter = false;

        lines.forEach(line => {
            if (line.includes('sender') || line.includes('receiver') || line.includes('SUM')) return;

            const timeMatch = line.match(/^\[(\d{2}:\d{2}:\d{2})\]/);
            const tsStr = timeMatch ? timeMatch[1] : null;

            // Check for UDP line: [  5]   0.00-1.00   sec  1.19 MBytes  10.0 Mbits/sec  0.035 ms  0/892 (0%)
            const udpMatch = line.match(/(\d+(?:\.\d+)?)-(\d+(?:\.\d+)?)\s+sec.*?(\d+(?:\.\d+)?)\s+([KMGb]?bits\/sec)\s+(\d+(?:\.\d+)?)\s+ms/i);
            if (udpMatch) {
                const start = parseFloat(udpMatch[1]);
                const end = parseFloat(udpMatch[2]);
                let mbits = parseFloat(udpMatch[3]);
                const unitRaw = udpMatch[4];
                const jitMs = parseFloat(udpMatch[5]);
                if (/Gbits/i.test(unitRaw)) mbits *= 1000;
                else if (/Kbits/i.test(unitRaw)) mbits /= 1000;

                if (end - start <= 1.5) {
                    hasUdpJitter = true;
                    dataPoints.push({ sec: end, val: mbits, jit: jitMs, label: tsStr || `${start}-${end}s` });
                }
            } else {
                // Parse standard TCP/generic interval lines
                const match = line.match(/(\d+(?:\.\d+)?)-(\d+(?:\.\d+)?)\s+sec.*?(\d+(?:\.\d+)?)\s+([KMGb]?bits\/sec)/i);
                if (match) {
                    const start = parseFloat(match[1]);
                    const end = parseFloat(match[2]);
                    let mbits = parseFloat(match[3]);
                    const unitRaw = match[4];
                    if (/Gbits/i.test(unitRaw)) mbits *= 1000;
                    else if (/Kbits/i.test(unitRaw)) mbits /= 1000;

                    if (end - start <= 1.5) {
                        dataPoints.push({ sec: end, val: mbits, jit: null, label: tsStr || `${start}-${end}s` });
                    }
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
            const trimmedPoints = uniquePoints.length > 60 ? uniquePoints.slice(-60) : uniquePoints;
            iperfChart.data.labels = trimmedPoints.map(p => p.label);
            iperfChart.data.datasets[0].data = trimmedPoints.map(p => p.val);

            // If UDP jitter is detected, add or update dataset[1]
            if (hasUdpJitter) {
                if (iperfChart.data.datasets.length < 2) {
                    iperfChart.data.datasets.push({
                        label: 'ジッター (ms)',
                        data: [],
                        borderColor: '#f59e0b',
                        borderWidth: 2,
                        pointRadius: 3,
                        pointBackgroundColor: '#fbbf24',
                        borderDash: [3, 3],
                        fill: false,
                        tension: 0.2,
                        yAxisID: 'yJitter'
                    });
                    if (!iperfChart.options.scales.yJitter) {
                        iperfChart.options.scales.yJitter = {
                            position: 'right',
                            beginAtZero: true,
                            grid: { drawOnChartArea: false },
                            ticks: { font: { size: 10 } },
                            title: { display: true, text: 'ジッター (ms)', font: { size: 10, weight: 'bold' } }
                        };
                    }
                }
                iperfChart.data.datasets[1].data = trimmedPoints.map(p => p.jit);
            }
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
            showToast('info', '表示モード', (newMode === 'simple') ? 'かんたん表示モードに切り替えました' : '詳細表示モードに切り替えました');
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
                const combined = `${log.Timestamp} ${log.SourceIP} ${log.Severity} ${log.Kind || ''} ${log.Message}`.toLowerCase();
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
                    ${log.Kind === 'Trap' ? '<span class="syslog-tag" style="background:rgba(139,92,246,0.2); color:#a78bfa;">Trap</span>' : ''}
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
                // 実際に受信しているポートを表示する (指定ポートが使えず 1514 に切り替わった場合も分かるように)
                const listenStatusEl = document.getElementById('syslog-listen-status');
                if (listenStatusEl) {
                    if (data.enabled === false) {
                        listenStatusEl.textContent = '受信状態: 停止中 (設定で Syslog 受信が無効です)';
                        listenStatusEl.style.color = 'var(--text-muted)';
                    } else if (data.listenError) {
                        listenStatusEl.textContent = '⚠ 受信状態: ' + data.listenError;
                        listenStatusEl.style.color = '#f59e0b';
                    } else if (data.trapListenError) {
                        listenStatusEl.textContent = '⚠ 受信状態: ' + data.trapListenError;
                        listenStatusEl.style.color = '#f59e0b';
                    } else if (data.listenPort) {
                        listenStatusEl.textContent = `受信状態: Syslog は UDP ${data.listenPort} 番、SNMP Trap は UDP ${data.trapListenPort || '-'} 番で受信中`;
                        listenStatusEl.style.color = '#10b981';
                    }
                }
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
                showToast('info', 'Syslog', 'Syslog ログを消去しました');
            }
        });
    }
    // Poll syslog every 3s when syslog tab is active (ID stored for future clearInterval)
    const syslogPollInterval = setInterval(() => {
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
                    showToast('success', 'コンフィグバックアップ', `スナップショットを作成しました (${data.filename})`);
                    await loadConfigBackupList(currentSnmpIp);
                } else {
                    showToast('error', 'コンフィグバックアップ', 'バックアップ取得に失敗しました。');
                }
            } catch (err) {
                showToast('error', 'コンフィグバックアップ', '通信エラーが発生しました。');
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

    // 6. Update SNMP Modal Opening with Manual Link, Backup, and Remote Control (Milestone 2)
    const originalOpenSnmpDetailsModal = openSnmpDetailsModal;
    openSnmpDetailsModal = async function(device) {
        if (typeof device === 'string') {
            const found = devices.find(d => d.ip === device);
            device = found || { ip: device, name: device };
        }
        if (originalOpenSnmpDetailsModal) await originalOpenSnmpDetailsModal(device);
        
        // Populate manual and location tab
        const locEl = document.getElementById('modal-memo-location');
        const webEl = document.getElementById('modal-memo-weburl');
        const linkWrapper = document.getElementById('modal-memo-link-wrapper');
        const linkEl = document.getElementById('modal-memo-link');
        const emptyEl = document.getElementById('modal-memo-empty');
        
        if (locEl) locEl.textContent = device.location || '未登録';
        if (webEl) webEl.innerHTML = safeLinkUrl(device.webUrl) ? `<a href="${escapeHTML(safeLinkUrl(device.webUrl))}" target="_blank" rel="noopener noreferrer" style="color:var(--primary); text-decoration:underline;">${escapeHTML(device.webUrl)}</a>` : '—';
        
        if (device.troubleMemo && device.troubleMemo.trim()) {
            if (linkEl) linkEl.href = safeLinkUrl(device.troubleMemo) || '#';
            if (linkWrapper) linkWrapper.style.display = 'block';
            if (emptyEl) emptyEl.style.display = 'none';
        } else {
            if (linkWrapper) linkWrapper.style.display = 'none';
            if (emptyEl) emptyEl.style.display = 'block';
        }

        // Load backup list
        loadConfigBackupList(device.ip);

        // Milestone 2: Setup Remote Tab for Device
        setupRemoteTabForDevice(device);

        // Milestone 2: Setup Device Logs Tab for Device
        setupDeviceLogTabForDevice(device);
    };
    window.openSnmpDetailsModal = openSnmpDetailsModal;

    // 7. Helper: Render simple mode memo badge into device cards
    const originalRenderDeviceCard = typeof renderDeviceCard !== 'undefined' ? renderDeviceCard : null;
    if (typeof originalRenderDeviceCard === 'function') {
        renderDeviceCard = function(device) {
            const card = originalRenderDeviceCard(device);
            if (card && (device.location || device.troubleMemo)) {
                const memoDiv = document.createElement('div');
                memoDiv.className = 'simple-mode-memo-badge';
                memoDiv.innerHTML = `
                    ${device.location ? `<span>📍 <strong>${escapeHTML(device.location)}</strong></span>` : ''}
                    ${safeLinkUrl(device.troubleMemo) ? `<span>📖 <a href="${escapeHTML(safeLinkUrl(device.troubleMemo))}" target="_blank" rel="noopener noreferrer" style="color:var(--primary); font-weight:600; text-decoration:underline;">マニュアル</a></span>` : ''}
                `;
                const content = card.querySelector('.device-card-content') || card;
                content.appendChild(memoDiv);
            }
            return card;
        };
    }

    // =========================================================================
    // 8. Milestone 2: Remote Device Management & Execution Logic
    // =========================================================================
    const btnRemoteReboot = document.getElementById('btn-remote-reboot');
    const remoteCmdSelect = document.getElementById('remote-cmd-select');
    const btnRemoteExecCmd = document.getElementById('btn-remote-exec-cmd');
    const remoteCustomCmdInput = document.getElementById('remote-custom-cmd-input');
    const btnRemoteRunCustom = document.getElementById('btn-remote-run-custom');
    const remoteConsoleOutput = document.getElementById('remote-console-output');
    const btnRemoteClearConsole = document.getElementById('btn-remote-clear-console');
    const btnRemoteCopyConsole = document.getElementById('btn-remote-copy-console');
    const remoteExecStatusDot = document.getElementById('remote-exec-status-dot');
    const btnGotoDeviceEdit = document.getElementById('btn-goto-device-edit');

    // Double-Confirmation Modal Elements
    const remoteConfirmModal = document.getElementById('remote-confirm-modal');
    const remoteConfirmDeviceName = document.getElementById('remote-confirm-device-name');
    const remoteConfirmDeviceIp = document.getElementById('remote-confirm-device-ip');
    const remoteConfirmActionText = document.getElementById('remote-confirm-action-text');
    const btnRemoteConfirmCancel = document.getElementById('btn-remote-confirm-cancel');
    const btnRemoteConfirmExecute = document.getElementById('btn-remote-confirm-execute');
    const closeRemoteConfirmBtn = document.getElementById('close-remote-confirm-btn');
    const confirmSafetyCheckbox = document.getElementById('confirm-safety-checkbox');

    let pendingRemoteExecution = null;

    function openRemoteConfirmModal(device, actionText, executionFn) {
        if (!remoteConfirmModal) {
            if (confirm(`【二重確認】対象: ${device.name || device.ip} (${device.ip})\n実行内容: ${actionText}\n実行しますか？`)) {
                executionFn();
            }
            return;
        }
        if (remoteConfirmDeviceName) remoteConfirmDeviceName.textContent = device.name || device.ip;
        if (remoteConfirmDeviceIp) remoteConfirmDeviceIp.textContent = device.ip;
        if (remoteConfirmActionText) remoteConfirmActionText.textContent = actionText;
        // 毎回ユーザー自身にチェックしてもらう (誤クリックでの再起動を防ぐ)
        if (confirmSafetyCheckbox) {
            confirmSafetyCheckbox.checked = false;
        }
        if (btnRemoteConfirmExecute) {
            btnRemoteConfirmExecute.disabled = !!confirmSafetyCheckbox;
            btnRemoteConfirmExecute.style.opacity = confirmSafetyCheckbox ? '0.5' : '1';
            btnRemoteConfirmExecute.style.cursor = confirmSafetyCheckbox ? 'not-allowed' : 'pointer';
        }

        pendingRemoteExecution = executionFn;
        remoteConfirmModal.style.display = 'flex';
        remoteConfirmModal.classList.add('active');
    }

    function closeRemoteConfirmModal() {
        if (remoteConfirmModal) {
            remoteConfirmModal.style.display = 'none';
            remoteConfirmModal.classList.remove('active');
        }
        pendingRemoteExecution = null;
    }

    if (btnRemoteConfirmCancel) {
        btnRemoteConfirmCancel.addEventListener('click', (e) => {
            e.preventDefault();
            closeRemoteConfirmModal();
        });
    }
    if (closeRemoteConfirmBtn) {
        closeRemoteConfirmBtn.addEventListener('click', (e) => {
            e.preventDefault();
            closeRemoteConfirmModal();
        });
    }
    if (remoteConfirmModal) {
        remoteConfirmModal.addEventListener('click', (e) => {
            if (e.target === remoteConfirmModal) {
                closeRemoteConfirmModal();
            }
        });
    }
    if (confirmSafetyCheckbox) {
        confirmSafetyCheckbox.addEventListener('change', () => {
            const isChecked = confirmSafetyCheckbox.checked;
            if (btnRemoteConfirmExecute) {
                btnRemoteConfirmExecute.disabled = !isChecked;
                btnRemoteConfirmExecute.style.opacity = isChecked ? '1' : '0.5';
                btnRemoteConfirmExecute.style.cursor = isChecked ? 'pointer' : 'not-allowed';
            }
        });
    }
    if (btnRemoteConfirmExecute) {
        btnRemoteConfirmExecute.addEventListener('click', (e) => {
            e.preventDefault();
            if (confirmSafetyCheckbox && !confirmSafetyCheckbox.checked) {
                return;
            }
            if (pendingRemoteExecution) {
                const fn = pendingRemoteExecution;
                closeRemoteConfirmModal();
                fn();
            }
        });
    }

    // Clear and Copy Console buttons
    if (btnRemoteClearConsole) {
        btnRemoteClearConsole.addEventListener('click', () => {
            if (remoteConsoleOutput) {
                remoteConsoleOutput.textContent = 'ログをクリアしました。待機中...';
            }
        });
    }
    if (btnRemoteCopyConsole) {
        btnRemoteCopyConsole.addEventListener('click', () => {
            if (remoteConsoleOutput && navigator.clipboard) {
                navigator.clipboard.writeText(remoteConsoleOutput.textContent);
                showToast('info', 'コピー完了', 'コンソールログをクリップボードにコピーしました');
            }
        });
    }

    // Go to device edit from disabled banner
    if (btnGotoDeviceEdit) {
        btnGotoDeviceEdit.addEventListener('click', () => {
            const targetIp = currentSnmpIp;
            closeSnmpModal();
            const manageNavBtn = document.querySelector('[data-view="view-manage"]');
            if (manageNavBtn) manageNavBtn.click();
            setTimeout(() => {
                if (targetIp) {
                    const dev = devices.find(d => d.ip === targetIp);
                    if (dev && typeof openDeviceModal === 'function') {
                        openDeviceModal(dev);
                    } else {
                        const editBtn = document.querySelector(`.edit-dev-btn[data-ip="${targetIp}"]`);
                        if (editBtn) editBtn.click();
                    }
                }
            }, 100);
        });
    }

    // Execute Remote Command API Caller
    async function executeRemoteActionApi(device, params) {
        const nowStr = new Date().toLocaleTimeString();
        const actionDesc = params.action === 'reboot'
            ? '機器の再起動 (Reboot)'
            : (params.customCommand ? `任意コマンド実行: ${params.customCommand}` : `プリセットコマンド実行 (ID: ${params.commandId})`);

        if (remoteExecStatusDot) {
            remoteExecStatusDot.className = 'status-dot';
            remoteExecStatusDot.style.background = '#f59e0b';
        }
        if (btnRemoteReboot) btnRemoteReboot.disabled = true;
        if (btnRemoteExecCmd) btnRemoteExecCmd.disabled = true;
        if (btnRemoteRunCustom) btnRemoteRunCustom.disabled = true;

        if (remoteConsoleOutput) {
            remoteConsoleOutput.textContent += `\n[${nowStr}] 実行中: ${actionDesc} (タイムアウト: 15秒)...\n`;
            remoteConsoleOutput.scrollTop = remoteConsoleOutput.scrollHeight;
        }

        try {
            const payload = {
                ip: device.ip,
                action: params.action,
                commandId: params.commandId || undefined,
                customCommand: params.customCommand || undefined,
                timeoutSec: 15
            };

            const res = await fetch('/api/device/remote-exec', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            });
            const data = await res.json();
            const finishTime = data.timestamp || new Date().toLocaleTimeString();

            if (res.ok && data.success) {
                if (remoteExecStatusDot) {
                    remoteExecStatusDot.className = 'status-dot success';
                    remoteExecStatusDot.style.background = '#10b981';
                }
                if (remoteConsoleOutput) {
                    remoteConsoleOutput.textContent += `[${finishTime}] ✅ 実行成功 (${data.executionTimeMs || 0}ms) - 状態: ${data.status} (終了コード: ${data.exitCode})\n`;
                    if (data.stdout && data.stdout.trim()) {
                        remoteConsoleOutput.textContent += `--- [標準出力 (STDOUT)] ---\n${data.stdout.trim()}\n`;
                    }
                    if (data.stderr && data.stderr.trim()) {
                        remoteConsoleOutput.textContent += `--- [標準エラー (STDERR)] ---\n${data.stderr.trim()}\n`;
                    }
                    remoteConsoleOutput.textContent += `------------------------------------------------------\n`;
                    remoteConsoleOutput.scrollTop = remoteConsoleOutput.scrollHeight;
                }
                showToast('success', 'リモート操作完了', `${device.name || device.ip} の操作が完了しました`);
            } else {
                if (remoteExecStatusDot) {
                    remoteExecStatusDot.className = 'status-dot error';
                    remoteExecStatusDot.style.background = '#ef4444';
                }
                if (remoteConsoleOutput) {
                    remoteConsoleOutput.textContent += `[${finishTime}] ❌ 実行失敗 (${data.executionTimeMs || 0}ms) - 状態: ${data.status || 'FAILED'} (終了コード: ${data.exitCode !== undefined ? data.exitCode : -1})\n`;
                    if (data.error || data.message) {
                        remoteConsoleOutput.textContent += `エラー詳細: ${data.error || data.message}\n`;
                    }
                    if (data.stdout && data.stdout.trim()) {
                        remoteConsoleOutput.textContent += `--- [標準出力 (STDOUT)] ---\n${data.stdout.trim()}\n`;
                    }
                    if (data.stderr && data.stderr.trim()) {
                        remoteConsoleOutput.textContent += `--- [標準エラー (STDERR)] ---\n${data.stderr.trim()}\n`;
                    }
                    remoteConsoleOutput.textContent += `------------------------------------------------------\n`;
                    remoteConsoleOutput.scrollTop = remoteConsoleOutput.scrollHeight;
                }
                showToast('error', 'リモート操作失敗', data.error || data.message || 'コマンド実行がエラーを返しました');
            }
        } catch (err) {
            console.error('Remote execution error:', err);
            if (remoteExecStatusDot) {
                remoteExecStatusDot.className = 'status-dot error';
                remoteExecStatusDot.style.background = '#ef4444';
            }
            if (remoteConsoleOutput) {
                remoteConsoleOutput.textContent += `[${new Date().toLocaleTimeString()}] ❌ 通信エラー: サーバーとの通信に失敗しました (${err.message})\n------------------------------------------------------\n`;
                remoteConsoleOutput.scrollTop = remoteConsoleOutput.scrollHeight;
            }
            showToast('error', '通信エラー', `サーバーとの通信に失敗しました: ${err.message}`);
        } finally {
            if (btnRemoteReboot) btnRemoteReboot.disabled = false;
            if (btnRemoteExecCmd) btnRemoteExecCmd.disabled = false;
            if (btnRemoteRunCustom) btnRemoteRunCustom.disabled = false;
        }
    }

    // Quick Reboot click handler
    if (btnRemoteReboot) {
        btnRemoteReboot.addEventListener('click', (e) => {
            e.preventDefault();
            if (!currentSnmpIp) return;
            const currentDev = devices.find(d => d.ip === currentSnmpIp);
            if (!currentDev || !currentDev.remote || !currentDev.remote.enabled) {
                showToast('warning', '警告', 'この機器はリモート管理が有効になっていません');
                return;
            }
            const rebootCmdText = currentDev.remote.rebootCommand ? `コマンド: ${currentDev.remote.rebootCommand}` : 'プロトコル標準再起動';
            openRemoteConfirmModal(currentDev, `機器の再起動 (Reboot) - ${rebootCmdText}`, () => {
                executeRemoteActionApi(currentDev, { action: 'reboot' });
            });
        });
    }

    // Preset Command Execute click handler
    if (btnRemoteExecCmd) {
        btnRemoteExecCmd.addEventListener('click', (e) => {
            e.preventDefault();
            if (!currentSnmpIp) return;
            const currentDev = devices.find(d => d.ip === currentSnmpIp);
            if (!currentDev || !currentDev.remote || !currentDev.remote.enabled) {
                showToast('warning', '警告', 'この機器はリモート管理が有効になっていません');
                return;
            }
            const cmdId = remoteCmdSelect ? remoteCmdSelect.value : '';
            if (!cmdId) {
                showToast('warning', 'コマンド未選択', '実行するプリセットコマンドを選択してください');
                return;
            }
            const cmdObj = (currentDev.remote.commands || []).find(c => c.id === cmdId);
            const cmdName = cmdObj ? `${cmdObj.name} (${cmdObj.command})` : cmdId;
            openRemoteConfirmModal(currentDev, `登録コマンド実行: ${cmdName}`, () => {
                executeRemoteActionApi(currentDev, { action: 'command', commandId: cmdId });
            });
        });
    }

    // Custom One-off Command Run click handler
    if (btnRemoteRunCustom) {
        btnRemoteRunCustom.addEventListener('click', (e) => {
            e.preventDefault();
            if (!currentSnmpIp) return;
            const currentDev = devices.find(d => d.ip === currentSnmpIp);
            if (!currentDev || !currentDev.remote || !currentDev.remote.enabled) {
                showToast('warning', '警告', 'この機器はリモート管理が有効になっていません');
                return;
            }
            const customCmd = remoteCustomCmdInput ? remoteCustomCmdInput.value.trim() : '';
            if (!customCmd) {
                showToast('warning', 'コマンド未入力', '実行するコマンド文字列を入力してください');
                return;
            }
            openRemoteConfirmModal(currentDev, `任意コマンド実行: ${customCmd}`, () => {
                executeRemoteActionApi(currentDev, { action: 'command', customCommand: customCmd });
            });
        });
    }

    // Populate Remote Tab in SNMP Modal
    function setupRemoteTabForDevice(device) {
        const disabledBanner = document.getElementById('remote-disabled-banner');
        const activePanel = document.getElementById('remote-active-panel');
        const summaryName = document.getElementById('remote-summary-name');
        const summaryIp = document.getElementById('remote-summary-ip');
        const summaryProtocol = document.getElementById('remote-summary-protocol');
        const summaryStatus = document.getElementById('remote-summary-status');
        const summaryPort = document.getElementById('remote-summary-port');
        const summaryUser = document.getElementById('remote-summary-user');

        const isRemoteEnabled = !!(device.remote && device.remote.enabled);

        if (!isRemoteEnabled) {
            if (disabledBanner) disabledBanner.style.display = 'block';
            if (activePanel) activePanel.style.display = 'none';
            return;
        }

        if (disabledBanner) disabledBanner.style.display = 'none';
        if (activePanel) activePanel.style.display = 'flex';

        if (summaryName) summaryName.textContent = device.name || device.ip;
        if (summaryIp) summaryIp.textContent = device.ip;
        if (summaryProtocol) summaryProtocol.textContent = (device.remote.protocol || 'ssh').toUpperCase();
        if (summaryStatus) summaryStatus.textContent = '有効 (Active)';
        if (summaryPort) summaryPort.textContent = device.remote.port || (device.remote.protocol === 'winrm' ? 5985 : 22);
        if (summaryUser) summaryUser.textContent = device.remote.user || '(未指定)';

        // Populate preset commands dropdown
        if (remoteCmdSelect) {
            remoteCmdSelect.innerHTML = '';
            const defaultOpt = document.createElement('option');
            defaultOpt.value = '';
            defaultOpt.textContent = '-- 実行するコマンドを選択してください --';
            remoteCmdSelect.appendChild(defaultOpt);

            const commands = device.remote.commands || [];
            if (commands.length > 0) {
                commands.forEach(c => {
                    const opt = document.createElement('option');
                    opt.value = c.id;
                    opt.textContent = `${c.name || 'コマンド'} (${c.command})`;
                    remoteCmdSelect.appendChild(opt);
                });
            } else {
                const emptyOpt = document.createElement('option');
                emptyOpt.value = '';
                emptyOpt.disabled = true;
                emptyOpt.textContent = '(登録されたカスタムコマンドはありません)';
                remoteCmdSelect.appendChild(emptyOpt);
            }
        }

        // Initialize console message
        if (remoteConsoleOutput) {
            remoteConsoleOutput.textContent = `[待機中] 対象機器: ${device.name || device.ip} (${device.ip}) - コマンドを選択または再起動ボタンを押してください。`;
        }
        if (remoteExecStatusDot) {
            remoteExecStatusDot.className = 'status-dot';
            remoteExecStatusDot.style.background = '#94a3b8';
        }
    }

    // =========================================================================
    // 9. Milestone 2: Device Log Retrieval & Console Viewer Logic
    // =========================================================================
    const DEVICE_LOG_PRESETS = [
        { id: "cisco_show_logging", name: "Cisco / ネットワーク機器: show logging", command: "show logging" },
        { id: "yamaha_show_log", name: "Yamaha ルーター: show log", command: "show log" },
        { id: "linux_journalctl", name: "Linux: journalctl (直近200行)", command: "journalctl -n 200 --no-pager" },
        { id: "linux_dmesg", name: "Linux: カーネルメッセージ (dmesg)", command: "dmesg -T | tail -n 200" },
        { id: "linux_syslog", name: "Linux: システムログ (/var/log/syslog)", command: "tail -n 200 /var/log/syslog" },
        { id: "windows_winevent_sys", name: "Windows: システムイベントログ (直近100件)", command: "Get-WinEvent -LogName System -MaxEvents 100 | Format-Table TimeCreated, Id, LevelDisplayName, Message -AutoSize | Out-String -Width 4096" },
        { id: "windows_winevent_app", name: "Windows: アプリケーションイベントログ (直近100件)", command: "Get-WinEvent -LogName Application -MaxEvents 100 | Format-Table TimeCreated, Id, LevelDisplayName, Message -AutoSize | Out-String -Width 4096" },
        { id: "custom", name: "カスタムコマンド入力", command: "" }
    ];

    const deviceLogDisabledBanner = document.getElementById('device-log-disabled-banner');
    const deviceLogActivePanel = document.getElementById('device-log-active-panel');
    const btnGotoDeviceEditFromLogs = document.getElementById('btn-goto-device-edit-from-logs');
    const deviceLogProtocolIcon = document.getElementById('device-log-protocol-icon');
    const deviceLogSummaryName = document.getElementById('device-log-summary-name');
    const deviceLogSummaryIp = document.getElementById('device-log-summary-ip');
    const deviceLogSummaryProtocol = document.getElementById('device-log-summary-protocol');
    const deviceLogSummaryStatus = document.getElementById('device-log-summary-status');
    const deviceLogSummaryPort = document.getElementById('device-log-summary-port');
    const deviceLogSummaryUser = document.getElementById('device-log-summary-user');

    const deviceLogPresetSelect = document.getElementById('device-log-preset-select');
    const deviceLogCustomCmd = document.getElementById('device-log-custom-cmd');
    const deviceLogTimeout = document.getElementById('device-log-timeout');
    const deviceLogFetchBtn = document.getElementById('device-log-fetch-btn');
    const deviceLogFetchSpinner = document.getElementById('device-log-fetch-spinner');
    const deviceLogFetchBtnText = document.getElementById('device-log-fetch-btn-text');
    const deviceLogFetchBtnIcon = document.getElementById('device-log-fetch-btn-icon');

    const deviceLogStatusDot = document.getElementById('device-log-status-dot');
    const deviceLogMetaInfo = document.getElementById('device-log-meta-info');
    const deviceLogConsole = document.getElementById('device-log-console');
    const deviceLogSearchInput = document.getElementById('device-log-search-input');
    const deviceLogSearchCount = document.getElementById('device-log-search-count');
    const deviceLogFilterMatchOnly = document.getElementById('device-log-filter-match-only');
    const deviceLogClearBtn = document.getElementById('device-log-clear-btn');
    const deviceLogCopyBtn = document.getElementById('device-log-copy-btn');
    const deviceLogDownloadBtn = document.getElementById('device-log-download-btn');

    const deviceLogHistoryRefreshBtn = document.getElementById('device-log-history-refresh-btn');
    const deviceLogHistoryList = document.getElementById('device-log-history-list');

    let currentDeviceLogRawText = '';
    let currentDeviceLogTimestamp = '';
    let currentDeviceLogIp = '';
    let isFetchingDeviceLog = false;

    // Helper: format bytes for log size
    function formatLogBytes(bytes) {
        if (!bytes || bytes <= 0) return '0 B';
        if (bytes >= 1048576) return (bytes / 1048576).toFixed(2) + ' MB';
        if (bytes >= 1024) return (bytes / 1024).toFixed(1) + ' KB';
        return bytes + ' B';
    }

    // Populate Device Logs Tab in SNMP Modal
    function setupDeviceLogTabForDevice(device) {
        if (!device) return;
        currentDeviceLogIp = device.ip;

        const isRemoteEnabled = !!(device.remote && device.remote.enabled);

        if (!isRemoteEnabled) {
            if (deviceLogDisabledBanner) deviceLogDisabledBanner.style.display = 'block';
            if (deviceLogActivePanel) deviceLogActivePanel.style.display = 'none';
            return;
        }

        if (deviceLogDisabledBanner) deviceLogDisabledBanner.style.display = 'none';
        if (deviceLogActivePanel) deviceLogActivePanel.style.display = 'flex';

        const proto = ((device.remote && device.remote.protocol) || 'ssh').toLowerCase();

        if (deviceLogSummaryName) deviceLogSummaryName.textContent = device.name || device.ip;
        if (deviceLogSummaryIp) deviceLogSummaryIp.textContent = device.ip;
        if (deviceLogSummaryProtocol) deviceLogSummaryProtocol.textContent = proto.toUpperCase();
        if (deviceLogSummaryStatus) deviceLogSummaryStatus.textContent = '有効 (Active)';
        if (deviceLogSummaryPort) deviceLogSummaryPort.textContent = (device.remote && device.remote.port) || (proto === 'winrm' ? 5985 : 22);
        if (deviceLogSummaryUser) deviceLogSummaryUser.textContent = (device.remote && device.remote.user) || '(未指定)';

        if (deviceLogProtocolIcon) {
            deviceLogProtocolIcon.textContent = proto === 'winrm' ? '🖥️' : (proto === 'custom' ? '🛠️' : '⚡');
        }

        // Set default preset based on protocol / device characteristics
        if (deviceLogPresetSelect) {
            let defaultPresetId = 'cisco_show_logging';
            if (proto === 'winrm') {
                defaultPresetId = 'windows_winevent_sys';
            } else {
                const nameLower = (device.name || '').toLowerCase();
                if (nameLower.includes('yamaha') || nameLower.includes('rtx')) {
                    defaultPresetId = 'yamaha_show_log';
                } else if (nameLower.includes('linux') || nameLower.includes('ubuntu') || nameLower.includes('debian') || nameLower.includes('centos')) {
                    defaultPresetId = 'linux_journalctl';
                }
            }
            deviceLogPresetSelect.value = defaultPresetId;
            const matched = DEVICE_LOG_PRESETS.find(p => p.id === defaultPresetId);
            if (deviceLogCustomCmd) {
                deviceLogCustomCmd.value = matched ? matched.command : 'show logging';
            }
        }

        // Initialize status and console if empty or changed target
        if (deviceLogStatusDot) {
            deviceLogStatusDot.className = 'status-dot';
            deviceLogStatusDot.style.background = '#94a3b8';
        }

        // Reset console for this device if not currently loaded
        if (!currentDeviceLogRawText || currentDeviceLogIp !== device.ip) {
            currentDeviceLogRawText = '';
            currentDeviceLogTimestamp = '';
            if (deviceLogConsole) {
                deviceLogConsole.textContent = `待機中... 対象機器: ${device.name || device.ip} (${device.ip})\n「今すぐログを取得」ボタンを押すと、機器から取得したログがここに表示されます。`;
            }
            if (deviceLogMetaInfo) deviceLogMetaInfo.textContent = '';
            if (deviceLogSearchCount) deviceLogSearchCount.textContent = '';
        }

        // Load historical logs
        loadDeviceLogHistory(device.ip);
    }

    // Go to device edit from logs banner
    if (btnGotoDeviceEditFromLogs) {
        btnGotoDeviceEditFromLogs.addEventListener('click', () => {
            const targetIp = currentDeviceLogIp || currentSnmpIp;
            closeSnmpModal();
            const manageNavBtn = document.querySelector('[data-view="view-manage"]');
            if (manageNavBtn) manageNavBtn.click();
            setTimeout(() => {
                if (targetIp) {
                    const dev = devices.find(d => d.ip === targetIp);
                    if (dev && typeof openDeviceModal === 'function') {
                        openDeviceModal(dev);
                    } else {
                        const editBtn = document.querySelector(`.edit-dev-btn[data-ip="${targetIp}"]`);
                        if (editBtn) editBtn.click();
                    }
                }
            }, 100);
        });
    }

    // Preset selection change listener
    if (deviceLogPresetSelect) {
        deviceLogPresetSelect.addEventListener('change', () => {
            const presetId = deviceLogPresetSelect.value;
            const preset = DEVICE_LOG_PRESETS.find(p => p.id === presetId);
            if (preset && preset.id !== 'custom') {
                if (deviceLogCustomCmd) {
                    deviceLogCustomCmd.value = preset.command;
                }
            }
        });
    }

    // Custom command input change listener
    if (deviceLogCustomCmd) {
        deviceLogCustomCmd.addEventListener('input', () => {
            const val = deviceLogCustomCmd.value.trim();
            const matched = DEVICE_LOG_PRESETS.find(p => p.id !== 'custom' && p.command.trim() === val);
            if (matched) {
                if (deviceLogPresetSelect) deviceLogPresetSelect.value = matched.id;
            } else {
                if (deviceLogPresetSelect) deviceLogPresetSelect.value = 'custom';
            }
        });
    }

    // Render Monospace Console with safe keyword search & match highlight
    function renderDeviceLogConsole() {
        if (!deviceLogConsole) return;
        if (!currentDeviceLogRawText) {
            deviceLogConsole.textContent = '待機中... 「今すぐログを取得」ボタンを押すと、対象機器から取得したログがここに表示されます。';
            if (deviceLogSearchCount) deviceLogSearchCount.textContent = '';
            return;
        }

        const searchQuery = deviceLogSearchInput ? deviceLogSearchInput.value.trim() : '';
        const filterMatchOnly = deviceLogFilterMatchOnly ? deviceLogFilterMatchOnly.checked : false;

        const rawLines = currentDeviceLogRawText.split(/\r?\n/);
        let matchedLinesCount = 0;
        let totalMatches = 0;

        if (!searchQuery) {
            // No search query: render all lines safely escaped
            deviceLogConsole.innerHTML = rawLines.map(line => escapeHTML(line)).join('\n');
            if (deviceLogSearchCount) {
                deviceLogSearchCount.textContent = `${rawLines.length} 行`;
            }
            return;
        }

        // Search query active: prepare safe regex for match detection
        const safeQuery = searchQuery.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        const reg = new RegExp(`(${safeQuery})`, 'gi');

        const filteredLines = [];
        for (let i = 0; i < rawLines.length; i++) {
            const line = rawLines[i];
            const lineMatches = line.match(reg);
            if (lineMatches && lineMatches.length > 0) {
                matchedLinesCount++;
                totalMatches += lineMatches.length;
                // Split the RAW line (capturing group keeps matches at odd indexes), then escape each part.
                // Matching on escaped HTML would hit inside entities like &amp; and break the markup.
                filteredLines.push(line.split(reg).map((part, idx) =>
                    idx % 2 === 1 ? `<mark class="log-search-match">${escapeHTML(part)}</mark>` : escapeHTML(part)
                ).join(''));
            } else if (!filterMatchOnly) {
                filteredLines.push(escapeHTML(line));
            }
        }

        if (filteredLines.length === 0) {
            deviceLogConsole.innerHTML = '<span style="color:var(--text-muted);">(一致する行がありません)</span>';
        } else {
            deviceLogConsole.innerHTML = filteredLines.join('\n');
        }

        if (deviceLogSearchCount) {
            deviceLogSearchCount.textContent = `${totalMatches} 件一致 (${matchedLinesCount} 行)`;
        }
    }

    // Keyword Search and Match-only filter input listeners
    if (deviceLogSearchInput) {
        deviceLogSearchInput.addEventListener('input', () => {
            renderDeviceLogConsole();
        });
    }
    if (deviceLogFilterMatchOnly) {
        deviceLogFilterMatchOnly.addEventListener('change', () => {
            renderDeviceLogConsole();
        });
    }

    // Clear Console Button
    if (deviceLogClearBtn) {
        deviceLogClearBtn.addEventListener('click', () => {
            currentDeviceLogRawText = '';
            currentDeviceLogTimestamp = '';
            if (deviceLogConsole) {
                deviceLogConsole.textContent = 'ログをクリアしました。待機中...';
            }
            if (deviceLogMetaInfo) deviceLogMetaInfo.textContent = '';
            if (deviceLogSearchCount) deviceLogSearchCount.textContent = '';
            if (deviceLogStatusDot) {
                deviceLogStatusDot.className = 'status-dot';
                deviceLogStatusDot.style.background = '#94a3b8';
            }
        });
    }

    // Copy Console Button
    if (deviceLogCopyBtn) {
        deviceLogCopyBtn.addEventListener('click', () => {
            const textToCopy = currentDeviceLogRawText || (deviceLogConsole ? deviceLogConsole.textContent : '');
            if (!textToCopy || !textToCopy.trim()) {
                showToast('warning', 'ログなし', 'コピーするログデータがありません');
                return;
            }
            if (navigator.clipboard) {
                navigator.clipboard.writeText(textToCopy).then(() => {
                    showToast('info', 'コピー完了', 'ログテキストをクリップボードにコピーしました');
                }).catch(err => {
                    console.error('Copy failed:', err);
                    showToast('warning', 'コピー失敗', 'クリップボードへのアクセスが拒否されました');
                });
            } else {
                showToast('warning', '未対応', 'お使いのブラウザはクリップボード操作に対応していません');
            }
        });
    }

    // Download Console Log as Client-Side Blob (.log / .txt)
    if (deviceLogDownloadBtn) {
        deviceLogDownloadBtn.addEventListener('click', () => {
            const blobContent = currentDeviceLogRawText || (deviceLogConsole ? deviceLogConsole.textContent : '');
            if (!blobContent || !blobContent.trim()) {
                showToast('warning', 'ログなし', '保存するログデータがありません');
                return;
            }

            try {
                const blob = new Blob([blobContent], { type: 'text/plain;charset=utf-8' });
                const url = URL.createObjectURL(blob);
                const a = document.createElement('a');
                const safeIp = (currentDeviceLogIp || 'device').replace(/[:.]/g, '_');
                const tsStr = (currentDeviceLogTimestamp || new Date().toISOString()).replace(/[^0-9]/g, '_').slice(0, 15);
                a.href = url;
                a.download = `${safeIp}_${tsStr}.log`;
                document.body.appendChild(a);
                a.click();
                document.body.removeChild(a);
                URL.revokeObjectURL(url);
                showToast('success', 'ダウンロード開始', 'ログファイルを保存しました');
            } catch (err) {
                console.error('Blob download error:', err);
                showToast('error', '保存エラー', `ログのダウンロードに失敗しました: ${err.message}`);
            }
        });
    }

    // Fetch Log Execution Button Click Listener
    if (deviceLogFetchBtn) {
        deviceLogFetchBtn.addEventListener('click', async (e) => {
            e.preventDefault();
            if (isFetchingDeviceLog) return;

            const targetIp = currentDeviceLogIp || currentSnmpIp;
            if (!targetIp) {
                showToast('warning', '対象未選択', '機器が選択されていません');
                return;
            }

            const currentDev = devices.find(d => d.ip === targetIp);
            if (!currentDev || !currentDev.remote || !currentDev.remote.enabled) {
                showToast('warning', '警告', 'この機器はリモート管理が有効になっていません');
                return;
            }

            const presetId = deviceLogPresetSelect ? deviceLogPresetSelect.value : 'custom';
            const customCmd = deviceLogCustomCmd ? deviceLogCustomCmd.value.trim() : '';
            if (!customCmd && presetId === 'custom') {
                showToast('warning', 'コマンド未入力', '実行するログ取得コマンドを入力してください');
                return;
            }

            const timeoutSec = deviceLogTimeout ? (parseInt(deviceLogTimeout.value, 10) || 30) : 30;

            // UI state: fetching
            isFetchingDeviceLog = true;
            if (deviceLogFetchBtn) deviceLogFetchBtn.disabled = true;
            if (deviceLogFetchSpinner) deviceLogFetchSpinner.classList.remove('hidden');
            if (deviceLogFetchBtnText) deviceLogFetchBtnText.textContent = 'ログ取得中...';
            if (deviceLogStatusDot) {
                deviceLogStatusDot.className = 'status-dot';
                deviceLogStatusDot.style.background = '#f59e0b';
            }

            const startTime = Date.now();
            const nowStr = new Date().toLocaleTimeString();

            if (deviceLogConsole) {
                deviceLogConsole.textContent = `[${nowStr}] 🚀 ログ取得を開始しました (コマンド: "${customCmd || presetId}", タイムアウト: ${timeoutSec}秒)...\n通信中...`;
            }

            try {
                const res = await fetch('/api/device/fetch-log', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        ip: targetIp,
                        presetId: presetId,
                        customCommand: customCmd,
                        timeoutSec: timeoutSec
                    })
                });

                const data = await res.json();
                const duration = data.durationMs || (Date.now() - startTime);

                if (res.ok && data.success) {
                    if (deviceLogStatusDot) {
                        deviceLogStatusDot.className = 'status-dot success';
                        deviceLogStatusDot.style.background = '#10b981';
                    }
                    currentDeviceLogRawText = data.stdout || '';
                    currentDeviceLogTimestamp = data.timestamp || new Date().toISOString();

                    if (deviceLogMetaInfo) {
                        const sizeStr = formatLogBytes(data.sizeBytes);
                        deviceLogMetaInfo.textContent = `所要時間: ${duration}ms | 行数: ${data.lineCount}行 | サイズ: ${sizeStr}${data.truncated ? ' (1MB超過のため表示切詰)' : ''}`;
                    }

                    renderDeviceLogConsole();
                    if (deviceLogConsole) {
                        deviceLogConsole.scrollTop = deviceLogConsole.scrollHeight;
                    }

                    showToast('success', 'ログ取得成功', `${currentDev.name || targetIp} から ${data.lineCount} 行のログを取得しました`);

                    // Refresh history list
                    loadDeviceLogHistory(targetIp);
                } else {
                    if (deviceLogStatusDot) {
                        deviceLogStatusDot.className = 'status-dot error';
                        deviceLogStatusDot.style.background = '#ef4444';
                    }
                    const errMsg = data.error || (data.status === 'TIMEOUT' ? `タイムアウト (${timeoutSec}秒) を超過しました` : 'ログ取得に失敗しました');

                    if (data.stdout && data.stdout.trim()) {
                        currentDeviceLogRawText = data.stdout;
                        currentDeviceLogTimestamp = data.timestamp || new Date().toISOString();
                        renderDeviceLogConsole();
                    } else if (deviceLogConsole) {
                        deviceLogConsole.textContent = `[${nowStr}] ❌ ログ取得失敗 (${duration}ms)\nステータス: ${data.status || 'ERROR'}\nエラー詳細: ${errMsg}\n${data.stderr ? `\n--- [標準エラー] ---\n${data.stderr}` : ''}`;
                    }

                    if (deviceLogMetaInfo) {
                        deviceLogMetaInfo.textContent = `エラー: ${data.status || 'FAILED'} (${duration}ms)`;
                    }

                    showToast('error', 'ログ取得失敗', errMsg);
                }
            } catch (err) {
                console.error('Fetch log request failed:', err);
                if (deviceLogStatusDot) {
                    deviceLogStatusDot.className = 'status-dot error';
                    deviceLogStatusDot.style.background = '#ef4444';
                }
                if (deviceLogConsole) {
                    deviceLogConsole.textContent = `[${nowStr}] ❌ 通信エラー: サーバーとの通信に失敗しました (${err.message})`;
                }
                showToast('error', '通信エラー', `サーバーとの通信に失敗しました: ${err.message}`);
            } finally {
                isFetchingDeviceLog = false;
                if (deviceLogFetchBtn) deviceLogFetchBtn.disabled = false;
                if (deviceLogFetchSpinner) deviceLogFetchSpinner.classList.add('hidden');
                if (deviceLogFetchBtnText) deviceLogFetchBtnText.textContent = '今すぐログを取得';
            }
        });
    }

    // Historical Logs Loader
    async function loadDeviceLogHistory(ip) {
        if (!deviceLogHistoryList) return;
        if (!ip) {
            deviceLogHistoryList.innerHTML = '<div style="color:var(--text-muted); text-align:center; padding:12px;">機器が選択されていません</div>';
            return;
        }

        try {
            const res = await fetch(`/api/device/logs?ip=${encodeURIComponent(ip)}`);
            if (!res.ok) {
                deviceLogHistoryList.innerHTML = '<div style="color:var(--text-muted); text-align:center; padding:12px;">履歴の取得に失敗しました</div>';
                return;
            }
            const data = await res.json();
            const logs = data.logs || [];

            if (logs.length === 0) {
                deviceLogHistoryList.innerHTML = '<div style="color:var(--text-muted); text-align:center; padding:12px;">保存された過去ログはありません</div>';
                return;
            }

            let html = '';
            logs.forEach(log => {
                const safeFileName = escapeHTML(log.fileName);
                const safeTimestamp = escapeHTML(log.timestamp || '-');
                const safeSize = escapeHTML(log.sizeFormatted || formatLogBytes(log.sizeBytes));
                const lineCount = log.lineCount !== undefined ? log.lineCount : '-';

                html += `
                    <div class="device-log-history-item">
                        <div class="device-log-history-meta">
                            <div class="device-log-history-title">
                                <span>📄</span>
                                <span style="font-family:'Cascadia Code', Consolas, monospace; font-size:0.8rem;">${safeFileName}</span>
                            </div>
                            <div class="device-log-history-sub">
                                <span>取得日時: ${safeTimestamp}</span> | 
                                <span>サイズ: ${safeSize}</span> | 
                                <span>行数: ${lineCount}行</span>
                            </div>
                        </div>
                        <div class="device-log-history-actions">
                            <button class="btn secondary-btn small btn-preview-log" data-filename="${safeFileName}" type="button" title="このログをビューワーに読み込み">👁️ プレビュー</button>
                            <a class="btn secondary-btn small" href="/api/device/log-download?file=${encodeURIComponent(log.fileName)}" download="${safeFileName}" title="ファイルをダウンロード">💾 ダウンロード</a>
                        </div>
                    </div>
                `;
            });
            deviceLogHistoryList.innerHTML = html;

            // Wire up Preview buttons
            const previewBtns = deviceLogHistoryList.querySelectorAll('.btn-preview-log');
            previewBtns.forEach(btn => {
                btn.addEventListener('click', async () => {
                    const fileName = btn.getAttribute('data-filename');
                    if (!fileName) return;

                    btn.disabled = true;
                    const origText = btn.textContent;
                    btn.textContent = '読込中...';

                    try {
                        const dlRes = await fetch(`/api/device/log-download?file=${encodeURIComponent(fileName)}`);
                        if (dlRes.ok) {
                            const text = await dlRes.text();
                            currentDeviceLogRawText = text;
                            currentDeviceLogTimestamp = fileName;
                            if (deviceLogMetaInfo) {
                                deviceLogMetaInfo.textContent = `プレビュー読込: ${fileName} (${formatLogBytes(text.length)})`;
                            }
                            if (deviceLogStatusDot) {
                                deviceLogStatusDot.className = 'status-dot success';
                                deviceLogStatusDot.style.background = '#10b981';
                            }
                            renderDeviceLogConsole();
                            if (deviceLogConsole) {
                                deviceLogConsole.scrollTop = 0;
                                deviceLogConsole.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
                            }
                            showToast('info', 'プレビュー表示', `${fileName} を読み込みました`);
                        } else {
                            showToast('error', '読込失敗', `ログファイル ${fileName} を取得できませんでした`);
                        }
                    } catch (err) {
                        console.error('Log preview fetch error:', err);
                        showToast('error', '読込エラー', err.message);
                    } finally {
                        btn.disabled = false;
                        btn.textContent = origText;
                    }
                });
            });

        } catch (err) {
            console.error('Load device log history error:', err);
            deviceLogHistoryList.innerHTML = `<div style="color:var(--text-muted); text-align:center; padding:12px;">履歴読み込みエラー: ${escapeHTML(err.message)}</div>`;
        }
    }

    // Historical Logs Refresh Button
    if (deviceLogHistoryRefreshBtn) {
        deviceLogHistoryRefreshBtn.addEventListener('click', () => {
            const targetIp = currentDeviceLogIp || currentSnmpIp;
            if (targetIp) {
                loadDeviceLogHistory(targetIp);
                showToast('info', '更新', 'ログ履歴を再読み込みしました');
            }
        });
    }
});
