# ==============================================================================
# LogSource.Tests.ps1 - Syslog / SNMP Trap の送信元の絞り込みのテスト
# ==============================================================================
# 【初心者向けの簡単な解説】
# 登録済みの機器から届いたログだけを受け付け、未登録の相手のログは無視することを確かめます。
# このPC自身のアドレス (127.0.0.x) を送信元にして UDP を送るので、外部へは通信しません。
#
# 【実機の設定を守るしくみ】
# 一時フォルダへ system をコピーして動かします。実際の devices.json / config.json は使いません。
#
# 【変更するときの注意】
# - 受信は別スレッドなので、届いた結果は少し待ちながら確かめます ($waitForLog)。
# - 受信ポートは空いている番号を選びます。既定の 514 / 162 を使うと他のソフトと重なることがあります。
# ==============================================================================

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$systemDir = Split-Path -Parent $here
Import-Module (Join-Path $systemDir "modules\Common.psm1") -Force -DisableNameChecking

# サーバーの API には合言葉が必要なので、このファイルの呼び出しすべてにヘッダーを付ける
$authHeaders = @{ "X-NDM-Auth" = (Get-AppAuthToken) }
$PSDefaultParameterValues = @{ "Invoke-RestMethod:Headers" = $authHeaders; "Invoke-WebRequest:Headers" = $authHeaders }

Describe "Test-LogSourceAllowed (送信元の判定)" {
    It "登録済みのアドレスだけを許可すること" {
        Test-LogSourceAllowed -SourceIp "192.168.1.10" -Devices @("192.168.1.10", "192.168.1.11") | Should Be $true
        Test-LogSourceAllowed -SourceIp "192.168.1.99" -Devices @("192.168.1.10") | Should Be $false
    }

    It "IPv6 の形で書いた IPv4 アドレスも同じアドレスとして扱うこと" {
        Test-LogSourceAllowed -SourceIp "::ffff:192.168.1.10" -Devices @("192.168.1.10") | Should Be $true
    }

    It "送信元や機器の一覧が空なら拒否すること" {
        Test-LogSourceAllowed -SourceIp "" -Devices @("192.168.1.10") | Should Be $false
        Test-LogSourceAllowed -SourceIp "192.168.1.10" -Devices @() | Should Be $false
        Test-LogSourceAllowed -SourceIp "192.168.1.10" -Devices $null | Should Be $false
    }
}

