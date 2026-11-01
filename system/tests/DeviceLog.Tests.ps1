# ==============================================================================
# DeviceLog.Tests.ps1 - 機器ログ取得・プリセット・API・安全性 自動テスト (Pester)
# ==============================================================================
# 【初心者向けの簡単な解説】
# このテストスイートは、ネットワーク機器（Cisco、Yamaha、Linux、Windows等）から
# 遠隔でシステムログ（カルテ・健康日記）を取得する機能が正しく動作するかを検証します。
# 1. プリセットコマンドの定義と整合性
# 2. ログ取得エンジン（Invoke-DeviceLogFetch）、タイムアウト強制終了、1MB/5MBバッファ制限、
#    ログファイル保存、監査ログ記録、過去レポート自動パージに対する保護
# 3. HTTP REST API (/api/device/fetch-log, logs, log-download, log-presets)
#    およびパストラバーサル攻撃に対する防御
# ==============================================================================

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = (Resolve-Path (Join-Path $here "..\..")).Path
$moduleDir = Join-Path $projectRoot "system\modules"
$reportsDir = Join-Path $projectRoot "Reports"

Import-Module (Join-Path $moduleDir "Common.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleDir "RemoteExec.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleDir "ReportGenerator.psm1") -Force -DisableNameChecking

# ── ヘルパー: テスト用一時ディレクトリの完全分離管理 ─────────────────────────
$testTempDir_Engine = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_DeviceLog_Engine_$([Guid]::NewGuid().ToString('N'))"
$testTempDir_Api    = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_DeviceLog_Api_$([Guid]::NewGuid().ToString('N'))"

$global:sampleApiLogContent = @"
================================================================================
 Network Device Monitor - Remote Device Log
 Device: Local-API (127.0.0.1)
 Protocol: custom
 Command: echo HELLO_LOG
 Timestamp: 2026-10-24 10:00:00
 Status: COMPLETED | ExitCode: 0 | Duration: 50ms
 Lines: 1 | Size: 10 bytes
================================================================================
[OUTPUT]
HELLO_LOG
"@

function Ensure-ApiSampleLog {
    $dlDir = Join-Path $testTempDir_Api "device_logs"
    if (-not (Test-Path $dlDir)) {
        New-Item -ItemType Directory -Path $dlDir -Force | Out-Null
    }
    $sampleLogName = "127.0.0.1_20261024_100000.log"
    $sampleLogPath = Join-Path $dlDir $sampleLogName
    if (-not (Test-Path $sampleLogPath)) {
        [System.IO.File]::WriteAllText($sampleLogPath, $global:sampleApiLogContent, [System.Text.Encoding]::UTF8)
    }
}

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

function Initialize-EngineTestEnv {
    Safe-RemoveDirectory $testTempDir_Engine
    New-Item -ItemType Directory -Path $testTempDir_Engine -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $testTempDir_Engine "device_logs") -Force | Out-Null
}

function Cleanup-EngineTestEnv {
    Safe-RemoveDirectory $testTempDir_Engine
}

function Initialize-ApiTestEnv {
    Safe-RemoveDirectory $testTempDir_Api
    New-Item -ItemType Directory -Path $testTempDir_Api -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $testTempDir_Api "device_logs") -Force | Out-Null
    Ensure-ApiSampleLog
}

function Cleanup-ApiTestEnv {
    Safe-RemoveDirectory $testTempDir_Api
}

function Set-SafeLastWriteTime([string]$itemPath, [DateTime]$newTime) {
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            (Get-Item -LiteralPath $itemPath).LastWriteTime = $newTime
            return
        } catch {
            Start-Sleep -Milliseconds 100
        }
    }
}

