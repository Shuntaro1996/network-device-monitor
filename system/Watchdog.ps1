# ==============================================================================
# Watchdog.ps1 - 監視サーバー外形死活監視（Health Check）＆自動復旧常駐スクリプト
# ==============================================================================
# 【役割】
# 1. system/Server.ps1 を子プロセスとして起動・監視します。
# 2. 15秒ごとに http://localhost:8081/api/health を叩き、プロセスが生きているだけでなく
#    「内部のPing監視ループやWebサーバーが正常に応答しているか（ハングアップしていないか）」を検証します。
# 3. 連続3回タイムアウトまたは応答停止を検知した場合、ハングアップとみなしてプロセスを強制終了（Kill）し、
#    3秒後に自動再起動（自己治癒・自動復旧）します。
# 4. 正常終了（ExitCode = 0）時は、自身も安全に終了します。
# ==============================================================================

param(
    [int]$Port = 8081,
    [int]$CheckIntervalSec = 15,
    [int]$HealthTimeoutSec = 5,
    [int]$MaxConsecutiveFails = 3,
    [int]$CircuitBreakerLimit = 5
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$serverScript = Join-Path $scriptDir "Server.ps1"
$debugLog = Join-Path $scriptDir "debug.log"

function Write-WatchdogLog([string]$msg, [string]$color = "Cyan") {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$ts] [WATCHDOG] $msg"
    Write-Host $line -ForegroundColor $color
    try {
        [System.IO.File]::AppendAllText($debugLog, "$line`r`n", [System.Text.Encoding]::UTF8)
    } catch {}
}

Write-WatchdogLog "Watchdog started (Target: http://localhost:$Port/api/health, Interval: ${CheckIntervalSec}s)" "Green"

$crashCount = 0

while ($true) {
    Write-WatchdogLog "Launching Server.ps1 process..." "Gray"
    
    # Launch Server.ps1 as child process
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$serverScript`""
    $psi.UseShellExecute = $false
    
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($null -eq $proc) {
        Write-WatchdogLog "[ERROR] Failed to start Server.ps1 process." "Red"
        Start-Sleep -Seconds 3
        continue
    }

    $pidVal = $proc.Id
    Write-WatchdogLog "Server.ps1 started (PID: $pidVal)" "Green"

    # Startup grace period (give server 10 seconds to bind HttpListener)
    Start-Sleep -Seconds 10

    $consecutiveHangFails = 0

    # Monitoring loop for this process instance
    while (-not $proc.HasExited) {
        $healthUrl = "http://localhost:$Port/api/health"
        $isHealthy = $false

        try {
            $req = [System.Net.HttpWebRequest]::Create($healthUrl)
            $req.Timeout = $HealthTimeoutSec * 1000
            $req.Method = "GET"
            
            $resp = $req.GetResponse()
            $statusCode = [int]$resp.StatusCode
            $resp.Close()

            if ($statusCode -eq 200) {
                $isHealthy = $true
            }
        } catch [System.Net.WebException] {
            $webEx = $_.Exception
            if ($webEx.Response) {
                $statusCode = [int]$webEx.Response.StatusCode
                try { $webEx.Response.Close() } catch {}
                # 503 = loop unresponsive
            }
        } catch {}

        if ($proc.HasExited) { break }

        if ($isHealthy) {
            $consecutiveHangFails = 0
        } else {
            $consecutiveHangFails++
            Write-WatchdogLog "[WARNING] Health check probe failed ($consecutiveHangFails/$MaxConsecutiveFails) on PID $pidVal" "Yellow"

            if ($consecutiveHangFails -ge $MaxConsecutiveFails) {
                Write-WatchdogLog "[CRITICAL] Server hang/unresponsive detected (3 consecutive health timeouts). Killing PID $pidVal..." "Red"
                try {
                    $proc.Kill()
                } catch {}
                $crashCount++
                break
            }
        }

        # Wait for next health probe, checking if process exited every 1 second
        for ($i = 0; $i -lt $CheckIntervalSec; $i++) {
            if ($proc.HasExited) { break }
            Start-Sleep -Seconds 1
        }
    }

    # Process terminated
    $exitCode = 0
    try {
        $proc.WaitForExit(3000)
        $exitCode = $proc.ExitCode
    } catch {}

    if ($exitCode -eq 0 -and $consecutiveHangFails -lt $MaxConsecutiveFails) {
        Write-WatchdogLog "Server exited gracefully (ExitCode 0). Watchdog stopping." "Green"
        break
    }

    # Abnormal termination or hang recovery
    $crashCount++
    Write-WatchdogLog "Abnormal termination detected (ExitCode: $exitCode, CrashCount: $crashCount)" "Red"

    if ($crashCount -ge $CircuitBreakerLimit) {
        Write-WatchdogLog "[CRITICAL] Circuit breaker triggered! Server crashed $crashCount consecutive times. Auto-restart aborted." "Red"
        Write-Host "`r`n[CRITICAL ERROR] サーバーが短時間に連続 $crashCount 回クラッシュしたため自動再起動を停止しました。" -ForegroundColor Red
        Write-Host "エラー内容は system\debug.log をご確認ください。キーを押すと終了します..." -ForegroundColor Yellow
        $null = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        break
    }

    Write-WatchdogLog "Auto-recovering: restarting Server.ps1 in 3 seconds..." "Yellow"
    Start-Sleep -Seconds 3
}
