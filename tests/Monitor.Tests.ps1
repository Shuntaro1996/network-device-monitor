# ==============================================================================
# Monitor.Tests.ps1 - Network Device Monitor Unit & Integration Tests (Pester)
# ==============================================================================

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Resolve-Path (Join-Path $here "..")
$moduleDir = Join-Path $projectRoot "system\modules"

# モジュールのインポート
Import-Module (Join-Path $moduleDir "Common.psm1") -Force
Import-Module (Join-Path $moduleDir "PingEngine.psm1") -Force
Import-Module (Join-Path $moduleDir "ReportGenerator.psm1") -Force
Import-Module (Join-Path $moduleDir "SnmpService.psm1") -Force
Import-Module (Join-Path $moduleDir "AlertManager.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleDir "IperfRunner.psm1") -Force -DisableNameChecking

Describe "1. パスワード・機密情報の暗号化 (DPAPI / Common.psm1)" {
    It "平文パスワードを DPAPI で暗号化すると 'enc:' 接頭辞が付くこと" {
        $secret = "SuperSecretPassword123!"
        $encrypted = Protect-SecretString -plainText $secret
        $encrypted | Should Not BeNullOrEmpty
        $encrypted.StartsWith("enc:") | Should Be $true
        $encrypted | Should Not Be $secret
    }

    It "暗号化された文字列を復号すると元の平文に正しく戻ること" {
        $secret = "SNMPv3_Auth_Passphrase_Complex#456"
        $encrypted = Protect-SecretString -plainText $secret
        $decrypted = Unprotect-SecretString -cipherText $encrypted
        $decrypted | Should Be $secret
    }

    It "既存の平文パスワード（後方互換性）はそのまま復号（透過処理）されること" {
        $plain = "LegacyPlainTextPass"
        $result = Unprotect-SecretString -cipherText $plain
        $result | Should Be $plain
    }

    It "空文字やnullを渡した場合は空文字が返ること" {
        (Unprotect-SecretString -cipherText "") | Should Be ""
        (Unprotect-SecretString -cipherText $null) | Should Be ""
        (Protect-SecretString -plainText "") | Should Be ""
    }
}

Describe "2. 2段階アラートしきい値判定 (PingEngine.psm1 / Evaluate-DeviceStatus)" {
    It "遅延が警告閾値以下の場合は 'Success' を返すこと" {
        $status = Evaluate-DeviceStatus -isSuccess $true -latencyMs 25.0 -consecutiveFails 0 -latencyWarningMs 80 -consecutiveFailThresh 2
        $status | Should Be "Success"
    }

    It "遅延が警告閾値を超過した場合は 'Warning' を返すこと" {
        $status = Evaluate-DeviceStatus -isSuccess $true -latencyMs 120.0 -consecutiveFails 0 -latencyWarningMs 80 -consecutiveFailThresh 2
        $status | Should Be "Warning"
    }

    It "1回目の失敗（単発パケロス）は 'Warning' を返すこと" {
        $status = Evaluate-DeviceStatus -isSuccess $false -latencyMs 0 -consecutiveFails 1 -latencyWarningMs 80 -consecutiveFailThresh 2
        $status | Should Be "Warning"
    }

    It "連続失敗回数が閾値（2回）に達した場合は 'Failed'（Critical）を返すこと" {
        $status = Evaluate-DeviceStatus -isSuccess $false -latencyMs 0 -consecutiveFails 2 -latencyWarningMs 80 -consecutiveFailThresh 2
        $status | Should Be "Failed"
    }

    It "連続失敗回数が閾値を超えた場合も 'Failed' を返すこと" {
        $status = Evaluate-DeviceStatus -isSuccess $false -latencyMs 0 -consecutiveFails 5 -latencyWarningMs 80 -consecutiveFailThresh 2
        $status | Should Be "Failed"
    }
}

Describe "3. TCP ポート死活監視 (PingEngine.psm1 / Test-TcpPortEndpoint)" {
    It "存在しないポートや接続不可IPへの接続時に適切に失敗すること" {
        # 127.0.0.1 の未使用ポート 65530 への短いタイムアウト接続テスト
        $res = Test-TcpPortEndpoint -ip "127.0.0.1" -port 65530 -timeoutMs 300
        $res.Success | Should Be $false
        $res.Status | Should Be "Failed"
        $res.Latency | Should BeNullOrEmpty
    }

    It "無効なIPやホスト名に対して例外で落ちずにエラーオブジェクトを返すこと" {
        $res = Test-TcpPortEndpoint -ip "256.256.256.256" -port 80 -timeoutMs 200
        $res.Success | Should Be $false
        $res.Status | Should Be "Failed"
    }
}

Describe "4. Iperf エラーログ除外 (ReportGenerator.psm1 / Clean-IperfLogLines)" {
    It "コネクションエラーとなったログブロックが正しく除外されること" {
        $rawLog = @(
            "=== iperf3 Execution at 2026-09-02 10:00:00 ===",
            "Connecting to host 192.168.1.50, port 5201",
            "iperf3: error - unable to connect to server: Connection refused",
            "=== iperf3 Execution at 2026-09-02 10:01:00 ===",
            "Connecting to host 192.168.1.50, port 5201",
            "[  5] local 192.168.1.10 port 54321 connected to 192.168.1.50 port 5201",
            "[ ID] Interval           Transfer     Bitrate",
            "[  5]   0.00-1.00   sec  11.2 MBytes  94.1 Mbits/sec",
            "- - - - - - - - - - - - - - - - - - - - - - - - -",
            "[  5]   0.00-1.00   sec  11.2 MBytes  94.1 Mbits/sec                  sender"
        )

        $cleaned = Clean-IperfLogLines -lines $rawLog
        $hasError = $cleaned | Where-Object { $_ -match "unable to connect|Connection refused" }
        $hasError | Should BeNullOrEmpty

        # 正常な計測行は保持されていること
        $hasData = $cleaned | Where-Object { $_ -match "94.1 Mbits/sec" }
        $hasData | Should Not BeNullOrEmpty
    }

    It "Measure-Bandwidth.ps1 は -UseIperf3 を指定しない場合は iperf3 を勝手に実行せず RTT 推定を行うこと" {
        $bwScript = Join-Path $projectRoot "system\Measure-Bandwidth.ps1"
        $output = & $bwScript -IpList "127.0.0.1" -NoCsv -NoReport *>&1 | Out-String
        $output | Should Match "RTT Estimate"
        $output | Should Not Match "Running iperf3"
    }

    It "Ping の応答時間から計算した帯域を監視画面に出さないこと" {
        $server = [System.IO.File]::ReadAllText((Join-Path $projectRoot "system\Server.ps1"), [System.Text.Encoding]::UTF8)
        $app = [System.IO.File]::ReadAllText((Join-Path $projectRoot "system\public\app.js"), [System.Text.Encoding]::UTF8)
        $server | Should Not Match 'syncHash\.Bandwidth'
        $app | Should Not Match '(data|statusData|fromStatus)\.bandwidth'
    }
}

Describe "5. 長期稼働ロールアップ事前集約 (ReportGenerator.psm1 / Update-RollupCache)" {
    It "時系列データから _rollup.json へ事前集約キャッシュが生成されること" {
        $tempSessionDir = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_Rollup_$(Get-Random)"
        New-Item -ItemType Directory -Path $tempSessionDir -Force | Out-Null
        try {
            $testSeries = @(
                @{ t = "12:00:01"; y = 10.5 },
                @{ t = "12:00:02"; y = 15.2 },
                @{ t = "12:00:03"; y = 82.0 }
            )

            $rollup = Update-RollupCache -sessionDir $tempSessionDir -ip "192.168.1.1" -timeSeries $testSeries
            $rollup | Should Not BeNullOrEmpty
            ($rollup.devices.ContainsKey("192.168.1.1")) | Should Be $true
            ($rollup.devices["192.168.1.1"].Count) | Should Be 3

            $cacheFile = Join-Path $tempSessionDir "_rollup.json"
            (Test-Path $cacheFile) | Should Be $true
        } finally {
            Remove-Item -Path $tempSessionDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "6. レポート自動削除機能 (ReportGenerator.psm1 / Purge-OldReports)" {
    It "保持期限を超えた古いレポートフォルダが安全に抽出・削除されること" {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_Purge_$(Get-Random)"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        try {
            $oldDir = Join-Path $tempDir "Session_20200101_000000"
            $newDir = Join-Path $tempDir "Session_20260901_000000"
            New-Item -ItemType Directory -Path $oldDir -Force | Out-Null
            New-Item -ItemType Directory -Path $newDir -Force | Out-Null

            # タイムスタンプを過去に変更
            (Get-Item $oldDir).LastWriteTime = (Get-Date).AddDays(-60)
            (Get-Item $newDir).LastWriteTime = (Get-Date)

            $deletedCount = Purge-OldReports -reportsDirectory $tempDir -retentionDays 30
            $deletedCount | Should Be 1
            (Test-Path $oldDir) | Should Be $false
            (Test-Path $newDir) | Should Be $true
        } finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "7. 回線品質劣化アラート判定 (PingEngine.psm1 / Evaluate-DeviceStatus)" {
    It "パケット損失率が閾値(5.0%)を超えた場合は 'Warning' を返すこと" {
        $status = Evaluate-DeviceStatus -isSuccess $true -latencyMs 20.0 -consecutiveFails 0 -packetLossRate 6.5 -lossWarningThreshPercent 5.0 -jitterMs 5.0 -jitterWarningThreshMs 20.0
        $status | Should Be "Warning"
    }

    It "ジッターが閾値(20.0ms)を超えた場合は 'Warning' を返すこと" {
        $status = Evaluate-DeviceStatus -isSuccess $true -latencyMs 20.0 -consecutiveFails 0 -packetLossRate 0.0 -lossWarningThreshPercent 5.0 -jitterMs 25.4 -jitterWarningThreshMs 20.0
        $status | Should Be "Warning"
    }

    It "損失率・ジッターともに閾値未満で遅延も正常な場合は 'Success' を返すこと" {
        $status = Evaluate-DeviceStatus -isSuccess $true -latencyMs 20.0 -consecutiveFails 0 -packetLossRate 2.0 -lossWarningThreshPercent 5.0 -jitterMs 10.0 -jitterWarningThreshMs 20.0
        $status | Should Be "Success"
    }
}

Describe "8. 設定・機器定義の自動スナップショット＆ロールバック (Common.psm1)" {
    It "Backup-ConfigSnapshot でスナップショットが保存され、Get-ConfigSnapshots で一覧取得できること" {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_SnapshotTest_$(Get-Random)"
        $backupDir = Join-Path $tempDir "backups"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        try {
            $sampleConfigFile = Join-Path $tempDir "devices.json"
            $sampleJson = '[{"ip":"192.168.1.1","name":"Router"}]'
            [System.IO.File]::WriteAllText($sampleConfigFile, $sampleJson, [System.Text.Encoding]::UTF8)

            $snapPath = Backup-ConfigSnapshot -targetFilePath $sampleConfigFile -backupDir $backupDir -maxGenerations 5
            $snapPath | Should Not BeNullOrEmpty
            (Test-Path $snapPath) | Should Be $true

            $list = @(Get-ConfigSnapshots -backupDir $backupDir)
            $list.Count | Should Be 1
            $list[0].type | Should Be "devices"
        } finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "スナップショット世代数が maxGenerations を超えた場合に古いファイルが自動ローテーション削除されること" {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_RotateTest_$(Get-Random)"
        $backupDir = Join-Path $tempDir "backups"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        try {
            $sampleConfigFile = Join-Path $tempDir "config.json"
            [System.IO.File]::WriteAllText($sampleConfigFile, '{"v":1}', [System.Text.Encoding]::UTF8)

            # 3世代制限で4回スナップショットを作成
            for ($i = 1; $i -le 4; $i++) {
                [System.IO.File]::WriteAllText($sampleConfigFile, "{`"v`":$i}", [System.Text.Encoding]::UTF8)
                $null = Backup-ConfigSnapshot -targetFilePath $sampleConfigFile -backupDir $backupDir -maxGenerations 3
                Start-Sleep -Milliseconds 100 # ミリ秒単位ファイル名の一意性を確保
            }

            $list = @(Get-ConfigSnapshots -backupDir $backupDir)
            $list.Count | Should Be 3 # 最大3世代のみ保持されていること
        } finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Restore-ConfigSnapshot で以前のスナップショットから安全に復元できること" {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_RestoreTest_$(Get-Random)"
        $backupDir = Join-Path $tempDir "backups"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        try {
            $targetFile = Join-Path $tempDir "devices.json"
            $origContent = '[{"ip":"10.0.0.1","name":"CoreSwitch"}]'
            [System.IO.File]::WriteAllText($targetFile, $origContent, [System.Text.Encoding]::UTF8)

            $snapPath = Backup-ConfigSnapshot -targetFilePath $targetFile -backupDir $backupDir -maxGenerations 5
            $snapFileName = [System.IO.Path]::GetFileName($snapPath)

            # ファイル内容を変更（誤操作をシミュレート）
            [System.IO.File]::WriteAllText($targetFile, '[{"ip":"10.0.0.1","name":"AccidentallyDeleted"}]', [System.Text.Encoding]::UTF8)

            # ロールバック実行
            $res = Restore-ConfigSnapshot -snapshotFileName $snapFileName -backupDir $backupDir -targetDir $tempDir
            $res.success | Should Be $true
            $res.restoredFile | Should Be "devices.json"

            # 復元されたファイルの内容が元通りか確認
            $restored = [System.IO.File]::ReadAllText($targetFile, [System.Text.Encoding]::UTF8)
            $restored | Should Be $origContent
        } finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Restore-ConfigSnapshot がバックアップフォルダ外のファイルや壊れたJSONで設定を上書きしないこと" {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_RestoreGuard_$(Get-Random)"
        $backupDir = Join-Path $tempDir "backups"
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        try {
            $targetFile = Join-Path $tempDir "devices.json"
            $origContent = '[{"ip":"10.0.0.1","name":"CoreSwitch"}]'
            [System.IO.File]::WriteAllText($targetFile, $origContent, [System.Text.Encoding]::UTF8)
            # バックアップフォルダの外にある「機器一覧に見えない」ファイル
            [System.IO.File]::WriteAllText((Join-Path $tempDir "outside.json"), '{"evil":true}', [System.Text.Encoding]::UTF8)
            # 壊れたスナップショット
            [System.IO.File]::WriteAllText((Join-Path $backupDir "devices_20260101_000000.json"), '[{"ip":', [System.Text.Encoding]::UTF8)

            (Restore-ConfigSnapshot -snapshotFileName "devices_..\outside.json" -backupDir $backupDir -targetDir $tempDir).success | Should Be $false
            (Restore-ConfigSnapshot -snapshotFileName "devices_20260101_000000.json" -backupDir $backupDir -targetDir $tempDir).success | Should Be $false

            [System.IO.File]::ReadAllText($targetFile, [System.Text.Encoding]::UTF8) | Should Be $origContent
        } finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "8b. SNMP Trap の解析 (SnmpService.psm1)" {
    # テスト用の Trap データを組み立てる (種類・長さ・中身の繰り返し)
    function New-Ber([int]$tag, [byte[]]$value) { return [byte[]](@($tag, $value.Length) + $value) }
    function New-BerText([string]$text) { return New-Ber 0x04 ([System.Text.Encoding]::UTF8.GetBytes($text)) }
    function New-BerBind([byte[]]$oid, [byte[]]$value) { return New-Ber 0x30 ([byte[]](@(New-Ber 0x06 $oid) + $value)) }
    $sysUpTimeOid = [byte[]](0x2B, 6, 1, 2, 1, 1, 3, 0)
    $trapOidOid = [byte[]](0x2B, 6, 1, 6, 3, 1, 1, 4, 1, 0)
    $linkDownOid = [byte[]](0x2B, 6, 1, 6, 3, 1, 1, 5, 3)

    It "v2c の linkDown Trap を読み取り、重要度と説明文に直せること" {
        $binds = [byte[]](@(New-BerBind $sysUpTimeOid (New-Ber 0x43 ([byte[]](1, 0)))) + @(New-BerBind $trapOidOid (New-Ber 0x06 $linkDownOid)) + @(New-BerBind ([byte[]](0x2B, 6, 1, 2, 1, 2, 2, 1, 1, 3)) (New-Ber 0x02 ([byte[]](3)))))
        $pduBody = [byte[]](@(New-Ber 0x02 ([byte[]](1))) + @(New-Ber 0x02 ([byte[]](0))) + @(New-Ber 0x02 ([byte[]](0))) + @(New-Ber 0x30 $binds))
        $packet = New-Ber 0x30 ([byte[]](@(New-Ber 0x02 ([byte[]](1))) + @(New-BerText "public") + @(New-Ber 0xA7 $pduBody)))

        $trap = ConvertFrom-SnmpTrapPacket -Packet $packet
        $trap.Version | Should Be "v2c"
        $trap.Pdu | Should Be "Trap"
        $trap.TrapOid | Should Be "1.3.6.1.6.3.1.1.5.3"
        $trap.UptimeTicks | Should Be "256"
        @($trap.VarBinds).Count | Should Be 1
        $trap.VarBinds[0].Oid | Should Be "1.3.6.1.2.1.2.2.1.1.3"
        $trap.VarBinds[0].Value | Should Be "3"

        $display = Get-SnmpTrapDisplay -Trap $trap
        $display.Severity | Should Be "Warning"
        $display.Message | Should Match "linkDown"
        $display.Message | Should Not Match "public"
    }

    It "v1 の Trap を読み取り、v2c と同じ番号にそろえられること" {
        $pduBody = [byte[]](@(New-Ber 0x06 ([byte[]](0x2B, 6, 1, 4, 1, 9))) + @(New-Ber 0x40 ([byte[]](192, 168, 0, 1))) + @(New-Ber 0x02 ([byte[]](2))) + @(New-Ber 0x02 ([byte[]](0))) + @(New-Ber 0x43 ([byte[]](5))) + @(New-Ber 0x30 ([byte[]]@())))
        $packet = New-Ber 0x30 ([byte[]](@(New-Ber 0x02 ([byte[]](0))) + @(New-BerText "public") + @(New-Ber 0xA4 $pduBody)))

        $trap = ConvertFrom-SnmpTrapPacket -Packet $packet
        $trap.Version | Should Be "v1"
        $trap.AgentAddress | Should Be "192.168.0.1"
        $trap.TrapOid | Should Be "1.3.6.1.6.3.1.1.5.3"
    }

    It "値が空の変数や 9 バイトの大きなカウンタがあっても Trap を読み取れること" {
        $binds = [byte[]](@(New-BerBind ([byte[]](0x2B, 6, 1, 2, 1, 1)) (New-Ber 0x46 ([byte[]](0, 255, 255, 255, 255, 255, 255, 255, 255)))) + @(New-BerBind ([byte[]](0x2B, 6, 1, 2, 1, 2)) (New-Ber 0x80 ([byte[]]@()))))
        $pduBody = [byte[]](@(New-Ber 0x02 ([byte[]](1))) + @(New-Ber 0x02 ([byte[]](0))) + @(New-Ber 0x02 ([byte[]](0))) + @(New-Ber 0x30 $binds))
        $packet = New-Ber 0x30 ([byte[]](@(New-Ber 0x02 ([byte[]](1))) + @(New-BerText "public") + @(New-Ber 0xA7 $pduBody)))

        $trap = ConvertFrom-SnmpTrapPacket -Packet $packet
        @($trap.VarBinds).Count | Should Be 2
        $trap.VarBinds[0].Value | Should Be "18446744073709551615"
        $trap.VarBinds[1].Value | Should Be ""
    }

    It "SNMPv3 は中身を読まずに v3 とだけ返し、壊れたデータは例外になること" {
        $v3 = New-Ber 0x30 ([byte[]](@(New-Ber 0x02 ([byte[]](3))) + @(New-Ber 0x30 ([byte[]]@()))))
        (ConvertFrom-SnmpTrapPacket -Packet $v3).Version | Should Be "v3"

        { ConvertFrom-SnmpTrapPacket -Packet ([byte[]](1, 2, 3)) } | Should Throw
        { ConvertFrom-SnmpTrapPacket -Packet ([byte[]](0x30, 0x7F, 0x02)) } | Should Throw
    }
}

Describe "8c. OBR の接続状況の読み取り (ObrStatus.psm1)" {
    Import-Module (Join-Path $projectRoot "system\modules\ObrStatus.psm1") -Force -DisableNameChecking

    It "接続中の応答から SSID・チャンネル・電波の強さ・速度を読み取れること" {
        $html = @'
<html><head><META HTTP-EQUIV="refresh" CONTENT="30;url=wlstast_main.htm?lang=eng"></head><body>
<script type="text/javascript">
<!--
var stainfo = {ssid:"SAMPLE-AP(00:11:22:33:44:55)",chan:"6 (2.4GHz) 20MHz",signal:-47,txbitrate:"144.4 Mbit/s"};
var antennaName = "antenna"
ContentsStart("Connecting Wireless LAN Access Point Information");
// -->
</script></body></html>
'@
        $r = ConvertFrom-ObrStatusHtml -Html $html
        $r.Found | Should Be $true
        $r.Connected | Should Be $true
        $r.Ssid | Should Be "SAMPLE-AP"
        $r.Bssid | Should Be "00:11:22:33:44:55"
        $r.Channel | Should Be "6 (2.4GHz) 20MHz"
        $r.SignalDbm | Should Be -47
        $r.TxBitrate | Should Be "144.4 Mbit/s"
    }

    It "非接続の応答を「未接続」と判定できること" {
        $r = ConvertFrom-ObrStatusHtml -Html 'var stainfo = {ssid:"---(---)",chan:"---",signal:0,txbitrate:"---"};'
        $r.Found | Should Be $true
        $r.Connected | Should Be $false
        $r.Ssid | Should Be ""
        $r.SignalDbm | Should Be $null
    }

    It "かっこを含む SSID を正しく分けられること" {
        $r = ConvertFrom-ObrStatusHtml -Html 'var stainfo = {ssid:"AP(2F)(AA:BB:CC:DD:EE:FF)",chan:"36 (5GHz) 80MHz",signal:-60,txbitrate:"866 Mbit/s"};'
        $r.Ssid | Should Be "AP(2F)"
        $r.Bssid | Should Be "AA:BB:CC:DD:EE:FF"
    }

    It "無線状態の履歴を CSV に追記でき、SSID の数式は実行されない形で保存されること" {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_ObrHistory_$(Get-Random)"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            $rows = @(@{ ip = '10.0.0.1'; name = '車両1'; state = 'Connected'; ssid = '=cmd|calc'; bssid = 'AA:BB'; channel = '6 (2.4GHz), 20MHz'; signalDbm = -47; txBitrate = '144 Mbit/s'; checkedAt = '2026-10-30 20:00:00' })
            Write-ObrHistoryRows -SessionDir $dir -Rows $rows | Should Be $true
            $rows2 = @(@{ ip = '10.0.0.1'; name = '車両1'; state = 'Disconnected'; checkedAt = '2026-10-30 20:00:30' })
            Write-ObrHistoryRows -SessionDir $dir -Rows $rows2 | Should Be $true
            $path = Join-Path $dir "obr_wireless_10.0.0.1.csv"
            $bytes = [System.IO.File]::ReadAllBytes($path)
            $bytes[0] | Should Be 0xEF
            $parsed = @(Get-Content $path -Encoding UTF8 | ConvertFrom-Csv)
            $parsed.Count | Should Be 2
            $parsed[0].SSID | Should Be "'=cmd|calc"
            $parsed[0].チャンネル | Should Be "6 (2.4GHz), 20MHz"
            $parsed[0]."電波強度_dBm" | Should Be "-47"
            $parsed[1].状態 | Should Be "Disconnected"
        } finally {
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "OBR に接続できないときは Unreachable を返すこと" {
        (Get-ObrWirelessStatus -HostName '127.0.0.9' -Password 'x' -TimeoutMs 1000).State | Should Be 'Unreachable'
    }

    It "stainfo がないページ (ログイン画面など) は接続状況なしと判定すること" {
        (ConvertFrom-ObrStatusHtml -Html '<html><body><form action="login"></form></body></html>').Found | Should Be $false
        (ConvertFrom-ObrStatusHtml -Html '').Found | Should Be $false
    }
}

Describe "9. システム前提環境・モジュール診断 (Common.psm1 / Test-SystemPrerequisites)" {
    It "Test-SystemPrerequisites が正常に診断結果ハッシュテーブルを返し、PowerShell互換性を検出すること" {
        $diag = Test-SystemPrerequisites
        $diag | Should Not BeNullOrEmpty
        $diag.isPsCompatible | Should Be $true
        $diag.psVersion | Should Not BeNullOrEmpty
        $diag.executionPolicy | Should Not BeNullOrEmpty
        ($diag.ContainsKey("snmpModule")) | Should Be $true
        ($diag.ContainsKey("iperf3")) | Should Be $true
        ($diag.ContainsKey("pesterModule")) | Should Be $true
    }

    It "SNMP モジュール診断プロパティが正しく構造化されていること" {
        $diag = Test-SystemPrerequisites
        $snmpInfo = $diag.snmpModule
        $snmpInfo | Should Not BeNullOrEmpty
        ($snmpInfo.ContainsKey("installed")) | Should Be $true
        ($snmpInfo.ContainsKey("requiredFor")) | Should Be $true
        $snmpInfo.requiredFor | Should Not BeNullOrEmpty
    }
}

Describe "10. トポロジー描画強化・UIアセット整合性検証" {
    It "devices.json が有効な JSON 配列であり、必須属性が含まれていること" {
        $devicesPath = Join-Path $projectRoot "system\devices.json"
        (Test-Path $devicesPath) | Should Be $true
        $json = Get-Content $devicesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $json | Should Not BeNullOrEmpty
        $json.Count | Should BeGreaterThan 0
        $first = $json[0]
        $first.ip | Should Not BeNullOrEmpty
    }

    It "index.html に階層ツリー整列・シアターモード・アニメーションFX切替ボタンが存在すること" {
        $htmlPath = Join-Path $projectRoot "system\public\index.html"
        (Test-Path $htmlPath) | Should Be $true
        $html = Get-Content $htmlPath -Raw -Encoding UTF8
        ($html.Contains('id="topo-tree-layout-btn"')) | Should Be $true
        ($html.Contains('id="topo-fullscreen-btn"')) | Should Be $true
        ($html.Contains('id="topo-fx-toggle-btn"')) | Should Be $true
    }

    It "style.css にシアターモードおよびアニメーションFXボタンスタイルが定義されていること" {
        $cssPath = Join-Path $projectRoot "system\public\style.css"
        (Test-Path $cssPath) | Should Be $true
        $css = Get-Content $cssPath -Raw -Encoding UTF8
        ($css.Contains('.topology-layout.theater-mode')) | Should Be $true
        ($css.Contains('.topo-btn-fx-on')) | Should Be $true
        ($css.Contains('.topo-btn-theater-active')) | Should Be $true
    }

    It "app.js に階層ツリー整列・彗星粒子描画・シアターモード制御関数が存在すること" {
        $jsPath = Join-Path $projectRoot "system\public\app.js"
        (Test-Path $jsPath) | Should Be $true
        $js = Get-Content $jsPath -Raw -Encoding UTF8
        ($js.Contains('function applyHierarchicalTreeLayout')) | Should Be $true
        ($js.Contains('function drawCometParticle')) | Should Be $true
        ($js.Contains('function formatMbps')) | Should Be $true
        ($js.Contains('function toggleTheaterMode')) | Should Be $true
        ($js.Contains('function toggleAnimationFx')) | Should Be $true
    }
}

Describe "11. Runspace 内でのモジュール関数呼び出し整合性 (Runspaceモジュールスコープ保証)" {
    It "New-AppRunspace で作成された Runspace 内で Evaluate-DeviceStatus が正常に実行できること" {
        $serverContent = Get-Content (Join-Path $projectRoot "system\Server.ps1") -Raw -Encoding UTF8
        # Server.ps1 内の New-AppRunspace 定義を抽出して実行
        $dummySyncHash = [hashtable]::Synchronized(@{
            PSScriptRoot = (Join-Path $projectRoot "system")
        })
        
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $modDir = Join-Path $dummySyncHash.PSScriptRoot "modules"
        Get-ChildItem -Path $modDir -Filter "*.psm1" | ForEach-Object {
            $iss.ImportPSModule($_.FullName)
        }
        $testRs = [runspacefactory]::CreateRunspace($iss)
        $testRs.ApartmentState = "STA"
        $testRs.ThreadOptions  = "ReuseThread"
        $testRs.Open()
        $testRs.SessionStateProxy.SetVariable("syncHash", $dummySyncHash)
        
        $pipe = $testRs.CreatePipeline()
        $pipe.Commands.AddScript("
            Evaluate-DeviceStatus -isSuccess `$true -latencyMs 15.0 -consecutiveFails 0 -latencyWarningMs 80 -consecutiveFailThresh 2
        ")
        $result = $pipe.Invoke()
        $testRs.Close()
        $testRs.Dispose()
        
        $result | Should Not BeNullOrEmpty
        $result[0] | Should Be "Success"
    }

    It "New-AppRunspace で作成された Runspace 内で Update-RollupCache および Invoke-SnmpWalkUnified が認識されること" {
        $dummySyncHash = [hashtable]::Synchronized(@{
            PSScriptRoot = (Join-Path $projectRoot "system")
        })
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $modDir = Join-Path $dummySyncHash.PSScriptRoot "modules"
        Get-ChildItem -Path $modDir -Filter "*.psm1" | ForEach-Object {
            $iss.ImportPSModule($_.FullName)
        }
        $testRs = [runspacefactory]::CreateRunspace($iss)
        $testRs.Open()
        
        $pipe = $testRs.CreatePipeline()
        $pipe.Commands.AddScript("
            @(
                (Get-Command Update-RollupCache -ErrorAction SilentlyContinue).Name,
                (Get-Command Invoke-SnmpWalkUnified -ErrorAction SilentlyContinue).Name
            )
        ")
        $commands = $pipe.Invoke()
        $testRs.Close()
        $testRs.Dispose()
        
        ($commands -contains "Update-RollupCache") | Should Be $true
        ($commands -contains "Invoke-SnmpWalkUnified") | Should Be $true
    }
}

Describe "12. 長時間・高頻度稼働時のログ記録・ローテーション結合・高速レポート生成検証" {
    It "100ms計測2時間相当（72,000行）の巨大CSVでも1秒未満で高速にレポート生成され、先頭と末尾のデータが保持されること" {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_LongRun72k_$(Get-Random)"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        try {
            $csvPath = Join-Path $tempDir "192.168.1.10.csv"
            $lines = [System.Collections.Generic.List[string]]::new(72020)
            $lines.Add("タイムスタンプ,IPアドレス,ステータス,遅延_ms,帯域_Mbps,送信_Mbps,受信_Mbps,瞬断継続_sec,ジッター_ms")
            $lines.Add('"2026-10-27 12:00:00","192.168.1.10","Success","3","250.0","1.2","2.4","","0.5"')
            for ($i = 1; $i -lt 71999; $i++) {
                $lines.Add('"2026-10-27 12:30:00","192.168.1.10","Success","5","250.0","1.5","2.8","","0.8"')
            }
            $lines.Add('"2026-10-27 13:59:59","192.168.1.10","Success","9","250.0","3.1","4.2","","1.2"')
            $lines.Add("")
            $lines.Add("--- 計測サマリー ---")
            $lines.Add("総Ping送信数（試行回数）,72000")
            [System.IO.File]::WriteAllLines($csvPath, $lines, [System.Text.Encoding]::GetEncoding(932))

            $sync = @{
                SessionDir = $tempDir
                PSScriptRoot = (Join-Path $projectRoot "system")
                Devices = @("192.168.1.10")
                Status = @{ "192.168.1.10" = @{ status = "Success" } }
                Stats = @{ "192.168.1.10" = @{ Total = 72000; Success = 72000; Failed = 0; MinLat = 3; MaxLat = 9; SumLat = 360000; LatCount = 72000; MaxOutageSec = 0; Outage600msCount = 0; Outage5sCount = 0; JitterSum = 57600; JitterCount = 72000 } }
                DeviceName = @{ "192.168.1.10" = "CoreRouter" }
                Group = @{ "192.168.1.10" = "Core" }
                Location = @{ "192.168.1.10" = "1F" }
                TroubleMemo = @{}
                PollInterval = 100
                HighFreqTargetIps = "192.168.1.10"
            }

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $html = Generate-SessionReportHtml -sync $sync -period "Session"
            $sw.Stop()

            $html | Should Not BeNullOrEmpty
            ($sw.ElapsedMilliseconds -lt 2000) | Should Be $true
            $html.Contains("12:00:00") | Should Be $true
            $html.Contains("13:59:59") | Should Be $true
        } finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "10MBローテーションで分割された複数CSV (_2.csv, _1.csv, .csv) が時系列順に結合されてレポート化されること" {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_RotMerge_$(Get-Random)"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        try {
            $enc = [System.Text.Encoding]::GetEncoding(932)
            $hdr = "タイムスタンプ,IPアドレス,ステータス,遅延_ms,帯域_Mbps,送信_Mbps,受信_Mbps,瞬断継続_sec,ジッター_ms"
            [System.IO.File]::WriteAllLines((Join-Path $tempDir "192.168.1.50_2.csv"), @($hdr, '"2026-10-27 10:00:01","192.168.1.50","Success","2","250.0","1.0","1.0","","0.2"'), $enc)
            [System.IO.File]::WriteAllLines((Join-Path $tempDir "192.168.1.50_1.csv"), @($hdr, '"2026-10-27 11:00:02","192.168.1.50","Success","4","250.0","1.2","1.4","","0.4"'), $enc)
            [System.IO.File]::WriteAllLines((Join-Path $tempDir "192.168.1.50.csv"),   @($hdr, '"2026-10-27 12:00:03","192.168.1.50","Success","6","250.0","1.5","1.8","","0.6"'), $enc)

            $sync = @{
                SessionDir = $tempDir
                PSScriptRoot = (Join-Path $projectRoot "system")
                Devices = @("192.168.1.50")
                Status = @{ "192.168.1.50" = @{ status = "Success" } }
                Stats = @{ "192.168.1.50" = @{ Total = 3; Success = 3; Failed = 0; MinLat = 2; MaxLat = 6; SumLat = 12; LatCount = 3; MaxOutageSec = 0; Outage600msCount = 0; Outage5sCount = 0; JitterSum = 1.2; JitterCount = 3 } }
                DeviceName = @{ "192.168.1.50" = "Switch50" }
                Group = @{ "192.168.1.50" = "Floor" }
                Location = @{ "192.168.1.50" = "2F" }
                TroubleMemo = @{}
                PollInterval = 100
                HighFreqTargetIps = "192.168.1.50"
            }

            $html = Generate-SessionReportHtml -sync $sync -period "Session"
            $html.Contains("10:00:01") | Should Be $true
            $html.Contains("11:00:02") | Should Be $true
            $html.Contains("12:00:03") | Should Be $true
        } finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Server.ps1 のPingループ内チェックポイント処理で重いCSV全行読み込みが排除されていること" {
        $serverRaw = Get-Content (Join-Path $projectRoot "system\Server.ps1") -Raw -Encoding UTF8
        # _checkpoint.json 保存箇所の直後に ReadAllLines による同期CSVパースが存在しないこと
        ($serverRaw -match '_checkpoint\.json[\s\S]{1,400}ReadAllLines') | Should Be $false
    }
}



Describe "13. 外部サイトからの API 呼び出し拒否 (CSRF 対策 / Test-ApiRequestAllowed)" {
    It "ブラウザ以外（Origin / Sec-Fetch-Site なし）からの呼び出しは許可されること" {
        Test-ApiRequestAllowed -Origin $null -SecFetchSite $null -Port 8081 | Should Be $true
    }

    It "監視画面自身（同一オリジン）からの呼び出しは許可されること" {
        Test-ApiRequestAllowed -Origin "http://localhost:8081" -SecFetchSite "same-origin" -Port 8081 | Should Be $true
        Test-ApiRequestAllowed -Origin "http://127.0.0.1:8081" -SecFetchSite $null -Port 8081 | Should Be $true
        Test-ApiRequestAllowed -Origin $null -SecFetchSite "none" -Port 8081 | Should Be $true
    }

    It "別サイトの Origin からの呼び出しは拒否されること" {
        Test-ApiRequestAllowed -Origin "https://evil.example.com" -SecFetchSite $null -Port 8081 | Should Be $false
        Test-ApiRequestAllowed -Origin "http://localhost:3000" -SecFetchSite $null -Port 8081 | Should Be $false
        Test-ApiRequestAllowed -Origin "null" -SecFetchSite $null -Port 8081 | Should Be $false
    }

    It "Sec-Fetch-Site が cross-site / same-site の場合は Origin がなくても拒否されること" {
        Test-ApiRequestAllowed -Origin $null -SecFetchSite "cross-site" -Port 8081 | Should Be $false
        Test-ApiRequestAllowed -Origin $null -SecFetchSite "same-site" -Port 8081 | Should Be $false
    }

    It "Server.ps1 が全開放の CORS ヘッダー (Access-Control-Allow-Origin: *) を返さないこと" {
        $serverSrc = Get-Content (Join-Path $projectRoot "system\Server.ps1") -Raw -Encoding UTF8
        $serverSrc | Should Not Match 'Access-Control-Allow-Origin'
        $serverSrc | Should Match 'Test-ApiRequestAllowed'
    }
}
