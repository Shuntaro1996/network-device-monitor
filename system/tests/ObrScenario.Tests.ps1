# ==============================================================================
# ObrScenario.Tests.ps1 - 模擬 OBR を相手にした無線確認の通しテスト (E2E)
# ==============================================================================
# 【初心者向けの簡単な解説】
# 実物の OBR がなくても、確認スレッド → 記録スレッド → CSV → /api/obr/history の流れを確かめるテストです。
# このPCの中だけで動く「模擬 OBR」を立て、サーバーを実際に起動して、次の順で状態を変えます。
#   接続中 (AP-A) → 切断 → 復旧 (AP-B) → AP の切り替え (AP-C)
#
# 【登場する機器】 すべて 127.0.0.x (このPC自身のアドレス) で、外部へは通信しません。
#   127.0.0.2: 模擬 OBR (正しいパスワード)      127.0.0.3: 模擬 OBR (違うパスワード)
#   127.0.0.4: OBR ではない機器                 127.0.0.5: OBR だがパスワード未設定
#   127.0.0.6〜10: 接続はできるが応答しない機器 (順番に確認すると他の機器の間隔が 15 秒以上に延びる台数)
#
# 【実機の設定を守るしくみ】
# サーバーは devices.json を読むので、テスト用の一時フォルダへ system をコピーし、その中で動かします。
# 実際の devices.json / config.json / backups はコピーせず、書き換えません。
#
# 【省略する場合】
# 模擬 OBR は 80 番ポートを使います (サーバーの確認処理が http://機器/ に接続するため)。
# 他のソフトが 80 番を使っていて待ち受けられないときは、理由を表示して省略します。
#
# 【変更するときの注意】
# - 1 回に 1 分半ほどかかります。切断や切り替えの時間 ($phase...) を短くすると、確認間隔 10 秒より短くなり出来事を確かめられません。
# - 確認間隔を変えたら「確認間隔」のテストの範囲 (9〜13 秒) も見直してください。
# - 模擬 OBR の応答の形は ObrStatus.psm1 の解説にある実機の状態ページに合わせています。
# ==============================================================================

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$systemDir = Split-Path -Parent $here

function Get-ObrTestStatusCode {
    # 400 や 403 は例外になるので、状態コードを取り出して返す
    param([string]$Url, [hashtable]$Headers = @{}, [string]$Method = "GET")
    try {
        return [int](Invoke-WebRequest -Uri $Url -Headers $Headers -Method $Method -UseBasicParsing -TimeoutSec 15).StatusCode
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        throw
    }
}

function Start-FakeObrServer {
    # 模擬 OBR を別スレッドで動かす。$State.Stop を $true にすると止まる。ログインの回数は $State.Logins に記録する
    param([string[]]$Addresses, [string]$Password, [hashtable]$State)
    $shell = [PowerShell]::Create()
    $null = $shell.AddScript({
            param($Listeners, $Password, $State, $PhaseA, $PhaseDown, $PhaseB)
            $loggedIn = @{}
            $startedAt = $null
            while (-not $State.Stop) {
                $served = $false
                foreach ($listener in $Listeners) {
                    if (-not $listener.Pending()) { continue }
                    $served = $true
                    $client = $listener.AcceptTcpClient()
                    try {
                        $ip = $listener.LocalEndpoint.Address.ToString()
                        $stream = $client.GetStream()
                        $stream.ReadTimeout = 2000
                        $buffer = New-Object byte[] 8192
                        $text = ""
                        # ヘッダーの終わりと、本文 (Content-Length の長さ) がそろうまで読む
                        while ($true) {
                            $count = $stream.Read($buffer, 0, $buffer.Length)
                            if ($count -le 0) { break }
                            $text += [System.Text.Encoding]::ASCII.GetString($buffer, 0, $count)
                            $headerEnd = $text.IndexOf("`r`n`r`n")
                            if ($headerEnd -lt 0) { continue }
                            $bodyLength = if ($text -match 'Content-Length:\s*(\d+)') { [int]$Matches[1] } else { 0 }
                            if (($text.Length - $headerEnd - 4) -ge $bodyLength) { break }
                        }

                        if ($text.StartsWith("POST")) {
                            # ログイン: 正しいパスワードなら以後は状態ページを返す
                            $State.Logins[$ip] = 1 + [int]$State.Logins[$ip]
                            if ($text.EndsWith("LOGIN_PASSWORD=" + [System.Uri]::EscapeDataString($Password))) { $loggedIn[$ip] = $true }
                            $page = "<html>ok</html>"
                        }
                        elseif (-not $loggedIn[$ip]) {
                            # 実機と同じく、未ログインなら stainfo のないログイン画面を返す
                            $page = "<html>login</html>"
                        }
                        else {
                            if ($null -eq $startedAt) { $startedAt = Get-Date }
                            $elapsed = ((Get-Date) - $startedAt).TotalSeconds
                            $info = if ($elapsed -lt $PhaseA) { 'ssid:"AP-A(00:11:22:33:44:55)",chan:"6 (2.4GHz) 20MHz",signal:-50,txbitrate:"144.4 Mbit/s"' }
                                elseif ($elapsed -lt $PhaseDown) { 'ssid:"---(---)",chan:"---",signal:0,txbitrate:"---"' }
                                elseif ($elapsed -lt $PhaseB) { 'ssid:"AP-B(AA:BB:CC:DD:EE:FF)",chan:"36 (5GHz) 40MHz",signal:-70,txbitrate:"72 Mbit/s"' }
                                else { 'ssid:"AP-C(11:22:33:44:55:66)",chan:"36 (5GHz) 40MHz",signal:-60,txbitrate:"300 Mbit/s"' }
                            $page = "<script>var stainfo = {$info};</script>"
                        }
                        $reply = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: $($page.Length)`r`nConnection: close`r`n`r`n$page")
                        $stream.Write($reply, 0, $reply.Length)
                        $stream.Flush()
                    }
                    catch {
                        # 確認の途中でサーバーが切断しても、模擬 OBR は動き続ける
                    }
                    finally { $client.Close() }
                }
                if (-not $served) { Start-Sleep -Milliseconds 50 }
            }
        })
    # 80 番を待ち受ける。使えないときは例外になり、呼び出し側でテストを省略する
    $listeners = foreach ($address in $Addresses) {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse($address), 80)
        $listener.Start()
        $listener
    }
    $null = $shell.AddArgument(@($listeners)).AddArgument($Password).AddArgument($State).AddArgument(25).AddArgument(45).AddArgument(65)
    return @{ Shell = $shell; Handle = $shell.BeginInvoke(); Listeners = @($listeners) }
}

