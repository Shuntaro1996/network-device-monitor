# ==============================================================================
# Scan.Tests.ps1 - ネットワーク機器自動探索 (スキャン) のテスト
# ==============================================================================
# 【初心者向けの簡単な解説】
# スキャンで見つけた機器の情報 (機器番号、種類の説明、SNMP の応答) の読み取りと、
# サーバーの /api/scan が機器の情報を返すことを確かめます。
#
# 【実機への影響】
# 問い合わせる先は 127.0.0.x (このPC自身) だけで、外部へは通信しません。
# サーバーは一時フォルダのコピーで動かし、実際の devices.json / config.json は使いません。
#
# 【変更するときの注意】
# - 模擬の SNMP 機器は空いている UDP ポートで待ち受けます。本物の SNMP が使う 161 番は使いません。
# ==============================================================================

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$systemDir = Split-Path -Parent $here
Import-Module (Join-Path $systemDir "modules\Common.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $systemDir "modules\PingEngine.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $systemDir "modules\SnmpService.psm1") -Force -DisableNameChecking

# サーバーの API には合言葉が必要なので、このファイルの呼び出しすべてにヘッダーを付ける
$authHeaders = @{ "X-NDM-Auth" = (Get-AppAuthToken) }
$PSDefaultParameterValues = @{ "Invoke-RestMethod:Headers" = $authHeaders }

Describe "ConvertFrom-ArpTable (機器番号の読み取り)" {
    It "IP アドレスと機器番号を取り出すこと (見出しが日本語でも読めること)" {
        $output = @"

インターフェイス: 192.168.1.5 --- 0x4
  インターネット アドレス 物理アドレス           種類
  192.168.1.1           AA-BB-CC-DD-EE-01     動的
  192.168.1.20          aa-bb-cc-dd-ee-02     静的
"@
        $table = ConvertFrom-ArpTable -ArpOutput $output
        $table["192.168.1.1"] | Should Be "aa-bb-cc-dd-ee-01"
        $table["192.168.1.20"] | Should Be "aa-bb-cc-dd-ee-02"
        $table.ContainsKey("192.168.1.5") | Should Be $false
    }

    It "空の出力では空の結果を返すこと" {
        (ConvertFrom-ArpTable -ArpOutput "").Count | Should Be 0
    }
}

Describe "Get-ScanDeviceHint (種類の説明)" {
    It "SNMP の説明があれば、それを 1 行にして使うこと" {
        Get-ScanDeviceHint -SnmpDescription "Cisco IOS`r`n  Software" -Ttl 255 | Should Be "Cisco IOS Software"
    }

    It "長い説明は切り詰めること" {
        (Get-ScanDeviceHint -SnmpDescription ("x" * 300)).Length | Should Be 163
    }

    It "説明がなければ TTL から推測し、断定しないこと" {
        Get-ScanDeviceHint -Ttl 64 | Should Match "可能性"
        Get-ScanDeviceHint -Ttl 128 | Should Match "Windows の可能性"
        Get-ScanDeviceHint -Ttl 255 | Should Match "ネットワーク機器の可能性"
    }

    It "TTL も分からなければ「不明」にすること" {
        Get-ScanDeviceHint | Should Be "不明"
        Get-ScanDeviceHint -Ttl 0 | Should Be "不明"
    }
}

