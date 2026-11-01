# ==============================================================================
# IperfServerLog.Tests.ps1 - iperf3 のサーバー側ログの取得の通しテスト (E2E)
# ==============================================================================
# 【初心者向けの簡単な解説】
# このPCの中で iperf3 のサーバーを動かし、アプリから実際に計測して、次のことを確かめます。
# - UDP の計測だけ --get-server-output が付き、サーバー側のログが別ファイルに分かれること
# - サーバー側のログは画面の出力にも計測ログにも混ざらず、ダウンロードできること
# - 計測中にブラウザを閉じても、計測とログの取得が終わってからサーバーが終了すること
# - UDP の計測中に「監視終了」ボタンで終了しても、完了を待ち、サーバー側のログをダウンロードできること
# Enter キーでの終了は、画面のないテストからキーを送れないので、ここでは確かめていません。
#
# 【実機の設定を守るしくみ】
# 一時フォルダへ system をコピーして動かします。実際の devices.json / config.json は使いません。
#
# 【省略する場合】
# 同梱の iperf3.exe が見つからないときは、理由を表示して省略します。
#
# 【変更するときの注意】
# - 「ブラウザを閉じる」は POST /api/shutdown?reason=unload で再現しています。
#   待っている間に /api/health 以外を呼ぶと、画面が戻ったとみなされて終了が取り消されるので呼ばないでください。
# - 終了の猶予は Server.ps1 の 10 秒です。計測時間 (15 秒) はそれより長くしてください。
# ==============================================================================

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$systemDir = Split-Path -Parent $here

# サーバーの API には合言葉が必要なので、このファイルの呼び出しすべてにヘッダーを付ける
Import-Module (Join-Path $systemDir "modules\Common.psm1") -Force -DisableNameChecking
$authHeaders = @{ "X-NDM-Auth" = (Get-AppAuthToken) }
$PSDefaultParameterValues = @{ "Invoke-RestMethod:Headers" = $authHeaders; "Invoke-WebRequest:Headers" = $authHeaders }

