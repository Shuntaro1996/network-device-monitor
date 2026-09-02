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
