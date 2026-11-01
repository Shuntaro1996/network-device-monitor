# ==============================================================================
# Watchdog.ps1 - 監視サーバー外形死活監視（Health Check）＆自動復旧常駐スクリプト
# ==============================================================================
# 【役割】
# 1. system/Server.ps1 を子プロセスとして起動・監視します。
# 2. 起動直後は 200ms 間隔で http://localhost:8081/api/health の応答開始を検知し、
#    サーバーの準備が完全に整った瞬間にブラウザを自動起動します（「接続できませんでした」を防止）。
# 3. 稼働中は 15秒ごとに http://localhost:8081/api/health を叩き、プロセスが生きているだけでなく
#    「内部のPing監視ループやWebサーバーが正常に応答しているか（ハングアップしていないか）」を検証します。
# 4. 連続3回タイムアウトまたは応答停止を検知した場合、ハングアップとみなしてプロセスを強制終了（Kill）し、
#    3秒後に自動再起動（自己治癒・自動復旧）します。
# 5. 正常終了（ExitCode = 0）時は、自身も安全に終了します。
# ==============================================================================

param(
    [int]$Port = 8081,
    [int]$CheckIntervalSec = 15,
    [int]$HealthTimeoutSec = 5,
    [int]$MaxConsecutiveFails = 3,
    [int]$CircuitBreakerLimit = 5,
    [switch]$LaunchBrowser,
    [switch]$RunPreflight
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$serverScript = Join-Path $scriptDir "Server.ps1"
$debugLog = Join-Path $scriptDir "debug.log"

# If invoked from Start-Monitor.bat with -RunPreflight, execute BOM check and Prerequisite check in-process
# to avoid spawning multiple separate powershell.exe processes (saves ~1.5s startup time).
if ($RunPreflight) {
    $bomScript = Join-Path $scriptDir "Ensure-Utf8Bom.ps1"
    if ([System.IO.File]::Exists($bomScript)) {
        try { & $bomScript -Quiet } catch {}
    }
    $prereqScript = Join-Path $scriptDir "Check-Prerequisites.ps1"
    if ([System.IO.File]::Exists($prereqScript)) {
        try { & $prereqScript } catch {}
    }
}

function Write-WatchdogLog([string]$msg, [string]$color = "Cyan") {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$ts] [WATCHDOG] $msg"
    Write-Host $line -ForegroundColor $color
    try {
        [System.IO.File]::AppendAllText($debugLog, "$line`r`n", [System.Text.Encoding]::UTF8)
    } catch {}
}

# ブラウザで開く URL。合言葉を付けて開くと、サーバーがブラウザに記憶させてから「/」へ移動させる
# 合言葉を読めないときは合言葉なしで開く (「開けません」の案内が表示されるので、原因に気づける)
function Get-MonitorUrl {
    try {
        Import-Module (Join-Path $scriptDir "modules\Common.psm1") -DisableNameChecking -ErrorAction Stop
        return "http://localhost:$Port/?auth=$(Get-AppAuthToken)"
    } catch {
        Write-WatchdogLog "[WARNING] Could not read the access token: $($_.Exception.Message)" "Yellow"
        return "http://localhost:$Port/"
    }
}

# すでに起動中なら、2 つ目のサーバーを起動せず、画面だけ開いて終わる
# (別のブラウザで「開けません」と出たときに Start-Monitor.bat で開き直すための動作)
try {
    $probe = [System.Net.HttpWebRequest]::Create("http://localhost:$Port/api/health")
    $probe.Timeout = 2000
    $probeResponse = $probe.GetResponse()
    $probeCode = [int]$probeResponse.StatusCode
    $probeResponse.Close()
    if ($probeCode -eq 200) {
        Write-WatchdogLog "Server is already running on port $Port." "Green"
        if ($LaunchBrowser) { Start-Process (Get-MonitorUrl) }
        exit 0
    }
} catch {}

Write-WatchdogLog "Watchdog started (Target: http://localhost:$Port/api/health, Interval: ${CheckIntervalSec}s)" "Green"

$crashCount = 0
$browserLaunched = $false

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
    Write-WatchdogLog "Server.ps1 started (PID: $pidVal). Waiting for HTTP listener readiness..." "Green"

    # Fast readiness probe (poll every 200ms up to 20s until HTTP listener responds)
    $healthUrl = "http://localhost:$Port/api/health"
    $readySw = [System.Diagnostics.Stopwatch]::StartNew()
    $serverReady = $false
    while (-not $proc.HasExited -and $readySw.Elapsed.TotalSeconds -lt 20) {
        try {
            $req = [System.Net.HttpWebRequest]::Create($healthUrl)
            $req.Timeout = 1000
            $req.Method = "GET"
            $resp = $req.GetResponse()
            $statusCode = [int]$resp.StatusCode
            $resp.Close()
            if ($statusCode -eq 200) {
                $serverReady = $true
                break
            }
        } catch {}
        Start-Sleep -Milliseconds 200
    }

    if ($serverReady) {
        $elapsedMs = [int]$readySw.Elapsed.TotalMilliseconds
        Write-WatchdogLog "Server HTTP listener ready in ${elapsedMs}ms (http://localhost:$Port/)" "Green"
        if ($LaunchBrowser -and -not $browserLaunched) {
            Write-WatchdogLog "Opening Web UI in browser (http://localhost:$Port)..." "Cyan"
            try {
                Start-Process (Get-MonitorUrl)
                $browserLaunched = $true
            } catch {}
        }
    }

    # Wait before first periodic health check
    for ($i = 0; $i -lt $CheckIntervalSec; $i++) {
        if ($proc.HasExited) { break }
        Start-Sleep -Seconds 1
    }

    $consecutiveHangFails = 0
    # 一定時間 (10分) 安定稼働したらクラッシュ回数をリセットする
    # (リセットしないと、長期運用で散発的に起きた再起動が積算され「短時間に連続5回」の判定が誤発動する)
    $stableResetSec = 600
    $instanceSw = [System.Diagnostics.Stopwatch]::StartNew()

    # Monitoring loop for this process instance
    while (-not $proc.HasExited) {
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
            if ($crashCount -gt 0 -and $instanceSw.Elapsed.TotalSeconds -ge $stableResetSec) {
                Write-WatchdogLog "Server stable for $stableResetSec s. Resetting crash counter ($crashCount -> 0)." "Green"
                $crashCount = 0
            }
        } else {
            $consecutiveHangFails++
            Write-WatchdogLog "[WARNING] Health check probe failed ($consecutiveHangFails/$MaxConsecutiveFails) on PID $pidVal" "Yellow"

            if ($consecutiveHangFails -ge $MaxConsecutiveFails) {
                Write-WatchdogLog "[CRITICAL] Server hang/unresponsive detected (3 consecutive health timeouts). Killing PID $pidVal..." "Red"
                try {
                    $proc.Kill()
                } catch {}
                # クラッシュ回数は下の「Abnormal termination」処理で1回だけ数える (ここで数えると二重カウントになる)
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
        $null = $proc.WaitForExit(3000)
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
