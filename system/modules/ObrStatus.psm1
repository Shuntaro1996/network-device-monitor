# ==============================================================================
# ObrStatus.psm1 - OBR の無線接続状況の読み取りモジュール
# ==============================================================================
# 【初心者向けの簡単な解説】
# OBR の状態ページ (HTML) には、無線の接続状況が次のような 1 行で書かれています。
#   接続中:  var stainfo = {ssid:"SAMPLE-AP(00:11:22:33:44:55)",chan:"6 (2.4GHz) 20MHz",signal:-47,txbitrate:"144.4 Mbit/s"};
#   非接続:  var stainfo = {ssid:"---(---)",chan:"---",signal:0,txbitrate:"---"};
# この行から、接続先の名前 (SSID)・チャンネル・電波の強さ・通信速度を取り出します。

function ConvertFrom-ObrStatusHtml {
    <#
    .SYNOPSIS
        OBR の状態ページの HTML から無線の接続状況を読み取ります。
        stainfo の行がないとき (ログイン画面が返ってきたときなど) は Found = $false を返します。
    #>
    param([string]$Html)

    $result = @{
        Found     = $false
        Connected = $false
        Ssid      = ""
        Bssid     = ""
        Channel   = ""
        SignalDbm = $null
        TxBitrate = ""
    }
    if ([string]::IsNullOrEmpty($Html)) { return $result }

    # スマートフォン等で折り返して見えても、実際のファイルでは 1 行。改行が入っていても読めるよう (?s) を付ける
    $pattern = '(?s)var\s+stainfo\s*=\s*\{\s*ssid\s*:\s*"(?<ssid>.*?)"\s*,\s*chan\s*:\s*"(?<chan>.*?)"\s*,\s*signal\s*:\s*(?<signal>-?\d+)\s*,\s*txbitrate\s*:\s*"(?<rate>.*?)"\s*\}'
    $match = [regex]::Match($Html, $pattern)
    if (-not $match.Success) { return $result }

    $result.Found = $true
    $rawSsid = $match.Groups['ssid'].Value.Trim()
    # 末尾のかっこの中は接続先のアクセスポイントの機器番号 (MAC アドレス)
    $ssidMatch = [regex]::Match($rawSsid, '^(?<name>.*)\((?<bssid>[^()]*)\)$')
    $ssidName = if ($ssidMatch.Success) { $ssidMatch.Groups['name'].Value.Trim() } else { $rawSsid }
    $bssid = if ($ssidMatch.Success) { $ssidMatch.Groups['bssid'].Value.Trim() } else { "" }

    # 非接続のときは値が「---」になる
    if ($ssidName -eq "" -or $ssidName -match '^-+$') { return $result }

    $result.Connected = $true
    $result.Ssid = $ssidName
    $result.Bssid = if ($bssid -match '^-*$') { "" } else { $bssid }
    $result.Channel = ($match.Groups['chan'].Value -replace '\s+', ' ').Trim()
    $result.SignalDbm = [int]$match.Groups['signal'].Value
    $result.TxBitrate = $match.Groups['rate'].Value.Trim()
    return $result
}

function Invoke-ObrHttpRequest {
    # OBR へ 1 回通信して、応答の本文を返す。つながらないときは例外を投げる
    param([string]$Url, [string]$PostBody = "", [int]$TimeoutMs = 3000)
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Timeout = $TimeoutMs
    $req.ReadWriteTimeout = $TimeoutMs
    $req.KeepAlive = $false
    # プロキシ環境では機器に届かないことがあるため、プロキシを使わない
    $req.Proxy = $null
    # 送るデータがあるときだけ POST にする ([string] の引数は $null を渡しても空文字になるので、空かどうかで判定する)
    if (-not [string]::IsNullOrEmpty($PostBody)) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($PostBody)
        $req.Method = "POST"
        $req.ContentType = "application/x-www-form-urlencoded"
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Close() }
    }
    $resp = $null
    try {
        try {
            $resp = $req.GetResponse()
        }
        catch [System.Net.WebException] {
            # 401 などの応答はつながってはいるので、本文を読む。応答がなければつながっていない
            $resp = $_.Exception.Response
            if ($null -eq $resp) { throw }
        }
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() } finally { $reader.Close() }
    }
    finally {
        if ($null -ne $resp) { try { $resp.Close() } catch {} }
    }
}

