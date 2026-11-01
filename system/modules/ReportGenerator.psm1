# ==============================================================================
# ReportGenerator.psm1 - 点検報告書・CSVサマリー・ロールアップ高速化モジュール
# ==============================================================================
# 【初心者向けの簡単な解説】
# 監視の結果をまとめる部品です。主な内容は次のとおりです。
#   - 点検報告書 (report.html) の作成: グラフ用のプログラムも中に入れるので、1 ファイルで開けます
#   - 古いセッションのフォルダの削除: 保存日数を過ぎたものを消します
#   - グラフ用データの事前の間引き: 長時間の記録でも報告書をすぐ作るためです
#   - 失敗した iperf の計測ログの除去
#
# 【変更するときの注意】
# - 機器名など外から来た値は、必ず HtmlEncode してから報告書に入れてください。
# - CSV の列の順番は Server.ps1 の書き込み処理に合わせています。片方だけ変えないでください。
# - テストは tests/Monitor.Tests.ps1 の 4、5、6、12 です。
# ==============================================================================

# 報告書HTMLの文字エスケープで使う [System.Web.HttpUtility] は PowerShell 5.1 では既定で読み込まれないため明示的に読み込む
# (他の処理が偶然読み込んでいない環境では、報告書生成が「型が見つかりません」で失敗していた)
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

# ── 1. Iperf3 コネクションエラーの自動除外・クリーンアップ ──────────────────

function Clean-IperfLogLines {
    <#
    .SYNOPSIS
        Iperf3のログ行配列から、有効な帯域転送データ（bits/sec）を含まない
        コネクションエラー・失敗試行のブロックのみを検知して除外します。
    .OUTPUTS
        残す行の配列。「=== iperf3 Execution」で始まる 1 回分の中に転送の行が 1 つもなければ、その回を丸ごと除きます。
    #>
    param([string[]]$lines)
    if ($null -eq $lines -or $lines.Count -eq 0) { return @() }
    
    $cleanBlocks = @()
    $currentBlock = @()
    $inBlock = $false
    $hasBw = $false

    foreach ($line in $lines) {
        if ($line -match '^=== iperf3 Execution') {
            if ($currentBlock.Count -gt 0 -and $hasBw) {
                $cleanBlocks += $currentBlock
            }
            $currentBlock = @($line)
            $inBlock = $true
            $hasBw = $false
        } else {
            if ($inBlock) {
                $currentBlock += $line
                if ($line -match '\[\s*\d+\]\s+[0-9.]+\s*-\s*[0-9.]+\s+sec\s+[0-9.]+\s+[KMG]?Bytes\s+[0-9.]+\s+[KMG]?bits/sec' -and $line -notmatch 'sender|receiver|SUM') {
                    $hasBw = $true
                }
            } else {
                $cleanBlocks += $line
            }
        }
    }
    if ($currentBlock.Count -gt 0 -and $hasBw) {
        $cleanBlocks += $currentBlock
    }
    return $cleanBlocks
}

# ── 2. レポートセッション古いフォルダ自動削除 ──────────────────────────────

function Purge-OldReports {
    <#
    .SYNOPSIS
        保存日数より古いフォルダを Reports から削除し、削除した数を返します。
    .PARAMETER retentionDays
        保存日数。0 以下なら何も削除しません。
    .PARAMETER activeSessionDir
        今使っているセッションのフォルダ。古くても削除しません。
    .NOTES
        device_logs 以外のサブフォルダがすべて対象です。Reports に残したいフォルダを増やすときは、除外に追加してください。
        Invoke-PurgeOldReports との違い: 0 以下の扱いと、結果の詳しさです。
    #>
    param(
        [string]$reportsDirectory,
        [int]$retentionDays = 30,
        [string]$activeSessionDir = $null
    )
    $deletedCount = 0
    if ([string]::IsNullOrWhiteSpace($reportsDirectory) -or -not (Test-Path $reportsDirectory)) { return $deletedCount }
    if ($retentionDays -le 0) { return $deletedCount }

    $cutoff = (Get-Date).AddDays(-$retentionDays)
    try {
        Get-ChildItem -Path $reportsDirectory -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "device_logs" } | ForEach-Object {
            if ($null -ne $activeSessionDir -and $_.FullName -eq $activeSessionDir) { return }
            if ($_.LastWriteTime -lt $cutoff) {
                try {
                    Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    $deletedCount++
                } catch {}
            }
        }
    } catch {}
    return $deletedCount
}

function Invoke-PurgeOldReports {
    <#
    .SYNOPSIS
        保存日数より古いフォルダを削除し、削除数と空いた容量を返します。
    .PARAMETER retentionDays
        保存日数。0 以下なら 30 日として扱います (Purge-OldReports は何も削除しません)。
    .OUTPUTS
        DeletedCount / FreedMb / Details を持つハッシュテーブル。
    .NOTES
        Server.ps1 にも同じ名前の関数があります。変更するときは両方を確認してください。
    #>
    param(
        [string]$reportsDirectory,
        [int]$retentionDays = 30,
        [string]$activeSessionDir = $null
    )
    $result = @{
        DeletedCount = 0
        FreedMb = 0.0
        Details = @()
    }
    if ([string]::IsNullOrWhiteSpace($reportsDirectory) -or -not (Test-Path $reportsDirectory)) {
        return $result
    }
    if ($retentionDays -le 0) { $retentionDays = 30 }

    $cutoff = (Get-Date).AddDays(-$retentionDays)
    try {
        $dirs = Get-ChildItem -Path $reportsDirectory -Directory -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -ne "device_logs" -and $_.LastWriteTime -lt $cutoff
        }
        foreach ($dir in $dirs) {
            if ($null -ne $activeSessionDir -and $dir.FullName -eq $activeSessionDir) { continue }
            try {
                $files = Get-ChildItem -Path $dir.FullName -Recurse -File -ErrorAction SilentlyContinue
                $dirBytes = ($files | Measure-Object -Property Length -Sum).Sum
                if ($null -eq $dirBytes) { $dirBytes = 0 }
                Remove-Item -Path $dir.FullName -Recurse -Force -ErrorAction Stop
                $result.DeletedCount++
                $result.FreedMb += [math]::Round($dirBytes / 1MB, 2)
                $result.Details += "Deleted old session: $($dir.Name) ($([math]::Round($dirBytes / 1MB, 2)) MB)"
            } catch {
                Write-Warning "Failed to purge old report session $($dir.FullName): $($_.Exception.Message)"
            }
        }
    } catch {
        Write-Warning "Error in Invoke-PurgeOldReports: $($_.Exception.Message)"
    }
    return $result
}

# ── 3. ロールアップ事前集約キャッシュ (長期データ高速化) ──────────────────

