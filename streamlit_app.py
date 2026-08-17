"""
Network Device Monitor & Diagnostic Tool - Streamlit Web Demo Application
PowerShell & SPA 連携型・エージェントレス死活監視＆診断システム Webデモ版
"""

import json
import os
import time
import random
import numpy as np
import pandas as pd
import plotly.graph_objects as go
import plotly.express as px
import streamlit as st

# ==========================================
# Page Configuration & Custom CSS
# ==========================================
st.set_page_config(
    page_title="ネットワーク機器監視システム | Network Device Monitor",
    page_icon="🌐",
    layout="wide",
    initial_sidebar_state="expanded"
)

# Custom CSS for Premium Design
st.markdown("""
<style>
    /* Metric Card Styling */
    div[data-testid="metric-container"] {
        background: rgba(30, 41, 59, 0.4);
        border: 1px solid rgba(255, 255, 255, 0.1);
        border-radius: 12px;
        padding: 12px 16px;
        box-shadow: 0 4px 15px rgba(0,0,0,0.2);
    }
    
    /* Live Speed Card */
    .live-speed-box {
        background: linear-gradient(135deg, rgba(30, 41, 59, 0.8), rgba(15, 23, 42, 0.95));
        border: 1px solid rgba(56, 189, 248, 0.4);
        border-radius: 14px;
        padding: 20px;
        text-align: center;
        box-shadow: 0 8px 32px rgba(56, 189, 248, 0.15);
        margin-bottom: 20px;
    }
    .live-speed-val {
        font-size: 3.2rem;
        font-weight: 800;
        color: #38bdf8;
        font-family: 'Courier New', monospace;
        line-height: 1;
    }
    .live-speed-unit {
        font-size: 1.2rem;
        font-weight: 600;
        color: #94a3b8;
        margin-left: 8px;
    }
    
    /* Device Card Grid */
    .device-grid-card {
        background: rgba(30, 41, 59, 0.5);
        border: 1px solid rgba(255, 255, 255, 0.08);
        border-radius: 10px;
        padding: 12px 14px;
        margin-bottom: 10px;
        transition: transform 0.15s ease, border-color 0.15s ease;
    }
    .device-grid-card:hover {
        border-color: rgba(56, 189, 248, 0.5);
        transform: translateY(-2px);
    }
    .status-badge {
        display: inline-block;
        padding: 2px 8px;
        border-radius: 12px;
        font-size: 0.75rem;
        font-weight: 700;
    }
    .badge-online { background: rgba(16, 185, 129, 0.2); color: #34d399; border: 1px solid rgba(16, 185, 129, 0.4); }
    .badge-warning { background: rgba(251, 191, 36, 0.2); color: #fbbf24; border: 1px solid rgba(251, 191, 36, 0.4); }
    .badge-offline { background: rgba(239, 68, 68, 0.2); color: #f87171; border: 1px solid rgba(239, 68, 68, 0.4); }
    .badge-paused { background: rgba(148, 163, 184, 0.2); color: #94a3b8; border: 1px solid rgba(148, 163, 184, 0.4); }
</style>
""", unsafe_allow_html=True)


