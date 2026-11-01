#Requires -Version 5.0
<#
.SYNOPSIS
    このPCをiperf3サーバーとして起動し、他のPCからの帯域幅計測を受け付けます
.DESCRIPTION
    iperf3をサーバーモードで起動します。
    他のPCの監視画面 (Iperf3 計測) や iperf3 コマンドから接続すると、このPCとの帯域幅が計測されます。
.PARAMETER Port
    iperf3リッスンポート（デフォルト: 5201）
.PARAMETER AddFirewallRule
    Windowsファイアウォールにルールを追加する（管理者権限が必要）
.EXAMPLE
    .\Start-BandwidthServer.ps1
    .\Start-BandwidthServer.ps1 -Port 5202 -AddFirewallRule
#>
param(
    [int]$Port = 5201,
    [switch]$AddFirewallRule
)

# このファイルは system\tools にあるので、system フォルダは 1 つ上になる
$SystemDir  = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ProjectRoot = Split-Path -Parent $SystemDir

function Write-Banner {
    Write-Host ""
    Write-Host "=====================================================" -ForegroundColor Cyan
    Write-Host "  iperf3 帯域幅計測サーバー" -ForegroundColor Cyan
    Write-Host "=====================================================" -ForegroundColor Cyan
}

function Find-Iperf3 {
    $candidates = @(
        (Join-Path $SystemDir "iperf3.exe"),
        (Join-Path $SystemDir "iperf3.18_64\iperf3.exe"),
        (Join-Path $ProjectRoot "iperf3.exe"),
        (Join-Path $ProjectRoot "iperf3\iperf3.exe"),
        "iperf3",
        "C:\iperf3\iperf3.exe",
        "C:\Program Files\iperf3\iperf3.exe",
        "C:\tools\iperf3\iperf3.exe"
    )
    foreach ($c in $candidates) {
        try {
            $out = & $c --version 2>&1
            if ($LASTEXITCODE -eq 0 -or ($out -join "") -match "iperf") { return $c }
        } catch {}
    }
    return $null
}

Write-Banner

# iperf3 検索
$iperf3 = Find-Iperf3
if (-not $iperf3) {
    Write-Host ""
    Write-Host "  [エラー] iperf3 が見つかりません" -ForegroundColor Red
    Write-Host ""
    Write-Host "  インストール方法:" -ForegroundColor Yellow
    Write-Host "  1. https://iperf.fr/iperf-download.php からWindows版をダウンロード" -ForegroundColor White
    Write-Host "  2. iperf3.exe をこのフォルダ（$SystemDir）またはルートに配置" -ForegroundColor White
    Write-Host "  3. このスクリプトを再実行" -ForegroundColor White
    Write-Host ""
    Read-Host "Enterで終了"
    exit 1
}

Write-Host ""
Write-Host "  iperf3: $iperf3" -ForegroundColor Green

# ファイアウォールルール追加
if ($AddFirewallRule) {
    $ruleName = "iperf3 Bandwidth Test (Port $Port)"
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if (-not $existing) {
        try {
            # -ErrorAction Stop を付けないと、管理者権限がなく失敗しても catch に入らず「追加しました」と表示されていた
            New-NetFirewallRule -DisplayName $ruleName `
                -Direction Inbound -Protocol TCP -LocalPort $Port `
                -Action Allow -Profile Any -ErrorAction Stop | Out-Null
            Write-Host "  ファイアウォールルールを追加しました: $ruleName" -ForegroundColor Green
        } catch {
            Write-Host "  [警告] ファイアウォールルールの追加に失敗（管理者権限が必要）" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  ファイアウォールルールは既に存在します" -ForegroundColor Gray
    }
}

# 自分のIPアドレスを表示
Write-Host ""
Write-Host "  このPCのIPアドレス:" -ForegroundColor Cyan
$ips = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notmatch "^127\." -and $_.PrefixOrigin -ne "WellKnown" }
foreach ($ip in $ips) {
    Write-Host "    $($ip.IPAddress) ($($ip.InterfaceAlias))" -ForegroundColor White
}

Write-Host ""
Write-Host "  リッスンポート: $Port" -ForegroundColor White
Write-Host ""
Write-Host "  別のPCから計測するには:" -ForegroundColor Yellow
    Write-Host "  iperf3 -c <このPCのIP> -p $Port" -ForegroundColor White
Write-Host ""
Write-Host "  停止: Ctrl+C" -ForegroundColor Gray
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

# iperf3 サーバー起動
try {
    & $iperf3 -s -p $Port
} catch {
    Write-Host "[エラー] iperf3 の起動に失敗しました: $($_.Exception.Message)" -ForegroundColor Red
}
