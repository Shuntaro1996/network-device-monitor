# ==============================================================================
# E2E-Lifecycle.Tests.ps1 - Network Device Monitor E2E Lifecycle Test Suite
# ==============================================================================
# 【初心者向けの簡単な解説】
# このテストは、監視サーバー（system/Server.ps1）を実際にバックグラウンドで起動し、
# 以下のシステム全体の「一連の動作（ライフサイクル）」を自動検証します。
# 1. 隔離されたポート（例: 8089）でサーバーが正常に起動すること
# 2. ヘルスチェック（/api/health）が疎通し、Ping監視ループが健全（pingAgeSec < 5.0）であること
# 3. 機器ステータスAPI（/api/status）からパケットロス・ジッター・遅延等の有効なメトリクスが返ること
# 4. 正常終了リクエスト（POST /api/shutdown）を受信して安全に終了（ExitCode 0）すること
# 5. 終了後に Reports/ 配下にセッションフォルダ、CSVログ、およびHTMLサマリーレポートが生成されること
# ==============================================================================

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Resolve-Path (Join-Path $here "..")
$systemDir = Join-Path $projectRoot "system"
$serverScript = Join-Path $systemDir "Server.ps1"
$reportsDir = Join-Path $projectRoot "Reports"

# Pester非実行環境（直接 powershell -File で実行された場合）の自動フォールバック
if (-not (Get-Command "Describe" -ErrorAction SilentlyContinue)) {
    $runTestsScript = Join-Path $here "Run-Tests.ps1"
    if (Test-Path $runTestsScript) {
        Write-Host "[INFO] Launching E2E-Lifecycle.Tests.ps1 via Run-Tests.ps1 runner..." -ForegroundColor Cyan
        & $runTestsScript -Filter "E2E-Lifecycle.Tests.ps1"
        return
    }
}

