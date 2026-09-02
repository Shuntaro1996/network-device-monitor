# ==============================================================================
# PingEngine.psm1 - ICMP Ping & TCPポート死活監視・多段アラート判定モジュール
# ==============================================================================

function Test-TcpPortEndpoint {
    <#
    .SYNOPSIS
        指定されたIPアドレス・ポート番号に対してTCP 3-way handshake接続を試行し、
        死活と応答時間（ms）を測定します（Web: 80/443, SSH: 22, DNS: 53など）。
    #>
    param(
        [string]$IP,
        [int]$Port = 80,
        [int]$TimeoutMs = 1000
    )
    $res = @{
        Success        = $false
        Status         = "Failed"
        ResponseTimeMs = 0
        Latency        = $null
        Error          = ""
    }
    if ([string]::IsNullOrWhiteSpace($IP) -or $Port -le 0 -or $Port -gt 65535) {
        $res.Error = "Invalid IP or Port"
        return $res
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $asyncResult = $client.BeginConnect($IP, $Port, $null, $null)
        $waitSuccess = $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        $sw.Stop()
        if ($waitSuccess -and $client.Connected) {
            $client.EndConnect($asyncResult)
            $res.Success = $true
            $res.Status  = "Success"
            $res.ResponseTimeMs = [int][math]::Max(1, $sw.ElapsedMilliseconds)
            $res.Latency = $res.ResponseTimeMs
        } else {
            $res.Error = "Connection timeout (${TimeoutMs}ms)"
        }
    } catch {
        $sw.Stop()
        $res.Error = $_.Exception.Message
    } finally {
        try { $client.Close(); $client.Dispose() } catch {}
    }
    return $res
}

function Evaluate-DeviceStatus {
    <#
    .SYNOPSIS
        監視結果から 2段階ステータス（Success / Warning / Failed）を判定します。
    #>
    param(
        [bool]$isSuccess,
        [double]$latencyMs,
        [int]$consecutiveFails,
        [int]$latencyWarningMs = 80,
        [int]$consecutiveFailThresh = 2,
        [double]$currentOutageSec = 0
    )
    if (-not $isSuccess) {
        if ($consecutiveFails -ge $consecutiveFailThresh) {
            return "Failed"   # 重大障害 (Critical)
        } else {
            return "Warning"  # 単発パケロス / 初期瞬断 (Warning)
        }
    }

    # 応答成功時: 遅延が警告閾値を超過していれば Warning
    if ($latencyWarningMs -gt 0 -and $latencyMs -gt $latencyWarningMs) {
        return "Warning"
    }

    return "Success"
}

Export-ModuleMember -Function Test-TcpPortEndpoint, Evaluate-DeviceStatus