# ==========================================
# Load Device Configuration
# ==========================================
@st.cache_data
def load_devices():
    json_path = os.path.join(os.path.dirname(__file__), "system", "devices.json")
    if os.path.exists(json_path):
        try:
            with open(json_path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            st.warning(f"devices.json 読み込み失敗: {e}")
    
    # Fallback default devices
    return [
        {"name": "2D用IPDecoder", "ip": "192.168.10.14", "group": "操作側", "x": 1034, "y": -128, "image": "decoder", "connectedTo": ""},
        {"name": "3D用IPDecoder", "ip": "192.168.10.13", "group": "操作側", "x": 1035, "y": 132, "image": "decoder", "connectedTo": ""},
        {"name": "RBTリモコン", "ip": "192.168.10.12", "group": "操作側", "x": 941, "y": -178, "image": "controller", "connectedTo": "192.168.10.35"},
        {"name": "AP800", "ip": "192.168.10.35", "group": "操作側", "x": 777, "y": -108, "image": "ap", "connectedTo": "192.168.10.13"},
        {"name": "OAP2(infra側)", "ip": "192.168.10.23", "group": "サイト側", "x": 604, "y": 149, "image": "ap", "connectedTo": "192.168.10.13,192.168.10.14"},
        {"name": "カメラ2", "ip": "192.168.10.11", "group": "サイト側", "x": 725, "y": -152, "image": "camera", "connectedTo": "192.168.10.23"},
        {"name": "PLC(サイト側)", "ip": "192.168.10.1", "group": "サイト側", "x": 520, "y": -30, "image": "server", "connectedTo": "192.168.10.23"},
        {"name": "スイッチハブ", "ip": "192.168.10.254", "group": "ネットワーク", "x": 800, "y": 0, "image": "switch", "connectedTo": ""}
    ]

raw_devices = load_devices()

# ==========================================
# Initialize Session State
# ==========================================
if "simulation_history" not in st.session_state:
    # Initialize history for all devices
    history = {}
    for dev in raw_devices:
        ip = dev.get("ip", "0.0.0.0")
        base_latency = random.uniform(2.0, 15.0)
        history[ip] = {
            "latencies": [max(0.5, base_latency + random.gauss(0, 1.5)) for _ in range(25)],
            "losses": [0.0] * 25,
            "jitters": [random.uniform(0.2, 1.8) for _ in range(25)],
            "base_latency": base_latency,
            "status": "online",  # online, warning, offline, paused
            "outages": 0
        }
    st.session_state.simulation_history = history

if "scenario" not in st.session_state:
    st.session_state.scenario = "通常稼働 (Normal)"

if "iperf_running" not in st.session_state:
    st.session_state.iperf_running = False

if "iperf_logs" not in st.session_state:
    st.session_state.iperf_logs = []

if "iperf_speeds" not in st.session_state:
    st.session_state.iperf_speeds = []


# ==========================================
# Update Simulation Step
# ==========================================
def update_simulation_step(scenario, thresh_latency):
    history = st.session_state.simulation_history
    for idx, dev in enumerate(raw_devices):
        ip = dev.get("ip", "0.0.0.0")
        h = history[ip]
        
        # Scenario logic
        if scenario == "通常稼働 (Normal)":
            lat = max(0.5, h["base_latency"] + random.gauss(0, 1.2))
            loss = 0.0 if random.random() > 0.02 else 5.0
            status = "online"
        elif scenario == "⚠️ 遅延スパイク発生 (Spike Demo)":
            if idx in [1, 4, 7]:  # specific devices suffer spikes
                lat = random.uniform(120.0, 260.0)
                loss = random.uniform(5.0, 18.0)
                status = "warning" if lat > thresh_latency else "online"
            else:
                lat = max(0.5, h["base_latency"] + random.gauss(0, 1.5))
                loss = 0.0
                status = "online"
        elif scenario == "🔴 障害発生 (Outage Demo)":
            if idx in [2, 5]:  # specific devices go down
                lat = 0.0
                loss = 100.0
                status = "offline"
                h["outages"] += 1
            elif idx in [1, 4]:
                lat = random.uniform(110.0, 190.0)
                loss = 12.5
                status = "warning"
            else:
                lat = max(0.5, h["base_latency"] + random.gauss(0, 1.5))
                loss = 0.0
                status = "online"
        else:
            lat = max(0.5, h["base_latency"] + random.gauss(0, 1.2))
            loss = 0.0
            status = "online"
            
        jitter = abs(lat - h["latencies"][-1]) if lat > 0 else 0.0
        
        # Update history queues
        h["latencies"].pop(0)
        h["latencies"].append(round(lat, 2))
        h["losses"].pop(0)
        h["losses"].append(round(loss, 1))
        h["jitters"].pop(0)
        h["jitters"].append(round(jitter, 2))
        h["status"] = status


# ==========================================
# Sidebar Configuration & Controls
# ==========================================
with st.sidebar:
    st.markdown("### 🌐 Network Monitor")
    st.caption("PowerShell & SPA 連携型 ネットワーク機器監視システム")
    st.markdown("---")
    
    # Navigation
    menu = st.radio(
        "📌 メインメニュー",
        [
            "📊 ダッシュボード (Dashboard)",
            "🌐 システム構成図 (Topology)",
            "🔍 詳細診断 & SNMP (Metrics)",
            "🚀 Iperf3 帯域計測 (Bandwidth)",
            "💾 レポート & エクスポート (Reports)"
        ],
        index=0
    )
    
    st.markdown("---")
    st.markdown("#### ⚙️ 監視パラメータ設定")
    
    thresh_latency = st.number_input("🔔 遅延アラート閾値 (ms)", min_value=10, max_value=2000, value=100, step=10)
    poll_interval = st.selectbox("⏱ 監視頻度 (Interval)", ["0.1s (超高頻度)", "0.5s (高頻度)", "1.0s (標準)", "5.0s (低負荷)"], index=2)
    ping_size = st.number_input("📡 Pingデータサイズ (bytes)", min_value=1, max_value=65500, value=1, step=32)
    
    st.markdown("---")
    st.markdown("#### 🧪 デモ・シミュレーション制御")
    scenario = st.selectbox(
        "シナリオ選択",
        ["通常稼働 (Normal)", "⚠️ 遅延スパイク発生 (Spike Demo)", "🔴 障害発生 (Outage Demo)"],
        index=0
    )
    st.session_state.scenario = scenario
    
    auto_refresh = st.toggle("🔄 リアルタイム自動更新 (Live)", value=True)
    if auto_refresh:
        update_simulation_step(scenario, thresh_latency)
    
    if st.button("⚡ 直ちにデータを1ステップ更新"):
        update_simulation_step(scenario, thresh_latency)
        st.rerun()

    st.markdown("---")
    st.markdown(
        """
        <div style="font-size: 0.75rem; color: #94a3b8; text-align: center;">
            OSS License: MIT / BSD / LGPL<br>
            <a href="https://github.com/Shuntaro1996/network-device-monitor" target="_blank" style="color: #38bdf8; text-decoration: none;">GitHub Repository</a>
        </div>
        """,
        unsafe_allow_html=True
    )


# ==========================================
# Summary Header Metrics
# ==========================================
history = st.session_state.simulation_history
all_statuses = [h["status"] for h in history.values()]
online_cnt = all_statuses.count("online")
warning_cnt = all_statuses.count("warning")
offline_cnt = all_statuses.count("offline")
paused_cnt = all_statuses.count("paused")

latest_latencies = [h["latencies"][-1] for h in history.values() if h["latencies"][-1] > 0]
avg_latency = np.mean(latest_latencies) if latest_latencies else 0.0
latest_losses = [h["losses"][-1] for h in history.values()]
avg_loss = np.mean(latest_losses) if latest_losses else 0.0
latest_jitters = [h["jitters"][-1] for h in history.values() if h["latencies"][-1] > 0]
avg_jitter = np.mean(latest_jitters) if latest_jitters else 0.0

st.title("🌐 ネットワーク機器監視システム")
st.caption("PowerShell バックエンド ＆ SPA フロントエンド統合 ネットワーク死活監視・診断ツール")

# Top Summary Row
col1, col2, col3, col4, col5, col6 = st.columns(6)
with col1:
    st.metric("🟢 正常稼働", f"{online_cnt} 台", delta=None)
with col2:
    st.metric("🟡 高遅延警告", f"{warning_cnt} 台", delta=f"{warning_cnt} 件" if warning_cnt > 0 else None, delta_color="inverse")
with col3:
    st.metric("🔴 障害/切断", f"{offline_cnt} 台", delta=f"{offline_cnt} 件" if offline_cnt > 0 else None, delta_color="inverse")
with col4:
    st.metric("⏱ 平均遅延", f"{avg_latency:.2f} ms", delta=None)
with col5:
    st.metric("📉 ロス率", f"{avg_loss:.1f} %", delta=None)
with col6:
    st.metric("〰️ ジッター", f"{avg_jitter:.2f} ms", delta=None)

st.markdown("---")


# ==========================================
# View 1: Dashboard
# ==========================================
if menu == "📊 ダッシュボード (Dashboard)":
    st.subheader("⏱ 稼働タイムライン & 直近ヒートマップ")
    
    # Heatmap Matrix (Devices x Time)
    device_names = [d.get("name", d.get("ip")) for d in raw_devices]
    time_steps = [f"-{24-i}s" for i in range(25)]
    
    heatmap_data = []
    for d in raw_devices:
        ip = d.get("ip")
        lats = history[ip]["latencies"]
        losses = history[ip]["losses"]
        row = []
        for l, loss in zip(lats, losses):
            if loss >= 100.0 or l == 0:
                row.append(2)  # Offline (Red)
            elif l > thresh_latency or loss > 0:
                row.append(1)  # Warning (Yellow)
            else:
                row.append(0)  # Online (Green)
        heatmap_data.append(row)
        
    fig_heat = go.Figure(data=go.Heatmap(
        z=heatmap_data,
        x=time_steps,
        y=device_names,
        colorscale=[
            [0.0, "#10b981"],   # Green
            [0.5, "#f59e0b"],   # Yellow
            [1.0, "#ef4444"]    # Red
        ],
        showscale=False,
        xgap=2,
        ygap=2
    ))
    fig_heat.update_layout(
        height=380,
        margin=dict(l=10, r=10, t=10, b=10),
        plot_bgcolor="rgba(0,0,0,0)",
        paper_bgcolor="rgba(0,0,0,0)",
        xaxis=dict(showgrid=False, zeroline=False),
        yaxis=dict(showgrid=False, zeroline=False, autorange="reversed")
    )
    st.plotly_chart(fig_heat, use_container_width=True)
    
    st.markdown("---")
    st.subheader("🖥 登録機器一覧 & リアルタイムステータス")
    
    # Group Devices by Group
    groups = {}
    for d in raw_devices:
        grp = d.get("group", "その他")
        if grp not in groups:
            groups[grp] = []
        groups[grp].append(d)
        
    for grp_name, dev_list in groups.items():
        st.markdown(f"#### 📂 グループ: **{grp_name}** ({len(dev_list)} 台)")
        
        # Display 3 cards per row
        cols = st.columns(3)
        for i, dev in enumerate(dev_list):
            ip = dev.get("ip")
            h = history[ip]
            stat = h["status"]
            lat = h["latencies"][-1]
            loss = h["losses"][-1]
            jit = h["jitters"][-1]
            
            badge_class = {
                "online": "badge-online",
                "warning": "badge-warning",
                "offline": "badge-offline",
                "paused": "badge-paused"
            }.get(stat, "badge-online")
            
            stat_label = {
                "online": "🟢 正常",
                "warning": "🟡 高遅延",
                "offline": "🔴 障害",
                "paused": "⏸ 停止"
            }.get(stat, "正常")
            
            with cols[i % 3]:
                st.markdown(f"""
                <div class="device-grid-card">
                    <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:8px;">
                        <span style="font-weight:700; font-size:1.0rem; color:#f8fafc;">{dev.get('name')}</span>
                        <span class="status-badge {badge_class}">{stat_label}</span>
                    </div>
                    <div style="font-size:0.8rem; color:#94a3b8; margin-bottom:10px;">
                        <code>{ip}</code> | 種別: {dev.get('image', 'general')}
                    </div>
                    <div style="display:flex; justify-content:space-between; font-size:0.85rem;">
                        <div>遅延: <b style="color:{'#f87171' if lat>thresh_latency else '#38bdf8'};">{lat:.1f} ms</b></div>
                        <div>ロス: <b>{loss:.0f}%</b></div>
                        <div>ジッター: <b>{jit:.1f} ms</b></div>
                    </div>
                </div>
                """, unsafe_allow_html=True)
                
                # Sparkline chart
                fig_spark = go.Figure()
                fig_spark.add_trace(go.Scatter(
                    y=h["latencies"][-15:],
                    mode='lines',
                    line=dict(color='#38bdf8' if stat=='online' else '#f87171', width=1.5),
                    fill='tozeroy',
                    fillcolor='rgba(56, 189, 248, 0.1)' if stat=='online' else 'rgba(239, 68, 68, 0.1)'
                ))
                fig_spark.update_layout(
                    height=50,
                    margin=dict(l=0, r=0, t=0, b=0),
                    xaxis=dict(visible=False),
                    yaxis=dict(visible=False),
                    plot_bgcolor='rgba(0,0,0,0)',
                    paper_bgcolor='rgba(0,0,0,0)'
                )
                st.plotly_chart(fig_spark, use_container_width=True, key=f"spark_{ip}")


# ==========================================
# View 2: System Topology Map
# ==========================================
elif menu == "🌐 システム構成図 (Topology)":
    st.subheader("🌐 システム構成図 & 動的リンクアラートマップ")
    st.caption("devices.json に登録された各機器の座標 (x, y) および接続関係 (connectedTo) をインタラクティブ描画")
    
    # Build Network Topology using Plotly Scatter
    edge_x = []
    edge_y = []
    edge_colors = []
    
    ip_to_dev = {d.get("ip"): d for d in raw_devices}
    
    for dev in raw_devices:
        x0 = dev.get("x", 0)
        y0 = dev.get("y", 0)
        conn_str = dev.get("connectedTo", "")
        if conn_str:
            targets = [t.strip() for t in conn_str.split(",") if t.strip()]
            for tgt_ip in targets:
                if tgt_ip in ip_to_dev:
                    tgt = ip_to_dev[tgt_ip]
                    x1 = tgt.get("x", 0)
                    y1 = tgt.get("y", 0)
                    edge_x.extend([x0, x1, None])
                    edge_y.extend([y0, y1, None])
                    
    # Node coordinates & attributes
    node_x = []
    node_y = []
    node_text = []
    node_colors = []
    node_sizes = []
    
    for dev in raw_devices:
        ip = dev.get("ip")
        h = history.get(ip, {"latencies": [0], "status": "online"})
        node_x.append(dev.get("x", 0))
        node_y.append(dev.get("y", 0))
        
        stat = h["status"]
        lat = h["latencies"][-1]
        
        color_map = {
            "online": "#10b981",   # Green
            "warning": "#f59e0b",  # Yellow
            "offline": "#ef4444",  # Red
            "paused": "#94a3b8"    # Gray
        }
        node_colors.append(color_map.get(stat, "#10b981"))
        node_sizes.append(22 if dev.get("image") in ["ap", "switch", "server"] else 16)
        
        node_text.append(f"<b>{dev.get('name')}</b><br>IP: {ip}<br>遅延: {lat:.1f} ms<br>状態: {stat}")
        
    fig_topo = go.Figure()
    
    # Draw Lines
    fig_topo.add_trace(go.Scatter(
        x=edge_x, y=edge_y,
        line=dict(width=1.5, color="rgba(148, 163, 184, 0.4)"),
        hoverinfo='none',
        mode='lines'
    ))
    
    # Draw Nodes
    fig_topo.add_trace(go.Scatter(
        x=node_x, y=node_y,
        mode='markers+text',
        text=[d.get("name") for d in raw_devices],
        textposition="top center",
        textfont=dict(color="#f8fafc", size=10),
        hoverinfo='text',
        hovertext=node_text,
        marker=dict(
            color=node_colors,
            size=node_sizes,
            line=dict(width=2, color="#ffffff")
        )
    ))
    
    fig_topo.update_layout(
        height=620,
        showlegend=False,
        margin=dict(l=10, r=10, t=10, b=10),
        plot_bgcolor="#0f172a",
        paper_bgcolor="#0f172a",
        xaxis=dict(showgrid=False, zeroline=False, showticklabels=False),
        yaxis=dict(showgrid=False, zeroline=False, showticklabels=False)
    )
    
    st.plotly_chart(fig_topo, use_container_width=True)


# ==========================================
# View 3: Deep Metrics & SNMP Diagnosis
# ==========================================
elif menu == "🔍 詳細診断 & SNMP (Metrics)":
    st.subheader("🔍 機器別 詳細Ping推移 & SNMP仮想診断")
    
    # Device Selector
    dev_names = [f"{d.get('name')} ({d.get('ip')})" for d in raw_devices]
    selected_idx = st.selectbox("診断対象機器を選択", range(len(raw_devices)), format_func=lambda i: dev_names[i])
    
    selected_dev = raw_devices[selected_idx]
    sel_ip = selected_dev.get("ip")
    sel_hist = history[sel_ip]
    
    # Top stats for selected device
    c1, c2, c3, c4 = st.columns(4)
    with c1:
        st.metric("機器名 / IP", selected_dev.get("name"), sel_ip)
    with c2:
        st.metric("現在遅延", f"{sel_hist['latencies'][-1]:.2f} ms")
    with c3:
        st.metric("直近ジッター", f"{sel_hist['jitters'][-1]:.2f} ms")
    with c4:
        st.metric("瞬断発生回数", f"{sel_hist['outages']} 回")
        
    st.markdown("---")
    
    # Latency & Jitter Time Series Chart
    time_series_x = [f"-{24-i}s" for i in range(25)]
    fig_metric = go.Figure()
    fig_metric.add_trace(go.Scatter(
        x=time_series_x,
        y=sel_hist["latencies"],
        name="Ping 遅延 (ms)",
        line=dict(color="#38bdf8", width=2.5),
        mode='lines+markers'
    ))
    fig_metric.add_trace(go.Scatter(
        x=time_series_x,
        y=sel_hist["jitters"],
        name="ジッター (ms)",
        line=dict(color="#fbbf24", width=2, dash='dot'),
        mode='lines'
    ))
    fig_metric.add_hline(y=thresh_latency, line_dash="dash", line_color="#ef4444", annotation_text="遅延閾値")
    
    fig_metric.update_layout(
        title=f"📈 Ping遅延 & ジッター 時系列推移 ({selected_dev.get('name')})",
        height=320,
        margin=dict(l=10, r=10, t=40, b=10),
        plot_bgcolor="rgba(0,0,0,0)",
        paper_bgcolor="rgba(0,0,0,0)",
        legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="right", x=1)
    )
    st.plotly_chart(fig_metric, use_container_width=True)
    
    # SNMP Virtual Gauges
    st.markdown("#### 🔬 SNMP v2c / v3 診断情報 (MIB取得シミュレーション)")
    sc1, sc2, sc3 = st.columns(3)
    
    cpu_val = random.randint(18, 55) if sel_hist["status"] == "online" else 0
    mem_val = random.randint(42, 78) if sel_hist["status"] == "online" else 0
    rx_mbps = random.uniform(15.0, 120.0) if sel_hist["status"] == "online" else 0.0
    tx_mbps = random.uniform(8.0, 95.0) if sel_hist["status"] == "online" else 0.0
    
    with sc1:
        fig_cpu = go.Figure(go.Indicator(
            mode="gauge+number",
            value=cpu_val,
            title={'text': "CPU 使用率 (%)"},
            gauge={
                'axis': {'range': [0, 100]},
                'bar': {'color': "#38bdf8"},
                'steps': [
                    {'range': [0, 60], 'color': "rgba(16, 185, 129, 0.15)"},
                    {'range': [60, 85], 'color': "rgba(251, 191, 36, 0.15)"},
                    {'range': [85, 100], 'color': "rgba(239, 68, 68, 0.15)"}
                ]
            }
        ))
        fig_cpu.update_layout(height=220, margin=dict(l=20, r=20, t=30, b=20), paper_bgcolor="rgba(0,0,0,0)")
        st.plotly_chart(fig_cpu, use_container_width=True)
        
    with sc2:
        fig_mem = go.Figure(go.Indicator(
            mode="gauge+number",
            value=mem_val,
            title={'text': "メモリ使用率 (%)"},
            gauge={
                'axis': {'range': [0, 100]},
                'bar': {'color': "#a78bfa"},
                'steps': [
                    {'range': [0, 70], 'color': "rgba(16, 185, 129, 0.15)"},
                    {'range': [70, 90], 'color': "rgba(251, 191, 36, 0.15)"},
                    {'range': [90, 100], 'color': "rgba(239, 68, 68, 0.15)"}
                ]
            }
        ))
        fig_mem.update_layout(height=220, margin=dict(l=20, r=20, t=30, b=20), paper_bgcolor="rgba(0,0,0,0)")
        st.plotly_chart(fig_mem, use_container_width=True)
        
    with sc3:
        st.markdown("**NIC インターフェース帯域**")
        st.markdown(f"📥 受信 (Rx): **{rx_mbps:.1f} Mbps**")
        st.progress(min(1.0, rx_mbps / 150.0))
        st.markdown(f"📤 送信 (Tx): **{tx_mbps:.1f} Mbps**")
        st.progress(min(1.0, tx_mbps / 150.0))
        st.caption("SNMP ifInOctets / ifOutOctets 算出")