Describe "OBR の無線確認の通しテスト (模擬 OBR)" {
    $password = "test-obr-pass"
    $slowAddresses = 6..10 | ForEach-Object { "127.0.0.$_" }
    $state = [hashtable]::Synchronized(@{ Stop = $false; Logins = [hashtable]::Synchronized(@{}) })
    $fake = $null
    $slowListeners = @()
    $serverProcess = $null
    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_ObrE2E_$([Guid]::NewGuid().ToString('N'))"

    try {
        # ── 準備: 模擬 OBR ───────────────────────────────────────────────────
        $canListen = $true
        try {
            $fake = Start-FakeObrServer -Addresses @("127.0.0.2", "127.0.0.3") -Password $password -State $state
            # 応答しない機器は、待ち受けるだけで受け取らない (接続はできるが応答がない状態になる)
            $slowListeners = foreach ($address in $slowAddresses) {
                $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse($address), 80)
                $listener.Start()
                $listener
            }
        }
        catch {
            $canListen = $false
            Write-Host "  [SKIP] Port 80 is not available for the fake OBR: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        if (-not $canListen) { return }

        # ── 準備: 実機の設定を含まないコピーと、テスト用の機器一覧 ──────────────
        $copySystem = Join-Path $workDir "system"
        $null = & robocopy $systemDir $copySystem /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 /XF devices.json config.json debug.log debug_1.log .bom_cache /XD backups tests iperf3.18_64
        if ($LASTEXITCODE -ge 8) { throw "Failed to copy the system folder (robocopy exit code $LASTEXITCODE)." }

        $devices = @(
            @{ ip = "127.0.0.2"; name = "OBR-Good"; group = "T"; image = "router"; obrEnabled = $true; obrPassword = $password },
            @{ ip = "127.0.0.3"; name = "OBR-BadPass"; group = "T"; image = "router"; obrEnabled = $true; obrPassword = "wrong" },
            @{ ip = "127.0.0.4"; name = "Not-OBR"; group = "T"; image = "router" },
            @{ ip = "127.0.0.5"; name = "OBR-NoPass"; group = "T"; image = "router"; obrEnabled = $true }
        )
        foreach ($address in $slowAddresses) {
            $devices += @{ ip = $address; name = "OBR-Slow-$address"; group = "T"; image = "router"; obrEnabled = $true; obrPassword = $password }
        }
        $noBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $copySystem "devices.json"), (ConvertTo-Json -InputObject $devices -Depth 4), $noBom)
        [System.IO.File]::WriteAllText((Join-Path $copySystem "config.json"), '{"autoShutdownOnDisconnect": false, "loggingEnabled": true}', $noBom)

        # ── 準備: サーバーの起動 (空いているポートを使う) ────────────────────────
        $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $probe.Start()
        $port = $probe.LocalEndpoint.Port
        $probe.Stop()
        $baseUrl = "http://localhost:$port"

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = "powershell.exe"
        $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $copySystem 'Server.ps1')`" -Port $port"
        $startInfo.WorkingDirectory = $copySystem
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $serverProcess = [System.Diagnostics.Process]::Start($startInfo)

        $getHistory = { param($ip) Invoke-RestMethod -Uri "$baseUrl/api/obr/history?ip=$ip" -TimeoutSec 15 }

        It "サーバーが起動すること" {
            $healthy = $false
            for ($attempt = 0; $attempt -lt 60 -and -not $healthy; $attempt++) {
                try { $healthy = (Invoke-RestMethod -Uri "$baseUrl/api/health" -TimeoutSec 2).status -eq "ok" }
                catch { Start-Sleep -Seconds 1 }
            }
            $healthy | Should Be $true
        }

        # 切断 → 復旧 → AP の切り替えが記録されるまで待つ (模擬 OBR の時間割で 70 秒ほどかかる)
        $view = $null
        $deadline = (Get-Date).AddSeconds(170)
        while ((Get-Date) -lt $deadline) {
            try { $view = & $getHistory "127.0.0.2" } catch { $view = $null }
            if ($null -ne $view) {
                $kinds = @($view.events | ForEach-Object { $_.type })
                if (($kinds -contains "disconnected") -and ($kinds -contains "recovered") -and ($kinds -contains "roamed") -and $view.rowCount -ge 6) { break }
            }
            Start-Sleep -Seconds 5
        }

        It "切断・復旧・AP の切り替えが、この順番で出来事になること" {
            $view | Should Not BeNullOrEmpty
            $kinds = @($view.events | ForEach-Object { $_.type })
            $kinds[0] | Should Be "disconnected"
            $kinds[1] | Should Be "recovered"
            $kinds -contains "roamed" | Should Be $true
        }

        It "電波の強さと通信速度が数値で返り、切断中は値なしになること" {
            @($view.points | Where-Object { $_.signal -eq -50 -and $_.rate -eq 144.4 }).Count | Should BeGreaterThan 0
            @($view.points | Where-Object { $null -eq $_.signal }).Count | Should BeGreaterThan 0
        }

        It "応答しない機器が 5 台あっても、確認間隔が約 10 秒に保たれること" {
            $times = @($view.points | ForEach-Object { [datetime]$_.t })
            $times.Count | Should BeGreaterThan 3
            for ($index = 1; $index -lt $times.Count; $index++) {
                $gap = ($times[$index] - $times[$index - 1]).TotalSeconds
                ($gap -ge 9 -and $gap -le 13) | Should Be $true
            }
        }

        It "応答しない機器は「確認できず」として記録されること" {
            @((& $getHistory "127.0.0.6").events | ForEach-Object { $_.type }) -contains "unreachable" | Should Be $true
        }

        It "正しいパスワードのログインは 1 回だけで、毎回は送らないこと" {
            $state.Logins["127.0.0.2"] | Should Be 1
        }

        It "パスワードが違う機器はログイン失敗として記録し、ログインをくり返さないこと" {
            @((& $getHistory "127.0.0.3").events | ForEach-Object { $_.type }) -contains "loginFailed" | Should Be $true
            $state.Logins["127.0.0.3"] | Should Be 1
        }

        It "OBR でない機器とパスワード未設定の機器は記録されないこと" {
            (& $getHistory "127.0.0.4").rowCount | Should Be 0
            (& $getHistory "127.0.0.5").rowCount | Should Be 0
        }

        It "不正な IP アドレスは 400、外部サイトからの呼び出しは 403 で拒否すること" {
            Get-ObrTestStatusCode "$baseUrl/api/obr/history?ip=a;b" | Should Be 400
            Get-ObrTestStatusCode "$baseUrl/api/obr/history" | Should Be 400
            Get-ObrTestStatusCode "$baseUrl/api/obr/history?ip=127.0.0.2" @{ Origin = "https://evil.example.com" } | Should Be 403
        }

        It "機器の IP アドレスを変更しても履歴を引き継ぐこと" {
            $before = (& $getHistory "127.0.0.3").rowCount
            $before | Should BeGreaterThan 0
            $body = '{"oldIp":"127.0.0.3","newIp":"127.0.0.12","name":"OBR-BadPass"}'
            $null = Invoke-RestMethod -Uri "$baseUrl/api/device/edit" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 15
            (& $getHistory "127.0.0.12").rowCount | Should Not BeLessThan $before
            (& $getHistory "127.0.0.3").rowCount | Should Be 0
        }

        It "POST /api/shutdown でサーバーが自分で終了すること" {
            $null = Invoke-RestMethod -Uri "$baseUrl/api/shutdown" -Method Post -TimeoutSec 15
            $serverProcess.WaitForExit(45000) | Should Be $true
            $serverProcess.ExitCode | Should Be 0
        }
    }
    finally {
        # ── 後片付け: 途中で失敗しても必ず止めて消す ─────────────────────────────
        if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
            try { $serverProcess.Kill(); $null = $serverProcess.WaitForExit(5000) } catch {}
        }
        $state.Stop = $true
        if ($null -ne $fake) {
            $null = $fake.Handle.AsyncWaitHandle.WaitOne(3000)
            foreach ($listener in $fake.Listeners) { try { $listener.Stop() } catch {} }
            $fake.Shell.Dispose()
        }
        foreach ($listener in @($slowListeners)) { if ($listener) { try { $listener.Stop() } catch {} } }
        # 別のフォルダを消さないよう、このテストが付けた名前のときだけ消す
        if ((Split-Path -Leaf $workDir).StartsWith("NDM_ObrE2E_") -and (Test-Path -LiteralPath $workDir)) {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
