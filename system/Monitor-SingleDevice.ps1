<#
.SYNOPSIS
    単一のネットワーク機器の連続疎通確認（1秒周期）、遅延計測、およびサマリー出力を行うスクリプト
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]$TargetAddress
)

$Host.UI.RawUI.WindowTitle = "監視中: $TargetAddress"

$stats = @{
    Success    = 0
    Failed     = 0
    Error      = 0
    MaxLatency = -1
    MinLatency = 999999
    SumLatency = 0
}

$startTime = Get-Date
$startStr = $startTime.ToString("yyyyMMdd_HHmmss")
$safeAddr = $TargetAddress -replace '[\\/:*?"<>|]', '_'

# カレントディレクトリ（ルート）にReportsディレクトリ作成
$logDir = "Reports"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

$tempCsv = "$logDir\results_${safeAddr}_${startStr}_ongoing.csv"

$rootDirForSignal = (Resolve-Path "$PSScriptRoot\..").Path
$stopSignalPath = Join-Path $rootDirForSignal ".stop_signal"

try { [console]::TreatControlCAsInput = $true } catch {}

Write-Host "ターゲット: [$TargetAddress]" -ForegroundColor Cyan
Write-Host "1秒間隔での連続疎通確認を開始します..." -ForegroundColor Cyan
Write-Host "※このウィンドウだけ終了するには [Q]キー, [Esc]キー または Ctrl+C" -ForegroundColor Yellow
Write-Host "※全て一括終了するには『Stop-All.bat』をご利用ください。`n" -ForegroundColor Yellow

$pingProvider = New-Object System.Net.NetworkInformation.Ping
$buffer = [byte[]]@(0)
$running = $true
$stoppedBySignal = $false

try {
    while ($running) {
        if (Test-Path $stopSignalPath) {
            Write-Host "`n全体停止シグナル（Stop-All）を受け付けました。集計処理を行います..." -ForegroundColor Yellow
            $stoppedBySignal = $true
            $running = $false
            break
        }

        if ([console]::KeyAvailable) {
            $key = [console]::ReadKey($true)
            if ($key.Key -eq 'Q' -or $key.Key -eq 'Escape' -or (($key.Modifiers -band [ConsoleModifiers]::Control) -and $key.Key -eq 'C')) {
                Write-Host "`n単独の終了操作を受け付けました。集計処理を行います..." -ForegroundColor Yellow
                $running = $false
                break
            }
        }

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        try {
            $reply = $pingProvider.Send($TargetAddress, 1000, $buffer)
            if ($reply.Status -eq 'Success') {
                $status = "Success"
                $latency = [int]$reply.RoundtripTime
                
                $stats.Success += 1
                $stats.SumLatency += $latency
                if ($latency -gt $stats.MaxLatency) { $stats.MaxLatency = $latency }
                if ($latency -lt $stats.MinLatency) { $stats.MinLatency = $latency }
                
                Write-Host "[$timestamp] $TargetAddress : 成功 (遅延: ${latency}ms)" -ForegroundColor Green
            } else {
                $status = "Failed"
                $latency = $null
                $stats.Failed += 1
                Write-Host "[$timestamp] $TargetAddress : 失敗 ($($reply.Status))" -ForegroundColor Red
            }
        } catch {
            $status = "Error"
            $latency = $null
            $stats.Error += 1
            Write-Host "[$timestamp] $TargetAddress : エラー" -ForegroundColor DarkRed
        }
        
        $resultObj = [PSCustomObject]@{
            Address    = $TargetAddress
            Status     = $status
            Latency_ms = $latency
            Timestamp  = $timestamp
        }
        
        $resultObj | Export-Csv -Path $tempCsv -NoTypeInformation -Encoding UTF8 -Append
        
        for ($i = 0; $i -lt 10; $i++) {
            if (Test-Path $stopSignalPath) { 
                Write-Host "`n全体停止シグナル（Stop-All）を受け付けました。集計処理を行います..." -ForegroundColor Yellow
                $stoppedBySignal = $true
                $running = $false
                break 
            }
            if ([console]::KeyAvailable) { break }
            Start-Sleep -Milliseconds 100
        }
    }
} finally {
    if ($null -ne $pingProvider) { $pingProvider.Dispose() }
    try { [console]::TreatControlCAsInput = $false } catch {}

    $endTime = Get-Date
    $endStr = $endTime.ToString("yyyyMMdd_HHmmss")
    $duration = $endTime - $startTime
    
    $finalCsvName = "results_${safeAddr}_${startStr}_to_${endStr}.csv"
    $finalCsvPath = "$logDir\$finalCsvName"

    $summaryLines = @()
    $summaryLines += "`n"
    $summaryLines += "========================================="
    $summaryLines += "【計測サマリー (Summary): $TargetAddress】"
    $summaryLines += "計測開始時間: $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    $summaryLines += "計測終了時間: $($endTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    $summaryLines += "計測期間(hh:mm:ss): $($duration.ToString('hh\:mm\:ss'))"
    $summaryLines += "-----------------------------------------"

    $total = $stats.Success + $stats.Failed + $stats.Error
    $summaryLines += "計測回数: $total 回 (成功: $($stats.Success), 失敗: $($stats.Failed), エラー: $($stats.Error))"
    
    if ($stats.Success -gt 0) {
        $avg = [math]::Round($stats.SumLatency / $stats.Success, 2)
        $summaryLines += "   遅延時間 -> 最大: $($stats.MaxLatency)ms, 最小: $($stats.MinLatency)ms, 平均: ${avg}ms"
    } else {
        $summaryLines += "   遅延時間 -> データなし"
    }
    $summaryLines += "========================================="

    Write-Host ""
    $summaryLines | ForEach-Object { Write-Host $_ -ForegroundColor Cyan }

    if (Test-Path $tempCsv) {
        $summaryLines | Out-File -FilePath $tempCsv -Encoding UTF8 -Append
        Rename-Item -Path $tempCsv -NewName $finalCsvName
        Write-Host "`n結果を保存しました: $finalCsvPath" -ForegroundColor Green
    }
    
    if ($stoppedBySignal) {
        Write-Host "`nStop-All 命令を検知したため、3秒後にこのウィンドウを自動で閉じます..." -ForegroundColor Magenta
        Start-Sleep -Seconds 3
        [Environment]::Exit(0)
    } else {
        Write-Host "`nこのウィンドウは右上の×ボタンで閉じてください。"
    }
}
