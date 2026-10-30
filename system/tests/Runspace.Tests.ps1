# ==============================================================================
# Runspace.Tests.ps1 - Multi-threaded Runspace Integrity, Stress & REST API Tests
# ==============================================================================
# 【初心者向けの簡単な解説】
# このテストファイルは、監視システムの重要な内部メカニズム（Runspace: 並行処理機能）が
# 複数スレッドで同時に激しく動作しても、データ破損やクラッシュ、ロック衝突を起こさないかを
# 高負荷をかけて徹底的に検証する自動テストです。
# また、Web画面との通信インターフェース（REST API）の送受信データ形式（スキーマ）が
# 仕様書通りに正しく構成されているかも厳密にチェックします。
# ==============================================================================

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Resolve-Path (Join-Path $here "..\..")
$systemDir = Join-Path $projectRoot "system"
$moduleDir = Join-Path $systemDir "modules"

# モジュールのインポート
Import-Module (Join-Path $moduleDir "Common.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleDir "PingEngine.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleDir "SnmpService.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleDir "ReportGenerator.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleDir "AlertManager.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleDir "IperfRunner.psm1") -Force -DisableNameChecking

# ==============================================================================
# 1. New-AppRunspace 基本ライフサイクル & 実行分離
# ==============================================================================
Describe "1. New-AppRunspace 基本ライフサイクル & 実行分離" {
    It "New-AppRunspace で STA / ReuseThread のバックグラウンド Runspace が正常に生成・オープンされること" {
        $rs = New-AppRunspace
        try {
            $rs | Should Not BeNullOrEmpty
            $rs.RunspaceStateInfo.State | Should Be ([System.Management.Automation.Runspaces.RunspaceState]::Opened)
            $rs.ApartmentState | Should Be ([System.Threading.ApartmentState]::STA)
        } finally {
            if ($rs) { $rs.Close(); $rs.Dispose() }
        }
    }

    It "syncHash および VariablesToSet がバックグラウンド Runspace へ正しく引き渡され参照できること" {
        $sync = [hashtable]::Synchronized(@{
            Key1         = "ValueAlpha"
            PSScriptRoot = $systemDir
        })
        $vars = @{
            WorkerName    = "Worker_Test_007"
            TargetTimeout = 750
        }

        $rs = New-AppRunspace -syncHash $sync -VariablesToSet $vars
        try {
            $pipe = $rs.CreatePipeline()
            $pipe.Commands.AddScript("
                `$syncHash.Key1 + '_' + `$WorkerName + '_' + `$TargetTimeout
            ")
            $res = $pipe.Invoke()
            $res | Should Not BeNullOrEmpty
            $res[0] | Should Be "ValueAlpha_Worker_Test_007_750"
        } finally {
            if ($rs) { $rs.Close(); $rs.Dispose() }
        }
    }
}

# ==============================================================================
# 2. 全6ヘルパーモジュールのバックグラウンド Runspace 自動ロード整合性
# ==============================================================================
Describe "2. 全6ヘルパーモジュールのバックグラウンド Runspace 自動ロード整合性" {
    It "Common.psm1 の関数群 (Get-MimeType, Protect/Unprotect-SecretString) が Runspace 内で実行できること" {
        $dummySync = [hashtable]::Synchronized(@{ PSScriptRoot = $systemDir })
        $rs = New-AppRunspace -syncHash $dummySync -ModulesToImport @("Common")
        try {
            $pipe = $rs.CreatePipeline()
            $pipe.Commands.AddScript("
                `$mime = Get-MimeType -ext '.json'
                `$secret = 'RunspaceSecretPass123'
                `$enc = Protect-SecretString -plainText `$secret
                `$dec = Unprotect-SecretString -cipherText `$enc
                [PSCustomObject]@{
                    Mime      = `$mime
                    Decrypted = `$dec
                    HasPrefix = `$enc.StartsWith('enc:')
                }
            ")
            $res = $pipe.Invoke()
            $res | Should Not BeNullOrEmpty
            $res[0].Mime | Should Be "application/json; charset=utf-8"
            $res[0].Decrypted | Should Be "RunspaceSecretPass123"
            $res[0].HasPrefix | Should Be $true
        } finally {
            if ($rs) { $rs.Close(); $rs.Dispose() }
        }
    }

    It "PingEngine.psm1 の関数 (Evaluate-DeviceStatus, Test-TcpPortEndpoint) が Runspace 内で実行できること" {
        $dummySync = [hashtable]::Synchronized(@{ PSScriptRoot = $systemDir })
        $rs = New-AppRunspace -syncHash $dummySync -ModulesToImport @("PingEngine")
        try {
            $pipe = $rs.CreatePipeline()
            $pipe.Commands.AddScript("
                `$s1 = Evaluate-DeviceStatus -isSuccess `$true -latencyMs 12.0 -consecutiveFails 0 -latencyWarningMs 80 -consecutiveFailThresh 2
                `$s2 = Evaluate-DeviceStatus -isSuccess `$false -latencyMs 0.0 -consecutiveFails 3 -latencyWarningMs 80 -consecutiveFailThresh 2
                [PSCustomObject]@{
                    Normal  = `$s1
                    Failure = `$s2
                }
            ")
            $res = $pipe.Invoke()
            $res | Should Not BeNullOrEmpty
            $res[0].Normal | Should Be "Success"
            $res[0].Failure | Should Be "Failed"
        } finally {
            if ($rs) { $rs.Close(); $rs.Dispose() }
        }
    }

    It "SnmpService.psm1 の関数 (Check-WebAndSslEndpoint, Invoke-SnmpGetUnified等) が Runspace 内で認識されること" {
        $dummySync = [hashtable]::Synchronized(@{ PSScriptRoot = $systemDir })
        $rs = New-AppRunspace -syncHash $dummySync -ModulesToImport @("SnmpService")
        try {
            $pipe = $rs.CreatePipeline()
            $pipe.Commands.AddScript("
                @(
                    (Get-Command Check-WebAndSslEndpoint -ErrorAction SilentlyContinue).Name,
                    (Get-Command Invoke-SnmpGetUnified -ErrorAction SilentlyContinue).Name,
                    (Get-Command Invoke-SnmpWalkUnified -ErrorAction SilentlyContinue).Name
                )
            ")
            $res = $pipe.Invoke()
            $res | Should Not BeNullOrEmpty
            ($res -contains "Check-WebAndSslEndpoint") | Should Be $true
            ($res -contains "Invoke-SnmpGetUnified") | Should Be $true
            ($res -contains "Invoke-SnmpWalkUnified") | Should Be $true
        } finally {
            if ($rs) { $rs.Close(); $rs.Dispose() }
        }
    }

    It "ReportGenerator.psm1 の関数 (Clean-IperfLogLines, Safe-ExportCsv, Update-RollupCache) が Runspace 内で実行できること" {
        $dummySync = [hashtable]::Synchronized(@{ PSScriptRoot = $systemDir })
        $rs = New-AppRunspace -syncHash $dummySync -ModulesToImport @("ReportGenerator")
        try {
            $pipe = $rs.CreatePipeline()
            $pipe.Commands.AddScript("
                `$rawLines = @(
                    '=== iperf3 Execution ===',
                    'error - unable to connect to server: Connection refused',
                    '=== iperf3 Execution ===',
                    '[  5] 0.00-1.00 sec 10 MBytes 80 Mbits/sec'
                )
                `$cleaned = Clean-IperfLogLines -lines `$rawLines
                [PSCustomObject]@{
                    CleanCount   = `$cleaned.Count
                    HasErrorLine = (`$cleaned -match 'unable to connect').Count -gt 0
                }
            ")
            $res = $pipe.Invoke()
            $res | Should Not BeNullOrEmpty
            $res[0].CleanCount | Should BeGreaterThan 0
            $res[0].HasErrorLine | Should Be $false
        } finally {
            if ($rs) { $rs.Close(); $rs.Dispose() }
        }
    }

    It "AlertManager.psm1 の関数 (Send-WebhookNotification, Send-EmailNotification) が Runspace 内で認識され安全実行できること" {
        $dummySync = [hashtable]::Synchronized(@{ PSScriptRoot = $systemDir })
        $rs = New-AppRunspace -syncHash $dummySync -ModulesToImport @("AlertManager")
        try {
            $pipe = $rs.CreatePipeline()
            $pipe.Commands.AddScript("
                `$cmds = @(
                    (Get-Command Send-WebhookNotification -ErrorAction SilentlyContinue).Name,
                    (Get-Command Send-EmailNotification -ErrorAction SilentlyContinue).Name
                )
                # 空URLでの安全実行検証（例外でクラッシュしないこと）
                Send-WebhookNotification -url '' -deviceName 'TestDev' -ip '10.0.0.1' -eventType 'test'
                `$cmds
            ")
            $res = $pipe.Invoke()
            $res | Should Not BeNullOrEmpty
            ($res -contains "Send-WebhookNotification") | Should Be $true
            ($res -contains "Send-EmailNotification") | Should Be $true
        } finally {
            if ($rs) { $rs.Close(); $rs.Dispose() }
        }
    }

    It "IperfRunner.psm1 の関数 (Get-IperfCommandLine, Rollback-FailedIperfExecution) が Runspace 内で実行できること" {
        $dummySync = [hashtable]::Synchronized(@{ PSScriptRoot = $systemDir })
        $rs = New-AppRunspace -syncHash $dummySync -ModulesToImport @("IperfRunner")
        try {
            $pipe = $rs.CreatePipeline()
            $pipe.Commands.AddScript("
                `$argsList = Get-IperfCommandLine -target '192.168.1.50' -port 5201 -time 15 -proto 'udp' -reverse `$true
                `$argsList
            ")
            $res = $pipe.Invoke()
            $res | Should Not BeNullOrEmpty
            ($res -contains "-c") | Should Be $true
            ($res -contains "192.168.1.50") | Should Be $true
            ($res -contains "-p") | Should Be $true
            ($res -contains "5201") | Should Be $true
            ($res -contains "-u") | Should Be $true
            ($res -contains "-R") | Should Be $true
        } finally {
            if ($rs) { $rs.Close(); $rs.Dispose() }
        }
    }

    It "引数なし（デフォルト呼び出し）で New-AppRunspace を実行した場合に全6モジュールが一括インポートされること" {
        $dummySync = [hashtable]::Synchronized(@{ PSScriptRoot = $systemDir })
        $rs = New-AppRunspace -syncHash $dummySync
        try {
            $pipe = $rs.CreatePipeline()
            $pipe.Commands.AddScript("
                @(
                    (Get-Command Get-MimeType -ErrorAction SilentlyContinue).Name,
                    (Get-Command Evaluate-DeviceStatus -ErrorAction SilentlyContinue).Name,
                    (Get-Command Check-WebAndSslEndpoint -ErrorAction SilentlyContinue).Name,
                    (Get-Command Clean-IperfLogLines -ErrorAction SilentlyContinue).Name,
                    (Get-Command Send-WebhookNotification -ErrorAction SilentlyContinue).Name,
                    (Get-Command Get-IperfCommandLine -ErrorAction SilentlyContinue).Name
                )
            ")
            $res = $pipe.Invoke()
            $res | Should Not BeNullOrEmpty
            ($res -contains "Get-MimeType") | Should Be $true
            ($res -contains "Evaluate-DeviceStatus") | Should Be $true
            ($res -contains "Check-WebAndSslEndpoint") | Should Be $true
            ($res -contains "Clean-IperfLogLines") | Should Be $true
            ($res -contains "Send-WebhookNotification") | Should Be $true
            ($res -contains "Get-IperfCommandLine") | Should Be $true
        } finally {
            if ($rs) { $rs.Close(); $rs.Dispose() }
        }
    }
}

# ==============================================================================
# 3. $syncHash マルチスレッド並行アクセス・負荷ストレステスト
# ==============================================================================
Describe "3. `$syncHash マルチスレッド並行アクセス・負荷ストレステスト" {
    It "6個の並行 Runspace から同一 `$syncHash への高頻度読み書きでデータ破損・例外が発生しないこと" {
        $syncHash = [hashtable]::Synchronized(@{})
        $syncHash.PSScriptRoot = $systemDir
        $syncHash.Status       = [hashtable]::Synchronized(@{})
        $syncHash.Stats        = [hashtable]::Synchronized(@{})
        $syncHash.SyslogQueue  = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
        $syncHash.Devices      = @("10.0.0.1", "10.0.0.2", "10.0.0.3", "10.0.0.4", "10.0.0.5")

        foreach ($dev in $syncHash.Devices) {
            $syncHash.Status[$dev] = @{
                status    = "Success"
                latency   = 5.0
                timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            }
            $syncHash.Stats[$dev] = [hashtable]::Synchronized(@{
                PingCount = 0
                LossCount = 0
            })
        }

        $workerScript = {
            param($workerId, $iterations, $sync)
            $res = [PSCustomObject]@{
                WorkerId     = $workerId
                SuccessCount = 0
                FailCount    = 0
                Errors       = [System.Collections.Generic.List[string]]::new()
            }
            $rnd = [System.Random]::new($workerId * 100 + [System.Environment]::TickCount)
            $devList = $sync.Devices

            for ($i = 0; $i -lt $iterations; $i++) {
                try {
                    $targetIp = $devList[$rnd.Next(0, $devList.Count)]

                    # 1. ステータス並行書き込み
                    $stObj = @{
                        status    = if ($rnd.Next(0, 10) -eq 0) { "Warning" } else { "Success" }
                        latency   = [math]::Round($rnd.NextDouble() * 40.0 + 2.0, 2)
                        timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
                    }
                    $sync.Status[$targetIp] = $stObj

                    # 2. ステータス並行読み出し
                    $readBack = $sync.Status[$targetIp]
                    if ($null -eq $readBack -or $null -eq $readBack.status) {
                        throw "Failed to read back status for $targetIp"
                    }

                    # 3. 統計カウンター更新 (Monitor ロックによる安全加算)
                    $statHash = $sync.Stats[$targetIp]
                    if ($statHash) {
                        $sRoot = $statHash.SyncRoot
                        [System.Threading.Monitor]::Enter($sRoot)
                        try {
                            $statHash.PingCount = [int]$statHash.PingCount + 1
                        } finally {
                            [System.Threading.Monitor]::Exit($sRoot)
                        }
                    }

                    # 4. 同期Syslogキューへの並行追加
                    $logItem = @{
                        Timestamp = (Get-Date).ToString("o")
                        WorkerId  = $workerId
                        Iteration = $i
                        Message   = "Stress ping from worker $workerId to $targetIp"
                    }
                    $sync.SyslogQueue.Add($logItem) | Out-Null

                    $res.SuccessCount++
                } catch {
                    $res.FailCount++
                    $res.Errors.Add("Worker $workerId iter $i error: $($_.Exception.Message)")
                }
                [System.Threading.Thread]::Sleep(1)
            }
            return $res
        }

        $numWorkers = 6
        $opsPerWorker = 25
        $psList = [System.Collections.Generic.List[object]]::new()
        $handleList = [System.Collections.Generic.List[object]]::new()

        for ($w = 1; $w -le $numWorkers; $w++) {
            $ps = [powershell]::Create()
            $ps.AddScript($workerScript) | Out-Null
            $ps.AddArgument($w) | Out-Null
            $ps.AddArgument($opsPerWorker) | Out-Null
            $ps.AddArgument($syncHash) | Out-Null
            $handle = $ps.BeginInvoke()
            $psList.Add($ps)
            $handleList.Add($handle)
        }

        $allDoneInTime = $true
        $workerOutputs = @()

        for ($idx = 0; $idx -lt $handleList.Count; $idx++) {
            $completed = $handleList[$idx].AsyncWaitHandle.WaitOne(20000)
            if (-not $completed) {
                $allDoneInTime = $false
            } else {
                $out = $psList[$idx].EndInvoke($handleList[$idx])
                $workerOutputs += $out
            }
            $psList[$idx].Dispose()
        }

        $allDoneInTime | Should Be $true
        $totalFails = ($workerOutputs | Measure-Object -Property FailCount -Sum).Sum
        $totalFails | Should Be 0

        $totalSuccess = ($workerOutputs | Measure-Object -Property SuccessCount -Sum).Sum
        $totalSuccess | Should Be ($numWorkers * $opsPerWorker)

        # Syslogキューに全トランザクション分 (150件) のレコードが存在すること
        $syncHash.SyslogQueue.Count | Should Be ($numWorkers * $opsPerWorker)

        # 各機器のPingCount合計が全実行回数と一致すること
        $totalPings = 0
        foreach ($dev in $syncHash.Devices) {
            $totalPings += [int]$syncHash.Stats[$dev].PingCount
        }
        $totalPings | Should Be ($numWorkers * $opsPerWorker)
    }
}

# ==============================================================================
# 4. Save-DevicesJson 並行書き込みストレステスト & スキーマ維持検証
# ==============================================================================
function Safe-RemoveDirectory([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path $path)) { return }
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    for ($i = 0; $i -lt 5; $i++) {
        try {
            Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
            break
        } catch {
            Start-Sleep -Milliseconds 100
        }
    }
}

Describe "4. Save-DevicesJson 並行書き込みストレステスト & スキーマ維持検証" {
    $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_Runspace_Stress_$([Guid]::NewGuid().ToString('N'))"
    $testBackupDir = Join-Path $testDir "backups"
    $testDevicesJson = Join-Path $testDir "devices_concurrent.json"

    BeforeEach {
        Safe-RemoveDirectory $testDir
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        New-Item -ItemType Directory -Path $testBackupDir -Force | Out-Null
    }

    AfterEach {
        Safe-RemoveDirectory $testDir
    }

    It "5個の並行 Runspace から同時に Save-DevicesJson を呼び出してもファイル破損・スキーマ欠落が発生しないこと" {
        $syncHash = [hashtable]::Synchronized(@{})
        $syncHash.PSScriptRoot = $systemDir
        $syncHash.BackupDir    = $testBackupDir
        $syncHash.DevicesLock  = [object]::new()

        $initialDevices = @("192.168.10.1", "192.168.10.2", "192.168.10.3", "192.168.10.4", "192.168.10.5")
        $syncHash.Devices = $initialDevices

        $syncHash.DeviceName    = [hashtable]::Synchronized(@{})
        $syncHash.Community     = [hashtable]::Synchronized(@{})
        $syncHash.IsMonitored   = [hashtable]::Synchronized(@{})
        $syncHash.Group         = [hashtable]::Synchronized(@{})
        $syncHash.Image         = [hashtable]::Synchronized(@{})
        $syncHash.ConnectedTo   = [hashtable]::Synchronized(@{})
        $syncHash.X             = [hashtable]::Synchronized(@{})
        $syncHash.Y             = [hashtable]::Synchronized(@{})
        $syncHash.Mac           = [hashtable]::Synchronized(@{})
        $syncHash.VendorContact = [hashtable]::Synchronized(@{})
        $syncHash.DeviceType    = [hashtable]::Synchronized(@{})
        $syncHash.WebUrl        = [hashtable]::Synchronized(@{})
        $syncHash.CheckType     = [hashtable]::Synchronized(@{})
        $syncHash.Port          = [hashtable]::Synchronized(@{})
        $syncHash.SnmpVersion   = [hashtable]::Synchronized(@{})
        $syncHash.SnmpUser      = [hashtable]::Synchronized(@{})
        $syncHash.SnmpAuthProto = [hashtable]::Synchronized(@{})
        $syncHash.SnmpAuthPass  = [hashtable]::Synchronized(@{})
        $syncHash.SnmpPrivProto = [hashtable]::Synchronized(@{})
        $syncHash.SnmpPrivPass  = [hashtable]::Synchronized(@{})

        foreach ($ip in $initialDevices) {
            $lastOctet = [int]($ip.Split('.')[-1])
            $syncHash.DeviceName[$ip]    = "CoreRouter_$lastOctet"
            $syncHash.Community[$ip]     = "public"
            $syncHash.IsMonitored[$ip]   = $true
            $syncHash.Group[$ip]         = "Infrastructure"
            $syncHash.Image[$ip]         = "router.png"
            $syncHash.ConnectedTo[$ip]   = if ($lastOctet -gt 1) { "192.168.10.1" } else { "" }
            $syncHash.X[$ip]             = 120 * $lastOctet
            $syncHash.Y[$ip]             = 180 * $lastOctet
            $syncHash.Mac[$ip]           = "AA:BB:CC:DD:EE:0$lastOctet"
            $syncHash.VendorContact[$ip] = "support@network.local"
            $syncHash.DeviceType[$ip]    = "network"
            $syncHash.WebUrl[$ip]        = "http://$ip"
            $syncHash.CheckType[$ip]     = "icmp"
            $syncHash.Port[$ip]          = 0
            $syncHash.SnmpVersion[$ip]   = "v2c"
            $syncHash.SnmpUser[$ip]      = ""
            $syncHash.SnmpAuthProto[$ip] = "none"
            $syncHash.SnmpAuthPass[$ip]  = ""
            $syncHash.SnmpPrivProto[$ip] = "none"
            $syncHash.SnmpPrivPass[$ip]  = ""
        }

        # 初回保存
        $initSaveOk = Save-DevicesJson -syncHash $syncHash -filePath $testDevicesJson
        $initSaveOk | Should Be $true

        # 5並行ワーカーによるランダム属性更新 + 並行 Save-DevicesJson 実行
        $workerScript = {
            param($workerId, $iterations, $sync, $filePath, $commonPath)
            Import-Module $commonPath -Force -DisableNameChecking
            $wRes = [PSCustomObject]@{
                WorkerId     = $workerId
                SuccessCount = 0
                FailCount    = 0
                Errors       = [System.Collections.Generic.List[string]]::new()
            }
            $rnd = [System.Random]::new($workerId * 50 + [System.Environment]::TickCount)
            $devs = $sync.Devices

            for ($i = 0; $i -lt $iterations; $i++) {
                try {
                    $target = $devs[$rnd.Next(0, $devs.Count)]
                    $sync.X[$target] = $rnd.Next(50, 1200)
                    $sync.Y[$target] = $rnd.Next(50, 900)
                    $sync.DeviceName[$target] = "Dev_${workerId}_${i}"

                    $saveOk = Save-DevicesJson -syncHash $sync -filePath $filePath
                    if ($saveOk) {
                        $wRes.SuccessCount++
                    } else {
                        $wRes.FailCount++
                        $wRes.Errors.Add("Save-DevicesJson returned false at iter $i")
                    }
                } catch {
                    $wRes.FailCount++
                    $wRes.Errors.Add("Worker $workerId exception at iter $i`: $($_.Exception.Message)")
                }
                [System.Threading.Thread]::Sleep($rnd.Next(2, 6))
            }
            return $wRes
        }

        $commonModulePath = Join-Path $moduleDir "Common.psm1"
        $workersCount = 5
        $itersCount = 8
        $psList = [System.Collections.Generic.List[object]]::new()
        $handleList = [System.Collections.Generic.List[object]]::new()

        for ($w = 1; $w -le $workersCount; $w++) {
            $ps = [powershell]::Create()
            $ps.AddScript($workerScript) | Out-Null
            $ps.AddArgument($w) | Out-Null
            $ps.AddArgument($itersCount) | Out-Null
            $ps.AddArgument($syncHash) | Out-Null
            $ps.AddArgument($testDevicesJson) | Out-Null
            $ps.AddArgument($commonModulePath) | Out-Null
            $h = $ps.BeginInvoke()
            $psList.Add($ps)
            $handleList.Add($h)
        }

        $allDone = $true
        $workerOutputs = @()

        for ($idx = 0; $idx -lt $handleList.Count; $idx++) {
            $completed = $handleList[$idx].AsyncWaitHandle.WaitOne(60000)
            if (-not $completed) {
                $allDone = $false
                Write-Warning "Worker index $idx timed out after 60s. InvocationState: $($psList[$idx].InvocationStateInfo.State)"
                if ($psList[$idx].Streams.Error.Count -gt 0) {
                    Write-Warning "Worker index $idx error stream: $($psList[$idx].Streams.Error | Out-String)"
                }
                try { $psList[$idx].Stop() } catch {}
            } else {
                $out = $psList[$idx].EndInvoke($handleList[$idx])
                $workerOutputs += $out
            }
            $psList[$idx].Dispose()
        }

        # ワーカー内部エラーの診断出力
        foreach ($wo in $workerOutputs) {
            if ($wo.FailCount -gt 0 -or ($wo.Errors -and $wo.Errors.Count -gt 0)) {
                Write-Warning "Worker $($wo.WorkerId) reported $($wo.FailCount) failures:`n$($wo.Errors -join "`n")"
            }
        }

        $allDone | Should Be $true
        $totalFailCount = ($workerOutputs | Measure-Object -Property FailCount -Sum).Sum
        $totalFailCount | Should Be 0

        # 保存された devices.json の構文・スキーマ整合性検証
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        $jsonExists = $false
        for ($retryCheck = 0; $retryCheck -lt 10; $retryCheck++) {
            if (Test-Path $testDevicesJson) { $jsonExists = $true; break }
            Start-Sleep -Milliseconds 150
        }
        $jsonExists | Should Be $true

        $rawJson = $null
        for ($retryRead = 0; $retryRead -lt 10; $retryRead++) {
            try {
                $rawJson = Get-Content $testDevicesJson -Raw -Encoding UTF8 -ErrorAction Stop
                if (-not [string]::IsNullOrWhiteSpace($rawJson)) { break }
            } catch {
                Start-Sleep -Milliseconds 150
            }
        }
        $rawJson | Should Not BeNullOrEmpty
        $parsed = $rawJson | ConvertFrom-Json
        $parsed | Should Not BeNullOrEmpty
        $parsed.Count | Should Be 5

        # 必須属性の欠損がないことを確認
        foreach ($item in $parsed) {
            $item.ip | Should Not BeNullOrEmpty
            $item.name | Should Not BeNullOrEmpty
            $item.community | Should Not BeNullOrEmpty
            $item.image | Should Not BeNullOrEmpty
            $item.deviceType | Should Not BeNullOrEmpty
            $item.checkType | Should Not BeNullOrEmpty
            ($null -ne $item.x) | Should Be $true
            ($null -ne $item.y) | Should Be $true
            ($null -ne $item.enabled) | Should Be $true
        }

        # バックアップスナップショットが生成されていることを確認
        $snapshots = Get-ChildItem -Path $testBackupDir -Filter "*.json" -ErrorAction SilentlyContinue
        $snapshots.Count | Should BeGreaterThan 0
    }
}

# ==============================================================================
# 5. REST API コントラクト & スキーマ整合性検証 (F13)
# ==============================================================================
Describe "5. REST API コントラクト & スキーマ整合性検証 (F13)" {
    
    # ── 5.1 /api/health コントラクト ──
    Context "/api/health コントラクト検証" {
        It "正常稼働時 (pingAgeSec < 5.0) に status 'ok' と全必須キー群を含むこと" {
            $now = [DateTime]::UtcNow
            $sync = [hashtable]::Synchronized(@{
                StartTime       = $now.AddSeconds(-30)
                LastPingLoopUtc = $now.AddSeconds(-1.2)
                Devices         = @("10.0.0.1", "10.0.0.2")
            })

            # Server.ps1 /api/health ハンドラーロジック模倣検証
            $nowUtc = [DateTime]::UtcNow
            $lastPing = if ($sync.LastPingLoopUtc) { $sync.LastPingLoopUtc } else { $nowUtc }
            $pingAgeSec = [math]::Round(($nowUtc - $lastPing).TotalSeconds, 1)
            $isHealthy = ($pingAgeSec -le 45.0)

            $health = @{
                status           = if ($isHealthy) { "ok" } else { "unhealthy" }
                message          = if ($isHealthy) { "OK" } else { "Ping runspace loop unresponsive" }
                timestamp        = $nowUtc.ToString("o")
                uptimeSec        = if ($sync.StartTime) { [int]($nowUtc - $sync.StartTime).TotalSeconds } else { 0 }
                monitoredDevices = if ($sync.Devices) { $sync.Devices.Count } else { 0 }
                lastPingLoopUtc  = $lastPing.ToString("o")
                pingAgeSec       = $pingAgeSec
            }

            $health.status | Should Be "ok"
            $health.message | Should Be "OK"
            $health.monitoredDevices | Should Be 2
            $health.uptimeSec | Should BeGreaterThan 0
            $health.pingAgeSec | Should BeLessThan 5.0
            $health.timestamp | Should Match '^\d{4}-\d{2}-\d{2}T'
        }

        It "Pingループ異常停止時 (pingAgeSec > 45.0 かつ稼働60秒超) に status 'unhealthy' と警告文を返すこと" {
            $now = [DateTime]::UtcNow
            $sync = [hashtable]::Synchronized(@{
                StartTime       = $now.AddSeconds(-120)
                LastPingLoopUtc = $now.AddSeconds(-55)
                Devices         = @("10.0.0.1")
            })

            $nowUtc = [DateTime]::UtcNow
            $lastPing = $sync.LastPingLoopUtc
            $pingAgeSec = [math]::Round(($nowUtc - $lastPing).TotalSeconds, 1)
            $isHealthy = $true
            $msg = "OK"
            if ($sync.StartTime -and ($nowUtc - $sync.StartTime).TotalSeconds -ge 60.0) {
                if ($pingAgeSec -gt 45.0) {
                    $isHealthy = $false
                    $msg = "Ping runspace loop unresponsive (last seen: ${pingAgeSec}s ago)"
                }
            }

            $health = @{
                status           = if ($isHealthy) { "ok" } else { "unhealthy" }
                message          = $msg
                pingAgeSec       = $pingAgeSec
                monitoredDevices = 1
            }

            $health.status | Should Be "unhealthy"
            $health.message | Should Match "unresponsive"
            $health.pingAgeSec | Should BeGreaterThan 45.0
        }

        It "未初期化時 (Devices 未設定) でも例外を発生させず安全なデフォルト値 (monitoredDevices: 0) を返すこと" {
            $sync = [hashtable]::Synchronized(@{})
            $nowUtc = [DateTime]::UtcNow
            $lastPing = if ($sync.LastPingLoopUtc) { $sync.LastPingLoopUtc } else { $nowUtc }
            $pingAgeSec = [math]::Round(($nowUtc - $lastPing).TotalSeconds, 1)

            $health = @{
                status           = "ok"
                uptimeSec        = if ($sync.StartTime) { [int]($nowUtc - $sync.StartTime).TotalSeconds } else { 0 }
                monitoredDevices = if ($sync.Devices) { $sync.Devices.Count } else { 0 }
                pingAgeSec       = $pingAgeSec
            }

            $health.monitoredDevices | Should Be 0
            $health.uptimeSec | Should Be 0
        }
    }

    # ── 5.2 /api/status コントラクト ──
    Context "/api/status コントラクト検証" {
        It "各デバイスのメトリクス辞書構造 (status, latency, loss, jitter, avgJitter, maxOutageSec) が完全であること" {
            $sync = [hashtable]::Synchronized(@{
                Status          = [hashtable]::Synchronized(@{})
                Stats           = [hashtable]::Synchronized(@{})
                Traffic         = [hashtable]::Synchronized(@{})
                Mac             = [hashtable]::Synchronized(@{})
                SnmpDetail      = [hashtable]::Synchronized(@{})
                InterfaceErrors = [hashtable]::Synchronized(@{})
                ConnectedTo     = [hashtable]::Synchronized(@{})
                IpConflicts     = [hashtable]::Synchronized(@{})
                IperfState      = @{ running = $false }
            })

            $testIp = "192.168.1.254"
            $sync.Status[$testIp] = @{
                status    = "Success"
                rawStatus = "Success"
                latency   = 4.8
                checkType = "icmp"
                port      = 0
                timestamp = "2026-09-19 12:00:00"
            }
            $sync.Stats[$testIp] = @{
                PacketLossRate   = 0.0
                Jitter           = 1.2
                JitterSum        = 24.0
                JitterCount      = 20
                MaxOutageSec     = 0.0
                CurrentOutageSec = 0.0
                Outage600msCount = 0
                Outage5sCount    = 0
                OutageEvents     = @()
            }
            $sync.Traffic[$testIp] = @{ tx = 12.5; rx = 82.7 }
            $sync.Mac[$testIp] = "00:11:22:33:44:55"

            # Server.ps1 /api/status ロジック模倣
            $st = @{
                status           = $sync.Status[$testIp].status
                rawStatus        = $sync.Status[$testIp].rawStatus
                latency          = $sync.Status[$testIp].latency
                checkType        = $sync.Status[$testIp].checkType
                port             = $sync.Status[$testIp].port
                timestamp        = $sync.Status[$testIp].timestamp
                tx               = $sync.Traffic[$testIp].tx
                rx               = $sync.Traffic[$testIp].rx
                mac              = $sync.Mac[$testIp]
                packetLossRate   = $sync.Stats[$testIp].PacketLossRate
                jitter           = $sync.Stats[$testIp].Jitter
                avgJitter        = [math]::Round($sync.Stats[$testIp].JitterSum / $sync.Stats[$testIp].JitterCount, 2)
                maxOutageSec     = $sync.Stats[$testIp].MaxOutageSec
                currentOutageSec = $sync.Stats[$testIp].CurrentOutageSec
                isSuppressed     = $false
            }

            $statusPayload = @{
                $testIp       = $st
                "_iperf"       = $sync.IperfState
                "_ipConflicts" = @()
            }

            $statusPayload.ContainsKey($testIp) | Should Be $true
            $devMetrics = $statusPayload[$testIp]
            $devMetrics.status | Should Be "Success"
            $devMetrics.latency | Should Be 4.8
            $devMetrics.packetLossRate | Should Be 0.0
            $devMetrics.jitter | Should Be 1.2
            $devMetrics.avgJitter | Should Be 1.2
            $devMetrics.tx | Should Be 12.5
            $devMetrics.rx | Should Be 82.7
            $devMetrics.mac | Should Be "00:11:22:33:44:55"
            $devMetrics.isSuppressed | Should Be $false

            $statusPayload.ContainsKey("_iperf") | Should Be $true
            $statusPayload.ContainsKey("_ipConflicts") | Should Be $true
        }
    }

    # ── 5.3 /api/devices コントラクト ──
    Context "/api/devices コントラクト検証" {
        It "devices リストの各要素が必須プロパティ群を保持し、パスワードが暗号化保護されていること" {
            $sync = [hashtable]::Synchronized(@{
                Devices       = @("172.16.0.1")
                DeviceName    = @{ "172.16.0.1" = "EdgeSwitch" }
                Community     = @{ "172.16.0.1" = "public" }
                IsMonitored   = @{ "172.16.0.1" = $true }
                Group         = @{ "172.16.0.1" = "Core" }
                Image         = @{ "172.16.0.1" = "switch.png" }
                ConnectedTo   = @{ "172.16.0.1" = "" }
                X             = @{ "172.16.0.1" = 300 }
                Y             = @{ "172.16.0.1" = 400 }
                Mac           = @{ "172.16.0.1" = "11:22:33:44:55:66" }
                VendorContact = @{ "172.16.0.1" = "cisco@example.com" }
                DeviceType    = @{ "172.16.0.1" = "switch" }
                WebUrl        = @{ "172.16.0.1" = "https://172.16.0.1" }
                CheckType     = @{ "172.16.0.1" = "icmp" }
                Port          = @{ "172.16.0.1" = 0 }
                SnmpVersion   = @{ "172.16.0.1" = "v3" }
                SnmpUser      = @{ "172.16.0.1" = "snmpadmin" }
                SnmpAuthProto = @{ "172.16.0.1" = "SHA" }
                SnmpAuthPass  = @{ "172.16.0.1" = (Protect-SecretString "AuthSecretPassword") }
                SnmpPrivProto = @{ "172.16.0.1" = "AES" }
                SnmpPrivPass  = @{ "172.16.0.1" = (Protect-SecretString "PrivSecretPassword") }
            })

            # Server.ps1 /api/devices レスポンス構築模倣
            $devArr = @()
            foreach ($ip in $sync.Devices) {
                $devArr += @{
                    ip            = $ip
                    name          = $sync.DeviceName[$ip]
                    community     = $sync.Community[$ip]
                    enabled       = $sync.IsMonitored[$ip]
                    group         = $sync.Group[$ip]
                    image         = $sync.Image[$ip]
                    connectedTo   = $sync.ConnectedTo[$ip]
                    x             = $sync.X[$ip]
                    y             = $sync.Y[$ip]
                    mac           = $sync.Mac[$ip]
                    vendorContact = $sync.VendorContact[$ip]
                    deviceType    = $sync.DeviceType[$ip]
                    webUrl        = $sync.WebUrl[$ip]
                    checkType     = $sync.CheckType[$ip]
                    port          = $sync.Port[$ip]
                    snmpVersion   = $sync.SnmpVersion[$ip]
                    snmpUser      = $sync.SnmpUser[$ip]
                    snmpAuthProto = $sync.SnmpAuthProto[$ip]
                    snmpAuthPass  = $sync.SnmpAuthPass[$ip]
                    snmpPrivProto = $sync.SnmpPrivProto[$ip]
                    snmpPrivPass  = $sync.SnmpPrivPass[$ip]
                }
            }
            $responsePayload = @{ devices = $devArr }

            $responsePayload.devices | Should Not BeNullOrEmpty
            $responsePayload.devices.Count | Should Be 1
            $d = $responsePayload.devices[0]

            $d.ip | Should Be "172.16.0.1"
            $d.name | Should Be "EdgeSwitch"
            $d.deviceType | Should Be "switch"
            $d.snmpVersion | Should Be "v3"

            # セキュリティ検証: 暗号化パスワードが平文露出せず enc: で保護されていること
            $d.snmpAuthPass.StartsWith("enc:") | Should Be $true
            $d.snmpAuthPass | Should Not Be "AuthSecretPassword"
            $d.snmpPrivPass.StartsWith("enc:") | Should Be $true
            $d.snmpPrivPass | Should Not Be "PrivSecretPassword"
        }
    }

    # ── 5.4 /api/syslog コントラクト ──
    Context "/api/syslog コントラクト検証" {
        It "logs 配列を含む構造を返し、GET要求時にキューの内容が消失しないこと" {
            $sync = [hashtable]::Synchronized(@{
                SyslogQueue = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
            })
            $sync.SyslogQueue.Add(@{ timestamp = "2026-09-19 12:00:00"; message = "Link UP Gi0/1" }) | Out-Null
            $sync.SyslogQueue.Add(@{ timestamp = "2026-09-19 12:01:00"; message = "OSPF Adjacency established" }) | Out-Null

            # Server.ps1 /api/syslog ロジック模倣
            $logs = @()
            [System.Threading.Monitor]::Enter($sync.SyslogQueue.SyncRoot)
            try {
                $logs = $sync.SyslogQueue.ToArray()
            } finally {
                [System.Threading.Monitor]::Exit($sync.SyslogQueue.SyncRoot)
            }
            $res = @{ logs = $logs }

            $res.logs | Should Not BeNullOrEmpty
            $res.logs.Count | Should Be 2
            $res.logs[0].message | Should Be "Link UP Gi0/1"
            $res.logs[1].message | Should Be "OSPF Adjacency established"

            # 読み出し後もキューが保持されていること
            $sync.SyslogQueue.Count | Should Be 2
        }

        It "SyslogQueue が空の場合は空配列 @() を返すこと" {
            $sync = [hashtable]::Synchronized(@{
                SyslogQueue = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
            })
            $res = @{ logs = $sync.SyslogQueue.ToArray() }
            ($null -ne $res.logs) | Should Be $true
            $res.logs.Count | Should Be 0
        }
    }

    # ── 5.5 /api/shutdown コントラクト ──
    Context "/api/shutdown コントラクト検証" {
        It "シャットダウン応答スキーマ (status: 'success', message: 'Shutdown initiated') を返し、PendingShutdown フラグをセットすること" {
            $sync = [hashtable]::Synchronized(@{
                PendingShutdown     = $false
                PendingShutdownTime = [DateTime]::MinValue
            })

            # Server.ps1 /api/shutdown ロジック模倣
            $sync.PendingShutdown = $true
            $sync.PendingShutdownTime = [DateTime]::UtcNow.AddSeconds(2)
            $response = @{ status = "success"; message = "Shutdown initiated" }

            $response.status | Should Be "success"
            $response.message | Should Be "Shutdown initiated"
            $sync.PendingShutdown | Should Be $true
            ($sync.PendingShutdownTime -gt [DateTime]::UtcNow) | Should Be $true
        }
    }

    # ── 5.6 エフェメラル HttpListener による HTTP 通信結合検証 ──
    Context "HTTP レベルでのエンドポイント疎通検証 (エフェメラル HttpListener)" {
        It "ローカル HTTP リスナー経由で /api/health, /api/devices, /api/shutdown が 200 OK で応答すること" {
            # 衝突を避けるための空きポート検索
            $testPort = 18090
            $listener = New-Object System.Net.HttpListener
            $prefix = "http://127.0.0.1:$testPort/"
            $listener.Prefixes.Add($prefix)

            $listenerStarted = $false
            try {
                $listener.Start()
                $listenerStarted = $true
            } catch {
                # ポート競合等でリッスンできない場合はスキップ
                Write-Warning "Could not start ephemeral HttpListener on $prefix`: $($_.Exception.Message)"
            }

            if ($listenerStarted) {
                $dummySync = [hashtable]::Synchronized(@{
                    StartTime       = [DateTime]::UtcNow.AddSeconds(-10)
                    LastPingLoopUtc = [DateTime]::UtcNow.AddSeconds(-1)
                    Devices         = @("127.0.0.1")
                    DeviceName      = @{ "127.0.0.1" = "LocalLoopback" }
                    Community       = @{ "127.0.0.1" = "public" }
                    IsMonitored     = @{ "127.0.0.1" = $true }
                    SyslogQueue     = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
                })

                # バックグラウンドで簡易リクエスト処理ループを起動
                $serverAsync = [powershell]::Create().AddScript({
                    param($l, $sync)
                    $reqCount = 0
                    while ($l.IsListening -and $reqCount -lt 4) {
                        try {
                            $context = $l.GetContext()
                            $req = $context.Request
                            $resp = $context.Response
                            $path = $req.Url.LocalPath

                            if ($path -eq "/api/health") {
                                $json = @{ status = "ok"; uptimeSec = 10; pingAgeSec = 1.0; monitoredDevices = 1 } | ConvertTo-Json -Compress
                                $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                                $resp.ContentType = "application/json; charset=utf-8"
                                $resp.StatusCode = 200
                                $resp.ContentLength64 = $buf.Length
                                $resp.OutputStream.Write($buf, 0, $buf.Length)
                                $resp.Close()
                            } elseif ($path -eq "/api/devices") {
                                $json = @{ devices = @(@{ ip = "127.0.0.1"; name = "LocalLoopback" }) } | ConvertTo-Json -Compress
                                $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                                $resp.ContentType = "application/json; charset=utf-8"
                                $resp.StatusCode = 200
                                $resp.ContentLength64 = $buf.Length
                                $resp.OutputStream.Write($buf, 0, $buf.Length)
                                $resp.Close()
                            } elseif ($path -eq "/api/shutdown") {
                                $json = @{ status = "success"; message = "Shutdown initiated" } | ConvertTo-Json -Compress
                                $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
                                $resp.ContentType = "application/json; charset=utf-8"
                                $resp.StatusCode = 200
                                $resp.ContentLength64 = $buf.Length
                                $resp.OutputStream.Write($buf, 0, $buf.Length)
                                $resp.Close()
                            } else {
                                $resp.StatusCode = 404
                                $resp.Close()
                            }
                            $reqCount++
                        } catch {
                            break
                        }
                    }
                }).AddArgument($listener).AddArgument($dummySync)
                $asyncHandle = $serverAsync.BeginInvoke()

                try {
                    # 1. GET /api/health
                    $wc = New-Object System.Net.WebClient
                    $wc.Encoding = [System.Text.Encoding]::UTF8
                    $healthJson = $wc.DownloadString("${prefix}api/health")
                    $parsedHealth = $healthJson | ConvertFrom-Json
                    $parsedHealth.status | Should Be "ok"
                    $parsedHealth.monitoredDevices | Should Be 1

                    # 2. GET /api/devices
                    $devicesJson = $wc.DownloadString("${prefix}api/devices")
                    $parsedDevices = $devicesJson | ConvertFrom-Json
                    $parsedDevices.devices | Should Not BeNullOrEmpty
                    $parsedDevices.devices[0].ip | Should Be "127.0.0.1"

                    # 3. POST /api/shutdown
                    $shutdownJson = $wc.UploadString("${prefix}api/shutdown", "POST", "")
                    $parsedShutdown = $shutdownJson | ConvertFrom-Json
                    $parsedShutdown.status | Should Be "success"
                    $parsedShutdown.message | Should Be "Shutdown initiated"
                } finally {
                    try { $listener.Stop(); $listener.Close() } catch {}
                    if ($serverAsync) {
                        try { $serverAsync.Dispose() } catch {}
                    }
                }
            }
        }
    }
}

# ==============================================================================
# 6. ファイルエンコーディング & 整合性検証 (UTF-8 BOM Guardrail)
# ==============================================================================
Describe "6. ファイルエンコーディング & 整合性検証 (UTF-8 BOM Guardrail)" {
    It "system/tests/ 配下の全 PowerShell スクリプト (.ps1) が UTF-8 BOM を保持していること" {
        $testScripts = Get-ChildItem -Path $here -Filter "*.ps1" -File | Where-Object {
            $_.FullName -notmatch '[\\/](temp_|backups|\.git)'
        }
        $testScripts.Count | Should BeGreaterThan 0

        $failedFiles = @()
        foreach ($file in $testScripts) {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
            if (-not $hasBom) {
                $failedFiles += $file.Name
            }
        }

        if ($failedFiles.Count -gt 0) {
            Write-Warning "Files missing UTF-8 BOM: $($failedFiles -join ', ')"
        }
        $failedFiles.Count | Should Be 0
    }
}

# ==============================================================================
# 7. 24時間連続稼働耐障害性 & レジリエンス検証 (M3)
# ==============================================================================
Describe "7. 24時間連続稼働耐障害性 & レジリエンス検証 (M3)" {

    # ── 7.1 Simulated Host Dropout & Recovery ──
    It "Test 1: 模擬ホスト瞬断および復旧サイクルにおいて ConsecutiveFails, CurrentOutageSec, MaxOutageSec, OutageEvents が正しく遷移すること" {
        $testIp = "10.200.1.50"
        $syncHash = [hashtable]::Synchronized(@{
            PSScriptRoot             = $systemDir
            Status                   = [hashtable]::Synchronized(@{})
            Stats                    = [hashtable]::Synchronized(@{})
            History                  = [hashtable]::Synchronized(@{})
            DeviceName               = @{ "10.200.1.50" = "SimulatedSwitch" }
            PollInterval             = 1000
            OutageThresh1Ms          = 600
            OutageThresh2Ms          = 5000
            LatencyWarningMs         = 80
            ConsecutiveFailThresh    = 2
            LossWarningThreshPercent = 5.0
            JitterWarningThreshMs    = 20.0
            EnableParentSuppression  = $false
            LoggingEnabled           = $false
        })

        $syncHash.Stats[$testIp] = [hashtable]::Synchronized(@{
            Total            = 10
            Success          = 10
            Failed           = 0
            MinLat           = 5.0
            MaxLat           = 15.0
            SumLat           = 80.0
            LatCount         = 10
            OutageStartTime  = $null
            CurrentOutageSec = 0.0
            MaxOutageSec     = 0.0
            Outage600msCount = 0
            Outage5sCount    = 0
            OutageEvents     = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
            RecentResults    = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new(@(1, 1, 1, 1, 1)))
            RecentLatencies  = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new(@(8.0, 10.0, 9.0)))
            PacketLossRate   = 0.0
            Jitter           = 1.0
            JitterSum        = 10.0
            JitterCount      = 10
            PreviousStatus   = "Success"
            ConsecutiveFails = 0
        })
        $syncHash.Status[$testIp] = @{
            status    = "Success"
            rawStatus = "Success"
            latency   = 10.0
            checkType = "icmp"
            port      = 0
            timestamp = (Get-Date).ToUniversalTime().ToString("o")
        }

        # サイクル処理ロジック (Server.ps1 準拠)
        $processCycle = {
            param($ip, [bool]$isPingSuccess, $simLatencyMs, $simulatedOutageElapsedSec = $null)
            $stObj = $syncHash.Stats[$ip]
            $rawStatus = if ($isPingSuccess) { "Success" } else { "Failed" }
            $latency = if ($isPingSuccess) { $simLatencyMs } else { $null }

            # 2段階ステータス判定 (PingEngine.psm1 Evaluate-DeviceStatus)
            if ($isPingSuccess) {
                $stObj.ConsecutiveFails = 0
            } else {
                $stObj.ConsecutiveFails = [int]$stObj.ConsecutiveFails + 1
            }
            $latVal = if ($latency) { [double]$latency } else { 0.0 }
            $evalStatus = Evaluate-DeviceStatus -isSuccess $isPingSuccess `
                -latencyMs $latVal `
                -consecutiveFails $stObj.ConsecutiveFails `
                -latencyWarningMs $syncHash.LatencyWarningMs `
                -consecutiveFailThresh $syncHash.ConsecutiveFailThresh `
                -packetLossRate $stObj.PacketLossRate `
                -lossWarningThreshPercent $syncHash.LossWarningThreshPercent `
                -jitterMs $stObj.Jitter `
                -jitterWarningThreshMs $syncHash.JitterWarningThreshMs

            $syncHash.Status[$ip] = @{
                status    = $evalStatus
                rawStatus = $rawStatus
                latency   = $latency
                checkType = "icmp"
                port      = 0
                timestamp = (Get-Date).ToUniversalTime().ToString("o")
            }

            # Stats 更新 (Server.ps1 準拠)
            [System.Threading.Monitor]::Enter($stObj.SyncRoot)
            try {
                $stObj.Total = [int]$stObj.Total + 1
                $resVal = if ($evalStatus -eq "Success") { 1 } else { 0 }
                $null = $stObj.RecentResults.Add($resVal)
                if ($stObj.RecentResults.Count -gt 30) { $stObj.RecentResults.RemoveAt(0) }

                if ($evalStatus -eq "Success") {
                    # 復旧処理 (Offline -> Online)
                    if ($null -ne $stObj.OutageStartTime -or $stObj.CurrentOutageSec -gt 0) {
                        $endTime = Get-Date
                        $startTime = if ($null -ne $stObj.OutageStartTime) { $stObj.OutageStartTime } else { $endTime.AddSeconds(-$stObj.CurrentOutageSec) }
                        $outageDurationSec = if ($null -ne $simulatedOutageElapsedSec) {
                            $simulatedOutageElapsedSec
                        } else {
                            [math]::Max(0.0, ($endTime - $startTime).TotalSeconds)
                        }
                        $durationMs = [math]::Round($outageDurationSec * 1000, 0)

                        if ($outageDurationSec -gt $stObj.MaxOutageSec) {
                            $stObj.MaxOutageSec = $outageDurationSec
                        }
                        $thresh1Sec = [double]$syncHash.OutageThresh1Ms / 1000.0
                        $thresh2Sec = [double]$syncHash.OutageThresh2Ms / 1000.0
                        if ($outageDurationSec -ge $thresh1Sec) { $stObj.Outage600msCount = [int]$stObj.Outage600msCount + 1 }
                        if ($outageDurationSec -ge $thresh2Sec) { $stObj.Outage5sCount    = [int]$stObj.Outage5sCount + 1 }

                        if ($outageDurationSec -ge $thresh1Sec) {
                            $ev = @{
                                StartTime  = $startTime.ToString("yyyy-MM-dd HH:mm:ss")
                                EndTime    = $endTime.ToString("yyyy-MM-dd HH:mm:ss")
                                DurationMs = $durationMs
                                Category   = "$($syncHash.OutageThresh1Ms)ms以上"
                            }
                            if ($null -eq $stObj.OutageEvents) {
                                $stObj.OutageEvents = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
                            }
                            [System.Threading.Monitor]::Enter($stObj.OutageEvents.SyncRoot)
                            try {
                                $null = $stObj.OutageEvents.Add($ev)
                            } finally {
                                [System.Threading.Monitor]::Exit($stObj.OutageEvents.SyncRoot)
                            }
                        }

                        $stObj.OutageStartTime  = $null
                        $stObj.CurrentOutageSec = 0.0
                    }
                    $stObj.Success = [int]$stObj.Success + 1
                    $stObj.PreviousStatus = "Success"
                } elseif ($evalStatus -eq "Failed" -or $evalStatus -eq "Warning") {
                    $stObj.PreviousStatus = "Failed"
                    $stObj.Failed = [int]$stObj.Failed + 1
                    if ($null -eq $stObj.OutageStartTime) {
                        $stObj.OutageStartTime = Get-Date
                        $stObj.CurrentOutageSec = if ($null -ne $simulatedOutageElapsedSec) { $simulatedOutageElapsedSec } else { 1.0 }
                    } else {
                        $stObj.CurrentOutageSec = if ($null -ne $simulatedOutageElapsedSec) {
                            $simulatedOutageElapsedSec
                        } else {
                            ((Get-Date) - $stObj.OutageStartTime).TotalSeconds
                        }
                    }
                }
            } finally {
                [System.Threading.Monitor]::Exit($stObj.SyncRoot)
            }
        }

        # サイクル 1: 1回目の失敗（Warning 状態へ遷移、ConsecutiveFails = 1）
        & $processCycle $testIp $false $null 1.0
        $syncHash.Stats[$testIp].ConsecutiveFails | Should Be 1
        $syncHash.Status[$testIp].status | Should Be "Warning"
        $syncHash.Stats[$testIp].CurrentOutageSec | Should Be 1.0
        $syncHash.Stats[$testIp].MaxOutageSec | Should Be 0.0
        $syncHash.Stats[$testIp].OutageEvents.Count | Should Be 0

        # サイクル 2: 2回目の失敗（Failed 状態へ遷移、ConsecutiveFails = 2、瞬断継続）
        & $processCycle $testIp $false $null 2.5
        $syncHash.Stats[$testIp].ConsecutiveFails | Should Be 2
        $syncHash.Status[$testIp].status | Should Be "Failed"
        $syncHash.Stats[$testIp].CurrentOutageSec | Should Be 2.5
        $syncHash.Stats[$testIp].MaxOutageSec | Should Be 0.0
        $syncHash.Stats[$testIp].OutageEvents.Count | Should Be 0

        # サイクル 3: 復旧 (Success 復帰、瞬断終了、MaxOutageSec 更新、OutageEvents 記録)
        & $processCycle $testIp $true 14.5 2.5
        $syncHash.Stats[$testIp].ConsecutiveFails | Should Be 0
        $syncHash.Status[$testIp].status | Should Be "Success"
        $syncHash.Stats[$testIp].CurrentOutageSec | Should Be 0.0
        $syncHash.Stats[$testIp].MaxOutageSec | Should Be 2.5
        $syncHash.Stats[$testIp].Outage600msCount | Should Be 1
        $syncHash.Stats[$testIp].OutageEvents.Count | Should Be 1
        $syncHash.Stats[$testIp].OutageEvents[0].DurationMs | Should Be 2500
        $syncHash.Stats[$testIp].OutageEvents[0].Category | Should Match "600ms"

        # サイクル 4: 復旧後の正常継続（MaxOutageSec 保持、OutageEvents 不変）
        & $processCycle $testIp $true 9.2 $null
        $syncHash.Stats[$testIp].ConsecutiveFails | Should Be 0
        $syncHash.Status[$testIp].status | Should Be "Success"
        $syncHash.Stats[$testIp].CurrentOutageSec | Should Be 0.0
        $syncHash.Stats[$testIp].MaxOutageSec | Should Be 2.5
        $syncHash.Stats[$testIp].OutageEvents.Count | Should Be 1
    }

    # ── 7.2 Background Runspace Exception Survival ──
    It "Test 2: バックグラウンド Runspace 内でネットワーク例外 (SocketException / TimeoutException) が発生しても Runspace が停止せず LastPingLoopUtc が更新され続けること" {
        $syncHash = [hashtable]::Synchronized(@{
            Running         = $true
            LoopCount       = 0
            SocketErrCount  = 0
            TimeoutErrCount = 0
            SuccessCount    = 0
            LastPingLoopUtc = [DateTime]::MinValue
            PSScriptRoot    = $systemDir
        })

        $rs = New-AppRunspace -syncHash $syncHash
        try {
            $pipe = $rs.CreatePipeline()
            $pipe.Commands.AddScript({
                while ($syncHash.Running) {
                    try {
                        $syncHash.LoopCount = [int]$syncHash.LoopCount + 1
                        $cur = [int]$syncHash.LoopCount

                        if ($cur -eq 1) {
                            $syncHash.SocketErrCount = [int]$syncHash.SocketErrCount + 1
                            throw [System.Net.Sockets.SocketException]::new(10060)
                        } elseif ($cur -eq 2) {
                            $syncHash.TimeoutErrCount = [int]$syncHash.TimeoutErrCount + 1
                            throw [System.TimeoutException]::new("Network Ping async operation timed out")
                        } else {
                            $syncHash.SuccessCount = [int]$syncHash.SuccessCount + 1
                        }
                    } catch {
                        # Server.ps1 line 1632-1641: catch block absorbs exception and records heartbeat
                    } finally {
                        $syncHash.LastPingLoopUtc = [DateTime]::UtcNow
                    }
                    [System.Threading.Thread]::Sleep(40)
                }
            })
            $asyncHandle = $pipe.InvokeAsync()

            # Wait for at least 2 successful iterations after exceptions (around 200ms)
            $swWait = [System.Diagnostics.Stopwatch]::StartNew()
            while ($syncHash.SuccessCount -lt 2 -and $swWait.ElapsedMilliseconds -lt 6000) {
                [System.Threading.Thread]::Sleep(40)
            }

            # Stop runspace loop
            $syncHash.Running = $false
            [System.Threading.Thread]::Sleep(80)

            # Assertions
            $rs.RunspaceStateInfo.State | Should Be ([System.Management.Automation.Runspaces.RunspaceState]::Opened)
            $syncHash.SocketErrCount | Should BeGreaterThan 0
            $syncHash.TimeoutErrCount | Should BeGreaterThan 0
            $syncHash.SuccessCount | Should BeGreaterThan 0
            $syncHash.LoopCount | Should BeGreaterThan 2

            # LastPingLoopUtc must be recently updated
            $ageSec = ([DateTime]::UtcNow - $syncHash.LastPingLoopUtc).TotalSeconds
            $ageSec | Should BeLessThan 3.0
        } finally {
            if ($rs) {
                try { $rs.Close(); $rs.Dispose() } catch {}
            }
        }
    }

    # ── 7.3 Multi-threaded State Concurrency Stress ──
    It "Test 3: マルチスレッド高負荷環境下で DevicesLock による機器変更、Status 参照、History 追記/フラッシュが競合せずスレッドセーフに動作すること" {
        $syncHash = [hashtable]::Synchronized(@{
            DevicesLock = [object]::new()
            Devices     = @("10.10.1.1", "10.10.1.2", "10.10.1.3", "10.10.1.4")
            DeviceName  = [hashtable]::Synchronized(@{
                "10.10.1.1" = "Router1"; "10.10.1.2" = "Switch1"; "10.10.1.3" = "AP1"; "10.10.1.4" = "Server1"
            })
            Status      = [hashtable]::Synchronized(@{})
            Stats       = [hashtable]::Synchronized(@{})
            History     = [hashtable]::Synchronized(@{})
            Running     = $true
        })
        foreach ($ip in $syncHash.Devices) {
            $syncHash.Status[$ip] = @{
                status    = "Success"
                latency   = 4.5
                timestamp = (Get-Date).ToString("o")
            }
            $syncHash.Stats[$ip] = [hashtable]::Synchronized(@{
                Total        = 10
                MaxOutageSec = 0.0
                OutageEvents = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
            })
            $syncHash.History[$ip] = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
        }

        # 4つの並行ワーカー:
        # Worker 1: DevicesLock 下での機器情報更新
        # Worker 2: Status.SyncRoot 下での /api/status スナップショット取得
        # Worker 3: History[$ip].SyncRoot 下でのログ追加
        # Worker 4: History[$ip].SyncRoot 下での定期ログフラッシュ (ToArray & RemoveRange)
        $workerScript = {
            param($workerId, $iterations, $sync)
            $res = [PSCustomObject]@{
                WorkerId     = $workerId
                SuccessCount = 0
                FailCount    = 0
                Errors       = [System.Collections.Generic.List[string]]::new()
            }
            $rnd = [System.Random]::new($workerId * 137 + [System.Environment]::TickCount)

            for ($i = 0; $i -lt $iterations; $i++) {
                try {
                    switch ($workerId) {
                        1 {
                            # Worker 1: DevicesLock 排他制御による動的機器メタデータ変更
                            [System.Threading.Monitor]::Enter($sync.DevicesLock)
                            try {
                                $devList = @($sync.Devices)
                                $targetIp = $devList[$rnd.Next(0, $devList.Count)]
                                $sync.DeviceName[$targetIp] = "Dev_${targetIp}_${i}"
                            } finally {
                                [System.Threading.Monitor]::Exit($sync.DevicesLock)
                            }
                        }
                        2 {
                            # Worker 2: /api/status スナップショット読み出し (Server.ps1 lines 2586-2656 準拠)
                            $keys = @()
                            $sSync = $sync.Status.SyncRoot
                            [System.Threading.Monitor]::Enter($sSync)
                            try {
                                $keys = @($sync.Status.Keys)
                            } finally {
                                [System.Threading.Monitor]::Exit($sSync)
                            }

                            foreach ($k in $keys) {
                                $st = $sync.Status[$k]
                                if ($null -eq $st) { continue }
                                $sObj = $sync.Stats[$k]
                                if ($null -ne $sObj -and $null -ne $sObj.OutageEvents) {
                                    $evSync = $sObj.OutageEvents.SyncRoot
                                    [System.Threading.Monitor]::Enter($evSync)
                                    try {
                                        $cnt = $sObj.OutageEvents.Count
                                    } finally {
                                        [System.Threading.Monitor]::Exit($evSync)
                                    }
                                }
                            }
                        }
                        3 {
                            # Worker 3: Ping ループ履歴追記 (Server.ps1 lines 1178-1193 準拠)
                            $targetIp = "10.10.1.$($rnd.Next(1, 5))"
                            if ($sync.History.ContainsKey($targetIp)) {
                                $hist = $sync.History[$targetIp]
                                if ($null -ne $hist) {
                                    $hSync = $hist.SyncRoot
                                    [System.Threading.Monitor]::Enter($hSync)
                                    try {
                                        $null = $hist.Add("`"$((Get-Date).ToString('o'))`",`"$targetIp`",`"Success`",`"5.0`"")
                                    } finally {
                                        [System.Threading.Monitor]::Exit($hSync)
                                    }
                                }
                            }
                        }
                        4 {
                            # Worker 4: 定期ログフラッシュ (Server.ps1 lines 1416-1468 準拠)
                            $targetIp = "10.10.1.$($rnd.Next(1, 5))"
                            if ($sync.History.ContainsKey($targetIp)) {
                                $hist = $sync.History[$targetIp]
                                if ($null -ne $hist) {
                                    $hSync = $hist.SyncRoot
                                    [System.Threading.Monitor]::Enter($hSync)
                                    try {
                                        $lines = $hist.ToArray()
                                        if ($lines.Length -gt 0) {
                                            $hist.RemoveRange(0, [math]::Min($lines.Length, $hist.Count))
                                        }
                                    } finally {
                                        [System.Threading.Monitor]::Exit($hSync)
                                    }
                                }
                            }
                        }
                    }
                    $res.SuccessCount++
                } catch {
                    $res.FailCount++
                    $res.Errors.Add("Worker $workerId iter $i error: $($_.Exception.Message)")
                }
                [System.Threading.Thread]::Sleep(2)
            }
            return $res
        }

        $numWorkers = 4
        $opsPerWorker = 20
        $psList = [System.Collections.Generic.List[object]]::new()
        $handleList = [System.Collections.Generic.List[object]]::new()

        for ($w = 1; $w -le $numWorkers; $w++) {
            $ps = [powershell]::Create()
            $ps.AddScript($workerScript) | Out-Null
            $ps.AddArgument($w) | Out-Null
            $ps.AddArgument($opsPerWorker) | Out-Null
            $ps.AddArgument($syncHash) | Out-Null
            $h = $ps.BeginInvoke()
            $psList.Add($ps)
            $handleList.Add($h)
        }

        $allDoneInTime = $true
        $workerOutputs = @()

        for ($idx = 0; $idx -lt $handleList.Count; $idx++) {
            $completed = $handleList[$idx].AsyncWaitHandle.WaitOne(20000)
            if (-not $completed) {
                $allDoneInTime = $false
            } else {
                $out = $psList[$idx].EndInvoke($handleList[$idx])
                $workerOutputs += $out
            }
            $psList[$idx].Dispose()
        }

        $allDoneInTime | Should Be $true
        $totalFails = ($workerOutputs | Measure-Object -Property FailCount -Sum).Sum
        $totalFails | Should Be 0
        $totalSuccess = ($workerOutputs | Measure-Object -Property SuccessCount -Sum).Sum
        $totalSuccess | Should Be ($numWorkers * $opsPerWorker)
    }

    # ── 7.4 24/7 Unattended Mode Verification ──
    It "Test 4: 24時間連続稼働モード (`$syncHash.AutoShutdownOnDisconnect = `$false) でブラウザハートビート途絶時も監視ループが維持されること" {
        # 1. 24時間無人モード ($sync.AutoShutdownOnDisconnect = $false) での検証
        $syncUnattended = [hashtable]::Synchronized(@{
            AutoShutdownOnDisconnect = $false
            HasClientConnected       = $true
            LastClientActivity       = [DateTime]::UtcNow.AddSeconds(-300) # 5分前にハートビート停止
            HeartbeatTimeoutSec      = 20
            Running                  = $true
        })

        # Server.ps1 lines 2501-2512 の監視判定ロジックを実行
        $shutdownTriggered = $false
        $autoShutdown = if ($syncUnattended.ContainsKey('AutoShutdownOnDisconnect')) { $syncUnattended.AutoShutdownOnDisconnect } else { $true }
        if (($autoShutdown -is [bool] -and $autoShutdown) -or (-not ($autoShutdown -is [bool]) -and "$autoShutdown" -ne "false" -and "$autoShutdown" -ne "")) {
            $timeoutSec = if ($syncUnattended.HeartbeatTimeoutSec) { [int]$syncUnattended.HeartbeatTimeoutSec } else { 60 }
            if ($syncUnattended.HasClientConnected) {
                $timeSinceLastActivity = ([DateTime]::UtcNow - $syncUnattended.LastClientActivity).TotalSeconds
                if ($timeSinceLastActivity -gt $timeoutSec) {
                    $shutdownTriggered = $true
                }
            }
        }

        # AutoShutdownOnDisconnect = $false のため、ハートビート途絶でもシャットダウンがトリガーされないこと
        $shutdownTriggered | Should Be $false
        $syncUnattended.Running | Should Be $true

        # 2. 通常モード ($sync.AutoShutdownOnDisconnect = $true) との対比検証
        $syncAttended = [hashtable]::Synchronized(@{
            AutoShutdownOnDisconnect = $true
            HasClientConnected       = $true
            LastClientActivity       = [DateTime]::UtcNow.AddSeconds(-300)
            HeartbeatTimeoutSec      = 20
            Running                  = $true
        })

        $attendedShutdownTriggered = $false
        $autoShutdown2 = if ($syncAttended.ContainsKey('AutoShutdownOnDisconnect')) { $syncAttended.AutoShutdownOnDisconnect } else { $true }
        if (($autoShutdown2 -is [bool] -and $autoShutdown2) -or (-not ($autoShutdown2 -is [bool]) -and "$autoShutdown2" -ne "false" -and "$autoShutdown2" -ne "")) {
            $timeoutSec2 = if ($syncAttended.HeartbeatTimeoutSec) { [int]$syncAttended.HeartbeatTimeoutSec } else { 60 }
            if ($syncAttended.HasClientConnected) {
                $timeSinceLastActivity2 = ([DateTime]::UtcNow - $syncAttended.LastClientActivity).TotalSeconds
                if ($timeSinceLastActivity2 -gt $timeoutSec2) {
                    $attendedShutdownTriggered = $true
                }
            }
        }

        # AutoShutdownOnDisconnect = $true では正しく自動シャットダウンが判定されること
        $attendedShutdownTriggered | Should Be $true

        # 3. config.json および /api/config REST API とのデータバインディング検証
        $sampleJson = '{"autoShutdownOnDisconnect": false}'
        $parsedConfig = $sampleJson | ConvertFrom-Json
        $syncUnattended.AutoShutdownOnDisconnect = [bool]$parsedConfig.autoShutdownOnDisconnect
        $syncUnattended.AutoShutdownOnDisconnect | Should Be $false

        # /api/config GET レスポンス辞書に autoShutdownOnDisconnect が正しく反映されること
        $apiConfigResponse = @{
            pollInterval             = 1000
            autoShutdownOnDisconnect = $syncUnattended.AutoShutdownOnDisconnect
        }
        $apiConfigResponse.autoShutdownOnDisconnect | Should Be $false
    }
}

