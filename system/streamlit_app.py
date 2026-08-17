"""
Network Device Monitor & Diagnostic Tool - Streamlit Live SPA Edition
バッチファイル起動時と完全に同一のオリジナル HTML/CSS/JS SPA 画面をフルスクリーン埋め込み表示
"""

import json
import os
import streamlit as st
import streamlit.components.v1 as components

# ==========================================
# Page Configuration
# ==========================================
st.set_page_config(
    page_title="ネットワーク機器監視システム | Network Device Monitor",
    page_icon="🌐",
    layout="wide",
    initial_sidebar_state="collapsed"
)

# Hide Streamlit default headers, footer, and padding for true full-screen experience
st.markdown("""
<style>
    /* Remove default Streamlit top/bottom padding */
    .block-container {
        padding-top: 0rem !important;
        padding-bottom: 0rem !important;
        padding-left: 0rem !important;
        padding-right: 0rem !important;
        max-width: 100% !important;
    }
    header[data-testid="stHeader"] {
        display: none !important;
    }
    footer {
        display: none !important;
    }
    #MainMenu {
        visibility: hidden !important;
    }
    iframe {
        border: none !important;
        width: 100% !important;
        min-height: 100vh !important;
    }
</style>
""", unsafe_allow_html=True)


# ==========================================
# Load and Bundle Assets
# ==========================================
@st.cache_data
def build_bundled_html():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    public_dir = os.path.join(base_dir, "public")
    if not os.path.exists(public_dir):
        public_dir = os.path.join(base_dir, "system", "public")
        
    devices_path = os.path.join(base_dir, "devices.json")
    if not os.path.exists(devices_path):
        devices_path = os.path.join(base_dir, "system", "devices.json")
        
    # Read HTML, CSS, and JS files
    with open(os.path.join(public_dir, "index.html"), "r", encoding="utf-8") as f:
        html_content = f.read()
        
    with open(os.path.join(public_dir, "style.css"), "r", encoding="utf-8") as f:
        css_content = f.read()
        
    with open(os.path.join(public_dir, "chart.js"), "r", encoding="utf-8") as f:
        chart_js = f.read()
        
    with open(os.path.join(public_dir, "vis-network.min.js"), "r", encoding="utf-8") as f:
        vis_js = f.read()
        
    with open(os.path.join(public_dir, "app.js"), "r", encoding="utf-8") as f:
        app_js = f.read()
        
    raw_devices = "[]"
    if os.path.exists(devices_path):
        with open(devices_path, "r", encoding="utf-8") as f:
            raw_devices = f.read()

    # Raw Mock API script template (using standard replace to prevent Python f-string brace syntax issues)
    mock_api_template = """
    <script>
    // ==============================================================
    // Network Device Monitor - Demo Mock API Layer (Streamlit Cloud)
    // ==============================================================
    (function() {
        console.log("🌐 Network Device Monitor - Demo Mock API Layer Initialized");
        
        let loadedDevices = __RAW_DEVICES_JSON__;
        if (!Array.isArray(loadedDevices) || loadedDevices.length === 0) {
            loadedDevices = [
                {"name": "2D用IPDecoder", "ip": "192.168.10.14", "group": "操作側", "x": 1034, "y": -128, "image": "decoder", "connectedTo": ""},
                {"name": "3D用IPDecoder", "ip": "192.168.10.13", "group": "操作側", "x": 1035, "y": 132, "image": "decoder", "connectedTo": ""},
                {"name": "RBTリモコン", "ip": "192.168.10.12", "group": "操作側", "x": 941, "y": -178, "image": "controller", "connectedTo": "192.168.10.35"},
                {"name": "AP800", "ip": "192.168.10.35", "group": "操作側", "x": 777, "y": -108, "image": "ap", "connectedTo": "192.168.10.13"},
                {"name": "OAP2(infra側)", "ip": "192.168.10.23", "group": "サイト側", "x": 604, "y": 149, "image": "ap", "connectedTo": "192.168.10.13,192.168.10.14"},
                {"name": "カメラ2", "ip": "192.168.10.11", "group": "サイト側", "x": 725, "y": -152, "image": "camera", "connectedTo": "192.168.10.23"},
                {"name": "PLC(サイト側)", "ip": "192.168.10.1", "group": "サイト側", "x": 520, "y": -30, "image": "server", "connectedTo": "192.168.10.23"},
                {"name": "スイッチハブ", "ip": "192.168.10.254", "group": "ネットワーク", "x": 800, "y": 0, "image": "switch", "connectedTo": ""}
            ];
        }
        
        // Ensure all devices are active (enabled = true) by default in demo
        loadedDevices.forEach(d => {
            d.enabled = true;
            if (!d.group) d.group = "その他";
        });

        let config = {
            threshLatency: 100,
            threshBandwidth: 10,
            pingDataSize: 1,
            pollInterval: 1000,
            highfreqMode: false,
            highfreqTargets: [],
            outageThresholds: [600, 5000],
            enableLogging: true,
            enableWebhook: false,
            enableAudio: false
        };
        
        let historyState = {};
        loadedDevices.forEach(d => {
            historyState[d.ip] = {
                status: "Success",
                latency: +(Math.random() * 6 + 1.5).toFixed(1),
                jitter: +(Math.random() * 0.8 + 0.1).toFixed(2),
                packetLoss: 0,
                outages: [0, 0]
            };
        });

        let iperfRunning = false;
        let iperfStartTime = 0;
        let iperfDuration = 5;
        let iperfTargetIp = "";
        let iperfOutput = "";
        let iperfIntervalTimer = null;

        const originalFetch = window.fetch;
        window.fetch = async function(url, options = {}) {
            const urlStr = typeof url === 'string' ? url : (url.url || '');
            const urlObj = new URL(urlStr, window.location.href);
            const path = urlObj.pathname;
            const method = (options.method || 'GET').toUpperCase();

            // 1. GET /api/devices
            if (path === '/api/devices' && method === 'GET') {
                return new Response(JSON.stringify({ devices: loadedDevices }), {
                    status: 200,
                    headers: { 'Content-Type': 'application/json' }
                });
            }

            // 2. GET /api/config
            if (path === '/api/config' && method === 'GET') {
                return new Response(JSON.stringify(config), {
                    status: 200,
                    headers: { 'Content-Type': 'application/json' }
                });
            }

            // 3. GET /api/status
            if (path === '/api/status' && method === 'GET') {
                const resultStatus = {};
                const now = new Date();
                const ts = now.toTimeString().split(' ')[0];
                
                loadedDevices.forEach((d, idx) => {
                    if (d.enabled === false) {
                        resultStatus[d.ip] = {
                            status: "Paused",
                            latency: "-",
                            timestamp: ts,
                            bandwidth: "-",
                            tx: "-",
                            rx: "-",
                            packetLossRate: 0.0,
                            jitter: 0.0,
                            outage600msCount: 0,
                            outage5sCount: 0,
                            maxOutageSec: 0,
                            currentOutageSec: 0
                        };
                        return;
                    }

                    const stObj = historyState[d.ip] || { latency: 3.5, packetLoss: 0, jitter: 0.3 };
                    let lat = Math.max(0.5, +(stObj.latency + (Math.random() * 1.6 - 0.8)).toFixed(1));
                    let loss = Math.random() < 0.01 ? 5.0 : 0.0;
                    let status = "Success";

                    stObj.latency = lat;
                    stObj.packetLoss = loss;
                    stObj.status = status;
                    stObj.jitter = +(Math.abs(Math.random() * 0.9 + 0.1)).toFixed(2);
                    
                    const txMb = (Math.random() * 3.5 + 0.5).toFixed(1);
                    const rxMb = (Math.random() * 6.0 + 1.2).toFixed(1);

                    resultStatus[d.ip] = {
                        status: status,
                        latency: lat,
                        timestamp: ts,
                        bandwidth: "100 Mbps",
                        tx: `${txMb} MB/s`,
                        rx: `${rxMb} MB/s`,
                        packetLossRate: loss,
                        jitter: stObj.jitter,
                        outage600msCount: 0,
                        outage5sCount: 0,
                        maxOutageSec: 0,
                        currentOutageSec: 0
                    };
                });

                // Include _iperf status state
                resultStatus["_iperf"] = {
                    running: iperfRunning,
                    output: iperfOutput,
                    targetIp: iperfTargetIp,
                    targetPort: 5201,
                    duration: iperfDuration
                };

                return new Response(JSON.stringify(resultStatus), {
                    status: 200,
                    headers: { 'Content-Type': 'application/json' }
                });
            }

            // 4. /api/iperf
            if (path === '/api/iperf') {
                const action = urlObj.searchParams.get('action');
                if (action === 'start') {
                    iperfTargetIp = urlObj.searchParams.get('ip') || '192.168.10.14';
                    iperfDuration = parseInt(urlObj.searchParams.get('t') || '5', 10);
                    iperfRunning = true;
                    iperfStartTime = Date.now();
                    iperfOutput = "Starting iperf3...\\nConnecting to host " + iperfTargetIp + ", port 5201\\n[  5] local 192.168.10.100 port 54321 connected to " + iperfTargetIp + " port 5201\\n[ ID] Interval           Transfer     Bitrate\\n";
                    
                    let curSec = 0;
                    if (iperfIntervalTimer) clearInterval(iperfIntervalTimer);
                    iperfIntervalTimer = setInterval(() => {
                        curSec++;
                        const speed = +(Math.random() * 80 + 880).toFixed(2);
                        const trans = +(speed / 8).toFixed(1);
                        const nowTs = new Date().toTimeString().split(' ')[0];
                        iperfOutput += "[" + nowTs + "] [  5]   " + (curSec-1) + ".00-" + curSec + ".00   sec   " + trans + " MBytes   " + speed + " Mbits/sec\\n";
                        if (curSec >= iperfDuration) {
                            clearInterval(iperfIntervalTimer);
                            iperfRunning = false;
                            const avgSpeed = 912.45;
                            iperfOutput += "[" + nowTs + "] - - - - - - - - - - - - - - - - - - - - - - - - -\\n";
                            iperfOutput += "[" + nowTs + "] [  5]   0.00-" + iperfDuration + ".00   sec   " + (+(avgSpeed*iperfDuration/8).toFixed(1)) + " MBytes   " + avgSpeed + " Mbits/sec   sender\\n";
                            iperfOutput += "=== iperf3 Finished at " + new Date().toLocaleString('ja-JP') + " ===\\n";
                        }
                    }, 1000);

                    return new Response(JSON.stringify({ status: "started", command: "iperf3 -c " + iperfTargetIp + " -t " + iperfDuration + " -i 1 --forceflush" }), {
                        status: 200,
                        headers: { 'Content-Type': 'application/json' }
                    });
                }
                if (action === 'status') {
                    return new Response(JSON.stringify({
                        status: "success",
                        running: iperfRunning,
                        output: iperfOutput,
                        command: "iperf3 -c " + iperfTargetIp + " -t " + iperfDuration + " -i 1 --forceflush"
                    }), {
                        status: 200,
                        headers: { 'Content-Type': 'application/json' }
                    });
                }
                if (action === 'stop') {
                    if (iperfIntervalTimer) clearInterval(iperfIntervalTimer);
                    iperfRunning = false;
                    return new Response(JSON.stringify({ status: "stopping" }), { status: 200, headers: { 'Content-Type': 'application/json' } });
                }
            }

            // 5. POST /api/device/toggle
            if (path === '/api/device/toggle' && method === 'POST') {
                try {
                    const body = typeof options.body === 'string' ? JSON.parse(options.body) : options.body;
                    const dev = loadedDevices.find(d => d.ip === body.ip);
                    if (dev) { dev.enabled = body.enabled; }
                } catch(e) {}
                return new Response(JSON.stringify({ status: "success" }), { status: 200, headers: { 'Content-Type': 'application/json' } });
            }

            // 6. POST /api/config
            if (path === '/api/config' && method === 'POST') {
                try {
                    const body = typeof options.body === 'string' ? JSON.parse(options.body) : options.body;
                    config = { ...config, ...body };
                } catch(e) {}
                return new Response(JSON.stringify({ status: "success" }), { status: 200, headers: { 'Content-Type': 'application/json' } });
            }

            // 7. SNMP details
            if (path === '/api/snmp') {
                return new Response(JSON.stringify({
                    status: "success",
                    sysDescr: "Cisco IOS Software, C2960 Software (C2960-LANBASEK9-M), Version 15.0(2)SE4",
                    sysUpTime: "128 days, 14:32:10",
                    sysName: "Core-Switch-01",
                    cpuUsage: Math.floor(Math.random() * 20 + 15),
                    memUsage: Math.floor(Math.random() * 15 + 45),
                    interfaces: [
                        { name: "GigabitEthernet0/1", status: "up", speed: "1 Gbps", inOctets: "145.2 GB", outOctets: "210.8 GB" },
                        { name: "GigabitEthernet0/2", status: "up", speed: "1 Gbps", inOctets: "88.4 GB", outOctets: "95.1 GB" },
                        { name: "GigabitEthernet0/3", status: "down", speed: "100 Mbps", inOctets: "0 B", outOctets: "0 B" }
                    ]
                }), {
                    status: 200,
                    headers: { 'Content-Type': 'application/json' }
                });
            }

            // Fallback for other requests
            try {
                return await originalFetch(url, options);
            } catch (e) {
                return new Response(JSON.stringify({ status: "success" }), { status: 200, headers: { 'Content-Type': 'application/json' } });
            }
        };
    })();
    </script>
    """

    mock_api_js = mock_api_template.replace("__RAW_DEVICES_JSON__", raw_devices)

    # Inject Inline CSS into head
    html_content = html_content.replace(
        '<link rel="stylesheet" href="style.css?v=33">',
        f'<style>\n{css_content}\n</style>'
    )

    # Wrap app.js to ensure execution even if DOMContentLoaded already fired in iframe
    app_js_executable = app_js.replace(
        "document.addEventListener('DOMContentLoaded', () => {",
        "function __initAppMain__() {"
    )
    app_js_executable += """
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', __initAppMain__);
    } else {
        __initAppMain__();
    }
    """
    
    # Inject Inline Libraries & Mock API & Executable App JS
    injected_scripts = f"""
    <script>{chart_js}</script>
    <script>{vis_js}</script>
    {mock_api_js}
    <script>{app_js_executable}</script>
    """
    
    # Replace external script tags with bundled inline code
    html_content = html_content.replace('<script src="chart.js"></script>', '')
    html_content = html_content.replace('<script src="vis-network.min.js"></script>', '')
    html_content = html_content.replace('<script src="app.js?v=51"></script>', injected_scripts)

    return html_content


# ==========================================
# Render Full Screen Component
# ==========================================
bundled_html = build_bundled_html()
components.html(bundled_html, height=1200, scrolling=True)