Describe "Syslog / Trap の受信 (サーバーを起動して確認)" {
    # テスト用の Trap データを組み立てる (種類・長さ・中身の繰り返し)
    function New-Ber([int]$tag, [byte[]]$value) { return [byte[]](@($tag, $value.Length) + $value) }
    function New-BerBind([byte[]]$oid, [byte[]]$value) { return New-Ber 0x30 ([byte[]](@(New-Ber 0x06 $oid) + $value)) }
    function New-TrapPacket {
        $linkDownOid = [byte[]](0x2B, 6, 1, 6, 3, 1, 1, 5, 3)
        $trapOidOid = [byte[]](0x2B, 6, 1, 6, 3, 1, 1, 4, 1, 0)
        $binds = [byte[]](@(New-BerBind $trapOidOid (New-Ber 0x06 $linkDownOid)))
        $pduBody = [byte[]](@(New-Ber 0x02 ([byte[]](1))) + @(New-Ber 0x02 ([byte[]](0))) + @(New-Ber 0x02 ([byte[]](0))) + @(New-Ber 0x30 $binds))
        return New-Ber 0x30 ([byte[]](@(New-Ber 0x02 ([byte[]](1))) + @(New-Ber 0x04 ([System.Text.Encoding]::ASCII.GetBytes("public"))) + @(New-Ber 0xA7 $pduBody)))
    }
    # 指定した送信元アドレスから UDP を 1 つ送る
    function Send-Udp([string]$from, [int]$port, [byte[]]$data) {
        $client = New-Object System.Net.Sockets.UdpClient((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($from), 0)))
        try { $null = $client.Send($data, $data.Length, "127.0.0.1", $port) } finally { $client.Close() }
    }

    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_LogSource_$([Guid]::NewGuid().ToString('N'))"
    $serverProcess = $null
    try {
        $copySystem = Join-Path $workDir "system"
        $null = & robocopy $systemDir $copySystem /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 /XF devices.json config.json debug.log debug_1.log .bom_cache /XD backups tests iperf3.18_64
        if ($LASTEXITCODE -ge 8) { throw "Failed to copy the system folder (robocopy exit code $LASTEXITCODE)." }

        # 空いている番号を選ぶ (Tcp は HTTP 用、Udp は受信用)
        $tcpProbe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $tcpProbe.Start(); $port = $tcpProbe.LocalEndpoint.Port; $tcpProbe.Stop()
        $udpProbe1 = New-Object System.Net.Sockets.UdpClient(0)
        $udpProbe2 = New-Object System.Net.Sockets.UdpClient(0)
        $syslogPort = $udpProbe1.Client.LocalEndPoint.Port
        $trapPort = $udpProbe2.Client.LocalEndPoint.Port
        $udpProbe1.Close(); $udpProbe2.Close()

        $noBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $copySystem "devices.json"), '[{"ip":"127.0.0.2","name":"Registered","group":"T","image":"router"}]', $noBom)
        [System.IO.File]::WriteAllText((Join-Path $copySystem "config.json"), "{`"autoShutdownOnDisconnect`": false, `"syslogEnabled`": true, `"syslogPort`": $syslogPort, `"trapPort`": $trapPort}", $noBom)

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = "powershell.exe"
        $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $copySystem 'Server.ps1')`" -Port $port"
        $startInfo.WorkingDirectory = $copySystem
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $serverProcess = [System.Diagnostics.Process]::Start($startInfo)
        $baseUrl = "http://localhost:$port"

        # 受信ポートが開くまで待つ
        $ready = $false
        for ($attempt = 0; $attempt -lt 60 -and -not $ready; $attempt++) {
            try {
                $state = Invoke-RestMethod -Uri "$baseUrl/api/syslog" -TimeoutSec 2
                $ready = ($state.listenPort -eq $syslogPort -and $state.trapListenPort -eq $trapPort)
            } catch {}
            if (-not $ready) { Start-Sleep -Seconds 1 }
        }

        # 条件を満たすまで待って、最後の状態を返す
        $waitForLog = {
            param([scriptblock]$condition)
            for ($attempt = 0; $attempt -lt 20; $attempt++) {
                $state = Invoke-RestMethod -Uri "$baseUrl/api/syslog" -TimeoutSec 5
                if (& $condition $state) { return $state }
                Start-Sleep -Milliseconds 300
            }
            return $state
        }
        $trapBytes = New-TrapPacket

        It "指定した受信ポートが開くこと" {
            $ready | Should Be $true
        }

        It "登録済みの機器からの Syslog を受け付けること" {
            Send-Udp "127.0.0.2" $syslogPort ([System.Text.Encoding]::UTF8.GetBytes("<134>from-registered"))
            $state = & $waitForLog { param($s) @($s.logs | Where-Object { $_.Message -eq "from-registered" }).Count -gt 0 }
            $entry = @($state.logs | Where-Object { $_.Message -eq "from-registered" })[0]
            $entry.SourceIP | Should Be "127.0.0.2"
        }

        It "未登録の相手からの Syslog を無視し、数と送信元を返すこと" {
            Send-Udp "127.0.0.3" $syslogPort ([System.Text.Encoding]::UTF8.GetBytes("<134>from-unknown"))
            $state = & $waitForLog { param($s) $s.rejectedCount -ge 1 }
            $state.rejectedCount | Should Be 1
            $state.rejectedLastIp | Should Be "127.0.0.3"
            @($state.logs | Where-Object { $_.Message -eq "from-unknown" }).Count | Should Be 0
        }

        It "登録済みの機器からの Trap を受け付けること" {
            Send-Udp "127.0.0.2" $trapPort $trapBytes
            $state = & $waitForLog { param($s) @($s.logs | Where-Object { $_.Message -match "linkDown" }).Count -gt 0 }
            @($state.logs | Where-Object { $_.Message -match "linkDown" -and $_.SourceIP -eq "127.0.0.2" }).Count | Should Be 1
        }

        It "未登録の相手からの Trap を無視すること" {
            Send-Udp "127.0.0.4" $trapPort $trapBytes
            $state = & $waitForLog { param($s) $s.rejectedCount -ge 2 }
            $state.rejectedCount | Should Be 2
            $state.rejectedLastIp | Should Be "127.0.0.4"
            @($state.logs | Where-Object { $_.SourceIP -eq "127.0.0.4" }).Count | Should Be 0
        }

        $null = Invoke-RestMethod -Uri "$baseUrl/api/shutdown" -Method Post -TimeoutSec 15
        $null = $serverProcess.WaitForExit(30000)
    }
    finally {
        if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
            try { $serverProcess.Kill(); $null = $serverProcess.WaitForExit(5000) } catch {}
        }
        if ((Split-Path -Leaf $workDir).StartsWith("NDM_LogSource_") -and (Test-Path -LiteralPath $workDir)) {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
