@echo off
REM =========================================================================
REM Run-Tests.bat - Network Device Monitor 自動テスト実行ランチャー
REM 【初心者向けの簡単な解説】
REM このスクリプトは、ネットワーク機器監視システムの全機能が正常に動いているか
REM （通信、設定保存、マルチスレッド並行処理、APIデータなど）を一括して
REM 自動診断（テスト）するワンクリック実行ツールです。
REM =========================================================================
setlocal
cd /d "%~dp0"
chcp 932 >nul

powershell -NoProfile -ExecutionPolicy Bypass -File "Run-Tests.ps1" %*
set TEST_EXIT=%errorlevel%

if %TEST_EXIT% neq 0 (
    echo.
    echo [ERROR] 自動テストで失敗が検出されました (終了コード: %TEST_EXIT%)。
    if "%CI%"=="" if not "%~1"=="-NoPause" pause
    exit /b %TEST_EXIT%
)

echo.
echo [OK] すべての自動テストに正常合格しました。
if "%CI%"=="" if not "%~1"=="-NoPause" pause
exit /b 0