Describe "F14: 自動 E2E サーバーライフサイクル統合テスト (Full Server Lifecycle)" {
    BeforeAll {
        $global:e2eTestPort = 8089
        $global:serverProc = $null
        $global:testSessionDir = $null
        $global:serverStartedUtc = [DateTime]::UtcNow

        # ── 1. 衝突しない隔離テスト用ポートの自動選定 (8089〜8120) ──────────────────
        for ($candidatePort = 8089; $candidatePort -le 8120; $candidatePort++) {
            $tcpListener = $null
            try {
                $tcpListener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $candidatePort)
                $tcpListener.Start()
                $tcpListener.Stop()
                $global:e2eTestPort = $candidatePort
                break
            } catch {
                if ($tcpListener) { try { $tcpListener.Stop() } catch {} }
            }
        }
        Write-Host "  [E2E SETUP] Selected isolated test port: $($global:e2eTestPort)" -ForegroundColor Cyan

        # ── 2. Server.ps1 のバックグラウンド起動 ──────────────────────────────────
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$serverScript`" -Port $($global:e2eTestPort)"
        $psi.WorkingDirectory = $systemDir
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $global:serverProc = [System.Diagnostics.Process]::Start($psi)
        $global:serverStartedUtc = [DateTime]::UtcNow
        Write-Host "  [E2E SETUP] Server.ps1 launched (PID: $($global:serverProc.Id))" -ForegroundColor Cyan
    }

    AfterAll {
        # ── テスト終了後の確実な後片付け（フェイルセーフ） ─────────────────────────
        if ($global:serverProc -and -not $global:serverProc.HasExited) {
            Write-Host "  [E2E CLEANUP] Teardown: Sending shutdown signal to PID $($global:serverProc.Id)..." -ForegroundColor Yellow
            try {
                $shutdownUrl = "http://localhost:$($global:e2eTestPort)/api/shutdown"
                $null = Invoke-RestMethod -Uri $shutdownUrl -Method Post -TimeoutSec 2 -ErrorAction SilentlyContinue
                $global:serverProc.WaitForExit(3000)
            } catch {}

            if (-not $global:serverProc.HasExited) {
                Write-Host "  [E2E CLEANUP] Process did not exit in time. Terminating forcefully..." -ForegroundColor Red
                try { $global:serverProc.Kill() } catch {}
            }
        }
    }

    # ──────────────────────────────────────────────────────────────────────────
    # Phase 1: サーバー起動とヘルスチェック待機
    # ──────────────────────────────────────────────────────────────────────────
    Context "1. サーバー起動とヘルスチェック待機 (/api/health)" {
        It "Server.ps1 プロセスが正常に起動し 有効な PID を保持していること" {
            $global:serverProc | Should Not BeNullOrEmpty
            $global:serverProc.Id | Should BeGreaterThan 0
            $global:serverProc.HasExited | Should Be $false
        }

        It "最大60秒以内に /api/health が HTTP 200 を返し status 'ok' かつ pingAgeSec < 15.0 になること" {
            $healthUrl = "http://localhost:$($global:e2eTestPort)/api/health"
            $maxWaitSec = 60
            $pollIntervalMs = 500
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $healthData = $null

            while ($stopwatch.Elapsed.TotalSeconds -lt $maxWaitSec) {
                if ($global:serverProc.HasExited) {
                    throw "Server process terminated prematurely with exit code $($global:serverProc.ExitCode)"
                }
                try {
                    $resp = Invoke-RestMethod -Uri $healthUrl -Method Get -TimeoutSec 2 -ErrorAction Stop
                    if ($resp -and $resp.status -eq "ok" -and ($resp.pingAgeSec -lt 15.0 -or $resp.uptimeSec -lt 30)) {
                        $healthData = $resp
                        if ($resp.sessionDir) {
                            $global:serverSessionDir = $resp.sessionDir
                        }
                        break
                    }
                } catch {
                    # 起動完了待機
                }
                Start-Sleep -Milliseconds $pollIntervalMs
            }

            $healthData | Should Not BeNullOrEmpty
            $healthData.status | Should Be "ok"
            $healthData.message | Should Be "OK"
            [double]$healthData.pingAgeSec | Should BeLessThan 15.0
            [int]$healthData.uptimeSec | Should BeGreaterThan -1
        }
    }

    # ──────────────────────────────────────────────────────────────────────────
    # Phase 2: 監視メトリクス整合性検証 (/api/status)
    # ──────────────────────────────────────────────────────────────────────────
    Context "2. 機器監視メトリクス取得と数値整合性検証 (/api/status)" {
        It "/api/status から有効な JSON レスポンスと _ipConflicts 配列が取得できること" {
            $statusUrl = "http://localhost:$($global:e2eTestPort)/api/status"
            $statusData = $null
            $sw = [System.Diagnostics.Stopwatch]::StartNew()

            # Ping初回サイクル完了まで最大10秒ポーリング
            while ($sw.Elapsed.TotalSeconds -lt 10) {
                try {
                    $res = Invoke-RestMethod -Uri $statusUrl -Method Get -TimeoutSec 3 -ErrorAction Stop
                    if ($res) {
                        $statusData = $res
                        break
                    }
                } catch {}
                Start-Sleep -Milliseconds 500
            }

            $statusData | Should Not BeNullOrEmpty

            # _ipConflicts キーの存在確認
            $hasIpConflicts = ($null -ne $statusData._ipConflicts) -or ($statusData.PSObject.Properties.Match("_ipConflicts").Count -gt 0)
            $hasIpConflicts | Should Be $true
        }

        It "各監視対象デバイスのメトリクス (status, loss, jitter, avgRtt) が有効な数値形式であること" {
            $statusUrl = "http://localhost:$($global:e2eTestPort)/api/status"
            $statusData = Invoke-RestMethod -Uri $statusUrl -Method Get -TimeoutSec 3 -ErrorAction Stop
            $statusData | Should Not BeNullOrEmpty

            $deviceProperties = $statusData.PSObject.Properties | Where-Object { $_.Name -notmatch '^_' }
            $deviceProperties.Count | Should BeGreaterThan 0

            foreach ($prop in $deviceProperties) {
                $devMetrics = $prop.Value
                $devMetrics | Should Not BeNullOrEmpty

                # ステータス文字列の検証 (up, down, warning, paused, success, failed など)
                [string]$devMetrics.status | Should Match '(?i)^(up|down|warning|paused|success|failed)$'

                # パケット損失率 (0.0% 〜 100.0%)
                $lossRaw = if ($null -ne $devMetrics.loss) { $devMetrics.loss } else { $devMetrics.packetLossRate }
                if ($null -ne $lossRaw) {
                    $lossVal = [double]$lossRaw
                    $lossVal | Should BeGreaterThan -0.01
                    $lossVal | Should BeLessThan 100.01
                }

                # ジッター (>= 0 ms)
                if ($null -ne $devMetrics.jitter) {
                    $jitterVal = [double]$devMetrics.jitter
                    $jitterVal | Should BeGreaterThan -0.01
                }

                # 遅延 (>= 0 ms)
                $rttRaw = if ($null -ne $devMetrics.avgRtt) { $devMetrics.avgRtt } else { $devMetrics.latency }
                if ($null -ne $rttRaw) {
                    $rttVal = [double]$rttRaw
                    $rttVal | Should BeGreaterThan -0.01
                }
            }
        }
    }

    # ──────────────────────────────────────────────────────────────────────────
    # Phase 3: グレースフルシャットダウン (/api/shutdown)
    # ──────────────────────────────────────────────────────────────────────────
    Context "3. グレースフルシャットダウン (/api/shutdown)" {
        It "POST /api/shutdown を送信すると status 'success' の応答が返ること" {
            $shutdownUrl = "http://localhost:$($global:e2eTestPort)/api/shutdown"
            $shutdownRes = Invoke-RestMethod -Uri $shutdownUrl -Method Post -TimeoutSec 5 -ErrorAction Stop
            $shutdownRes | Should Not BeNullOrEmpty
            $shutdownRes.status | Should Be "success"
        }

        It "シャットダウン要求後にサーバープロセスが安全に終了し ExitCode 0 であること" {
            $exited = $global:serverProc.WaitForExit(30000)
            $exited | Should Be $true
            $global:serverProc.HasExited | Should Be $true
            $global:serverProc.ExitCode | Should Be 0
        }
    }

    # ──────────────────────────────────────────────────────────────────────────
    # Phase 4: レポート・CSVファイル出力検証 (Reports/)
    # ──────────────────────────────────────────────────────────────────────────
    Context "4. レポート生成検証 (Reports/ ディレクトリ & CSV / HTML)" {
        It "Reports/ 配下に今回のテスト実行セッションフォルダ (yyyyMMdd_HHmmss) が生成されていること" {
            Test-Path $reportsDir | Should Be $true

            if ($global:serverSessionDir -and (Test-Path $global:serverSessionDir)) {
                $global:testSessionDir = $global:serverSessionDir
                Write-Host "  [E2E VERIFY] Session directory resolved via /api/health: $($global:testSessionDir)" -ForegroundColor Green
            } else {
                $sessionDirs = Get-ChildItem -Path $reportsDir -Directory -ErrorAction SilentlyContinue | Where-Object {
                    $_.Name -match '^\d{8}_\d{6}$'
                } | Sort-Object Name -Descending

                foreach ($dir in $sessionDirs) {
                    if ($dir.CreationTimeUtc -ge $global:serverStartedUtc.AddSeconds(-30)) {
                        $global:testSessionDir = $dir.FullName
                        break
                    }
                }
                if (-not $global:testSessionDir -and $sessionDirs.Count -gt 0) {
                    $global:testSessionDir = $sessionDirs[0].FullName
                }
            }

            $global:testSessionDir | Should Not BeNullOrEmpty
            Test-Path $global:testSessionDir | Should Be $true
            Write-Host "  [E2E VERIFY] Verified session directory: $($global:testSessionDir)" -ForegroundColor Green
        }

        It "セッションフォルダ内に機器別の CSV 測定ログが存在し、正常なヘッダーが記録されていること" {
            $global:testSessionDir | Should Not BeNullOrEmpty

            $csvFiles = @()
            for ($retryCsv = 0; $retryCsv -lt 20; $retryCsv++) {
                $csvFiles = Get-ChildItem -Path $global:testSessionDir -Filter "*.csv" -File -ErrorAction SilentlyContinue
                if ($csvFiles -and $csvFiles.Count -gt 0) { break }
                Start-Sleep -Milliseconds 500
            }
            $csvFiles.Count | Should BeGreaterThan 0

            # 最初の CSV を読み込んで内容構造を検証 (Shift-JIS / UTF-8 対応)
            $targetCsv = $csvFiles[0].FullName
            $rawContent = $null
            for ($r = 0; $r -lt 10; $r++) {
                try {
                    $rawContent = [System.IO.File]::ReadAllText($targetCsv, [System.Text.Encoding]::GetEncoding(932))
                    if ($rawContent) { break }
                } catch {
                    Start-Sleep -Milliseconds 200
                }
            }
            $rawContent | Should Not BeNullOrEmpty
            
            # CSV に必須ヘッダー要素（IPアドレス、ステータス、またはタイムスタンプ）が含まれていること
            $hasHeader = ($rawContent -match 'タイムスタンプ' -or $rawContent -match 'IPアドレス' -or $rawContent -match 'ステータス')
            $hasHeader | Should Be $true
        }

        It "セッションフォルダ内に HTML サマリーレポート (report.html) が 0 バイト超で生成されていること" {
            $global:testSessionDir | Should Not BeNullOrEmpty
            $reportHtmlPath = Join-Path $global:testSessionDir "report.html"

            # サーバー終了処理後のファイルフラッシュ完了を最大15秒(30回×500ms)ポーリング待機
            $found = $false
            for ($attempt = 0; $attempt -lt 30; $attempt++) {
                if (Test-Path $reportHtmlPath) {
                    $found = $true
                    break
                }
                Start-Sleep -Milliseconds 500
            }
            $found | Should Be $true

            $fileInfo = Get-Item $reportHtmlPath
            $fileInfo.Length | Should BeGreaterThan 0

            # HTML 内にグラフ・レポート用の基本構造が含まれること
            $htmlText = [System.IO.File]::ReadAllText($reportHtmlPath, [System.Text.Encoding]::UTF8)
            $htmlText | Should Match '<html'
            $htmlText | Should Match '</html>'
        }
    }
}
