@echo off
REM =========================================================================
REM Service-Setup.bat - Windows サービス登録・管理支援ツール
REM =========================================================================
setlocal
cd /d "%~dp0..\.."
chcp 932 >nul

echo =========================================================
echo   Network Device Monitor - Windows サービス登録支援
echo =========================================================
echo.
echo このスクリプトは、Network Device Monitor を Windows サービスとして
echo OS起動時にバックグラウンドで自動実行するためのガイド・設定を行います。
echo.
echo [1] 通常起動（Watchdog付き・推奨）: Start-Monitor.bat を実行
echo [2] 自動起動の登録: Windows にログオンしたときに起動（パスワード入力なし）
echo [3] 自動起動の登録: PC の起動時に起動（ログオン前から動かす／Windows のパスワード入力あり）
echo [4] Windows サービス登録（NSSM を利用した完全バックグラウンド常駐）の手順を表示
echo.
echo ※ [2][3] は、今ログオンしている「%USERDOMAIN%\%USERNAME%」で実行するように登録します。
echo    保存済みのパスワードは、保存した Windows ユーザーでしか復号できないためです。
echo    以前 SYSTEM で登録したタスクも、同じ名前のため上書きされます。
echo.

set /p CHOICE="実行したい番号を選択してください [1/2/3/4/Q]: "
if /i "%CHOICE%"=="1" goto :RUN_NORMAL
if /i "%CHOICE%"=="2" goto :REGISTER_LOGON
if /i "%CHOICE%"=="3" goto :REGISTER_STARTUP
if /i "%CHOICE%"=="4" goto :SHOW_NSSM
goto :EOF

:RUN_NORMAL
start "" "Start-Monitor.bat"
goto :EOF

:REGISTER_LOGON
echo.
echo ログオン時の自動起動を登録します（管理者権限が必要な場合があります）...
schtasks /create /tn "NetworkDeviceMonitor" /tr "\"%~dp0..\..\Start-Monitor.bat\"" /sc onlogon /ru "%USERDOMAIN%\%USERNAME%" /it /f
goto :REGISTER_RESULT

:REGISTER_STARTUP
echo.
echo PC 起動時の自動起動を登録します（管理者権限が必要です）。
echo.
echo 【注意】ログオン前は Google ドライブなどの同期ドライブが使えません。
echo         このフォルダ: %~dp0
echo         同期ドライブ上にある場合は、先に C ドライブなどへ移してから登録してください。
echo.
echo このあと「%USERDOMAIN%\%USERNAME%」の Windows パスワードを聞かれます。
echo 入力した文字は画面に表示されません。Windows のタスク スケジューラが安全に保管します。
schtasks /create /tn "NetworkDeviceMonitor" /tr "\"%~dp0..\..\Start-Monitor.bat\"" /sc onstart /ru "%USERDOMAIN%\%USERNAME%" /rp * /f
goto :REGISTER_RESULT

:REGISTER_RESULT
if errorlevel 1 (
    echo [ERROR] 登録に失敗しました。管理者権限のコマンドプロンプトで実行してください。
) else (
    echo [OK] タスク スケジューラに「NetworkDeviceMonitor」を登録しました。
)
pause
goto :EOF

:SHOW_NSSM
echo.
echo 【NSSM によるサービス登録手順】
echo 1. NSSM ^(https://nssm.cc/^) をダウンロードし、nssm.exe を本フォルダに配置します。
echo 2. 管理者コマンドプロンプトで以下を実行します:
echo      nssm install NetworkDeviceMonitor "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" "-NoProfile -ExecutionPolicy Bypass -File \"%~dp0..\Server.ps1\""
echo      nssm set NetworkDeviceMonitor AppDirectory "%~dp0..\.."
echo      nssm set NetworkDeviceMonitor AppRestartDelay 3000
echo      nssm set NetworkDeviceMonitor ObjectName "%USERDOMAIN%\%USERNAME%" "Windowsのパスワード"
echo      nssm start NetworkDeviceMonitor
echo.
echo ※ ObjectName の設定がないと SYSTEM で動き、保存済みのパスワードを復号できません。
echo ※ 同期ドライブ上では動きません。C ドライブなどへ移してから登録してください。
echo.
pause
goto :EOF