Describe "Get-SnmpSystemInfoBulk (SNMP の問い合わせ)" {
    # 問い合わせを 1 回受け取り、機器名と説明を返す模擬の SNMP 機器
    function Start-FakeSnmpAgent {
        param([int]$Port, [string]$Name, [string]$Description)
        $shell = [PowerShell]::Create()
        $null = $shell.AddScript({
                param($Port, $Name, $Description)
                function Ber([int]$tag, [byte[]]$value) { return ,[byte[]](@($tag, $value.Length) + $value) }
                $listener = New-Object System.Net.Sockets.UdpClient(New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse("127.0.0.1"), $Port))
                $listener.Client.ReceiveTimeout = 5000
                $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                try { $null = $listener.Receive([ref]$remote) } catch { $listener.Close(); return }
                $descrBind = Ber 0x30 ([byte[]]((Ber 0x06 ([byte[]](0x2B, 6, 1, 2, 1, 1, 1, 0))) + (Ber 0x04 ([System.Text.Encoding]::UTF8.GetBytes($Description)))))
                $nameBind = Ber 0x30 ([byte[]]((Ber 0x06 ([byte[]](0x2B, 6, 1, 2, 1, 1, 5, 0))) + (Ber 0x04 ([System.Text.Encoding]::UTF8.GetBytes($Name)))))
                $list = Ber 0x30 ([byte[]]($descrBind + $nameBind))
                $zero = Ber 0x02 ([byte[]](0))
                $pdu = Ber 0xA2 ([byte[]]((Ber 0x02 ([byte[]](1))) + $zero + $zero + $list))
                $reply = Ber 0x30 ([byte[]]((Ber 0x02 ([byte[]](1))) + (Ber 0x04 ([System.Text.Encoding]::ASCII.GetBytes("public"))) + $pdu))
                $null = $listener.Send($reply, $reply.Length, $remote)
                $listener.Close()
            }).AddArgument($Port).AddArgument($Name).AddArgument($Description)
        return @{ Shell = $shell; Handle = $shell.BeginInvoke() }
    }
    function Get-FreeUdpPort {
        $probe = New-Object System.Net.Sockets.UdpClient(0)
        $free = $probe.Client.LocalEndPoint.Port
        $probe.Close()
        return $free
    }

    It "機器名と説明を読み取ること" {
        $port = Get-FreeUdpPort
        $agent = Start-FakeSnmpAgent -Port $port -Name "core-sw" -Description "Sample Switch OS 1.0"
        Start-Sleep -Milliseconds 800
        $result = Get-SnmpSystemInfoBulk -Ips @("127.0.0.1") -Port $port -TimeoutMs 2000
        $null = $agent.Handle.AsyncWaitHandle.WaitOne(6000)
        $agent.Shell.Dispose()
        $result["127.0.0.1"].Name | Should Be "core-sw"
        $result["127.0.0.1"].Description | Should Be "Sample Switch OS 1.0"
    }

    It "応答のない機器は結果に含めず、例外にもしないこと" {
        $result = Get-SnmpSystemInfoBulk -Ips @("127.0.0.1") -Port (Get-FreeUdpPort) -TimeoutMs 500
        $result.Count | Should Be 0
    }

    It "機器がなければ、すぐに空の結果を返すこと" {
        (Get-SnmpSystemInfoBulk -Ips @()).Count | Should Be 0
    }
}

Describe "GET /api/scan (サーバーを起動して確認)" {
    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_ScanE2E_$([Guid]::NewGuid().ToString('N'))"
    $serverProcess = $null
    try {
        $copySystem = Join-Path $workDir "system"
        $null = & robocopy $systemDir $copySystem /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 /XF devices.json config.json debug.log debug_1.log .bom_cache /XD backups tests iperf3.18_64
        if ($LASTEXITCODE -ge 8) { throw "Failed to copy the system folder (robocopy exit code $LASTEXITCODE)." }
        $noBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $copySystem "devices.json"), '[{"ip":"127.0.0.2","name":"Sample","group":"T","image":"router"}]', $noBom)
        [System.IO.File]::WriteAllText((Join-Path $copySystem "config.json"), '{"autoShutdownOnDisconnect": false}', $noBom)

        $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
        $baseUrl = "http://localhost:$port"
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = "powershell.exe"
        $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $copySystem 'Server.ps1')`" -Port $port"
        $startInfo.WorkingDirectory = $copySystem
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $serverProcess = [System.Diagnostics.Process]::Start($startInfo)
        for ($attempt = 0; $attempt -lt 60; $attempt++) {
            try { if ((Invoke-RestMethod -Uri "$baseUrl/api/health" -TimeoutSec 2).status -eq "ok") { break } }
            catch { Start-Sleep -Seconds 1 }
        }

        It "見つけた機器の IP アドレスと種類の説明を返すこと" {
            $result = Invoke-RestMethod -Uri "$baseUrl/api/scan?start=127.0.0.2&end=127.0.0.3" -TimeoutSec 30
            (@($result.activeIps) -join ",") | Should Be "127.0.0.2,127.0.0.3"
            @($result.hosts).Count | Should Be 2
            @($result.hosts)[0].ip | Should Be "127.0.0.2"
            @($result.hosts)[0].kind | Should Not BeNullOrEmpty
        }

        It "何も見つからなくても応答を返すこと" {
            $result = Invoke-RestMethod -Uri "$baseUrl/api/scan?start=192.0.2.1&end=192.0.2.2" -TimeoutSec 30
            @($result.activeIps).Count | Should Be 0
            @($result.hosts).Count | Should Be 0
        }

        It "スキャン結果の一覧を hidden クラスで切り替えていること (style.display では表示されない)" {
            $appSource = [System.IO.File]::ReadAllText((Join-Path $systemDir "public\app.js"), [System.Text.Encoding]::UTF8)
            $appSource | Should Match "scanResultsContainer\.classList\.remove\('hidden'\)"
            $appSource | Should Not Match "scanResultsContainer\.style\.display"
        }

        $null = Invoke-RestMethod -Uri "$baseUrl/api/shutdown" -Method Post -TimeoutSec 15
        $null = $serverProcess.WaitForExit(30000)
    }
    finally {
        if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
            try { $serverProcess.Kill(); $null = $serverProcess.WaitForExit(5000) } catch {}
        }
        if ((Split-Path -Leaf $workDir).StartsWith("NDM_ScanE2E_") -and (Test-Path -LiteralPath $workDir)) {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