# ==========================================
# View 4: Iperf3 Bandwidth Simulator
# ==========================================
elif menu == "🚀 Iperf3 帯域計測 (Bandwidth)":
    st.subheader("🚀 Iperf3 実効帯域・スループット計測シミュレーター")
    st.caption("本システムで改修した「iperf3 リアルタイム伝送速度カード & ログストリーミング」をWeb上で忠実に体験")
    
    col_ctrl1, col_ctrl2, col_ctrl3 = st.columns(3)
    with col_ctrl1:
        target_iperf_ip = st.selectbox("測定先ターゲットIP", [d.get("ip") for d in raw_devices], index=0)
    with col_ctrl2:
        test_duration = st.slider("測定秒数 (秒)", min_value=3, max_value=15, value=6)
    with col_ctrl3:
        st.write("")
        st.write("")
        run_iperf = st.button("🚀 iperf3 計測を開始", type="primary", use_container_width=True)
        
    speed_container = st.empty()
    chart_container = st.empty()
    log_container = st.empty()
    
    if run_iperf:
        st.session_state.iperf_logs = []
        st.session_state.iperf_speeds = []
        
        # Initial status
        st.session_state.iperf_logs.append(f"[{time.strftime('%H:%M:%S')}] Connecting to host {target_iperf_ip}, port 5201")
        st.session_state.iperf_logs.append(f"[{time.strftime('%H:%M:%S')}] [  5] local 192.168.10.100 port 54321 connected to {target_iperf_ip} port 5201")
        st.session_state.iperf_logs.append(f"[{time.strftime('%H:%M:%S')}] [ ID] Interval           Transfer     Bitrate")
        
        base_speed = random.uniform(820.0, 940.0)
        
        # Streaming simulation loop
        for sec in range(1, test_duration + 1):
            cur_speed = round(base_speed + random.gauss(0, 25.0), 2)
            st.session_state.iperf_speeds.append(cur_speed)
            
            # Live speed card
            speed_container.markdown(f"""
            <div class="live-speed-box">
                <div style="font-size:0.9rem; color:#38bdf8; font-weight:700; margin-bottom:6px;">
                    ⚡ REALTIME SPEED (計測中)
                </div>
                <div>
                    <span class="live-speed-val">{cur_speed:.2f}</span>
                    <span class="live-speed-unit">Mbits/sec</span>
                </div>
            </div>
            """, unsafe_allow_html=True)
            
            # Update chart
            fig_live_iperf = go.Figure()
            fig_live_iperf.add_trace(go.Scatter(
                x=[f"{i}s" for i in range(1, len(st.session_state.iperf_speeds) + 1)],
                y=st.session_state.iperf_speeds,
                mode='lines+markers',
                line=dict(color='#38bdf8', width=3),
                fill='tozeroy',
                fillcolor='rgba(56, 189, 248, 0.15)'
            ))
            fig_live_iperf.update_layout(
                title="📊 リアルタイム・スループット推移 (Mbps)",
                height=260,
                margin=dict(l=10, r=10, t=40, b=10),
                plot_bgcolor="rgba(0,0,0,0)",
                paper_bgcolor="rgba(0,0,0,0)",
                yaxis=dict(range=[0, 1100])
            )
            chart_container.plotly_chart(fig_live_iperf, use_container_width=True)
            
            # Add log line
            ts = time.strftime('%H:%M:%S')
            transfer_mb = round(cur_speed / 8.0, 1)
            st.session_state.iperf_logs.append(f"[{ts}] [  5]   {sec-1}.00-{sec}.00   sec   {transfer_mb:.1f} MBytes   {cur_speed:.2f} Mbits/sec")
            log_container.code("\n".join(st.session_state.iperf_logs), language="bash")
            
            time.sleep(0.5)  # Fast preview animation
            
        # Completion
        avg_sp = np.mean(st.session_state.iperf_speeds)
        st.session_state.iperf_logs.append(f"[{time.strftime('%H:%M:%S')}] - - - - - - - - - - - - - - - - - - - - - - - - -")
        st.session_state.iperf_logs.append(f"[{time.strftime('%H:%M:%S')}] [  5]  0.00-{test_duration}.00   sec   {round(avg_sp*test_duration/8.0, 1)} MBytes   {avg_sp:.2f} Mbits/sec   sender")
        st.session_state.iperf_logs.append(f"[{time.strftime('%H:%M:%S')}] === iperf3 Finished at {time.strftime('%Y-%m-%d %H:%M:%S')} ===")
        log_container.code("\n".join(st.session_state.iperf_logs), language="bash")
        
        st.success(f"✅ 計測完了: 平均伝送速度 **{avg_sp:.2f} Mbps**")


