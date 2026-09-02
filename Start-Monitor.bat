@echo off
REM =========================================================================
REM 【初心者向けの簡単な解説】
REM このファイルは、この「ネットワーク機器監視システム」を一発起動するためのスイッチです。
REM 
REM ダブルクリックすると、以下のことを自動で行います：
REM 1. 監視データを収集したり保存したりする「裏側のサーバー（PowerShell）」を起動します。
REM 2. 画面を表示するための「Webブラウザ」を自動で立ち上げ、監視画面（http://localhost:8081）を開きます。
REM 
REM ※ 監視を止めたいときは、この起動した黒い画面（コマンドプロンプト）の中で
REM    [Enter] キー（改行キー）を押すだけで安全にサーバーが停止し、ログが保存されます。
REM =========================================================================

setlocal
cd /d "%~dp0"
chcp 65001 >nul

echo ==============================================
echo   Network Monitor (Single UI Version - PS)
echo ==============================================

echo.
echo [1/2] Starting local PowerShell server on port 8081...

:: Give the server a moment to start, then launch browser
start "Launch Browser" cmd /c "timeout /t 2 >nul & start http://localhost:8081"

echo [2/2] Launching Web UI...
echo.
echo ==============================================
echo   Server is running! 
echo   Your browser will open automatically.
echo.
echo   Press [Enter] in this window to STOP the server
echo   and save logs to the Reports folder.
echo ==============================================

:: Automatic UTF-8 BOM check for PowerShell 5.1 compatibility
powershell -NoProfile -ExecutionPolicy Bypass -File "system\Ensure-Utf8Bom.ps1"

:: System Prerequisites & PowerShell Module Check (with auto-setup option)
powershell -NoProfile -ExecutionPolicy Bypass -File "system\Check-Prerequisites.ps1"

:: Launch server via Watchdog (monitors process survival and HTTP /api/health responsiveness)
powershell -NoProfile -ExecutionPolicy Bypass -File "system\Watchdog.ps1"
set EXIT_CODE=%errorlevel%

echo.
echo ==============================================
echo   [INFO] 監視システムが終了しました (Exit: %EXIT_CODE%)
echo ==============================================
goto :EOF