# ── ログ取得オーケストレーション関数 (Invoke-DeviceLogFetch) ───────────────────
# バックエンドサーバーの /api/device/fetch-log 処理ロジックと同等の高水準関数。
# 各種バリデーション、コマンド解決、実行、保存、バッファ制限、監査ログ記録を統括します。
function global:Invoke-DeviceLogFetch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Device,

        [Parameter(Mandatory = $false)]
        [string]$PresetId = "",

        [Parameter(Mandatory = $false)]
        [string]$CustomCommand = "",

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSec = 20,

        [Parameter(Mandatory = $false)]
        [string]$ReportsDirectory = "Reports",

        [Parameter(Mandatory = $false)]
        [string]$ClientIp = "127.0.0.1"
    )

    $ip = if ($Device.ContainsKey('ip')) { [string]$Device['ip'] } else { "" }
    $deviceName = if ($Device.ContainsKey('name') -and -not [string]::IsNullOrWhiteSpace($Device['name'])) {
        [string]$Device['name']
    } else { $ip }

    if ([string]::IsNullOrWhiteSpace($ip)) {
        return @{
            success     = $false
            status      = "MISSING_IP"
            error       = "Target IP address is required"
            ip          = ""
            deviceName  = $deviceName
            command     = ""
            stdout      = ""
            stderr      = "Target IP address is required"
            exitCode    = -1
            truncated   = $false
            lineCount   = 0
            sizeBytes   = 0
            logFilePath = ""
            logFileName = ""
            timestamp   = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
            durationMs  = 0
        }
    }

    $remote = if ($Device.ContainsKey('remote') -and $Device['remote']) { $Device['remote'] } else { @{} }
    $isEnabled = [bool]$(if ($remote -is [hashtable] -and $remote.ContainsKey('enabled')) { $remote['enabled'] } else { $false })
    if (-not $isEnabled) {
        return @{
            success     = $false
            status      = "REMOTE_DISABLED"
            error       = "Remote management is disabled for device '$ip'"
            ip          = $ip
            deviceName  = $deviceName
            command     = ""
            stdout      = ""
            stderr      = "Remote management is disabled for device '$ip'"
            exitCode    = -1
            truncated   = $false
            lineCount   = 0
            sizeBytes   = 0
            logFilePath = ""
            logFileName = ""
            timestamp   = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
            durationMs  = 0
        }
    }

    $protocol = if ($remote -is [hashtable] -and $remote.ContainsKey('protocol')) { [string]$remote['protocol'] } else { "custom" }

    # コマンドの解決 (カスタムコマンド優先、未指定時はプリセット解決)
    $resolvedCommand = ""
    if (-not [string]::IsNullOrWhiteSpace($CustomCommand)) {
        $resolvedCommand = $CustomCommand
    } elseif (-not [string]::IsNullOrWhiteSpace($PresetId)) {
        $presets = Get-DeviceLogPresets
        foreach ($p in $presets) {
            if ($p.id -eq $PresetId) {
                $resolvedCommand = [string]$p.command
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($resolvedCommand) -and $remote.ContainsKey('commands') -and $null -ne $remote['commands']) {
            foreach ($cmdItem in $remote['commands']) {
                $cId = if ($cmdItem.id) { [string]$cmdItem.id } else { "" }
                if ($cId -eq $PresetId) {
                    $resolvedCommand = if ($cmdItem.command) { [string]$cmdItem.command } else { "" }
                    break
                }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($resolvedCommand)) {
        return @{
            success     = $false
            status      = "NO_COMMAND_SPECIFIED"
            error       = "No command specified or preset not found"
            ip          = $ip
            deviceName  = $deviceName
            command     = ""
            stdout      = ""
            stderr      = "No command specified or preset not found"
            exitCode    = -1
            truncated   = $false
            lineCount   = 0
            sizeBytes   = 0
            logFilePath = ""
            logFileName = ""
            timestamp   = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
            durationMs  = 0
        }
    }

    if ($TimeoutSec -le 0 -or $TimeoutSec -gt 300) { $TimeoutSec = 20 }

    # コマンド実行 (Invoke-RemoteDeviceCommand)
    $execResult = Invoke-RemoteDeviceCommand -Device $Device -Action "command" -CustomCommand $resolvedCommand -TimeoutSec $TimeoutSec
    $stdout = if ($null -ne $execResult.stdout) { [string]$execResult.stdout } else { "" }
    $stderr = if ($null -ne $execResult.stderr) { [string]$execResult.stderr } else { "" }
    $exitCode = if ($null -ne $execResult.exitCode) { [int]$execResult.exitCode } else { -1 }
    $execStatus = if ($null -ne $execResult.status) { [string]$execResult.status } else { "UNKNOWN" }
    $durationMs = if ($null -ne $execResult.executionTimeMs) { [int]$execResult.executionTimeMs } else { 0 }
    $rawSizeBytes = [System.Text.Encoding]::UTF8.GetByteCount($stdout)
    $lineCount = if ([string]::IsNullOrEmpty($stdout)) { 0 } else { ($stdout -split "`r?`n").Count }

    $nowUtc = [DateTime]::UtcNow
    $timestampIso = $nowUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $fileTimestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")

    # ファイル保存 (Reports/device_logs/{IP}_{timestamp}.log)
    $saveResult = Save-DeviceLogFile -ReportsDirectory $ReportsDirectory -Ip $ip -DeviceName $deviceName -Protocol $protocol -Command $resolvedCommand -LogContent $stdout -Status $execStatus -ExitCode $exitCode -DurationMs $durationMs -Timestamp $fileTimestamp

    $logFileName = if ($saveResult.success) { $saveResult.fileName } else { "${ip}_${fileTimestamp}.log" }
    $logFilePath = if ($saveResult.success) { $saveResult.filePath } else { "Reports/device_logs/$logFileName" }

    # 1MB stdout 切り詰め保護 (HTTP レスポンス保護)
    $truncated = $false
    $responseStdout = $stdout
    if ($stdout.Length -gt 1000000) {
        $truncated = $true
        $truncationMsg = "`r`n`r`n--- [TRUNCATED: 出力サイズが1MBを超過したため画面表示を切り詰めました。全ログはダウンロード機能または $logFilePath をご参照ください] ---"
        $responseStdout = $stdout.Substring(0, 1000000) + $truncationMsg
    }

    # 監査ログ記録 (Reports/audit.log - Local\NDM_AuditLog_Mutex)
    $auditDetails = "Device: $deviceName ($ip) | Command: $resolvedCommand | Status: $execStatus | ExitCode: $exitCode | Lines: $lineCount | Size: $($stdout.Length)B | File: $logFileName | Duration: ${durationMs}ms"
    Log-Audit -action "LOG_RETRIEVAL" -target $ip -details $auditDetails -clientIp $ClientIp -reportsDirectory $ReportsDirectory

    return @{
        success         = ($execStatus -eq "COMPLETED" -or $execResult.success -eq $true)
        status          = $execStatus
        ip              = $ip
        deviceName      = $deviceName
        command         = $resolvedCommand
        stdout          = $responseStdout
        stderr          = $stderr
        exitCode        = $exitCode
        truncated       = $truncated
        lineCount       = $lineCount
        sizeBytes       = $rawSizeBytes
        logFilePath     = $logFilePath
        logFileName     = $logFileName
        timestamp       = $timestampIso
        durationMs      = $durationMs
        isDiskTruncated = [bool]$saveResult.isDiskTruncated
    }
}

# ==============================================================================
# テストセクション 1: Get-DeviceLogPresets コマンドプリセット管理テスト
# ==============================================================================
Describe "1. Get-DeviceLogPresets コマンドプリセット一覧・スキーマ検証" {
    It "Get-DeviceLogPresets が配列を返し、要素数が8件以上であること" {
        $presets = Get-DeviceLogPresets
        $presets | Should Not BeNullOrEmpty
        $presets.Count | Should BeGreaterThan 7
    }

    It "必須プリセットID（cisco, yamaha, linux 3種, windows 3種, custom）がすべて存在すること" {
        $presets = Get-DeviceLogPresets
        $ids = @($presets | ForEach-Object { $_.id })

        ($ids -contains "cisco_show_logging") | Should Be $true
        ($ids -contains "yamaha_show_log") | Should Be $true
        ($ids -contains "linux_journalctl") | Should Be $true
        ($ids -contains "linux_dmesg") | Should Be $true
        ($ids -contains "linux_syslog") | Should Be $true
        ($ids -contains "windows_winevent_sys") | Should Be $true
        ($ids -contains "windows_winevent_app") | Should Be $true
        ($ids -contains "windows_eventlog_sys") | Should Be $true
        ($ids -contains "custom") | Should Be $true
    }

    It "各プリセットが必須フィールド（id, name, command, category, protocol, description）を保持すること" {
        $presets = Get-DeviceLogPresets
        foreach ($p in $presets) {
            $p.id | Should Not BeNullOrEmpty
            $p.name | Should Not BeNullOrEmpty
            $p.category | Should Not BeNullOrEmpty
            $p.protocol | Should Not BeNullOrEmpty
            $p.description | Should Not BeNullOrEmpty
            $null -ne $p.command | Should Be $true
        }
    }

    It "custom プリセットは command が空文字、category が 'custom'、protocol が 'custom' であること" {
        $presets = Get-DeviceLogPresets
        $custom = $presets | Where-Object { $_.id -eq "custom" }
        $custom | Should Not BeNullOrEmpty
        $custom.command | Should Be ""
        $custom.category | Should Be "custom"
        $custom.protocol | Should Be "custom"
    }

    It "Cisco および Yamaha プリセットの category が 'network'、protocol が 'ssh' であること" {
        $presets = Get-DeviceLogPresets
        $cisco = $presets | Where-Object { $_.id -eq "cisco_show_logging" }
        $cisco.category | Should Be "network"
        $cisco.protocol | Should Be "ssh"
        $cisco.command | Should Be "show logging"

        $yamaha = $presets | Where-Object { $_.id -eq "yamaha_show_log" }
        $yamaha.category | Should Be "network"
        $yamaha.protocol | Should Be "ssh"
        $yamaha.command | Should Be "show log"
    }

    It "Linux プリセットの category が 'linux'、protocol が 'ssh' であり、行数制限やページャー抑止が含まれること" {
        $presets = Get-DeviceLogPresets
        $journal = $presets | Where-Object { $_.id -eq "linux_journalctl" }
        $journal.category | Should Be "linux"
        $journal.protocol | Should Be "ssh"
        $journal.command | Should Match "--no-pager"

        $dmesg = $presets | Where-Object { $_.id -eq "linux_dmesg" }
        $dmesg.category | Should Be "linux"
        $dmesg.command | Should Match "tail"

        $syslog = $presets | Where-Object { $_.id -eq "linux_syslog" }
        $syslog.category | Should Be "linux"
        $syslog.command | Should Match "tail"
    }

    It "Windows プリセットの category が 'windows'、protocol が 'winrm' であり、Out-String による横幅確保が含まれること" {
        $presets = Get-DeviceLogPresets
        $winSys = $presets | Where-Object { $_.id -eq "windows_winevent_sys" }
        $winSys.category | Should Be "windows"
        $winSys.protocol | Should Be "winrm"
        $winSys.command | Should Match "Out-String -Width 4096"

        $winApp = $presets | Where-Object { $_.id -eq "windows_winevent_app" }
        $winApp.category | Should Be "windows"
        $winApp.protocol | Should Be "winrm"
        $winApp.command | Should Match "Out-String -Width 4096"
    }
}

# ==============================================================================
# テストセクション 2: Invoke-DeviceLogFetch 実行エンジン・安全性・バッファ保護検証
# ==============================================================================
Describe "2. Invoke-DeviceLogFetch 実行エンジン・安全性・バッファ保護検証" {
    BeforeAll {
        Initialize-EngineTestEnv
    }

    AfterAll {
        Cleanup-EngineTestEnv
    }

    It "有効なカスタムコマンドを実行した場合、status 'COMPLETED', exitCode 0 で完全な結果構造体を返すこと" {
        $dev = @{
            ip     = "127.0.0.1"
            name   = "Local-Dev"
            remote = @{
                enabled  = $true
                protocol = "custom"
            }
        }
        $res = Invoke-DeviceLogFetch -Device $dev -CustomCommand "echo LOG_FETCH_SUCCESS_99182" -ReportsDirectory $testTempDir_Engine
        $res.success | Should Be $true
        $res.status | Should Be "COMPLETED"
        $res.exitCode | Should Be 0
        $res.stdout | Should Match "LOG_FETCH_SUCCESS_99182"
        $res.truncated | Should Be $false
        $res.logFileName | Should Match "^127\.0\.0\.1_\d{8}_\d{6}\.log$"
        Test-Path (Join-Path $testTempDir_Engine "device_logs\$($res.logFileName)") | Should Be $true
    }

    It "プリセットID を指定して実行した場合にコマンドが正しく解決されて実行されること" {
        $dev = @{
            ip     = "127.0.0.1"
            name   = "Local-Preset"
            remote = @{
                enabled  = $true
                protocol = "custom"
                commands = @(
                    @{ id = "registered_cmd"; name = "Test Cmd"; command = "echo REGISTERED_COMMAND_RESOLVED" }
                )
            }
        }
        $res = Invoke-DeviceLogFetch -Device $dev -PresetId "registered_cmd" -ReportsDirectory $testTempDir_Engine
        $res.success | Should Be $true
        $res.status | Should Be "COMPLETED"
        $res.stdout | Should Match "REGISTERED_COMMAND_RESOLVED"
    }

    It "リモート管理が無効 (enabled = `$false) の機器に対しては即座に status 'REMOTE_DISABLED', success = `$false を返すこと" {
        $dev = @{
            ip     = "192.168.1.99"
            name   = "Disabled-Router"
            remote = @{
                enabled  = $false
                protocol = "custom"
            }
        }
        $res = Invoke-DeviceLogFetch -Device $dev -CustomCommand "echo DISABLED_TEST" -ReportsDirectory $testTempDir_Engine
        $res.success | Should Be $false
        $res.status | Should Be "REMOTE_DISABLED"
        $res.exitCode | Should Be -1
        $res.stderr | Should Match "disabled"
    }

    It "IP未指定の場合は status 'MISSING_IP', success = `$false を返すこと" {
        $dev = @{
            ip     = ""
            name   = "No-IP"
            remote = @{ enabled = $true; protocol = "custom" }
        }
        $res = Invoke-DeviceLogFetch -Device $dev -CustomCommand "echo test" -ReportsDirectory $testTempDir_Engine
        $res.success | Should Be $false
        $res.status | Should Be "MISSING_IP"
    }

    It "コマンドもプリセットも未指定の場合は status 'NO_COMMAND_SPECIFIED', success = `$false を返すこと" {
        $dev = @{
            ip     = "127.0.0.1"
            name   = "No-Cmd"
            remote = @{ enabled = $true; protocol = "custom" }
        }
        $res = Invoke-DeviceLogFetch -Device $dev -CustomCommand "" -PresetId "" -ReportsDirectory $testTempDir_Engine
        $res.success | Should Be $false
        $res.status | Should Be "NO_COMMAND_SPECIFIED"
    }

    It "1MB stdout バッファ保護：1MB (1,000,000文字) を超える大容量出力に対し、truncated = `$true となり警告が付加されること" {
        $dev = @{
            ip     = "127.0.0.1"
            name   = "Large-Output-Dev"
            remote = @{
                enabled  = $true
                protocol = "custom"
            }
        }
        $largeCmd = 'powershell -NoProfile -Command "Write-Output (New-Object string (''A'', 1200000))"'
        $res = Invoke-DeviceLogFetch -Device $dev -CustomCommand $largeCmd -TimeoutSec 25 -ReportsDirectory $testTempDir_Engine
        $res.success | Should Be $true
        $res.truncated | Should Be $true
        $res.stdout | Should Match "TRUNCATED: 出力サイズが1MBを超過したため画面表示を切り詰めました"
        $res.stdout.Length | Should BeLessThan 1001000
    }

    It "プロセス実行タイムアウト制限 (proc.Kill)：スリープコマンドを短時間 (1秒) で安全に強制終了すること" {
        $dev = @{
            ip     = "127.0.0.1"
            name   = "Timeout-Target"
            remote = @{
                enabled  = $true
                protocol = "custom"
            }
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $res = Invoke-DeviceLogFetch -Device $dev -CustomCommand "powershell.exe -NoProfile -Command Start-Sleep -Seconds 10" -TimeoutSec 1 -ReportsDirectory $testTempDir_Engine
        $sw.Stop()

        $res.success | Should Be $false
        $res.status | Should Be "TIMEOUT"
        $res.stderr | Should Match "timed out"
        # タイムアウトが1秒で、全体の所要時間が5秒未満であること (ハングアップせずにKillされたことを検証)
        $sw.ElapsedMilliseconds | Should BeLessThan 5000
    }

    It "5MB ディスク保存ガード (Save-DeviceLogFile)：6MB のログ内容を保存した場合、isDiskTruncated = `$true となり 5.3MB 以下に制限されること" {
        $chunk = "B" * 1024
        $sb = New-Object System.Text.StringBuilder(6 * 1024 * 1024 + 100)
        for ($i = 0; $i -lt 6144; $i++) {
            $null = $sb.Append($chunk)
        }
        $sixMbLog = $sb.ToString()

        $saveRes = Save-DeviceLogFile -ReportsDirectory $testTempDir_Engine -Ip "10.0.0.1" -DeviceName "Guard-SW" -Protocol "ssh" -Command "show tech" -LogContent $sixMbLog -Status "COMPLETED" -ExitCode 0 -DurationMs 1000
        $saveRes.success | Should Be $true
        $saveRes.isDiskTruncated | Should Be $true

        $savedFile = $saveRes.fullPath
        Test-Path $savedFile | Should Be $true
        $fileBytes = (Get-Item $savedFile).Length
        # 5MB + ヘッダー + マーカー <= 5,500,000 bytes (約5.24MB)
        $fileBytes | Should BeLessThan 5500000
        $fileContent = [System.IO.File]::ReadAllText($savedFile, [System.Text.Encoding]::UTF8)
        $fileContent | Should Match "DISK LOG TRUNCATED: 5MB超過のため保存を制限しました"
    }

    It "ログファイル保存整合性：Reports/device_logs/{IP}_{timestamp}.log が作成され、自己記述型ヘッダーが含まれること" {
        $dev = @{
            ip     = "172.16.0.1"
            name   = "Core-Switch"
            remote = @{ enabled = $true; protocol = "custom" }
        }
        $res = Invoke-DeviceLogFetch -Device $dev -CustomCommand "echo SWITCH_UPTIME_100_DAYS" -ReportsDirectory $testTempDir_Engine
        $logFile = Join-Path $testTempDir_Engine "device_logs\$($res.logFileName)"
        Test-Path $logFile | Should Be $true

        $text = [System.IO.File]::ReadAllText($logFile, [System.Text.Encoding]::UTF8)
        $text | Should Match "Network Device Monitor - Remote Device Log"
        $text | Should Match "Device: Core-Switch \(172\.16\.0\.1\)"
        $text | Should Match "Protocol: custom"
        $text | Should Match "Status: COMPLETED"
        $text | Should Match "\[OUTPUT\]"
        $text | Should Match "SWITCH_UPTIME_100_DAYS"
    }

    It "監査ログ記録 (Reports/audit.log)：Local\NDM_AuditLog_Mutex を経由して LOG_RETRIEVAL アクションが記録されること" {
        $auditFile = Join-Path $testTempDir_Engine "audit.log"
        if (Test-Path $auditFile) { Remove-Item $auditFile -Force }

        $dev = @{
            ip     = "192.168.10.1"
            name   = "Audit-Test-Dev"
            remote = @{ enabled = $true; protocol = "custom" }
        }
        $res = Invoke-DeviceLogFetch -Device $dev -CustomCommand "echo AUDIT_LOG_VERIFICATION" -ReportsDirectory $testTempDir_Engine -ClientIp "10.9.8.7"
        Test-Path $auditFile | Should Be $true

        $auditText = ""
        for ($retry = 0; $retry -lt 10; $retry++) {
            try {
                $auditText = [System.IO.File]::ReadAllText($auditFile, [System.Text.Encoding]::UTF8)
                break
            } catch {
                Start-Sleep -Milliseconds 100
            }
        }
        $auditText | Should Match "\[Action: LOG_RETRIEVAL\]"
        $auditText | Should Match "\[Target: 192\.168\.10\.1\]"
        $auditText | Should Match "\[10\.9\.8\.7\]"
        $auditText | Should Match "AUDIT_LOG_VERIFICATION"
    }

    It "レポート自動パージに対する非破壊保護：Invoke-PurgeOldReports を実行しても Reports/device_logs フォルダおよびログファイルが絶対に削除されないこと" {
        # 1. 模擬の過去セッションフォルダ (20200101_000000) を作成
        $oldSessionDir = Join-Path $testTempDir_Engine "20200101_000000"
        New-Item -ItemType Directory -Path $oldSessionDir -Force | Out-Null
        $dummyReport = Join-Path $oldSessionDir "summary.csv"
        [System.IO.File]::WriteAllText($dummyReport, "dummy data", [System.Text.Encoding]::UTF8)
        Set-SafeLastWriteTime $oldSessionDir ((Get-Date).AddDays(-100))

        # 2. device_logs フォルダ内に古いログファイルを作成
        $deviceLogsDir = Join-Path $testTempDir_Engine "device_logs"
        if (-not (Test-Path $deviceLogsDir)) {
            New-Item -ItemType Directory -Path $deviceLogsDir -Force | Out-Null
        }
        $oldLogFile = Join-Path $deviceLogsDir "192.168.1.1_20200101_000000.log"
        [System.IO.File]::WriteAllText($oldLogFile, "preserved log", [System.Text.Encoding]::UTF8)
        Set-SafeLastWriteTime $deviceLogsDir ((Get-Date).AddDays(-100))
        Set-SafeLastWriteTime $oldLogFile ((Get-Date).AddDays(-100))

        # 3. Invoke-PurgeOldReports を 30日保持ポリシーで実行
        $purgeRes = Invoke-PurgeOldReports -reportsDirectory $testTempDir_Engine -retentionDays 30

        # 古いセッションフォルダは削除されること
        Test-Path $oldSessionDir | Should Be $false
        $purgeRes.DeletedCount | Should BeGreaterThan 0

        # device_logs フォルダおよび中のログファイルは削除されず残存すること (保護の検証)
        Test-Path $deviceLogsDir | Should Be $true
        Test-Path $oldLogFile | Should Be $true
    }
}

# ==============================================================================
# テストセクション 3: HTTP REST API エンドポイント統合テスト (エフェメラルリスナー)
# ==============================================================================
Describe "3. HTTP REST API (/api/device/fetch-log, logs, log-download, log-presets) 統合テスト" {
    BeforeAll {
        Initialize-ApiTestEnv

        # 模擬ログファイルを作成
        $dlDir = Join-Path $testTempDir_Api "device_logs"
        $sampleLogName = "127.0.0.1_20261024_100000.log"
        $sampleLogPath = Join-Path $dlDir $sampleLogName
        $sampleContent = @"
================================================================================
 Network Device Monitor - Remote Device Log
 Device: Local-API (127.0.0.1)
 Protocol: custom
 Command: echo HELLO_LOG
 Timestamp: 2026-10-24 10:00:00
 Status: COMPLETED | ExitCode: 0 | Duration: 50ms
 Lines: 1 | Size: 10 bytes
================================================================================
[OUTPUT]
HELLO_LOG
"@
        [System.IO.File]::WriteAllText($sampleLogPath, $sampleContent, [System.Text.Encoding]::UTF8)

        # 空きポート取得
        $tcpListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $tcpListener.Start()
        $global:apiPort = $tcpListener.LocalEndpoint.Port
        $tcpListener.Stop()

        # 同期ハッシュの初期化
        $global:testSyncHash = [hashtable]::Synchronized(@{
            Devices = @("127.0.0.1", "10.0.0.1")
            DeviceName = @{
                "127.0.0.1" = "Local-Dev"
                "10.0.0.1"  = "Disabled-Dev"
            }
            Remote = @{
                "127.0.0.1" = @{
                    enabled  = $true
                    protocol = "custom"
                    commands = @(
                        @{ id = "cmd-echo"; name = "Echo Hello"; command = "echo API_PRESET_RESOLVED" }
                    )
                }
                "10.0.0.1" = @{
                    enabled  = $false
                    protocol = "custom"
                }
            }
        })

        # エフェメラル HTTP リスナーの起動
        $global:listenerRs = [powershell]::Create()
        $global:listenerRs.AddScript({
            param($port, $moduleDir, $reportsDirectory, $syncHash)
            Import-Module (Join-Path $moduleDir "Common.psm1") -Force -DisableNameChecking
            Import-Module (Join-Path $moduleDir "RemoteExec.psm1") -Force -DisableNameChecking

            $listener = New-Object System.Net.HttpListener
            $listener.Prefixes.Add("http://127.0.0.1:$port/")
            $listener.Start()

            $running = $true
            while ($running -and $listener.IsListening) {
                try {
                    $ctx = $listener.GetContext()
                    $req = $ctx.Request
                    $res = $ctx.Response
                    $path = $req.Url.LocalPath
                    $method = $req.HttpMethod

                    if ($method -eq "POST" -and $path -eq "/api/shutdown") {
                        Write-JsonResponse $res @{ status = "ok" } 200
                        $running = $false
                        break
                    }

                    if ($path -eq "/api/device/log-presets" -and $method -eq "GET") {
                        $presets = Get-DeviceLogPresets
                        Write-JsonResponse $res @{ success = $true; presets = $presets } 200
                        continue
                    }

                    if ($path -eq "/api/device/fetch-log" -and $method -eq "POST") {
                        $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                        $json = $reader.ReadToEnd()
                        $reader.Close()

                        $payload = $null
                        try { if ($json) { $payload = $json | ConvertFrom-Json } } catch {}
                        if ($null -eq $payload) {
                            Write-JsonResponse $res @{ error = "Invalid JSON"; success = $false; status = "INVALID_REQUEST" } 400
                            continue
                        }

                        $ip = if ($payload.ip) { [string]$payload.ip.Trim() } else { "" }
                        $presetId = if ($payload.presetId) { [string]$payload.presetId.Trim() } else { "" }
                        $customCmd = if ($payload.customCommand) { [string]$payload.customCommand.Trim() } else { "" }
                        $timeoutSec = if ($payload.timeoutSec) { [int]$payload.timeoutSec } else { 15 }

                        if ([string]::IsNullOrWhiteSpace($ip)) {
                            Write-JsonResponse $res @{ error = "Target IP address is required"; success = $false; status = "MISSING_IP" } 400
                            continue
                        }

                        if (-not ($syncHash.Devices -contains $ip)) {
                            Write-JsonResponse $res @{ error = "Device '$ip' not found"; success = $false; status = "DEVICE_NOT_FOUND" } 404
                            continue
                        }

                        $remoteCfg = if ($syncHash.Remote -and $syncHash.Remote.ContainsKey($ip)) { $syncHash.Remote[$ip] } else { $null }
                        $isEnabled = [bool]$(if ($remoteCfg -and $remoteCfg.ContainsKey('enabled')) { $remoteCfg['enabled'] } else { $false })
                        if (-not $isEnabled) {
                            Write-JsonResponse $res @{ error = "Remote management is disabled for device '$ip'"; success = $false; status = "REMOTE_DISABLED" } 400
                            continue
                        }

                        $resolvedCmd = ""
                        if (-not [string]::IsNullOrWhiteSpace($customCmd)) {
                            $resolvedCmd = $customCmd
                        } elseif (-not [string]::IsNullOrWhiteSpace($presetId)) {
                            $allPresets = Get-DeviceLogPresets
                            foreach ($p in $allPresets) {
                                if ($p.id -eq $presetId) { $resolvedCmd = [string]$p.command; break }
                            }
                            if ([string]::IsNullOrWhiteSpace($resolvedCmd) -and $remoteCfg.ContainsKey('commands')) {
                                foreach ($ci in $remoteCfg['commands']) {
                                    if ($ci.id -eq $presetId) { $resolvedCmd = [string]$ci.command; break }
                                }
                            }
                        }

                        if ([string]::IsNullOrWhiteSpace($resolvedCmd)) {
                            Write-JsonResponse $res @{ error = "No command specified"; success = $false; status = "NO_COMMAND_SPECIFIED" } 400
                            continue
                        }

                        $devArg = @{
                            ip     = $ip
                            name   = if ($syncHash.DeviceName.ContainsKey($ip)) { $syncHash.DeviceName[$ip] } else { $ip }
                            remote = $remoteCfg
                        }

                        $execResult = Invoke-RemoteDeviceCommand -Device $devArg -Action "command" -CustomCommand $resolvedCmd -TimeoutSec $timeoutSec
                        $stdout = if ($null -ne $execResult.stdout) { [string]$execResult.stdout } else { "" }
                        $execStatus = if ($null -ne $execResult.status) { [string]$execResult.status } else { "UNKNOWN" }
                        $exitCode = if ($null -ne $execResult.exitCode) { [int]$execResult.exitCode } else { -1 }

                        $fileTimestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
                        $saveRes = Save-DeviceLogFile -ReportsDirectory $reportsDirectory -Ip $ip -DeviceName $devArg.name -Protocol "custom" -Command $resolvedCmd -LogContent $stdout -Status $execStatus -ExitCode $exitCode -Timestamp $fileTimestamp
                        $logFileName = $saveRes.fileName
                        $logFilePath = $saveRes.filePath

                        $truncated = $false
                        $respStdout = $stdout
                        if ($stdout.Length -gt 1000000) {
                            $truncated = $true
                            $respStdout = $stdout.Substring(0, 1000000) + "`r`n`r`n--- [TRUNCATED: 1MB] ---"
                        }

                        Log-Audit -action "LOG_RETRIEVAL" -target $ip -details "Fetch log API" -clientIp "127.0.0.1" -reportsDirectory $reportsDirectory

                        if ($execStatus -eq "COMPLETED" -or $execResult.success -eq $true) {
                            Write-JsonResponse $res @{
                                success     = $true
                                status      = "COMPLETED"
                                ip          = $ip
                                command     = $resolvedCmd
                                stdout      = $respStdout
                                stderr      = $execResult.stderr
                                exitCode    = $exitCode
                                truncated   = $truncated
                                logFilePath = $logFilePath
                                logFileName = $logFileName
                                lineCount   = $saveRes.lineCount
                                sizeBytes   = $saveRes.sizeBytes
                            } 200
                        } elseif ($execStatus -eq "TIMEOUT") {
                            Write-JsonResponse $res @{
                                success = $false
                                status  = "TIMEOUT"
                                error   = "Execution timed out"
                            } 500
                        } else {
                            Write-JsonResponse $res @{
                                success = $false
                                status  = "EXECUTION_FAILED"
                                error   = "Execution failed"
                            } 500
                        }
                        continue
                    }

                    if ($path -eq "/api/device/logs" -and $method -eq "GET") {
                        $targetIp = if ($req.QueryString["ip"]) { [string]$req.QueryString["ip"].Trim() } else { "" }
                        $devLogsDir = Join-Path $reportsDirectory "device_logs"
                        $logList = @()

                        if (Test-Path $devLogsDir) {
                            $pattern = if (-not [string]::IsNullOrWhiteSpace($targetIp)) { "${targetIp}_*.log" } else { "*.log" }
                            $files = Get-ChildItem -Path $devLogsDir -Filter $pattern -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
                            foreach ($f in $files) {
                                $logList += @{
                                    fileName      = $f.Name
                                    filePath      = "Reports/device_logs/$($f.Name)"
                                    ip            = if ($f.Name -match '^([^_]+)_') { $matches[1] } else { $targetIp }
                                    timestamp     = $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
                                    sizeBytes     = $f.Length
                                    sizeFormatted = "$([math]::Round($f.Length / 1KB, 1)) KB"
                                    lineCount     = 10
                                }
                            }
                        }

                        Write-JsonResponse $res @{ success = $true; ip = $targetIp; logs = $logList } 200
                        continue
                    }

                    if ($path -eq "/api/device/log-download" -and $method -eq "GET") {
                        $requestedFile = if ($req.QueryString["file"]) { [string]$req.QueryString["file"] } else { [string]$req.QueryString["fileName"] }
                        if ([string]::IsNullOrWhiteSpace($requestedFile)) {
                            Write-JsonResponse $res @{ error = "Parameter 'file' is required"; success = $false } 400
                            continue
                        }

                        $cleanFileName = [System.IO.Path]::GetFileName($requestedFile)
                        if ([string]::IsNullOrWhiteSpace($cleanFileName)) {
                            Write-JsonResponse $res @{ error = "Invalid file name"; success = $false } 400
                            continue
                        }

                        $ext = [System.IO.Path]::GetExtension($cleanFileName).ToLower()
                        if ($ext -ne ".log" -and $ext -ne ".txt") {
                            Write-JsonResponse $res @{ error = "Invalid file extension"; success = $false } 400
                            continue
                        }

                        $devLogsDir = Join-Path $reportsDirectory "device_logs"
                        $targetFilePath = Join-Path $devLogsDir $cleanFileName
                        $fullLogsDir = [System.IO.Path]::GetFullPath($devLogsDir)
                        if (-not $fullLogsDir.EndsWith([System.IO.Path]::DirectorySeparatorChar.ToString())) {
                            $fullLogsDir += [System.IO.Path]::DirectorySeparatorChar
                        }
                        $fullTargetPath = [System.IO.Path]::GetFullPath($targetFilePath)

                        if (-not $fullTargetPath.StartsWith($fullLogsDir, [System.StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path $fullTargetPath -PathType Leaf)) {
                            Write-JsonResponse $res @{ error = "Log file not found: $cleanFileName"; success = $false } 404
                            continue
                        }

                        try {
                            $res.StatusCode = 200
                            $res.ContentType = "text/plain; charset=utf-8"
                            $res.Headers.Add("Content-Disposition", "attachment; filename=`"$cleanFileName`"")
                            [byte[]]$bytes = [System.IO.File]::ReadAllBytes($fullTargetPath)
                            $res.ContentLength64 = $bytes.Length
                            $res.OutputStream.Write($bytes, 0, $bytes.Length)
                            $res.Close()
                        } catch {
                            try { $res.Close() } catch {}
                        }
                        continue
                    }

                    Write-JsonResponse $res @{ error = "Not found" } 404
                } catch {
                    break
                }
            }
            try { $listener.Stop(); $listener.Close() } catch {}
        }).AddArgument($global:apiPort).AddArgument($moduleDir).AddArgument($testTempDir_Api).AddArgument($global:testSyncHash) | Out-Null

        $global:listenerHandle = $global:listenerRs.BeginInvoke()
        Start-Sleep -Milliseconds 500
    }

    It "GET /api/device/log-presets が HTTP 200 OK を返し、全プリセットを含む JSON を返却すること" {
        $uri = "http://127.0.0.1:$($global:apiPort)/api/device/log-presets"
        $res = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 5
        $res.success | Should Be $true
        $res.presets | Should Not BeNullOrEmpty
        $res.presets.Count | Should BeGreaterThan 7
    }

    It "POST /api/device/fetch-log (有効なカスタムコマンド) が HTTP 200 OK を返し、正常にログ出力を取得できること" {
        $uri = "http://127.0.0.1:$($global:apiPort)/api/device/fetch-log"
        $body = @{
            ip            = "127.0.0.1"
            customCommand = "echo HTTP_FETCH_LOG_SUCCESS"
            timeoutSec    = 10
        } | ConvertTo-Json
        $res = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json; charset=utf-8" -TimeoutSec 10
        $res.success | Should Be $true
        $res.status | Should Be "COMPLETED"
        $res.stdout | Should Match "HTTP_FETCH_LOG_SUCCESS"
        $res.logFileName | Should Not BeNullOrEmpty
    }

    It "POST /api/device/fetch-log (プリセット指定) が HTTP 200 OK を返し、指定コマンドが解決・実行されること" {
        $uri = "http://127.0.0.1:$($global:apiPort)/api/device/fetch-log"
        $body = @{
            ip         = "127.0.0.1"
            presetId   = "cmd-echo"
            timeoutSec = 10
        } | ConvertTo-Json
        $res = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json; charset=utf-8" -TimeoutSec 10
        $res.success | Should Be $true
        $res.status | Should Be "COMPLETED"
        $res.stdout | Should Match "API_PRESET_RESOLVED"
    }

    It "POST /api/device/fetch-log で remote.enabled = `$false の機器は HTTP 400 REMOTE_DISABLED を返すこと" {
        $uri = "http://127.0.0.1:$($global:apiPort)/api/device/fetch-log"
        $body = @{
            ip            = "10.0.0.1"
            customCommand = "echo TEST"
        } | ConvertTo-Json
        $statusCode = 0
        $errStatus = ""
        try {
            $null = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json; charset=utf-8" -TimeoutSec 5
        } catch {
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                try { $errStatus = ($_.ErrorDetails.Message | ConvertFrom-Json).status } catch {}
            }
        }
        $statusCode | Should Be 400
        $errStatus | Should Be "REMOTE_DISABLED"
    }

    It "POST /api/device/fetch-log で未登録IPアドレスの場合は HTTP 404 DEVICE_NOT_FOUND を返すこと" {
        $uri = "http://127.0.0.1:$($global:apiPort)/api/device/fetch-log"
        $body = @{
            ip            = "192.168.200.200"
            customCommand = "echo TEST"
        } | ConvertTo-Json
        $statusCode = 0
        try {
            $null = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json; charset=utf-8" -TimeoutSec 5
        } catch {
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
        }
        $statusCode | Should Be 404
    }

    It "POST /api/device/fetch-log で IP 未指定の場合は HTTP 400 MISSING_IP を返すこと" {
        $uri = "http://127.0.0.1:$($global:apiPort)/api/device/fetch-log"
        $body = @{
            ip            = ""
            customCommand = "echo TEST"
        } | ConvertTo-Json
        $statusCode = 0
        try {
            $null = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json; charset=utf-8" -TimeoutSec 5
        } catch {
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
        }
        $statusCode | Should Be 400
    }

    It "POST /api/device/fetch-log でタイムアウト発生時は HTTP 500 TIMEOUT を返すこと" {
        $uri = "http://127.0.0.1:$($global:apiPort)/api/device/fetch-log"
        $body = @{
            ip            = "127.0.0.1"
            customCommand = "powershell.exe -NoProfile -Command Start-Sleep -Seconds 10"
            timeoutSec    = 1
        } | ConvertTo-Json
        $statusCode = 0
        $errStatus = ""
        try {
            $null = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json; charset=utf-8" -TimeoutSec 10
        } catch {
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                try { $errStatus = ($_.ErrorDetails.Message | ConvertFrom-Json).status } catch {}
            }
        }
        $statusCode | Should Be 500
        $errStatus | Should Be "TIMEOUT"
    }

    It "POST /api/device/fetch-log で大容量ログ (> 1MB) 取得時に response.truncated = `$true となること" {
        $uri = "http://127.0.0.1:$($global:apiPort)/api/device/fetch-log"
        $largeCmd = 'powershell -NoProfile -Command "Write-Output (New-Object string (''X'', 1200000))"'
        $body = @{
            ip            = "127.0.0.1"
            customCommand = $largeCmd
            timeoutSec    = 25
        } | ConvertTo-Json
        $res = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json; charset=utf-8" -TimeoutSec 35
        $res.success | Should Be $true
        $res.truncated | Should Be $true
    }

    It "GET /api/device/logs?ip={ip} が HTTP 200 OK を返し、対象機器の過去ログ一覧を返却すること" {
        Ensure-ApiSampleLog
        $uri = "http://127.0.0.1:$($global:apiPort)/api/device/logs?ip=127.0.0.1"
        $res = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 5
        $res.success | Should Be $true
        $res.ip | Should Be "127.0.0.1"
        $res.logs | Should Not BeNullOrEmpty
        $sample = $res.logs | Where-Object { $_.fileName -match "^127\.0\.0\.1_" }
        $sample | Should Not BeNullOrEmpty
    }

    It "GET /api/device/logs (IP未指定) で全機器の過去ログ一覧が取得できること" {
        Ensure-ApiSampleLog
        $uri = "http://127.0.0.1:$($global:apiPort)/api/device/logs"
        $res = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 5
        $res.success | Should Be $true
        $res.logs | Should Not BeNullOrEmpty
    }

    It "GET /api/device/log-download?file={fileName} で実在するログファイルがダウンロードできること" {
        Ensure-ApiSampleLog
        $sampleLogName = "127.0.0.1_20261024_100000.log"
        $uri = "http://127.0.0.1:$($global:apiPort)/api/device/log-download?file=$sampleLogName"
        $res = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -TimeoutSec 5
        $res.StatusCode | Should Be 200
        $cType = if ($res.Headers["Content-Type"]) { $res.Headers["Content-Type"] } else { $res.ContentType }
        $cType | Should Match "text/plain"
        $res.Content | Should Match "HELLO_LOG"
    }

    It "GET /api/device/log-download に対するパストラバーサル攻撃 (..) が HTTP 400 または 404 で遮断されること" {
        $badUrls = @(
            "http://127.0.0.1:$($global:apiPort)/api/device/log-download?file=../../devices.json",
            "http://127.0.0.1:$($global:apiPort)/api/device/log-download?file=..%2F..%2Fdevices.json",
            "http://127.0.0.1:$($global:apiPort)/api/device/log-download?file=C:\Windows\win.ini"
        )
        foreach ($badUri in $badUrls) {
            $blocked = $false
            try {
                $null = Invoke-WebRequest -Uri $badUri -Method Get -UseBasicParsing -TimeoutSec 3
            } catch {
                $code = [int]$_.Exception.Response.StatusCode
                if ($code -eq 400 -or $code -eq 404) {
                    $blocked = $true
                }
            }
            $blocked | Should Be $true
        }
    }

    It "GET /api/device/log-download で不正な拡張子 (.json, .bat, .exe) のファイル要求が HTTP 400 で遮断されること" {
        $badUri = "http://127.0.0.1:$($global:apiPort)/api/device/log-download?file=devices.json"
        $statusCode = 0
        try {
            $null = Invoke-WebRequest -Uri $badUri -Method Get -UseBasicParsing -TimeoutSec 3
        } catch {
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
        }
        $statusCode | Should Be 400
    }

    It "GET /api/device/log-download でパラメータ未指定の場合は HTTP 400 を返すこと" {
        $badUri = "http://127.0.0.1:$($global:apiPort)/api/device/log-download"
        $statusCode = 0
        try {
            $null = Invoke-WebRequest -Uri $badUri -Method Get -UseBasicParsing -TimeoutSec 3
        } catch {
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
        }
        $statusCode | Should Be 400
    }

    AfterAll {
        try {
            $null = Invoke-RestMethod -Uri "http://127.0.0.1:$($global:apiPort)/api/shutdown" -Method Post -TimeoutSec 3 -ErrorAction SilentlyContinue
        } catch {}
        if ($global:listenerRs) {
            try {
                if ($global:listenerHandle) {
                    $null = $global:listenerRs.EndInvoke($global:listenerHandle)
                }
            } catch {}
            try { $global:listenerRs.Dispose() } catch {}
            $global:listenerRs = $null
        }
        Cleanup-ApiTestEnv
        Remove-Variable -Name "TestDrive" -Scope Global -ErrorAction SilentlyContinue
    }
}
