# 🌐 Network Device Monitor & Diagnostic Tool — README（管理者向け）

**対象読者**: システムの導入・構成管理・トラブルシューティングを担当する管理者

---

## 📋 目次

1. [システム概要](#1-システム概要)
2. [ファイル・ディレクトリ構成](#2-ファイルディレクトリ構成)
3. [動作要件と前提条件](#3-動作要件と前提条件)
4. [起動・停止手順](#4-起動停止手順)
5. [設定ファイルの詳細](#5-設定ファイルの詳細)
6. [アーキテクチャ概要](#6-アーキテクチャ概要)
7. [監視エンジンの仕様](#7-監視エンジンの仕様)
8. [セキュリティ設計（サニタイズ仕様）](#8-セキュリティ設計サニタイズ仕様)
9. [JSON保存処理の設計](#9-json保存処理の設計)
10. [デバッグとログ管理](#10-デバッグとログ管理)
11. [ログのローテーション仕様](#11-ログのローテーション仕様)
12. [主要APIエンドポイント一覧](#12-主要apiエンドポイント一覧)
13. [トラブルシューティング](#13-トラブルシューティング)
14. [既知の制限事項](#14-既知の制限事項)

---

## 1. システム概要

本システムは **PowerShell製のHTTPサーバー** をバックエンドとし、ブラウザ上のSPAでネットワーク機器の状態を一元管理するツールです。

### 主要機能

| 機能 | 実装方式 | 説明 |
|------|----------|------|
| **死活監視 (Ping)** | .NET `System.Net.NetworkInformation.Ping` | 指定間隔でICMP Echo を送出 |
| **SNMP監視** | SharpSnmpLib / PowerShell SNMPモジュール | v2c/v3に対応。MIB-II + HOST-RESOURCES-MIB |
| **経路診断 (MTR)** | `tracert` をバックグラウンド実行 | ホップごとの遅延・パケットロスを可視化 |
| **帯域計測 (Iperf3)** | 同梱の `iperf3.18_64` を非同期実行 | ライブコンソール出力・ログ保存 |
| **トポロジー可視化** | vis-network.js | CDP/LLDP自動検出 + 手動リンク編集 |
| **履歴トレンド** | 内部リングバッファ (max 1440エントリ/機器) | 過去24時間の遅延・通信量グラフ |

---

## 2. ファイル・ディレクトリ構成

```
NetworkDeviceMonitor/
├── Start-Monitor.bat              ← 起動スクリプト
├── 利用手順書.md                  ← 利用者向け手順書
├── Reports/                       ← 実行時ログ出力先
│   └── <yyyyMMdd_HHmmss>/
│       ├── ping_<IP>.csv          ← Ping履歴（5MBローテーション、最大3世代）
│       └── iperf_<target>_<ts>.log ← Iperf3計測ログ
└── system/
    ├── Server.ps1                 ← ★メインバックエンドサーバー
    ├── Launcher.ps1               ← 個別デバイス監視ランチャー
    ├── Measure-Bandwidth.ps1      ← SNMPによる帯域計算ロジック
    ├── Monitor-SingleDevice.ps1   ← 単体デバイス監視スクリプト
    ├── Start-BandwidthServer.ps1  ← 帯域監視補助サーバー
    ├── devices.json               ← 監視対象デバイス設定（自動保存）
    ├── config.json                ← グローバル設定（自動保存）
    ├── debug.log                  ← ★エラーログ（バックグラウンド例外を記録）
    ├── iperf3.18_64/              ← Iperf3バイナリ（同梱）
    └── public/                    ← フロントエンド静的ファイル
        ├── index.html             ← メインUI（グラスモーフィズムデザイン）
        ├── app.js                 ← フロントエンドロジック（API通信・グラフ等）
        ├── chart.js               ← Chart.js（トレンドグラフ描画）
        └── vis-network.min.js     ← vis-network（トポロジー図描画）
```

---

## 3. 動作要件と前提条件

| 要件 | 詳細 |
|------|------|
| **OS** | Windows 10/11、Windows Server 2019以降 |
| **PowerShell** | 5.1以上（標準搭載） |
| **ブラウザ** | Chrome / Edge / Firefox 最新版 |
| **ポート** | TCP 8081（ファイアウォールで開放が必要な場合あり） |
| **ネットワーク** | 管理用PCから監視対象機器へのICMP(Ping)が通ること |
| **SNMP（任意）** | 対象機器でSNMP v2c または v3 が有効になっていること |
| **PowerShell SNMP モジュール（任意）** | `Install-Module SNMP` で事前インストール推奨 |

### SNMP モジュールのインストール（管理者PowerShellで実行）

```powershell
Install-Module -Name SNMP -Scope CurrentUser -Force
```

---

## 4. 起動・停止手順

### 起動

```bat
Start-Monitor.bat をダブルクリック
```

内部では以下が実行されます：

```powershell
powershell.exe -ExecutionPolicy Bypass -File "system\Server.ps1"
Start http://localhost:8081
```

### 停止

バックグラウンドのPowerShellウィンドウを **閉じる** か、`Ctrl+C` で停止します。

### ポート番号の変更

`system/Server.ps1` の先頭付近にある以下の行を変更します：

```powershell
$port = 8081  # ← ここを変更
```

---

## 5. 設定ファイルの詳細

### `system/config.json`

システム全体のグローバル設定。UIからの変更が自動反映されます。

```json
{
    "pollInterval":      1000,     // Ping監視間隔（ms）。最小100（超高頻度モード）
    "pingDataSize":      1,        // ICMPパケットのデータサイズ（bytes）
    "loggingEnabled":    true,     // Ping履歴CSVへの書き出し有効/無効
    "highFreqTargetIps": "",       // 超高頻度モード（<=100ms）時のPing対象IP（カンマ区切り、最大2台）
    "outageThresh1Ms":   600,      // 瞬断カウント閾値①（ms）。この時間以上の瞬断を回数カウント
    "outageThresh2Ms":   5000      // 瞬断カウント閾値②（ms）。この時間以上の瞬断を回数カウント
}
```

> ⚙️ `outageThresh1Ms` / `outageThresh2Ms` はサイドバーの **「⚡ 瞬断カウント閾値」** 欄から変更可能です。Enter または Tab で確定すると即時保存されます。

### `system/devices.json`

監視対象機器の設定。UIで機器を追加/削除/変更すると自動保存されます。**手動編集は推奨しません。**

```json
[
  {
    "ip":           "192.168.1.1",
    "name":         "コアスイッチ",
    "community":    "public",
    "group":        "1F",
    "image":        "switch",
    "enabled":      true,
    "connectedTo":  "192.168.1.254",
    "x":            100,
    "y":            200,
    "mac":          "AA:BB:CC:DD:EE:FF",
    "snmpVersion":  "v2c",
    "snmpUser":     "",
    "snmpAuthProto":"none",
    "snmpAuthPass": "",
    "snmpPrivProto":"none",
    "snmpPrivPass": ""
  }
]
```

---

## 6. アーキテクチャ概要

```
┌─────────────────────────────────────────────────────────────┐
│  Server.ps1 (メインスレッド)                                │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  $syncHash (Synchronized Hashtable)                   │  │
│  │  共有状態: Devices, Latency, Status, History, ...     │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │ Ping Engine │  │ SNMP Engine │  │ MAC/Topology Engine │  │
│  │ (Runspace)  │  │ (Runspace)  │  │ (Runspace)          │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
│                                                              │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │  HTTP Listener (port 8081)  ← API リクエスト処理        │ │
│  └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                        ▲ HTTP
                        │
              ┌─────────────────┐
              │ Browser (SPA)   │
              │ app.js + UI     │
              └─────────────────┘
```

各監視エンジンは **PowerShell Runspace** で非同期実行され、`$syncHash` 経由で状態を共有します。`Save-DevicesJson` 関数はスレッドセーフなロック（`[System.Threading.Monitor]`）を使用して設定ファイルに書き込みます。

---

## 7. 監視エンジンの仕様

### Ping エンジン

| 項目 | 仕様 |
|------|------|
| 実装クラス | `System.Net.NetworkInformation.Ping` |
| タイムアウト | 通常モード: 1000ms / 超高頻度モード: `Max(80, pollInterval)` ms |
| 並列実行 | 通常モード: 全登録デバイスを並列Ping |
| 超高頻度モード | **最大2台**（`highFreqTargetIps` で指定）を高速Ping |
| 最小間隔 | 100ms（`pollInterval <= 100` の場合に超高頻度モード有効） |
| Min/Max記録 | セッション開始からの最小・最大遅延を各機器ごとに記録 |
| 最大瞬断時間 | 連続してオフライン（Failed）だった最長時間（秒）を機器ごとに記録 |
| 瞬断回数カウント | オフライン→オンライン復帰時に、閾値①・②を超えていた場合にカウント（サイドバーで変更可能） |

#### 超高頻度モード（100ms）の制限事項

- `pollInterval` が 100ms 以下の場合、Ping対象は `highFreqTargetIp` で指定した **1台のみ** に限定されます。
- 他の登録機器への監視は通常頻度（最低1秒間隔）で継続されます。
- ディスクへのCSVログ書き込み周期は監視間隔に関わらず **最低1秒間隔** です（IOバースト防止）。

### SNMP エンジン

| 項目 | 仕様 |
|------|------|
| バージョン対応 | SNMPv2c / SNMPv3 |
| 主要MIB | RFC1213 (MIB-II) / HOST-RESOURCES-MIB / IF-MIB |
| Wi-Fi拡張 | IEEE 802.11 MIB (`dot11CurrentChannel`) |
| 実装ライブラリ | SharpSnmpLib (PowerShell SNMPモジュール経由) |
| ポーリング間隔 | `Max(1, pollInterval / 1000)` 秒 |

---

## 8. セキュリティ設計（サニタイズ仕様）

外部から受け付けるユーザー入力は以下のルールで検証・無害化しています。

### IPアドレス検証

```powershell
# 形式: xxx.xxx.xxx.xxx（各オクテット0-255）
if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { # 400 Bad Request を返す }
```

### Iperf3 カスタムオプション（ホワイトリスト方式）

```powershell
# 英数字・ハイフン・スペースのみ許可（コマンドインジェクション防止）
$safeOpts = ($opts -replace '[^a-zA-Z0-9\-\s]', '')
```

> ⚠️ 特殊文字（セミコロン、バッククォート、パイプ、引用符など）は **すべて自動的に除去** されます。

### ホスト名サニタイズ

```powershell
# DNS名として有効な文字のみ許可
$safeHost = ($host -replace '[^a-zA-Z0-9\-\.]', '')
```

### ロック機構（競合書き込み防止）

- `Save-DevicesJson` 関数は `[System.Threading.Monitor]::Enter($syncHash)` でロックを取得してからJSONを書き込みます。
- 書き込みは `.tmp` ファイルへの出力後に `Move-Item -Force` でアトミックに切り替えます（書き込み途中のファイル破損を防止）。
- 書き込み失敗時は最大5回リトライし、失敗内容を `debug.log` に記録します。

---

## 9. JSON保存処理の設計

### `Save-DevicesJson` 関数の動作

1. `$syncHash.Devices` の全エントリをPowerShellオブジェクト配列 (`$outArray`) に変換
2. `ConvertTo-Json -Depth 5` でJSONに変換（文字列結合は使用しない）
3. 一時ファイル (`devices.json.tmp`) に書き込み
4. `Move-Item -Force` でアトミックにリネーム
5. 失敗した場合は最大5回リトライ

### 設計上のポイント

- 以前の文字列結合によるJSON生成を廃止し、**PowerShellネイティブのオブジェクト→JSON変換**を採用。
- `$saveDevicesJsonScript` スクリプトブロックとして定義し、メインスレッドと全Runspaceで同一ロジックを共有。
- 各Runspace内で `Save-DevicesJson` を呼び出す際は、スクリプトブロックを `.Invoke()` または `. ([scriptblock]::Create(...))` でロードして使用。

---

## 10. デバッグとログ管理

### `system/debug.log`

バックグラウンド処理（Runspace内）で予期しないエラーが発生した場合に記録されます。

**記録される主なエラー:**

| 発生箇所 | 記録内容 |
|----------|----------|
| Ping Engine | PingタイムアウトやRunspace起動失敗 |
| SNMP詳細取得 | SNMP応答エラー、OID解析失敗 |
| MAC/Topology検出 | ARP・LLDP取得失敗 |
| Save-DevicesJson | ファイル書き込みのリトライ失敗 |

**ログフォーマット:**

```
[2026-06-23 10:35:42] Save-DevicesJson error: Access to the path '...' is denied.
[2026-06-23 10:35:43] SNMP detail error for 192.168.1.1: The operation has timed out.
```

**定期メンテナンス**: `debug.log` は自動ローテーションされません。ファイルが大きくなった場合は手動で削除またはアーカイブしてください。

---

## 11. ログのローテーション仕様

### Ping 履歴 CSV（`Reports/<session>/<IP>.csv`）

| 仕様 | 詳細 |
|------|------|
| **自動ローテーション条件** | ファイルサイズが 5MB を超えた場合 |
| **世代管理** | `.1`, `.2`, `.3` の suffix でリネーム（最大3世代） |
| **保持件数** | 最大4ファイル（現行 + 3世代分） |

### CSVサマリーブロック

サーバー停止時（`Ctrl+C` または PowerShell ウィンドウを閉じた時）に、各機器の CSV ファイル末尾に以下のサマリーが**日本語**で自動追記されます。

```
--- サマリー ---
セッション,2026-08-06_07-00-00
IPアドレス,192.168.1.1
総Ping回数,3600
成功,3580
失敗,20
到達率 (%),99.44
遅延 最小 (ms),1
遅延 最大 (ms),45
遅延 平均 (ms),3.20
最大瞬断時間 (秒),20.5
瞬断回数 (600ms 以上),5
瞬断回数 (5000ms 以上),1
備考 (瞬断回数),オフラインからオンラインへ復帰した時点でカウント。セッション終了時点で継続中の瞬断は含まない
```

> ⚠️ 瞬断回数の閾値ラベル（`600ms 以上` / `5000ms 以上`）は、停止時点の設定値が反映されます。

---

## 12. 主要APIエンドポイント一覧

サーバーは `http://localhost:8081` でリッスンします。

| メソッド | パス | 説明 |
|---------|------|------|
| `GET` | `/api/status` | 全デバイスの現在ステータス（Ping, SNMP, 遅延Min/Max, 最大瞬断時間, 瞬断カウント） |
| `GET` | `/api/history?ip=<IP>` | 指定IPの過去24時間の遅延・通信量履歴 |
| `GET` | `/api/devices` | 登録デバイス一覧（名前・グループ・SNMP設定等） |
| `POST` | `/api/devices` | デバイスの追加・更新・削除 |
| `GET` | `/api/config` | 現在のグローバル設定取得（瞬断閾値含む） |
| `POST` | `/api/config` | 設定の更新（pollInterval, pingDataSize, outageThresh1Ms, outageThresh2Ms 等） |
| `POST` | `/api/iperf/start` | Iperf3計測開始 |
| `GET` | `/api/iperf/status` | Iperf3計測の進捗・結果取得 |
| `POST` | `/api/iperf/stop` | Iperf3計測の強制停止 |
| `POST` | `/api/mtr/start` | MTR（経路診断）開始 |
| `GET` | `/api/mtr/status` | MTR結果取得 |
| `GET` | `/api/topology` | トポロジー接続情報の取得 |
| `POST` | `/api/topology` | トポロジー接続情報の保存 |
| `GET` | `/api/snmp/detail?ip=<IP>` | 指定IPのSNMP詳細情報（インターフェース等）取得 |

---

## 13. トラブルシューティング

### ブラウザが開かない / 画面が表示されない

1. PowerShellウィンドウに赤いエラーが出ていないか確認します。
2. ブラウザで `http://localhost:8081` に手動でアクセスします。
3. ポート8081が他のプロセスに使用されていないか確認します：
   ```powershell
   netstat -ano | findstr :8081
   ```
4. `Server.ps1` 先頭の `$port = 8081` を別のポート番号に変更します。

### デバイスが「オフライン」のままになる

1. 管理PCから対象IPへPingが通るか確認します：
   ```powershell
   ping 192.168.1.1
   ```
2. Windowsファイアウォールがブロックしていないか確認します。
3. `system/debug.log` にエラーが記録されていないか確認します。

### SNMP情報が取得できない

1. PowerShell SNMPモジュールがインストールされているか確認します：
   ```powershell
   Get-Module -ListAvailable SNMP
   ```
2. 対象機器のSNMP設定（コミュニティ名、許可IPアドレス）を確認します。
3. v3の場合、認証プロトコル・パスワードの設定が機器側と一致しているか確認します。

### Iperf3計測が始まらない

1. 対象ホストでiperf3サーバーが起動していることを確認します：
   ```bash
   iperf3 -s
   ```
2. ファイアウォールでTCP 5201（デフォルトポート）が開放されているか確認します。
3. カスタムオプション欄に記号が含まれていないか確認します（英数字・ハイフン・スペースのみ有効）。

### `debug.log` にエラーが記録され続ける

- エラー内容を確認し、原因となっている機器・設定を特定してください。
- ファイルロックエラーの場合：監視対象デバイス数を減らすか、`pollInterval` を大きくすることで改善する場合があります。

---

## 14. 既知の制限事項

| 制限 | 詳細 |
|------|------|
| **超高頻度モード（100ms）の同時監視台数** | 最大2台（`highFreqTargetIps` で指定） |
| **SNMP MIB対応範囲** | RFC1213 / HOST-RESOURCES-MIB / IF-MIB のみ。ベンダー固有MIBは非対応 |
| **MTRの精度** | `tracert` コマンドに依存するため、ICMPをブロックするルーターはタイムアウト表示になります |
| **デバイス上限** | 技術的な上限はありませんが、50台以上ではポーリング遅延が発生する場合があります |
| **CSVの精度** | 100ms監視時でもCSV書き込みは最低1秒間隔です（ディスクIO負荷低減のため） |
| **debug.logのローテーション** | 自動ローテーションなし。手動での管理が必要です |
| **瞬断カウントの精度** | 閾値変更前にカウントされた履歴はリセットされません。変更後の復帰イベントから新閾値が適用されます |
| **瞬断カウントのセッション末処理** | セッション終了時点でオフライン継続中の瞬断は、カウントに含まれません（最大瞬断時間には反映済み）|
