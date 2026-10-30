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

function ConvertFrom-ObrCsvCell {
    # ConvertTo-ObrCsvCell が Excel 対策で先頭に付けた ' を取り除き、元の文字に戻す
    param([string]$Text)
    if ($Text -match "^'[=+\-@\t\r]") { return $Text.Substring(1) }
    return $Text
}

function ConvertTo-ObrMbps {
    # 「144.4 Mbit/s」のような通信速度の文字を Mbit/s の数値にする。読めないときは $null
    param([string]$Text)
    $match = [regex]::Match($Text, '^\s*(?<value>\d+(\.\d+)?)\s*(?<unit>[kKmMgG]?)bit', 'IgnoreCase')
    if (-not $match.Success) { return $null }
    $value = [double]::Parse($match.Groups['value'].Value, [System.Globalization.CultureInfo]::InvariantCulture)
    switch ($match.Groups['unit'].Value.ToLower()) {
        'k' { return $value / 1000 }
        'g' { return $value * 1000 }
        'm' { return $value }
        default { return $value / 1000000 }
    }
}

function Get-ObrSecondsBetween {
    # 2 つの確認日時の間の秒数を返す。読めない日時があるときは $null
    param([string]$From, [string]$To)
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $fromTime = [DateTime]::MinValue
    $toTime = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact($From, 'yyyy-MM-dd HH:mm:ss', $culture, 'None', [ref]$fromTime)) { return $null }
    if (-not [DateTime]::TryParseExact($To, 'yyyy-MM-dd HH:mm:ss', $culture, 'None', [ref]$toTime)) { return $null }
    return [math]::Max(0, [int]($toTime - $fromTime).TotalSeconds)
}

function Get-ObrSmallerValue {
    # 小さいほうの値を返す ($null は「値なし」として無視する)
    param($First, $Second)
    if ($null -eq $First) { return $Second }
    if ($null -eq $Second) { return $First }
    return [math]::Min($First, $Second)
}

