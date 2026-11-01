@echo off
REM =========================================================================
REM 【初心者向けの簡単な解説】
REM このファイルは、この「ネットワーク機器監視システム」を一発起動するためのスイッチです。
REM 
REM ダブルクリックすると、以下のことを自動で行います：
REM 1. 監視データを収集したり保存したりする「裏側のサーバー（PowerShell）」を起動します。
REM 2. サーバーの起動完了を確認した瞬間に「Webブラウザ」を自動で立ち上げ、監視画面（http://localhost:8081）を開きます。
REM 
REM ※ 監視を止めたいときは、この起動した黒い画面（コマンドプロンプト）の中で
REM    [Enter] キー（改行キー）を押すだけで安全にサーバーが停止し、ログが保存されます。
REM =========================================================================

setlocal
chcp 932 >nul
cd /d "%~dp0"

REM 利用者が迷わないよう、操作に使わないものを隠す (GitHub や開発ツール用のファイルです)
attrib +h ".gitignore" >nul 2>&1
attrib +h ".github" >nul 2>&1
attrib +h ".claude" >nul 2>&1

echo ==============================================
echo   Network Monitor (Single UI Version - PS)
echo ==============================================
echo.
echo [1/2] Starting local PowerShell server on port 8081...
echo [2/2] Web UI will open automatically as soon as the server is ready.
echo.
echo ==============================================
echo   Press [Enter] in this window to STOP the server
echo   and save logs to the Reports folder.
echo ==============================================

:: Run preflight (UTF-8 BOM check + Prerequisite check), launch Server via Watchdog, and open browser when ready
powershell -NoProfile -ExecutionPolicy Bypass -File "system\Watchdog.ps1" -RunPreflight -LaunchBrowser
set EXIT_CODE=%errorlevel%

echo.
echo ==============================================
echo   [INFO] 監視システムが終了しました (Exit: %EXIT_CODE%)
echo ==============================================
goto :EOF