function Get-ObrWirelessStatus {
    <#
    .SYNOPSIS
        OBR に問い合わせて無線の接続状況を返します。
        State は Connected (接続中) / Disconnected (未接続) / LoginFailed (ログイン失敗) / Unreachable (通信不可) のいずれかです。
    .DESCRIPTION
        ログイン後 5 分は状態ページを読めるので、まず読んでみて、読めないときだけログインします。
        パスワードは暗号化されない HTTP で送られるため、送る回数を必要最小限にするためです。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][string]$Password,
        [int]$TimeoutMs = 3000
    )
    $statusUrl = "http://$HostName/public/stat/wlstast_main.htm?lang=en"
    $loginUrl = "http://$HostName/index.htm"
    $fail = { param($state) @{ State = $state; Ssid = ""; Bssid = ""; Channel = ""; SignalDbm = $null; TxBitrate = "" } }

    try {
        $parsed = ConvertFrom-ObrStatusHtml -Html (Invoke-ObrHttpRequest -Url $statusUrl -TimeoutMs $TimeoutMs)
        if (-not $parsed.Found) {
            $null = Invoke-ObrHttpRequest -Url $loginUrl -PostBody ("LOGIN_PASSWORD=" + [System.Uri]::EscapeDataString($Password)) -TimeoutMs $TimeoutMs
            $parsed = ConvertFrom-ObrStatusHtml -Html (Invoke-ObrHttpRequest -Url $statusUrl -TimeoutMs $TimeoutMs)
        }
    }
    catch {
        return (& $fail "Unreachable")
    }
    if (-not $parsed.Found) { return (& $fail "LoginFailed") }
    if (-not $parsed.Connected) { return (& $fail "Disconnected") }
    return @{
        State     = "Connected"
        Ssid      = $parsed.Ssid
        Bssid     = $parsed.Bssid
        Channel   = $parsed.Channel
        SignalDbm = $parsed.SignalDbm
        TxBitrate = $parsed.TxBitrate
    }
}

function ConvertTo-ObrCsvCell {
    # CSV の 1 項目にする。SSID は機器の外から決められる文字なので、Excel が数式として実行しないよう先頭に ' を付けて防ぐ
    param($Value)
    $text = if ($null -eq $Value) { "" } else { [string]$Value }
    if ($text -match '^[=+\-@\t\r]' -and $text -notmatch '^-?\d+(\.\d+)?$') { $text = "'" + $text }
    return '"' + $text.Replace('"', '""') + '"'
}

function Write-ObrHistoryRows {
    <#
    .SYNOPSIS
        無線状態の履歴を機器ごとの CSV (obr_wireless_IPアドレス.csv) に追記します。
        Excel で開いても文字化けしないよう UTF-8 (BOM 付き) で保存し、10MB を超えたら _1 に切り替えます。
    .OUTPUTS
        すべて書き込めたら $true、失敗したら $false (呼び出し側で次回書き直します)。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SessionDir,
        [Parameter(Mandatory = $true)][object[]]$Rows
    )
    $header = "確認日時,IPアドレス,機器名,状態,SSID,アクセスポイント,チャンネル,電波強度_dBm,通信速度`r`n"
    $withBom = New-Object System.Text.UTF8Encoding($true)
    $noBom = New-Object System.Text.UTF8Encoding($false)
    try {
        foreach ($group in ($Rows | Group-Object { $_.ip })) {
            $safeIp = $group.Name -replace '[\\/:*?"<>|]', '_'
            $csvPath = Join-Path $SessionDir "obr_wireless_${safeIp}.csv"
            if ((Test-Path -LiteralPath $csvPath) -and (Get-Item -LiteralPath $csvPath).Length -gt 10MB) {
                Move-Item -LiteralPath $csvPath -Destination (Join-Path $SessionDir "obr_wireless_${safeIp}_1.csv") -Force
            }
            if (-not (Test-Path -LiteralPath $csvPath)) {
                [System.IO.File]::WriteAllText($csvPath, $header, $withBom)
            }
            $lines = foreach ($row in $group.Group) {
                (@($row.checkedAt, $row.ip, $row.name, $row.state, $row.ssid, $row.bssid, $row.channel, $row.signalDbm, $row.txBitrate) | ForEach-Object { ConvertTo-ObrCsvCell $_ }) -join ","
            }
            [System.IO.File]::AppendAllText($csvPath, (($lines -join "`r`n") + "`r`n"), $noBom)
        }
        return $true
    }
    catch {
        return $false
    }
}

Export-ModuleMember -Function ConvertFrom-ObrStatusHtml, Get-ObrWirelessStatus, Write-ObrHistoryRows
