# ==============================================================================
# Check-Prerequisites.ps1 - 起動前システム前提環境・モジュール診断スクリプト
# ==============================================================================
param(
    [switch]$AutoInstall
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Resolve-Path (Join-Path $scriptDir "..")
$moduleCommon = Join-Path $scriptDir "modules\Common.psm1"

if (Test-Path $moduleCommon) {
    Import-Module $moduleCommon -Force -ErrorAction SilentlyContinue
}

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "  Network Device Monitor - システム前提環境チェック" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$diag = Test-SystemPrerequisites -projectRoot $projectRoot

# 1. PowerShell バージョン
if ($diag.isPsCompatible) {
    Write-Host " [✔] PowerShell バージョン : $($diag.psVersion) (適合)" -ForegroundColor Green
} else {
    Write-Host " [❌] PowerShell バージョン : $($diag.psVersion) (PowerShell 5.1 以上が必要です)" -ForegroundColor Red
}

# 2. 実行ポリシー
if ($diag.isPolicyOk) {
    Write-Host " [✔] 実行ポリシー         : $($diag.executionPolicy) (実行可能)" -ForegroundColor Green
} else {
    Write-Host " [!] 実行ポリシー         : $($diag.executionPolicy) (起動バッチでBypass実行されます)" -ForegroundColor Yellow
}

# 3. Iperf3 実行ツール
if ($diag.iperf3.available) {
    Write-Host " [✔] Iperf3 帯域計測ツール : 利用可能 ($($diag.iperf3.path))" -ForegroundColor Green
} else {
    Write-Host " [!] Iperf3 帯域計測ツール : 未検出 (tools\iperf3.exe を配置すると有効になります)" -ForegroundColor Yellow
}

# 4. Pester 自動テスト
if ($diag.pesterModule.installed) {
    Write-Host " [✔] Pester 自動テスト     : インストール済み (v$($diag.pesterModule.version))" -ForegroundColor Green
} else {
    Write-Host " [-] Pester 自動テスト     : 未インストール (開発・テスト時のみ必要)" -ForegroundColor DarkGray
}

# 5. SNMP モジュール (最重要)
if ($diag.snmpModule.installed) {
    Write-Host " [✔] SNMP 通信モジュール   : インストール済み (v$($diag.snmpModule.version))" -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host " 全ての必須コンポーネントが正常に確認されました。起動します...`n" -ForegroundColor Green
    Start-Sleep -Milliseconds 600
    exit 0
} else {
    Write-Host " [❌] SNMP 通信モジュール   : 未インストール" -ForegroundColor Red
    Write-Host "     ※ SNMP トラフィック監視や機器詳細の取得に必要です。" -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Cyan
    
    $shouldInstall = $false
    if ($AutoInstall) {
        $shouldInstall = $true
    } else {
        Write-Host ""
        $answer = Read-Host "SNMP モジュールを今すぐ自動インストールしますか？ [Y: はい / N: スキップ] (デフォルト: Y)"
        if ([string]::IsNullOrWhiteSpace($answer) -or $answer.Trim().ToUpper() -eq "Y") {
            $shouldInstall = $true
        }
    }

    if ($shouldInstall) {
        Write-Host "`nPowerShell Gallery から SNMP モジュールをインストール中..." -ForegroundColor Cyan
        Write-Host "（NuGet プロバイダーと SNMP モジュールをユーザー環境に自動導入します）" -ForegroundColor Gray
        
        $res = Install-PrerequisiteModule -moduleName "SNMP"
        if ($res.success) {
            Write-Host " [✔] SNMP モジュールのインストールに成功しました！" -ForegroundColor Green
            Write-Host "監視サーバーを起動します...`n" -ForegroundColor Green
            Start-Sleep -Seconds 1
            exit 0
        } else {
            Write-Host " [❌] インストールに失敗しました: $($res.error)" -ForegroundColor Red
            Write-Host "インターネット未接続環境の場合は、インターネット接続を確認するか、" -ForegroundColor Yellow
            Write-Host "管理者権限の PowerShell で 'Install-Module -Name SNMP -Scope CurrentUser' を実行してください。" -ForegroundColor Yellow
            Write-Host "`n（※ Ping 死活監視機能は SNMP モジュールなしでもそのまま起動・利用可能です）`n" -ForegroundColor Gray
            Start-Sleep -Seconds 3
            exit 0
        }
    } else {
        Write-Host "`nSNMP モジュールのインストールをスキップしました。" -ForegroundColor Yellow
        Write-Host "（※ Ping 死活監視機能はそのまま起動・利用可能です）`n" -ForegroundColor Gray
        Start-Sleep -Seconds 1
        exit 0
    }
}