# ==========================================
# View 5: Reports & CSV Export
# ==========================================
elif menu == "💾 レポート & エクスポート (Reports)":
    st.subheader("💾 監視セッションレポート & CSVエクスポート")
    st.caption("監視結果サマリー、直近稼働率、瞬断カウントログのダウンロード")
    
    # Generate report table
    report_rows = []
    for d in raw_devices:
        ip = d.get("ip")
        h = history[ip]
        lats = [x for x in h["latencies"] if x > 0]
        avg_l = np.mean(lats) if lats else 0.0
        max_l = np.max(lats) if lats else 0.0
        min_l = np.min(lats) if lats else 0.0
        loss_rate = np.mean(h["losses"])
        
        report_rows.append({
            "グループ": d.get("group", "その他"),
            "機器名": d.get("name"),
            "IPアドレス": ip,
            "ステータス": h["status"],
            "平均遅延 (ms)": round(avg_l, 2),
            "最小遅延 (ms)": round(min_l, 2),
            "最大遅延 (ms)": round(max_l, 2),
            "パケットロス率 (%)": f"{loss_rate:.1f}%",
            "瞬断検知回数": h["outages"]
        })
        
    df_report = pd.DataFrame(report_rows)
    st.dataframe(df_report, use_container_width=True, hide_index=True)
    
    # CSV Download Button
    csv_data = df_report.to_csv(index=False, encoding="utf-8-sig")
    st.download_button(
        label="📥 監視レポートをCSV形式でダウンロード",
        data=csv_data,
        file_name=f"NetworkMonitor_Report_{time.strftime('%Y%m%d_%H%M%S')}.csv",
        mime="text/csv",
        type="primary"
    )
