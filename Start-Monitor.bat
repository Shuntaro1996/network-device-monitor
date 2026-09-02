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
powershell -NoProfile -Command "$files = @('system\Server.ps1') + (Get-ChildItem -Path 'system\modules\*.psm1' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }); foreach($f in $files){ if(Test-Path $f){ $b=[System.IO.File]::ReadAllBytes((Resolve-Path $f)); if($b.Length -lt 3 -or $b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF){ $t=[System.IO.File]::ReadAllText((Resolve-Path $f),[System.Text.Encoding]::UTF8); [System.IO.File]::WriteAllText((Resolve-Path $f),$t,[System.Text.Encoding]::UTF8) } } }"

set CRASH_COUNT=0
:RUN_SERVER
powershell -NoProfile -ExecutionPolicy Bypass -File "system\Server.ps1"
set EXIT_CODE=%errorlevel%

if %EXIT_CODE% equ 0 (
    echo.
    echo ==============================================
    echo   [INFO] 監視サーバーは正常に終了しました。
    echo ==============================================
    goto :EOF
)

:: 異常終了（ExitCode != 0）時の自動復旧（Watchdog）
set /a CRASH_COUNT+=1
echo.
echo ==============================================
echo   [WARNING] サーバーが異常終了しました (終了コード: %EXIT_CODE%)
echo   クラッシュ回数: %CRASH_COUNT% 回
echo ==============================================

if %CRASH_COUNT% geq 5 (
    echo.
    echo [CRITICAL ERROR] 短時間に連続5回クラッシュしたため、自動再起動を停止しました。
    echo エラー内容または system\debug.log を確認してください。
    pause
    goto :EOF
)

echo 3秒後に監視サーバーを自動再起動（復旧）します...
timeout /t 3 /nobreak >nul
goto :RUN_SERVER
