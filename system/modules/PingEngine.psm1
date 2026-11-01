# ==============================================================================
# PingEngine.psm1 - ICMP Ping & TCPポート死活監視・多段アラート判定モジュール
# ==============================================================================
# 【初心者向けの簡単な解説】
# 機器が応答しているかを調べる部品と、その結果を「正常・注意・障害」に分ける部品です。
#
# 【このファイルにないもの】
# 実際に Ping を送るループと、連続失敗回数・パケットロス率・ジッターの計算は Server.ps1 にあります。
# このファイルの判定は、計算済みの値を受け取るだけです。
#
# 【変更するときの注意】
# - 判定を変えると、画面の色と通知の両方が変わります。テストは tests/Monitor.Tests.ps1 の 2 と 7 です。
# ==============================================================================

function Test-TcpPortEndpoint {
    <#
    .SYNOPSIS
        指定されたIPアドレス・ポート番号に対してTCP 3-way handshake接続を試行し、
        死活と応答時間（ms）を測定します（Web: 80/443, SSH: 22, DNS: 53など）。
    .DESCRIPTION
        Ping に応答しない設定の機器でも、サービスのポートに接続できれば動いていると判断できます。
    .OUTPUTS
        Success (接続できたか) / Status / ResponseTimeMs / Latency / Error を持つハッシュテーブル。
        失敗しても例外にはせず、理由を Error に入れて返します。
    .NOTES
        応答時間は最小 1 ms にしています。同じPC内などで 0 ms になると、値がないものと区別しにくいためです。
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

    # TcpClient の Connect は相手が応答しないと長く待つので、BeginConnect と WaitOne で待ち時間を TimeoutMs に抑える
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
        遅延超過に加え、パケット損失率異常・ジッター急増（品質劣化）も検知します。
    .DESCRIPTION
        判定の順番: 応答がなければ、連続失敗回数で Failed か Warning。
        応答があれば、遅延 → パケット損失率 → ジッターの順に確かめ、1 つでも超えていれば Warning。
    .PARAMETER consecutiveFailThresh
        この回数以上連続で失敗すると Failed にします。1 回の失敗で障害扱いにしないのは、単発の取りこぼしで誤報を出さないためです。
    .PARAMETER latencyWarningMs
        遅延の警告しきい値。損失率とジッターも含め、しきい値に 0 を指定するとその確認をしません。
    .PARAMETER currentOutageSec
        現在は判定に使っていません。
    .OUTPUTS
        "Success" / "Warning" / "Failed" のいずれかの文字列。
    .NOTES
        遅延だけ「より大きい」(-gt) で判定し、損失率とジッターは「以上」(-ge) で判定しています。
    #>
    param(
        [bool]$isSuccess,
        [double]$latencyMs,
        [int]$consecutiveFails,
        [int]$latencyWarningMs = 80,
        [int]$consecutiveFailThresh = 2,
        [double]$currentOutageSec = 0,
        [double]$packetLossRate = 0.0,
        [double]$lossWarningThreshPercent = 5.0,
        [double]$jitterMs = 0.0,
        [double]$jitterWarningThreshMs = 20.0
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

    # パケット損失率が警告閾値を超過していれば Warning（回線品質劣化）
    if ($lossWarningThreshPercent -gt 0 -and $packetLossRate -ge $lossWarningThreshPercent) {
        return "Warning"
    }

    # ジッターが警告閾値を超過していれば Warning（パケット揺らぎ・輻輳検知）
    if ($jitterWarningThreshMs -gt 0 -and $jitterMs -ge $jitterWarningThreshMs) {
        return "Warning"
    }

    return "Success"
}

Export-ModuleMember -Function Test-TcpPortEndpoint, Evaluate-DeviceStatus
