# 🌐 Network Device Monitor & Diagnostic Tool

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%2F%207%2B-blue.svg?logo=powershell)](https://microsoft.com/powershell)
[![Frontend](https://img.shields.io/badge/Frontend-HTML5%20%2F%20CSS3%20%2F%20JavaScript-yellow.svg)](https://developer.mozilla.org/en-US/docs/Web/JavaScript)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows-0078D6.svg?logo=windows)](https://www.microsoft.com/windows)

**Windows PowerShell 製バックエンドHTTPサーバーとモダンSPAフロントエンド（Vis-Network / Chart.js / Web Audio）で構成された、エージェントレス型のオールインワン・ネットワーク機器監視＆診断ツールです。**

---

## 🌟 主な機能 (Key Features)

| カテゴリ | 機能 | 説明 |
| :--- | :--- | :--- |
| **⚡ 死活監視 (Ping)** | **デュアルレート高精度Ping** | 通常監視（1.0s等）に加え、最重要機器2台を0.1秒、他機器を5.0秒で並行監視するデュアルレート監視をサポート。 |
| **📡 Syslog / SNMP Trap 受信** | **機器からの通知を一覧表示** | 登録済みの機器から届く Syslog と SNMP Trap（v1 / v2c）を受信し、重要度付きで表示。未登録の相手からのものは無視し、件数を画面に表示。実際の受信ポートも画面で確認可能。 |
| **🧭 経路トレース** | **構成図から右クリックで実行** | このPCから機器までに通る機器を一覧表示し、構成図上でも強調表示。 |
| **📶 OBR 無線接続状況** | **SSID・電波・速度を表示** | OBR にログインして無線の接続状況を 10 秒ごとに確認し、機器カードと構成図に表示。未接続は画面で通知。カードから電波・速度のグラフと切断などの出来事の履歴も確認可能。 |
| **📑 CSV 入出力** | **Excel で一括編集** | 機器一覧を CSV で書き出し・取り込み（同じIPは更新、新しいIPは追加）。 |
| **📊 通信品質解析** | **パケットロス率 & ジッター算出** | 直近サンプリングからのリアルタイムパケット損失率 (%) およびジッター (ms) を自動計算。 |
| **⏱ 稼働タイムライン** | **到達性ヒートマップ** | 画面上部に直近の稼働品質（緑: 正常 / 黄: 高遅延 / 赤: 障害 / 灰: 停止）をカラーバーで時系列表示。 |
| **🔔 外部・音声アラート** | **Webhook & Web Audio 音声通知** | Slack/Teams/Discord への自動 Webhook POST、およびブラウザ側でのビープ/チャイム音波合成アラート。 |
| **🌐 トポロジー可視化** | **動的リンクアラートマップ** | `Vis-Network` による機器配置・接続線描画。障害・高遅延時に接続線が赤・黄へと動的カラーチェンジ。 |
| **🔍 SNMP 診断** | **SNMP v2c / v3 詳細情報取得** | インターフェース使用量、Tx/Rx帯域、エラーパケット、システム情報をエージェントレスで収集。 |
| **🔧 リモート機器制御** | **SSH / WinRM / カスタム遠隔制御** | 登録機器に対するワンクリック遠隔再起動および任意コマンド実行。Windows DPAPI によるパスワード暗号化保管、プリセットコマンド管理を完備。 |
| **🔒 他のPC・外部サイト遮断 & コマンド注入防止** | **接続元の確認・CSRF 対策 & 安全な引数受け渡し** | このPC以外からの接続は接続元のアドレスで判定して `403` で遮断。合言葉のない要求も `401` で拒否し、同じPCの他のユーザーからの操作を防止。監視画面以外のWebサイトからの API 呼び出しも `Origin` / `Sec-Fetch-Site` ヘッダーで判定して `403` で遮断し、別サイトの画面への埋め込みも禁止。SSH/WinRM のコマンドは正しくエスケープ・環境変数経由で渡し、監視PC上で意図しない命令が動くことを防止。 |
| **🛡️ 安全二重確認 & ログ出力** | **誤操作防止ダイアログ & ターミナル** | 対象機器名・IPを明示する二重確認モーダルによる安全防護。実行結果・終了コード・stdout/stderrをリアルタイムターミナル出力。 |
| **📋 機器ログ遠隔取得** | **カルテ閲覧・プリセット & 安全保護** | Cisco/Yamaha/Linux/Windowsのシステムログ（syslog/journalctl/イベントログ）をワンクリック遠隔取得。等幅ダークビューアー、リアルタイム検索ハイライト・絞り込み、1MB/5MB二重保護、ローカル保存・再ダウンロード完備。 |
| **📋 操作履歴 & 監査ログ** | **改ざん防止 Audit Log & UI Viewer** | 全ての変更操作およびリモート制御履歴を `Reports/audit.log` へ永続記録。画面ヘッダーの操作履歴モーダルから即座に確認可能。 |
| **🚀 帯域計測** | **Iperf3 統合スループット診断** | 同梱の `iperf3` をバックグラウンドで自動制御し、実効スループットをライブ計測・ログ保存。UDP の計測ではサーバー側のログも自動で受け取り、別ファイルとしてダウンロード可能（計測中にブラウザを閉じても取得まで完了）。 |
| **📡 UI切断耐性 & 自動復旧** | **切断検知バナー & 自動トースト** | 3回連続ステータス取得失敗で切断警告バナー表示、通信復旧時に自動復旧トースト表示。30 FPS間引きで低CPU負荷。 |
| **⏱ 24/7 常時稼働 & 耐障害性** | **無人連続運用 & 例外自己防護** | ブラウザ切断時の自動終了を解除する無人モード（`autoShutdownOnDisconnect: false`）、ソケット切断例外自己吸収、動的瞬断・復旧追跡を完備。 |
| **💾 バックアップ & 復元** | **1クリック設定エクスポート/インポート** | 登録機器リスト・トポロジー座標・監視パラメータを1つの JSON として即座にバックアップ・復元。 |
| **📑 レポート & 保守** | **日本語CSVサマリー & 自動パージ** | セッション終了時に詳細な日本語サマリーブロックを出力。指定日数を超えた古いログの自動クリーンアップ。 |
| **🧪 総合自動テスト** | **テストスイート統合検証** | 機器ログ取得、ユニット、リモート制御、通知、Runspace統合、E2E、ブラウザUI自動検証をワンクリック（`Run-Tests.bat`）で一括実行。 |
| **🛠️ 簡単セットアップ** | **ワンクリック起動** | 外部Webサーバー不要。`Start-Monitor.bat` をダブルクリックするだけで即座にローカルサーバーが起動。 |

---

## 🏗️ システム構成 (Architecture)

```mermaid
graph TD
    subgraph Client["ブラウザ SPA (system/public/)"]
        UI["ダッシュボード (index.html / app.js)"]
        Banner["切断検知バナー & 再接続トースト"]
        RemoteUI["リモート操作タブ & 安全二重確認ダイアログ & ターミナルコンソール"]
        Chart["Chart.js / Vis-Network (30 FPS)"]
    end

    subgraph Backend["PowerShell HTTP Server (system/Server.ps1)"]
        HTTP["HTTP Listener (/api/*)"]
        SyncHash["スレッド同期データ ($syncHash)"]
        
        subgraph Runspaces["並行ワーカー (Runspaces) & 実行モジュール"]
            PingRS["PingEngine (デュアルレート)"]
            SnmpRS["SnmpService (v2c/v3 帯域収集)"]
            RemoteRS["RemoteExec (SSH / WinRM / Custom 実行エンジン & 機器ログ取得)"]
            BwRS["IperfRunner (帯域計測)"]
            MacRS["ARP / MAC アドレス解決"]
            SyslogRS["Syslog リスナー (UDP 514)"]
        end
    end

    subgraph Storage["データ蓄積 & レポート"]
        Config["設定 / 機器構成 (config.json, devices.json - DPAPI暗号化)"]
        AuditLog["操作履歴・監査ログ (Reports/audit.log)"]
        DeviceLogs["機器カルテ・ログ保存 (Reports/device_logs/ - 削除保護)"]
        Reports["セッション記録 (Reports/ *.csv, *.html)"]
        Backups["スナップショット退避 (backups/)"]
    end

    subgraph TestSuite["自動テスト検証基盤 (system/tests/)"]
        TestRunner["Run-Tests.bat / Run-Tests.ps1"]
        DeviceLogTests["機器ログ取得・バッファ保護・API検証"]
        PesterTests["ユニット & Runspace統合テスト"]
        RemoteTests["RemoteExec 単体・統合テスト"]
        E2ETests["E2Eライフサイクル検証"]
        UITests["Playwright ブラウザUI検証"]
    end

    UI <-->|REST API / HTTP JSON| HTTP
    RemoteUI <-->|POST /api/device/remote-exec| HTTP
    HTTP <--> SyncHash
    SyncHash <--> PingRS
    SyncHash <--> SnmpRS
    SyncHash <--> RemoteRS
    SyncHash <--> BwRS
    SyncHash <--> MacRS
    SyncHash <--> SyslogRS
    Backend --> Config
    Backend --> AuditLog
    Backend --> Reports
    Backend --> Backups
```

---

## 📁 ディレクトリ構成 (Directory Structure)

本リポジトリは、運用担当者が日常的に使用する **「ユーザー操作部」**、監視処理やAPIを担う **「システム内部実装部」**、そしてシステムの品質を保証する **「自動テスト検証部」** の3層に明確に分離されています。

```
NetworkDeviceMonitor/
│
├── 📂 【ユーザー操作部】（プロジェクトルート）
│   ├── Start-Monitor.bat              # 🚀 起動用バッチファイル（Windows監視サーバー一発起動）
│   ├── 利用手順書.html                  # 📘 エンドユーザー・運用担当者向け利用マニュアル（平易な用語解説付き）
│
├── 📂 【隠しフォルダ】（普段は見えません）
│   ├── .github/                       # 📖 README.md（本ドキュメント）・LICENSE
│   └── .claude/                       # 開発ツール用の CLAUDE.md
│
├── 📂 【システム内部実装部】（system/ フォルダ）
│   ├── Server.ps1                     # メインバックエンドHTTPサーバー＆監視コーディネーター
│   ├── Stop-All.bat                   # 機器ごとの監視ウィンドウを一括終了
│   ├── GEMINI.md / CYCLE.md           # 開発の運用ルール・自律サイクルの手順
│   ├── Watchdog.ps1                   # 監視サーバー外形死活監視＆自己治癒（自動再起動）
│   ├── Check-Prerequisites.ps1        # 前提モジュール自動検査・インストール
│   ├── Ensure-Utf8Bom.ps1             # PowerShell 5.1 文字化け防止（UTF-8 BOM）検証ツール
│   ├── config.json                    # システム全体設定ファイル（Git の管理対象外）
│   ├── devices.json                   # 監視対象デバイス設定ファイル（社内の機器情報が入るので Git の管理対象外）
│   ├── devices.example.json           # devices.json の形式の見本
│   ├── 管理者向け設計書.html            # 管理者・開発者向け詳細設計書
│   ├── SPECIFICATION.md               # システム機能仕様書
│   ├── modules/                       # バックエンド機能モジュール群
│   │   ├── Common.psm1                # 共通処理・Runspace生成・設定JSON暗号化保存（DPAPI）
│   │   ├── RemoteExec.psm1            # 🔧 リモート制御実行エンジン（SSH / WinRM / カスタム・安全タイムアウト管理）
│   │   ├── PingEngine.psm1            # 高精度Ping死活監視・パケットロス・ジッター計算
│   │   ├── SnmpService.psm1           # SNMP v2c/v3 トラフィック・インターフェース情報取得
│   │   ├── ReportGenerator.psm1       # CSVセッション記録・点検報告書（HTML）生成
│   │   ├── AlertManager.psm1          # Webhook通知・音声アラート・消音タイマー管理
│   │   └── IperfRunner.psm1           # 帯域計測（iperf3）実行管理
│   ├── backups/                       # 機器構成・設定の自動スナップショット退避先（最新20世代）
│   ├── iperf3.18_64/                  # iperf3 実行バイナリ
│   └── public/                        # フロントエンド静的アセット (SPA)
│       ├── index.html                 # メインSPA画面（リモート操作・二重確認モーダル搭載）
│       ├── third-party-notices.html   # 同梱ソフトウェアのライセンス表記
│       ├── style.css                  # カスタムスタイルシート（レスポンシブ・警告スタイル・ターミナルコンソール）
│       ├── app.js                     # UI制御・Chart.jsグラフ描画・リモート操作制御・切断復旧ハンドラー
│       ├── chart.js                   # チャート描画ライブラリ
│       └── vis-network.min.js         # トポロジー図描画エンジン
│
├── 📂 【自動テスト検証部】（system/tests/ フォルダ）
│   ├── Run-Tests.bat                  # 🧪 自動テスト一括実行ランチャー（ワンクリック実行）
│   ├── Run-Tests.ps1                  # ⚙️ 自動テスト総合管理スクリプト（PowerShell実行用）
│   ├── Run-InCopy.ps1                 # 🧳 一時フォルダのコピーで全テストを実行（実機の設定を使わない）
│   ├── AppJs.Tests.ps1                # 🟨 app.js の関数のテスト（Node.js がなければ省略）
│   ├── app-functions.check.js         # 🟨 上のテストの本体
│   ├── AlertManager.Tests.ps1         # 🔔 Webhook・メール通知テスト（このPC内の模擬サーバーで確認）
│   ├── DeviceLog.Tests.ps1            # 📋 機器ログ取得テスト（プリセット・安全性・バッファ保護・API検証）
│   ├── Monitor.Tests.ps1              # 🔬 ユニットテスト（個別モジュール機能検証）
│   ├── RemoteExec.Tests.ps1           # 🔧 リモート制御テスト（SSH/WinRM/カスタム実行・タイムアウト・DPAPI暗号化・監査ログ）
│   ├── Tools.Tests.ps1                # 🧰 帯域計測の部品・文字コード検査ツールのテスト
│   ├── Runspace.Tests.ps1             # 🔄 Runspace統合テスト（並行スレッド動作・API契約検証）
│   ├── ObrScenario.Tests.ps1          # 📶 模擬 OBR を相手にした無線確認の通しテスト（80番ポートが使えなければ省略）
│   ├── Auth.Tests.ps1                 # 🔑 合言葉による認証のテスト
│   ├── Scan.Tests.ps1                 # 🔍 スキャン結果の機器情報のテスト
│   ├── LogSource.Tests.ps1            # 📡 Syslog / Trap の送信元の絞り込みのテスト
│   ├── IperfServerLog.Tests.ps1       # 🚀 iperf3 のサーバー側ログの取得の通しテスト（iperf3.exe がなければ省略）
│   ├── E2E-Lifecycle.Tests.ps1        # 🚀 E2Eライフサイクル検証（起動→監視→終了→CSV生成の通し確認）
│   └── ui_verification.py             # 🌐 ブラウザUI自動テスト（Playwright画面検証・切断バナー動作）
│
└── 📂 【レポート出力先】（Reports/ フォルダ）
    ├── audit.log                      # 🛡️ 操作履歴・監査ログ（設定変更・リモート再起動・コマンド実行記録）
    ├── device_logs/                   # 📋 取得済み機器ログ保管先（{IP}_{日時}.log - パージ保護）
    └── sessions/ (起動日時)/          # 実行時ログ・CSVサマリーレポート・点検報告書HTML（自動生成）
```

---

## 🚀 起動方法 (Quick Start)

### 前提要件
* **OS**: Windows 10 / 11 / Windows Server 2016 以降
* **PowerShell**: Windows PowerShell 5.1 または PowerShell 7+
* **ブラウザ**: Google Chrome / Microsoft Edge / Firefox

### 監視の開始手順
1. 本リポジトリをクローンまたはダウンロードします。
   ```bash
   git clone https://github.com/Shuntaro1996/network-device-monitor.git
   ```
2. フォルダ内の **`Start-Monitor.bat`** をダブルクリックします。
3. 自動的にブラウザが起動し、監視ダッシュボード（`http://localhost:8081`）が表示されます。

> **💡 選択プロンプトの自動進行について**:
> システム起動時やセットアップ確認時の選択肢プロンプトは、運用ルールに基づき原則として「4」を選択したものとしてスムーズに自動進行します。

---

## 🧪 自動テスト実行手順 (Automated Testing)

本システムには、システムの健全性をワンクリックで総合検査できる自動テストスイートが備わっています。

### 実行手順
- **ワンクリック実行（推奨）**:
  `system\tests\Run-Tests.bat` をダブルクリックします。
- **PowerShell コマンド実行**:
  ```powershell
  powershell.exe -ExecutionPolicy Bypass -File .\system\tests\Run-Tests.ps1
  ```
  詳細な合否結果を表示したい場合は `-VerboseOutput` スイッチを付与します：
  ```powershell
  powershell.exe -ExecutionPolicy Bypass -File .\system\tests\Run-Tests.ps1 -VerboseOutput
  ```

- **実機の設定を使わずに実行（動作中の監視と重ねないとき）**:
  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\system\tests\Run-InCopy.ps1
  ```

### テストスイート構成
1. **機器ログ取得テスト (`system/tests/DeviceLog.Tests.ps1`)**:
   Cisco/Yamaha/Linux/Windows各プリセット整合性、リモート無効時ガード、1MB画面切り詰め・5MBディスク保存ガード、プロセスタイムアウト強制終了、自己記述ヘッダー保存、名前付きミューテックス排他制御監査ログ、パストラバーサル遮断を含むHTTP REST APIを網羅検証。
2. **ユニットテスト (`system/tests/Monitor.Tests.ps1`)**:
   コアモジュールの個別機能（DPAPI暗号化、遅延・パケットロス閾値判定、TCPポート監視、サマリー集計、古いログの自動パージ等）を検証。
3. **リモート制御テスト (`system/tests/RemoteExec.Tests.ps1`)**:
   リモート制御エンジン（SSH / WinRM / カスタム）の安全性、入力バリデーション、タイムアウト監視（プロセス強制終了）、DPAPI暗号化保存、および操作履歴（Audit Log）出力を網羅的に検証。
4. **Runspace統合テスト (`system/tests/Runspace.Tests.ps1`)**:
   6大ヘルパーモジュールの並行スレッド読み込み、高負荷マルチスレッド環境でのデータ競合耐性、REST API（`/api/health`, `/api/status`, `/api/devices`, `/api/syslog`, `/api/shutdown`）の契約検証に加え、ホスト瞬断・復旧遷移、ソケット例外時のRunspace生存性、24時間無人稼働モードを検証。
5. **E2Eライフサイクル検証 (`system/tests/E2E-Lifecycle.Tests.ps1`)**:
   サーバープロセスの起動から死活監視確認、安全なシャットダウン、CSVサマリーログ生成までの一連のライフサイクルを通しで検証。
6. **ブラウザUI自動テスト (`system/tests/ui_verification.py`)**:
   Playwright ヘッドレスブラウザによる画面レイアウト描画、各種ボタン操作、切断検知バナー（`#network-offline-banner`）と自動再接続トーストの動作検証。
7. **通知テスト (`system/tests/AlertManager.Tests.ps1`)**:
   Webhook とメールの送信を、このPC内の模擬サーバーで検証。
8. **ツールの部品テスト (`system/tests/Tools.Tests.ps1`)**:
   iperf3 のオプションの組み立てと安全確認、ログの巻き戻し、文字コード検査ツールを検証。
9. **app.js の関数テスト (`system/tests/AppJs.Tests.ps1`)**:
   画面に触らない関数を Node.js で検証（Node.js がなければ省略）。
10. **OBR の通しテスト (`system/tests/ObrScenario.Tests.ps1`)**:
   模擬 OBR を相手にサーバーを実際に動かし、確認間隔、ログイン、履歴 API を検証（80番ポートが使えなければ省略）。

> **💡 テストの件数**: 件数は変わっていくので、ここには書きません。実行後に画面の最後に表示される `Total` / `Passed` / `Failed` を確認してください。自動テストは主に模擬の相手で確かめるもので、実機の OBR や SNMP 機器での動作は別途確認が必要です。

---

## 📖 ドキュメント (Documentation)

* **運用者・一般ユーザー向け操作マニュアル**: [利用手順書.html](../利用手順書.html)
  - 初心者・運用者向けに **専門用語（Runspace、Pester、ジッター、E2E、AST構文解析など）の平易なやさしい解説** を掲載しています。
* **管理者・開発者向け詳細設計書**: [system/管理者向け設計書.html](../system/管理者向け設計書.html)
* **同梱ソフトウェアのライセンス表記**: [system/public/third-party-notices.html](../system/public/third-party-notices.html)
* **機能詳細仕様書**: [system/SPECIFICATION.md](../system/SPECIFICATION.md)

---

## 👤 作成者 (Author)

* **GitHub**: [@Shuntaro1996](https://github.com/Shuntaro1996)

---

## 📄 ライセンス (License)

本プロジェクトは [MIT License](LICENSE) のもとで公開されています。
