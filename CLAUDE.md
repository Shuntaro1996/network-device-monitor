# CLAUDE.md

運用ルール・行動規範は GEMINI.md を正とし、そのまま従うこと。

@GEMINI.md

## 概要

Windows 専用のネットワーク機器監視ツール。PowerShell 製の HTTP サーバーと、ビルド工程のない素の HTML/JS による SPA で構成される。

- `Start-Monitor.bat` → `system/Watchdog.ps1 -RunPreflight -LaunchBrowser` → `system/Server.ps1` の順に起動する。サーバーは `HttpListener` で `http://localhost:8081` を待ち受ける。
- `system/Server.ps1`（約 6,700 行）
  - 1 本のループで `/api/*` のルーティングと静的ファイル配信を行う。
  - Ping・SNMP・Syslog などは Runspace で並行に動かし、データは `$syncHash` で共有する。
  - 時間のかかる処理は `Start-BackgroundScript`（RunspacePool `$asyncWorkerPool`）で実行し、メインループを止めない。
- `system/modules/*.psm1`
  - Common：DPAPI、監査ログ、CSRF 判定など
  - PingEngine、SnmpService、RemoteExec、IperfRunner、AlertManager、ReportGenerator、ObrStatus
  - Runspace 内では関数が見えないため、各スクリプトブロックで明示的に `Import-Module` するか、`$iss` に登録する。
- `system/public/`：`index.html` / `app.js`（約 8,800 行）/ `style.css`。vis-network と Chart.js は同梱のファイルを使い、npm は使わない。
- 設定ファイルは `system/config.json` と `system/devices.json`。社内の機器情報が入るので git の管理対象外で、形式の見本は `system/devices.example.json`。パスワードは DPAPI で暗号化して保存する。実行時の生成物は `Reports/` に出力され、git の管理対象外。

## テスト

- テストは Pester 3.4.0 で、Windows PowerShell 5.1（`powershell.exe`）を使って実行する。
  - pwsh 7 では一部が動かない（例：`Add-Type -OutputType ConsoleApplication`）。
  - PowerShell ツールは pwsh 7 で動くため、`powershell.exe` を明示的に呼ぶ。
- 全体のテスト：`system\tests\Run-Tests.bat`。E2E のテストは標準で実行される。UI のテストは `-All` か `-IncludeUI` を付けたときだけ実行される。
- コピーでの全テスト：`system\tests\Run-InCopy.ps1`。一時フォルダのコピーで実行し、`devices.json` と `config.json` は使わない。合否は終了コードで返す。
- 個別のテスト：
  ```
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command 'Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Script system\tests\RemoteExec.Tests.ps1 -PassThru -Quiet'
  ```
- この PC ではアプリ制御（Smart App Control）が、生成した exe の実行をブロックする。テストでは exe をコンパイルして起動せず、`Add-Type` による P/Invoke などメモリ内で完結する方法を使う。

## 文字コード・改行（壊すと PS 5.1 で文字化け・構文エラーになる）

- `.ps1` / `.psm1` は **UTF-8 BOM 付き** にする。`system/Ensure-Utf8Bom.ps1` と `Run-Tests.ps1` が BOM の有無を検査・付与する。新しいファイルにも BOM を付けること。
- `.bat` は **Shift_JIS（CP932）** で、先頭で `chcp 932` を実行している。UTF-8 で保存し直さないこと。
- 改行コードはファイルごとに異なる。例：`Server.ps1` と `利用手順書.html` は CRLF、`RemoteExec.psm1` は LF。編集するときは既存の改行コードに合わせる。

## セキュリティ上の前提（変更時に崩さないこと）

- 全リクエストはルーティングの前に `Test-ClientAddressAllowed`（接続元がこのPC自身かの検査）を通す。`Host` ヘッダーは偽れるので判定に使わない。
- `/api/*` はルーティングの前に `Test-ApiRequestAllowed`（`Origin` / `Sec-Fetch-Site` の検査）を通す。`Access-Control-Allow-Origin: *` は返さない。
- リモート実行の引数は `ConvertTo-ProcessArgument` でエスケープする。パスワードやコマンドは環境変数経由で渡し、コマンドライン文字列に直接埋め込まない。
- UI で動的な値を `innerHTML` に入れるときは、必ず `escapeHTML()` を通す。

## 作業上の注意

- 仕様・機能を変更したら、`README.md` / `system/SPECIFICATION.md` / `利用手順書.html` を同時に更新する（GEMINI.md の §2）。
- `利用手順書.html` はビルド工程のない 1 枚の HTML なので、直接編集する（CSS と JS もファイル内に含まれ、外部ファイルは読み込まない）。`system/管理者向け設計書.html` と `system/public/third-party-notices.html` も同じ作りで、直接編集する。
- プロジェクト直下には、利用者が使うもの（`Start-Monitor.bat` / `Stop-All.bat` / `利用手順書.html` / `Reports/`）と、ツールや GitHub が直下を前提とするもの（`README.md` / `LICENSE` / `CLAUDE.md` / `GEMINI.md` / `.gitignore`）だけを置く。それ以外は `system/` に入れる。
- コード内のコメントは日本語で、「初心者向けの簡単な解説」という既存のスタイルに合わせる。
- コードを追加・修正するときは、あとから修正しやすいよう、事細かく説明を書く。関数や処理のまとまりごとに、目的・入力と結果・なぜその方法にしたのか・変更するときの注意点を書く。コードをそのまま言い換えるだけの説明にはしない。