Describe "iperf3 のサーバー側ログの取得 (UDP)" {
    $iperfExe = Join-Path $systemDir "iperf3.18_64\iperf3.exe"
    if (-not (Test-Path -LiteralPath $iperfExe)) {
        Write-Host "  [SKIP] iperf3.exe was not found." -ForegroundColor Yellow
        return
    }

    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_IperfE2E_$([Guid]::NewGuid().ToString('N'))"
    $serverProcess = $null
    $iperfServer = $null

    # 空いているポートを調べる (ポート番号 0 を指定すると Windows が空きを選ぶ)
    $getFreePort = {
        $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $probe.Start()
        $freePort = $probe.LocalEndpoint.Port
        $probe.Stop()
        return $freePort
    }

    # 相手役の iperf3 に使うポートを、5300〜5399 から空いているものを選ぶ
    # Windows が接続元に自動で割り当てる番号 (49152 以降) を使うと、相手が待ち受ける前に接続したとき、
    # 接続元と宛先が同じ番号になって自分自身につながり、計測が接続直後に失敗することがある
    $getFreeIperfPort = {
        foreach ($candidate in 5300..5399) {
            $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $candidate)
            try { $probe.Start(); $probe.Stop(); return $candidate } catch {}
        }
        throw "No free port for iperf3."
    }

    # 相手役の iperf3 を起動して待つ。PC に負荷がかかっていると起動が遅いので 3 秒待つ
    # 待ち受けの一覧 (netstat など) はこの iperf3 を正しく表示しない環境があるので使わない
    $startIperfServer = {
        $process = Start-Process -FilePath $iperfExe -ArgumentList "-s", "-p", "$iperfPort" -PassThru -WindowStyle Hidden
        Start-Sleep -Seconds 3
        return $process
    }

    try {
        # ── 準備: 実機の設定を含まないコピーとサーバーの起動 ───────────────────────
        $copySystem = Join-Path $workDir "system"
        $null = & robocopy $systemDir $copySystem /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 /XF devices.json config.json debug.log debug_1.log .bom_cache /XD backups tests
        if ($LASTEXITCODE -ge 8) { throw "Failed to copy the system folder (robocopy exit code $LASTEXITCODE)." }
        $noBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $copySystem "devices.json"), '[{"ip":"127.0.0.4","name":"Sample","group":"T","image":"router"}]', $noBom)
        [System.IO.File]::WriteAllText((Join-Path $copySystem "config.json"), '{"autoShutdownOnDisconnect": true, "loggingEnabled": true}', $noBom)

        $port = & $getFreePort
        $iperfPort = & $getFreeIperfPort
        $baseUrl = "http://localhost:$port"
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = "powershell.exe"
        $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $copySystem 'Server.ps1')`" -Port $port"
        $startInfo.WorkingDirectory = $copySystem
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $serverProcess = [System.Diagnostics.Process]::Start($startInfo)

        # 計測を始める
        $startMeasure = {
            param($seconds, $options)
            $encoded = [System.Uri]::EscapeDataString("$options -p $iperfPort")
            return Invoke-RestMethod -Uri "$baseUrl/api/iperf?ip=127.0.0.1&t=$seconds&opts=$encoded" -TimeoutSec 15
        }
        # 計測の終わりを待って、最後の状態を返す
        $waitMeasure = {
            for ($attempt = 0; $attempt -lt 120; $attempt++) {
                $status = Invoke-RestMethod -Uri "$baseUrl/api/iperf?action=status" -TimeoutSec 15
                if (-not $status.running) { return $status }
                Start-Sleep -Milliseconds 500
            }
            throw "The measurement did not finish."
        }
        $getText = { param($path) (Invoke-WebRequest -Uri "$baseUrl$path" -UseBasicParsing -TimeoutSec 15).Content }

        It "サーバーが起動すること" {
            $healthy = $false
            for ($attempt = 0; $attempt -lt 60 -and -not $healthy; $attempt++) {
                try { $healthy = (Invoke-RestMethod -Uri "$baseUrl/api/health" -TimeoutSec 2).status -eq "ok" }
                catch { Start-Sleep -Seconds 1 }
            }
            $healthy | Should Be $true
        }

        # 相手役の iperf3 は、サーバーの起動が終わってから動かす (サーバーは起動時に残っている iperf3 を片付けるため)
        $iperfServer = & $startIperfServer

        It "計測前は、サーバー側のログのダウンロードが 404 になること" {
            $code = 0
            try { $code = [int](Invoke-WebRequest -Uri "$baseUrl/api/iperf/remote-log" -UseBasicParsing -TimeoutSec 15).StatusCode }
            catch [System.Net.WebException] { $code = [int]$_.Exception.Response.StatusCode }
            $code | Should Be 404
        }

        $null = & $startMeasure 3 "-u -b 1M"
        $udpStatus = & $waitMeasure

        It "UDP の計測で --get-server-output が自動で付くこと" {
            $udpStatus.command | Should Match "--get-server-output"
        }

        It "サーバー側のログが画面の出力に混ざらないこと" {
            $udpStatus.output | Should Not Match "Server output:"
            $udpStatus.output | Should Not Match "Accepted connection"
            $udpStatus.output | Should Match "iperf Done"
        }

        It "サーバー側のログが計測ログに混ざらないこと" {
            $clientLog = [string](& $getText "/api/iperf/log?ip=127.0.0.1")
            $clientLog | Should Not Match "Accepted connection"
            $clientLog | Should Match "receiver"
        }

        It "サーバー側のログを、機器を指定しても指定しなくてもダウンロードできること" {
            foreach ($path in @("/api/iperf/remote-log?ip=127.0.0.1", "/api/iperf/remote-log")) {
                $remoteLog = [string](& $getText $path)
                $remoteLog | Should Match "iperf3 Server Output"
                $remoteLog | Should Match "Accepted connection"
                $remoteLog | Should Match "Lost/Total Datagrams"
                $remoteLog | Should Not Match "iperf Done"
            }
        }

        It "計測ログの取得 (機器の指定なし) がサーバー側のログに置き換わらないこと" {
            ([string](& $getText "/api/iperf/log")) | Should Not Match "iperf3 Server Output"
        }

        It "TCP の計測には付かず、サーバー側のログも増えないこと" {
            $before = [regex]::Matches([string](& $getText "/api/iperf/remote-log?ip=127.0.0.1"), "iperf3 Server Output").Count
            $null = & $startMeasure 2 "-R"
            $tcpStatus = & $waitMeasure
            $tcpStatus.command | Should Not Match "--get-server-output"
            [regex]::Matches([string](& $getText "/api/iperf/remote-log?ip=127.0.0.1"), "iperf3 Server Output").Count | Should Be $before
        }

        It "計測中にブラウザを閉じても、10 秒の猶予のあとサーバーが止まらないこと" {
            $null = & $startMeasure 15 "-u -b 1M"
            Start-Sleep -Seconds 1
            $null = Invoke-RestMethod -Uri "$baseUrl/api/shutdown?reason=unload" -Method Post -TimeoutSec 15
            Start-Sleep -Seconds 12
            $serverProcess.HasExited | Should Be $false
        }

        It "計測が終わると、サーバーが自分で終了すること" {
            $serverProcess.WaitForExit(60000) | Should Be $true
            $serverProcess.ExitCode | Should Be 0
        }

        It "ブラウザを閉じたあとの計測のサーバー側のログも保存されていること" {
            $remoteFile = @(Get-ChildItem -Path (Join-Path $workDir "Reports") -Recurse -Filter "remote_iperf_127.0.0.1.log")
            $remoteFile.Count | Should Be 1
            $text = [System.IO.File]::ReadAllText($remoteFile[0].FullName, [System.Text.Encoding]::UTF8)
            # UDP の計測は 3 秒と 15 秒の 2 回
            [regex]::Matches($text, "iperf3 Server Output").Count | Should Be 2
            $text | Should Match "14\.\d+-15\.\d+\s+sec"
        }

        # ── 2 台目のサーバー: 「監視終了」ボタンの終了 (reason なしの POST /api/shutdown) ──
        # 新しいセッションになるので、1 回目のログとは別のファイルになる
        if ($null -ne $iperfServer -and -not $iperfServer.HasExited) { $iperfServer.Kill(); $null = $iperfServer.WaitForExit(3000) }
        $port = & $getFreePort
        $iperfPort = & $getFreeIperfPort
        $baseUrl = "http://localhost:$port"
        $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $copySystem 'Server.ps1')`" -Port $port"
        $serverProcess = [System.Diagnostics.Process]::Start($startInfo)
        for ($attempt = 0; $attempt -lt 60; $attempt++) {
            try { if ((Invoke-RestMethod -Uri "$baseUrl/api/health" -TimeoutSec 2).status -eq "ok") { break } }
            catch { Start-Sleep -Seconds 1 }
        }
        $iperfServer = & $startIperfServer

        It "UDP の計測中に「監視終了」で終了すると、完了を待つことが応答で分かること" {
            $null = & $startMeasure 8 "-u -b 1M"
            Start-Sleep -Seconds 1
            (Invoke-RestMethod -Uri "$baseUrl/api/shutdown" -Method Post -TimeoutSec 15).waitingForIperf | Should Be $true
            Start-Sleep -Seconds 4
            $serverProcess.HasExited | Should Be $false
        }

        It "計測が終わったあと、サーバーの終了前にサーバー側のログをダウンロードできること" {
            $null = & $waitMeasure
            $remoteLog = [string](& $getText "/api/iperf/remote-log")
            $remoteLog | Should Match "iperf3 Server Output"
            $remoteLog | Should Match "7\.\d+-8\.\d+\s+sec"
        }

        It "そのあとサーバーが自分で終了すること" {
            $serverProcess.WaitForExit(40000) | Should Be $true
            $serverProcess.ExitCode | Should Be 0
        }

        # ── 3 台目のサーバー: TCP の計測中は「監視終了」で待たない ──
        if ($null -ne $iperfServer -and -not $iperfServer.HasExited) { $iperfServer.Kill(); $null = $iperfServer.WaitForExit(3000) }
        $port = & $getFreePort
        $iperfPort = & $getFreeIperfPort
        $baseUrl = "http://localhost:$port"
        $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $copySystem 'Server.ps1')`" -Port $port"
        $serverProcess = [System.Diagnostics.Process]::Start($startInfo)
        for ($attempt = 0; $attempt -lt 60; $attempt++) {
            try { if ((Invoke-RestMethod -Uri "$baseUrl/api/health" -TimeoutSec 2).status -eq "ok") { break } }
            catch { Start-Sleep -Seconds 1 }
        }
        $iperfServer = & $startIperfServer

        It "TCP の計測中に「監視終了」で終了すると、完了を待たずに終了すること" {
            $null = & $startMeasure 60 "-R"
            Start-Sleep -Seconds 1
            (Invoke-RestMethod -Uri "$baseUrl/api/shutdown" -Method Post -TimeoutSec 15).waitingForIperf | Should Be $false
            $serverProcess.WaitForExit(30000) | Should Be $true
        }
    }
    finally {
        # ── 後片付け: 途中で失敗しても必ず止めて消す ─────────────────────────────
        if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
            try { $serverProcess.Kill(); $null = $serverProcess.WaitForExit(5000) } catch {}
        }
        if ($null -ne $iperfServer -and -not $iperfServer.HasExited) {
            try { $iperfServer.Kill(); $null = $iperfServer.WaitForExit(3000) } catch {}
        }
        # 別のフォルダを消さないよう、このテストが付けた名前のときだけ消す
        if ((Split-Path -Leaf $workDir).StartsWith("NDM_IperfE2E_") -and (Test-Path -LiteralPath $workDir)) {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
