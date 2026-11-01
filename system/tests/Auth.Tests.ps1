# ==============================================================================
# Auth.Tests.ps1 - 合言葉による認証のテスト
# ==============================================================================
# 【初心者向けの簡単な解説】
# 合言葉を持たない要求が画面でも API でも拒否され、Start-Monitor.bat と同じ開き方なら
# ブラウザに記憶されて使えることを確かめます。
#
# 【実機の設定を守るしくみ】
# 一時フォルダへ system をコピーして動かします。実際の devices.json / config.json は使いません。
# 合言葉はふだんと同じファイルを使い、読むだけで変更しません (保存処理のテストは一時フォルダで行います)。
#
# 【変更するときの注意】
# - Invoke-WebRequest はリダイレクトを自動でたどるので、302 を確かめる所は HttpWebRequest を使います。
# - このテストではヘッダーを自動で付けません。合言葉がないときの動作を確かめるためです。
# ==============================================================================

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$systemDir = Split-Path -Parent $here
Import-Module (Join-Path $systemDir "modules\Common.psm1") -Force -DisableNameChecking

Describe "Get-AppAuthToken / Test-AuthTokenValid (合言葉の作成と判定)" {
    It "合言葉を作って保存し、次回も同じものを返すこと" {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_Auth_$(Get-Random)"
        try {
            $path = Join-Path $dir "sub\token.txt"
            $first = Get-AppAuthToken -Path $path
            $first | Should Match '^[0-9a-f]{64}$'
            Get-AppAuthToken -Path $path | Should Be $first
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "保存された内容が壊れていれば作り直し、毎回違う値になること" {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_Auth_$(Get-Random)"
        $null = New-Item -ItemType Directory -Path $dir
        try {
            $path = Join-Path $dir "token.txt"
            [System.IO.File]::WriteAllText($path, "broken")
            $made = Get-AppAuthToken -Path $path
            $made | Should Match '^[0-9a-f]{64}$'
            Get-AppAuthToken -Path (Join-Path $dir "other.txt") | Should Not Be $made
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "一致するときだけ許可し、空は拒否すること" {
        Test-AuthTokenValid -Provided "abc" -Expected "abc" | Should Be $true
        Test-AuthTokenValid -Provided "abd" -Expected "abc" | Should Be $false
        Test-AuthTokenValid -Provided "ab" -Expected "abc" | Should Be $false
        Test-AuthTokenValid -Provided "ABC" -Expected "abc" | Should Be $false
        Test-AuthTokenValid -Provided "" -Expected "abc" | Should Be $false
        Test-AuthTokenValid -Provided "" -Expected "" | Should Be $false
    }
}

Describe "サーバーの認証 (サーバーを起動して確認)" {
    # 状態コードと、応答のヘッダー・本文を返す (リダイレクトはたどらない)
    function Send-TestRequest {
        param([string]$Url, [hashtable]$Headers = @{}, [string]$Cookie = "", [string]$Method = "GET")
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = $Method
        $req.AllowAutoRedirect = $false
        $req.Proxy = $null
        $req.Timeout = 15000
        if ($Method -eq "POST") { $req.ContentLength = 0 }
        foreach ($name in $Headers.Keys) { $req.Headers[$name] = $Headers[$name] }
        if ($Cookie) { $req.Headers["Cookie"] = $Cookie }
        try { $resp = $req.GetResponse() }
        catch [System.Net.WebException] {
            $resp = $_.Exception.Response
            if ($null -eq $resp) { throw }
        }
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $result = @{ Code = [int]$resp.StatusCode; Body = $reader.ReadToEnd(); SetCookie = $resp.Headers["Set-Cookie"]; Location = $resp.Headers["Location"] }
        $resp.Close()
        return $result
    }

    $token = Get-AppAuthToken
    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_AuthE2E_$([Guid]::NewGuid().ToString('N'))"
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

        It "合言葉なしでも /api/health だけは応答すること (Watchdog の死活確認用)" {
            $code = 0
            for ($attempt = 0; $attempt -lt 60 -and $code -ne 200; $attempt++) {
                try { $code = (Send-TestRequest "$baseUrl/api/health").Code } catch { Start-Sleep -Seconds 1 }
            }
            $code | Should Be 200
        }

        It "合言葉なしの API は 401 になること" {
            foreach ($path in @("/api/devices", "/api/config", "/api/config/export")) {
                $result = Send-TestRequest "$baseUrl$path"
                $result.Code | Should Be 401
                $result.Body | Should Match "UNAUTHORIZED"
            }
        }

        It "合言葉なしの操作 (コマンド実行・終了) も 401 になること" {
            (Send-TestRequest "$baseUrl/api/device/remote-exec" -Method POST).Code | Should Be 401
            (Send-TestRequest "$baseUrl/api/shutdown" -Method POST).Code | Should Be 401
            $serverProcess.HasExited | Should Be $false
        }

        It "合言葉なしの画面は 401 で、Start-Monitor.bat の案内を表示すること" {
            $result = Send-TestRequest "$baseUrl/"
            $result.Code | Should Be 401
            $result.Body | Should Match "Start-Monitor\.bat"
            (Send-TestRequest "$baseUrl/app.js").Code | Should Be 401
        }

        It "違う合言葉は、ヘッダーでもクッキーでも URL でも拒否されること" {
            $wrong = "0" * 64
            (Send-TestRequest "$baseUrl/api/devices" -Headers @{ "X-NDM-Auth" = $wrong }).Code | Should Be 401
            (Send-TestRequest "$baseUrl/api/devices" -Cookie "NDM_Auth=$wrong").Code | Should Be 401
            (Send-TestRequest "$baseUrl/?auth=$wrong").Code | Should Be 401
        }

        It "API の URL に合言葉を付けても受け付けないこと" {
            (Send-TestRequest "$baseUrl/api/devices?auth=$token").Code | Should Be 401
        }

        It "Start-Monitor.bat の開き方では、合言葉を記憶させて / へ移動させること" {
            $result = Send-TestRequest "$baseUrl/?auth=$token"
            $result.Code | Should Be 302
            $result.Location | Should Be "/"
            $result.SetCookie | Should Match "NDM_Auth=$token"
            $result.SetCookie | Should Match "HttpOnly"
            $result.SetCookie | Should Match "SameSite=Strict"
        }

        It "記憶した合言葉 (クッキー) で画面と API を使えること" {
            (Send-TestRequest "$baseUrl/" -Cookie "NDM_Auth=$token").Code | Should Be 200
            (Send-TestRequest "$baseUrl/app.js" -Cookie "NDM_Auth=$token").Code | Should Be 200
            (Send-TestRequest "$baseUrl/api/devices" -Cookie "NDM_Auth=$token").Code | Should Be 200
        }

        It "プログラムからはヘッダーの合言葉で API を使えること" {
            (Send-TestRequest "$baseUrl/api/devices" -Headers @{ "X-NDM-Auth" = $token }).Code | Should Be 200
        }

        It "合言葉があっても、外部サイトからの呼び出しは 403 のままであること" {
            (Send-TestRequest "$baseUrl/api/devices" -Cookie "NDM_Auth=$token" -Headers @{ "Origin" = "https://evil.example.com" }).Code | Should Be 403
        }

        It "起動中に Watchdog を実行すると、2 つ目のサーバーを起動せずに終わること" {
            $serversBefore = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match [regex]::Escape($copySystem) }).Count
            $watchdog = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$(Join-Path $copySystem 'Watchdog.ps1')`"", "-Port", "$port" -PassThru -WindowStyle Hidden
            $watchdog.WaitForExit(20000) | Should Be $true
            $watchdog.ExitCode | Should Be 0
            @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match [regex]::Escape($copySystem) }).Count | Should Be $serversBefore
        }

        $null = Send-TestRequest "$baseUrl/api/shutdown" -Method POST -Headers @{ "X-NDM-Auth" = $token }
        $null = $serverProcess.WaitForExit(30000)
    }
    finally {
        if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
            try { $serverProcess.Kill(); $null = $serverProcess.WaitForExit(5000) } catch {}
        }
        if ((Split-Path -Leaf $workDir).StartsWith("NDM_AuthE2E_") -and (Test-Path -LiteralPath $workDir)) {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
