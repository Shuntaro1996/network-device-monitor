@echo off
REM =========================================================================
REM Run-Tests.bat - Network Device Monitor 自動テスト実行
REM =========================================================================
setlocal
cd /d "%~dp0"
chcp 65001 >nul

powershell -NoProfile -ExecutionPolicy Bypass -File "Run-Tests.ps1"
if %errorlevel% neq 0 (
    echo.
    echo [ERROR] テストで失敗が検出されました。
    pause
    exit /b %errorlevel%
)

echo.
echo [OK] すべてのテストに合格しました。
pause