function Get-ObrHistoryView {
    <#
    .SYNOPSIS
        無線状態の履歴 CSV を読み、画面に出すグラフの点と出来事の一覧を作ります。
    .DESCRIPTION
        10 秒ごとの記録は 1 日で 8,640 行になるため、全行をメモリに持たず 1 行ずつ処理します。
        グラフの点は MaxPoints 以下に間引きます。短い電波の低下が隠れないよう、間引いた区間の最小値を残します。
        出来事は間引く前の全行で判定するので、短い切断も一覧から漏れません。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SessionDir,
        [Parameter(Mandatory = $true)][string]$Ip,
        [int]$MaxPoints = 2000,
        [int]$MaxEvents = 500
    )
    Add-Type -AssemblyName Microsoft.VisualBasic
    $safeIp = $Ip -replace '[\\/:*?"<>|]', '_'
    # 10MB を超えて切り替わった古いファイルから順に読む
    $paths = @(
        (Join-Path $SessionDir "obr_wireless_${safeIp}_1.csv"),
        (Join-Path $SessionDir "obr_wireless_${safeIp}.csv")
    ) | Where-Object { Test-Path -LiteralPath $_ }

    $points = [System.Collections.Generic.List[hashtable]]::new()
    $events = [System.Collections.Generic.List[hashtable]]::new()
    $eventsTotal = 0
    $rowCount = 0
    $firstAt = ""
    $lastAt = ""
    $previousState = ""
    $lastBssid = ""
    $openEvent = $null      # まだ終わっていない切断などの出来事
    $bucketSize = 1         # グラフの 1 点にまとめる行数 (点が増えすぎたら 2 倍にする)
    $bucketCount = 0
    $bucketTime = ""
    $bucketSignal = $null
    $bucketRate = $null
    $lastRateText = $null   # 通信速度は同じ値が続くことが多いので、前の行と同じなら読み直さない
    $lastRateValue = $null
    $stateEventTypes = @{ Disconnected = 'disconnected'; Unreachable = 'unreachable'; LoginFailed = 'loginFailed' }

    foreach ($path in $paths) {
        # 記録専用スレッドが追記・切り替えをしていても読めるよう、書き込みと移動を許可して開く
        $stream = [System.IO.FileStream]::new($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
        $parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($reader)
        try {
            $parser.SetDelimiters(",")
            $parser.HasFieldsEnclosedInQuotes = $true
            $parser.TrimWhiteSpace = $false
            while (-not $parser.EndOfData) {
                # 書き込みの途中で読んだ行は形が崩れていることがあるので、読み飛ばす
                try { $fields = $parser.ReadFields() }
                catch [Microsoft.VisualBasic.FileIO.MalformedLineException] { continue }
                if ($null -eq $fields -or $fields.Count -lt 9 -or $fields[0] -eq '確認日時') { continue }

                $time = $fields[0]
                $state = $fields[3]
                if ($state -ne 'Connected' -and -not $stateEventTypes.ContainsKey($state)) { continue }
                $rowCount++
                if ($firstAt -eq "") { $firstAt = $time }
                $lastAt = $time

                # ── グラフの点 ──
                $signal = $null
                $rate = $null
                if ($state -eq 'Connected') {
                    $parsedSignal = 0
                    if ([int]::TryParse($fields[7], [ref]$parsedSignal)) { $signal = $parsedSignal }
                    if ($fields[8] -cne $lastRateText) {
                        $lastRateText = $fields[8]
                        $lastRateValue = ConvertTo-ObrMbps $lastRateText
                    }
                    $rate = $lastRateValue
                }
                if ($bucketCount -eq 0) { $bucketTime = $time; $bucketSignal = $null; $bucketRate = $null }
                if ($null -ne $signal -and ($null -eq $bucketSignal -or $signal -lt $bucketSignal)) { $bucketSignal = $signal }
                if ($null -ne $rate -and ($null -eq $bucketRate -or $rate -lt $bucketRate)) { $bucketRate = $rate }
                $bucketCount++
                if ($bucketCount -ge $bucketSize) {
                    $points.Add(@{ t = $bucketTime; signal = $bucketSignal; rate = $bucketRate })
                    $bucketCount = 0
                    if ($points.Count -ge $MaxPoints) {
                        # 点が上限に届いたら、隣どうしを 1 点にまとめて半分にする
                        $merged = [System.Collections.Generic.List[hashtable]]::new()
                        for ($i = 0; $i -lt $points.Count; $i += 2) {
                            $point = $points[$i]
                            if (($i + 1) -lt $points.Count) {
                                $next = $points[$i + 1]
                                $point = @{ t = $point.t; signal = (Get-ObrSmallerValue $point.signal $next.signal); rate = (Get-ObrSmallerValue $point.rate $next.rate) }
                            }
                            $merged.Add($point)
                        }
                        $points = $merged
                        $bucketSize *= 2
                    }
                }

                # ── 出来事 ──
                if ($state -ne $previousState) {
                    if ($null -ne $openEvent) {
                        $openEvent.durationSec = Get-ObrSecondsBetween $openEvent.time $time
                        $openEvent.ongoing = $false
                        $openEvent = $null
                    }
                    if ($state -eq 'Connected') {
                        # 記録の最初の行が接続中なのは「復旧」ではないので、何か起きていたときだけ出す
                        if ($previousState -ne "") {
                            $events.Add(@{ time = $time; type = 'recovered'; ssid = (ConvertFrom-ObrCsvCell $fields[4]); bssid = (ConvertFrom-ObrCsvCell $fields[5]); signalDbm = $signal; txBitrate = (ConvertFrom-ObrCsvCell $fields[8]) })
                            $eventsTotal++
                        }
                    }
                    else {
                        $openEvent = @{ time = $time; type = $stateEventTypes[$state]; durationSec = $null; ongoing = $true }
                        $events.Add($openEvent)
                        $eventsTotal++
                    }
                    $previousState = $state
                }
                if ($state -eq 'Connected' -and $fields[5] -ne "") {
                    if ($lastBssid -ne "" -and $fields[5] -cne $lastBssid) {
                        $events.Add(@{ time = $time; type = 'roamed'; ssid = (ConvertFrom-ObrCsvCell $fields[4]); fromBssid = (ConvertFrom-ObrCsvCell $lastBssid); toBssid = (ConvertFrom-ObrCsvCell $fields[5]); signalDbm = $signal })
                        $eventsTotal++
                    }
                    $lastBssid = $fields[5]
                }
                # 不安定な機器で出来事が増え続けてもメモリを使いすぎないよう、新しいものだけ残す
                if ($events.Count -gt ($MaxEvents * 2)) { $events.RemoveRange(0, $events.Count - $MaxEvents) }
            }
        }
        finally {
            $parser.Dispose()
            $reader.Dispose()
            $stream.Dispose()
        }
    }

    if ($bucketCount -gt 0) { $points.Add(@{ t = $bucketTime; signal = $bucketSignal; rate = $bucketRate }) }
    # 今も続いている出来事は、最後の記録までの長さを表示する
    if ($null -ne $openEvent) { $openEvent.durationSec = Get-ObrSecondsBetween $openEvent.time $lastAt }
    if ($events.Count -gt $MaxEvents) { $events.RemoveRange(0, $events.Count - $MaxEvents) }

    return @{
        rowCount    = $rowCount
        firstAt     = $firstAt
        lastAt      = $lastAt
        thinned     = ($bucketSize -gt 1)
        points      = $points.ToArray()
        events      = $events.ToArray()
        eventsTotal = $eventsTotal
    }
}

Export-ModuleMember -Function ConvertFrom-ObrStatusHtml, Get-ObrWirelessStatus, Write-ObrHistoryRows, Get-ObrHistoryView
