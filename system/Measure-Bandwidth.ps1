#Requires -Version 5.0
param(
    [string[]]$IpList,
    [switch]$Scan,
    [switch]$UseIperf3,
    [int]$DurationSec = 5,
    [int]$PingCount = 5,
    [switch]$NoCsv,
    [switch]$NoReport,
    [bool]$OpenReport = $true
)

# Settings
$SystemDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $SystemDir
$DevicesFile = Join-Path $ProjectRoot "devices.txt"
$ReportsDir  = Join-Path $ProjectRoot "Reports"
$Timestamp   = Get-Date -Format "yyyyMMdd_HHmmss"
$CsvFile     = Join-Path $ReportsDir "bandwidth_$Timestamp.csv"
$ReportFile  = Join-Path $ReportsDir "bandwidth_$Timestamp.html"

if (-not (Test-Path $ReportsDir)) { New-Item -ItemType Directory -Path $ReportsDir | Out-Null }

function Write-Log { param([string]$Msg, [string]$Color = "Cyan") Write-Host $Msg -ForegroundColor $Color }

function Find-Iperf3 {
    $candidates = @(
        (Join-Path $SystemDir "iperf3.exe"),
        (Join-Path $SystemDir "iperf3.18_64\iperf3.exe"),
        (Join-Path $ProjectRoot "iperf3.exe"),
        "iperf3",
        "C:\iperf3\iperf3.exe"
    )
    foreach ($c in $candidates) {
        try {
            $out = & $c --version 2>&1
            if ($LASTEXITCODE -eq 0 -or ($out -join "") -match "iperf") { return $c }
        } catch {}
    }
    return $null
}

function Test-TcpPort {
    param([string]$IP, [int]$Port)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async  = $client.BeginConnect($IP, $Port, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne(800, $false)) {
            try { $client.EndConnect($async) | Out-Null } catch {}
            $client.Close(); return $true
        }
        $client.Close(); return $false
    } catch { return $false }
}

function Resolve-Host {
    param([string]$IP)
    try { return [System.Net.Dns]::GetHostEntry($IP).HostName } catch { return $IP }
}

function Measure-Ping {
    param([string]$IP, [int]$Count)
    $pinger = New-Object System.Net.NetworkInformation.Ping
    $results = @(); $lost = 0
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $reply = $pinger.Send($IP, 1000)
            if ($reply.Status -eq "Success") { $results += $reply.RoundtripTime } else { $lost++ }
        } catch { $lost++ }
        Start-Sleep -Milliseconds 100
    }
    if ($results.Count -eq 0) { return @{ Reachable=$false; Avg=0; Loss=100 } }
    return @{ Reachable=$true; Avg=[math]::Round(($results | Measure-Object -Average).Average, 2); Loss=[math]::Round(($lost/$Count)*100, 1) }
}

$DevicesJson = Join-Path $SystemDir "devices.json"

$Iperf3Exe = Find-Iperf3
$targets = @()
if ($IpList) { 
    $targets = $IpList 
}
elseif (Test-Path $DevicesFile) { 
    $targets = Get-Content $DevicesFile | Where-Object { $_ -match '^\d+\.' } 
}
elseif (Test-Path $DevicesJson) {
    try {
        $jsonObj = Get-Content $DevicesJson -Raw -Encoding UTF8 | ConvertFrom-Json
        $targets = $jsonObj | Where-Object { $_.enabled -ne $false } | Select-Object -ExpandProperty ip
    } catch {}
}

if ($targets.Count -eq 0) { Write-Log "No targets found in devices.txt or devices.json." "Red"; exit 1 }

$allResults = @()
Write-Log "Starting bandwidth check for $($targets.Count) hosts..."

foreach ($ip in $targets) {
    $ip = $ip.Trim()
    $hostname = Resolve-Host $ip
    Write-Log "Checking $ip ($hostname)..." "White"
    
    $ping = Measure-Ping $ip $PingCount
    $res = [PSCustomObject]@{
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        IP = $ip
        Hostname = $hostname
        Reachable = $ping.Reachable
        PingAvgMs = $ping.Avg
        PingLossPercent = $ping.Loss
        BandwidthMbps = ""
        BandwidthMethod = "N/A"
    }

    if ($res.Reachable) {
        if ($Iperf3Exe -and (Test-TcpPort $ip 5201)) {
            Write-Log "  Running iperf3..." -Color Gray
            $out = & $Iperf3Exe -c $ip -t $DurationSec -J 2>&1 | Out-String
            $json = $out | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($json -and $json.end -and $json.end.sum_sent) {
                $res.BandwidthMbps = [math]::Round($json.end.sum_sent.bits_per_second / 1000000, 2)
                $res.BandwidthMethod = "iperf3"
            }
        }
        
        if ($res.BandwidthMbps -eq "") {
            $effectivePing = [math]::Max(0.1, $res.PingAvgMs)
            $res.BandwidthMbps = [math]::Round(1000 / $effectivePing * 0.5, 2)
            $res.BandwidthMethod = "RTT Estimate"
        }
        Write-Log "  Result: $($res.BandwidthMbps) Mbps ($($res.BandwidthMethod))" "Yellow"
    } else {
        Write-Log "  Host unreachable." "Red"
    }
    $allResults += $res
}

if (-not $NoCsv) {
    $allResults | Export-Csv -Path $CsvFile -NoTypeInformation -Encoding UTF8
} else {
    Write-Log "  CSV generation skipped." -Color Gray
}

if (-not $NoReport) {
    $GenScript = Join-Path $SystemDir "Generate-BandwidthReport.ps1"
    if (Test-Path $GenScript -and -not $NoCsv) {
        & $GenScript -CsvFile $CsvFile -OutputFile $ReportFile
        Write-Host "  Report generated: $ReportFile" -ForegroundColor Green
        if ($OpenReport) { Start-Process $ReportFile }
    }
}
Write-Log "Finished." "Cyan"