function Get-ChartTimeAxis {
    <#
    .SYNOPSIS
        グラフの横軸に使う位置 (0 時からの秒数) を、記録の時刻から作ります。
    .DESCRIPTION
        【初心者向けの簡単な解説】
        CSV の時刻は秒までです。0.1 秒ごとに測ると同じ時刻の点が約 10 個でき、そのまま描くと縦に重なって
        線が乱れます。そこで同じ秒の点を、その 1 秒の中に均等に並べます。
    .PARAMETER Times
        "HH:mm:ss" 形式の時刻の配列 (古い順)。
    .OUTPUTS
        Times と同じ順番の数値。時刻として読めないものは $null です。JavaScript 側はその点を描きません。
    .NOTES
        並べる位置は表示のための推定で、実際に測った瞬間ではありません。
        時刻が前より小さくなったら日付が変わったと判断し、1 日分 (86400 秒) を足して線が左へ戻らないようにします。
    #>
    param([string[]]$Times)

    $positions = [System.Collections.Generic.List[object]]::new()
    $dayOffset = 0
    $previousSeconds = -1
    $index = 0
    $count = if ($Times) { $Times.Count } else { 0 }
    while ($index -lt $count) {
        # 同じ時刻が何個続くかを数える
        $runEnd = $index
        while (($runEnd + 1) -lt $count -and $Times[$runEnd + 1] -eq $Times[$index]) { $runEnd++ }
        $runLength = $runEnd - $index + 1

        if ($Times[$index] -match '^(\d{2}):(\d{2}):(\d{2})$') {
            $seconds = [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [int]$Matches[3]
            if ($seconds -lt $previousSeconds) { $dayOffset += 86400 }
            $previousSeconds = $seconds
            for ($i = 0; $i -lt $runLength; $i++) {
                $positions.Add([math]::Round($seconds + $dayOffset + ($i / $runLength), 3))
            }
        }
        else {
            for ($i = 0; $i -lt $runLength; $i++) { $positions.Add($null) }
        }
        $index = $runEnd + 1
    }
    return $positions.ToArray()
}

function Update-RollupCache {
    <#
    .SYNOPSIS
        監視セッション中の時系列データを事前集約（最大1,200点）し、
        _rollup.json へ非同期・安全にキャッシュ保存します。
    .OUTPUTS
        保存した内容。保存できないときや入力が空のときは何も返さないか $null で、例外にはしません。
    .NOTES
        間引きは一定の間隔で点を選ぶだけなので、短い変化が消えることがあります。
    #>
    param(
        [string]$sessionDir,
        [string]$ip,
        [array]$timeSeries
    )
    if ([string]::IsNullOrWhiteSpace($sessionDir) -or -not (Test-Path $sessionDir) -or [string]::IsNullOrWhiteSpace($ip)) { return }
    if ($null -eq $timeSeries -or $timeSeries.Count -eq 0) { return }

    $cacheFile = Join-Path $sessionDir "_rollup.json"
    try {
        $rollupObj = @{ updatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"); devices = @{} }
        if (Test-Path $cacheFile) {
            try {
                $raw = [System.IO.File]::ReadAllText($cacheFile, [System.Text.Encoding]::UTF8)
                $existing = $raw | ConvertFrom-Json
                if ($existing -and $existing.devices) {
                    foreach ($prop in $existing.devices.PSObject.Properties) {
                        $rollupObj.devices[$prop.Name] = $prop.Value
                    }
                }
            } catch {}
        }

        # ダウンサンプリング (最大1200点) - O(N) Listを使用
        $total = $timeSeries.Count
        $step = if ($total -gt 1200) { [math]::Ceiling($total / 1200) } else { 1 }
        $downsampled = [System.Collections.Generic.List[object]]::new([int]([math]::Ceiling($total / $step) + 1))
        for ($i = 0; $i -lt $total; $i += $step) {
            $downsampled.Add($timeSeries[$i])
        }

        $rollupObj.devices[$ip] = $downsampled.ToArray()
        $jsonStr = $rollupObj | ConvertTo-Json -Depth 6 -Compress
        [System.IO.File]::WriteAllText($cacheFile, $jsonStr, [System.Text.Encoding]::UTF8)
        return $rollupObj
    } catch {}
    return $null
}

# ── 4. 点検報告書 HTML 生成 (Chart.js 埋め込み・ロールアップ優先) ─────────

function Generate-SessionReportHtml {
    <#
    .SYNOPSIS
        監視の結果から点検報告書 (HTML) を作ります。
    .PARAMETER sync
        監視の共有データ ($syncHash)。機器の一覧、状態、統計、セッションのフォルダなどを使います。
    .PARAMETER period
        報告書に表示する対象期間の文字。
    .PARAMETER savePath
        指定するとファイルにも保存します。
    .OUTPUTS
        HTML の文字列。
    .NOTES
        最初にメモリ上の未保存の記録を CSV へ書き出します。そのため、この関数は記録の書き込みも行います。
        一時停止中の機器と、まだ計測していない機器は報告書に載りません。
    #>
    param(
        [hashtable]$sync,
        [string]$period = "today",
        [string]$savePath = $null
    )
    $tsNow = (Get-Date).ToString("yyyy年MM月dd日 HH:mm:ss")
    $sessionDir = $sync.SessionDir
    $devices = $sync.Devices
    if ($null -eq $devices) { $devices = @() }

    # メモリ内キューのディスクフラッシュ
    if ($sync.History) {
        foreach ($ip in $devices) {
            $hList = $sync.History[$ip]
            if ($null -ne $hList) {
                $lines = @()
                [System.Threading.Monitor]::Enter($hList.SyncRoot)
                try {
                    if ($hList.Count -gt 0) {
                        $lines = $hList.ToArray()
                        $hList.Clear()
                    }
                } finally {
                    [System.Threading.Monitor]::Exit($hList.SyncRoot)
                }
                if ($lines.Count -gt 0 -and $sessionDir) {
                    $sIp = $ip -replace '[\\/:*?"<>|]', '_'
                    $cP = Join-Path $sessionDir "${sIp}.csv"
                    try { [System.IO.File]::AppendAllText($cP, ($lines -join "`r`n") + "`r`n", [System.Text.Encoding]::GetEncoding(932)) } catch {}
                }
            }
        }
    }

    # Chart.js のインラインコード取得
    $chartJsInline = ""
    $baseDir = if ($sync.PSScriptRoot) { $sync.PSScriptRoot } else { (Get-Location).Path }
    $candidatePaths = @(
        (Join-Path $baseDir "public\chart.js"),
        (Join-Path $baseDir "system\public\chart.js")
    )
    foreach ($cp in $candidatePaths) {
        if (Test-Path $cp) {
            try {
                $chartJsInline = [System.IO.File]::ReadAllText($cp, [System.Text.Encoding]::UTF8)
                if ($chartJsInline) { break }
            } catch {}
        }
    }

    $palette = @(
        '#3b82f6', '#10b981', '#f59e0b', '#ec4899', '#8b5cf6',
        '#06b6d4', '#f43f5e', '#14b8a6', '#6366f1', '#84cc16',
        '#d946ef', '#0ea5e9', '#eab308', '#a855f7', '#22c55e'
    )

    $reportRows = @()
    $allTotalSuccess = 0
    $allTotalPings = 0
    $totalLatSum = 0.0
    $totalLatCount = 0
    $maxOverallOutage = 0.0

    $chartDataObj = @{
        devices = @()
        iperfResults = @()
    }

    $devCardsHtml = @()
    $devIdx = 0

    # ロールアップキャッシュの事前読み込み確認
    $rollupCache = $null
    if ($sessionDir) {
        $cacheFile = Join-Path $sessionDir "_rollup.json"
        if (Test-Path $cacheFile) {
            try {
                $rRaw = [System.IO.File]::ReadAllText($cacheFile, [System.Text.Encoding]::UTF8)
                $rollupCache = $rRaw | ConvertFrom-Json
            } catch {}
        }
    }

    foreach ($ip in $devices) {
        $st = if ($sync.Status.ContainsKey($ip) -and $sync.Status[$ip].status) { $sync.Status[$ip].status } else { "Unknown" }
        $stats = $sync.Stats[$ip]

        # PAUSEDまたは未計測の機器は除外
        $isPaused = ($st -eq "PAUSED")
        $hasMeasured = ($null -ne $stats -and $stats.Total -gt 0)
        if ($isPaused -or -not $hasMeasured) {
            continue
        }

        $dName   = if ($sync.DeviceName.ContainsKey($ip) -and $sync.DeviceName[$ip]) { $sync.DeviceName[$ip] } else { $ip }
        $dGroup  = if ($sync.Group.ContainsKey($ip) -and $sync.Group[$ip]) { $sync.Group[$ip] } else { "未分類" }
        $color   = $palette[$devIdx % $palette.Count]

        $totalPings = 0
        $success = 0
        $failed = 0
        $reachRate = "100.0%"
        $lossRate = "0.0%"
        $avgJit = "—"
        $minLat = "—"
        $maxLat = "—"
        $avgLat = "—"
        $maxOutage = "—"
        $out600ms = "0 回"
        $out5s = "0 回"

        if ($null -ne $stats) {
            $totalPings = $stats.Total
            $success = $stats.Success
            $failed = $stats.Failed
            if ($totalPings -gt 0) {
                $reachVal = [math]::Round(($success / $totalPings) * 100, 2)
                $reachRate = "${reachVal}%"
                $lossVal = [math]::Round(($failed / $totalPings) * 100, 2)
                $lossRate = "${lossVal}%"
                $allTotalSuccess += $success
                $allTotalPings += $totalPings
            }
            if ($stats.JitterCount -gt 0) {
                $avgJit = "$([math]::Round($stats.JitterSum / $stats.JitterCount, 2)) ms"
            }
            if ($stats.LatCount -gt 0) {
                # LAN内の機器は応答が1ms未満で 0ms になることが多いため、0 も有効な値として表示する
                # (以前は -gt 0 判定で、最小・最大遅延が「—」になっていた)
                if ($stats.MinLat -ne [double]::MaxValue -and $stats.MinLat -ge 0) { $minLat = "$($stats.MinLat) ms" }
                if ($stats.MaxLat -ge 0) { $maxLat = "$($stats.MaxLat) ms" }
                $avgLatVal = [math]::Round($stats.SumLat / $stats.LatCount, 1)
                $avgLat = "$avgLatVal ms"
                $totalLatSum += $stats.SumLat
                $totalLatCount += $stats.LatCount
            }
            if ($stats.MaxOutageSec -gt 0) {
                $maxOutage = "$([math]::Round($stats.MaxOutageSec * 1000, 0)) ms"
                if ($stats.MaxOutageSec -gt $maxOverallOutage) { $maxOverallOutage = $stats.MaxOutageSec }
            }
            $out600ms = "$($stats.Outage600msCount) 回"
            $out5s = "$($stats.Outage5sCount) 回"
        }

        # 監視頻度 (Ping間隔) の算出
        $baseIntervalMs = if ($sync.PollInterval -gt 0) { [int]$sync.PollInterval } else { 1000 }
        $highFreqIps = if ($sync.HighFreqTargetIps) { ($sync.HighFreqTargetIps -split ',') | ForEach-Object { $_.Trim() } } else { @() }
        $isUltraHighFreq = ($baseIntervalMs -le 100)

        $freqDisplay = if ($isUltraHighFreq) {
            if ($highFreqIps -contains $ip) { "0.1s (100ms)" } else { "5.0s (5秒)" }
        } else {
            if ($baseIntervalMs -ge 1000) {
                if ($baseIntervalMs % 1000 -eq 0) { "$([int]($baseIntervalMs / 1000))s ($([int]($baseIntervalMs / 1000))秒)" } else { "$([math]::Round($baseIntervalMs / 1000, 1))s" }
            } else {
                "$([math]::Round($baseIntervalMs / 1000, 2))s (${baseIntervalMs}ms)"
            }
        }

        $reportRows += @"
<tr>
    <td><span class="color-dot" style="background-color:$color;"></span><strong>$([System.Web.HttpUtility]::HtmlEncode($dName))</strong><br><small style="color:#64748b;">$([System.Web.HttpUtility]::HtmlEncode($ip))</small></td>
    <td>$([System.Web.HttpUtility]::HtmlEncode($dGroup))</td>
    <td><span class="status-tag $($st.ToLower())">$st</span></td>
    <td style="text-align:center; font-weight:600; color:#475569; white-space:nowrap;">$freqDisplay</td>
    <td style="text-align:right;">$totalPings</td>
    <td style="text-align:right; color:#16a34a; font-weight:600;">$success</td>
    <td style="text-align:right; color:#dc2626; font-weight:600;">$failed</td>
    <td style="text-align:right; font-weight:700;">$reachRate</td>
    <td style="text-align:right;">$lossRate</td>
    <td style="text-align:right;">$avgJit</td>
    <td style="text-align:right;">$minLat</td>
    <td style="text-align:right;">$maxLat</td>
    <td style="text-align:right; font-weight:600; color:#2563eb;">$avgLat</td>
    <td style="text-align:right; color:#f59e0b; font-weight:600;">$maxOutage</td>
    <td style="text-align:right;">$out600ms</td>
    <td style="text-align:right;">$out5s</td>
</tr>
"@

        # 時系列データの取得（ローテーション分割CSV結合 & 事前間引きパースにより長時間・数万行でも数ミリ秒で超高速処理）
        $timeSeries = @()
        $safeIp = $ip -replace '[\\/:*?"<>|]', '_'
        $basePrefix = $safeIp
        $csvPath = if ($sessionDir) { Join-Path $sessionDir "${safeIp}.csv" } else { "" }
        if ($csvPath -and -not (Test-Path $csvPath)) {
            # $ip から直接作ると、ファイル名に使えない文字が残ったときに例外でレポート全体が止まるので、$safeIp から作る
            $altSafeIp = $safeIp -replace '[\.:_]', '_'
            $altCsvPath = Join-Path $sessionDir "${altSafeIp}.csv"
            if (Test-Path $altCsvPath) {
                $csvPath = $altCsvPath
                $basePrefix = $altSafeIp
            }
        }

        if ($csvPath -and (Test-Path $csvPath)) {
            try {
                # 10MBローテーションされた過去CSV (_10.csv .. _1.csv) と最新CSVを時系列順（古い順）に収集
                $csvSegmentPaths = [System.Collections.Generic.List[string]]::new()
                if ($sessionDir) {
                    for ($rotIdx = 10; $rotIdx -ge 1; $rotIdx--) {
                        $rotFile = Join-Path $sessionDir "${basePrefix}_${rotIdx}.csv"
                        if (Test-Path $rotFile) {
                            $csvSegmentPaths.Add($rotFile)
                        }
                    }
                }
                $csvSegmentPaths.Add($csvPath)

                $validLines = [System.Collections.Generic.List[string]]::new(8192)
                foreach ($segPath in $csvSegmentPaths) {
                    $rawLines = [System.IO.File]::ReadAllLines($segPath, [System.Text.Encoding]::GetEncoding(932))
                    $isFirstNonEmptyInSeg = $true
                    foreach ($line in $rawLines) {
                        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("---")) {
                            if (-not $isFirstNonEmptyInSeg) { break }
                            continue
                        }
                        if ($isFirstNonEmptyInSeg) {
                            $isFirstNonEmptyInSeg = $false
                            # 2ファイル目以降のヘッダー行はスキップ
                            if ($validLines.Count -gt 0 -and ($line -match 'タイムスタンプ|Timestamp')) {
                                continue
                            }
                        }
                        $validLines.Add($line)
                    }
                }
                if ($validLines.Count -gt 1) {
                    # ConvertFrom-Csv の前に生テキスト行を最大1,200件へ間引くことで O(N^2) 遅延を完全に防止
                    $dataCount = $validLines.Count - 1
                    $step = if ($dataCount -gt 1200) { [math]::Ceiling($dataCount / 1200) } else { 1 }
                    $sampledLines = [System.Collections.Generic.List[string]]::new(1205)
                    $sampledLines.Add($validLines[0]) # CSVヘッダー行
                    for ($i = 1; $i -lt $validLines.Count; $i += $step) {
                        $sampledLines.Add($validLines[$i])
                    }
                    # 最終行（最新データ）が間引きで漏れないよう末尾を保証
                    if ($validLines.Count -gt 2 -and (($validLines.Count - 1 - 1) % $step) -ne 0) {
                        $sampledLines.Add($validLines[$validLines.Count - 1])
                    }

                    $parsedCsv = @($sampledLines | ConvertFrom-Csv)
                    $tsList = [System.Collections.Generic.List[object]]::new($parsedCsv.Count)
                    foreach ($row in $parsedCsv) {
                        $tStr = if ($row.タイムスタンプ) { $row.タイムスタンプ } elseif ($row.Timestamp) { $row.Timestamp } else { "" }
                        $tShort = if ($tStr.Length -ge 19) { $tStr.Substring(11, 8) } else { $tStr }
                        $latR = if ($row.遅延_ms) { $row.遅延_ms } elseif ($row.Latency_ms) { $row.Latency_ms } else { "" }
                        $latV = if ($latR -match '^\d+(\.\d+)?$') { [double]$latR } else { $null }
                        $jitR = if ($row.ジッター_ms) { $row.ジッター_ms } elseif ($row.Jitter_ms) { $row.Jitter_ms } else { "" }
                        $jitV = if ($jitR -match '^\d+(\.\d+)?$') { [double]$jitR } else { $null }
                        $txR = if ($row.送信_Mbps) { $row.送信_Mbps } elseif ($row.Tx_Mbps) { $row.Tx_Mbps } else { "" }
                        $txV = if ($txR -match '^\d+(\.\d+)?$') { [double]$txR } else { $null }
                        $rxR = if ($row.受信_Mbps) { $row.受信_Mbps } elseif ($row.Rx_Mbps) { $row.Rx_Mbps } else { "" }
                        $rxV = if ($rxR -match '^\d+(\.\d+)?$') { [double]$rxR } else { $null }
                        $outR = if ($row.瞬断継続_sec) { $row.瞬断継続_sec } else { "" }
                        $outV = if ($outR -match '^\d+(\.\d+)?$') { [double]$outR } else { 0 }
                        $stR = if ($row.ステータス) { $row.ステータス } elseif ($row.Status) { $row.Status } else { "" }

                        $tsList.Add(@{
                            t   = $tShort
                            lat = $latV
                            jit = $jitV
                            tx  = $txV
                            rx  = $rxV
                            out = $outV
                            st  = $stR
                        })
                    }
                    $timeSeries = $tsList.ToArray()
                }
            } catch { }
        }

        if ($timeSeries.Count -eq 0) {
            $cachedDev = if ($rollupCache -and $rollupCache.devices) { $rollupCache.devices.PSObject.Properties[$ip] } else { $null }
            if ($cachedDev -and $cachedDev.Value) {
                $timeSeries = @($cachedDev.Value)
            }
        }

        $chartDataObj.devices += @{
            ip         = $ip
            name       = $dName
            group      = $dGroup
            color      = $color
            timeSeries = $timeSeries
            # グラフの横軸の位置。timeSeries と同じ順番で、同じ秒の点を重ならないように並べたもの
            timeX      = @(Get-ChartTimeAxis -Times @($timeSeries | ForEach-Object { [string]$_.t }))
        }

        $devCardsHtml += @"
<div class="device-card">
    <div class="device-card-header">
        <div>
            <span class="color-dot" style="background-color:$color;"></span>
            <strong>$([System.Web.HttpUtility]::HtmlEncode($dName))</strong> <span style="font-size:11px; color:#64748b;">($([System.Web.HttpUtility]::HtmlEncode($ip)))</span>
        </div>
        <span class="status-tag $($st.ToLower())">$st</span>
    </div>
    <div style="font-size:11px; color:#64748b; margin-bottom:8px;">
        到達率: <strong>$reachRate</strong> | 平均遅延: <strong>$avgLat</strong> | ジッター: <strong>$avgJit</strong> | 瞬断: <strong>$maxOutage</strong>
    </div>
    <div class="device-chart-box">
        <canvas id="device-chart-$devIdx"></canvas>
    </div>
</div>
"@
        $devIdx++
    }

    # 瞬断発生履歴明細
    $outageEventsAll = @()
    foreach ($ip in $devices) {
        $s = $sync.Stats[$ip]
        if ($null -ne $s -and $null -ne $s.OutageEvents -and $s.OutageEvents.Count -gt 0) {
            $dName = if ($sync.DeviceName.ContainsKey($ip)) { $sync.DeviceName[$ip] } else { $ip }
            foreach ($ev in $s.OutageEvents) {
                $outageEventsAll += @{
                    DeviceName = $dName
                    Ip = $ip
                    StartTime = $ev.StartTime
                    EndTime = $ev.EndTime
                    DurationMs = $ev.DurationMs
                    Category = $ev.Category
                }
            }
        }
    }

    $outageDetailsHtml = ""
    if ($outageEventsAll.Count -gt 0) {
        $outageRows = ""
        $evNo = 1
        foreach ($ev in ($outageEventsAll | Sort-Object StartTime -Descending)) {
            $outageRows += @"
<tr>
    <td style="text-align:center;">$evNo</td>
    <td><strong>$([System.Web.HttpUtility]::HtmlEncode($ev.DeviceName))</strong><br><small style="color:#64748b;">$([System.Web.HttpUtility]::HtmlEncode($ev.Ip))</small></td>
    <td>$($ev.StartTime)</td>
    <td>$($ev.EndTime)</td>
    <td style="text-align:right; font-weight:700; color:#dc2626;">$($ev.DurationMs) ms</td>
    <td style="text-align:center;"><span style="background:#fef2f2; color:#b91c1c; padding:2px 8px; border-radius:12px; font-weight:600; font-size:10px;">$($ev.Category)</span></td>
</tr>
"@
            $evNo++
        }
        $outageDetailsHtml = @"
        <div style="overflow-x:auto; margin-top:8px;">
            <table style="font-size:11px;">
                <thead>
                    <tr>
                        <th style="width:40px; text-align:center;">No</th>
                        <th>対象機器</th>
                        <th>瞬断開始日時</th>
                        <th>復旧完了日時</th>
                        <th style="text-align:right;">継続時間 (ms)</th>
                        <th style="text-align:center;">判定区分</th>
                    </tr>
                </thead>
                <tbody>
                    $outageRows
                </tbody>
            </table>
        </div>
"@
    } else {
        $outageDetailsHtml = @"
        <div style="padding:14px 18px; background:#f0fdf4; border:1px solid #bbf7d0; border-radius:8px; color:#15803d; font-size:11.5px; margin-top:8px;">
            ✔ 本計測期間中に規定閾値（$($sync.OutageThresh1Ms)ms以上）を超える瞬断・通信途絶は検知されませんでした（完全安定稼働）。
        </div>
"@
    }

    # Iperf3 ログ解析とグラフカード構築
    $iperfCardsHtml = @()
    $iperfResults = @()
    $iperfCardIdx = 0

    if ($sessionDir -and (Test-Path $sessionDir)) {
        $iperfFiles = Get-ChildItem -Path $sessionDir -Filter "iperf_*.log" -ErrorAction SilentlyContinue
        foreach ($ipfFile in $iperfFiles) {
            $targetIp = $ipfFile.BaseName -replace '^iperf_', ''
            $dName = if ($sync.DeviceName.ContainsKey($targetIp)) { $sync.DeviceName[$targetIp] } else { $targetIp }
            
            try {
                $rawLogContent = [System.IO.File]::ReadAllLines($ipfFile.FullName, [System.Text.Encoding]::UTF8)
                $logContent = Clean-IperfLogLines $rawLogContent
                if ($logContent.Count -gt 0) {
                    $bwPoints = @()
                    $jitPoints = @()
                    $isUdp = $false
                    $protoStr = "TCP"
                    
                    $summaryObj = @{
                        Target = "$dName ($targetIp)"
                        Protocol = "TCP"
                        Duration = "—"
                        Transfer = "—"
                        AvgBw = "—"
                        MaxBw = "—"
                        MinBw = "—"
                        Jitter = "—"
                        Loss = "—"
                        Retr = "—"
                        Evaluation = "—"
                    }

                    $execStartTime = $null
                    foreach ($l in $logContent) {
                        if ($l -match 'Execution at\s+([0-9\-:\s]+)') {
                            try { $execStartTime = [datetime]::ParseExact($Matches[1].Trim(), "yyyy-MM-dd HH:mm:ss", $null) } catch {}
                        }
                        if ($l -match 'Command:\s*iperf3\s+.*?-u' -or $l -match '通信プロトコル\s*:\s*UDP') { $isUdp = $true; $protoStr = "UDP" }

                        $lineTs = ""
                        if ($l -match '^\[([0-9]{2}:[0-9]{2}:[0-9]{2})\]') {
                            $lineTs = $Matches[1]
                        }
                        
                        # UDP line
                        if ($l -match '\[\s*\d+\]\s+([0-9.]+)-([0-9.]+)\s+sec\s+([0-9.]+)\s+([KMG]?)Bytes\s+([0-9.]+)\s+([KMG]?)bits/sec\s+([0-9.]+)\s+ms\s+(\d+)/(\d+)\s+\(([0-9.]+)%\)') {
                            $isUdp = $true; $protoStr = "UDP"
                            $sT = [double]$Matches[1]; $eT = [double]$Matches[2]
                            $bwR = [double]$Matches[5]; $bwU = $Matches[6]
                            $jM = [double]$Matches[7]
                            $bwM = switch ($bwU) { 'K' { $bwR / 1000.0 } 'G' { $bwR * 1000.0 } default { $bwR } }
                            $lbl = if ($lineTs) { $lineTs } elseif ($execStartTime) { $execStartTime.AddSeconds($eT).ToString("HH:mm:ss") } else { "${sT}-${eT}s" }
                            if ($l -notmatch 'sender|receiver|SUM' -and ($eT - $sT) -le 1.5) {
                                $bwPoints += @{ sec = $eT; val = [math]::Round($bwM, 2); label = $lbl }
                                $jitPoints += @{ sec = $eT; val = [math]::Round($jM, 3); label = $lbl }
                            }
                        }
                        # TCP line
                        elseif ($l -match '\[\s*\d+\]\s+([0-9.]+)-([0-9.]+)\s+sec\s+([0-9.]+)\s+([KMG]?)Bytes\s+([0-9.]+)\s+([KMG]?)bits/sec' -and $l -notmatch 'sender|receiver|SUM') {
                            $sT = [double]$Matches[1]; $eT = [double]$Matches[2]
                            $bwR = [double]$Matches[5]; $bwU = $Matches[6]
                            $bwM = switch ($bwU) { 'K' { $bwR / 1000.0 } 'G' { $bwR * 1000.0 } default { $bwR } }
                            $lbl = if ($lineTs) { $lineTs } elseif ($execStartTime) { $execStartTime.AddSeconds($eT).ToString("HH:mm:ss") } else { "${sT}-${eT}s" }
                            if (($eT - $sT) -le 1.5) {
                                $bwPoints += @{ sec = $eT; val = [math]::Round($bwM, 2); label = $lbl }
                            }
                        }

                        # Summary lines parser
                        if ($l -match '通信プロトコル\s*:\s*(.+)') { $summaryObj.Protocol = $Matches[1].Trim() }
                        if ($l -match '合計計測時間\s*:\s*(.+)') { $summaryObj.Duration = $Matches[1].Trim() }
                        if ($l -match '合計データ転送量\s*:\s*(.+)') { $summaryObj.Transfer = $Matches[1].Trim() }
                        if ($l -match '平均帯域.*:\s*(.+)') { $summaryObj.AvgBw = $Matches[1].Trim() }
                        if ($l -match '最大帯域\s*:\s*(.+)') { $summaryObj.MaxBw = $Matches[1].Trim() }
                        if ($l -match '最小帯域\s*:\s*(.+)') { $summaryObj.MinBw = $Matches[1].Trim() }
                        if ($l -match '平均ジッター.*:\s*(.+)') { $summaryObj.Jitter = $Matches[1].Trim() }
                        if ($l -match 'パケット損失率.*:\s*(.+)') { $summaryObj.Loss = $Matches[1].Trim() }
                        if ($l -match 'TCP再送パケット数\s*:\s*(.+)') { $summaryObj.Retr = $Matches[1].Trim() }
                        if ($l -match '品質評価.*:\s*(.+)') { $summaryObj.Evaluation = $Matches[1].Trim() }
                    }

                    if ($bwPoints.Count -gt 0) {
                        $iperfResults += @{
                            target     = $targetIp
                            name       = $dName
                            protocol   = $protoStr
                            isUdp      = $isUdp
                            bwPoints   = $bwPoints
                            jitPoints  = $jitPoints
                            summary    = $summaryObj
                        }

                        $protoBadge = if ($isUdp) { "background:#0284c7; color:#fff;" } else { "background:#3b82f6; color:#fff;" }
                        $cardHtml = @"
<div class="device-card" style="margin-bottom:16px;">
    <div class="device-card-header">
        <div>
            <span style="display:inline-block; padding:2px 6px; border-radius:4px; font-size:11px; font-weight:700; $protoBadge">$protoStr</span>
            <strong style="margin-left:6px;">$([System.Web.HttpUtility]::HtmlEncode($dName))</strong> <span style="font-size:12px; color:#64748b;">($([System.Web.HttpUtility]::HtmlEncode($targetIp)))</span>
        </div>
        <span style="font-size:12px; font-weight:600; color:#16a34a;">$([System.Web.HttpUtility]::HtmlEncode($summaryObj.Evaluation))</span>
    </div>
    <div style="padding:8px 12px; background:#f8fafc; border-bottom:1px solid #e2e8f0; font-size:12px; display:flex; flex-wrap:wrap; gap:16px;">
        <div>平均スループット: <strong>$($summaryObj.AvgBw)</strong></div>
        <div>計測時間: <strong>$($summaryObj.Duration)</strong></div>
        <div>転送量: <strong>$($summaryObj.Transfer)</strong></div>
        $(if ($isUdp) { "<div>ジッター: <strong>$($summaryObj.Jitter)</strong></div><div>損失率: <strong>$($summaryObj.Loss)</strong></div>" } else { "<div>再送: <strong>$($summaryObj.Retr)</strong></div>" })
    </div>
    <div class="device-chart-box" style="height:180px;">
        <canvas id="iperf-report-chart-$iperfCardIdx"></canvas>
    </div>
</div>
"@
                        $iperfCardsHtml += $cardHtml
                        $iperfCardIdx++
                    }
                }
            } catch { }
        }
    }

    $chartDataObj.iperfResults = $iperfResults

    # 全体統計
    $totalDevicesCount = $devIdx
    $overallReach = if ($allTotalPings -gt 0) { "$([math]::Round(($allTotalSuccess / $allTotalPings) * 100, 1))%" } else { "100.0%" }
    $overallAvgLat = if ($totalLatCount -gt 0) { "$([math]::Round($totalLatSum / $totalLatCount, 0)) ms" } else { "—" }
    $overallMaxOutageStr = if ($maxOverallOutage -gt 0) { "$([math]::Round($maxOverallOutage * 1000, 0)) ms" } else { "—" }

    $rowsHtml = if ($reportRows.Count -gt 0) { $reportRows -join "`r`n" } else { "<tr><td colspan='16' style='text-align:center; padding:20px; color:#94a3b8;'>計測データがありません</td></tr>" }
    $devCardsHtmlStr = if ($devCardsHtml.Count -gt 0) { $devCardsHtml -join "`r`n" } else { "<div style='color:#94a3b8; font-size:12px; padding:10px;'>有効なグラフデータがありません</div>" }
    $iperfSectionHtml = if ($iperfCardsHtml.Count -gt 0) { $iperfCardsHtml -join "`r`n" } else { "<div style='color:#94a3b8; font-size:12px; padding:10px; background:#f8fafc; border:1px dashed #cbd5e1; border-radius:8px;'>本計測期間中の Iperf3 帯域計測ログはありません。</div>" }

    $chartDataJson = $chartDataObj | ConvertTo-Json -Depth 6 -Compress

    $chartScriptTag = if ($chartJsInline) {
        "<script>`n" + $chartJsInline + "`n</script>"
    } else {
        "<script src='https://cdn.jsdelivr.net/npm/chart.js@4.5.1/dist/chart.umd.min.js'></script>"
    }

    $reportHtmlPart1 = @"
<!DOCTYPE html>
<html lang="ja">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ネットワーク機器 定期点検・折れ線グラフ報告書 ($tsNow)</title>
"@
    $reportHtmlPart1 += $chartScriptTag
    $reportHtmlPart2 = @"
    <style>
        @page { size: A4 landscape; margin: 10mm; }
        * { box-sizing: border-box; }
        body { font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, 'Yu Gothic UI', Meiryo, sans-serif; color: #1e293b; background: #f8fafc; margin: 0; padding: 20px; line-height: 1.5; font-size: 12px; }
        .container { max-width: 1280px; margin: 0 auto; background: #fff; border: 1px solid #e2e8f0; border-radius: 12px; padding: 28px; box-shadow: 0 4px 12px rgba(0,0,0,0.03); }
        .report-header { display: flex; justify-content: space-between; align-items: flex-end; border-bottom: 3px solid #3b82f6; padding-bottom: 12px; margin-bottom: 20px; }
        .report-title { font-size: 20px; font-weight: 800; color: #0f172a; margin: 0; display: flex; align-items: center; gap: 8px; }
        .report-meta { text-align: right; font-size: 11px; color: #64748b; }
        .summary-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; margin-bottom: 24px; }
        .summary-box { background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 10px; padding: 12px; text-align: center; }
        .summary-box .val { font-size: 22px; font-weight: 800; color: #2563eb; }
        .summary-box .label { font-size: 11px; color: #64748b; margin-top: 2px; font-weight: 600; }
        .section-title { font-size: 14px; font-weight: 700; margin: 24px 0 10px 0; border-left: 4px solid #3b82f6; padding-left: 8px; color: #0f172a; display: flex; align-items: center; gap: 6px; }
        table { width: 100%; border-collapse: collapse; margin-top: 6px; font-size: 11px; }
        th, td { border: 1px solid #e2e8f0; padding: 6px 8px; text-align: left; }
        th { background: #f1f5f9; color: #334155; font-weight: 700; font-size: 10.5px; white-space: nowrap; }
        tr:nth-child(even) { background: #f8fafc; }
        .color-dot { display: inline-block; width: 9px; height: 9px; border-radius: 50%; margin-right: 5px; vertical-align: middle; }
        .status-tag { display: inline-block; padding: 2px 6px; border-radius: 10px; font-size: 10px; font-weight: 700; text-transform: uppercase; }
        .status-tag.success { background: #dcfce7; color: #15803d; }
        .status-tag.warning { background: #fef3c7; color: #d97706; }
        .status-tag.failed { background: #fee2e2; color: #b91c1c; }
        .status-tag.unknown { background: #f1f5f9; color: #64748b; }
        .chart-card { background: #fff; border: 1px solid #e2e8f0; border-radius: 10px; padding: 16px; margin-bottom: 18px; box-shadow: 0 1px 3px rgba(0,0,0,0.02); }
        .chart-card-title { font-size: 12px; font-weight: 700; color: #334155; margin-bottom: 10px; }
        .chart-box { position: relative; height: 260px; min-height: 260px; width: 100%; }
        .device-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 14px; margin-top: 10px; }
        .device-card { background: #fff; border: 1px solid #e2e8f0; border-radius: 8px; padding: 12px; }
        .device-card-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px; }
        .device-chart-box { position: relative; height: 160px; min-height: 160px; width: 100%; }
        .print-bar { position: fixed; top: 15px; right: 15px; background: rgba(15, 23, 42, 0.95); backdrop-filter: blur(8px); color: #fff; padding: 10px 18px; border-radius: 40px; box-shadow: 0 8px 24px rgba(0,0,0,0.25); display: flex; gap: 14px; align-items: center; z-index: 9999; border: 1px solid rgba(255,255,255,0.1); }
        .print-btn { background: linear-gradient(135deg, #2563eb, #1d4ed8); color: #fff; border: none; padding: 8px 18px; border-radius: 20px; cursor: pointer; font-weight: 700; font-size: 12px; display: flex; align-items: center; gap: 6px; box-shadow: 0 2px 8px rgba(37,99,235,0.4); transition: transform 0.15s, background 0.15s; }
        .print-btn:hover { transform: translateY(-1px); background: linear-gradient(135deg, #1d4ed8, #1e40af); }
        .print-btn:active { transform: translateY(1px); }
        @media print {
            .print-bar { display: none !important; }
            body { background: #fff; padding: 0; font-size: 10px; }
            .container { border: none; box-shadow: none; padding: 0; max-width: 100%; margin: 0; }
            .chart-card, .device-card, .summary-box { break-inside: avoid; page-break-inside: avoid; }
            table { break-inside: auto; }
            tr { break-inside: avoid; page-break-inside: avoid; }
            .section-title { break-after: avoid; page-break-after: avoid; }
        }
    </style>
</head>
<body>
    <div class="print-bar">
        <div style="display:flex; align-items:center; gap:8px;">
            <span style="font-size:16px;">📄</span>
            <div>
                <strong style="font-size:12px; display:block;">定期点検報告書</strong>
                <span style="font-size:10px; color:#94a3b8;">A4横向き・カラー印刷</span>
            </div>
        </div>
        <button class="print-btn" onclick="window.print()" title="クリックしてA4横向きPDFに保存、またはプリンターで印刷">
            🖨️ A4横向きで印刷 / PDF保存
        </button>
    </div>

    <div class="container">
        <div class="report-header">
            <div>
                <div class="report-title">📊 ネットワーク機器 稼働状況・定期点検報告書</div>
                <div style="font-size:11px; color:#64748b; margin-top:4px;">対象期間: $([System.Web.HttpUtility]::HtmlEncode($period)) | 作成日時: $tsNow</div>
            </div>
            <div class="report-meta">
                システム名: <strong>Network Device Monitor</strong><br>
                総合可用性 (到達率): <strong style="color:#16a34a; font-size:13px;">$overallReach</strong>
            </div>
        </div>

        <div class="summary-grid">
            <div class="summary-box">
                <div class="val">$totalDevicesCount</div>
                <div class="label">計測対象機器数</div>
            </div>
            <div class="summary-box">
                <div class="val" style="color:#16a34a;">$overallReach</div>
                <div class="label">全体到達率 (稼働率)</div>
            </div>
            <div class="summary-box">
                <div class="val" style="color:#0284c7;">$overallAvgLat</div>
                <div class="label">全体平均遅延</div>
            </div>
            <div class="summary-box">
                <div class="val" style="color:#f59e0b;">$overallMaxOutageStr</div>
                <div class="label">最大瞬断時間</div>
            </div>
        </div>

        <div class="section-title">1. 機器別 稼働・遅延・統計サマリー一覧</div>
        <div style="overflow-x:auto;">
            <table>
                <thead>
                    <tr>
                        <th>機器名 / IPアドレス</th>
                        <th>グループ</th>
                        <th>状態</th>
                        <th>監視頻度</th>
                        <th>総Ping数</th>
                        <th>成功数</th>
                        <th>失敗数</th>
                        <th>到達率 (%)</th>
                        <th>パケット損失率 (%)</th>
                        <th>平均ジッター</th>
                        <th>最小遅延</th>
                        <th>最大遅延</th>
                        <th>平均遅延</th>
                        <th>最大瞬断時間</th>
                        <th>600ms以上瞬断</th>
                        <th>5s以上瞬断</th>
                    </tr>
                </thead>
                <tbody>
                    $rowsHtml
                </tbody>
            </table>
        </div>
        <div style="font-size:10.5px; color:#64748b; margin-top:6px;">
            ※ 瞬断回数は、通信断から復帰した時点でカウントされます（計測終了時点で継続中の瞬断は含みません）。
        </div>

        <div class="section-title">2. 瞬断・通信切断 発生履歴明細（発生日時・復旧完了日時・継続時間一覧）</div>
        $outageDetailsHtml

        <div class="section-title" style="margin-top:24px;">3. 全機器 応答遅延（Latency）推移グラフ (ms)</div>
        <div class="chart-card">
            <div class="chart-card-title">📈 時系列 応答遅延推移 (凡例クリックで各機器の表示/非表示を切り替え可能)</div>
            <div class="chart-box">
                <canvas id="unified-latency-chart"></canvas>
            </div>
        </div>

        <div class="section-title">4. 全機器 ジッター（揺らぎ）推移グラフ (ms)</div>
        <div class="chart-card">
            <div class="chart-card-title">〰️ 時系列 ジッター推移 (通信のブレ・安定度)</div>
            <div class="chart-box">
                <canvas id="unified-jitter-chart"></canvas>
            </div>
        </div>

        <div class="section-title">5. 機器別 詳細推移グラフ (遅延 & 送受信帯域)</div>
        <div class="device-grid">
            $devCardsHtmlStr
        </div>

        <div class="section-title" style="margin-top:24px;">6. Iperf3 帯域計測・スループット診断結果 (グラフ & サマリー一覧)</div>
        <div class="device-grid" style="grid-template-columns: 1fr;">
            $iperfSectionHtml
        </div>

        <div style="margin-top:30px; border-top:1px solid #e2e8f0; padding-top:12px; font-size:10.5px; color:#94a3b8; text-align:center;">
            Generated by Network Device Monitor — $tsNow
        </div>
    </div>

    <script id="report-data" type="application/json">
$chartDataJson
    </script>
    <script>
    function initReportCharts() {
        var rawEl = document.getElementById('report-data');
        if (!rawEl) return;
        var reportData = {};
        try {
            reportData = JSON.parse(rawEl.textContent || '{}');
        } catch(e) {
            console.error('Failed to parse report-data JSON:', e);
            return;
        }
        var devices = reportData.devices || [];
        if (typeof Chart === 'undefined') {
            console.error('Chart.js is not loaded.');
            return;
        }

        // 1. 時刻の軸の準備
        // 横軸は文字の時刻ではなく数値 (0 時からの秒数。サーバー側の Get-ChartTimeAxis が作る timeX) を使う。
        // 文字の時刻だと同じ秒の点が同じ位置に重なり、測定の間隔が違う機器の点の位置もずれるため。
        var firstValues = devices.map(function(d) {
            return (d.timeX || []).filter(function(x) { return x !== null; })[0];
        }).filter(function(x) { return x !== undefined; });
        var latestFirst = firstValues.length ? Math.max.apply(null, firstValues) : 0;
        devices.forEach(function(d) {
            // 記録の開始の直前に日付が変わった機器も、ほかの機器と同じ日の位置にそろえる
            var first = (d.timeX || []).filter(function(x) { return x !== null; })[0];
            d.dayOffset = (first !== undefined && latestFirst - first > 43200) ? 86400 : 0;
        });

        // 機器の記録から、グラフの点 ({ x: 横軸の位置, y: 値 }) を作る。時刻が読めなかった点は除く
        function getPlotPoints(d, key) {
            var points = [];
            (d.timeSeries || []).forEach(function(p, i) {
                var x = (d.timeX || [])[i];
                if (x !== null && x !== undefined) { points.push({ x: x + d.dayOffset, y: p[key] }); }
            });
            return points;
        }

        // 0 時からの秒数を HH:mm:ss の文字に戻す (日付をまたいだ分は取り除く)
        function formatClock(value) {
            var total = Math.floor(value) % 86400;
            var pad = function(n) { return (n < 10 ? '0' : '') + n; };
            return pad(Math.floor(total / 3600)) + ':' + pad(Math.floor(total / 60) % 60) + ':' + pad(total % 60);
        }

        // 時刻の横軸の共通設定。precision: 0 は目盛りを整数の秒にして、同じ時刻の文字が並ばないようにする指定
        function createTimeAxis(minValue, maxValue, maxTicks, fontSize, gridColor) {
            return {
                type: 'linear',
                min: minValue,
                max: maxValue,
                grid: { color: gridColor },
                ticks: {
                    maxTicksLimit: maxTicks,
                    precision: 0,
                    maxRotation: 0,
                    minRotation: 0,
                    font: { size: fontSize },
                    callback: function(value) { return formatClock(value); }
                },
                title: { display: true, text: '時刻 (HH:mm:ss)', font: { size: fontSize } }
            };
        }

        // 全機器のグラフの案内用。機器ごとに、マウスの位置に一番近い点を 1 つ選ぶ。
        // 標準の index は「同じ番号の点」を選ぶので、測定の間隔が違う機器では別の時刻の値が出てしまう
        Chart.Interaction.modes.eachNearestX = function(chart, e) {
            var items = [];
            chart.getSortedVisibleDatasetMetas().forEach(function(meta) {
                var best = null;
                meta.data.forEach(function(element, index) {
                    if (element.skip) { return; }
                    var distance = Math.abs(element.x - e.x);
                    if (best === null || distance < best.distance) {
                        best = { element: element, datasetIndex: meta.index, index: index, distance: distance };
                    }
                });
                if (best) { items.push(best); }
            });
            return items;
        };

        var allPoints = [];
        devices.forEach(function(d) { allPoints = allPoints.concat(getPlotPoints(d, 'lat')); });
        var allX = allPoints.map(function(p) { return p.x; });
        var minX = allX.length ? Math.min.apply(null, allX) : undefined;
        var maxX = allX.length ? Math.max.apply(null, allX) : undefined;

        // 2. 応答遅延 (Latency) 統合グラフ
        var latencyDatasets = devices.map(function(d) {
            var devLabel = (d.name || d.ip) + ' (' + d.ip + ')';
            return {
                label: devLabel,
                data: getPlotPoints(d, 'lat'),
                borderColor: d.color,
                backgroundColor: 'transparent',
                borderWidth: 1.8,
                pointRadius: 0,
                pointHoverRadius: 4,
                tension: 0,
                fill: false,
                spanGaps: true
            };
        });

        var latCtx = document.getElementById('unified-latency-chart');
        if (latCtx) {
            new Chart(latCtx, {
                type: 'line',
                data: { datasets: latencyDatasets },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    interaction: { mode: 'eachNearestX', intersect: false },
                    plugins: {
                        legend: { position: 'top', labels: { boxWidth: 12, font: { size: 11 } } },
                        tooltip: {
                            callbacks: {
                                title: function(items) { return items.length ? formatClock(items[0].parsed.x) : ''; },
                                label: function(ctx) {
                                    return ' ' + ctx.dataset.label + ': ' + (ctx.parsed.y != null ? ctx.parsed.y + ' ms' : '応答なし');
                                }
                            }
                        }
                    },
                    scales: {
                        x: createTimeAxis(minX, maxX, 12, 10, '#f1f5f9'),
                        y: {
                            beginAtZero: true,
                            grid: { color: '#f1f5f9' },
                            title: { display: true, text: '遅延 (ms)', font: { size: 10 } }
                        }
                    }
                }
            });
        }

        // 3. ジッター (Jitter) 統合グラフ
        var jitterDatasets = devices.map(function(d) {
            var devLabel = (d.name || d.ip) + ' (' + d.ip + ')';
            return {
                label: devLabel,
                data: getPlotPoints(d, 'jit'),
                borderColor: d.color,
                borderWidth: 1.5,
                pointRadius: 0,
                pointHoverRadius: 4,
                tension: 0,
                fill: false,
                spanGaps: true
            };
        });

        var jitCtx = document.getElementById('unified-jitter-chart');
        if (jitCtx) {
            new Chart(jitCtx, {
                type: 'line',
                data: { datasets: jitterDatasets },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    interaction: { mode: 'eachNearestX', intersect: false },
                    plugins: {
                        legend: { position: 'top', labels: { boxWidth: 12, font: { size: 11 } } },
                        tooltip: {
                            callbacks: {
                                title: function(items) { return items.length ? formatClock(items[0].parsed.x) : ''; },
                                label: function(ctx) {
                                    return ' ' + ctx.dataset.label + ': ' + (ctx.parsed.y != null ? ctx.parsed.y + ' ms' : '-');
                                }
                            }
                        }
                    },
                    scales: {
                        x: createTimeAxis(minX, maxX, 12, 10, '#f1f5f9'),
                        y: {
                            beginAtZero: true,
                            grid: { color: '#f1f5f9' },
                            title: { display: true, text: 'ジッター (ms)', font: { size: 10 } }
                        }
                    }
                }
            });
        }

        // 4. 機器別 詳細推移グラフ
        devices.forEach(function(d, idx) {
            var canvasEl = document.getElementById('device-chart-' + idx);
            if (!canvasEl || !d.timeSeries || d.timeSeries.length === 0) return;

            var latData = getPlotPoints(d, 'lat');
            var txData = getPlotPoints(d, 'tx');
            var rxData = getPlotPoints(d, 'rx');
            var hasTraffic = (d.timeSeries || []).some(function(p) { return (p.tx != null && p.tx > 0) || (p.rx != null && p.rx > 0); });

            var datasets = [
                {
                    label: '応答遅延 (ms)',
                    data: latData,
                    borderColor: '#3b82f6',
                    backgroundColor: 'rgba(59, 130, 246, 0.08)',
                    borderWidth: 1.5,
                    pointRadius: 0,
                    tension: 0,
                    spanGaps: true,
                    yAxisID: 'y'
                }
            ];

            if (hasTraffic) {
                datasets.push({
                    label: '送信 Tx (Mbps)',
                    data: txData,
                    borderColor: '#10b981',
                    borderWidth: 1.2,
                    pointRadius: 0,
                    tension: 0,
                    borderDash: [3, 3],
                    spanGaps: true,
                    yAxisID: 'yTraffic'
                });
                datasets.push({
                    label: '受信 Rx (Mbps)',
                    data: rxData,
                    borderColor: '#f59e0b',
                    borderWidth: 1.2,
                    pointRadius: 0,
                    tension: 0,
                    borderDash: [3, 3],
                    spanGaps: true,
                    yAxisID: 'yTraffic'
                });
            }

            var scales = {
                x: createTimeAxis(latData.length ? latData[0].x : undefined, latData.length ? latData[latData.length - 1].x : undefined, 8, 9, '#f8fafc'),
                y: {
                    beginAtZero: true,
                    grid: { color: '#f1f5f9' },
                    title: { display: true, text: '遅延 (ms)', font: { size: 10 } }
                }
            };
            if (hasTraffic) {
                scales.yTraffic = {
                    position: 'right',
                    beginAtZero: true,
                    grid: { drawOnChartArea: false },
                    title: { display: true, text: '帯域 (Mbps)', font: { size: 10 } }
                };
            }

            new Chart(canvasEl, {
                type: 'line',
                data: { datasets: datasets },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    interaction: { mode: 'index', intersect: false },
                    plugins: {
                        legend: { position: 'top', labels: { boxWidth: 10, font: { size: 10 } } },
                        tooltip: {
                            callbacks: {
                                title: function(items) { return items.length ? formatClock(items[0].parsed.x) : ''; }
                            }
                        }
                    },
                    scales: scales
                }
            });
        });

        // 5. Iperf3 Result Charts
        var iperfResults = reportData.iperfResults || [];
        iperfResults.forEach(function(ipf, idx) {
            var canvasEl = document.getElementById('iperf-report-chart-' + idx);
            if (!canvasEl || !ipf.bwPoints || ipf.bwPoints.length === 0) return;

            var labels = ipf.bwPoints.map(function(p) { return p.label; });
            var bwData = ipf.bwPoints.map(function(p) { return { x: p.label, y: p.val }; });

            var datasets = [
                {
                    label: 'スループット (Mbps)',
                    data: bwData,
                    borderColor: '#3b82f6',
                    backgroundColor: 'rgba(59, 130, 246, 0.1)',
                    borderWidth: 2,
                    pointRadius: 3,
                    pointBackgroundColor: '#60a5fa',
                    tension: 0.3,
                    fill: true,
                    yAxisID: 'y'
                }
            ];

            if (ipf.isUdp && ipf.jitPoints && ipf.jitPoints.length > 0) {
                var jitData = ipf.jitPoints.map(function(p) { return { x: p.label, y: p.val }; });
                datasets.push({
                    label: 'ジッター (ms)',
                    data: jitData,
                    borderColor: '#f59e0b',
                    borderWidth: 1.5,
                    borderDash: [4, 4],
                    pointRadius: 2,
                    tension: 0.2,
                    fill: false,
                    yAxisID: 'yJitter'
                });
            }

            var scales = {
                x: {
                    grid: { color: '#f8fafc' },
                    ticks: { maxTicksLimit: 12, autoSkip: true, maxRotation: 0, minRotation: 0, font: { size: 9 } },
                    title: { display: true, text: '時刻 (HH:mm:ss)', font: { size: 9 } }
                },
                y: {
                    beginAtZero: true,
                    grid: { color: '#f1f5f9' },
                    title: { display: true, text: '帯域 (Mbps)', font: { size: 10 } }
                }
            };

            if (ipf.isUdp && ipf.jitPoints && ipf.jitPoints.length > 0) {
                scales.yJitter = {
                    position: 'right',
                    beginAtZero: true,
                    grid: { drawOnChartArea: false },
                    title: { display: true, text: 'ジッター (ms)', font: { size: 10 } }
                };
            }

            new Chart(canvasEl, {
                type: 'line',
                data: { labels: labels, datasets: datasets },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    interaction: { mode: 'index', intersect: false },
                    plugins: {
                        legend: { position: 'top', labels: { boxWidth: 10, font: { size: 10 } } }
                    },
                    scales: scales
                }
            });
        });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initReportCharts);
    } else {
        initReportCharts();
    }
    </script>
</body>
</html>
"@
    $reportHtml = $reportHtmlPart1 + $reportHtmlPart2

    if ($savePath) {
        try {
            $dir = Split-Path -Parent $savePath
            if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [System.IO.File]::WriteAllText($savePath, $reportHtml, [System.Text.Encoding]::UTF8)
        } catch { }
    }

    return $reportHtml
}

# ── 5. CSVファイルへの安全なエクスポート ─────────────────────────────────────

function Safe-ExportCsv {
    <#
    .SYNOPSIS
        CSVファイルへの安全なエクスポート（名前付きMutex同期・リトライ・新規作成/追記両対応・文字コード指定）
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0, Mandatory = $false, ValueFromPipeline = $true)]
        [Alias("records", "InputObject")]
        $Data,

        [Parameter(Position = 1, Mandatory = $false)]
        [Alias("filePath")]
        [string]$Path,

        [Parameter()]
        [switch]$Append,

        [Parameter()]
        [string]$Encoding = "shift_jis",

        [Parameter()]
        [int]$MaxRetries = 5,

        [Parameter()]
        [int]$RetryIntervalMs = 100,

        [Parameter()]
        [int]$MutexTimeoutMs = 5000,

        [Parameter()]
        [string]$MutexName
    )

    begin {
        $pipelineData = [System.Collections.ArrayList]::new()
    }
    process {
        if ($null -ne $_) {
            $null = $pipelineData.Add($_)
        }
    }
    end {
        if ($pipelineData.Count -gt 0) {
            $Data = $pipelineData
        }

        # 引数の順序・型への柔軟対応: Safe-ExportCsv $Path $Data の逆順指定も自動検出
        if ($Data -is [string] -and [string]::IsNullOrWhiteSpace($Path)) {
            $Path = $Data
            $Data = $null
        }

        if ([string]::IsNullOrWhiteSpace($Path) -or $null -eq $Data) {
            return $false
        }

        # 親ディレクトリの存在保証
        try {
            $dir = Split-Path -Parent $Path
            if ($dir -and -not (Test-Path $dir)) {
                New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
            }
        } catch {}

        # 文字エンコーディングの解決
        $enc = switch -Regex ($Encoding.ToLowerInvariant()) {
            '^(shift_jis|sjis|cp932|932)$' { [System.Text.Encoding]::GetEncoding(932) }
            '^(utf-?8-?nobom|utf8)$'         { New-Object System.Text.UTF8Encoding($false) }
            '^utf-?8-?bom$'                 { New-Object System.Text.UTF8Encoding($true) }
            '^(utf-?16|unicode)$'           { [System.Text.Encoding]::Unicode }
            '^ascii$'                       { [System.Text.Encoding]::ASCII }
            default {
                try { [System.Text.Encoding]::GetEncoding($Encoding) } catch { [System.Text.Encoding]::GetEncoding(932) }
            }
        }

        # CSV文字列化 (ConvertTo-Csv)
        $csvLines = @($Data | ConvertTo-Csv -NoTypeInformation)
        if ($csvLines.Count -eq 0) { return $false }

        $fileExistsAndHasContent = (Test-Path $Path) -and ((Get-Item $Path).Length -gt 0)

        $csvText = if ($Append -and $fileExistsAndHasContent) {
            # 追記モードで既存ファイルが存在する場合、ヘッダー行（1行目）を抑止
            ($csvLines | Select-Object -Skip 1) -join [System.Environment]::NewLine
        } else {
            $csvLines -join [System.Environment]::NewLine
        }

        if ([string]::IsNullOrEmpty($csvText)) { return $true }
        if (-not $csvText.EndsWith([System.Environment]::NewLine)) {
            $csvText += [System.Environment]::NewLine
        }

        # 名前付き Mutex によるプロセス間・スレッド間排他制御
        $cleanPath = try { [System.IO.Path]::GetFullPath($Path).ToLowerInvariant() } catch { $Path.ToLowerInvariant() }
        $hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($cleanPath))
        $hashStr = ([System.BitConverter]::ToString($hashBytes) -replace '-').Substring(0, 16)
        $mName = if ($MutexName) { $MutexName } else { "Local\NDM_CSV_" + $hashStr }

        $mutex = $null
        $hasMutex = $false
        try {
            $mutex = New-Object System.Threading.Mutex($false, $mName)
            try {
                $hasMutex = $mutex.WaitOne($MutexTimeoutMs)
            } catch [System.Threading.AbandonedMutexException] {
                $hasMutex = $true
            }
        } catch {
            $hasMutex = $false
        }

        try {
            $retry = 0
            while ($retry -lt $MaxRetries) {
                try {
                    if ($Append -and $fileExistsAndHasContent) {
                        [System.IO.File]::AppendAllText($Path, $csvText, $enc)
                    } else {
                        [System.IO.File]::WriteAllText($Path, $csvText, $enc)
                    }
                    return $true
                } catch {
                    $retry++
                    Start-Sleep -Milliseconds ($RetryIntervalMs * $retry)
                }
            }
            Write-Warning "Safe-ExportCsv failed to write to $Path after $MaxRetries retries."
            return $false
        } finally {
            if ($hasMutex -and $null -ne $mutex) {
                try { $mutex.ReleaseMutex() } catch {}
            }
            if ($null -ne $mutex) {
                try { $mutex.Dispose() } catch {}
            }
        }
    }
}

Export-ModuleMember -Function Clean-IperfLogLines, Purge-OldReports, Invoke-PurgeOldReports, Get-ChartTimeAxis, Update-RollupCache, Generate-SessionReportHtml, Safe-ExportCsv
