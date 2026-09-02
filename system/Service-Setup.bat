@echo off
REM =========================================================================
REM Service-Setup.bat - Windows サービス登録・管理支援ツール
REM =========================================================================
setlocal
cd /d "%~dp0.."
chcp 65001 >nul

echo =========================================================
echo   Network Device Monitor - Windows サービス登録支援
echo =========================================================
echo.
echo このスクリプトは、Network Device Monitor を Windows サービスとして
echo OS起動時にバックグラウンドで自動実行するためのガイド・設定を行います。
echo.
echo [1] 通常起動（Watchdog付き・推奨）: Start-Monitor.bat を実行
echo [2] Windows タスクスケジューラでのPC起動時自動起動の登録
echo [3] Windows サービス登録（NSSMを利用した完全バックグラウンド常駐）
echo.

set /p CHOICE="実行したい番号を選択してください [1/2/3/Q]: "
if /i "%CHOICE%"=="1" (
    start "" "Start-Monitor.bat"
    goto :EOF
)
if /i "%CHOICE%"=="2" (
    echo.
    echo タスクスケジューラに登録します（管理者権限が必要）...
    schtasks /create /tn "NetworkDeviceMonitor" /tr "\"%~dp0..\Start-Monitor.bat\"" /sc onstart /ru SYSTEM /f
    if %errorlevel% equ 0 (
        echo [OK] タスクスケジューラに「NetworkDeviceMonitor」を登録しました。
    ) else (
        echo [ERROR] 登録に失敗しました。管理者権限のコマンドプロンプトで実行してください。
    )
    pause
    goto :EOF
)
if /i "%CHOICE%"=="3" (
    echo.
    echo 【NSSM によるサービス登録手順】
    echo 1. NSSM (https://nssm.cc/) をダウンロードし、nssm.exe を本フォルダに配置します。
    echo 2. 管理者コマンドプロンプトで以下を実行します:
    echo      nssm install NetworkDeviceMonitor "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" "-NoProfile -ExecutionPolicy Bypass -File \"%~dp0Server.ps1\""
    echo      nssm set NetworkDeviceMonitor AppDirectory "%~dp0.."
    echo      nssm set NetworkDeviceMonitor AppRestartDelay 3000
    echo      nssm start NetworkDeviceMonitor
    echo.
    pause
    goto :EOF
)
goto :EOF
