# 🌐 Network Device Monitor & Diagnostic Tool — 管理者・開発者向け詳細設計書

**対象読者**: システムの導入・構成管理・API連携・カスタマイズ・トラブルシューティングを担当するインフラエンジニア・管理者

---

## 📋 目次

1. [システム概要](#1-システム概要)
2. [ファイル・ディレクトリ構成](#2-ファイルディレクトリ構成)
3. [動作要件と前提条件](#3-動作要件と前提条件)
4. [起動・停止手順](#4-起動停止手順)
5. [設定ファイル仕様（config.json / devices.json）](#5-設定ファイル仕様configjson--devicesjson)
6. [アーキテクチャとスレッドモデル](#6-アーキテクチャとスレッドモデル)
7. [監視エンジンの詳細仕様](#7-監視エンジンの詳細仕様)
8. [通信品質アルゴリズム（パケロス・ジッター・瞬断）](#8-通信品質アルゴリズムパケロスジッター瞬断)
9. [外部通知 & Web Audio 設計](#9-外部通知--web-audio-設計)
10. [バックアップ・リストア & ログ保守仕様](#10-バックアップリストア--ログ保守仕様)
11. [REST API エンドポイント一覧](#11-rest-api-エンドポイント一覧)
12. [セキュリティ & 入力サニタイズ仕様](#12-セキュリティ--入力サニタイズ仕様)
13. [トラブルシューティング](#13-トラブルシューティング)
14. [既知の制限事項](#14-既知の制限事項)

---

## 1. システム概要

本システムは **PowerShell 5.1 / 7+ 製のマルチスレッド非同期 HTTP バックエンド** と、ブラウザ上で動作する **Vanilla JS + Vis-Network + Chart.js 製の軽量SPAフロントエンド** で構成された、エージェントレス型のネットワーク監視・診断基盤です。

### 核心機能
- **デュアルレート死活監視 (Ping)**: 最重要機器（最大2台）を 0.1秒、他機器を 5.0秒で並行高精度監視。
- **通信品質解析**: パケットロス率 (%)、RFC 3550 準拠ジッター (ms)、最大瞬断時間 (秒)、閾値別瞬断回数のリアルタイム算出。
- **稼働ヒートマップ**: 直近サンプリングの到達品質をカラーバーで時系列表示。
- **外部 Webhook & Web Audio 通知**: Slack/Teams/Discord 等への非同期 POST およびブラウザ上での音波合成アラート。
- **動的トポロジー可視化**: 機器間リンクの障害・遅延ステータスに応じた動的カラーチェンジ。
- **設定バックアップ & リストア**: 監視設定・機器情報を1つの JSON でエクスポート/インポート。
- **自動ログローテーション & パージ**: 保持日数を超過した過去ログの自動削除。

---

## 2. ファイル・ディレクトリ構成

```
NetworkDeviceMonitor/
├── Start-Monitor.bat              # 起動スクリプト（管理者不要）
├── 利用手順書.md                  # 現場運用者向けマニュアル
├── README.md                      # プロジェクト概要
├── LICENSE                        # MIT License
├── Reports/                       # 実行時ログ・CSVレポート出力先（自動生成）
│   └── <yyyyMMdd_HHmmss>/
│       ├── ping_<IP>.csv          # Ping履歴（末尾に日本語サマリーブロック付与）
│       └── iperf_<target>_<ts>.log # Iperf3計測ログ
└── system/
    ├── README.md                  # ★本ドキュメント
    ├── Server.ps1                 # ★メインバックエンドサーバー（Runspace並列処理）
    ├── Launcher.ps1               # 個別デバイス監視ランチャー
    ├── Measure-Bandwidth.ps1      # SNMPによる帯域計算ロジック
    ├── Monitor-SingleDevice.ps1   # 単体デバイス監視スクリプト
    ├── Start-BandwidthServer.ps1  # 帯域監視補助サーバー
    ├── devices.json               # 監視対象デバイス設定（自動保存）
    ├── config.json                # システム全体設定（自動保存）
    ├── debug.log                  # エラーログ（Runspace例外を記録）
    ├── iperf3.18_64/              # Iperf3バイナリ（同梱）
    └── public/                    # フロントエンド静的アセット
        ├── index.html             # メインUI（日本語化・グラスモーフィズム）
        ├── app.js                 # UIロジック・Web Audio・Chart制御・API通信
        ├── style.css              # レスポンシブスタイルシート（デイ/ナイト対応）
        ├── chart.js               # Chart.js
        └── vis-network.min.js     # Vis-Network
```

---

## 3. 動作要件と前提条件

| 項目 | 要件 |
| :--- | :--- |
| **OS** | Windows 10 / 11 / Windows Server 2016 以降 |
| **PowerShell** | Windows PowerShell 5.1 または PowerShell 7+ |
| **ブラウザ** | Google Chrome / Microsoft Edge / Mozilla Firefox（最新版） |
| **通信ポート** | TCP `8081`（HTTP API・Web画面用） |
| **ネットワーク** | 監視対象機器への ICMP Echo（Ping）疎通 |
| **SNMP (任意)** | 対象機器で SNMP v2c または v3 が有効であること |
| **SNMPモジュール** | `Install-Module SNMP -Scope CurrentUser -Force` でインストール推奨 |

---

## 4. 起動・停止手順

### 起動
`Start-Monitor.bat` をダブルクリックします。内部で以下が実行されます：
```cmd
powershell.exe -ExecutionPolicy Bypass -File "system\Server.ps1"
```
サーバー初期化後、自動的にブラウザで `http://localhost:8081` が開きます。

### 停止
バックグラウンドの PowerShell ウィンドウで **[Enter] キーを押す** か、ウィンドウを閉じます。
停止時に全監視機器の直近サマリー（到達率・パケロス率・ジッター・最大瞬断時間）が CSV に追記され、ポート・Runspace が安全に解放されます。

---

## 5. 設定ファイル仕様（config.json / devices.json）

### `system/config.json`
システム全体の監視・通知・保守パラメータ。UI（⚙️ システム設定）からの変更が即座に同期・保存されます。

```json
{
  "pollInterval": 1000,
  "pingDataSize": 1,
  "loggingEnabled": true,
  "highFreqTargetIps": "192.168.10.1,192.168.10.2",
  "outageThresh1Ms": 600,
  "outageThresh2Ms": 5000,
  "latencyThreshMs": 100,
  "logRetentionDays": 30,
  "webhookUrl": "https://hooks.slack.com/services/...",
  "webhookEnabled": true,
  "webhookOfflineOnly": true,
  "soundEnabled": true,
  "soundVolume": 0.5
}
```

| キー | 型 | 初期値 | 説明 |
| :--- | :--- | :--- | :--- |
| `pollInterval` | int | `1000` | 通常監視のポーリング間隔 (ms)。`100` でデュアルレートモード発動 |
| `pingDataSize` | int | `1` | ICMP Echo ペイロードサイズ (bytes) |
| `loggingEnabled` | bool | `true` | CSV ログ記録の有効/無効 |
| `highFreqTargetIps` | string | `""` | 0.1s 超高頻度監視の対象IP（カンマ区切り、最大2台） |
| `outageThresh1Ms` | int | `600` | 瞬断判定閾値① (ms)。これ以上の瞬断回数をカウント |
| `outageThresh2Ms` | int | `5000` | 瞬断判定閾値② (ms)。これ以上の瞬断回数をカウント |
| `latencyThreshMs` | int | `100` | 遅延アラート警告閾値 (ms) |
| `logRetentionDays` | int | `30` | ログ保持日数。この日数を超えた古いセッションを自動パージ |
| `webhookUrl` | string | `""` | 外部通知先 Webhook URL |
| `webhookEnabled` | bool | `false` | Webhook 自動送信の有効/無効 |
| `webhookOfflineOnly` | bool | `true` | オフライン/復旧時のみ通知（高遅延時は除外） |
| `soundEnabled` | bool | `true` | ブラウザ音声アラートの有効/無効 |
| `soundVolume` | float | `0.5` | 音声アラート音量 (0.0 〜 1.0) |

---

## 6. アーキテクチャとスレッドモデル

```
┌────────────────────────────────────────────────────────────────────────┐
│ Server.ps1 (メインプロセス)                                            │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ $syncHash (スレッドセーフな Synchronized Hashtable)               │  │
│  │ ・Devices, Status, Stats, Traffic, Bandwidth, Config, ...        │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                        │
│  ┌─────────────────────────┐  ┌─────────────────────────────────────┐  │
│  │ Ping Engine (Runspace)  │  │ SNMP & Topology Engine (Runspace)   │  │
│  │ ・デュアルレート制御    │  │ ・IF-MIB トラフィック取得           │  │
│  │ ・パケロス/ジッター算出 │  │ ・CDP/LLDP 自動リンク検出           │  │
│  │ ・Webhook 非同期POST    │  │ ・エラーパケット・システム情報取得   │  │
│  └─────────────────────────┘  └─────────────────────────────────────┘  │
│                                                                        │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ HTTP Server (HttpListener :8081)                                 │  │
│  │ ・REST API ルーティング & 静的アセット配信                       │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────┘
                                ▲ HTTP JSON / WebSocket 代替ポーリング
                                │
                      ┌──────────────────┐
                      │ Browser (SPA)    │
                      │ app.js           │
                      │ ・Web Audio 合成 │
                      │ ・Vis-Network    │
                      │ ・Chart.js       │
                      └──────────────────┘
```

---

## 7. 監視エンジンの詳細仕様

### ① デュアルレート監視アーキテクチャ
- `pollInterval <= 100`（0.1秒超高頻度モード）設定時：
  - `highFreqTargetIps` に指定された**最大2台の機器は 0.1秒（100ms）間隔**で超高精度Pingを実行。
  - **その他の監視機器は 5.0秒間隔** でバックグラウンド監視を継続（PC負荷を最小限に抑制）。
- **ディスクIO最適化（10秒バッファリング）**:
  - 超高頻度監視時でもディスク書き込みは内部キューにバッファリングし、10秒周期またはセッション終了時に一括フラッシュすることでストレージ負荷を低減。

### ② SNMP エンジン
- `SharpSnmpLib` を用いて、非同期に各機器の MIB-II（RFC 1213）および IF-MIB をポーリング。
- 送信レート（Tx Mbps）、受信レート（Rx Mbps）、エラーパケット数（InErrors / OutErrors）、破棄パケット数を取得。

---

## 8. 通信品質アルゴリズム（パケロス・ジッター・瞬断）

### ① パケットロス率 (%)
- 直近 30 サンプリングの成否履歴（`RecentResults`）を保持。
$$\text{PacketLossRate} = \left( \frac{\text{FailedCount}}{\text{TotalCount}} \right) \times 100$$

### ② ジッター（RFC 3550 準拠）
- 直近の連続したPing応答遅延（$D_i, D_{i-1}$）の差分絶対値から、指数平滑移動平均を用いてジッター $J$ を算出：
$$D = |Lat_i - Lat_{i-1}|$$
$$J = J + \frac{D - J}{16}$$

### ③ 瞬断最大時間 & 閾値カウント
- 連続オフライン期間の経過時間を秒単位（0.1s精度）でトラッキング。
- 機器がオンラインに復帰した瞬間に、その停止時間が `outageThresh1Ms`（例: 600ms）または `outageThresh2Ms`（例: 5000ms）を超えていた場合に該当カウンターをインクリメント。

---

## 9. 外部通知 & Web Audio 設計

### ① Webhook 送信（`Send-WebhookNotification`）
- 機器のオフライン検知、復旧検知、およびテスト送信時に非同期で JSON POST を実行：
```json
{
  "text": "🔴 **機器オフライン検知**\n・対象機器: コアスイッチ (192.168.10.1)\n・発生時刻: 2026-08-17 19:30:00\n・詳細: 連続タイムアウト発生",
  "content": "🔴 **機器オフライン検知**...",
  "deviceName": "コアスイッチ",
  "ip": "192.168.10.1",
  "eventType": "offline",
  "timestamp": "2026-08-17 19:30:00"
}
```

### ② Web Audio API 音声合成エンジン（外部音声ファイル不要）
- ブラウザの `AudioContext` を使用し、オシレーター（発振器）と GainNode で警告音を直接生成：
  - **障害時（Error）**: 880Hz → 440Hz → 880Hz の鋸歯状波（Sawtooth）高低ビープ音。
  - **警告時（Warning）**: 587.33Hz → 880Hz の正弦波（Sine）ソフトチャイム。

---

## 10. バックアップ・リストア & ログ保守仕様

### ① 完全バックアップ & リストア
- **エクスポート (`GET /api/config/export`)**:
  - `devices.json` の全内容（IP、名前、グループ、座標、SNMP情報）と `config.json` の全パラメータを統合した JSON を生成・ダウンロード。
- **インポート (`POST /api/config/import`)**:
  - アップロードされた JSON を検証後、`devices.json` および `config.json` にアトミック反映し、監視状態を即時リロード。

### ② ログ自動パージ（`Purge-OldReports`）
- サーバー起動時および定期サイクルにおいて、`Reports/` 直下のセッションフォルダー名（`yyyyMMdd_HHmmss`）を検証。
- `logRetentionDays`（デフォルト: 30日）を超過したフォルダーを再帰的に自動安全削除。

---

## 11. REST API エンドポイント一覧

| メソッド | パス | 説明 |
| :--- | :--- | :--- |
| `GET` | `/api/status` | 全デバイスの最新ステータス（Ping、遅延、パケロス率、ジッター、Tx/Rx、瞬断時間） |
| `GET` | `/api/devices` | 登録デバイス一覧の取得 |
| `POST` | `/api/devices` | デバイスの追加・更新・削除 |
| `POST` | `/api/device/toggle` | 指定IPの監視一時停止/再開切り替え |
| `GET` | `/api/config` | システム設定（監視間隔、Pingサイズ、閾値、通知設定等）の取得 |
| `POST` | `/api/config` | システム設定の更新・保存 |
| `GET` | `/api/config/export` | 機器・システム設定の完全バックアップ JSON ダウンロード |
| `POST` | `/api/config/import` | バックアップ JSON のアップロード・復元適用 |
| `POST` | `/api/webhook/test` | Webhook URL のテスト通知送信 |
| `GET` | `/api/topology` | トポロジー接続・座標情報の取得 |
| `POST` | `/api/topology` | トポロジー接続・座標情報の保存 |
| `GET` | `/api/iperf` | Iperf3 計測の開始 (`action=start`) および状態取得 (`action=status`) |
| `GET` | `/api/mtr` | MTR 経路診断の開始・結果取得 |

---

## 12. セキュリティ & 入力サニタイズ仕様

- **IPアドレス検証**: IPv4 正規表現 `^\d{1,3}(\.\d{1,3}){3}$` による厳格なオクテット範囲検証。
- **Iperf3 オプションサニタイズ**: 英数字・ハイフン・スペース以外の特殊記号（`;`, `&`, `|`, `` ` `` 等）を完全除去し、コマンドインジェクションを遮断。
- **アトミックファイル書き込み**: 設定ファイルの保存時は一時ファイル（`.tmp`）に書き込み完了後、`Move-Item -Force` でアトミックに差し替え（書き込み途中の破損防止）。

---

## 13. トラブルシューティング

| 現象 | 想定原因 | 対処方法 |
| :--- | :--- | :--- |
| **起動時にポート重複エラー** | ポート 8081 が他プロセスで使用中 | `Server.ps1` 先頭の `$port = 8081` を別のポートに変更 |
| **Ping が通らない** | 対象機器の ICMP 応答が無効 | 対象機器のファイアウォールで ICMP Echo を許可 |
| **Webhook が届かない** | URL 誤りまたはネットワーク制限 | ⚙️ システム設定の「🔔 テスト送信」でエラーメッセージを確認 |
| **バックアップ復元に失敗** | JSON フォーマット不正 | エクスポート機能で生成された正規の JSON ファイルか確認 |

---

## 14. 既知の制限事項 & 大規模（50台）監視設計

1. **50台規模の標準対応**: 非同期並列 Ping（`SendPingAsync`）および 10秒バッファリング一括書込により、50台同時監視時でも低CPU負荷・低ディスクIOで安定稼働します。
2. **超高頻度モード（0.1s）の対象台数**: PC負荷および通信帯域の最適化のため、0.1s 監視対象は最大 2 台までとなります（他48台は 5.0s 間隔でバックグラウンド継続）。
3. **セッション終了時の瞬断扱い**: セッション終了時点で継続中の瞬断は「瞬断中時間」として記録され、復帰回数カウントには含まれません。
