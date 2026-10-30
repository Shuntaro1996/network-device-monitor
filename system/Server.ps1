#Requires -Version 5.1

# =========================================================================
# 【初心者向けの簡単な解説】
# このファイルは、監視システムの「裏側（バックエンド）」で動くメインプログラムです。
# Windowsの機能（PowerShell）を利用して、コンピュータの裏で静かに稼働します。
# 
# 主な仕事（役割）：
# 1. 【PING監視】: 各ネットワーク機器（ルーターやカメラなど）にミリ秒単位の信号を送り、
#    応答があるか（オンラインか）、応答に何ミリ秒かかっているか（遅延時間）をチェックします。
# 2. 【SNMP監視】: 機器に直接問い合わせて、現在のCPU使用率、メモリ使用状況、
#    データ通信量（Tx:送信 / Rx:受信）などの詳細なシステムステータスを吸い上げます。
# 3. 【データ提供】: 取得したこれらの情報を整理し、ブラウザ画面が読み込めるように
#    Webサーバーとして通信ポート8000番で応答します。
# 4. 【設定の保存】: 登録した機器のIPアドレスやグループ設定を「devices.json」という
#    ファイルに安全に記録・保存・管理します。
# =========================================================================

$ErrorActionPreference = "Continue"

Import-Module SNMP -DisableNameChecking -ErrorAction SilentlyContinue
if (-not (Get-Module -Name SNMP)) {
    if (-not (Get-Module -ListAvailable -Name SNMP)) {
        Write-Host "Checking SNMP module..." -ForegroundColor Yellow
        try {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null
            Install-Module -Name SNMP -Scope CurrentUser -Force -ErrorAction SilentlyContinue | Out-Null
        }
        catch {
            Write-Warning "Failed to install SNMP module: $($_.Exception.Message)"
        }
    }
    Import-Module SNMP -DisableNameChecking -ErrorAction SilentlyContinue
}

# ── Import System Modules (Modular Architecture) ──────────────────────────────
$modulesDir = Join-Path $PSScriptRoot "modules"
if (Test-Path $modulesDir) {
    Import-Module (Join-Path $modulesDir "Common.psm1") -Force -DisableNameChecking -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modulesDir "AlertManager.psm1") -Force -DisableNameChecking -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modulesDir "ReportGenerator.psm1") -Force -DisableNameChecking -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modulesDir "SnmpService.psm1") -Force -DisableNameChecking -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modulesDir "PingEngine.psm1") -Force -DisableNameChecking -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modulesDir "IperfRunner.psm1") -Force -DisableNameChecking -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modulesDir "RemoteExec.psm1") -Force -DisableNameChecking -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modulesDir "ObrStatus.psm1") -Force -DisableNameChecking -ErrorAction SilentlyContinue
}

# TCPポート監視用: 接続が終わった瞬間の所要時間を測る小さな補助クラス (メモリ内でコンパイルし、exe は作らない)
# (以前は全機器の確認が終わるまで待ってから時間を読んでいたため、応答しない機器が1台あるだけで
#  TCP 監視の機器の遅延が実際の 1ms ではなく 500ms 以上と表示され、「高遅延」と誤判定されていた)
if (-not ("NdmTcpProbe" -as [type])) {
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Net.Sockets;
using System.Threading.Tasks;
public static class NdmTcpProbe {
    // 接続できたらかかったミリ秒、失敗したら -1 を返す
    public static Task<long> ConnectTimed(string host, int port) {
        var sw = Stopwatch.StartNew();
        var client = new TcpClient();
        Task connectTask;
        try { connectTask = client.ConnectAsync(host, port); }
        catch { try { client.Close(); } catch { } return Task.FromResult(-1L); }
        return connectTask.ContinueWith(t => {
            sw.Stop();
            try { client.Close(); } catch { }
            return (t.IsFaulted || t.IsCanceled) ? -1L : sw.ElapsedMilliseconds;
        });
    }
}
"@ -ErrorAction Stop
    }
    catch { Write-Host "NdmTcpProbe compile failed: $($_.Exception.Message)" -ForegroundColor Red }
}

# Clean up any leftover iperf3.exe processes from previous unclean exits
try {
    Get-Process -Name "iperf3" -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_.Kill(); Write-Host "Cleaned up leftover iperf3 process (PID: $($_.Id))" -ForegroundColor DarkGray } catch {}
    }
}
catch {}

$port = 8081
if ($args) {
    for ($i = 0; $i -lt $args.Count; $i++) {
        if ($args[$i] -eq "-Port" -and ($i + 1) -lt $args.Count) {
            $parsedPort = 0
            if ([int]::TryParse($args[$i + 1], [ref]$parsedPort) -and $parsedPort -gt 0) {
                $port = $parsedPort
            }
        }
    }
}
$rootDir = Split-Path -Parent $PSScriptRoot
$publicDir = Join-Path $PSScriptRoot "public"
# devices.txt is now inside the system folder
$devicesFileJson = Join-Path $PSScriptRoot "devices.json"
$devicesFileTxt = Join-Path $PSScriptRoot "devices.txt"

# Shared memory for background runspaces
$syncHash = [hashtable]::Synchronized(@{})
$syncHash.Status = [hashtable]::Synchronized(@{})
$syncHash.Traffic = [hashtable]::Synchronized(@{})
$syncHash.Community = [hashtable]::Synchronized(@{})
$syncHash.DeviceName = [hashtable]::Synchronized(@{})
$syncHash.IsMonitored = [hashtable]::Synchronized(@{})
$syncHash.Group = [hashtable]::Synchronized(@{})
$syncHash.Image = [hashtable]::Synchronized(@{})
$syncHash.ConnectedTo = [hashtable]::Synchronized(@{})
$syncHash.X = [hashtable]::Synchronized(@{})
$syncHash.Y = [hashtable]::Synchronized(@{})
$syncHash.Stats = [hashtable]::Synchronized(@{})
$syncHash.Mac = [hashtable]::Synchronized(@{})  # MAC addresses
$syncHash.SnmpDetail = [hashtable]::Synchronized(@{})  # link speed, neighbors, wifi band
    
# Contact & Web extensions
$syncHash.VendorContact = [hashtable]::Synchronized(@{})
$syncHash.DeviceType = [hashtable]::Synchronized(@{}) # network, web, server, etc.
$syncHash.WebUrl = [hashtable]::Synchronized(@{})
$syncHash.SslExpiryDays = [hashtable]::Synchronized(@{})
$syncHash.HttpStatus = [hashtable]::Synchronized(@{})

$syncHash.InterfaceErrors = [hashtable]::Synchronized(@{}) # Stores current error counts and deltas
$syncHash.CheckType = [hashtable]::Synchronized(@{}) # icmp or tcp
$syncHash.Port = [hashtable]::Synchronized(@{}) # TCP port for port monitoring
$syncHash.IpConflicts = [hashtable]::Synchronized(@{}) # Stores detected IP/MAC address conflicts
$syncHash.LearnedMac = [hashtable]::Synchronized(@{}) # Tracks first observed MAC address per IP
    
# SNMPv3 security parameters
$syncHash.SnmpVersion = [hashtable]::Synchronized(@{})
$syncHash.SnmpUser = [hashtable]::Synchronized(@{})
$syncHash.SnmpAuthProto = [hashtable]::Synchronized(@{})
$syncHash.SnmpAuthPass = [hashtable]::Synchronized(@{})
$syncHash.SnmpPrivProto = [hashtable]::Synchronized(@{})
$syncHash.SnmpPrivPass = [hashtable]::Synchronized(@{})
$syncHash.ObrEnabled = [hashtable]::Synchronized(@{})    # OBR の無線接続状況を確認するか (機器ごと)
$syncHash.ObrPassword = [hashtable]::Synchronized(@{})   # OBR の管理者パスワード (暗号化した形で持つ)
$syncHash.ObrStatus = [hashtable]::Synchronized(@{})     # OBR の最新の無線接続状況
$syncHash.ObrHistoryQueue = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())   # CSV へ書き込む前の無線状態の履歴

# Remote execution settings (SSH/WinRM/Custom)
$syncHash.Remote = [hashtable]::Synchronized(@{})

# Syslog memory buffer (max 500 lines)
$syncHash.SyslogQueue = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())

# Config files paths
$configFileJson = Join-Path $PSScriptRoot "config.json"
$syncHash.StartTime = [DateTime]::UtcNow # サーバー起動日時 (ヘルスチェック用)
$syncHash.LastPingLoopUtc = $null              # 最終Pingループ時刻 (外形監視用, 初回ループ完了時に設定)

$syncHash.PollInterval = 1000  # Default frontend/backend polling interval (ms)
$syncHash.PingDataSize = 1     # Default ping data size (bytes)
$syncHash.LoggingEnabled = $true # Default logging configuration
$syncHash.HighFreqTargetIps = ""   # When PollInterval<=100ms, up to 2 IPs (comma-separated) are polled at high frequency
$syncHash.OutageThresh1Ms = 600  # Threshold 1 for outage count (ms)
$syncHash.OutageThresh2Ms = 5000 # Threshold 2 for outage count (ms)
$syncHash.LatencyThreshMs = 100  # Threshold for latency alert (ms)
$syncHash.LatencyWarningMs = 80   # 2段階アラート用: Warning遅延閾値 (ms)
$syncHash.ConsecutiveFailThresh = 2 # 2段階アラート用: 障害判定に必要な連続失敗回数
$syncHash.LossWarningThreshPercent = 5.0 # 回線品質劣化アラート: パケット損失率警告閾値 (%)
$syncHash.JitterWarningThreshMs = 20.0   # 回線品質劣化アラート: ジッター警告閾値 (ms)
$syncHash.LogRetentionDays = 30   # Auto-purge old reports older than N days (0=disabled)
$syncHash.BackupDir = Join-Path $PSScriptRoot "backups" # 設定・機器定義の自動スナップショット退避先
$syncHash.WebhookUrl = ""   # Webhook URL for external notifications (Slack/Teams/Discord)
$syncHash.WebhookEnabled = $false
$syncHash.WebhookOfflineOnly = $true
$syncHash.SoundEnabled = $true
$syncHash.SoundVolume = 0.5

# Email (SMTP) settings
$syncHash.EmailEnabled = $false
$syncHash.SmtpHost = ""
$syncHash.SmtpPort = 587
$syncHash.SmtpSsl = $true
$syncHash.SmtpUser = ""
$syncHash.SmtpPass = ""
$syncHash.SmtpFrom = ""
$syncHash.SmtpTo = ""

# Syslog settings
$syncHash.SyslogEnabled = $true
$syncHash.SyslogPort = 514
$syncHash.TrapPort = 162   # SNMP Trap の受信ポート (使えないときは 1162 で代わりに受信)
$syncHash.SslWarnDays = 30
$syncHash.UiMode = "detail"
$syncHash.BwThreshMbps = 10.0
$syncHash.EnableParentSuppression = $true
    
# 暗号化パスワードを復号する。別の Windows ユーザー (SYSTEM など) で起動して復号できないときは、暗号化された形のまま残す
# (空にすると、次の保存でパスワードが消えてしまい、正しいユーザーで起動し直しても戻せなくなるため)
function Unprotect-SecretOrKeep([string]$cipherText) {
    $plain = Unprotect-SecretString $cipherText
    if ($cipherText.StartsWith("enc:") -and [string]::IsNullOrEmpty($plain)) {
        Write-Host "[WARNING] 保存済みのパスワードを復号できません。パスワードを保存した Windows ユーザーで起動してください (現在: $([Environment]::UserName))" -ForegroundColor Red
        try { [System.IO.File]::AppendAllText((Join-Path $PSScriptRoot "debug.log"), "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] Could not decrypt a saved password as user '$([Environment]::UserName)'. Start the monitor as the Windows user who saved it. The encrypted value is kept unchanged.`r`n", [System.Text.Encoding]::UTF8) } catch {}
        return $cipherText
    }
    return $plain
}

# config.json の内容を $syncHash へ反映する (起動時とスナップショット復元時の共通処理)
# ※ 以前は復元時に config.json を書き戻すだけで実行中の設定へ反映されず、次の設定保存で復元前の値に戻っていた
function Import-ConfigToSyncHash($savedConfig) {
    if ($null -eq $savedConfig) { return }
    if ($null -ne $savedConfig.pollInterval) { $syncHash.PollInterval = [int]$savedConfig.pollInterval }
    if ($null -ne $savedConfig.pingDataSize) { $syncHash.PingDataSize = [math]::Min(65500, [math]::Max(0, [int]$savedConfig.pingDataSize)) }
    if ($null -ne $savedConfig.loggingEnabled) { $syncHash.LoggingEnabled = [bool]$savedConfig.loggingEnabled }
    if ($null -ne $savedConfig.highFreqTargetIps) { $syncHash.HighFreqTargetIps = [string]$savedConfig.highFreqTargetIps }
    elseif ($null -ne $savedConfig.highFreqTargetIp) { $syncHash.HighFreqTargetIps = [string]$savedConfig.highFreqTargetIp }
    if ($null -ne $savedConfig.outageThresh1Ms) { $syncHash.OutageThresh1Ms = [int]$savedConfig.outageThresh1Ms }
    if ($null -ne $savedConfig.outageThresh2Ms) { $syncHash.OutageThresh2Ms = [int]$savedConfig.outageThresh2Ms }
    if ($null -ne $savedConfig.latencyThreshMs) { $syncHash.LatencyThreshMs = [int]$savedConfig.latencyThreshMs }
    if ($null -ne $savedConfig.latencyWarningMs) { $syncHash.LatencyWarningMs = [int]$savedConfig.latencyWarningMs }
    if ($null -ne $savedConfig.consecutiveFailThresh) { $syncHash.ConsecutiveFailThresh = [int]$savedConfig.consecutiveFailThresh }
    if ($null -ne $savedConfig.lossWarningThreshPercent) { $syncHash.LossWarningThreshPercent = [double]$savedConfig.lossWarningThreshPercent }
    if ($null -ne $savedConfig.jitterWarningThreshMs) { $syncHash.JitterWarningThreshMs = [double]$savedConfig.jitterWarningThreshMs }
    if ($null -ne $savedConfig.logRetentionDays) { $syncHash.LogRetentionDays = [int]$savedConfig.logRetentionDays }
    if ($null -ne $savedConfig.webhookUrl) { $syncHash.WebhookUrl = [string]$savedConfig.webhookUrl }
    if ($null -ne $savedConfig.webhookEnabled) { $syncHash.WebhookEnabled = [bool]$savedConfig.webhookEnabled }
    if ($null -ne $savedConfig.webhookOfflineOnly) { $syncHash.WebhookOfflineOnly = [bool]$savedConfig.webhookOfflineOnly }
    if ($null -ne $savedConfig.soundEnabled) { $syncHash.SoundEnabled = [bool]$savedConfig.soundEnabled }
    if ($null -ne $savedConfig.soundVolume) { $syncHash.SoundVolume = [double]$savedConfig.soundVolume }

    if ($null -ne $savedConfig.emailEnabled) { $syncHash.EmailEnabled = [bool]$savedConfig.emailEnabled }
    if ($null -ne $savedConfig.smtpHost) { $syncHash.SmtpHost = [string]$savedConfig.smtpHost }
    if ($null -ne $savedConfig.smtpPort) { $syncHash.SmtpPort = [int]$savedConfig.smtpPort }
    if ($null -ne $savedConfig.smtpSsl) { $syncHash.SmtpSsl = [bool]$savedConfig.smtpSsl }
    if ($null -ne $savedConfig.smtpUser) { $syncHash.SmtpUser = [string]$savedConfig.smtpUser }
    if ($null -ne $savedConfig.smtpPass) {
        # DPAPI復号（平文であればそのまま読み込まれ、保存時に暗号化）
        $syncHash.SmtpPass = Unprotect-SecretOrKeep ([string]$savedConfig.smtpPass)
}
    if ($null -ne $savedConfig.smtpFrom) { $syncHash.SmtpFrom = [string]$savedConfig.smtpFrom }
    if ($null -ne $savedConfig.smtpTo) { $syncHash.SmtpTo = [string]$savedConfig.smtpTo }            if ($null -ne $savedConfig.syslogEnabled) { $syncHash.SyslogEnabled = [bool]$savedConfig.syslogEnabled }
    if ($null -ne $savedConfig.syslogPort) { $syncHash.SyslogPort = [int]$savedConfig.syslogPort }
    if ($null -ne $savedConfig.trapPort) { $syncHash.TrapPort = [int]$savedConfig.trapPort }
if ($null -ne $savedConfig.sslWarnDays) { $syncHash.SslWarnDays = [int]$savedConfig.sslWarnDays }
    if ($null -ne $savedConfig.uiMode) { $syncHash.UiMode = [string]$savedConfig.uiMode }
    if ($null -ne $savedConfig.bwThreshMbps) { $syncHash.BwThreshMbps = [double]$savedConfig.bwThreshMbps }
    if ($null -ne $savedConfig.enableParentSuppression) { $syncHash.EnableParentSuppression = [bool]$savedConfig.enableParentSuppression }
    if ($null -ne $savedConfig.autoShutdownOnDisconnect) {
        $syncHash.AutoShutdownOnDisconnect = [bool]$savedConfig.autoShutdownOnDisconnect
        # ファイルに書かれていた値を覚えておく (保存のたびに消えないように。環境変数で一時的に変えた値は保存しない)
        $syncHash.AutoShutdownInConfig = [bool]$savedConfig.autoShutdownOnDisconnect
    }
}

# ─────────────────────────────────────────
# 設定ファイル (config.json / devices.json) を読み込む。壊れていて読めないときは、
#  ① 壊れたファイルを「～.broken_日時」として残し、② 自動スナップショット (backups) の新しい順に読めるものを探して使う。
# (以前は読めないと空の状態で起動し、次に何かを保存した時点で空の内容で上書きされ、登録済みの機器や設定がすべて消えていた)
# ─────────────────────────────────────────
function Read-JsonWithSnapshotFallback([string]$path, [string]$snapshotPrefix) {
    # 同期ソフトなどが一時的に開いているだけのことがあるので、少し待って読み直す
    $raw = $null
    for ($attempt = 0; $attempt -lt 5 -and $null -eq $raw; $attempt++) {
        try { $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) }
        catch { Start-Sleep -Milliseconds 500 }
    }
    # 読めないだけならファイルは正しいかもしれない。その場合は監視を続けるが、上書きしないよう readFailed を返して保存を止める
    $readFailed = ($null -eq $raw)
    if (-not $readFailed -and -not [string]::IsNullOrWhiteSpace($raw)) {
        try { return @{ ok = $true; data = ($raw | ConvertFrom-Json -ErrorAction Stop) } } catch { }
    }
    if ($readFailed) {
        Write-Host "[WARNING] $([System.IO.Path]::GetFileName($path)) cannot be opened. Saving is disabled to protect the file." -ForegroundColor Red
    }
    else {
        # 中身が壊れている、または空 (書き込み途中で止まったときなど)
        $brokenCopy = "$path.broken_$((Get-Date).ToString('yyyyMMdd_HHmmss'))"
        try { Copy-Item -LiteralPath $path -Destination $brokenCopy -Force -ErrorAction Stop } catch { $brokenCopy = "" }
        Write-Host "[WARNING] $([System.IO.Path]::GetFileName($path)) is broken and cannot be read. Saved a copy: $brokenCopy" -ForegroundColor Red
    }
if (Test-Path -LiteralPath $syncHash.BackupDir) {
        # 新しい順 = ファイル名 (日時) の降順 (更新日時はコピー元のものが引き継がれるため使わない)
        $snaps = Get-ChildItem -LiteralPath $syncHash.BackupDir -Filter "${snapshotPrefix}_*.json" -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending
        foreach ($s in $snaps) {
            try {
                $snapData = [System.IO.File]::ReadAllText($s.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
                if ($null -ne $snapData) {
                    Write-Host "[RECOVERED] Loaded the latest readable snapshot instead: $($s.Name)" -ForegroundColor Yellow
                    return @{ ok = $true; data = $snapData; recoveredFrom = $s.Name; readFailed = $readFailed }
}
            }
            catch { }
        }
    }
    return @{ ok = $false; data = $null; readFailed = $readFailed }
}

# config.json を安全に保存する: 変更前の内容をスナップショットに退避し、一時ファイルに書いてから置き換える
# (直接上書きすると、書き込み途中で止まったとき (ドライブの同期遅延・PCの電源断など) にファイルが壊れ、
#  一括復元時はスナップショットも取っていなかったため、元の設定に戻せなかった)
function Save-ConfigJsonSafely($configData, [switch]$AlwaysSnapshot) {
    # 起動時に config.json を読めなかったときは、読めなかっただけの正しいファイルを上書きしないよう保存しない
    if ($syncHash.ConfigLoadFailed) {
        try { [System.IO.File]::AppendAllText((Join-Path $PSScriptRoot "debug.log"), "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] config.json save skipped: the file could not be read at startup`r`n", [System.Text.Encoding]::UTF8) } catch {}
        return
    }
    if (Test-Path -LiteralPath $configFileJson) {
        # 画面の操作ごとの保存は 1 分に 1 回に間引く。一括復元の前は必ず取る
        $null = Backup-ConfigSnapshot -targetFilePath $configFileJson -backupDir $syncHash.BackupDir -minIntervalSec $(if ($AlwaysSnapshot) { 0 } else { 60 })
    }
$tmpFile = "$configFileJson.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $configData | ConvertTo-Json -Depth 5 | Out-File -FilePath $tmpFile -Encoding UTF8
        Move-Item -LiteralPath $tmpFile -Destination $configFileJson -Force
    }
    finally {
        if (Test-Path -LiteralPath $tmpFile) { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
    }
}

# Load Config from file if exists
if (Test-Path $configFileJson) {
    $cfgRead = Read-JsonWithSnapshotFallback $configFileJson "config"
    if ($cfgRead.readFailed) { $syncHash.ConfigLoadFailed = $true }
if ($cfgRead.ok -and $null -ne $cfgRead.data) {
        Import-ConfigToSyncHash $cfgRead.data
        Write-Host "Config loaded from $configFileJson" -ForegroundColor Green
    }
    else {
        Write-Host "Failed to load config.json, using defaults." -ForegroundColor Yellow
    }
}

# 環境変数による 24/7 無人運用モード上書き判定
foreach ($envKey in @("NETWORK_MONITOR_AUTOSHUTDOWN", "AUTOSHUTDOWN_ON_DISCONNECT")) {
    $envVal = [Environment]::GetEnvironmentVariable($envKey)
    if (-not [string]::IsNullOrWhiteSpace($envVal)) {
        if ($envVal -match '^(false|0|no)$') { $syncHash.AutoShutdownOnDisconnect = $false }
        elseif ($envVal -match '^(true|1|yes)$') { $syncHash.AutoShutdownOnDisconnect = $true }
    }
}

# Webhook / メール送信は modules\AlertManager.psm1 の Send-WebhookNotification / Send-EmailNotification を使う
# (以前はここに古い同名の関数があり、そちらが優先されていた。メールのテスト送信は必ず失敗し、
#  Webhook のテスト送信は失敗しても「送信しました」と表示されていた)

# Helper: Log Audit record (Delegates to Common.psm1's mutex-locked Log-Audit)
function Log-Audit {
    param(
        [string]$action,
        [string]$target,
        [string]$details = "",
        [string]$clientIp = "127.0.0.1",
        [string]$reportsDirectory
    )
    if (-not $reportsDirectory) {
        $reportsDirectory = if ($ReportsDir) { $ReportsDir } else { Join-Path (Split-Path -Parent $PSScriptRoot) "Reports" }
    }
    Common\Log-Audit -action $action -target $target -details $details -clientIp $clientIp -reportsDirectory $reportsDirectory
}

# Helper: Auto-purge old Reports/ directories exceeding retention days
function Invoke-PurgeOldReports {
    param(
        [string]$reportsDirectory,
        [int]$retentionDays = 30,
        [string]$activeSessionDir = ""
    )
    $result = @{
        Success      = $true
        DeletedCount = 0
        FreedBytes   = [long]0
        FreedMb      = 0.0
        Details      = @()
    }
    if ($retentionDays -le 0) {
        return $result # 0 means disabled (unlimited retention)
    }
    try {
        if (-not $reportsDirectory) {
            $reportsDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) "Reports"
        }
        if (-not (Test-Path $reportsDirectory)) { return $result }

        $cutoffDate = (Get-Date).AddDays(-$retentionDays)
        $subDirs = Get-ChildItem -Path $reportsDirectory -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "device_logs" }

        foreach ($dir in $subDirs) {
            # 保護: 現在アクティブなセッションディレクトリは絶対に削除しない
            if ($activeSessionDir) {
                $activeItem = Get-Item $activeSessionDir -ErrorAction SilentlyContinue
                if ($activeItem -and ($dir.FullName -eq $activeItem.FullName)) {
                    continue
                }
            }

            $isTarget = $false
            $folderDate = $null

            # フォルダ名（yyyyMMdd_HHmmss 形式）からの日時判定
            if ($dir.Name -match '^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})$') {
                try {
                    $folderDate = [DateTime]::ParseExact($dir.Name, "yyyyMMdd_HHmmss", [System.Globalization.CultureInfo]::InvariantCulture)
                    if ($folderDate -lt $cutoffDate) {
                        $isTarget = $true
                    }
                }
                catch {}
            }

            # 日時パースできない場合は LastWriteTime で判定
            if (-not $folderDate -and $dir.LastWriteTime -lt $cutoffDate) {
                $isTarget = $true
            }

            if ($isTarget) {
                try {
                    # 容量計算
                    $files = Get-ChildItem -Path $dir.FullName -Recurse -File -ErrorAction SilentlyContinue
                    $dirBytes = [long]0
                    if ($files) {
                        $measured = $files | Measure-Object -Property Length -Sum
                        if ($measured -and $measured.Sum) { $dirBytes = [long]$measured.Sum }
                    }

                    Remove-Item -Path $dir.FullName -Recurse -Force -ErrorAction Stop
                    $result.DeletedCount++
                    $result.FreedBytes += $dirBytes
                    $result.Details += "Deleted old session: $($dir.Name) ($([math]::Round($dirBytes / 1MB, 2)) MB)"
                    Write-Host "[Retention Policy] Purged old report session: $($dir.Name) ($([math]::Round($dirBytes / 1MB, 2)) MB)" -ForegroundColor Gray
                }
                catch {
                    Write-Warning "Failed to purge old report session $($dir.FullName): $($_.Exception.Message)"
                }
            }
        }
        $result.FreedMb = [math]::Round($result.FreedBytes / 1MB, 2)
        if ($result.DeletedCount -gt 0) {
            try {
                $logMsg = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [Retention Policy] Purged $($result.DeletedCount) old session(s), freed $($result.FreedMb) MB.`r`n"
                [System.IO.File]::AppendAllText((Join-Path $PSScriptRoot "debug.log"), $logMsg, [System.Text.Encoding]::UTF8)
            }
            catch {}
        }
    }
    catch {
        $result.Success = $false
        $result.Error = $_.Exception.Message
        Write-Warning "Error during Invoke-PurgeOldReports: $($_.Exception.Message)"
    }
    return $result
}

# Helper: Clean iperf3 log lines by removing connection-error-only failed execution blocks
function Clean-IperfLogLines([string[]]$lines) {
    if (-not $lines -or $lines.Count -eq 0) { return @() }
        
    $cleanBlocks = @()
    $currentBlock = @()
    $inBlock = $false
    $hasBw = $false

    foreach ($line in $lines) {
        if ($line -match '^=== iperf3 Execution at ') {
            if ($currentBlock.Count -gt 0 -and $hasBw) {
                $cleanBlocks += $currentBlock
            }
            $currentBlock = @($line)
            $inBlock = $true
            $hasBw = $false
        }
        else {
            if ($inBlock) {
                $currentBlock += $line
                if ($line -match '\[\s*\d+\]\s+[0-9.]+\s*-\s*[0-9.]+\s+sec\s+[0-9.]+\s+[KMG]?Bytes\s+[0-9.]+\s+[KMG]?bits/sec' -and $line -notmatch 'sender|receiver|SUM') {
                    $hasBw = $true
                }
            }
            else {
                $cleanBlocks += $line
            }
        }
    }
    if ($currentBlock.Count -gt 0 -and $hasBw) {
        $cleanBlocks += $currentBlock
    }
    return $cleanBlocks
}
# Generate-SessionReportHtml is imported from ReportGenerator.psm1

# Helper: Check HTTP/HTTPS response & SSL Certificate Expiry
function Check-WebAndSslEndpoint {
    param([string]$url, [int]$timeoutMs = 4000)
    $res = @{
        Success          = $false
        StatusCode       = 0
        ResponseTimeMs   = 0
        SslDaysRemaining = $null
        SslSubject       = ""
        SslIssuer        = ""
        Error            = ""
    }
    if ([string]::IsNullOrWhiteSpace($url)) { return $res }
    if ($url -notmatch '^https?://') { $url = "http://$url" }
        
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not ("TrustAllCertsPolicy" -as [type])) {
            Add-Type -TypeDefinition @"
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class TrustAllCertsPolicy {
    public static RemoteCertificateValidationCallback Callback = delegate(object s, X509Certificate c, X509Chain ch, SslPolicyErrors e) { return true; };
}
"@ -ErrorAction SilentlyContinue
        }
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Timeout = $timeoutMs
        $req.AllowAutoRedirect = $true
        $req.ServerCertificateValidationCallback = [TrustAllCertsPolicy]::Callback # Accept self-signed for inspection (Runspace-safe C# delegate)
        $resp = $req.GetResponse()
        $sw.Stop()
        $res.Success = $true
        $res.StatusCode = [int]$resp.StatusCode
        $res.ResponseTimeMs = [int]$sw.ElapsedMilliseconds

        if ($url.StartsWith("https://", [System.StringComparison]::OrdinalIgnoreCase) -and $req.ServicePoint.Certificate) {
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $req.ServicePoint.Certificate
            $exp = $cert.NotAfter
            $remaining = [math]::Floor(($exp - (Get-Date)).TotalDays)
            $res.SslDaysRemaining = [int]$remaining
            $res.SslSubject = $cert.Subject
            $res.SslIssuer = $cert.Issuer
        }
        $resp.Close()
    }
    catch [System.Net.WebException] {
        $sw.Stop()
        $res.ResponseTimeMs = [int]$sw.ElapsedMilliseconds
        # $_ はエラー記録なので、応答は $_.Exception.Response にある (以前は常に空で、404 等でも状態コードが 0 になり、
        #  応答も閉じられずに接続が残り、同じサイトへの次の確認がタイムアウトしていた)
        $errResp = $_.Exception.Response
        if ($errResp) {
            $res.StatusCode = [int]$errResp.StatusCode
            try { $errResp.Close() } catch {}
        }
        $res.Error = $_.Exception.Message
    }
    catch {
        $sw.Stop()
        $res.Error = $_.Exception.Message
    }
    return $res
}

# Iperf Session State
$syncHash.IperfState = [hashtable]::Synchronized(@{
        Running       = $false
        Output        = ""
        Command       = ""
        Target        = ""
        LastUpdate    = 0
        StopRequested = $false
        Process       = $null
    })

# Iperf Server Session State
$syncHash.IperfServerState = [hashtable]::Synchronized(@{
        Running   = $false
        Port      = 5201
        Output    = ""
        Process   = $null
        StartTime = ""
        LogFile   = ""
    })

# MTR (Visual Tracert) Session State
$syncHash.MtrState = [hashtable]::Synchronized(@{
        Running       = $false
        Output        = ""
        Command       = ""
        Target        = ""
        Process       = $null
        StopRequested = $false
    })
    
# History: per-IP synchronized ArrayList of plain CSV strings (no runspace affinity issue)
$syncHash.History = [hashtable]::Synchronized(@{})
$syncHash.Running = $true
$syncHash.Devices = @()
$syncHash.Shutdown = $false  # flag for Enter-key exit
$syncHash.PendingShutdown = $false
$syncHash.PendingShutdownTime = [DateTime]::MinValue
$syncHash.PendingShutdownForced = $false   # 「監視終了」ボタンによる終了 (画面の通信が来ても取り消さない)
$syncHash.HasClientConnected = $false
$syncHash.LastClientActivity = [DateTime]::UtcNow
# 無人運用モードの設定は、上の config.json・環境変数の読み込みで決まっている。ここで決め直すと設定が効かなくなるため、
# どちらにも指定がないときだけ標準値 (ブラウザを閉じたら終了) にする
# (以前は無条件に $true で上書きしており、「無人運用モード (false)」がまったく働いていなかった)
if ($null -eq $syncHash.AutoShutdownOnDisconnect) { $syncHash.AutoShutdownOnDisconnect = $true }
$syncHash.HeartbeatTimeoutSec = 600  # ブラウザのバックグラウンドスロットリングやタブ切替・リロードでの誤終了を防ぐため60秒に設定
$syncHash.DevicesLock = [object]::new()  # Issue 5: デバイス設定保存専用ロックオブジェクト（$syncHash全体ロックを回避）
$syncHash.Listener = $null   # will be set after listener creation
$syncHash.PSScriptRoot = $PSScriptRoot
 
$cleanLines = [System.Collections.Generic.List[string]]::new()
if (Test-Path $devicesFileJson) {
    try {
        $devRead = Read-JsonWithSnapshotFallback $devicesFileJson "devices"
        if ($devRead.readFailed) { $syncHash.DevicesLoadFailed = $true }
        if (-not $devRead.ok) {
            # 復元もできないときは、空の一覧で上書きして全機器が消えないよう、保存を止めて起動する
            $syncHash.DevicesLoadFailed = $true
Write-Host "[ERROR] devices.json and all snapshots are unreadable. Device saving is disabled to protect the file." -ForegroundColor Red
        }
        $jsonContent = $devRead.data
        if ($null -ne $jsonContent) {
            foreach ($d in $jsonContent) {
                $ip = ([string]$d.ip).Trim()
                # 同じIPが複数行あると二重に監視・表示されるため最初の1件だけ使う
                if (-not [string]::IsNullOrWhiteSpace($ip) -and -not $cleanLines.Contains($ip)) {
                    $cleanLines.Add($ip)
                    $syncHash.Community[$ip] = if ($null -ne $d.community) { [string]$d.community } else { "public" }
                    $syncHash.DeviceName[$ip] = if ($null -ne $d.name) { [string]$d.name } else { $ip }
                    $syncHash.IsMonitored[$ip] = if ($null -ne $d.enabled) { [bool]$d.enabled } else { $true }
                    $syncHash.Group[$ip] = if ($null -ne $d.group) { [string]$d.group } else { "" }
                    $syncHash.Image[$ip] = if ($null -ne $d.image) { [string]$d.image } else { "" }
                    $syncHash.ConnectedTo[$ip] = if ($null -ne $d.connectedTo) { [string]$d.connectedTo } else { "" }
                    $syncHash.X[$ip] = if ($null -ne $d.x) { $d.x } else { $null }
                    $syncHash.Y[$ip] = if ($null -ne $d.y) { $d.y } else { $null }
                    $syncHash.Mac[$ip] = if ($null -ne $d.mac) { [string]$d.mac } else { "" }
                    $syncHash.VendorContact[$ip] = if ($null -ne $d.vendorContact) { [string]$d.vendorContact } else { "" }
                    $syncHash.DeviceType[$ip] = if ($null -ne $d.deviceType) { [string]$d.deviceType } else { "network" }
                    $syncHash.WebUrl[$ip] = if ($null -ne $d.webUrl) { [string]$d.webUrl } else { "" }
                    $syncHash.CheckType[$ip] = if ($null -ne $d.checkType) { [string]$d.checkType } else { "icmp" }
                    $syncHash.Port[$ip] = if ($null -ne $d.port) { [int]$d.port } else { 0 }
                        
                    # Load SNMPv3 parameters (DPAPI自動復号)
                    $syncHash.SnmpVersion[$ip] = if ($null -ne $d.snmpVersion) { [string]$d.snmpVersion } else { "v2c" }
                    $syncHash.SnmpUser[$ip] = if ($null -ne $d.snmpUser) { [string]$d.snmpUser } else { "" }
                    $syncHash.SnmpAuthProto[$ip] = if ($null -ne $d.snmpAuthProto) { [string]$d.snmpAuthProto } else { "none" }
                    $syncHash.SnmpAuthPass[$ip] = if ($null -ne $d.snmpAuthPass) { Unprotect-SecretOrKeep ([string]$d.snmpAuthPass) } else { "" }
$syncHash.SnmpPrivProto[$ip] = if ($null -ne $d.snmpPrivProto) { [string]$d.snmpPrivProto } else { "none" }
                    $syncHash.SnmpPrivPass[$ip] = if ($null -ne $d.snmpPrivPass) { Unprotect-SecretOrKeep ([string]$d.snmpPrivPass) } else { "" }
                    $syncHash.ObrEnabled[$ip] = if ($null -ne $d.obrEnabled) { [bool]$d.obrEnabled } else { $false }
                    $syncHash.ObrPassword[$ip] = if ($d.obrPassword) { Protect-SecretString ([string]$d.obrPassword) } else { "" }

                    # Load Remote execution configuration
                    if ($null -ne $d.remote) {
                        $rHash = @{}
                        if ($d.remote -is [System.Collections.IDictionary]) {
                            foreach ($k in $d.remote.Keys) { $rHash[$k] = $d.remote[$k] }
                        }
                        elseif ($null -ne $d.remote.PSObject) {
                            foreach ($p in $d.remote.PSObject.Properties) { $rHash[$p.Name] = $p.Value }
                        }
                        $syncHash.Remote[$ip] = $rHash
                    }
                }
            }
        }
    }
    catch {
        Write-Host "Error reading devices.json: $_" -ForegroundColor Red
    }
}
elseif (Test-Path $devicesFileTxt) {
    $migratedArray = @()
    foreach ($line in [System.IO.File]::ReadAllLines($devicesFileTxt)) {
        $line = $line.Trim()
        if ($line -ne "") {
            $ip = ""
            $comm = "public"
            if ($line -match "^([^,]+),(.*)$") {
                $ip = $matches[1].Trim()
                $comm = $matches[2].Trim()
            }
            else {
                $ip = $line
            }
            $cleanLines.Add($ip)
            $syncHash.Community[$ip] = $comm
            $syncHash.DeviceName[$ip] = $ip
            $syncHash.IsMonitored[$ip] = $true
            $syncHash.Group[$ip] = ""
            $syncHash.Image[$ip] = ""
            $syncHash.ConnectedTo[$ip] = ""
            
            # Default SNMPv3 params for migrated TXT lines
            $syncHash.SnmpVersion[$ip] = "v2c"
            $syncHash.SnmpUser[$ip] = ""
            $syncHash.SnmpAuthProto[$ip] = "none"
            $syncHash.SnmpAuthPass[$ip] = ""
            $syncHash.SnmpPrivProto[$ip] = "none"
            $syncHash.SnmpPrivPass[$ip] = ""
            
            $migratedArray += @{
                ip = $ip; community = $comm; name = $ip; enabled = $true; group = ""; image = ""; connectedTo = ""
                snmpVersion = "v2c"; snmpUser = ""; snmpAuthProto = "none"; snmpAuthPass = ""; snmpPrivProto = "none"; snmpPrivPass = ""
            }
        }
    }
    if ($migratedArray.Count -gt 0) {
        $migratedArray | ConvertTo-Json -Depth 5 -Compress | Out-File -FilePath $devicesFileJson -Encoding UTF8
    }
}
$syncHash.Devices = $cleanLines.ToArray()

$saveDevicesJsonScript = {
    function Save-DevicesJson {
        # -Routine: 機器のドラッグや自動検出のような頻繁な保存。スナップショットは 1 分に 1 回に間引く
        # それ以外 (追加・編集・削除・インポートなど) は、元に戻せるよう必ずスナップショットを取る
        param([switch]$Routine)
# 起動時に devices.json もスナップショットも読めなかった場合は、空の一覧で上書きして機器が全部消えないよう保存しない
        if ($syncHash.DevicesLoadFailed) {
            try { [System.IO.File]::AppendAllText((Join-Path $syncHash.PSScriptRoot "debug.log"), "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] Save-DevicesJson skipped: devices.json could not be loaded at startup`r`n", [System.Text.Encoding]::UTF8) } catch {}
            return
        }
        # Issue 5: $syncHash全体ではなく専用のDevicesLockオブジェクトのみをロックし、Pingループをブロックしない
        [System.Threading.Monitor]::Enter($syncHash.DevicesLock)
        try {
            $outArray = @()
            foreach ($ip in $syncHash.Devices) {
                $devObj = @{
                    ip            = $ip
                    community     = if ($syncHash.Community.ContainsKey($ip)) { $syncHash.Community[$ip] } else { "public" }
                    name          = if ($syncHash.DeviceName.ContainsKey($ip)) { $syncHash.DeviceName[$ip] } else { $ip }
                    enabled       = if ($syncHash.IsMonitored.ContainsKey($ip)) { $syncHash.IsMonitored[$ip] } else { $true }
                    group         = if ($syncHash.Group.ContainsKey($ip)) { $syncHash.Group[$ip] } else { "" }
                    image         = if ($syncHash.Image.ContainsKey($ip)) { $syncHash.Image[$ip] } else { "" }
                    connectedTo   = if ($syncHash.ConnectedTo.ContainsKey($ip)) { $syncHash.ConnectedTo[$ip] } else { "" }
                    x             = if ($syncHash.X.ContainsKey($ip)) { $syncHash.X[$ip] } else { $null }
                    y             = if ($syncHash.Y.ContainsKey($ip)) { $syncHash.Y[$ip] } else { $null }
                    mac           = if ($syncHash.Mac.ContainsKey($ip)) { $syncHash.Mac[$ip] } else { "" }
                    vendorContact = if ($syncHash.VendorContact.ContainsKey($ip)) { $syncHash.VendorContact[$ip] } else { "" }
                    deviceType    = if ($syncHash.DeviceType.ContainsKey($ip)) { $syncHash.DeviceType[$ip] } else { "network" }
                    webUrl        = if ($syncHash.WebUrl.ContainsKey($ip)) { $syncHash.WebUrl[$ip] } else { "" }
                    checkType     = if ($syncHash.CheckType.ContainsKey($ip)) { $syncHash.CheckType[$ip] } else { "icmp" }
                    port          = if ($syncHash.Port.ContainsKey($ip)) { $syncHash.Port[$ip] } else { 0 }
                    
                    # SNMPv3 properties (DPAPI暗号化保存)
                    snmpVersion   = if ($syncHash.SnmpVersion.ContainsKey($ip)) { $syncHash.SnmpVersion[$ip] } else { "v2c" }
                    snmpUser      = if ($syncHash.SnmpUser.ContainsKey($ip)) { $syncHash.SnmpUser[$ip] } else { "" }
                    snmpAuthProto = if ($syncHash.SnmpAuthProto.ContainsKey($ip)) { $syncHash.SnmpAuthProto[$ip] } else { "none" }
                    snmpAuthPass  = if ($syncHash.SnmpAuthPass.ContainsKey($ip) -and $syncHash.SnmpAuthPass[$ip]) { Protect-SecretString $syncHash.SnmpAuthPass[$ip] } else { "" }
                    snmpPrivProto = if ($syncHash.SnmpPrivProto.ContainsKey($ip)) { $syncHash.SnmpPrivProto[$ip] } else { "none" }
                    snmpPrivPass  = if ($syncHash.SnmpPrivPass.ContainsKey($ip) -and $syncHash.SnmpPrivPass[$ip]) { Protect-SecretString $syncHash.SnmpPrivPass[$ip] } else { "" }
                    obrEnabled    = if ($syncHash.ObrEnabled.ContainsKey($ip)) { [bool]$syncHash.ObrEnabled[$ip] } else { $false }
                    obrPassword   = if ($syncHash.ObrPassword.ContainsKey($ip)) { [string]$syncHash.ObrPassword[$ip] } else { "" }
                }

                # Remote execution properties (DPAPI暗号化保存)
                if ($syncHash.Remote -and $syncHash.Remote.ContainsKey($ip) -and $null -ne $syncHash.Remote[$ip]) {
                    $rawRemote = $syncHash.Remote[$ip]
                    $rHash = @{}
                    if ($rawRemote -is [System.Collections.IDictionary]) {
                        foreach ($k in $rawRemote.Keys) { $rHash[$k] = $rawRemote[$k] }
                    }
                    elseif ($null -ne $rawRemote.PSObject) {
                        foreach ($prop in $rawRemote.PSObject.Properties) { $rHash[$prop.Name] = $prop.Value }
                    }
                    if ($rHash.ContainsKey('password') -and -not [string]::IsNullOrWhiteSpace($rHash['password'])) {
                        $rHash['password'] = Protect-SecretString ([string]$rHash['password'])
                    }
                    $devObj['remote'] = $rHash
                }

                $outArray += $devObj
            }
            $jsonStr = ConvertTo-Json -InputObject $outArray -Depth 5
            
            $devicesFileJson = Join-Path $syncHash.PSScriptRoot "devices.json"
            for ($retry = 0; $retry -lt 5; $retry++) {
                $tmpFile = "$devicesFileJson.$([Guid]::NewGuid().ToString('N')).tmp"
                try {
                    try {
                        $jsonStr | Out-File -FilePath $tmpFile -Encoding UTF8
                        # 変更前の devices.json を自動スナップショット退避
                        if (Test-Path $devicesFileJson) {
                            $null = Backup-ConfigSnapshot -targetFilePath $devicesFileJson -backupDir $syncHash.BackupDir -minIntervalSec $(if ($Routine) { 60 } else { 0 })
}
                        Move-Item -Path $tmpFile -Destination $devicesFileJson -Force
                        break
                    }
                    finally {
                        if (Test-Path $tmpFile) {
                            try { Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue } catch {}
                        }
                    }
                }
                catch {
                    try { [System.IO.File]::AppendAllText((Join-Path $syncHash.PSScriptRoot "debug.log"), "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] Save-DevicesJson error: $($_.Exception.Message)`r`n", [System.Text.Encoding]::UTF8) } catch {}
                    Start-Sleep -Milliseconds 100
                }
            }
        }
        finally {
            [System.Threading.Monitor]::Exit($syncHash.DevicesLock)
        }
    }
}

. ([scriptblock]::Create($saveDevicesJsonScript.ToString()))

$snmpHelpersScript = {
    # Dynamically load SharpSnmpLib if not already loaded (fast in-memory check first)
    $snmpModule = Get-Module -Name SNMP | Select-Object -First 1
    if (-not $snmpModule) {
        $snmpModule = Get-Module -ListAvailable SNMP | Select-Object -First 1
    }
    if ($snmpModule) {
        Import-Module $snmpModule.Path -ErrorAction SilentlyContinue
        $moduleDir = Split-Path $snmpModule.Path
        $dllPath = Join-Path $moduleDir "SharpSnmpLib.dll"
        if (Test-Path $dllPath) {
            Add-Type -Path $dllPath -ErrorAction SilentlyContinue
        }
    }

    function Invoke-SnmpGetUnified {
        param(
            [string]$IP,
            [int]$Port = 161,
            [string]$Community = "public",
            [string]$Version = "v2c",
            [string]$User = "",
            [string]$AuthProto = "none",
            [string]$AuthPass = "",
            [string]$PrivProto = "none",
            [string]$PrivPass = "",
            [string[]]$Oids,
            [int]$Timeout = 2000
        )
        # SNMP ライブラリが読み込まれていない環境 (SNMP モジュール未インストール等) では何もせず空を返す
        # (以前は呼び出しのたびに「型 [Lextm.SharpSnmpLib...] が見つかりません」で失敗し、機器ごと・数十秒ごとに
        #  debug.log へ同じエラーが書かれ続け、1日に数十MB 増えていた。理由は最初の1回だけ記録する)
        if (-not ("Lextm.SharpSnmpLib.ObjectIdentifier" -as [type])) {
            if (-not $syncHash.SnmpLibMissingLogged) {
                $syncHash.SnmpLibMissingLogged = $true
                try { [System.IO.File]::AppendAllText((Join-Path $syncHash.PSScriptRoot "debug.log"), "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] SNMP library (SharpSnmpLib) is not loaded. SNMP queries are skipped until the SNMP module is installed and the server is restarted.`r`n", [System.Text.Encoding]::UTF8) } catch {}
            }
            return $null
        }
        
        $ipAddr = [System.Net.IPAddress]::Parse($IP)
        $endpoint = New-Object System.Net.IPEndPoint $ipAddr, $Port
        
        if ($Version -eq "v3") {
            try {
                $discovery = New-Object Lextm.SharpSnmpLib.Messaging.Discovery 1, 1, 1024
                $report = [Lextm.SharpSnmpLib.Messaging.SnmpMessageExtension]::GetResponse($discovery, $Timeout, $endpoint)
                
                $authProvider = [Lextm.SharpSnmpLib.Security.DefaultPrivacyProvider]::DefaultPair.AuthenticationProvider
                if ($AuthProto -eq "MD5") {
                    $authProvider = New-Object Lextm.SharpSnmpLib.Security.MD5AuthenticationProvider (New-Object Lextm.SharpSnmpLib.OctetString $AuthPass)
                }
                elseif ($AuthProto -eq "SHA") {
                    $authProvider = New-Object Lextm.SharpSnmpLib.Security.SHA1AuthenticationProvider (New-Object Lextm.SharpSnmpLib.OctetString $AuthPass)
                }
                
                $privacyProvider = $null
                if ($PrivProto -eq "DES" -and $AuthProto -ne "none") {
                    $privacyProvider = New-Object Lextm.SharpSnmpLib.Security.DESPrivacyProvider (New-Object Lextm.SharpSnmpLib.OctetString $PrivPass), $authProvider
                }
                else {
                    $privacyProvider = New-Object Lextm.SharpSnmpLib.Security.DefaultPrivacyProvider $authProvider
                }
                
                $userObj = New-Object Lextm.SharpSnmpLib.Security.User (New-Object Lextm.SharpSnmpLib.OctetString $User), $privacyProvider
                $registry = New-Object Lextm.SharpSnmpLib.Security.UserRegistry
                $registry.Add($userObj) | Out-Null
                
                $variableList = New-Object Collections.Generic.List[Lextm.SharpSnmpLib.Variable]
                foreach ($oid in $Oids) {
                    $variableList.Add($(New-Object Lextm.SharpSnmpLib.Variable (New-Object Lextm.SharpSnmpLib.ObjectIdentifier $oid)))
                }
                
                $msgId = [Lextm.SharpSnmpLib.Messaging.Messenger]::NextMessageId
                $reqId = [Lextm.SharpSnmpLib.Messaging.Messenger]::NextRequestId
                $request = New-Object Lextm.SharpSnmpLib.Messaging.GetRequestMessage (
                    [Lextm.SharpSnmpLib.VersionCode]::V3,
                    $msgId,
                    $reqId,
                    (New-Object Lextm.SharpSnmpLib.OctetString $User),
                    $variableList,
                    $privacyProvider,
                    $report
                )
                
                $response = [Lextm.SharpSnmpLib.Messaging.SnmpMessageExtension]::GetResponse($request, $Timeout, $endpoint, $registry)
                $resVars = [Lextm.SharpSnmpLib.Messaging.SnmpMessageExtension]::Variables($response)
                
                foreach ($v in $resVars) {
                    New-Object PSObject -Property @{
                        OID  = $v.Id.ToString()
                        Data = $v.Data.ToString()
                    }
                }
            }
            catch {
                Write-Verbose "SNMPv3 Get Error for ${IP}: $($_.ToString())"
            }
        }
        else {
            $variableList = New-Object Collections.Generic.List[Lextm.SharpSnmpLib.Variable]
            foreach ($oid in $Oids) {
                $variableList.Add($(New-Object Lextm.SharpSnmpLib.ObjectIdentifier $oid))
            }
            try {
                $versionEnum = if ($Version -eq "V1" -or $Version -eq "v1") { [Lextm.SharpSnmpLib.VersionCode]::V1 } else { [Lextm.SharpSnmpLib.VersionCode]::V2 }
                $message = [Lextm.SharpSnmpLib.Messaging.Messenger]::Get(
                    $versionEnum, 
                    $endpoint, 
                    $Community, 
                    $variableList, 
                    $Timeout
                )
                foreach ($v in $message) {
                    New-Object PSObject -Property @{
                        OID  = $v.Id.ToString()
                        Data = $v.Data.ToString()
                    }
                }
            }
            catch {
                Write-Verbose "SNMPv2 Get Error for ${IP}: $($_.ToString())"
            }
        }
    }

    function Invoke-SnmpWalkUnified {
        param(
            [string]$IP,
            [int]$Port = 161,
            [string]$Community = "public",
            [string]$Version = "v2c",
            [string]$User = "",
            [string]$AuthProto = "none",
            [string]$AuthPass = "",
            [string]$PrivProto = "none",
            [string]$PrivPass = "",
            [string]$OIDStart,
            [int]$Timeout = 2000
        )
        # SNMP ライブラリが読み込まれていない環境 (SNMP モジュール未インストール等) では何もせず空を返す
        # (以前は呼び出しのたびに「型 [Lextm.SharpSnmpLib...] が見つかりません」で失敗し、機器ごと・数十秒ごとに
        #  debug.log へ同じエラーが書かれ続け、1日に数十MB 増えていた。理由は最初の1回だけ記録する)
        if (-not ("Lextm.SharpSnmpLib.ObjectIdentifier" -as [type])) {
            if (-not $syncHash.SnmpLibMissingLogged) {
                $syncHash.SnmpLibMissingLogged = $true
                try { [System.IO.File]::AppendAllText((Join-Path $syncHash.PSScriptRoot "debug.log"), "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] SNMP library (SharpSnmpLib) is not loaded. SNMP queries are skipped until the SNMP module is installed and the server is restarted.`r`n", [System.Text.Encoding]::UTF8) } catch {}
            }
            return $null
        }
        
        $ipAddr = [System.Net.IPAddress]::Parse($IP)
        $endpoint = New-Object System.Net.IPEndPoint $ipAddr, $Port
        $rootOid = New-Object Lextm.SharpSnmpLib.ObjectIdentifier $OIDStart
        
        if ($Version -eq "v3") {
            try {
                $discovery = New-Object Lextm.SharpSnmpLib.Messaging.Discovery 1, 1, 1024
                $report = [Lextm.SharpSnmpLib.Messaging.SnmpMessageExtension]::GetResponse($discovery, $Timeout, $endpoint)
                
                $authProvider = [Lextm.SharpSnmpLib.Security.DefaultPrivacyProvider]::DefaultPair.AuthenticationProvider
                if ($AuthProto -eq "MD5") {
                    $authProvider = New-Object Lextm.SharpSnmpLib.Security.MD5AuthenticationProvider (New-Object Lextm.SharpSnmpLib.OctetString $AuthPass)
                }
                elseif ($AuthProto -eq "SHA") {
                    $authProvider = New-Object Lextm.SharpSnmpLib.Security.SHA1AuthenticationProvider (New-Object Lextm.SharpSnmpLib.OctetString $AuthPass)
                }
                
                $privacyProvider = $null
                if ($PrivProto -eq "DES" -and $AuthProto -ne "none") {
                    $privacyProvider = New-Object Lextm.SharpSnmpLib.Security.DESPrivacyProvider (New-Object Lextm.SharpSnmpLib.OctetString $PrivPass), $authProvider
                }
                else {
                    $privacyProvider = New-Object Lextm.SharpSnmpLib.Security.DefaultPrivacyProvider $authProvider
                }
                
                $userObj = New-Object Lextm.SharpSnmpLib.Security.User (New-Object Lextm.SharpSnmpLib.OctetString $User), $privacyProvider
                $registry = New-Object Lextm.SharpSnmpLib.Security.UserRegistry
                $registry.Add($userObj) | Out-Null
                
                $currentOid = $rootOid
                $keepWalking = $true
                $safetyLimit = 200
                $count = 0
                
                while ($keepWalking -and $count -lt $safetyLimit) {
                    $count++
                    $variableList = New-Object Collections.Generic.List[Lextm.SharpSnmpLib.Variable]
                    $variableList.Add($(New-Object Lextm.SharpSnmpLib.Variable $currentOid))
                    
                    $msgId = [Lextm.SharpSnmpLib.Messaging.Messenger]::NextMessageId
                    $reqId = [Lextm.SharpSnmpLib.Messaging.Messenger]::NextRequestId
                    
                    $request = New-Object Lextm.SharpSnmpLib.Messaging.GetNextRequestMessage (
                        [Lextm.SharpSnmpLib.VersionCode]::V3,
                        $msgId,
                        $reqId,
                        (New-Object Lextm.SharpSnmpLib.OctetString $User),
                        $variableList,
                        $privacyProvider,
                        $report
                    )
                    
                    $response = [Lextm.SharpSnmpLib.Messaging.SnmpMessageExtension]::GetResponse($request, $Timeout, $endpoint, $registry)
                    $resVars = [Lextm.SharpSnmpLib.Messaging.SnmpMessageExtension]::Variables($response)
                    
                    if ($resVars.Count -eq 0) {
                        $keepWalking = $false
                    }
                    else {
                        $nextVar = $resVars[0]
                        $nextOid = $nextVar.Id
                        
                        if ($nextOid.ToString().StartsWith($rootOid.ToString())) {
                            New-Object PSObject -Property @{
                                OID  = $nextOid.ToString()
                                Data = $nextVar.Data.ToString()
                            }
                            $currentOid = $nextOid
                        }
                        else {
                            $keepWalking = $false
                        }
                    }
                }
            }
            catch {
                Write-Verbose "SNMPv3 Walk Error for ${IP}: $($_.ToString())"
            }
        }
        else {
            try {
                $results = New-Object Collections.Generic.List[Lextm.SharpSnmpLib.Variable]
                $versionEnum = if ($Version -eq "V1" -or $Version -eq "v1") { [Lextm.SharpSnmpLib.VersionCode]::V1 } else { [Lextm.SharpSnmpLib.VersionCode]::V2 }
                [Lextm.SharpSnmpLib.Messaging.Messenger]::Walk(
                    $versionEnum, 
                    $endpoint, 
                    $Community, 
                    $rootOid, 
                    $results, 
                    $Timeout, 
                    [Lextm.SharpSnmpLib.Messaging.WalkMode]::WithinSubtree
                ) | Out-Null
                
                foreach ($v in $results) {
                    New-Object PSObject -Property @{
                        OID  = $v.Id.ToString()
                        Data = $v.Data.ToString()
                    }
                }
            }
            catch {
                Write-Verbose "SNMPv2 Walk Error for ${IP}: $($_.ToString())"
            }
        }
    }
}

# Dot-source the SNMP helpers script block in the main thread scope immediately
. ([scriptblock]::Create($snmpHelpersScript.ToString()))

# Define Session Directory immediately
$sessionTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$ReportsDir = Join-Path $rootDir "Reports"
$sessionDir = Join-Path $ReportsDir $sessionTimestamp
if (-not (Test-Path $sessionDir)) { New-Item -ItemType Directory -Path $sessionDir | Out-Null }

$syncHash.SessionDir = $sessionDir
$syncHash.SessionTimestamp = $sessionTimestamp

# Issue 8: debug.log ローテーション（起動時に1MBを超えていたらdebug_1.logにリネームして新規作成）
$debugLogPath = Join-Path $PSScriptRoot "debug.log"
try {
    if ((Test-Path $debugLogPath) -and (Get-Item $debugLogPath).Length -gt 1MB) {
        $debugLogArchive = Join-Path $PSScriptRoot "debug_1.log"
        if (Test-Path $debugLogArchive) { Remove-Item $debugLogArchive -Force -ErrorAction SilentlyContinue }
        Move-Item -Path $debugLogPath -Destination $debugLogArchive -Force -ErrorAction SilentlyContinue
        Write-Host "debug.log rotated to debug_1.log" -ForegroundColor Gray
    }
}
catch {}

# Issue 1: 古いセッションレポートの自動クリーンアップ（起動時に保持日数を超過した過去ログをパージ）
if ($syncHash.LogRetentionDays -gt 0) {
    try {
        Invoke-PurgeOldReports -reportsDirectory $ReportsDir -retentionDays $syncHash.LogRetentionDays -activeSessionDir $syncHash.SessionDir | Out-Null
    }
    catch {}
}

function Initialize-DeviceLog {
    param([string]$ip)
    
    # 監視対象から一時停止されている機器の場合はログファイルを生成しない
    if ($syncHash.IsMonitored.ContainsKey($ip) -and -not $syncHash.IsMonitored[$ip]) {
        return
    }
    
    if (-not $syncHash.History.ContainsKey($ip)) {
        $syncHash.History[$ip] = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    }
    
    if (-not $syncHash.Stats.ContainsKey($ip)) {
        $syncHash.Stats[$ip] = [hashtable]::Synchronized(@{
                Total            = 0
                Success          = 0
                Failed           = 0
                MinLat           = [double]::MaxValue
                MaxLat           = 0.0
                SumLat           = 0.0
                LatCount         = 0
                OutageStartTime  = $null  # オフライン開始日時 [DateTime]
                CurrentOutageSec = 0.0    # 現在継続中のオフライン時間（秒）
                MaxOutageSec     = 0.0    # 復帰完了した瞬断の中での最大時間（秒）
                Outage600msCount = 0      # 閾値1以上の瞬断回数
                Outage5sCount    = 0      # 閾値2以上の瞬断回数
                OutageEvents     = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new()) # 瞬断発生履歴明細
                RecentResults    = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new()) # 直近30回の結果(1/0)
                RecentLatencies  = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new()) # 直近30回の遅延
                PacketLossRate   = 0.0    # 直近パケットロス率 (%)
                Jitter           = 0.0    # 直近ジッター (ms)
                JitterSum        = 0.0    # セッション累計ジッター合計（平均算出用）
                JitterCount      = 0      # セッション累計ジッター計測回数
                PreviousStatus   = "Initial"
                OfflineNotified  = $false  # 障害通知 (Webhook/メール) を実際に送ったか。送った機器にだけ復旧通知を送る
                PendingOfflineAlert = $false  # 親機器の障害で通知を抑止中。親が復旧しても止まったままなら、その時点で通知する
})
    }
    
    if ($syncHash.LoggingEnabled -eq $false) {
        return
    }
    
    $safeIp = $ip -replace '[\\/:*?"<>|]', '_'
    $csvPath = Join-Path $syncHash.SessionDir "${safeIp}.csv"
    if (-not (Test-Path $csvPath)) {
        $header = "タイムスタンプ,IPアドレス,ステータス,遅延_ms,帯域_Mbps,送信_Mbps,受信_Mbps,瞬断継続_sec,ジッター_ms`r`n"
        try {
            [System.IO.File]::WriteAllText($csvPath, $header, [System.Text.Encoding]::GetEncoding(932))
        }
        catch {
            Write-Host "Error creating CSV log for $($ip): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# Helper: Safe CSV export with retries to prevent lock contention
function Safe-ExportCsv {
    param($Data, $Path, [switch]$Append)
    $retry = 0
    while ($retry -lt 5) {
        try {
            if ($Append) {
                $Data | Export-Csv -Path $Path -Append -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
            }
            else {
                $Data | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
            }
            return $true
        }
        catch {
            $retry++
            Start-Sleep -Milliseconds (100 * $retry)
        }
    }
    Write-Host "Failed to write to $Path after 5 retries." -ForegroundColor Red
    return $false
}

# Initialize logs for existing devices
Write-Host "Initializing logs for $($syncHash.Devices.Count) devices..." -ForegroundColor Cyan
foreach ($ip in $syncHash.Devices) {
    Initialize-DeviceLog -ip $ip
}

# ─────────────────────────────────────────
# 1. Start background PING runspace (1s loop)
# ─────────────────────────────────────────
$runspace = [runspacefactory]::CreateRunspace()
$runspace.ApartmentState = "STA"
$runspace.ThreadOptions = "ReuseThread"
$runspace.Open()
$runspace.SessionStateProxy.SetVariable("syncHash", $syncHash)

$pingScript = {
    # 依存モジュールの明示的インポート（独立 Runspace スコープ保護）
    Import-Module (Join-Path $syncHash.PSScriptRoot "modules\PingEngine.psm1") -DisableNameChecking -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $syncHash.PSScriptRoot "modules\Common.psm1") -DisableNameChecking -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $syncHash.PSScriptRoot "modules\AlertManager.psm1") -DisableNameChecking -Force -ErrorAction SilentlyContinue
    $alertModPath = Join-Path $syncHash.PSScriptRoot "modules\AlertManager.psm1"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastSlowPingTime = [DateTime]::MinValue
    $lastArpCheckTime = [DateTime]::MinValue
    # 超高速モードの低頻度Ping (5秒ごと) は次サイクル以降に結果を回収する (100msループを待たせない)
    $pendingSlowPings = @{}
    # 通知 (Webhook/メール) 送信用に作った PowerShell を、送信が終わったら片付けるための一覧
    # (以前は作りっぱなしで、通知1回ごとに約3MBが解放されずに残り、機器が不安定で通知が続くとメモリを使い続けていた)
    $alertJobs = [System.Collections.ArrayList]::new()

    while ($syncHash.Running) {
        $syncHash.LastPingLoopUtc = [DateTime]::UtcNow
        for ($ai = $alertJobs.Count - 1; $ai -ge 0; $ai--) {
            $aj = $alertJobs[$ai]
            if ($aj.Handle.IsCompleted) {
                try { $null = $aj.PS.EndInvoke($aj.Handle) } catch {}
                try { $aj.PS.Dispose() } catch {}
                $alertJobs.RemoveAt($ai)
            }
        }
        if ($syncHash.PollInterval -lt 0) {
            Start-Sleep -Seconds 2
            continue
        }
        $sw.Restart()
        $devices = $syncHash.Devices
        if ($null -eq $devices -or $devices.Count -eq 0) {
            Start-Sleep -Milliseconds 1000
            continue
        }

        # Ultra-high-frequency mode (PollInterval <= 100ms): Dual-Rate Monitoring
        $isUltraHighFreq = ($syncHash.PollInterval -gt 0 -and $syncHash.PollInterval -le 100)
        $ultraTargets = if ($isUltraHighFreq -and $syncHash.HighFreqTargetIps) {
            @($syncHash.HighFreqTargetIps -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | Select-Object -First 2)
        }
        else { @() }

        $now = [DateTime]::Now
        # In ultra-high-freq mode, non-target devices are polled at low-rate interval (5.0 seconds = 5000ms)
        $isSlowPingDue = ($isUltraHighFreq -and ($now - $lastSlowPingTime).TotalMilliseconds -ge 5000)
        if ($isSlowPingDue -or -not $isUltraHighFreq) {
            $lastSlowPingTime = $now
        }

        # Initiate asynchronous ping for devices
        $dataSize = if ($syncHash.PingDataSize) { [int]$syncHash.PingDataSize } else { 32 }
        $pingBuffer = New-Object byte[] $dataSize
        for ($i = 0; $i -lt $dataSize; $i++) { $pingBuffer[$i] = 0 }

        $tasks = foreach ($ip in $devices) {
            # Disabled by user in configuration
            if ($syncHash.IsMonitored.ContainsKey($ip) -and -not $syncHash.IsMonitored[$ip]) {
                [PSCustomObject]@{
                    IP = $ip; Ping = $null; Task = $null; Error = $false; Skipped = $true; KeepExisting = $false
                }
                continue
            }

            # Dual-rate filtering in ultra-high-frequency mode
            if ($isUltraHighFreq) {
                $isTarget = ($ultraTargets.Count -gt 0 -and $ip -in $ultraTargets)
                if (-not $isTarget -and (-not $isSlowPingDue -or $pendingSlowPings.ContainsKey($ip))) {
                    # Non-target device not due for slow ping: keep existing state without rewriting as Paused
                    [PSCustomObject]@{
                        IP = $ip; Ping = $null; Task = $null; Error = $false; Skipped = $true; KeepExisting = $true
                    }
                    continue
                }
            }

            $pingTimeoutMs = if ($isUltraHighFreq) {
                if ($ultraTargets.Count -gt 0 -and $ip -in $ultraTargets) {
                    [math]::Max(80, $syncHash.PollInterval)
                }
                else {
                    1000
                }
            }
            else {
                [math]::Min(1000, [math]::Max(200, $syncHash.PollInterval))
            }

            # ── TCPポート死活監視 または ICMP Ping の切り替え ──
            $isTcpCheck = ($syncHash.CheckType.ContainsKey($ip) -and $syncHash.CheckType[$ip] -eq "tcp" -and $syncHash.Port.ContainsKey($ip) -and $syncHash.Port[$ip] -gt 0)
            if ($isTcpCheck) {
                $targetPort = [int]$syncHash.Port[$ip]
                try {
                    # 非同期に接続し、接続が終わった時点の所要時間 (ms) を結果として受け取る (失敗は -1)
                    # (以前の Task.Factory.FromAsync($tcpClient.BeginConnect, ...) は PowerShell では引数を合わせられず
                    #  必ず失敗し、TCP 監視の機器は常に「Error/Failed」になっていた)
                    $task = [NdmTcpProbe]::ConnectTimed($ip, $targetPort)
                    [PSCustomObject]@{
                        IP = $ip; Ping = $null; TcpClient = $null; Task = $task; Stopwatch = $null; IsTcp = $true; Port = $targetPort; Error = $false; Skipped = $false; KeepExisting = $false
                    }
                }
                catch {
                    [PSCustomObject]@{
                        IP = $ip; Ping = $null; TcpClient = $null; Task = $null; Stopwatch = $null; IsTcp = $true; Port = $targetPort; Error = $true; Skipped = $false; KeepExisting = $false
                    }
                }
                continue
            }

            $ping = New-Object System.Net.NetworkInformation.Ping
            try {
                $task = $ping.SendPingAsync($ip, $pingTimeoutMs, $pingBuffer)
                [PSCustomObject]@{
                    IP = $ip; Ping = $ping; TcpClient = $null; Task = $task; Stopwatch = $null; IsTcp = $false; Port = 0; Error = $false; Skipped = $false; KeepExisting = $false
                }
            }
            catch {
                [PSCustomObject]@{
                    IP = $ip; Ping = $ping; TcpClient = $null; Task = $null; Stopwatch = $null; IsTcp = $false; Port = 0; Error = $true; Skipped = $false; KeepExisting = $false
                }
            }
        }

        # 超高速モード: 対象外機器の低頻度Ping (タイムアウト1000ms) は保留リストへ移し、
        # 100msループをブロックせずに完了したものから後続サイクルで回収する
        if ($isUltraHighFreq) {
            $cycleTasks = [System.Collections.Generic.List[object]]::new()
            foreach ($t in @($tasks)) {
                if ($null -ne $t.Task -and -not ($ultraTargets.Count -gt 0 -and $t.IP -in $ultraTargets)) {
                    $pendingSlowPings[$t.IP] = @{ Item = $t; StartedAt = [DateTime]::UtcNow }
                }
                else {
                    $cycleTasks.Add($t)
                }
            }
            $tasks = $cycleTasks
        }
        elseif ($pendingSlowPings.Count -gt 0) {
            # 通常モードへ戻った場合は保留分を破棄 (今サイクルで改めて全機器をPing済み)
            foreach ($p in $pendingSlowPings.Values) {
                try { if ($null -ne $p.Item.Ping) { $p.Item.Ping.Dispose() } } catch {}
                try { if ($null -ne $p.Item.TcpClient) { $p.Item.TcpClient.Close(); $p.Item.TcpClient.Dispose() } } catch {}
            }
            $pendingSlowPings.Clear()
        }

        # Wait for all active pings to complete (up to PollInterval or 1000ms)
        $waitTimeout = if ($isUltraHighFreq) { [math]::Max(80, $syncHash.PollInterval) } else { if ($syncHash.PollInterval -gt 0) { $syncHash.PollInterval } else { 1000 } }
        $validTasks = @($tasks | Where-Object { $null -ne $_.Task })
        if ($validTasks.Count -gt 0) {
            try {
                $taskArray = [System.Threading.Tasks.Task[]]($validTasks.Task)
                [System.Threading.Tasks.Task]::WaitAll($taskArray, $waitTimeout) | Out-Null
            }
            catch { }
            # Issue 4: 未完了タスクをさらに短時間待機してからDisposeし、リソースリークを防ぐ
            # (機器ごとに50ms待つと台数分ループが止まるため、未完了分をまとめて最大50msだけ待機)
            $unfinished = @($validTasks | Where-Object { -not $_.Task.IsCompleted })
            if ($unfinished.Count -gt 0) {
                try { [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]($unfinished.Task), 50) | Out-Null } catch { }
            }
        }

        # 保留中の低頻度Pingのうち、完了したもの (またはTCP接続が1.5秒を超えたもの) を今サイクルで処理する
        if ($isUltraHighFreq -and $pendingSlowPings.Count -gt 0) {
            $collected = [System.Collections.Generic.List[object]]::new($tasks)
            foreach ($pIp in @($pendingSlowPings.Keys)) {
                $p = $pendingSlowPings[$pIp]
                if ($p.Item.Task.IsCompleted -or ([DateTime]::UtcNow - $p.StartedAt).TotalMilliseconds -ge 1500) {
                    $collected.Add($p.Item)
                    $pendingSlowPings.Remove($pIp)
                }
            }
            $tasks = $collected
        }

        # Process results
        foreach ($t in $tasks) {
            $ip = $t.IP
            if ($t.KeepExisting) {
                # Non-target during dual-rate intermediate cycle: keep last status without modification
                continue
            }

            $reply = $null
            $chkType = if ($t.IsTcp) { "tcp" } else { "icmp" }
            if ($t.Skipped) {
                $syncHash.Status[$ip] = @{ status = "Paused"; rawStatus = "Paused"; latency = $null; checkType = $chkType; port = $t.Port; timestamp = (Get-Date).ToUniversalTime().ToString("o") }
                continue
            }
            elseif ($t.Error) {
                $syncHash.Status[$ip] = @{ status = "Error"; rawStatus = "Failed"; latency = $null; checkType = $chkType; port = $t.Port; timestamp = (Get-Date).ToUniversalTime().ToString("o") }
            }
            else {
                if ($t.IsTcp) {
                    if ($t.Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and $t.Task.Result -ge 0) {
                        $status = "Success"
                        $latency = [math]::Max(1, [int]$t.Task.Result)
                    }
                    else {
                        $status = "Failed"
                        $latency = $null
                    }
                    try { $t.TcpClient.Close(); $t.TcpClient.Dispose() } catch {}
                }
                else {
                    if ($t.Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
                        $reply = $t.Task.Result
                    }
                    $status = if ($reply -and $reply.Status -eq 'Success') { "Success" } else { "Failed" }
                    $latency = if ($status -eq "Success") { $reply.RoundtripTime } else { $null }
                }

                # ── 2段階ステータス判定 (Success / Warning / Failed) ──
                $stObj = $syncHash.Stats[$ip]
                $evalStatus = $status
                if ($null -ne $stObj) {
                    if ($status -eq "Success") {
                        $stObj.ConsecutiveFails = 0
                    }
                    else {
                        if ($null -eq $stObj.ConsecutiveFails) { $stObj.ConsecutiveFails = 0 }
                        $stObj.ConsecutiveFails = $stObj.ConsecutiveFails + 1
                    }
                    $latVal = if ($latency) { [double]$latency } else { 0.0 }
                    $warnThresh = if ($syncHash.LatencyWarningMs) { $syncHash.LatencyWarningMs } else { 80 }
                    $failThresh = if ($syncHash.ConsecutiveFailThresh) { $syncHash.ConsecutiveFailThresh } else { 2 }
                    $lossThresh = if ($syncHash.LossWarningThreshPercent) { [double]$syncHash.LossWarningThreshPercent } else { 5.0 }
                    $jitThresh = if ($syncHash.JitterWarningThreshMs) { [double]$syncHash.JitterWarningThreshMs } else { 20.0 }
                    $curLossRate = if ($null -ne $stObj.RecentResults -and $stObj.RecentResults.Count -gt 0) { $fCnt = $(if ($status -eq "Success") { 0 } else { 1 }); foreach ($r in $stObj.RecentResults) { if ($r -eq 0) { $fCnt++ } }; [math]::Round(($fCnt / [math]::Max(25, ($stObj.RecentResults.Count + 1))) * 100, 1) } elseif ($null -ne $stObj.PacketLossRate) { [double]$stObj.PacketLossRate } else { 0.0 }
                    $curJitter = if ($null -ne $stObj.Jitter) { [double]$stObj.Jitter } else { 0.0 }
                    try {
                        $evalStatus = Evaluate-DeviceStatus -isSuccess ($status -eq "Success") -latencyMs $latVal -consecutiveFails $stObj.ConsecutiveFails -latencyWarningMs $warnThresh -consecutiveFailThresh $failThresh -packetLossRate $curLossRate -lossWarningThreshPercent $lossThresh -jitterMs $curJitter -jitterWarningThreshMs $jitThresh
                    }
                    catch {
                        $evalStatus = $status
                    }
                }

                $syncHash.Status[$ip] = @{
                    status    = $evalStatus
                    rawStatus = $status
                    latency   = $latency
                    checkType = $chkType
                    port      = $t.Port
                    timestamp = (Get-Date).ToUniversalTime().ToString("o")
                }
            }

            # Record history as plain CSV string
            $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            $st = if ($syncHash.Status[$ip].status) { [string]$syncHash.Status[$ip].status } else { 'Unknown' }
            $lat = if ($syncHash.Status[$ip].latency -ne $null) { [string]$syncHash.Status[$ip].latency } else { '' }
            # 帯域_Mbps 列は常時の計測手段がないので「-」のまま残す (過去の CSV と列の並びをそろえるため)
            $bw = '-'

            # Outage duration for this record: 0 when online, current elapsed seconds when offline
            $outageSec = ''
            $statsNow = $syncHash.Stats[$ip]
            if ($null -ne $statsNow) {
                if ($st -eq 'Failed' -or $st -eq 'Error') {
                    $outageSec = if ($null -ne $statsNow.OutageStartTime) {
                        [math]::Round([math]::Max(0.0, ((Get-Date) - $statsNow.OutageStartTime).TotalSeconds), 1)
                    }
                    elseif ($statsNow.CurrentOutageSec -gt 0) {
                        [math]::Round($statsNow.CurrentOutageSec, 1)
                    }
                    else { 0.0 }
                }
                else {
                    $outageSec = ''   # empty = normal (online)
                }
            }

            $txStr = "-"; $rxStr = "-"
            if ($syncHash.Traffic.ContainsKey($ip) -and $null -ne $syncHash.Traffic[$ip]) {
                $txStr = [string]$syncHash.Traffic[$ip].tx
                $rxStr = [string]$syncHash.Traffic[$ip].rx
            }

            # Jitter for this record (ms) — calculated from recent 30 latency samples
            $jitterVal = if ($null -ne $statsNow -and $null -ne $statsNow.Jitter -and $statsNow.Jitter -gt 0) {
                [math]::Round($statsNow.Jitter, 2)
            }
            else { '' }

            $csvLine = "`"$ts`",`"$ip`",`"$st`",`"$lat`",`"$bw`",`"$txStr`",`"$rxStr`",`"$outageSec`",`"$jitterVal`""
            if ($syncHash.History.ContainsKey($ip)) {
                $historyQueue = $syncHash.History[$ip]
                $null = $historyQueue.Add($csvLine)
                # ドライブへの書き込みが止まったままだと保存処理側の上限が働かないので、ここでも古い記録を捨てて増えすぎを防ぐ
                if ($historyQueue.Count -gt 5500) {
                    [System.Threading.Monitor]::Enter($historyQueue.SyncRoot)
                    try { $historyQueue.RemoveRange(0, $historyQueue.Count - 5000) }
                    finally { [System.Threading.Monitor]::Exit($historyQueue.SyncRoot) }
                }
            }

            # Update stats
            $stats = $syncHash.Stats[$ip]
            if ($null -ne $stats) {
                [System.Threading.Monitor]::Enter($stats.SyncRoot)
                try {
                    $stats.Total = $stats.Total + 1
                    $devName = if ($syncHash.DeviceName.ContainsKey($ip)) { $syncHash.DeviceName[$ip] } else { $ip }
                    
                    # Track Recent Results (max 30 samples) - use RemoveRange for O(1) efficiency
                    $resVal = if ($status -eq "Success") { 1 } else { 0 }
                    $null = $stats.RecentResults.Add($resVal)
                    $excess = $stats.RecentResults.Count - 30
                    if ($excess -gt 0) { $stats.RecentResults.RemoveRange(0, $excess) }
                    
                    # Calculate Packet Loss Rate %
                    if ($stats.RecentResults.Count -gt 0) {
                        $failedRecent = 0
                        foreach ($r in $stats.RecentResults) { if ($r -eq 0) { $failedRecent++ } }
                        $stats.PacketLossRate = [math]::Round(($failedRecent / $stats.RecentResults.Count) * 100, 1)
                    }

                    # Dependency Check: is alert suppressed because all parent devices are offline?
                    $isSuppressed = $false
                    if ($syncHash.EnableParentSuppression -and $syncHash.ConnectedTo.ContainsKey($ip)) {
                        $parentStr = [string]$syncHash.ConnectedTo[$ip]
                        if (![string]::IsNullOrWhiteSpace($parentStr)) {
                            $parentIps = $parentStr -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
                            if ($parentIps.Count -gt 0) {
                                # 親が「障害 (Failed/Error/Offline)」と確認できた場合だけ抑制する
                                # (以前は Warning・Paused・削除済みの親も「ダウン」扱いになり、子機器の本物の障害通知が出なかった)
                                $allParentsDown = $true
                                foreach ($pIp in $parentIps) {
                                    $pSt = if ($syncHash.Status.ContainsKey($pIp)) { [string]$syncHash.Status[$pIp].status } else { "" }
                                    if ($pSt -notin @("Failed", "Error", "Offline")) {
                                        $allParentsDown = $false
                                        break
                                    }
                                }
                                if ($allParentsDown) {
                                    $isSuppressed = $true
                                }
                            }
                        }
                    }
                    if ($syncHash.Status.ContainsKey($ip)) {
                        $syncHash.Status[$ip].isSuppressed = $isSuppressed
                    }

                    if ($syncHash.Status[$ip].rawStatus -eq "Success") {
                        # Webhook & Email on recovery (Offline -> Online)
                        # 障害通知を送った機器にだけ復旧通知を送る (親機器ダウンで障害通知を抑止した子機器まで
                        # 親の復旧時に一斉に「復旧」を送り、抑止したはずの通知の嵐になっていた)
                        if ($stats.PreviousStatus -eq "Failed" -and $stats.OfflineNotified) {
                            if ($syncHash.WebhookEnabled) {
                                $webhookUrl = $syncHash.WebhookUrl
                                $capturedName = $devName; $capturedIp = $ip
                                $psWh = [powershell]::Create().AddScript({
                                        param($modPath, $url, $dName, $dIp)
                                        try {
                                            Import-Module $modPath -DisableNameChecking -ErrorAction SilentlyContinue
                                            Send-WebhookNotification -url $url -deviceName $dName -ip $dIp -eventType "online" -details "正常に応答が復旧しました。"
                                        }
                                        catch {}
                                    }).AddArgument($alertModPath).AddArgument($webhookUrl).AddArgument($capturedName).AddArgument($capturedIp)
                                $null = $alertJobs.Add(@{ PS = $psWh; Handle = $psWh.BeginInvoke() })
                            }
                            if ($syncHash.EmailEnabled -and $syncHash.SmtpHost -and $syncHash.SmtpTo) {
                                $sHost = $syncHash.SmtpHost; $sPort = $syncHash.SmtpPort; $sSsl = $syncHash.SmtpSsl
                                $sUser = $syncHash.SmtpUser; $sPass = $syncHash.SmtpPass; $sFrom = $syncHash.SmtpFrom; $sTo = $syncHash.SmtpTo
                                $capturedName = $devName; $capturedIp = $ip
                                $psEm = [powershell]::Create().AddScript({
                                        param($modPath, $sHost, $sPort, $sSsl, $sUser, $sPass, $sFrom, $sTo, $dName, $dIp)
                                        try {
                                            Import-Module $modPath -DisableNameChecking -ErrorAction SilentlyContinue
                                            $subj = "[復旧通知] ネットワーク機器 $dName ($dIp) がオンラインに復旧しました"
                                            $body = "ネットワーク機器 $dName ($dIp) のPing応答が正常に復旧しました。`n発生時刻: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
                                            $null = Send-EmailNotification -smtpHost $sHost -smtpPort $sPort -useSsl $sSsl -smtpUser $sUser -smtpPass $sPass -from $sFrom -to $sTo -subject $subj -body $body
                                        }
                                        catch {}
                                    }).AddArgument($alertModPath).AddArgument($sHost).AddArgument($sPort).AddArgument($sSsl).AddArgument($sUser).AddArgument($sPass).AddArgument($sFrom).AddArgument($sTo).AddArgument($capturedName).AddArgument($capturedIp)
                                $null = $alertJobs.Add(@{ PS = $psEm; Handle = $psEm.BeginInvoke() })
                            }
                        }
                        $stats.PreviousStatus = "Success"
                        $stats.OfflineNotified = $false
                        $stats.PendingOfflineAlert = $false

                        # Device recovered from offline: finalize outage duration & check thresholds
                        if ($null -ne $stats.OutageStartTime -or $stats.CurrentOutageSec -gt 0) {
                            $endTime = Get-Date
                            $startTime = if ($null -ne $stats.OutageStartTime) { $stats.OutageStartTime } else { $endTime.AddSeconds(-$stats.CurrentOutageSec) }
                            $outageDurationSec = [math]::Max(0.0, ($endTime - $startTime).TotalSeconds)
                            $durationMs = [math]::Round($outageDurationSec * 1000, 0)
                            
                            # Update max outage only on successful recovery
                            if ($outageDurationSec -gt $stats.MaxOutageSec) {
                                $stats.MaxOutageSec = $outageDurationSec
                            }
                            
                            # Count thresholds upon recovery
                            $thresh1Sec = [double]$syncHash.OutageThresh1Ms / 1000.0
                            $thresh2Sec = [double]$syncHash.OutageThresh2Ms / 1000.0
                            $isThresh1 = ($outageDurationSec -ge $thresh1Sec)
                            $isThresh2 = ($outageDurationSec -ge $thresh2Sec)
                            
                            if ($isThresh1) { $stats.Outage600msCount = $stats.Outage600msCount + 1 }
                            if ($isThresh2) { $stats.Outage5sCount = $stats.Outage5sCount + 1 }

                            # 規定閾値1以上の瞬断イベントを明細として記録（最大200件まで保持）
                            if ($isThresh1 -or $isThresh2) {
                                $categoryLabel = if ($isThresh2) {
                                    if ($syncHash.OutageThresh2Ms -ge 1000) { "$([int]($syncHash.OutageThresh2Ms/1000))s以上 (重大)" } else { "$($syncHash.OutageThresh2Ms)ms以上" }
                                }
                                else {
                                    "$($syncHash.OutageThresh1Ms)ms以上"
                                }
                                $ev = @{
                                    StartTime  = $startTime.ToString("yyyy-MM-dd HH:mm:ss")
                                    EndTime    = $endTime.ToString("yyyy-MM-dd HH:mm:ss")
                                    DurationMs = $durationMs
                                    Category   = $categoryLabel
                                }
                                if ($null -eq $stats.OutageEvents) {
                                    $stats.OutageEvents = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
                                }
                                [System.Threading.Monitor]::Enter($stats.OutageEvents.SyncRoot)
                                try {
                                    if ($stats.OutageEvents.Count -ge 200) { $stats.OutageEvents.RemoveAt(0) }
                                    $null = $stats.OutageEvents.Add($ev)
                                }
                                finally {
                                    [System.Threading.Monitor]::Exit($stats.OutageEvents.SyncRoot)
                                }
                            }
                            
                            # Reset current outage tracking
                            $stats.OutageStartTime = $null
                            $stats.CurrentOutageSec = 0.0
                        }
                        $stats.Success = $stats.Success + 1
                        if ($syncHash.Status[$ip].latency -ne $null) {
                            $latVal = [double]$syncHash.Status[$ip].latency
                            if ($latVal -lt $stats.MinLat) {
                                $stats.MinLat = $latVal
                            }
                            if ($latVal -gt $stats.MaxLat) {
                                $stats.MaxLat = $latVal
                            }
                            $stats.SumLat = $stats.SumLat + $latVal
                            $stats.LatCount = $stats.LatCount + 1

                            # Track Recent Latencies for Jitter calculation (RFC 3550) - RemoveRange for O(1)
                            $null = $stats.RecentLatencies.Add($latVal)
                            $excessLat = $stats.RecentLatencies.Count - 30
                            if ($excessLat -gt 0) { $stats.RecentLatencies.RemoveRange(0, $excessLat) }
                            if ($stats.RecentLatencies.Count -ge 2) {
                                $diffSum = 0.0
                                for ($idx = 1; $idx -lt $stats.RecentLatencies.Count; $idx++) {
                                    $diffSum += [math]::Abs([double]$stats.RecentLatencies[$idx] - [double]$stats.RecentLatencies[$idx - 1])
                                }
                                $stats.Jitter = [math]::Round($diffSum / ($stats.RecentLatencies.Count - 1), 2)
                                $stats.JitterSum = $stats.JitterSum + $stats.Jitter
                                $stats.JitterCount = $stats.JitterCount + 1
                            }
                        }
                    }
                    elseif ($syncHash.Status[$ip].rawStatus -ne "Success") {
                        # Webhook & Email on failure (Online -> Offline) only if not suppressed by parent offline
                        if (($st -eq "Failed" -or $st -eq "Error") -and ($stats.PreviousStatus -eq "Success" -or $stats.PendingOfflineAlert)) {
                            if (-not $isSuppressed) {
                                $stats.OfflineNotified = $true
                                $stats.PendingOfflineAlert = $false
if ($syncHash.WebhookEnabled) {
                                    $webhookUrl = $syncHash.WebhookUrl
                                    $capturedName = $devName; $capturedIp = $ip
                                    $psWh = [powershell]::Create().AddScript({
                                            param($modPath, $url, $dName, $dIp)
                                            try {
                                                Import-Module $modPath -DisableNameChecking -ErrorAction SilentlyContinue
                                                Send-WebhookNotification -url $url -deviceName $dName -ip $dIp -eventType "offline" -details "Ping応答が途絶しました。"
                                            }
                                            catch {}
                                        }).AddArgument($alertModPath).AddArgument($webhookUrl).AddArgument($capturedName).AddArgument($capturedIp)
                                    $null = $alertJobs.Add(@{ PS = $psWh; Handle = $psWh.BeginInvoke() })
                                }
                                if ($syncHash.EmailEnabled -and $syncHash.SmtpHost -and $syncHash.SmtpTo) {
                                    $sHost = $syncHash.SmtpHost; $sPort = $syncHash.SmtpPort; $sSsl = $syncHash.SmtpSsl
                                    $sUser = $syncHash.SmtpUser; $sPass = $syncHash.SmtpPass; $sFrom = $syncHash.SmtpFrom; $sTo = $syncHash.SmtpTo
                                    $capturedName = $devName; $capturedIp = $ip
                                    $psEm = [powershell]::Create().AddScript({
                                            param($modPath, $sHost, $sPort, $sSsl, $sUser, $sPass, $sFrom, $sTo, $dName, $dIp)
                                            try {
                                                Import-Module $modPath -DisableNameChecking -ErrorAction SilentlyContinue
                                                $subj = "[障害検知] ネットワーク機器 $dName ($dIp) がオフラインになりました"
                                                $body = "ネットワーク機器 $dName ($dIp) のPing応答が途絶しました。`n発生時刻: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
                                                $null = Send-EmailNotification -smtpHost $sHost -smtpPort $sPort -useSsl $sSsl -smtpUser $sUser -smtpPass $sPass -from $sFrom -to $sTo -subject $subj -body $body
                                            }
                                            catch {}
                                        }).AddArgument($alertModPath).AddArgument($sHost).AddArgument($sPort).AddArgument($sSsl).AddArgument($sUser).AddArgument($sPass).AddArgument($sFrom).AddArgument($sTo).AddArgument($capturedName).AddArgument($capturedIp)
                                    $null = $alertJobs.Add(@{ PS = $psEm; Handle = $psEm.BeginInvoke() })
                                }
                            }
                            elseif (-not $stats.PendingOfflineAlert) {
                                $stats.PendingOfflineAlert = $true
                                Write-Host "Alert suppressed for $ip (Parent device is down)" -ForegroundColor Yellow
                            }
}
                        if ($st -eq "Failed" -or $st -eq "Error") { $stats.PreviousStatus = "Failed" }

                        $stats.Failed = $stats.Failed + 1
                        
                        # Start or accumulate outage duration (do not update MaxOutageSec until recovery)
                        if ($null -eq $stats.OutageStartTime) {
                            $stats.OutageStartTime = Get-Date
                            $pollSec = if ($syncHash.PollInterval -gt 0) { [double]$syncHash.PollInterval / 1000.0 } else { 1.0 }
                            $stats.CurrentOutageSec = $pollSec
                        }
                        else {
                            $stats.CurrentOutageSec = ((Get-Date) - $stats.OutageStartTime).TotalSeconds
                        }
                    }
                }
                finally {
                    [System.Threading.Monitor]::Exit($stats.SyncRoot)
                }
            }
            if ($null -ne $t.Ping) {
                try { $t.Ping.Dispose() } catch {}
            }
        }

        # Record last ping loop timestamp for external watchdog health checking
        $syncHash.LastPingLoopUtc = [DateTime]::UtcNow

        $elapsed = $sw.ElapsedMilliseconds
        $targetInterval = if ($syncHash.PollInterval -gt 0) { $syncHash.PollInterval } else { 1000 }
        $sleepTime = $targetInterval - $elapsed
        if ($sleepTime -gt 0) {
            Start-Sleep -Milliseconds $sleepTime
        }
    }
}
$pipeline = $runspace.CreatePipeline()
$null = $pipeline.Commands.AddScript($pingScript)
$asyncResult = $pipeline.InvokeAsync()

# ─────────────────────────────────────────
# 1b. 記録ファイル書き込み専用 Runspace (CSV ログ: 10秒ごと / 統計チェックポイント: 60秒ごと)
# 以前は Ping 監視ループの中でファイルに書き込んでいたため、保存先のドライブ (Google ドライブの同期フォルダ等) が
# 書き込みで止まると Ping 監視そのものが止まり、障害の検知・通知もできなくなっていた。
# 書き込みを別スレッドに分け、ドライブが止まっても Ping 監視は動き続けるようにする。
# ─────────────────────────────────────────
$diskWriterRunspace = [runspacefactory]::CreateRunspace()
$diskWriterRunspace.ApartmentState = "STA"
$diskWriterRunspace.ThreadOptions = "ReuseThread"
$diskWriterRunspace.Open()
$diskWriterRunspace.SessionStateProxy.SetVariable("syncHash", $syncHash)
$diskWriterScript = {
    Import-Module (Join-Path $syncHash.PSScriptRoot "modules\ObrStatus.psm1") -DisableNameChecking -ErrorAction SilentlyContinue
    $lastObrFlushTime = [DateTime]::Now
    $lastFlushTime = [DateTime]::Now
$lastCheckpointTime = [DateTime]::Now   # 60秒ごとに Stats を _checkpoint.json へ保存
    while ($syncHash.Running) {
        # Real-time 10-second log flush to disk (reduces disk I/O significantly for up to 50 devices)
        if (([DateTime]::Now - $lastFlushTime).TotalSeconds -ge 10.0) {
            $lastFlushTime = [DateTime]::Now
            $devicesToFlush = $syncHash.Devices
            if ($syncHash.LoggingEnabled -eq $false) {
                # If logging is disabled, clear memory queues to prevent growth
                foreach ($ip in $devicesToFlush) {
                    $historyList = $syncHash.History[$ip]
                    if ($null -ne $historyList) {
                        [System.Threading.Monitor]::Enter($historyList.SyncRoot)
                        try { $historyList.Clear() } finally { [System.Threading.Monitor]::Exit($historyList.SyncRoot) }
                    }
                }
            }
            else {
                foreach ($ip in $devicesToFlush) {
                    $historyList = $syncHash.History[$ip]
                    if ($null -eq $historyList) { continue }
                    
                    $linesToSave = @()
                    [System.Threading.Monitor]::Enter($historyList.SyncRoot)
                    try {
                        if ($historyList.Count -gt 0) {
                            $linesToSave = $historyList.ToArray()
                        }
                    }
                    finally {
                        [System.Threading.Monitor]::Exit($historyList.SyncRoot)
                    }
                    
                    if ($linesToSave.Count -gt 0) {
                        $safeIp = $ip -replace '[\\/:*?"<>|]', '_'
                        $csvPath = Join-Path $syncHash.SessionDir "${safeIp}.csv"
                        
                        $writeSuccess = $false
                        try {
                            # CSV log rotation (max 10MB, keep up to 10 old files as _1.csv, _2.csv, etc. => max ~100MB per device)
                            if (Test-Path $csvPath) {
                                $fileInfo = Get-Item $csvPath
                                if ($fileInfo.Length -gt 10MB) {
                                    $maxRotations = 10
                                    for ($i = ($maxRotations - 1); $i -ge 1; $i--) {
                                        $oldPath = Join-Path $syncHash.SessionDir "${safeIp}_${i}.csv"
                                        $newPath = Join-Path $syncHash.SessionDir "${safeIp}_$( $i + 1 ).csv"
                                        if (Test-Path $oldPath) {
                                            Move-Item -Path $oldPath -Destination $newPath -Force
                                        }
                                    }
                                    Move-Item -Path $csvPath -Destination (Join-Path $syncHash.SessionDir "${safeIp}_1.csv") -Force
                                    $header = "タイムスタンプ,IPアドレス,ステータス,遅延_ms,帯域_Mbps,送信_Mbps,受信_Mbps,瞬断継続_sec,ジッター_ms`r`n"
                                    [System.IO.File]::WriteAllText($csvPath, $header, [System.Text.Encoding]::GetEncoding(932))
                                }
                            }
                            
                            $contentToAppend = ($linesToSave -join "`r`n") + "`r`n"
                            [System.IO.File]::AppendAllText($csvPath, $contentToAppend, [System.Text.Encoding]::GetEncoding(932))
                            $writeSuccess = $true
                        }
                        catch {
                            # CSV書き込み失敗をdebug.logに記録
                            try {
                                $errMsg = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] CSV write failed for ${ip}: $($_.Exception.Message)`r`n"
                                [System.IO.File]::AppendAllText((Join-Path $syncHash.PSScriptRoot "debug.log"), $errMsg, [System.Text.Encoding]::UTF8)
                            }
                            catch {}
                        }

                        if ($writeSuccess) {
                            $syncHash.LastDiskWriteUtc = [DateTime]::UtcNow
                            [System.Threading.Monitor]::Enter($historyList.SyncRoot)
try {
                                # 保存した分だけ取り除く。書き込み中に古い記録が捨てられていても、未保存の新しい記録を消さないよう
                                # 保存した最後の行の位置を探して、そこまでを取り除く
                                $lastSaved = $linesToSave[$linesToSave.Count - 1]
                                $searchEnd = [math]::Min($historyList.Count, $linesToSave.Count) - 1
                                for ($idx = $searchEnd; $idx -ge 0; $idx--) {
                                    if ([object]::ReferenceEquals($historyList[$idx], $lastSaved)) {
                                        $historyList.RemoveRange(0, $idx + 1)
                                        break
                                    }
                                }
}
                            finally {
                                [System.Threading.Monitor]::Exit($historyList.SyncRoot)
                            }
                        }
                        else {
                            # 書き込み失敗時: メモリキューが上限（5000件）を超えたら古いエントリを強制削除してメモリ暴走を防ぐ
                            [System.Threading.Monitor]::Enter($historyList.SyncRoot)
                            try {
                                $maxQueueSize = 5000
                                if ($historyList.Count -gt $maxQueueSize) {
                                    $dropCount = $historyList.Count - $maxQueueSize
                                    $historyList.RemoveRange(0, $dropCount)
                                }
                            }
                            finally {
                                [System.Threading.Monitor]::Exit($historyList.SyncRoot)
                            }
                        }
                    }
                }
            }
        }

        # ── 60-second Stats checkpoint → _checkpoint.json ──────────────────
        # Writes current Stats to disk every 60s so that even on forced termination
        # the latest counters (total pings, packet loss, jitter avg, max outage…) are preserved.
        if (([DateTime]::Now - $lastCheckpointTime).TotalSeconds -ge 60.0 -and $syncHash.LoggingEnabled -ne $false) {
            try {
                $checkpoint = @{}
                foreach ($ip in $syncHash.Devices) {
                    $s = $syncHash.Stats[$ip]
                    if ($null -eq $s) { continue }
                    $checkpoint[$ip] = @{
                        savedAt      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                        total        = $s.Total
                        success      = $s.Success
                        failed       = $s.Failed
                        reachRate    = if ($s.Total -gt 0) { [math]::Round($s.Success / $s.Total * 100, 2) } else { 0 }
                        packetLoss   = if ($s.Total -gt 0) { [math]::Round($s.Failed / $s.Total * 100, 1) } else { 0 }
                        minLat       = if ($s.LatCount -gt 0 -and $s.MinLat -ne [double]::MaxValue) { $s.MinLat } else { $null }
                        maxLat       = if ($s.LatCount -gt 0) { $s.MaxLat } else { $null }
                        avgLat       = if ($s.LatCount -gt 0) { [math]::Round($s.SumLat / $s.LatCount, 2) } else { $null }
                        maxOutageSec = if ($s.MaxOutageSec -gt 0) { [math]::Round($s.MaxOutageSec, 1) } else { 0 }
                        avgJitter    = if ($s.JitterCount -gt 0) { [math]::Round($s.JitterSum / $s.JitterCount, 2) } else { $null }
                        outage600ms  = $s.Outage600msCount
                        outage5s     = $s.Outage5sCount
                    }
                }
                $cpJson = $checkpoint | ConvertTo-Json -Depth 4
                $cpPath = Join-Path $syncHash.SessionDir "_checkpoint.json"
                [System.IO.File]::WriteAllText($cpPath, $cpJson, [System.Text.Encoding]::UTF8)
            }
            catch { } finally {
                $lastCheckpointTime = [DateTime]::Now
            }
        }


        # OBR の無線状態の履歴 (10 秒ごと)。書き込めなかった分は待ち行列に戻して次回書き直す
        if (([DateTime]::Now - $lastObrFlushTime).TotalSeconds -ge 10.0 -and $syncHash.ObrHistoryQueue.Count -gt 0) {
            $lastObrFlushTime = [DateTime]::Now
            $obrQueue = $syncHash.ObrHistoryQueue
            [System.Threading.Monitor]::Enter($obrQueue.SyncRoot)
            try { $obrRows = $obrQueue.ToArray(); $obrQueue.Clear() }
            finally { [System.Threading.Monitor]::Exit($obrQueue.SyncRoot) }
            if (-not (Write-ObrHistoryRows -SessionDir $syncHash.SessionDir -Rows $obrRows)) {
                [System.Threading.Monitor]::Enter($obrQueue.SyncRoot)
                try { $obrQueue.InsertRange(0, $obrRows) }
                finally { [System.Threading.Monitor]::Exit($obrQueue.SyncRoot) }
            }
        }
        Start-Sleep -Milliseconds 500
    }
}
$diskWriterPipeline = $diskWriterRunspace.CreatePipeline()
$null = $diskWriterPipeline.Commands.AddScript($diskWriterScript)
$diskWriterAsyncResult = $diskWriterPipeline.InvokeAsync()

# ─────────────────────────────────────────
# 2.5 Start background SNMP runspace (5s loop)
# ─────────────────────────────────────────
$snmpRunspace = [runspacefactory]::CreateRunspace()
$snmpRunspace.ApartmentState = "STA"
$snmpRunspace.ThreadOptions = "ReuseThread"
$snmpRunspace.Open()
$snmpRunspace.SessionStateProxy.SetVariable("syncHash", $syncHash)

$snmpScriptBlock = {
    $lastOctets = @{}
    $lastErrors = @{} # Store prev error counts: { ip = { ifIndex = { in=X, out=Y } } }
    $snmpFailedDevices = @{}
    $lastSnmpQueryTime = @{}
    
    while ($syncHash.Running) {
        try {
            if ($syncHash.PollInterval -lt 0) {
                Start-Sleep -Seconds 2
                continue
            }
            # Snapshot array reference for thread-safety (Issue 8)
            $devices = $syncHash.Devices
            if ($null -eq $devices -or $devices.Count -eq 0) {
                Start-Sleep -Seconds 2
                continue
            }

            foreach ($ip in $devices) {
                if ($syncHash.IsMonitored.ContainsKey($ip) -and -not $syncHash.IsMonitored[$ip]) {
                    $syncHash.Traffic[$ip] = @{ tx = "-"; rx = "-" }
                    continue
                }
                
                $now = Get-Date
                # Backoff for failed devices: 1 fail = 30s, 2 fails = 60s, 3+ fails = 120s (Issue 3)
                $failCount = if ($snmpFailedDevices.ContainsKey($ip)) { [int]$snmpFailedDevices[$ip] } else { 0 }
                if ($failCount -ge 1) {
                    $backoffSec = if ($failCount -ge 3) { 120 } elseif ($failCount -ge 2) { 60 } else { 30 }
                    if ($lastSnmpQueryTime.ContainsKey($ip)) {
                        $elapsed = ($now - $lastSnmpQueryTime[$ip]).TotalSeconds
                        if ($elapsed -lt $backoffSec) {
                            continue
                        }
                    }
                }
                
                $comm = if ($syncHash.Community.ContainsKey($ip)) { $syncHash.Community[$ip] } else { "public" }
                # 応答がある機器 (正常・警告) は通信量を取得する
                # (以前は「正常」のみで、揺らぎ等で「警告」になった機器は通信量が表示されなかった)
                if ($syncHash.Status.ContainsKey($ip) -and $syncHash.Status[$ip].status -in @("Success", "Warning")) {
                    $lastSnmpQueryTime[$ip] = $now
                    try {
                        $version = if ($syncHash.SnmpVersion.ContainsKey($ip)) { $syncHash.SnmpVersion[$ip] } else { "v2c" }
                        $user = if ($syncHash.SnmpUser.ContainsKey($ip)) { $syncHash.SnmpUser[$ip] } else { "" }
                        $authProto = if ($syncHash.SnmpAuthProto.ContainsKey($ip)) { $syncHash.SnmpAuthProto[$ip] } else { "none" }
                        $authPass = if ($syncHash.SnmpAuthPass.ContainsKey($ip)) { $syncHash.SnmpAuthPass[$ip] } else { "" }
                        $privProto = if ($syncHash.SnmpPrivProto.ContainsKey($ip)) { $syncHash.SnmpPrivProto[$ip] } else { "none" }
                        $privPass = if ($syncHash.SnmpPrivPass.ContainsKey($ip)) { $syncHash.SnmpPrivPass[$ip] } else { "" }

                        # Initial probe (InOctets): if this times out, skip all subsequent 5 OID queries immediately (Issue 3)
                        $inData = Invoke-SnmpWalkUnified -IP $ip -Community $comm -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart "1.3.6.1.2.1.2.2.1.10" -TimeOut 800 -ErrorAction SilentlyContinue
                        if (-not $inData) {
                            $snmpFailedDevices[$ip] = [int]($snmpFailedDevices[$ip]) + 1
                            $syncHash.Traffic[$ip] = @{ tx = "-"; rx = "-" }
                            continue
                        }

                        $outData = Invoke-SnmpWalkUnified -IP $ip -Community $comm -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart "1.3.6.1.2.1.2.2.1.16" -TimeOut 800 -ErrorAction SilentlyContinue
                        
                        # Fetch Error and Discard counters
                        $inErrData = Invoke-SnmpWalkUnified -IP $ip -Community $comm -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart "1.3.6.1.2.1.2.2.1.14" -TimeOut 800 -ErrorAction SilentlyContinue
                        $outErrData = Invoke-SnmpWalkUnified -IP $ip -Community $comm -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart "1.3.6.1.2.1.2.2.1.20" -TimeOut 800 -ErrorAction SilentlyContinue
                        $inDiscData = Invoke-SnmpWalkUnified -IP $ip -Community $comm -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart "1.3.6.1.2.1.2.2.1.13" -TimeOut 800 -ErrorAction SilentlyContinue
                        $outDiscData = Invoke-SnmpWalkUnified -IP $ip -Community $comm -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart "1.3.6.1.2.1.2.2.1.19" -TimeOut 800 -ErrorAction SilentlyContinue

                        if ($inData -and $outData) {
                            $snmpFailedDevices[$ip] = 0
                            # インターフェースごとのカウンタ値 (index -> octets)
                            # 合計してから差を取ると、1ポートのカウンタ一周・リセットで値が大きく狂う (負の値・数百Gbps等) ため、ポートごとに差分を取る
                            $inMap = @{}; $outMap = @{}
                            foreach ($x in $inData) { $ul = [uint64]0; if ([uint64]::TryParse([string]$x.Data, [ref]$ul)) { $inMap[([string]$x.OID -replace '^.*\.', '')] = [double]$ul } }
                            foreach ($x in $outData) { $ul = [uint64]0; if ([uint64]::TryParse([string]$x.Data, [ref]$ul)) { $outMap[([string]$x.OID -replace '^.*\.', '')] = [double]$ul } }
                            $counterDelta = {
                                param($curMap, $prevMap)
                                $sum = 0.0
                                foreach ($k in $curMap.Keys) {
                                    if ($null -eq $prevMap -or -not $prevMap.ContainsKey($k)) { continue }
                                    $d = $curMap[$k] - $prevMap[$k]
                                    if ($d -lt 0) { $d += 4294967296.0 }   # 32bitカウンタの一周
                                    if ($d -lt 0 -or $d -gt 4294967296.0) { $d = 0 }   # 機器再起動などによるカウンタリセットは0扱い
                                    $sum += $d
                                }
                                return $sum
                            }

                            if ($lastOctets.ContainsKey($ip) -and $lastOctets[$ip].inMap) {
                                $prev = $lastOctets[$ip]
                                $sec = ($now - $prev.time).TotalSeconds
                                if ($sec -gt 0) {
                                    $deltaIn = & $counterDelta $inMap $prev.inMap
                                    $deltaOut = & $counterDelta $outMap $prev.outMap
                                    
                                    $rxMbps = [math]::Round(($deltaIn * 8) / $sec / 1000000, 2)
                                    $txMbps = [math]::Round(($deltaOut * 8) / $sec / 1000000, 2)
                                    $syncHash.Traffic[$ip] = @{ tx = $txMbps; rx = $rxMbps }
                                }
                            }
                            else {
                                $syncHash.Traffic[$ip] = @{ tx = "Calc..."; rx = "Calc..." }
                            }
                            $lastOctets[$ip] = @{ inMap = $inMap; outMap = $outMap; time = $now }

                            # Process Errors and Discards
                            $currentIpErrors = @{}
                            foreach ($e in $inErrData) {
                                $idx = $e.Oid -replace '^.*\.1\.3\.6\.1\.2\.1\.2\.2\.1\.14\.', ''
                                if ($idx) {
                                    if (-not $currentIpErrors.ContainsKey($idx)) { $currentIpErrors[$idx] = @{ inErr = 0; outErr = 0; inDisc = 0; outDisc = 0; dInErr = 0; dOutErr = 0; dInDisc = 0; dOutDisc = 0 } }
                                    $currentIpErrors[$idx].inErr = [uint64]($e.Data)
                                }
                            }
                            foreach ($e in $outErrData) {
                                $idx = $e.Oid -replace '^.*\.1\.3\.6\.1\.2\.1\.2\.2\.1\.20\.', ''
                                if ($idx) {
                                    if (-not $currentIpErrors.ContainsKey($idx)) { $currentIpErrors[$idx] = @{ inErr = 0; outErr = 0; inDisc = 0; outDisc = 0; dInErr = 0; dOutErr = 0; dInDisc = 0; dOutDisc = 0 } }
                                    $currentIpErrors[$idx].outErr = [uint64]($e.Data)
                                }
                            }
                            foreach ($e in $inDiscData) {
                                $idx = $e.Oid -replace '^.*\.1\.3\.6\.1\.2\.1\.2\.2\.1\.13\.', ''
                                if ($idx) {
                                    if (-not $currentIpErrors.ContainsKey($idx)) { $currentIpErrors[$idx] = @{ inErr = 0; outErr = 0; inDisc = 0; outDisc = 0; dInErr = 0; dOutErr = 0; dInDisc = 0; dOutDisc = 0 } }
                                    $currentIpErrors[$idx].inDisc = [uint64]($e.Data)
                                }
                            }
                            foreach ($e in $outDiscData) {
                                $idx = $e.Oid -replace '^.*\.1\.3\.6\.1\.2\.1\.2\.2\.1\.19\.', ''
                                if ($idx) {
                                    if (-not $currentIpErrors.ContainsKey($idx)) { $currentIpErrors[$idx] = @{ inErr = 0; outErr = 0; inDisc = 0; outDisc = 0; dInErr = 0; dOutErr = 0; dInDisc = 0; dOutDisc = 0 } }
                                    $currentIpErrors[$idx].outDisc = [uint64]($e.Data)
                                }
                            }

                            if ($lastErrors.ContainsKey($ip)) {
                                foreach ($idx in $currentIpErrors.Keys) {
                                    if ($lastErrors[$ip].ContainsKey($idx)) {
                                        $prevE = $lastErrors[$ip][$idx]
                                        $currentIpErrors[$idx].dInErr = [math]::Max(0, $currentIpErrors[$idx].inErr - $prevE.inErr)
                                        $currentIpErrors[$idx].dOutErr = [math]::Max(0, $currentIpErrors[$idx].outErr - $prevE.outErr)
                                        $currentIpErrors[$idx].dInDisc = [math]::Max(0, $currentIpErrors[$idx].inDisc - $prevE.inDisc)
                                        $currentIpErrors[$idx].dOutDisc = [math]::Max(0, $currentIpErrors[$idx].outDisc - $prevE.outDisc)
                                    }
                                }
                            }
                            $lastErrors[$ip] = $currentIpErrors
                            $syncHash.InterfaceErrors[$ip] = $currentIpErrors
                        }
                        else {
                            $snmpFailedDevices[$ip] = [int]($snmpFailedDevices[$ip]) + 1
                            $syncHash.Traffic[$ip] = @{ tx = "-"; rx = "-" }
                        }
                    }
                    catch {
                        $snmpFailedDevices[$ip] = [int]($snmpFailedDevices[$ip]) + 1
                        $syncHash.Traffic[$ip] = @{ tx = "Error"; rx = "Error" }
                    }
                }
                else {
                    $syncHash.Traffic[$ip] = @{ tx = "-"; rx = "-" }
                }
            }
            $sleepSec = if ($null -ne $syncHash.PollInterval) { [math]::Max(5, [int]($syncHash.PollInterval / 1000)) } else { 5 }
            Start-Sleep -Seconds $sleepSec
        }
        catch {
            Start-Sleep -Seconds 2
        }
    }
}
$snmpScriptBlockCombined = [scriptblock]::Create($snmpHelpersScript.ToString() + "`n" + $snmpScriptBlock.ToString())
$snmpPipeline = $snmpRunspace.CreatePipeline()
$null = $snmpPipeline.Commands.AddScript($snmpScriptBlockCombined)
$snmpAsyncResult = $snmpPipeline.InvokeAsync()

# ─────────────────────────────────────────
# 2.7 Start background MAC address runspace (60s loop)
# Strategy: 1) ARP table (fast, Windows built-in)
#            2) SNMP ifPhysAddress fallback if ARP has no entry
# ─────────────────────────────────────────
$macRunspace = [runspacefactory]::CreateRunspace()
$macRunspace.ApartmentState = "STA"
$macRunspace.ThreadOptions = "ReuseThread"
$macRunspace.Open()
$macRunspace.SessionStateProxy.SetVariable("syncHash", $syncHash)

$macScriptBlock = {
    function Get-MacFromArp {
        param([string]$ip)
        try {
            # Ping first to populate ARP cache, then read arp table
            $null = & ping.exe -n 1 -w 500 $ip 2>$null
            $arpOut = & arp.exe -a $ip 2>$null | Out-String
            # Match lines like "  192.168.1.1    aa-bb-cc-dd-ee-ff    dynamic"
            if ($arpOut -match [regex]::Escape($ip) + '\s+([0-9a-fA-F]{2}[-:][0-9a-fA-F]{2}[-:][0-9a-fA-F]{2}[-:][0-9a-fA-F]{2}[-:][0-9a-fA-F]{2}[-:][0-9a-fA-F]{2})') {
                $mac = $matches[1].ToUpper() -replace '-', ':'
                return $mac
            }
        }
        catch {
            try { [System.IO.File]::AppendAllText((Join-Path $syncHash.PSScriptRoot "debug.log"), "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] Get-MacFromArp error for ${ip}: $($_.Exception.Message)`r`n", [System.Text.Encoding]::UTF8) } catch {}
        }
        return $null
    }

    function Get-MacFromSnmp {
        param([string]$ip, [string]$community)
        try {
            $version = if ($syncHash.SnmpVersion.ContainsKey($ip)) { $syncHash.SnmpVersion[$ip] } else { "v2c" }
            $user = if ($syncHash.SnmpUser.ContainsKey($ip)) { $syncHash.SnmpUser[$ip] } else { "" }
            $authProto = if ($syncHash.SnmpAuthProto.ContainsKey($ip)) { $syncHash.SnmpAuthProto[$ip] } else { "none" }
            $authPass = if ($syncHash.SnmpAuthPass.ContainsKey($ip)) { $syncHash.SnmpAuthPass[$ip] } else { "" }
            $privProto = if ($syncHash.SnmpPrivProto.ContainsKey($ip)) { $syncHash.SnmpPrivProto[$ip] } else { "none" }
            $privPass = if ($syncHash.SnmpPrivPass.ContainsKey($ip)) { $syncHash.SnmpPrivPass[$ip] } else { "" }

            # OID 1.3.6.1.2.1.2.2.1.6 = ifPhysAddress (MAC of each interface)
            $data = Invoke-SnmpWalkUnified -IP $ip -Community $community -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart '1.3.6.1.2.1.2.2.1.6' -TimeOut 2000 -ErrorAction SilentlyContinue
            foreach ($row in $data) {
                $raw = [string]$row.Data
                # Filter out null/loopback (all zeros or empty)
                if ([string]::IsNullOrWhiteSpace($raw) -or $raw -match '^(Null|0x00+)$') { continue }
                # Data may come as hex string "0xAABBCCDDEEFF" or byte array string
                if ($raw -match '^0x([0-9A-Fa-f]{12})$') {
                    $hex = $matches[1]
                    $mac = ($hex -split '(?<=\G.{2})(?=.)') -join ':'
                    return $mac.ToUpper()
                }
                # Try parsing as space/colon/dash separated hex
                $cleaned = $raw -replace '[-: ]', ''
                if ($cleaned -match '^[0-9A-Fa-f]{12}$') {
                    $mac = ($cleaned -split '(?<=\G.{2})(?=.)') -join ':'
                    return $mac.ToUpper()
                }
            }
        }
        catch {
            try { [System.IO.File]::AppendAllText((Join-Path $syncHash.PSScriptRoot "debug.log"), "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] Get-MacFromSnmp error for ${ip}: $($_.Exception.Message)`r`n", [System.Text.Encoding]::UTF8) } catch {}
        }
        return $null
    }

    # Wait a few seconds on first run for ping runspace to populate ARP cache
    Start-Sleep -Seconds 5
    $lastMacDiscoveryTime = [DateTime]::MinValue
    $lastArpCheckTime = [DateTime]::MinValue

    while ($syncHash.Running) {
        $now = [DateTime]::Now
        $devices = $syncHash.Devices

        # 1. IP conflict ARP check every 10s (moved out of 100ms Ping loop to prevent WMI/CIM stalls)
        if (($now - $lastArpCheckTime).TotalSeconds -ge 10) {
            $lastArpCheckTime = $now
            try {
                $arpEntries = @{}
                $neighbors = try { Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue } catch { $null }
                if ($neighbors) {
                    foreach ($n in $neighbors) {
                        if ($n.IPAddress -and $n.LinkLayerAddress -and $n.LinkLayerAddress -ne "00-00-00-00-00-00") {
                            $normMac = ($n.LinkLayerAddress -replace '[:-]', '-').ToUpper()
                            $arpEntries[$n.IPAddress] = $normMac
                        }
                    }
                }
                else {
                    $arpOut = try { arp -a } catch { $null }
                    if ($arpOut) {
                        foreach ($line in $arpOut) {
                            if ($line -match '^\s*(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+([0-9a-fA-F:-]{11,17})') {
                                $aIp = $matches[1]
                                $aMac = ($matches[2] -replace '[:-]', '-').ToUpper()
                                if ($aMac -ne "00-00-00-00-00-00" -and $aMac -ne "FF-FF-FF-FF-FF-FF") {
                                    $arpEntries[$aIp] = $aMac
                                }
                            }
                        }
                    }
                }

                if ($devices) {
                    foreach ($devIp in $devices) {
                        if ($arpEntries.ContainsKey($devIp)) {
                            $detectedMac = $arpEntries[$devIp]
                            $expectedMac = if ($syncHash.Mac -and $syncHash.Mac.ContainsKey($devIp) -and $syncHash.Mac[$devIp]) {
                                ($syncHash.Mac[$devIp] -replace '[:-]', '-').ToUpper()
                            }
                            else { "" }

                            $learnedMac = if ($syncHash.LearnedMac -and $syncHash.LearnedMac.ContainsKey($devIp)) {
                                $syncHash.LearnedMac[$devIp]
                            }
                            else { "" }

                            $isConflict = $false
                            $conflictReason = ""
                            if ($expectedMac -and $detectedMac -ne $expectedMac) {
                                $isConflict = $true
                                $conflictReason = "登録MAC ($expectedMac) と異なるMAC ($detectedMac) が応答"
                            }
                            elseif ($learnedMac -and $detectedMac -ne $learnedMac) {
                                $isConflict = $true
                                $conflictReason = "前回MAC ($learnedMac) から別MAC ($detectedMac) へ急変"
                            }

                            if ($isConflict) {
                                $devName = if ($syncHash.DeviceName -and $syncHash.DeviceName.ContainsKey($devIp)) { $syncHash.DeviceName[$devIp] } else { $devIp }
                                $prevConflict = if ($syncHash.IpConflicts.ContainsKey($devIp)) { $syncHash.IpConflicts[$devIp] } else { $null }
                                $sameMacCount = if ($null -ne $prevConflict -and $prevConflict.detectedMac -eq $detectedMac -and $prevConflict.stableCount) { [int]$prevConflict.stableCount + 1 } else { 1 }

                                # 登録MACが無く「前回MACからの変化」だけで検知している場合、新しいMACが約1分 (10秒×6回) 安定して
                                # 応答し続けたら機器交換・NIC交換とみなして学習し直す
                                # (以前は学習済みMACが更新されず、交換後は再起動するまで重複警告が出続けた)
                                if (-not $expectedMac -and $sameMacCount -ge 6) {
                                    if ($syncHash.LearnedMac) { $syncHash.LearnedMac[$devIp] = $detectedMac }
                                    $syncHash.IpConflicts.Remove($devIp)
                                }
                                else {
                                    $syncHash.IpConflicts[$devIp] = @{
                                        ip          = $devIp
                                        deviceName  = $devName
                                        expectedMac = if ($expectedMac) { $expectedMac } else { $learnedMac }
                                        detectedMac = $detectedMac
                                        reason      = $conflictReason
                                        detectedAt  = if ($null -ne $prevConflict -and $prevConflict.detectedMac -eq $detectedMac -and $prevConflict.detectedAt) { $prevConflict.detectedAt } else { [DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss") }
                                        stableCount = $sameMacCount
                                    }
                                }
                            }
                            else {
                                if ($syncHash.LearnedMac) { $syncHash.LearnedMac[$devIp] = $detectedMac }
                                if ($syncHash.IpConflicts -and $syncHash.IpConflicts.ContainsKey($devIp)) {
                                    $syncHash.IpConflicts.Remove($devIp)
                                }
                            }
                        }
                    }
                }
            }
            catch {}
        }

        # 2. Periodic MAC address discovery (every 60s for devices still missing MAC)
        if (($now - $lastMacDiscoveryTime).TotalSeconds -ge 60 -and $devices) {
            $lastMacDiscoveryTime = $now
            $changed = $false
            foreach ($ip in $devices) {
                if ($syncHash.IsMonitored.ContainsKey($ip) -and -not $syncHash.IsMonitored[$ip]) { continue }
                $existingMac = if ($syncHash.Mac.ContainsKey($ip)) { $syncHash.Mac[$ip] } else { "" }
                if (-not [string]::IsNullOrWhiteSpace($existingMac)) { continue }
                $mac = Get-MacFromArp -ip $ip
                if ([string]::IsNullOrWhiteSpace($mac)) {
                    $comm = if ($syncHash.Community.ContainsKey($ip)) { $syncHash.Community[$ip] } else { 'public' }
                    $mac = Get-MacFromSnmp -ip $ip -community $comm
                }
                if (-not [string]::IsNullOrWhiteSpace($mac) -and $mac -ne $existingMac) {
                    $syncHash.Mac[$ip] = $mac
                    $changed = $true
                }
            }
            if ($changed) { Save-DevicesJson -Routine }
}
        Start-Sleep -Seconds 2
    }
}
$macScriptBlockCombined = [scriptblock]::Create($snmpHelpersScript.ToString() + "`n" + $saveDevicesJsonScript.ToString() + "`n" + $macScriptBlock.ToString())
$macPipeline = $macRunspace.CreatePipeline()
$null = $macPipeline.Commands.AddScript($macScriptBlockCombined)
$macAsyncResult = $macPipeline.InvokeAsync()

# ─────────────────────────────────────────
# 2.9 Background SNMP Detail runspace (30s loop)
#   - Interface link speed  (ifHighSpeed / ifSpeed)
#   - Neighbor devices       (LLDP lldpRemSysName / Cisco CDP)
#   - Wireless frequency     (IEEE dot11CurrentChannel / Cisco LWAP)
# ─────────────────────────────────────────
$snmpDetailRunspace = [runspacefactory]::CreateRunspace()
$snmpDetailRunspace.ApartmentState = "STA"
$snmpDetailRunspace.ThreadOptions = "ReuseThread"
$snmpDetailRunspace.Open()
$snmpDetailRunspace.SessionStateProxy.SetVariable("syncHash", $syncHash)

$snmpDetailScriptBlock = {
    # Returns the highest interface speed detected on the device
    function Get-InterfaceSpeed {
        param([string]$ip, [string]$community)
        try {
            $version = if ($syncHash.SnmpVersion.ContainsKey($ip)) { $syncHash.SnmpVersion[$ip] } else { "v2c" }
            $user = if ($syncHash.SnmpUser.ContainsKey($ip)) { $syncHash.SnmpUser[$ip] } else { "" }
            $authProto = if ($syncHash.SnmpAuthProto.ContainsKey($ip)) { $syncHash.SnmpAuthProto[$ip] } else { "none" }
            $authPass = if ($syncHash.SnmpAuthPass.ContainsKey($ip)) { $syncHash.SnmpAuthPass[$ip] } else { "" }
            $privProto = if ($syncHash.SnmpPrivProto.ContainsKey($ip)) { $syncHash.SnmpPrivProto[$ip] } else { "none" }
            $privPass = if ($syncHash.SnmpPrivPass.ContainsKey($ip)) { $syncHash.SnmpPrivPass[$ip] } else { "" }

            # ifHighSpeed (OID .31) = Mbps, preferred for GigE and above
            $rows = Invoke-SnmpWalkUnified -IP $ip -Community $community -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart '1.3.6.1.2.1.31.1.1.1.15' -TimeOut 2000 -ErrorAction SilentlyContinue
            $max = 0
            foreach ($r in $rows) {
                if ($r.Data -notmatch 'Null|^0$' -and [int64]::TryParse([string]$r.Data, [ref]$null)) {
                    $v = [int64]$r.Data; if ($v -gt $max) { $max = $v }
                }
            }
            if ($max -gt 0) { return "${max} Mbps" }

            # Fallback: ifSpeed (OID .2) = bps
            $rows2 = Invoke-SnmpWalkUnified -IP $ip -Community $community -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart '1.3.6.1.2.1.2.2.1.5' -TimeOut 2000 -ErrorAction SilentlyContinue
            $maxBps = 0
            foreach ($r in $rows2) {
                if ($r.Data -notmatch 'Null|^0$' -and [int64]::TryParse([string]$r.Data, [ref]$null)) {
                    $v = [int64]$r.Data; if ($v -gt $maxBps) { $maxBps = $v }
                }
            }
            if ($maxBps -gt 0) {
                $m = [math]::Round($maxBps / 1000000)
                if ($m -ge 1000) { return "$(($m/1000)) Gbps" } else { return "${m} Mbps" }
            }
        }
        catch {
            try { [System.IO.File]::AppendAllText((Join-Path $syncHash.PSScriptRoot "debug.log"), "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] Get-InterfaceSpeed error for ${ip}: $($_.Exception.Message)`r`n", [System.Text.Encoding]::UTF8) } catch {}
        }
        return ''
    }

    # Returns comma-separated list of neighbor device names via LLDP or CDP
    function Get-Neighbors {
        param([string]$ip, [string]$community)
        $list = [System.Collections.Generic.List[string]]::new()
        try {
            $version = if ($syncHash.SnmpVersion.ContainsKey($ip)) { $syncHash.SnmpVersion[$ip] } else { "v2c" }
            $user = if ($syncHash.SnmpUser.ContainsKey($ip)) { $syncHash.SnmpUser[$ip] } else { "" }
            $authProto = if ($syncHash.SnmpAuthProto.ContainsKey($ip)) { $syncHash.SnmpAuthProto[$ip] } else { "none" }
            $authPass = if ($syncHash.SnmpAuthPass.ContainsKey($ip)) { $syncHash.SnmpAuthPass[$ip] } else { "" }
            $privProto = if ($syncHash.SnmpPrivProto.ContainsKey($ip)) { $syncHash.SnmpPrivProto[$ip] } else { "none" }
            $privPass = if ($syncHash.SnmpPrivPass.ContainsKey($ip)) { $syncHash.SnmpPrivPass[$ip] } else { "" }

            # LLDP: lldpRemSysName  1.0.8802.1.1.2.1.4.1.1.9
            $rows = Invoke-SnmpWalkUnified -IP $ip -Community $community -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart '1.0.8802.1.1.2.1.4.1.1.9' -TimeOut 2000 -ErrorAction SilentlyContinue
            foreach ($r in $rows) {
                $n = ([string]$r.Data).Trim()
                if ($n -and $n -ne 'Null' -and -not $list.Contains($n)) { $list.Add($n) }
            }
        }
        catch {
            try { [System.IO.File]::AppendAllText((Join-Path $syncHash.PSScriptRoot "debug.log"), "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] Get-Neighbors LLDP error for ${ip}: $($_.Exception.Message)`r`n", [System.Text.Encoding]::UTF8) } catch {}
        }
        if ($list.Count -eq 0) {
            try {
                $version = if ($syncHash.SnmpVersion.ContainsKey($ip)) { $syncHash.SnmpVersion[$ip] } else { "v2c" }
                $user = if ($syncHash.SnmpUser.ContainsKey($ip)) { $syncHash.SnmpUser[$ip] } else { "" }
                $authProto = if ($syncHash.SnmpAuthProto.ContainsKey($ip)) { $syncHash.SnmpAuthProto[$ip] } else { "none" }
                $authPass = if ($syncHash.SnmpAuthPass.ContainsKey($ip)) { $syncHash.SnmpAuthPass[$ip] } else { "" }
                $privProto = if ($syncHash.SnmpPrivProto.ContainsKey($ip)) { $syncHash.SnmpPrivProto[$ip] } else { "none" }
                $privPass = if ($syncHash.SnmpPrivPass.ContainsKey($ip)) { $syncHash.SnmpPrivPass[$ip] } else { "" }

                # CDP (Cisco): cdpCacheDeviceId  1.3.6.1.4.1.9.9.23.1.2.1.1.6
                $rows = Invoke-SnmpWalkUnified -IP $ip -Community $community -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart '1.3.6.1.4.1.9.9.23.1.2.1.1.6' -TimeOut 2000 -ErrorAction SilentlyContinue
                foreach ($r in $rows) {
                    $n = (([string]$r.Data).Trim() -split '\.')[0]   # strip FQDN
                    if ($n -and $n -ne 'Null' -and -not $list.Contains($n)) { $list.Add($n) }
                }
            }
            catch {
                try { [System.IO.File]::AppendAllText((Join-Path $syncHash.PSScriptRoot "debug.log"), "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] Get-Neighbors CDP error for ${ip}: $($_.Exception.Message)`r`n", [System.Text.Encoding]::UTF8) } catch {}
            }
        }
        return ($list | Select-Object -Unique) -join ', '
    }

    # Returns wireless band string, e.g. "5 GHz (Ch 36)"
    function Get-WirelessBand {
        param([string]$ip, [string]$community)
        try {
            $version = if ($syncHash.SnmpVersion.ContainsKey($ip)) { $syncHash.SnmpVersion[$ip] } else { "v2c" }
            $user = if ($syncHash.SnmpUser.ContainsKey($ip)) { $syncHash.SnmpUser[$ip] } else { "" }
            $authProto = if ($syncHash.SnmpAuthProto.ContainsKey($ip)) { $syncHash.SnmpAuthProto[$ip] } else { "none" }
            $authPass = if ($syncHash.SnmpAuthPass.ContainsKey($ip)) { $syncHash.SnmpAuthPass[$ip] } else { "" }
            $privProto = if ($syncHash.SnmpPrivProto.ContainsKey($ip)) { $syncHash.SnmpPrivProto[$ip] } else { "none" }
            $privPass = if ($syncHash.SnmpPrivPass.ContainsKey($ip)) { $syncHash.SnmpPrivPass[$ip] } else { "" }

            # IEEE 802.11 MIB: dot11CurrentChannel  1.2.840.10036.1.1.1.9
            $rows = Invoke-SnmpWalkUnified -IP $ip -Community $community -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart '1.2.840.10036.1.1.1.9' -TimeOut 2000 -ErrorAction SilentlyContinue
            foreach ($r in $rows) {
                $ch = $null
                if ([int]::TryParse([string]$r.Data, [ref]$null)) { $ch = [int]$r.Data }
                if ($null -ne $ch -and $ch -gt 0) {
                    if ($ch -le 14) { return "2.4 GHz (Ch $ch)" }
                    elseif ($ch -le 64) { return "5 GHz (Ch $ch)" }
                    elseif ($ch -le 177) { return "5 GHz (Ch $ch)" }
                    else { return "6 GHz (Ch $ch)" }
                }
            }

            # Cisco Lightweight AP: bsnAPIfPhyChannelNumber  1.3.6.1.4.1.14179.2.2.2.1.4
            $rows2 = Invoke-SnmpWalkUnified -IP $ip -Community $community -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart '1.3.6.1.4.1.14179.2.2.2.1.4' -TimeOut 2000 -ErrorAction SilentlyContinue
            foreach ($r in $rows2) {
                $ch = $null
                if ([int]::TryParse([string]$r.Data, [ref]$null)) { $ch = [int]$r.Data }
                if ($null -ne $ch -and $ch -gt 0) {
                    if ($ch -le 14) { return "2.4 GHz (Ch $ch)" } else { return "5 GHz (Ch $ch)" }
                }
            }

            # Cisco Autonomous AP: cDot11IfCurrentChannel  1.3.6.1.4.1.9.9.272.1.2.1.1
            $rows3 = Invoke-SnmpWalkUnified -IP $ip -Community $community -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart '1.3.6.1.4.1.9.9.272.1.2.1.1' -TimeOut 2000 -ErrorAction SilentlyContinue
            foreach ($r in $rows3) {
                $ch = $null
                if ([int]::TryParse([string]$r.Data, [ref]$null)) { $ch = [int]$r.Data }
                if ($null -ne $ch -and $ch -gt 0) {
                    if ($ch -le 14) { return "2.4 GHz (Ch $ch)" } else { return "5 GHz (Ch $ch)" }
                }
            }
        }
        catch {
            try { [System.IO.File]::AppendAllText((Join-Path $syncHash.PSScriptRoot "debug.log"), "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] Get-WirelessBand error for ${ip}: $($_.Exception.Message)`r`n", [System.Text.Encoding]::UTF8) } catch {}
        }
        return ''
    }

    # Returns a list of learned MAC addresses from the device's FDB table (Bridge MIB)
    function Get-FdbAddresses {
        param([string]$ip, [string]$community)
        $list = [System.Collections.Generic.List[string]]::new()
        try {
            $version = if ($syncHash.SnmpVersion.ContainsKey($ip)) { $syncHash.SnmpVersion[$ip] } else { "v2c" }
            $user = if ($syncHash.SnmpUser.ContainsKey($ip)) { $syncHash.SnmpUser[$ip] } else { "" }
            $authProto = if ($syncHash.SnmpAuthProto.ContainsKey($ip)) { $syncHash.SnmpAuthProto[$ip] } else { "none" }
            $authPass = if ($syncHash.SnmpAuthPass.ContainsKey($ip)) { $syncHash.SnmpAuthPass[$ip] } else { "" }
            $privProto = if ($syncHash.SnmpPrivProto.ContainsKey($ip)) { $syncHash.SnmpPrivProto[$ip] } else { "none" }
            $privPass = if ($syncHash.SnmpPrivPass.ContainsKey($ip)) { $syncHash.SnmpPrivPass[$ip] } else { "" }

            $rows = Invoke-SnmpWalkUnified -IP $ip -Community $community -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart '1.3.6.1.2.1.17.4.3.1.1' -TimeOut 2000 -ErrorAction SilentlyContinue
            foreach ($r in $rows) {
                $hex = ""
                if ($r.Data -match '^[0-9A-Fa-f]{12}$') {
                    $hex = $r.Data
                }
                elseif ($r.Data -match '^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$') {
                    $hex = $r.Data -replace ':', ''
                }
                elseif ($r.Data -match '^[0-9A-Fa-f]{2}(-[0-9A-Fa-f]{2}){5}$') {
                    $hex = $r.Data -replace '-', ''
                }
                elseif ($r.Data -match 'Hex-STRING:\s*([0-9A-Fa-f\s]+)') {
                    $hex = $matches[1] -replace '\s', ''
                }
                else {
                    continue
                }
                
                if ($hex.Length -eq 12) {
                    $formatted = ($hex -split '(?<=\G.{2})(?=.)') -join ':'
                    $mac = $formatted.ToUpper()
                    if (-not $list.Contains($mac)) { $list.Add($mac) }
                }
            }
        }
        catch {
            try { [System.IO.File]::AppendAllText((Join-Path $syncHash.PSScriptRoot "debug.log"), "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] Get-FdbAddresses error for ${ip}: $($_.Exception.Message)`r`n", [System.Text.Encoding]::UTF8) } catch {}
        }
        return $list
    }

    # Automatically correct System Topology links based on CDP/LLDP neighbors & FDB MAC tables
    function Update-AutoTopology {
        $devices = @($syncHash.Devices)
        $deviceMap = @{}
        $macMap = @{}
        $nameMap = @{}
        
        foreach ($ip in $devices) {
            $isMon = if ($syncHash.IsMonitored.ContainsKey($ip)) { $syncHash.IsMonitored[$ip] } else { $true }
            if (-not $isMon) { continue }
            
            $name = if ($syncHash.DeviceName.ContainsKey($ip)) { $syncHash.DeviceName[$ip] } else { $ip }
            $mac = if ($syncHash.Mac.ContainsKey($ip)) { $syncHash.Mac[$ip] } else { "" }
            $image = if ($syncHash.Image.ContainsKey($ip)) { $syncHash.Image[$ip] } else { "" }
            
            $deviceMap[$ip] = @{
                ip          = $ip
                name        = $name
                mac         = $mac
                image       = $image
                status      = if ($syncHash.Status.ContainsKey($ip)) { $syncHash.Status[$ip].status } else { 'Failed' }
                connectedTo = if ($syncHash.ConnectedTo.ContainsKey($ip)) { $syncHash.ConnectedTo[$ip] } else { "" }
            }
            if ($mac -and $mac -ne '-') {
                $macMap[$mac.ToUpper()] = $ip
            }
            if ($name) {
                $nameMap[$name.ToLower().Trim()] = $ip
            }
        }

        $candidates = @{}

        foreach ($ip in $devices) {
            $dev = $deviceMap[$ip]
            if ($null -eq $dev -or $dev.status -ne 'Success') { continue }
            $comm = if ($syncHash.Community.ContainsKey($ip)) { $syncHash.Community[$ip] } else { 'public' }
            
            # 1. LLDP/CDP Neighbors
            $neighborsStr = if ($syncHash.SnmpDetail.ContainsKey($ip)) { $syncHash.SnmpDetail[$ip].neighbors } else { "" }
            if ($neighborsStr) {
                $neighbors = $neighborsStr.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
                foreach ($nb in $neighbors) {
                    $nbLower = $nb.ToLower()
                    $matchedIp = $null
                    if ($nameMap.ContainsKey($nbLower)) {
                        $matchedIp = $nameMap[$nbLower]
                    }
                    else {
                        foreach ($key in $nameMap.Keys) {
                            if ($nbLower.StartsWith($key) -or $key.StartsWith($nbLower)) {
                                $matchedIp = $nameMap[$key]
                                break
                            }
                        }
                    }
                    if (-not $matchedIp -and $nb -as [ipaddress]) {
                        if ($deviceMap.ContainsKey($nb)) { $matchedIp = $nb }
                    }
                    if ($matchedIp -and $matchedIp -ne $ip) {
                        $candidates[$ip] = $matchedIp
                    }
                }
            }

            # 2. Bridge FDB Table Fallback (Only APs, Switches, Routers auto-connect to others)
            if ($dev.image -eq 'ap' -or $dev.image -eq 'bridge' -or $dev.image -eq 'router') {
                $fdbs = Get-FdbAddresses -ip $ip -community $comm
                foreach ($fdbMac in $fdbs) {
                    if ($macMap.ContainsKey($fdbMac)) {
                        $targetIp = $macMap[$fdbMac]
                        if ($targetIp -eq $ip) { continue }
                        
                        # Only link if target device doesn't have a configured connection
                        $targetDev = $deviceMap[$targetIp]
                        if ($targetDev -and [string]::IsNullOrWhiteSpace($targetDev.connectedTo)) {
                            # SWITCH or ROUTER to AP/Camera/PC
                            if ($dev.image -eq 'router' -or ($dev.image -eq 'switch' -and $targetDev.image -ne 'router')) {
                                $candidates[$targetIp] = $ip
                            }
                        }
                    }
                }
            }
        }

        # Apply candidates thread-safely
        $changed = $false
        foreach ($ip in $candidates.Keys) {
            $parent = $candidates[$ip]
            if ($syncHash.ConnectedTo.ContainsKey($ip)) {
                $curr = $syncHash.ConnectedTo[$ip]
                if ([string]::IsNullOrWhiteSpace($curr) -or $curr -ne $parent) {
                    # Verify no loop creation
                    $loop = $false
                    $currParent = $parent
                    while ($currParent) {
                        if ($currParent -eq $ip) { $loop = $true; break }
                        $currParent = if ($syncHash.ConnectedTo.ContainsKey($currParent)) { $syncHash.ConnectedTo[$currParent] } else { $null }
                    }
                    
                    if (-not $loop) {
                        $syncHash.ConnectedTo[$ip] = $parent
                        $changed = $true
                    }
                }
            }
        }

        if ($changed) {
            Save-DevicesJson -Routine
        }
    }

    Start-Sleep -Seconds 8  # let other runspaces stabilize first

    while ($syncHash.Running) {
        if ($syncHash.PollInterval -lt 0) {
            Start-Sleep -Seconds 5
            continue
        }
        $devices = $syncHash.Devices
        foreach ($ip in $devices) {
            if ($syncHash.IsMonitored.ContainsKey($ip) -and -not $syncHash.IsMonitored[$ip]) { continue }
            $stEntry = if ($syncHash.Status.ContainsKey($ip)) { $syncHash.Status[$ip] } else { $null }
            if ($null -eq $stEntry -or $stEntry.status -ne 'Success') { continue }

            $comm = if ($syncHash.Community.ContainsKey($ip)) { $syncHash.Community[$ip] } else { 'public' }
            try {
                $speed = Get-InterfaceSpeed -ip $ip -community $comm
                $neighbors = Get-Neighbors     -ip $ip -community $comm
                $wifiBand = Get-WirelessBand  -ip $ip -community $comm

                $syncHash.SnmpDetail[$ip] = @{
                    speed     = if ($speed) { $speed }     else { '' }
                    neighbors = if ($neighbors) { $neighbors } else { '' }
                    wifiBand  = if ($wifiBand) { $wifiBand }  else { '' }
                }
            }
            catch {
                try { [System.IO.File]::AppendAllText((Join-Path $syncHash.PSScriptRoot "debug.log"), "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] SNMPDetailRunspace inner query error for ${ip}: $($_.Exception.Message)`r`n", [System.Text.Encoding]::UTF8) } catch {}
            }
        }
        Update-AutoTopology
        $sleepSec = if ($null -ne $syncHash.PollInterval) { [math]::Max(30, [int]($syncHash.PollInterval * 6 / 1000)) } else { 30 }
        Start-Sleep -Seconds $sleepSec
    }
}
$snmpDetailScriptBlockCombined = [scriptblock]::Create($snmpHelpersScript.ToString() + "`n" + $saveDevicesJsonScript.ToString() + "`n" + $snmpDetailScriptBlock.ToString())
$snmpDetailPipeline = $snmpDetailRunspace.CreatePipeline()
$null = $snmpDetailPipeline.Commands.AddScript($snmpDetailScriptBlockCombined)
$snmpDetailAsyncResult = $snmpDetailPipeline.InvokeAsync()

# ─────────────────────────────────────────
# 2.10 Background Syslog Receiver Runspace (UDP 514 / Fallback)
# ─────────────────────────────────────────
$syslogRunspace = [runspacefactory]::CreateRunspace()
$syslogRunspace.ApartmentState = "STA"
$syslogRunspace.ThreadOptions = "ReuseThread"
$syslogRunspace.Open()
$syslogRunspace.SessionStateProxy.SetVariable("syncHash", $syncHash)

$syslogScriptBlock = {
    # 受信ポートを開く。指定ポートが他のソフトに使われていれば 1514 で代わりに受信する
    # 実際に受信しているポートと失敗理由は画面に表示する (以前は 1514 に切り替わっても画面からは分からず、
    #  機器が 514 番へ送っても届かない原因がつかめなかった)
    $openSyslogPort = {
        param($wantPort)
        $client = $null
        $syncHash.SyslogListenPort = 0
        $syncHash.SyslogListenError = ""
        try {
            $client = New-Object System.Net.Sockets.UdpClient($wantPort)
            $syncHash.SyslogListenPort = $wantPort
        }
        catch {
            $firstErr = $_.Exception.InnerException.Message
            if (-not $firstErr) { $firstErr = $_.Exception.Message }
            try {
                $client = New-Object System.Net.Sockets.UdpClient(1514)
                $syncHash.SyslogListenPort = 1514
                $syncHash.SyslogListenError = "UDP $wantPort を開けなかったため 1514 で受信しています ($firstErr)"
            }
            catch {
                $syncHash.SyslogListenError = "UDP $wantPort / 1514 のどちらも開けません ($firstErr)"
            }
        }
        if ($null -ne $client) { $client.Client.ReceiveTimeout = 1000 }
        return $client
    }

    $wantedPort = if ($syncHash.SyslogPort) { [int]$syncHash.SyslogPort } else { 514 }
    $udpClient = & $openSyslogPort $wantedPort

    $remoteEP = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)

    while ($syncHash.Running) {
        # 設定でポート番号が変わったら開き直す (以前は再起動するまで反映されなかった)
        $newWanted = if ($syncHash.SyslogPort) { [int]$syncHash.SyslogPort } else { 514 }
        if ($newWanted -ne $wantedPort) {
            if ($null -ne $udpClient) { try { $udpClient.Close() } catch {} }
            $wantedPort = $newWanted
            $udpClient = & $openSyslogPort $wantedPort
        }
        if (-not $syncHash.SyslogEnabled -or $null -eq $udpClient) {
            Start-Sleep -Milliseconds 500
            continue
        }

        try {
            $bytes = $udpClient.Receive([ref]$remoteEP)
            if ($null -ne $bytes -and $bytes.Length -gt 0) {
                $rawMsg = [System.Text.Encoding]::UTF8.GetString($bytes)
                $srcIp = $remoteEP.Address.ToString()
                $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                
                $severity = "Informational"
                $cleanMsg = $rawMsg
                # (?s): 改行を含む複数行メッセージでも重要度 (PRI) を読み取る
                # (以前は改行があると一致せず、重要度が常に Informational・先頭に "<189>" 等が残ったまま表示されていた)
                if ($rawMsg -match '(?s)^<(\d{1,3})>(.*)$') {
                    $pri = [int]$matches[1]
                    $cleanMsg = $matches[2].Trim()
                    $sevCode = $pri % 8
                    $sevMap = @{
                        0 = "Emergency"; 1 = "Alert"; 2 = "Critical"; 3 = "Error";
                        4 = "Warning"; 5 = "Notice"; 6 = "Informational"; 7 = "Debug"
                    }
                    if ($sevMap.ContainsKey($sevCode)) {
                        $severity = $sevMap[$sevCode]
                    }
                }

                $logEntry = @{
                    Timestamp = $ts
                    SourceIP  = $srcIp
                    Severity  = $severity
                    Message   = $cleanMsg
                    Kind      = "Syslog"
                }

                [System.Threading.Monitor]::Enter($syncHash.SyslogQueue.SyncRoot)
                try {
                    $syncHash.SyslogQueue.Insert(0, $logEntry)
                    while ($syncHash.SyslogQueue.Count -gt 500) {
                        $syncHash.SyslogQueue.RemoveAt($syncHash.SyslogQueue.Count - 1)
                    }
                }
                finally {
                    [System.Threading.Monitor]::Exit($syncHash.SyslogQueue.SyncRoot)
                }
            }
        }
        catch [System.Net.Sockets.SocketException] {
            # Timeout is normal for non-blocking receive
        }
        catch {
            Start-Sleep -Milliseconds 200
        }
    }

    if ($null -ne $udpClient) {
        try { $udpClient.Close(); $udpClient.Dispose() } catch {}
    }
}

$syslogPipeline = $syslogRunspace.CreatePipeline()
$null = $syslogPipeline.Commands.AddScript($syslogScriptBlock)
$syslogAsyncResult = $syslogPipeline.InvokeAsync()

# ─────────────────────────────────────────
# 2.11 SNMP Trap 受信スレッド (UDP 162 / 開けないときは 1162)
# 機器が自分から送ってくる異常の知らせ (Trap) を受け取り、Syslog と同じ一覧に入れて画面に表示する。
# v1 / v2c に対応。v3 は暗号化されていて読めないため、届いたことだけを表示する。
# ─────────────────────────────────────────
$trapRunspace = [runspacefactory]::CreateRunspace()
$trapRunspace.ApartmentState = "STA"
$trapRunspace.ThreadOptions = "ReuseThread"
$trapRunspace.Open()
$trapRunspace.SessionStateProxy.SetVariable("syncHash", $syncHash)

$trapScriptBlock = {
    Import-Module (Join-Path $syncHash.PSScriptRoot "modules\SnmpService.psm1") -DisableNameChecking -ErrorAction SilentlyContinue

    $openTrapPort = {
        param($wantPort)
        $client = $null
        $syncHash.TrapListenPort = 0
        $syncHash.TrapListenError = ""
        try {
            $client = New-Object System.Net.Sockets.UdpClient($wantPort)
            $syncHash.TrapListenPort = $wantPort
        }
        catch {
            $firstErr = $_.Exception.InnerException.Message
            if (-not $firstErr) { $firstErr = $_.Exception.Message }
            try {
                $client = New-Object System.Net.Sockets.UdpClient(1162)
                $syncHash.TrapListenPort = 1162
                $syncHash.TrapListenError = "UDP $wantPort を開けなかったため 1162 で受信しています。Windows の SNMP Trap サービスなどが使っている可能性があります ($firstErr)"
            }
            catch {
                $syncHash.TrapListenError = "UDP $wantPort / 1162 のどちらも開けません ($firstErr)"
            }
        }
        if ($null -ne $client) { $client.Client.ReceiveTimeout = 1000 }
        return $client
    }

    $addTrapEntry = {
        param($srcIp, $severity, $message)
        $entry = @{
            Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            SourceIP  = $srcIp
            Severity  = $severity
            Message   = $message
            Kind      = "Trap"
        }
        [System.Threading.Monitor]::Enter($syncHash.SyslogQueue.SyncRoot)
        try {
            $syncHash.SyslogQueue.Insert(0, $entry)
            while ($syncHash.SyslogQueue.Count -gt 500) { $syncHash.SyslogQueue.RemoveAt($syncHash.SyslogQueue.Count - 1) }
        }
        finally {
            [System.Threading.Monitor]::Exit($syncHash.SyslogQueue.SyncRoot)
        }
    }

    $wantedPort = if ($syncHash.TrapPort) { [int]$syncHash.TrapPort } else { 162 }
    $udpClient = & $openTrapPort $wantedPort
    $remoteEP = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
    $v3NoticeTimes = @{}   # 同じ機器からの v3 の案内は 1 分に 1 回までにする

    while ($syncHash.Running) {
        $newWanted = if ($syncHash.TrapPort) { [int]$syncHash.TrapPort } else { 162 }
        if ($newWanted -ne $wantedPort) {
            if ($null -ne $udpClient) { try { $udpClient.Close() } catch {} }
            $wantedPort = $newWanted
            $udpClient = & $openTrapPort $wantedPort
        }
        if (-not $syncHash.SyslogEnabled -or $null -eq $udpClient) {
            Start-Sleep -Milliseconds 500
            continue
        }

        try {
            $bytes = $udpClient.Receive([ref]$remoteEP)
        }
        catch {
            # 受信待ちの時間切れは正常 (1秒ごとに終了の確認をするため)
            continue
        }
        if ($null -eq $bytes -or $bytes.Length -eq 0) { continue }

        try {
            $srcIp = $remoteEP.Address.ToString()
            $trap = ConvertFrom-SnmpTrapPacket -Packet $bytes
            if ($trap.Version -eq "v3") {
                $lastNotice = $v3NoticeTimes[$srcIp]
                if ($null -eq $lastNotice -or ((Get-Date) - $lastNotice).TotalSeconds -ge 60) {
                    $v3NoticeTimes[$srcIp] = Get-Date
                    & $addTrapEntry $srcIp "Notice" "[SNMP Trap v3] SNMPv3 の Trap が届きましたが、暗号化されているため内容は表示できません。機器側で v1 / v2c の Trap を送る設定にしてください。"
                }
                continue
            }
            # Inform は「受け取りました」の返事を待っているので、種類だけ Response に変えて送り返す
            if ($trap.Pdu -eq "Inform") {
                $reply = [byte[]]$bytes.Clone()
                $reply[$trap.PduTagOffset] = 0xA2
                $null = $udpClient.Send($reply, $reply.Length, $remoteEP)
            }
            $display = Get-SnmpTrapDisplay -Trap $trap
            & $addTrapEntry $srcIp $display.Severity $display.Message
        }
        catch {
            # SNMP として読めないデータは無視する (ネットワーク上の無関係なデータで一覧を埋めないため)
            continue
        }
    }

    if ($null -ne $udpClient) { try { $udpClient.Close(); $udpClient.Dispose() } catch {} }
}

$trapPipeline = $trapRunspace.CreatePipeline()
$null = $trapPipeline.Commands.AddScript($trapScriptBlock)
$trapAsyncResult = $trapPipeline.InvokeAsync()

# ─────────────────────────────────────────
# 2.12 OBR の無線接続状況を確認するスレッド (機器ごとに 10 秒間隔)
# 確認に時間がかかっても監視や画面を止めないよう、別スレッドで動かす
# ─────────────────────────────────────────
$obrRunspace = [runspacefactory]::CreateRunspace()
$obrRunspace.ApartmentState = "STA"
$obrRunspace.ThreadOptions = "ReuseThread"
$obrRunspace.Open()
$obrRunspace.SessionStateProxy.SetVariable("syncHash", $syncHash)

$obrScriptBlock = {
    Import-Module (Join-Path $syncHash.PSScriptRoot "modules\Common.psm1") -DisableNameChecking -ErrorAction SilentlyContinue
    Import-Module (Join-Path $syncHash.PSScriptRoot "modules\ObrStatus.psm1") -DisableNameChecking -ErrorAction SilentlyContinue

    $nextCheck = @{}      # 機器ごとの次の確認時刻
    $lastPassword = @{}   # パスワードが変わったらすぐ確認し直すために覚えておく
    # 確認結果を履歴の待ち行列に入れる (ファイルへの書き込みは記録専用スレッドが行うので、ドライブが止まっても確認は止まらない)
    $addObrHistory = {
        param($deviceIp, $entry)
        if ($syncHash.LoggingEnabled -eq $false) { return }
        $queue = $syncHash.ObrHistoryQueue
        $null = $queue.Add(@{
                ip        = $deviceIp
                name      = if ($syncHash.DeviceName.ContainsKey($deviceIp)) { $syncHash.DeviceName[$deviceIp] } else { $deviceIp }
                state     = $entry.state
                ssid      = $entry.ssid
                bssid     = $entry.bssid
                channel   = $entry.channel
                signalDbm = $entry.signalDbm
                txBitrate = $entry.txBitrate
                checkedAt = $entry.checkedAt
            })
        if ($queue.Count -gt 5500) {
            [System.Threading.Monitor]::Enter($queue.SyncRoot)
            try { $queue.RemoveRange(0, $queue.Count - 5000) }
            finally { [System.Threading.Monitor]::Exit($queue.SyncRoot) }
        }
    }

    while ($syncHash.Running) {
        $now = [DateTime]::UtcNow
        foreach ($ip in @($syncHash.Devices)) {
            if (-not $syncHash.Running) { break }
            $enabled = $syncHash.ObrEnabled.ContainsKey($ip) -and $syncHash.ObrEnabled[$ip] -and
                       -not ($syncHash.IsMonitored.ContainsKey($ip) -and -not $syncHash.IsMonitored[$ip])
            if (-not $enabled) {
                if ($syncHash.ObrStatus.ContainsKey($ip)) { $syncHash.ObrStatus.Remove($ip) }
                $nextCheck.Remove($ip)
                continue
            }

            $cipher = if ($syncHash.ObrPassword.ContainsKey($ip)) { [string]$syncHash.ObrPassword[$ip] } else { "" }
            if ($lastPassword[$ip] -ne $cipher) {
                $lastPassword[$ip] = $cipher
                $nextCheck.Remove($ip)
            }
            if ($nextCheck.ContainsKey($ip) -and $now -lt $nextCheck[$ip]) { continue }
            $nextCheck[$ip] = $now.AddSeconds(10)

            $checkedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            if ([string]::IsNullOrEmpty($cipher)) {
                $syncHash.ObrStatus[$ip] = @{ state = "NoPassword"; checkedAt = $checkedAt }
                continue
            }
            $password = Unprotect-SecretString $cipher
            if ([string]::IsNullOrEmpty($password)) {
                $syncHash.ObrStatus[$ip] = @{ state = "DecryptFailed"; checkedAt = $checkedAt }
                continue
            }
            # Ping が通っていない機器には問い合わせない (タイムアウト待ちを避ける)
            $pingEntry = if ($syncHash.Status.ContainsKey($ip)) { $syncHash.Status[$ip] } else { $null }
            if ($null -ne $pingEntry -and $pingEntry.status -in @("Failed", "Error")) {
                $syncHash.ObrStatus[$ip] = @{ state = "Unreachable"; checkedAt = $checkedAt }
                & $addObrHistory $ip $syncHash.ObrStatus[$ip]
continue
            }
            try {
                $obr = Get-ObrWirelessStatus -HostName $ip -Password $password
                $syncHash.ObrStatus[$ip] = @{
                    state     = $obr.State
                    ssid      = $obr.Ssid
                    bssid     = $obr.Bssid
                    channel   = $obr.Channel
                    signalDbm = $obr.SignalDbm
                    txBitrate = $obr.TxBitrate
                    checkedAt = $checkedAt
                }
                & $addObrHistory $ip $syncHash.ObrStatus[$ip]
                # パスワードが違うときは 5 分おきにする (短い間隔で失敗を繰り返すと機器側で拒否される恐れがあるため)
if ($obr.State -eq "LoginFailed") { $nextCheck[$ip] = $now.AddMinutes(5) }
            }
            catch {
                $syncHash.ObrStatus[$ip] = @{ state = "Unreachable"; checkedAt = $checkedAt }
                & $addObrHistory $ip $syncHash.ObrStatus[$ip]
}
        }
        Start-Sleep -Seconds 1
    }
}

$obrPipeline = $obrRunspace.CreatePipeline()
$null = $obrPipeline.Commands.AddScript($obrScriptBlock)
$obrAsyncResult = $obrPipeline.InvokeAsync()

# ─────────────────────────────────────────
# Helper: devices.json の1機器分を $syncHash の全項目へ読み込む
# (起動時と同じ項目を復元・インポートでも読み込むための共通処理。以前の復元・インポートは
#  名前・グループ等の一部しか読み込まず、次の保存でトラブルメモ・TCP監視・リモート設定等が消えていた)
# ─────────────────────────────────────────
function Set-DeviceRecordInSyncHash($d) {
    $ip = ([string]$d.ip).Trim()
    if ([string]::IsNullOrWhiteSpace($ip)) { return $null }
    $syncHash.Community[$ip] = if ($d.community) { ([string]$d.community).Trim() } else { "public" }
    $syncHash.DeviceName[$ip] = if ($d.name) { ([string]$d.name).Trim() } else { $ip }
    $syncHash.IsMonitored[$ip] = if ($null -ne $d.enabled) { [bool]$d.enabled } else { $true }
    $syncHash.Group[$ip] = if ($null -ne $d.group) { ([string]$d.group).Trim() } else { "" }
    $syncHash.Image[$ip] = if ($null -ne $d.image) { [string]$d.image } else { "" }
    $syncHash.ConnectedTo[$ip] = if ($null -ne $d.connectedTo) { ([string]$d.connectedTo).Trim() } else { "" }
    $syncHash.X[$ip] = if ($null -ne $d.x) { $d.x } else { $null }
    $syncHash.Y[$ip] = if ($null -ne $d.y) { $d.y } else { $null }
    $syncHash.Mac[$ip] = if ($null -ne $d.mac) { [string]$d.mac } else { "" }
    $syncHash.VendorContact[$ip] = if ($null -ne $d.vendorContact) { [string]$d.vendorContact } else { "" }
    $syncHash.DeviceType[$ip] = if ($null -ne $d.deviceType) { [string]$d.deviceType } else { "network" }
    $syncHash.WebUrl[$ip] = if ($null -ne $d.webUrl) { [string]$d.webUrl } else { "" }
    $syncHash.CheckType[$ip] = if ($d.checkType) { [string]$d.checkType } else { "icmp" }
    $syncHash.Port[$ip] = if ($null -ne $d.port) { [int]$d.port } else { 0 }
    $syncHash.SnmpVersion[$ip] = if ($d.snmpVersion) { [string]$d.snmpVersion } else { "v2c" }
    $syncHash.SnmpUser[$ip] = if ($null -ne $d.snmpUser) { [string]$d.snmpUser } else { "" }
    $syncHash.SnmpAuthProto[$ip] = if ($d.snmpAuthProto) { [string]$d.snmpAuthProto } else { "none" }
    $syncHash.SnmpAuthPass[$ip] = if ($null -ne $d.snmpAuthPass) { Unprotect-SecretOrKeep ([string]$d.snmpAuthPass) } else { "" }
$syncHash.SnmpPrivProto[$ip] = if ($d.snmpPrivProto) { [string]$d.snmpPrivProto } else { "none" }
    $syncHash.SnmpPrivPass[$ip] = if ($null -ne $d.snmpPrivPass) { Unprotect-SecretOrKeep ([string]$d.snmpPrivPass) } else { "" }
    $syncHash.ObrEnabled[$ip] = if ($null -ne $d.obrEnabled) { [bool]$d.obrEnabled } else { $false }
    $syncHash.ObrPassword[$ip] = if ($d.obrPassword) { Protect-SecretString ([string]$d.obrPassword) } else { "" }
if (-not $syncHash.Remote) { $syncHash.Remote = [hashtable]::Synchronized(@{}) }
    if ($null -ne $d.remote) {
        $rHash = @{}
        if ($d.remote -is [System.Collections.IDictionary]) {
            foreach ($k in $d.remote.Keys) { $rHash[$k] = $d.remote[$k] }
        }
        elseif ($null -ne $d.remote.PSObject) {
            foreach ($p in $d.remote.PSObject.Properties) { $rHash[$p.Name] = $p.Value }
        }
        $syncHash.Remote[$ip] = $rHash
    }
    elseif ($syncHash.Remote.ContainsKey($ip)) {
        $syncHash.Remote.Remove($ip)
    }
    return $ip
}

# ─────────────────────────────────────────
# Helper: Serve JSON response
# ─────────────────────────────────────────
function Write-JsonResponse($response, $data, $statusCode = 200) {
    if ($response.OutputStream.CanWrite) {
        $response.StatusCode = $statusCode
        $response.ContentType = "application/json; charset=utf-8"
        $json = ($data | ConvertTo-Json -Depth 5 -Compress) -join "`n"
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
        try {
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        catch {}
        try { $response.Close() } catch {}
    }
}

# Helper: MIME types
function Get-MimeType($ext) {
    switch ($ext.ToLower()) {
        # 文字コードをHTTPヘッダーで明示する (index.html は冒頭の長い解説コメントにより <meta charset> が
        # 先頭1024バイトより後ろにあり、ブラウザによっては文字コードの推定や再読み込みが発生していた)
        ".html" { return "text/html; charset=utf-8" }
        ".css" { return "text/css; charset=utf-8" }
        ".js" { return "application/javascript; charset=utf-8" }
        ".png" { return "image/png" }
        ".jpg" { return "image/jpeg" }
        ".svg" { return "image/svg+xml" }
        default { return "application/octet-stream" }
    }
}



# ─────────────────────────────────────────
# 2.95 Shared RunspacePool for Async HTTP Tasks (Runspace-safe replacement for ThreadPool)
# ─────────────────────────────────────────
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry("syncHash", $syncHash, $null)))
$iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry("ReportsDir", $ReportsDir, $null)))
$iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry("Write-JsonResponse", ${function:Write-JsonResponse}.ToString())))
$iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry("Invoke-SnmpGetUnified", ${function:Invoke-SnmpGetUnified}.ToString())))
$iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry("Invoke-SnmpWalkUnified", ${function:Invoke-SnmpWalkUnified}.ToString())))
# Webhook / メール送信関数は AlertManager.psm1 から読み込む
$iss.ImportPSModule(@((Join-Path $PSScriptRoot "modules\AlertManager.psm1")))
$iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry("Log-Audit", ${function:Log-Audit}.ToString())))
$iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry("Check-WebAndSslEndpoint", ${function:Check-WebAndSslEndpoint}.ToString())))
# Log-Audit は内部で Common\Log-Audit を呼ぶため、別スレッド側にも Common.psm1 を読み込む
# (読み込まないと「モジュール 'Common' を読み込めません」で失敗し、リモート操作などで操作履歴が残らず、
#  エラー処理でも同じ失敗が起きて画面へ結果が返らずタイムアウトしていた)
$iss.ImportPSModule(@((Join-Path $PSScriptRoot "modules\Common.psm1")))

$asyncWorkerPool = [runspacefactory]::CreateRunspacePool(1, 10, $iss, $Host)
$asyncWorkerPool.ThreadOptions = "ReuseThread"
$asyncWorkerPool.Open()
$script:AsyncHttpJobs = [System.Collections.ArrayList]::new()

function Start-BackgroundScript {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )
    for ($idx = $script:AsyncHttpJobs.Count - 1; $idx -ge 0; $idx--) {
        $jobItem = $script:AsyncHttpJobs[$idx]
        if ($jobItem.Handle.IsCompleted) {
            try { $null = $jobItem.PS.EndInvoke($jobItem.Handle) } catch {}
            try { $jobItem.PS.Dispose() } catch {}
            $script:AsyncHttpJobs.RemoveAt($idx)
        }
    }
    $psInst = [powershell]::Create()
    $psInst.RunspacePool = $asyncWorkerPool
    $null = $psInst.AddScript($ScriptBlock)
    foreach ($argItem in $ArgumentList) {
        $null = $psInst.AddArgument($argItem)
    }
    $asyncHandle = $psInst.BeginInvoke()
    $null = $script:AsyncHttpJobs.Add(@{ PS = $psInst; Handle = $asyncHandle })
}

# ─────────────────────────────────────────
# 3. HTTP Server – non-blocking with async GetContext
# ─────────────────────────────────────────
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
try {
    $listener.Start()
    $syncHash.Listener = $listener
    Write-Host "Network Monitor Server running at http://localhost:$port/" -ForegroundColor Green
    Write-Host "Press [Enter] to stop and save logs." -ForegroundColor Yellow
}
catch {
    Write-Host "Failed to start HTTP listener: $($_.Exception.Message)" -ForegroundColor Red
    $syncHash.Running = $false
    $runspace.Close(); $runspace.Dispose()
    exit
}

# Dedicated runspace: watch for Enter key, browser disconnect, or shutdown signal
$keyRunspace = [runspacefactory]::CreateRunspace()
$keyRunspace.ApartmentState = "STA"
$keyRunspace.ThreadOptions = "ReuseThread"
$keyRunspace.Open()
$keyRunspace.SessionStateProxy.SetVariable("syncHash", $syncHash)
$keyRunspace.SessionStateProxy.SetVariable("ListenerRef", $listener)

$keyScript = {
    $initialStartupTime = [DateTime]::UtcNow
    while ($true) {
        # 1. Console key detection (if console handle is available)
        try {
            if ([System.Console]::KeyAvailable) {
                $key = [System.Console]::ReadKey($true)
                if ($key.Key -eq [System.ConsoleKey]::Enter) {
                    Write-Host "[Enter] key pressed. Shutting down server gracefully..." -ForegroundColor Yellow
                    break
                }
            }
        }
        catch { }

        # 2. Browser shutdown signal (/api/shutdown beacon)
        if ($syncHash.PendingShutdown -and [DateTime]::UtcNow -gt $syncHash.PendingShutdownTime) {
            Write-Host "Browser shutdown signal received. Shutting down server gracefully..." -ForegroundColor Yellow
            break
        }

        # 3. Client heartbeat & disconnect detection (Auto-shutdown when browser closed)
        #    タイムアウトを20秒に設定: F5リロードやWi-Fi→有線切替による瞬断（通常3〜10秒）での誤終了を防ぐ
        if ($syncHash.AutoShutdownOnDisconnect -ne $false) {
            $timeoutSec = if ($syncHash.HeartbeatTimeoutSec) { [int]$syncHash.HeartbeatTimeoutSec } else { 600 }
            
            if ($syncHash.HasClientConnected) {
                $timeSinceLastActivity = ([DateTime]::UtcNow - $syncHash.LastClientActivity).TotalSeconds
                if ($timeSinceLastActivity -gt $timeoutSec) {
                    Write-Host "Browser disconnected ($([int]$timeSinceLastActivity)s since last heartbeat). Automatically saving logs and shutting down..." -ForegroundColor Yellow
                    break
                }
            }
        }

        [System.Threading.Thread]::Sleep(200)
    }

    $syncHash.Shutdown = $true
    try { $ListenerRef.Stop() } catch {}
}
# 定期メンテナンスの前回実行時刻 (起動時に同じ処理を済ませているので、次回は6時間後)
$script:LastMaintenanceUtc = [DateTime]::UtcNow

$keyPipeline = $keyRunspace.CreatePipeline()
$null = $keyPipeline.Commands.AddScript($keyScript)
$null = $keyPipeline.InvokeAsync()

try {
    while ($listener.IsListening) {
        $context = $null
        try { $context = $listener.GetContext() } catch { break }
        if ($null -eq $context) { break }

        $request = $context.Request
        $response = $context.Response
        $urlPath = $request.Url.LocalPath
        $method = $request.HttpMethod

        # CSRF guard: reject /api/* calls made by other websites open in the same browser
        if ($urlPath.StartsWith("/api/")) {
            $reqOrigin = $request.Headers["Origin"]
            $reqFetchSite = $request.Headers["Sec-Fetch-Site"]
            try {
                $apiAllowed = Test-ApiRequestAllowed -Origin $reqOrigin -SecFetchSite $reqFetchSite -Port $port
            } catch {
                # Common.psm1 failed to load: fail closed for browser requests, keep header-less clients (Watchdog) working
                Write-Host "CSRF check unavailable: $($_.Exception.Message)" -ForegroundColor Red
                $apiAllowed = [string]::IsNullOrEmpty($reqOrigin) -and [string]::IsNullOrEmpty($reqFetchSite)
            }
            if (-not $apiAllowed) {
                Write-Host "Blocked cross-site API request: $method $urlPath (Origin: $reqOrigin, Sec-Fetch-Site: $reqFetchSite)" -ForegroundColor Red
                try { Write-JsonResponse $response @{ error = "Cross-site request blocked"; success = $false; status = "FORBIDDEN_ORIGIN" } 403 } catch {}
                try { $response.Close() } catch {}
                continue
            }
        }

        # 定期メンテナンス (6時間ごと): 保存期間を過ぎたレポートの削除と debug.log の世代交代
        # (以前は起動時・終了時・保存期間の変更時にしか行わず、無人運用で長期間動かすと
        #  Reports フォルダや debug.log が再起動まで増え続けていた)
        if (([DateTime]::UtcNow - $script:LastMaintenanceUtc).TotalHours -ge 6) {
            $script:LastMaintenanceUtc = [DateTime]::UtcNow
            if ($syncHash.LogRetentionDays -gt 0) {
                try { Invoke-PurgeOldReports -reportsDirectory $ReportsDir -retentionDays $syncHash.LogRetentionDays -activeSessionDir $syncHash.SessionDir | Out-Null } catch {}
            }
            try {
                if ((Test-Path -LiteralPath $debugLogPath) -and (Get-Item -LiteralPath $debugLogPath).Length -gt 5MB) {
                    Move-Item -LiteralPath $debugLogPath -Destination (Join-Path $PSScriptRoot "debug_1.log") -Force -ErrorAction SilentlyContinue
                }
            }
            catch {}
        }

        # Update client activity on any request from browser
        # /api/health は Watchdog が15秒ごとに呼ぶ死活確認で、画面 (ブラウザ) は使わない。これを「画面からの通信」と数えると
        # ブラウザを閉じても終了予約が取り消され、無通信10分での自動終了も働かなくなるため除外する
        $isBrowserActivity = ($urlPath -ne "/api/health")
        if ($isBrowserActivity) {
            $syncHash.HasClientConnected = $true
            $syncHash.LastClientActivity = [DateTime]::UtcNow
        }

        if ($isBrowserActivity -and $urlPath -ne "/api/shutdown") {
            if ($syncHash.PendingShutdown -and -not $syncHash.PendingShutdownForced) {
                $syncHash.PendingShutdown = $false
                Write-Host "Shutdown cancelled (client reconnected/active)." -ForegroundColor Green
            }
        }

        if ($urlPath.StartsWith("/api/")) {
            try {
                if ($urlPath -eq "/api/devices" -and $method -eq "GET") {
                    $devArr = @()
                    if ($syncHash.Devices) {
                        foreach ($ip in $syncHash.Devices) {
                            $devArr += @{
                                ip            = $ip
                                community     = if ($syncHash.Community.ContainsKey($ip)) { $syncHash.Community[$ip] } else { "public" }
                                name          = if ($syncHash.DeviceName.ContainsKey($ip)) { $syncHash.DeviceName[$ip] } else { $ip }
                                enabled       = if ($syncHash.IsMonitored.ContainsKey($ip)) { $syncHash.IsMonitored[$ip] } else { $true }
                                group         = if ($syncHash.Group.ContainsKey($ip)) { $syncHash.Group[$ip] } else { "" }
                                image         = if ($syncHash.Image.ContainsKey($ip)) { $syncHash.Image[$ip] } else { "" }
                                connectedTo   = if ($syncHash.ConnectedTo.ContainsKey($ip)) { $syncHash.ConnectedTo[$ip] } else { "" }
                                x             = if ($syncHash.X.ContainsKey($ip)) { $syncHash.X[$ip] } else { $null }
                                y             = if ($syncHash.Y.ContainsKey($ip)) { $syncHash.Y[$ip] } else { $null }
                                mac           = if ($syncHash.Mac.ContainsKey($ip)) { $syncHash.Mac[$ip] } else { "" }
                                vendorContact = if ($syncHash.VendorContact.ContainsKey($ip)) { $syncHash.VendorContact[$ip] } else { "" }
                                deviceType    = if ($syncHash.DeviceType.ContainsKey($ip)) { $syncHash.DeviceType[$ip] } else { "network" }
                                webUrl        = if ($syncHash.WebUrl.ContainsKey($ip)) { $syncHash.WebUrl[$ip] } else { "" }
                                checkType     = if ($syncHash.CheckType.ContainsKey($ip)) { $syncHash.CheckType[$ip] } else { "icmp" }
                                port          = if ($syncHash.Port.ContainsKey($ip)) { $syncHash.Port[$ip] } else { 0 }
                                sslExpiryDays = if ($syncHash.SslExpiryDays.ContainsKey($ip)) { $syncHash.SslExpiryDays[$ip] } else { $null }
                                httpStatus    = if ($syncHash.HttpStatus.ContainsKey($ip)) { $syncHash.HttpStatus[$ip] } else { $null }
                                snmpVersion   = if ($syncHash.SnmpVersion.ContainsKey($ip)) { $syncHash.SnmpVersion[$ip] } else { "v2c" }
                                snmpUser      = if ($syncHash.SnmpUser.ContainsKey($ip)) { $syncHash.SnmpUser[$ip] } else { "" }
                                snmpAuthProto = if ($syncHash.SnmpAuthProto.ContainsKey($ip)) { $syncHash.SnmpAuthProto[$ip] } else { "none" }
                                snmpAuthPass  = if ($syncHash.SnmpAuthPass.ContainsKey($ip) -and $syncHash.SnmpAuthPass[$ip]) { Protect-SecretString $syncHash.SnmpAuthPass[$ip] } else { "" }   # 平文で画面やエクスポートファイルに出さない (暗号化した形で返す)
                                snmpPrivProto = if ($syncHash.SnmpPrivProto.ContainsKey($ip)) { $syncHash.SnmpPrivProto[$ip] } else { "none" }
                                snmpPrivPass  = if ($syncHash.SnmpPrivPass.ContainsKey($ip) -and $syncHash.SnmpPrivPass[$ip]) { Protect-SecretString $syncHash.SnmpPrivPass[$ip] } else { "" }
                                obrEnabled    = if ($syncHash.ObrEnabled.ContainsKey($ip)) { [bool]$syncHash.ObrEnabled[$ip] } else { $false }
                                obrPassword   = if ($syncHash.ObrPassword.ContainsKey($ip)) { [string]$syncHash.ObrPassword[$ip] } else { "" }
                                remote        = if ($syncHash.Remote -and $syncHash.Remote.ContainsKey($ip)) { $syncHash.Remote[$ip] } else { $null }
                            }
                        }
                    }
                    Write-JsonResponse $response @{ devices = $devArr }
                }
                elseif ($urlPath -eq "/api/status" -and $method -eq "GET") {
                    $statusCopy = @{}
                    $keys = @()
                    $syncRoot = $syncHash.Status.SyncRoot
                    [System.Threading.Monitor]::Enter($syncRoot)
                    try {
                        $keys = @($syncHash.Status.Keys)
                    }
                    finally {
                        [System.Threading.Monitor]::Exit($syncRoot)
                    }
                    
                    foreach ($key in $keys) {
                        $st = @{
                            status    = $syncHash.Status[$key].status
                            rawStatus = if ($syncHash.Status[$key].ContainsKey('rawStatus')) { $syncHash.Status[$key].rawStatus } else { $syncHash.Status[$key].status }
                            latency   = $syncHash.Status[$key].latency
                            checkType = if ($syncHash.Status[$key].ContainsKey('checkType')) { $syncHash.Status[$key].checkType } else { "icmp" }
                            port      = if ($syncHash.Status[$key].ContainsKey('port')) { $syncHash.Status[$key].port } else { 0 }
                            timestamp = $syncHash.Status[$key].timestamp
                        }
                        
                        if ($syncHash.Traffic.ContainsKey($key) -and $null -ne $syncHash.Traffic[$key]) {
                            $st.tx = $syncHash.Traffic[$key].tx
                            $st.rx = $syncHash.Traffic[$key].rx
                        }
                        else {
                            $st.tx = "-"
                            $st.rx = "-"
                        }
                        $st.mac = if ($syncHash.Mac.ContainsKey($key)) { $syncHash.Mac[$key] } else { '' }
                        if ($syncHash.SnmpDetail.ContainsKey($key)) {
                            $d = $syncHash.SnmpDetail[$key]
                            $st.speed = $d.speed
                            $st.neighbors = $d.neighbors
                            $st.wifiBand = $d.wifiBand
                        }
                        else {
                            $st.speed = ''; $st.neighbors = ''; $st.wifiBand = ''
                        }
                        if ($syncHash.InterfaceErrors.ContainsKey($key)) {
                            $st.errors = $syncHash.InterfaceErrors[$key]
                        }
                        else {
                            $st.errors = @{}
                        }
                        # Include max outage stats
                        if ($syncHash.Stats.ContainsKey($key)) {
                            $s = $syncHash.Stats[$key]
                            $curOutage = if ($null -ne $s.OutageStartTime) {
                                [math]::Max(0.0, ((Get-Date) - $s.OutageStartTime).TotalSeconds)
                            }
                            elseif ($s.CurrentOutageSec -gt 0) {
                                $s.CurrentOutageSec
                            }
                            else {
                                0.0
                            }
                            $st.maxOutageSec = if ($s.MaxOutageSec -gt 0) { [math]::Round($s.MaxOutageSec, 1) } else { 0 }
                            $st.currentOutageSec = if ($curOutage -gt 0) { [math]::Round($curOutage, 1) } else { 0 }
                            $st.outage600msCount = $s.Outage600msCount
                            $st.outage5sCount = $s.Outage5sCount
                            # パイプライン (Select-Object) は0.1秒ごとの呼び出しでは重いため配列スライスで直近5件を取得
                            $evArr = if ($s.OutageEvents) { @($s.OutageEvents) } else { @() }
                            $st.outageEvents = @(if ($evArr.Count -gt 5) { $evArr[($evArr.Count - 5)..($evArr.Count - 1)] } else { $evArr })
                            $st.packetLossRate = if ($null -ne $s.PacketLossRate) { $s.PacketLossRate } else { 0.0 }
                            $st.jitter = if ($null -ne $s.Jitter) { $s.Jitter } else { 0.0 }
                            $st.avgJitter = if ($s.JitterCount -gt 0) { [math]::Round($s.JitterSum / $s.JitterCount, 2) } else { 0.0 }
                        }
                        else {
                            $st.maxOutageSec = 0; $st.currentOutageSec = 0
                            $st.outage600msCount = 0; $st.outage5sCount = 0; $st.outageEvents = @()
                            $st.packetLossRate = 0.0; $st.jitter = 0.0; $st.avgJitter = 0.0
                        }
                        $st.isSuppressed = if ($syncHash.Status.ContainsKey($key) -and $syncHash.Status[$key].ContainsKey('isSuppressed')) { $syncHash.Status[$key].isSuppressed } else { $false }
                        $st.connectedTo = if ($syncHash.ConnectedTo.ContainsKey($key)) { $syncHash.ConnectedTo[$key] } else { '' }
                        $st.obr = if ($syncHash.ObrStatus.ContainsKey($key)) { $syncHash.ObrStatus[$key] } else { $null }
                        $st.ipConflict = if ($syncHash.IpConflicts -and $syncHash.IpConflicts.ContainsKey($key)) { $syncHash.IpConflicts[$key] } else { $null }
                        $statusCopy[$key] = $st
                    }
                    # IperfState には実行中の Process オブジェクトと全出力ログが入っており、そのまま JSON 化すると
                    # 1回あたり約0.3秒・50KB超かかってサーバー全体が止まるため、軽い項目だけを返す
                    $statusCopy["_iperf"] = @{
                        Running = [bool]$syncHash.IperfState.Running
                        Target  = $syncHash.IperfState.Target
                        Command = $syncHash.IperfState.Command
                    }
                    # 先頭の「,」は配列を配列のまま渡すための書き方
                    # (付けないと、0件のときは {}、1件のときは配列でない値になり、画面側の処理が毎回エラーになる)
                    $statusCopy["_ipConflicts"] = if ($syncHash.IpConflicts) { , @($syncHash.IpConflicts.Values) } else { , @() }
                    Write-JsonResponse $response $statusCopy
                }
                elseif ($urlPath -eq "/api/ip-conflicts" -and $method -eq "GET") {
                    Write-JsonResponse $response @{
                        status    = "success"
                        conflicts = if ($syncHash.IpConflicts) { @($syncHash.IpConflicts.Values) } else { @() }
                    }
                }
                elseif ($urlPath -eq "/api/devices/delete" -and $method -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $jsonBody = $reader.ReadToEnd()
                    $payload = $jsonBody | ConvertFrom-Json

                    if ($payload.ip) {
                        $ipToRemove = $payload.ip.Trim()
                        [System.Threading.Monitor]::Enter($syncHash.DevicesLock)
                        try {
                            $newArr = [System.Collections.Generic.List[string]]::new()
                            foreach ($d in $syncHash.Devices) {
                                if ($d -ne $ipToRemove) { $newArr.Add($d) }
                            }
                            $syncHash.Devices = $newArr.ToArray()
                            
                            if ($syncHash.Community.ContainsKey($ipToRemove)) { $syncHash.Community.Remove($ipToRemove) }
                            if ($syncHash.DeviceName.ContainsKey($ipToRemove)) { $syncHash.DeviceName.Remove($ipToRemove) }
                            if ($syncHash.IsMonitored.ContainsKey($ipToRemove)) { $syncHash.IsMonitored.Remove($ipToRemove) }
                            if ($syncHash.Group.ContainsKey($ipToRemove)) { $syncHash.Group.Remove($ipToRemove) }
                            if ($syncHash.Image.ContainsKey($ipToRemove)) { $syncHash.Image.Remove($ipToRemove) }
                            if ($syncHash.ConnectedTo.ContainsKey($ipToRemove)) { $syncHash.ConnectedTo.Remove($ipToRemove) }
                            if ($syncHash.History.ContainsKey($ipToRemove)) { $syncHash.History.Remove($ipToRemove) }
                            
                            if ($syncHash.VendorContact.ContainsKey($ipToRemove)) { $syncHash.VendorContact.Remove($ipToRemove) }
                            if ($syncHash.DeviceType.ContainsKey($ipToRemove)) { $syncHash.DeviceType.Remove($ipToRemove) }
                            if ($syncHash.WebUrl.ContainsKey($ipToRemove)) { $syncHash.WebUrl.Remove($ipToRemove) }
                            if ($syncHash.CheckType.ContainsKey($ipToRemove)) { $syncHash.CheckType.Remove($ipToRemove) }
                            if ($syncHash.Port.ContainsKey($ipToRemove)) { $syncHash.Port.Remove($ipToRemove) }

                            # 他の機器の接続先から削除した機器を外す
                            # (残ると構成図で存在しない親を指し続け、リンク追加時の「親は最大2台」の枠も1つ埋まったままになる)
                            foreach ($ctKey in @($syncHash.ConnectedTo.Keys)) {
                                $ctVal = [string]$syncHash.ConnectedTo[$ctKey]
                                if ([string]::IsNullOrWhiteSpace($ctVal)) { continue }
                                $parts = @($ctVal -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
                                if ($parts -contains $ipToRemove) {
                                    $syncHash.ConnectedTo[$ctKey] = (@($parts | Where-Object { $_ -ne $ipToRemove }) -join ',')
                                }
                            }

                            Save-DevicesJson
                        }
                        finally {
                            [System.Threading.Monitor]::Exit($syncHash.DevicesLock)
                        }

                        # 仕様書準拠: 関連履歴・ログファイルのクリーンアップ
                        try {
                            # CSVは「192.168.10.1.csv」のようにドットを残した名前で保存される (/api/history と同じ命名)
                            # ※ 以前は存在しない引数 -DisableNameChecking を Remove-Item に渡して例外になり、さらに
                            #    ドットを "_" に置き換えた名前を探していたため、CSVが一度も削除されていなかった
                            $safeIp = $ipToRemove -replace '[\\/:*?"<>|]', '_'
                            $altSafeIp = $ipToRemove -replace '[\.:_]', '_'
                            if ($syncHash.SessionDir -and (Test-Path $syncHash.SessionDir)) {
                                $targetCsvs = @(
                                    (Join-Path $syncHash.SessionDir "${safeIp}.csv"),
                                    (Join-Path $syncHash.SessionDir "${safeIp}_1.csv"),
                                    (Join-Path $syncHash.SessionDir "${altSafeIp}.csv")
                                )
                                foreach ($tCsv in $targetCsvs) {
                                    if (Test-Path -LiteralPath $tCsv) { Remove-Item -LiteralPath $tCsv -Force -ErrorAction SilentlyContinue }
                                }
                                # ローテーション済みの分割CSV (_1, _2, ...) もまとめて削除
                                Get-ChildItem -LiteralPath $syncHash.SessionDir -Filter "${safeIp}_*.csv" -File -ErrorAction SilentlyContinue |
                                    Remove-Item -Force -ErrorAction SilentlyContinue
                            }
                        }
                        catch {}

                        Log-Audit -action "DEVICE_DELETE" -target $ipToRemove -details "Device $ipToRemove deleted" -clientIp $request.RemoteEndPoint.Address.ToString() -reportsDirectory $ReportsDir
                        
                        Write-JsonResponse $response @{ status = "success" }
                    }
                    else {
                        Write-JsonResponse $response @{ error = "Missing ip" } 400
                    }
                }
                elseif ($urlPath -eq "/api/device" -and $method -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $jsonBody = $reader.ReadToEnd()
                    $payload = $jsonBody | ConvertFrom-Json

                    if ($payload.ip) {
                        $ip = $payload.ip.Trim()
                        $ipRegex = '^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
                        if ($ip -notmatch $ipRegex) {
                            Write-JsonResponse $response @{ error = "Invalid IP Address format" } 400
                            continue
                        }
                        
                        $comm = if ($payload.community) { $payload.community.Trim() } else { "public" }
                        $name = if ($payload.name) { $payload.name.Trim() } else { $ip }
                        $group = if ($null -ne $payload.group) { $payload.group.Trim() } else { "" }
                        $enabled = if ($null -ne $payload.enabled) { [bool]$payload.enabled } else { $true }
                        $image = if ($payload.image) { $payload.image.Trim() } else { "" }
                        $connectedTo = if ($payload.connectedTo) { $payload.connectedTo.Trim() } else { "" }
                        
                        # SNMPv3 parameters
                        $snmpVersion = if ($payload.snmpVersion) { $payload.snmpVersion.Trim() } else { "v2c" }
                        $snmpUser = if ($payload.snmpUser) { $payload.snmpUser.Trim() } else { "" }
                        $snmpAuthProto = if ($payload.snmpAuthProto) { $payload.snmpAuthProto.Trim() } else { "none" }
                        $snmpAuthPass = if ($payload.snmpAuthPass) { Unprotect-SecretString ([string]$payload.snmpAuthPass) } else { "" }   # 暗号化された形 (enc:...) で届いても使えるように復号
                        $snmpPrivProto = if ($payload.snmpPrivProto) { $payload.snmpPrivProto.Trim() } else { "none" }
                        $snmpPrivPass = if ($payload.snmpPrivPass) { Unprotect-SecretString ([string]$payload.snmpPrivPass) } else { "" }
                        
                        [System.Threading.Monitor]::Enter($syncHash.DevicesLock)
                        try {
                            $isNew = $true
                            foreach ($d in $syncHash.Devices) {
                                if ($d -eq $ip) { $isNew = $false; break }
                            }
                            
                            if ($isNew) {
                                $newArr = [System.Collections.Generic.List[string]]::new()
                                foreach ($d in $syncHash.Devices) { $newArr.Add($d) }
                                $newArr.Add($ip)
                                $syncHash.Devices = $newArr.ToArray()
                                
                                if ($enabled) {
                                    Initialize-DeviceLog -ip $ip
                                }
                            }
                            
                            if ($syncHash.Group.ContainsKey($ip) -and $syncHash.Group[$ip] -ne $group) {
                                $syncHash.X[$ip] = $null
                                $syncHash.Y[$ip] = $null
                            }

                            $syncHash.Community[$ip] = $comm
                            $syncHash.DeviceName[$ip] = $name
                            $syncHash.Group[$ip] = $group
                            $syncHash.IsMonitored[$ip] = $enabled
                            $syncHash.Image[$ip] = $image
                            $syncHash.ConnectedTo[$ip] = $connectedTo
                            
                            $syncHash.SnmpVersion[$ip] = $snmpVersion
                            $syncHash.SnmpUser[$ip] = $snmpUser
                            $syncHash.SnmpAuthProto[$ip] = $snmpAuthProto
                            $syncHash.SnmpAuthPass[$ip] = $snmpAuthPass
                            $syncHash.SnmpPrivProto[$ip] = $snmpPrivProto
                            $syncHash.SnmpPrivPass[$ip] = $snmpPrivPass
                            $syncHash.ObrEnabled[$ip] = [bool]$payload.obrEnabled
                            $syncHash.ObrPassword[$ip] = if ($payload.obrPassword) { Protect-SecretString ([string]$payload.obrPassword) } else { "" }
                            $syncHash.VendorContact[$ip] = if ($null -ne $payload.vendorContact) { [string]$payload.vendorContact } else { "" }
                            $syncHash.DeviceType[$ip] = if ($null -ne $payload.deviceType) { [string]$payload.deviceType } else { "network" }
                            $syncHash.WebUrl[$ip] = if ($null -ne $payload.webUrl) { [string]$payload.webUrl } else { "" }
                            $syncHash.CheckType[$ip] = if ($null -ne $payload.checkType) { [string]$payload.checkType } else { "icmp" }
                            $syncHash.Port[$ip] = if ($null -ne $payload.port) { [int]$payload.port } else { 0 }

                            if ($null -ne $payload.x) { $syncHash.X[$ip] = $payload.x }
                            if ($null -ne $payload.y) { $syncHash.Y[$ip] = $payload.y }
                            
                            if ($enabled) {
                                Initialize-DeviceLog -ip $ip
                            }

                            Save-DevicesJson
                        }
                        finally {
                            [System.Threading.Monitor]::Exit($syncHash.DevicesLock)
                        }
                        Log-Audit -action "DEVICE_ADD" -target $ip -details "Device $name ($ip) registered" -clientIp $request.RemoteEndPoint.Address.ToString() -reportsDirectory $ReportsDir
                        Write-JsonResponse $response @{ status = "success" }
                    }
                    else {
                        Write-JsonResponse $response @{ error = "Missing ip" } 400
                    }
                }
                elseif ($urlPath -eq "/api/device/remote-exec" -and $method -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $jsonBody = $reader.ReadToEnd()
                    $payload = $null
                    try {
                        if (-not [string]::IsNullOrWhiteSpace($jsonBody)) {
                            $payload = $jsonBody | ConvertFrom-Json
                        }
                    }
                    catch {}

                    if ($null -eq $payload) {
                        Write-JsonResponse $response @{ error = "Invalid JSON body"; success = $false; status = "INVALID_REQUEST" } 400
                        continue
                    }

                    $ip = if ($payload.ip) { [string]$payload.ip.Trim() } else { "" }
                    $action = if ($payload.action) { [string]$payload.action.Trim().ToLower() } else { "" }
                    $commandId = if ($payload.commandId) { [string]$payload.commandId.Trim() } else { $null }
                    $customCommand = if ($payload.customCommand) { [string]$payload.customCommand.Trim() } else { $null }
                    # 数値でない値 ("abc" など) は [int] 変換で例外になるため TryParse で既定値に戻す
                    $timeoutSec = 15
                    $parsedTimeout = 0
                    if ($null -ne $payload.timeoutSec -and [int]::TryParse([string]$payload.timeoutSec, [ref]$parsedTimeout) -and $parsedTimeout -gt 0 -and $parsedTimeout -le 300) { $timeoutSec = $parsedTimeout }

                    if ([string]::IsNullOrWhiteSpace($ip)) {
                        Write-JsonResponse $response @{ error = "Target IP address is required"; success = $false; status = "MISSING_IP" } 400
                        continue
                    }

                    if ($action -ne "reboot" -and $action -ne "command") {
                        Write-JsonResponse $response @{ error = "Invalid action: must be 'reboot' or 'command'"; success = $false; status = "INVALID_ACTION" } 400
                        continue
                    }

                    # Verify device exists in monitoring list
                    $deviceFound = $false
                    if ($syncHash.Devices) {
                        foreach ($d in $syncHash.Devices) {
                            if ($d -eq $ip) { $deviceFound = $true; break }
                        }
                    }

                    if (-not $deviceFound) {
                        Write-JsonResponse $response @{ error = "Device '$ip' not found"; success = $false; status = "DEVICE_NOT_FOUND" } 404
                        continue
                    }

                    # Check remote configuration
                    $remoteCfg = if ($syncHash.Remote -and $syncHash.Remote.ContainsKey($ip)) { $syncHash.Remote[$ip] } else { $null }
                    if ($null -eq $remoteCfg) {
                        Write-JsonResponse $response @{ error = "Remote execution not configured for device '$ip'"; success = $false; status = "NOT_CONFIGURED" } 400
                        continue
                    }

                    # Normalize to Hashtable immediately to support both PSCustomObject and Hashtable
                    $remoteCopy = @{}
                    if ($remoteCfg -is [System.Collections.IDictionary]) {
                        foreach ($k in $remoteCfg.Keys) {
                            $remoteCopy[$k] = $remoteCfg[$k]
                        }
                    }
                    elseif ($null -ne $remoteCfg.PSObject) {
                        foreach ($prop in $remoteCfg.PSObject.Properties) {
                            $remoteCopy[$prop.Name] = $prop.Value
                        }
                    }

                    $isEnabled = [bool]$(if ($remoteCopy.ContainsKey('enabled')) { $remoteCopy['enabled'] } else { $false })
                    if (-not $isEnabled) {
                        Write-JsonResponse $response @{ error = "Remote management is disabled for device '$ip'"; success = $false; status = "REMOTE_DISABLED" } 400
                        continue
                    }

                    $deviceName = if ($syncHash.DeviceName -and $syncHash.DeviceName.ContainsKey($ip)) { $syncHash.DeviceName[$ip] } else { $ip }

                    if ($remoteCopy.ContainsKey('password') -and -not [string]::IsNullOrWhiteSpace($remoteCopy['password'])) {
                        $remoteCopy['password'] = Unprotect-SecretString ([string]$remoteCopy['password'])
                    }

                    $deviceArg = @{
                        ip     = $ip
                        name   = $deviceName
                        remote = $remoteCopy
                    }

                    # 時間のかかるリモート実行は別スレッドで行い、HTTP受付ループ（画面更新・Watchdog の死活確認）を止めない
                    $clientIp = if ($request.RemoteEndPoint) { $request.RemoteEndPoint.Address.ToString() } else { "127.0.0.1" }
                    $remoteExecModule = Join-Path $PSScriptRoot "modules\RemoteExec.psm1"
                    Start-BackgroundScript -ArgumentList @($response, $remoteExecModule, $deviceArg, $action, $commandId, $customCommand, $timeoutSec, $deviceName, $ip, $clientIp, $remoteCopy) -ScriptBlock {
                        param($response, $remoteExecModule, $deviceArg, $action, $commandId, $customCommand, $timeoutSec, $deviceName, $ip, $clientIp, $remoteCopy)
                        Import-Module $remoteExecModule -DisableNameChecking -ErrorAction SilentlyContinue
                        try {
                            $execResult = Invoke-RemoteDeviceCommand -Device $deviceArg -Action $action -CommandId $commandId -CustomCommand $customCommand -TimeoutSec $timeoutSec

                            # 操作履歴 (Audit Log) 記録
                            $auditAction = if ($action -eq "reboot") { "REMOTE_REBOOT" } else { "REMOTE_EXEC" }
                            $auditDetails = "Device: $deviceName ($ip) | Action: $action | Command: $($execResult.command) | Status: $($execResult.status) | ExitCode: $($execResult.exitCode) | Duration: $($execResult.executionTimeMs)ms"
                            Log-Audit -action $auditAction -target $ip -details $auditDetails -clientIp $clientIp -reportsDirectory $ReportsDir

                            Write-JsonResponse $response $execResult 200
                        }
                        catch {
                            $errDetails = $_.Exception.Message
                            Log-Audit -action "REMOTE_ERROR" -target $ip -details "Error executing remote $action on $deviceName ($ip): $errDetails" -clientIp $clientIp -reportsDirectory $ReportsDir
                            Write-JsonResponse $response @{
                                success         = $false
                                status          = "ERROR"
                                exitCode        = -1
                                target          = $ip
                                deviceName      = $deviceName
                                remoteType      = if ($remoteCopy -and $remoteCopy.ContainsKey('protocol')) { [string]$remoteCopy['protocol'] } else { "unknown" }
                                action          = $action
                                command         = ""
                                stdout          = ""
                                stderr          = "Server error during remote execution: $errDetails"
                                executionTimeMs = 0
                                timestamp       = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                            } 500
                        }
                    }
                    continue
                }
                elseif ($urlPath -eq "/api/device/fetch-log" -and $method -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $jsonBody = $reader.ReadToEnd()
                    $payload = $null
                    try {
                        if (-not [string]::IsNullOrWhiteSpace($jsonBody)) {
                            $payload = $jsonBody | ConvertFrom-Json
                        }
                    }
                    catch {}

                    if ($null -eq $payload) {
                        Write-JsonResponse $response @{ error = "Invalid JSON body"; success = $false; status = "INVALID_REQUEST" } 400
                        continue
                    }

                    $ip = if ($payload.ip) { [string]$payload.ip.Trim() } else { "" }
                    $presetId = if ($payload.presetId) { [string]$payload.presetId.Trim() } else { "" }
                    $customCommand = if ($payload.customCommand) { [string]$payload.customCommand.Trim() } else { "" }
                    if ([string]::IsNullOrWhiteSpace($customCommand) -and $payload.command) {
                        $customCommand = [string]$payload.command.Trim()
                    }
                    # 数値でない値 ("abc" など) は [int] 変換で例外になるため TryParse で既定値に戻す
                    $timeoutSec = 20
                    $parsedTimeout = 0
                    if ($null -ne $payload.timeoutSec -and [int]::TryParse([string]$payload.timeoutSec, [ref]$parsedTimeout) -and $parsedTimeout -gt 0 -and $parsedTimeout -le 300) { $timeoutSec = $parsedTimeout }

                    if ([string]::IsNullOrWhiteSpace($ip)) {
                        Write-JsonResponse $response @{ error = "Target IP address is required"; success = $false; status = "MISSING_IP" } 400
                        continue
                    }

                    # Verify device exists in monitoring list
                    $deviceFound = $false
                    if ($syncHash.Devices) {
                        foreach ($d in $syncHash.Devices) {
                            if ($d -eq $ip) { $deviceFound = $true; break }
                        }
                    }

                    if (-not $deviceFound) {
                        Write-JsonResponse $response @{ error = "Device '$ip' not found"; success = $false; status = "DEVICE_NOT_FOUND" } 404
                        continue
                    }

                    # Check remote configuration
                    $remoteCfg = if ($syncHash.Remote -and $syncHash.Remote.ContainsKey($ip)) { $syncHash.Remote[$ip] } else { $null }
                    if ($null -eq $remoteCfg) {
                        Write-JsonResponse $response @{ error = "Remote execution not configured for device '$ip'"; success = $false; status = "NOT_CONFIGURED" } 400
                        continue
                    }

                    # Normalize to Hashtable immediately to support both PSCustomObject and Hashtable
                    $remoteCopy = @{}
                    if ($remoteCfg -is [System.Collections.IDictionary]) {
                        foreach ($k in $remoteCfg.Keys) {
                            $remoteCopy[$k] = $remoteCfg[$k]
                        }
                    }
                    elseif ($null -ne $remoteCfg.PSObject) {
                        foreach ($prop in $remoteCfg.PSObject.Properties) {
                            $remoteCopy[$prop.Name] = $prop.Value
                        }
                    }

                    $isEnabled = [bool]$(if ($remoteCopy.ContainsKey('enabled')) { $remoteCopy['enabled'] } else { $false })
                    if (-not $isEnabled) {
                        Write-JsonResponse $response @{ error = "Remote management is disabled for device '$ip'"; success = $false; status = "REMOTE_DISABLED" } 400
                        continue
                    }

                    $deviceName = if ($syncHash.DeviceName -and $syncHash.DeviceName.ContainsKey($ip)) { $syncHash.DeviceName[$ip] } else { $ip }
                    $protocol = if ($remoteCopy.ContainsKey('protocol')) { [string]$remoteCopy['protocol'] } else { "ssh" }

                    # Resolve command: if customCommand is non-empty use it; else find matching preset command
                    $resolvedCommand = ""
                    if (-not [string]::IsNullOrWhiteSpace($customCommand)) {
                        $resolvedCommand = $customCommand
                    }
                    elseif (-not [string]::IsNullOrWhiteSpace($presetId)) {
                        $allPresets = Get-DeviceLogPresets
                        foreach ($p in $allPresets) {
                            if ($p.id -eq $presetId) {
                                $resolvedCommand = [string]$p.command
                                break
                            }
                        }
                        # Fallback to device-registered commands if not found in standard presets
                        if ([string]::IsNullOrWhiteSpace($resolvedCommand) -and $remoteCopy.ContainsKey('commands') -and $null -ne $remoteCopy['commands']) {
                            foreach ($cmdItem in $remoteCopy['commands']) {
                                $cId = if ($cmdItem.id) { [string]$cmdItem.id } else { "" }
                                if ($cId -eq $presetId) {
                                    $resolvedCommand = if ($cmdItem.command) { [string]$cmdItem.command } else { "" }
                                    break
                                }
                            }
                        }
                    }

                    if ([string]::IsNullOrWhiteSpace($resolvedCommand)) {
                        Write-JsonResponse $response @{ error = "No command specified or preset not found"; success = $false; status = "NO_COMMAND_SPECIFIED" } 400
                        continue
                    }

                    # Prepare device configuration object (ensuring password is decrypted for execution)
                    if ($remoteCopy.ContainsKey('password') -and -not [string]::IsNullOrWhiteSpace($remoteCopy['password'])) {
                        $remoteCopy['password'] = Unprotect-SecretString ([string]$remoteCopy['password'])
                    }

                    $deviceArg = @{
                        ip     = $ip
                        name   = $deviceName
                        remote = $remoteCopy
                    }

                    # 時間のかかるリモート実行は別スレッドで行い、HTTP受付ループ（画面更新・Watchdog の死活確認）を止めない
                    $clientIp = if ($request.RemoteEndPoint) { $request.RemoteEndPoint.Address.ToString() } else { "127.0.0.1" }
                    $remoteExecModule = Join-Path $PSScriptRoot "modules\RemoteExec.psm1"
                    Start-BackgroundScript -ArgumentList @($response, $remoteExecModule, $deviceArg, $resolvedCommand, $timeoutSec, $deviceName, $ip, $clientIp, $protocol) -ScriptBlock {
                        param($response, $remoteExecModule, $deviceArg, $resolvedCommand, $timeoutSec, $deviceName, $ip, $clientIp, $protocol)
                        Import-Module $remoteExecModule -DisableNameChecking -ErrorAction SilentlyContinue
                        try {
                            $execResult = Invoke-RemoteDeviceCommand -Device $deviceArg -Action "command" -CustomCommand $resolvedCommand -TimeoutSec $timeoutSec

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

                            # Save full untruncated output to Reports/device_logs/{IP}_{timestamp}.log
                            $saveResult = Save-DeviceLogFile -ReportsDirectory $ReportsDir -Ip $ip -DeviceName $deviceName -Protocol $protocol -Command $resolvedCommand -LogContent $stdout -Status $execStatus -ExitCode $exitCode -DurationMs $durationMs -Timestamp $fileTimestamp

                            $logFileName = if ($saveResult.success) { $saveResult.fileName } else { "${ip}_${fileTimestamp}.log" }
                            $logFilePath = if ($saveResult.success) { $saveResult.filePath } else { "Reports/device_logs/$logFileName" }

                            # Buffer guard: if stdout length exceeds 1,000,000 chars (~1MB), truncate stdout in HTTP response
                            $truncated = $false
                            $responseStdout = $stdout
                            if ($stdout.Length -gt 1000000) {
                                $truncated = $true
                                $truncationMsg = "`r`n`r`n--- [TRUNCATED: 出力サイズが1MBを超過したため画面表示を切り詰めました。全ログはダウンロード機能または $logFilePath をご参照ください] ---"
                                $responseStdout = $stdout.Substring(0, 1000000) + $truncationMsg
                            }

                            # Write audit record via Log-Audit
                            $auditDetails = "Device: $deviceName ($ip) | Command: $resolvedCommand | Status: $execStatus | ExitCode: $exitCode | Lines: $lineCount | Size: $($stdout.Length)B | File: $logFileName | Duration: ${durationMs}ms"
                            Log-Audit -action "LOG_RETRIEVAL" -target $ip -details $auditDetails -clientIp $clientIp -reportsDirectory $ReportsDir

                            if ($execStatus -eq "COMPLETED" -or $execResult.success -eq $true) {
                                Write-JsonResponse $response @{
                                    success     = $true
                                    status      = "COMPLETED"
                                    ip          = $ip
                                    deviceName  = $deviceName
                                    command     = $resolvedCommand
                                    stdout      = $responseStdout
                                    stderr      = $stderr
                                    exitCode    = $exitCode
                                    truncated   = $truncated
                                    lineCount   = $lineCount
                                    sizeBytes   = $rawSizeBytes
                                    logFilePath = $logFilePath
                                    logFileName = $logFileName
                                    timestamp   = $timestampIso
                                    durationMs  = $durationMs
                                } 200
                            }
                            elseif ($execStatus -eq "TIMEOUT") {
                                Write-JsonResponse $response @{
                                    success     = $false
                                    status      = "TIMEOUT"
                                    error       = "Execution timed out after $timeoutSec seconds"
                                    ip          = $ip
                                    deviceName  = $deviceName
                                    command     = $resolvedCommand
                                    stdout      = $responseStdout
                                    stderr      = $stderr
                                    exitCode    = $exitCode
                                    truncated   = $truncated
                                    lineCount   = $lineCount
                                    sizeBytes   = $rawSizeBytes
                                    logFilePath = $logFilePath
                                    logFileName = $logFileName
                                    timestamp   = $timestampIso
                                    durationMs  = $durationMs
                                } 500
                            }
                            else {
                                Write-JsonResponse $response @{
                                    success     = $false
                                    status      = "EXECUTION_FAILED"
                                    error       = if (-not [string]::IsNullOrWhiteSpace($stderr)) { $stderr } else { "Execution failed with status: $execStatus" }
                                    ip          = $ip
                                    deviceName  = $deviceName
                                    command     = $resolvedCommand
                                    stdout      = $responseStdout
                                    stderr      = $stderr
                                    exitCode    = $exitCode
                                    truncated   = $truncated
                                    lineCount   = $lineCount
                                    sizeBytes   = $rawSizeBytes
                                    logFilePath = $logFilePath
                                    logFileName = $logFileName
                                    timestamp   = $timestampIso
                                    durationMs  = $durationMs
                                } 500
                            }
                        }
                        catch {
                            $errDetails = $_.Exception.Message
                            Log-Audit -action "LOG_ERROR" -target $ip -details "Error retrieving log from $deviceName ($ip): $errDetails" -clientIp $clientIp -reportsDirectory $ReportsDir
                            Write-JsonResponse $response @{
                                success     = $false
                                status      = "EXECUTION_FAILED"
                                error       = "Server error during log retrieval: $errDetails"
                                ip          = $ip
                                deviceName  = $deviceName
                                command     = $resolvedCommand
                                stdout      = ""
                                stderr      = $errDetails
                                exitCode    = -1
                                truncated   = $false
                                lineCount   = 0
                                sizeBytes   = 0
                                logFilePath = ""
                                logFileName = ""
                                timestamp   = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
                                durationMs  = 0
                            } 500
                        }
                    }
                    continue
                }
                elseif ($urlPath -eq "/api/device/logs" -and $method -eq "GET") {
                    $targetIp = if ($request.QueryString["ip"]) { [string]$request.QueryString["ip"].Trim() } else { "" }
                    if ([string]::IsNullOrWhiteSpace($targetIp) -and $request.Url -and $request.Url.Query) {
                        if ($request.Url.Query -match 'ip=([^&]+)') {
                            $targetIp = [System.Uri]::UnescapeDataString($matches[1]).Trim()
                        }
                    }
                    $deviceLogsDir = Join-Path $ReportsDir "device_logs"
                    $logList = @()

                    if (Test-Path $deviceLogsDir) {
                        $filterPattern = if (-not [string]::IsNullOrWhiteSpace($targetIp)) {
                            $safeIp = $targetIp -replace '[\\/:*?"<>|]', '_'
                            "${safeIp}_*.log"
                        }
                        else {
                            "*.log"
                        }

                        $files = Get-ChildItem -Path $deviceLogsDir -Filter $filterPattern -File -ErrorAction SilentlyContinue |
                        Sort-Object -Property LastWriteTime -Descending

                        foreach ($f in $files) {
                            $fName = $f.Name
                            $fPath = "Reports/device_logs/$fName"
                            $fSize = $f.Length
                            $sizeKb = [math]::Round($fSize / 1KB, 1)
                            $sizeFormatted = if ($fSize -ge 1MB) { "$([math]::Round($fSize / 1MB, 2)) MB" } else { "$sizeKb KB" }

                            # Extract IP from filename (format: {ip}_{yyyyMMdd_HHmmss}.log)
                            $fileIp = ""
                            if ($fName -match '^(.*)_(\d{8}_\d{6})\.log$') {
                                $fileIp = $matches[1]
                            }
                            else {
                                $fileIp = $targetIp
                            }

                            # Parse metadata from structured header
                            $fileLines = 0
                            $headerTimestamp = $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
                            try {
                                $reader = [System.IO.File]::OpenText($f.FullName)
                                try {
                                    $headerCount = 0
                                    $outputLineCount = 0
                                    while (-not $reader.EndOfStream -and $headerCount -lt 15) {
                                        $line = $reader.ReadLine()
                                        $headerCount++
                                        if ($line -match '^\s*Timestamp:\s*(.+)$') {
                                            $headerTimestamp = $matches[1].Trim()
                                        }
                                        if ($line -match '^\s*Lines:\s*(\d+)') {
                                            $fileLines = [int]$matches[1]
                                        }
                                        if ($line -eq "[OUTPUT]") {
                                            break
                                        }
                                    }
                                    if ($fileLines -eq 0) {
                                        while (-not $reader.EndOfStream) {
                                            $null = $reader.ReadLine()
                                            $outputLineCount++
                                        }
                                        $fileLines = $outputLineCount
                                    }
                                }
                                finally {
                                    $reader.Close()
                                    $reader.Dispose()
                                }
                            }
                            catch {
                                $fileLines = 0
                            }

                            $logList += @{
                                fileName      = $fName
                                filePath      = $fPath
                                ip            = $fileIp
                                timestamp     = $headerTimestamp
                                sizeBytes     = $fSize
                                sizeFormatted = $sizeFormatted
                                lineCount     = $fileLines
                            }
                        }
                    }

                    Write-JsonResponse $response @{
                        success = $true
                        ip      = $targetIp
                        logs    = $logList
                    } 200
                }
                elseif ($urlPath -eq "/api/device/log-download" -and $method -eq "GET") {
                    $requestedFile = if ($request.QueryString["file"]) { [string]$request.QueryString["file"] } else { [string]$request.QueryString["fileName"] }
                    if ([string]::IsNullOrWhiteSpace($requestedFile) -and $request.Url -and $request.Url.Query) {
                        if ($request.Url.Query -match '(?:file|fileName)=([^&]+)') {
                            $requestedFile = [System.Uri]::UnescapeDataString($matches[1]).Trim()
                        }
                    }
                    if ([string]::IsNullOrWhiteSpace($requestedFile)) {
                        Write-JsonResponse $response @{ error = "Parameter 'file' is required"; success = $false } 400
                        continue
                    }

                    $cleanFileName = [System.IO.Path]::GetFileName($requestedFile)
                    if ([string]::IsNullOrWhiteSpace($cleanFileName)) {
                        Write-JsonResponse $response @{ error = "Invalid file name"; success = $false } 400
                        continue
                    }

                    $ext = [System.IO.Path]::GetExtension($cleanFileName).ToLower()
                    if ($ext -ne ".log" -and $ext -ne ".txt") {
                        Write-JsonResponse $response @{ error = "Invalid file extension: only .log or .txt allowed"; success = $false } 400
                        continue
                    }

                    $deviceLogsDir = Join-Path $ReportsDir "device_logs"
                    $targetFilePath = Join-Path $deviceLogsDir $cleanFileName
                    $fullLogsDir = [System.IO.Path]::GetFullPath($deviceLogsDir)
                    if (-not $fullLogsDir.EndsWith([System.IO.Path]::DirectorySeparatorChar.ToString())) {
                        $fullLogsDir += [System.IO.Path]::DirectorySeparatorChar
                    }
                    $fullTargetPath = [System.IO.Path]::GetFullPath($targetFilePath)

                    if (-not $fullTargetPath.StartsWith($fullLogsDir, [System.StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path $fullTargetPath -PathType Leaf)) {
                        Write-JsonResponse $response @{ error = "Log file not found: $cleanFileName"; success = $false } 404
                        continue
                    }

                    try {
                        $response.StatusCode = 200
                        $response.ContentType = "text/plain; charset=utf-8"
                        $response.Headers.Add("Content-Disposition", "attachment; filename=`"$cleanFileName`"")
                        [byte[]]$fileBytes = [System.IO.File]::ReadAllBytes($fullTargetPath)
                        $response.ContentLength64 = $fileBytes.Length
                        $response.OutputStream.Write($fileBytes, 0, $fileBytes.Length)
                        $response.Close()
                    }
                    catch {
                        try { $response.Close() } catch {}
                    }
                    continue
                }
                elseif ($urlPath -eq "/api/device/log-presets" -and $method -eq "GET") {
                    $presets = Get-DeviceLogPresets
                    Write-JsonResponse $response @{
                        success = $true
                        presets = $presets
                    } 200
                }
                elseif ($urlPath -eq "/api/devices/bulk" -and $method -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $jsonBody = $reader.ReadToEnd()
                    $payload = $jsonBody | ConvertFrom-Json

                    if ($null -ne $payload) {
                        $ipRegex = '^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
                        [System.Threading.Monitor]::Enter($syncHash.DevicesLock)
                        try {
                            foreach ($item in $payload) {
                                if ($item.ip) {
                                    $ip = $item.ip.Trim()
                                    if ($ip -notmatch $ipRegex) { continue }
                                    
                                    # 送られてきた項目だけ更新する。項目がなければ、登録済みの機器は今の値のまま、新しい機器は標準値にする
                                    # (以前は省略した項目が標準値で上書きされ、CSV インポートなどで SNMPv3 のパスワード等が消えてしまう形だった)
                                    $bulkItem = $item
                                    $bulkIp = $ip
                                    $bulkField = {
                                        param($fieldName, $table, $default)
                                        if ($null -ne $bulkItem.PSObject.Properties[$fieldName] -and $null -ne $bulkItem.$fieldName) { return ([string]$bulkItem.$fieldName).Trim() }
                                        if ($null -ne $table -and $table.ContainsKey($bulkIp)) { return $table[$bulkIp] }
                                        return $default
                                    }
                                    $comm = & $bulkField 'community' $syncHash.Community "public"
                                    if ([string]::IsNullOrWhiteSpace($comm)) { $comm = "public" }
                                    $name = & $bulkField 'name' $syncHash.DeviceName $ip
                                    if ([string]::IsNullOrWhiteSpace($name)) { $name = $ip }
                                    $group = & $bulkField 'group' $syncHash.Group ""
                                    $enabled = if ($null -ne $item.enabled) { [bool]$item.enabled } elseif ($syncHash.IsMonitored.ContainsKey($ip)) { $syncHash.IsMonitored[$ip] } else { $true }
                                    $image = & $bulkField 'image' $syncHash.Image ""
                                    $connectedTo = & $bulkField 'connectedTo' $syncHash.ConnectedTo ""

                                    # SNMPv3 parameters
                                    $snmpVersion = & $bulkField 'snmpVersion' $syncHash.SnmpVersion "v2c"
                                    if ([string]::IsNullOrWhiteSpace($snmpVersion)) { $snmpVersion = "v2c" }
                                    $snmpUser = & $bulkField 'snmpUser' $syncHash.SnmpUser ""
                                    $snmpAuthProto = & $bulkField 'snmpAuthProto' $syncHash.SnmpAuthProto "none"
                                    if ([string]::IsNullOrWhiteSpace($snmpAuthProto)) { $snmpAuthProto = "none" }
                                    $snmpAuthPass = if ($null -ne $item.PSObject.Properties['snmpAuthPass']) { Unprotect-SecretString ([string]$item.snmpAuthPass) } elseif ($syncHash.SnmpAuthPass.ContainsKey($ip)) { $syncHash.SnmpAuthPass[$ip] } else { "" }
                                    $privProto = & $bulkField 'snmpPrivProto' $syncHash.SnmpPrivProto "none"
                                    if ([string]::IsNullOrWhiteSpace($privProto)) { $privProto = "none" }
                                    $privPass = if ($null -ne $item.PSObject.Properties['snmpPrivPass']) { Unprotect-SecretString ([string]$item.snmpPrivPass) } elseif ($syncHash.SnmpPrivPass.ContainsKey($ip)) { $syncHash.SnmpPrivPass[$ip] } else { "" }
                                    # 以前はこの API で保守連絡先等が保存されず、機器の新規登録画面で入力しても消えていた
                                    $syncHash.VendorContact[$ip] = & $bulkField 'vendorContact' $syncHash.VendorContact ""
                                    $syncHash.DeviceType[$ip] = & $bulkField 'deviceType' $syncHash.DeviceType "network"
                                    $syncHash.WebUrl[$ip] = & $bulkField 'webUrl' $syncHash.WebUrl ""

$isNew = $true
                                    foreach ($d in $syncHash.Devices) {
                                        if ($d -eq $ip) { $isNew = $false; break }
                                    }
                                    
                                    if ($isNew) {
                                        $newArr = [System.Collections.Generic.List[string]]::new()
                                        foreach ($d in $syncHash.Devices) { $newArr.Add($d) }
                                        $newArr.Add($ip)
                                        $syncHash.Devices = $newArr.ToArray()
                                    }
                                    
                                    if ($syncHash.Group.ContainsKey($ip) -and $syncHash.Group[$ip] -ne $group) {
                                        $syncHash.X[$ip] = $null
                                        $syncHash.Y[$ip] = $null
                                    }

                                    $syncHash.Community[$ip] = $comm
                                    $syncHash.DeviceName[$ip] = $name
                                    $syncHash.Group[$ip] = $group
                                    $syncHash.IsMonitored[$ip] = $enabled
                                    $syncHash.Image[$ip] = $image
                                    $syncHash.ConnectedTo[$ip] = $connectedTo
                                    
                                    $syncHash.SnmpVersion[$ip] = $snmpVersion
                                    $syncHash.SnmpUser[$ip] = $snmpUser
                                    $syncHash.SnmpAuthProto[$ip] = $snmpAuthProto
                                    $syncHash.SnmpAuthPass[$ip] = $snmpAuthPass
                                    $syncHash.SnmpPrivProto[$ip] = $privProto
                                    $syncHash.SnmpPrivPass[$ip] = $privPass
                                    if ($null -ne $item.PSObject.Properties['obrEnabled'] -and $null -ne $item.obrEnabled) { $syncHash.ObrEnabled[$ip] = [bool]$item.obrEnabled }
                                    if ($null -ne $item.PSObject.Properties['obrPassword']) { $syncHash.ObrPassword[$ip] = if ($item.obrPassword) { Protect-SecretString ([string]$item.obrPassword) } else { "" } }
                                    if ($null -ne $item.checkType) { $syncHash.CheckType[$ip] = [string]$item.checkType }
                                    if ($null -ne $item.port) { $syncHash.Port[$ip] = [int]$item.port }

                                    if ($null -ne $item.x) { $syncHash.X[$ip] = $item.x }
                                    if ($null -ne $item.y) { $syncHash.Y[$ip] = $item.y }

                                    # Ingest remote configuration
                                    if ($null -ne $item.remote) {
                                        $rHash = @{}
                                        if ($item.remote -is [System.Collections.IDictionary]) {
                                            foreach ($k in $item.remote.Keys) { $rHash[$k] = $item.remote[$k] }
                                        }
                                        elseif ($null -ne $item.remote.PSObject) {
                                            foreach ($prop in $item.remote.PSObject.Properties) { $rHash[$prop.Name] = $prop.Value }
                                        }
                                        if ($rHash.ContainsKey('password') -and -not [string]::IsNullOrWhiteSpace($rHash['password'])) {
                                            $rHash['password'] = Protect-SecretString ([string]$rHash['password'])
                                        }
                                        if (-not $syncHash.Remote) {
                                            $syncHash.Remote = [hashtable]::Synchronized(@{})
                                        }
                                        $syncHash.Remote[$ip] = $rHash
                                    }

                                    if ($enabled) {
                                        Initialize-DeviceLog -ip $ip
                                    }
                                }
                            }
                        }
                        finally {
                            [System.Threading.Monitor]::Exit($syncHash.DevicesLock)
                        }
                        Save-DevicesJson
                        Write-JsonResponse $response @{ status = "success" }
                    }
                    else {
                        Write-JsonResponse $response @{ error = "Invalid payload" } 400
                    }
                }
                elseif ($urlPath -eq "/api/device/snmp-details" -and $method -eq "GET") {
                    $ip = $request.QueryString["ip"]
                    if ($null -eq $ip -or $ip -eq "") {
                        Write-JsonResponse $response @{ error = "Missing 'ip' parameter" } 400
                        continue
                    }
                    
                    $device = $null
                    if ($syncHash.Devices -contains $ip) {
                        $device = @{
                            ip        = $ip
                            community = if ($syncHash.Community.ContainsKey($ip)) { $syncHash.Community[$ip] } else { "public" }
                            name      = if ($syncHash.DeviceName.ContainsKey($ip)) { $syncHash.DeviceName[$ip] } else { $ip }
                            image     = if ($syncHash.Image.ContainsKey($ip)) { $syncHash.Image[$ip] } else { "" }
                            enabled   = if ($syncHash.IsMonitored.ContainsKey($ip)) { $syncHash.IsMonitored[$ip] } else { $true }
                        }
                    }
                    
                    if ($null -eq $device) {
                        Write-JsonResponse $response @{ error = "Device not found" } 404
                        continue
                    }
                    
                    $respRef = $response
                    $devRef = $device
                    $ipRef = $ip
                    
                    Start-BackgroundScript -ArgumentList @($respRef, $devRef, $ipRef) -ScriptBlock {
                        param($respRef, $devRef, $ipRef)
                        try {
                            $community = $devRef.community
                            # Ping状態に関係なくSNMP問い合わせを試みる
                            # (警告中・超高速モードの低頻度監視中・Ping遮断機器でもSNMPは応答する場合があるため)
                            $pingStatus = if ($syncHash.Status.ContainsKey($ipRef)) { [string]$syncHash.Status[$ipRef].status } else { "" }
                            $snmpLibLoaded = [bool]("Lextm.SharpSnmpLib.Messaging.Messenger" -as [type])
                            $failReason = ""

                            $snmpData = @{}
                            $success = $false

                            if (-not $snmpLibLoaded) {
                                $failReason = "SNMPライブラリ (SharpSnmpLib) が読み込まれていません。前提モジュール (SNMP) のインストール状態を確認してください。"
                            }
                            else {
                                try {
                                    # 注意: 変数名を $version にすると下のラッパー関数の引数 $Version と衝突し (PowerShellは大文字小文字を区別しない)、
                                    #       SNMPv3機器でも常に v2c で問い合わせてしまうため別名にする
                                    $snmpVer = if ($syncHash.SnmpVersion.ContainsKey($ipRef)) { $syncHash.SnmpVersion[$ipRef] } else { "v2c" }
                                    $user = if ($syncHash.SnmpUser.ContainsKey($ipRef)) { $syncHash.SnmpUser[$ipRef] } else { "" }
                                    $authProto = if ($syncHash.SnmpAuthProto.ContainsKey($ipRef)) { $syncHash.SnmpAuthProto[$ipRef] } else { "none" }
                                    $authPass = if ($syncHash.SnmpAuthPass.ContainsKey($ipRef)) { $syncHash.SnmpAuthPass[$ipRef] } else { "" }
                                    $privProto = if ($syncHash.SnmpPrivProto.ContainsKey($ipRef)) { $syncHash.SnmpPrivProto[$ipRef] } else { "none" }
                                    $privPass = if ($syncHash.SnmpPrivPass.ContainsKey($ipRef)) { $syncHash.SnmpPrivPass[$ipRef] } else { "" }

                                    # Scoped wrappers to route through our unified helpers
                                    function Invoke-SnmpGet {
                                        param([string]$IP, [string]$Community, [string]$OID, $Version, $TimeOut, $ErrorAction)
                                        Invoke-SnmpGetUnified -IP $IP -Community $Community -Version $snmpVer -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -Oids $OID -Timeout $TimeOut -ErrorAction $ErrorAction
                                    }
                                    function Invoke-SnmpWalk {
                                        param([string]$IP, [string]$Community, [string]$OID, $Version, $TimeOut, $ErrorAction)
                                        Invoke-SnmpWalkUnified -IP $IP -Community $Community -Version $snmpVer -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart $OID -Timeout $TimeOut -ErrorAction $ErrorAction
                                    }
                                    
                                    $sysName = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.1.5.0" -Version V2 -TimeOut 1000 -ErrorAction SilentlyContinue).Data
                                    $sysDescr = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.1.1.0" -Version V2 -TimeOut 1000 -ErrorAction SilentlyContinue).Data
                                    $sysUpTimeTicks = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.1.3.0" -Version V2 -TimeOut 1000 -ErrorAction SilentlyContinue).Data
                                    
                                    if ($sysDescr) {
                                        $success = $true
                                        
                                        $uptimeStr = ""
                                        if ($sysUpTimeTicks -and [int64]::TryParse($sysUpTimeTicks, [ref]$null)) {
                                            $ticks = [int64]$sysUpTimeTicks
                                            $totalSec = $ticks / 100
                                            $days = [math]::Floor($totalSec / 86400)
                                            $hours = [math]::Floor(($totalSec % 86400) / 3600)
                                            $mins = [math]::Floor(($totalSec % 3600) / 60)
                                            $uptimeStr = "$($days)d $($hours)h $($mins)m"
                                        }
                                        else {
                                            $uptimeStr = "Unknown"
                                        }
                                        
                                        # Interfaces Table
                                        $ifIndexes = Invoke-SnmpWalk -IP $ipRef -Community $community -OID "1.3.6.1.2.1.2.2.1.1" -Version V2 -TimeOut 1000 -ErrorAction SilentlyContinue
                                        $ifTable = @()
                                        foreach ($row in $ifIndexes) {
                                            $idx = $row.Data
                                            if ($idx) {
                                                $ifDesc = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.2.2.1.2.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $ifName = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.31.1.1.1.1.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $admin = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.2.2.1.7.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $oper = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.2.2.1.8.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $speed = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.2.2.1.5.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $highSpeed = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.31.1.1.1.15.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $inOctets = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.2.2.1.10.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $outOctets = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.2.2.1.16.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $inErrors = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.2.2.1.14.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $outErrors = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.2.2.1.20.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                
                                                $speedStr = ""
                                                if ($highSpeed -and $highSpeed -ne "Null" -and [int64]$highSpeed -gt 0) {
                                                    $speedStr = "$highSpeed Mbps"
                                                }
                                                elseif ($speed -and $speed -ne "Null" -and [int64]$speed -gt 0) {
                                                    $mb = [math]::Round([int64]$speed / 1000000)
                                                    $speedStr = "$mb Mbps"
                                                }
                                                
                                                $currentBw = "-"
                                                if ($syncHash.Traffic.ContainsKey($ipRef) -and $null -ne $syncHash.Traffic[$ipRef]) {
                                                    $currentBw = "Tx: $($syncHash.Traffic[$ipRef].tx) / Rx: $($syncHash.Traffic[$ipRef].rx) Mbps"
                                                }
                                                
                                                $ifTable += @{
                                                    index       = $idx
                                                    name        = if ($ifName -and $ifName -ne "Null") { $ifName } else { $ifDesc }
                                                    adminStatus = if ($admin -eq "1") { "up" } else { "down" }
                                                    operStatus  = if ($oper -eq "1") { "up" } else { "down" }
                                                    speed       = $speedStr
                                                    inOctets    = $inOctets
                                                    outOctets   = $outOctets
                                                    inErrors    = $inErrors
                                                    outErrors   = $outErrors
                                                    bandwidth   = $currentBw
                                                }
                                            }
                                        }
                                        
                                        # Routing Table
                                        $routeRows = Invoke-SnmpWalk -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.4.21.1.1" -Version V2 -TimeOut 1000 -ErrorAction SilentlyContinue
                                        $routingTable = @()
                                        foreach ($rRow in $routeRows) {
                                            $dest = $rRow.Data
                                            if ($dest -and $dest -ne "Null") {
                                                $nextHop = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.4.21.1.7.$dest" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $mask = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.4.21.1.11.$dest" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $ifIndex = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.4.21.1.2.$dest" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $type = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.4.21.1.8.$dest" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $proto = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.4.21.1.9.$dest" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                
                                                $typeStr = switch ($type) {
                                                    "1" { "other" }
                                                    "2" { "invalid" }
                                                    "3" { "direct" }
                                                    "4" { "indirect" }
                                                    default { "unknown" }
                                                }
                                                
                                                $protoStr = switch ($proto) {
                                                    "1" { "other" }
                                                    "2" { "local" }
                                                    "3" { "netmgmt" }
                                                    "4" { "icmp" }
                                                    "5" { "egp" }
                                                    "6" { "ggp" }
                                                    "7" { "hello" }
                                                    "8" { "rip" }
                                                    "9" { "is-is" }
                                                    "10" { "es-is" }
                                                    "11" { "ciscoIgrp" }
                                                    "12" { "bbnSpfIgp" }
                                                    "13" { "ospf" }
                                                    "14" { "bgp" }
                                                    default { "static" }
                                                }
                                                
                                                $routingTable += @{
                                                    destination = $dest
                                                    nextHop     = $nextHop
                                                    mask        = $mask
                                                    interface   = $ifIndex
                                                    type        = $typeStr
                                                    proto       = $protoStr
                                                }
                                            }
                                        }
                                        
                                        # ARP Table
                                        $arpRows = Invoke-SnmpWalk -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.4.22.1.3" -Version V2 -TimeOut 1000 -ErrorAction SilentlyContinue
                                        $arpTable = @()
                                        foreach ($aRow in $arpRows) {
                                            $netAddr = $aRow.Data
                                            if ($netAddr -and $netAddr -ne "Null") {
                                                $instance = $aRow.Oid -replace '^.*\.1\.3\.6\.1\.2\.1\.4\.22\.1\.3\.', ''
                                                if ($instance) {
                                                    $physAddr = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.4.22.1.2.$instance" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                    $ifIdx = $instance -replace '\..*$', ''
                                                    $arpTable += @{
                                                        interface  = $ifIdx
                                                        ipAddress  = $netAddr
                                                        macAddress = $physAddr
                                                    }
                                                }
                                            }
                                        }
                                        
                                        # TCP Connections
                                        $tcpRows = Invoke-SnmpWalk -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.6.13.1.1" -Version V2 -TimeOut 1000 -ErrorAction SilentlyContinue
                                        $tcpConnections = @()
                                        foreach ($tRow in $tcpRows) {
                                            $instance = $tRow.Oid -replace '^.*\.1\.3\.6\.1\.2\.1\.6\.13\.1\.1\.', ''
                                            if ($instance) {
                                                $parts = $instance -split '\.'
                                                if ($parts.Count -eq 10) {
                                                    $localIp = ($parts[0..3]) -join '.'
                                                    $localPort = $parts[4]
                                                    $remIp = ($parts[5..8]) -join '.'
                                                    $remPort = $parts[9]
                                                    
                                                    $stateVal = $tRow.Data
                                                    $stateStr = switch ($stateVal) {
                                                        "1" { "CLOSED" }
                                                        "2" { "LISTEN" }
                                                        "3" { "SYN_SENT" }
                                                        "4" { "SYN_RECEIVED" }
                                                        "5" { "ESTABLISHED" }
                                                        "6" { "FIN_WAIT_1" }
                                                        "7" { "FIN_WAIT_2" }
                                                        "8" { "CLOSE_WAIT" }
                                                        "9" { "LAST_ACK" }
                                                        "10" { "CLOSING" }
                                                        "11" { "TIME_WAIT" }
                                                        default { "UNKNOWN" }
                                                    }
                                                    
                                                    $tcpConnections += @{
                                                        localAddress  = "$($localIp):$($localPort)"
                                                        remoteAddress = "$($remIp):$($remPort)"
                                                        state         = $stateStr
                                                    }
                                                }
                                            }
                                        }
                                        
                                        # CPU Load
                                        $cpuLoad = $null
                                        $cpuLoads = Invoke-SnmpWalk -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.25.3.3.1.2" -Version V2 -TimeOut 1000 -ErrorAction SilentlyContinue
                                        if ($cpuLoads) {
                                            $totalCpu = 0
                                            $cnt = 0
                                            foreach ($c in $cpuLoads) {
                                                if ([int]::TryParse($c.Data, [ref]$null)) {
                                                    $totalCpu += [int]$c.Data
                                                    $cnt++
                                                }
                                            }
                                            if ($cnt -gt 0) {
                                                $cpuLoad = [math]::Round($totalCpu / $cnt)
                                            }
                                        }
                                        
                                        # Memory/Storage
                                        $ramUsed = $null; $ramTotal = $null
                                        $diskUsed = $null; $diskTotal = $null
                                        $storageIndexes = Invoke-SnmpWalk -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.25.2.3.1.1" -Version V2 -TimeOut 1000 -ErrorAction SilentlyContinue
                                        foreach ($sRow in $storageIndexes) {
                                            $sIdx = $sRow.Data
                                            if ($sIdx) {
                                                $sType = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.25.2.3.1.2.$sIdx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $sUnits = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.25.2.3.1.4.$sIdx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $sSize = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.25.2.3.1.5.$sIdx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $sUsed = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.25.2.3.1.6.$sIdx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                
                                                if ($sUnits -and $sSize -and [int64]::TryParse($sUnits, [ref]$null) -and [int64]::TryParse($sSize, [ref]$null)) {
                                                    $units = [int64]$sUnits
                                                    $sizeBytes = [int64]$sSize * $units
                                                    $usedBytes = [int64]$sUsed * $units
                                                    
                                                    if ($sType -like "*hrStorageRam*" -or $sType -eq ".1.3.6.1.2.1.25.2.1.2") {
                                                        $ramTotal = $sizeBytes
                                                        $ramUsed = $usedBytes
                                                    }
                                                    elseif ($sType -like "*hrStorageFixedDisk*" -or $sType -eq ".1.3.6.1.2.1.25.2.1.4") {
                                                        $diskTotal = $sizeBytes
                                                        $diskUsed = $usedBytes
                                                    }
                                                }
                                            }
                                        }
                                        
                                        # Vendor Details
                                        $vendor = @{}
                                        if ($devRef.image -eq "camera" -or $devRef.name -like "*カメラ*") {
                                            $vendor.type = "Camera"
                                            $vendor.resolution = "1920x1080"
                                            $vendor.fps = 30
                                            $vendor.temperature = "42.0 °C"
                                            $vendor.fanSpeed = "1600 RPM"
                                        }
                                        elseif ($devRef.image -eq "power" -or $devRef.name -like "*UPS*" -or $devRef.name -like "*電源*") {
                                            $vendor.type = "UPS"
                                            $vendor.batteryStatus = "88%"
                                            $vendor.voltage = "100.8 V"
                                            $vendor.load = "32.0 %"
                                        }
                                        elseif ($devRef.image -eq "switch" -or $devRef.image -eq "bridge" -or $devRef.name -like "*Switch*" -or $devRef.name -like "*SW*" -or $devRef.name -like "*BR*") {
                                            $vendor.type = "Switch"
                                            $vendor.fanStatus = "OK"
                                            $vendor.powerRedundancy = "Active / Redundant"
                                            $vendor.chassisTemp = "36.5 °C"
                                        }
                                        
                                        # Enhance interface data with errors/discards
                                        $ifErrors = if ($syncHash.InterfaceErrors.ContainsKey($ipRef)) { $syncHash.InterfaceErrors[$ipRef] } else { @{} }
                                        $enhancedInterfaces = foreach ($iface in $ifTable) {
                                            $idx = [string]$iface.index
                                            if ($ifErrors.ContainsKey($idx)) {
                                                $err = $ifErrors[$idx]
                                                $iface.inErrors = $err.inErr
                                                $iface.outErrors = $err.outErr
                                                $iface.inDiscards = $err.inDisc
                                                $iface.outDiscards = $err.outDisc
                                                $iface.deltaInErrors = $err.dInErr
                                                $iface.deltaOutErrors = $err.dOutErr
                                                $iface.deltaInDiscards = $err.dInDisc
                                                $iface.deltaOutDiscards = $err.dOutDisc
                                            }
                                            else {
                                                $iface.inErrors = 0; $iface.outErrors = 0
                                                $iface.inDiscards = 0; $iface.outDiscards = 0
                                                $iface.deltaInErrors = 0; $iface.deltaOutErrors = 0
                                                $iface.deltaInDiscards = 0; $iface.deltaOutDiscards = 0
                                            }
                                            $iface
                                        }

                                        $snmpData = @{
                                            sysName    = $sysName
                                            sysDescr   = $sysDescr
                                            sysUpTime  = $uptimeStr
                                            interfaces = $enhancedInterfaces
                                            routes     = $routingTable
                                            arp        = $arpTable
                                            tcp        = $tcpConnections
                                            cpu        = $cpuLoad
                                            ramUsed    = $ramUsed
                                            ramTotal   = $ramTotal
                                            diskUsed   = $diskUsed
                                            diskTotal  = $diskTotal
                                            vendor     = $vendor
                                        }
                                    }
                                }
                                catch {
                                    $success = $false
                                    $failReason = "SNMP取得中にエラーが発生しました: $($_.Exception.Message)"
                                }
                                if (-not $success -and -not $failReason) {
                                    $verLabel = if ($snmpVer -eq "v3") { "SNMPv3 (ユーザー名・認証/暗号化設定)" } else { "コミュニティ名 ($community)" }
                                    $failReason = "SNMP応答がありません。機器でSNMPが有効か、$verLabel が機器の設定と一致しているか、UDP 161番ポートが遮断されていないかを確認してください。"
                                    if ($pingStatus -in @("Failed", "Error", "Offline")) {
                                        $failReason += " (現在Ping応答もありません)"
                                    }
                                }
                            }

                            if (-not $success) {
                                # SNMP failed or timed out: Return minimal info (no mock data)
                                $snmpData = @{
                                    snmpError  = $failReason
                                    sysName    = $devRef.name
                                    sysDescr   = "N/A (SNMP Response Timeout)"
                                    sysUpTime  = "N/A"
                                    interfaces = @()
                                    routes     = @()
                                    arp        = @()
                                    tcp        = @()
                                    cpu        = $null
                                    ramUsed    = $null
                                    ramTotal   = $null
                                    diskUsed   = $null
                                    diskTotal  = $null
                                    vendor     = @{}
                                }
                            }
                            
                            Write-JsonResponse $respRef $snmpData
                        }
                        catch {
                            Write-JsonResponse $respRef @{ error = "SNMP details error: $($_.Exception.Message)" } 500
                        }
                    }
                    continue
                }
                elseif ($urlPath -eq "/api/test-results" -and $method -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $jsonBody = $reader.ReadToEnd()
                    $testResultsPath = Join-Path $syncHash.PSScriptRoot "test_results.json"
                    $jsonBody | Out-File -FilePath $testResultsPath -Encoding UTF8 -NoNewline:$false
                    Write-Host "Test results received and written to test_results.json" -ForegroundColor Green
                    Write-JsonResponse $response @{ status = "success" }
                }
                elseif ($urlPath -eq "/api/device/edit" -and $method -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $jsonBody = $reader.ReadToEnd()
                    $payload = $jsonBody | ConvertFrom-Json

                    if ($payload.oldIp -and $payload.newIp) {
                        $oldIp = $payload.oldIp.Trim()
                        $newIp = $payload.newIp.Trim()
                        
                        $ipRegex = '^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
                        if ($oldIp -notmatch $ipRegex -or $newIp -notmatch $ipRegex) {
                            Write-JsonResponse $response @{ error = "Invalid IP Address format" } 400
                            continue
                        }
                        # 変更先のIPを別の機器が既に使っている場合は拒否する
                        # (以前はそのまま進み、相手機器の設定を上書きした上で編集中の機器のデータも消していた)
                        if ($oldIp -ne $newIp -and ($syncHash.Devices -contains $newIp)) {
                            Write-JsonResponse $response @{ error = "IP address $newIp is already used by another device" } 409
                            continue
                        }

                        $comm = if ($payload.community) { $payload.community.Trim() } else { "public" }
                        $name = if ($payload.name) { $payload.name.Trim() } else { $newIp }
                        $group = if ($null -ne $payload.group) { $payload.group.Trim() } else { "" }
                        $enabled = if ($null -ne $payload.enabled) { [bool]$payload.enabled } else { $true }
                        $image = if ($payload.image) { $payload.image.Trim() } else { "" }
                        $connectedTo = if ($payload.connectedTo) { $payload.connectedTo.Trim() } else { "" }

                        # 送信されなかった項目は既存値を維持する
                        # (構成図のリンク追加・削除などは一部の項目だけを送るため、既定値で上書きすると
                        #  SNMPv3認証情報・保守連絡先等が消えてしまう)
                        $hasField = { param($n) $null -ne $payload.PSObject.Properties[$n] }
                        $prevValue = { param($table, $default) if ($null -ne $table -and $table.ContainsKey($oldIp)) { $table[$oldIp] } else { $default } }

                        # SNMPv3 parameters
                        $snmpVersion = if (& $hasField 'snmpVersion') { if ($payload.snmpVersion) { $payload.snmpVersion.Trim() } else { "v2c" } } else { & $prevValue $syncHash.SnmpVersion "v2c" }
                        $snmpUser = if (& $hasField 'snmpUser') { if ($payload.snmpUser) { $payload.snmpUser.Trim() } else { "" } } else { & $prevValue $syncHash.SnmpUser "" }
                        $snmpAuthProto = if (& $hasField 'snmpAuthProto') { if ($payload.snmpAuthProto) { $payload.snmpAuthProto.Trim() } else { "none" } } else { & $prevValue $syncHash.SnmpAuthProto "none" }
                        $snmpAuthPass = if (& $hasField 'snmpAuthPass') { if ($payload.snmpAuthPass) { Unprotect-SecretString ([string]$payload.snmpAuthPass) } else { "" } } else { & $prevValue $syncHash.SnmpAuthPass "" }
                        $snmpPrivProto = if (& $hasField 'snmpPrivProto') { if ($payload.snmpPrivProto) { $payload.snmpPrivProto.Trim() } else { "none" } } else { & $prevValue $syncHash.SnmpPrivProto "none" }
                        $snmpPrivPass = if (& $hasField 'snmpPrivPass') { if ($payload.snmpPrivPass) { Unprotect-SecretString ([string]$payload.snmpPrivPass) } else { "" } } else { & $prevValue $syncHash.SnmpPrivPass "" }
                        $obrEnabledVal = if (& $hasField 'obrEnabled') { [bool]$payload.obrEnabled } else { [bool](& $prevValue $syncHash.ObrEnabled $false) }
                        $obrPasswordVal = if (& $hasField 'obrPassword') { if ($payload.obrPassword) { Protect-SecretString ([string]$payload.obrPassword) } else { "" } } else { & $prevValue $syncHash.ObrPassword "" }
                        $vendorContactVal = if (& $hasField 'vendorContact') { [string]$payload.vendorContact } else { & $prevValue $syncHash.VendorContact "" }
                        $deviceTypeVal = if (& $hasField 'deviceType') { [string]$payload.deviceType } else { & $prevValue $syncHash.DeviceType "network" }
                        $webUrlVal = if (& $hasField 'webUrl') { [string]$payload.webUrl } else { & $prevValue $syncHash.WebUrl "" }
                        # 監視方式 (ICMP / TCP) とポート: 以前は編集APIで反映されず、画面で変更しても保存されなかった
                        $checkTypeVal = if (& $hasField 'checkType') { if ($payload.checkType) { [string]$payload.checkType } else { "icmp" } } else { & $prevValue $syncHash.CheckType "icmp" }
                        $portVal = if (& $hasField 'port') { [int]$payload.port } else { [int](& $prevValue $syncHash.Port 0) }

                        [System.Threading.Monitor]::Enter($syncHash.DevicesLock)
                        try {
                            $oldGroup = if ($syncHash.Group.ContainsKey($oldIp)) { $syncHash.Group[$oldIp] } else { "" }

                            if ($oldIp -ne $newIp) {
                                if (-not ($syncHash.Devices -contains $newIp)) {
                                    $newArr = [System.Collections.Generic.List[string]]::new()
                                    foreach ($d in $syncHash.Devices) {
                                        if ($d -eq $oldIp) { $newArr.Add($newIp) }
                                        else { $newArr.Add($d) }
                                    }
                                    $syncHash.Devices = $newArr.ToArray()
                                    
                                    # Rename CSV file and rotated files if they exist
                                    $oldSafeIp = $oldIp -replace '[\\/:*?"<>|]', '_'
                                    $newSafeIp = $newIp -replace '[\\/:*?"<>|]', '_'
                                    $oldCsvPath = Join-Path $syncHash.SessionDir "${oldSafeIp}.csv"
                                    $newCsvPath = Join-Path $syncHash.SessionDir "${newSafeIp}.csv"
                                    if (Test-Path $oldCsvPath) {
                                        Rename-Item -Path $oldCsvPath -NewName "${newSafeIp}.csv" -Force
                                    }
                                    # Also rename any rotated files
                                    Get-ChildItem -Path $syncHash.SessionDir -Filter "${oldSafeIp}_*.csv" -ErrorAction SilentlyContinue | ForEach-Object {
                                        $renamed = $_.Name -replace "^$([regex]::Escape($oldSafeIp))_", "${newSafeIp}_"
                                        Rename-Item -Path $_.FullName -NewName $renamed -Force
                                    }
                                    
                                    if ($syncHash.History.ContainsKey($oldIp)) {
                                        $syncHash.History[$newIp] = $syncHash.History[$oldIp]
                                        $syncHash.History.Remove($oldIp)
                                    }
                                    else {
                                        $syncHash.History[$newIp] = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
                                    }

                                    if ($syncHash.Stats.ContainsKey($oldIp)) {
                                        $syncHash.Stats[$newIp] = $syncHash.Stats[$oldIp]
                                        $syncHash.Stats.Remove($oldIp)
                                    }
                                    else {
                                        $syncHash.Stats[$newIp] = [hashtable]::Synchronized(@{
                                                Total    = 0
                                                Success  = 0
                                                MinLat   = [double]::MaxValue
                                                MaxLat   = 0.0
                                                SumLat   = 0.0
                                                LatCount = 0
                                            })
                                    }

                                    if ($syncHash.Status.ContainsKey($oldIp)) { $syncHash.Status.Remove($oldIp) }
                                    if ($syncHash.Traffic.ContainsKey($oldIp)) { $syncHash.Traffic.Remove($oldIp) }
                                    
                                    if ($syncHash.Community.ContainsKey($oldIp)) { $syncHash.Community.Remove($oldIp) }
                                    if ($syncHash.DeviceName.ContainsKey($oldIp)) { $syncHash.DeviceName.Remove($oldIp) }
                                    if ($syncHash.Group.ContainsKey($oldIp)) { $syncHash.Group.Remove($oldIp) }
                                    if ($syncHash.IsMonitored.ContainsKey($oldIp)) { $syncHash.IsMonitored.Remove($oldIp) }
                                    if ($syncHash.Image.ContainsKey($oldIp)) { $syncHash.Image.Remove($oldIp) }
                                    if ($syncHash.ConnectedTo.ContainsKey($oldIp)) { $syncHash.ConnectedTo.Remove($oldIp) }
                                    
                                    if ($syncHash.SnmpVersion.ContainsKey($oldIp)) { $syncHash.SnmpVersion.Remove($oldIp) }
                                    if ($syncHash.SnmpUser.ContainsKey($oldIp)) { $syncHash.SnmpUser.Remove($oldIp) }
                                    if ($syncHash.SnmpAuthProto.ContainsKey($oldIp)) { $syncHash.SnmpAuthProto.Remove($oldIp) }
                                    if ($syncHash.SnmpAuthPass.ContainsKey($oldIp)) { $syncHash.SnmpAuthPass.Remove($oldIp) }
                                    if ($syncHash.SnmpPrivProto.ContainsKey($oldIp)) { $syncHash.SnmpPrivProto.Remove($oldIp) }
                                    if ($syncHash.SnmpPrivPass.ContainsKey($oldIp)) { $syncHash.SnmpPrivPass.Remove($oldIp) }
                                    foreach ($obrTable in @($syncHash.ObrEnabled, $syncHash.ObrPassword, $syncHash.ObrStatus)) { if ($obrTable.ContainsKey($oldIp)) { $obrTable.Remove($oldIp) } }

                                    if ($syncHash.X.ContainsKey($oldIp)) {
                                        $syncHash.X[$newIp] = $syncHash.X[$oldIp]
                                        $syncHash.X.Remove($oldIp)
                                    }
                                    if ($syncHash.Y.ContainsKey($oldIp)) {
                                        $syncHash.Y[$newIp] = $syncHash.Y[$oldIp]
                                        $syncHash.Y.Remove($oldIp)
                                    }

                                    if ($syncHash.Remote -and $syncHash.Remote.ContainsKey($oldIp)) {
                                        $oldRemote = $syncHash.Remote[$oldIp]
                                        $syncHash.Remote.Remove($oldIp)
                                        $syncHash.Remote[$newIp] = $oldRemote
                                    }
                                }
                            }

                            if ($oldGroup -ne $group) {
                                $syncHash.X[$newIp] = $null
                                $syncHash.Y[$newIp] = $null
                            }

                            $syncHash.Community[$newIp] = $comm
                            $syncHash.DeviceName[$newIp] = $name
                            $syncHash.Group[$newIp] = $group
                            $syncHash.IsMonitored[$newIp] = $enabled
                            $syncHash.Image[$newIp] = $image
                            $syncHash.ConnectedTo[$newIp] = $connectedTo

                            $syncHash.SnmpVersion[$newIp] = $snmpVersion
                            $syncHash.SnmpUser[$newIp] = $snmpUser
                            $syncHash.SnmpAuthProto[$newIp] = $snmpAuthProto
                            $syncHash.SnmpAuthPass[$newIp] = $snmpAuthPass
                            $syncHash.SnmpPrivProto[$newIp] = $snmpPrivProto
                            $syncHash.SnmpPrivPass[$newIp] = $snmpPrivPass
                            $syncHash.ObrEnabled[$newIp] = $obrEnabledVal
                            $syncHash.ObrPassword[$newIp] = $obrPasswordVal

                            $syncHash.VendorContact[$newIp] = $vendorContactVal
                            $syncHash.DeviceType[$newIp] = $deviceTypeVal
                            $syncHash.WebUrl[$newIp] = $webUrlVal
                            $syncHash.CheckType[$newIp] = $checkTypeVal
                            $syncHash.Port[$newIp] = $portVal

                            # Update Remote configuration
                            if ($null -ne $payload.remote) {
                                $rHash = @{}
                                if ($payload.remote -is [System.Collections.IDictionary]) {
                                    foreach ($k in $payload.remote.Keys) { $rHash[$k] = $payload.remote[$k] }
                                }
                                elseif ($null -ne $payload.remote.PSObject) {
                                    foreach ($prop in $payload.remote.PSObject.Properties) { $rHash[$prop.Name] = $prop.Value }
                                }
                                
                                $newPass = if ($rHash.ContainsKey('password')) { [string]$rHash['password'] } else { "" }
                                if (-not [string]::IsNullOrWhiteSpace($newPass)) {
                                    $rHash['password'] = Protect-SecretString $newPass
                                }
                                elseif ($syncHash.Remote -and $syncHash.Remote.ContainsKey($newIp) -and $null -ne $syncHash.Remote[$newIp]) {
                                    # Retain existing password if blank in edit payload
                                    $prevRemote = $syncHash.Remote[$newIp]
                                    $prevPass = if ($prevRemote -is [System.Collections.IDictionary]) { if ($prevRemote.ContainsKey('password')) { $prevRemote['password'] } else { "" } } elseif ($null -ne $prevRemote.PSObject -and $null -ne $prevRemote.PSObject.Properties['password']) { $prevRemote.password } else { "" }
                                    if (-not [string]::IsNullOrWhiteSpace($prevPass)) {
                                        $rHash['password'] = $prevPass
                                    }
                                }
                                if (-not $syncHash.Remote) {
                                    $syncHash.Remote = [hashtable]::Synchronized(@{})
                                }
                                $syncHash.Remote[$newIp] = $rHash
                            }

                            if ($oldIp -ne $newIp) {
                                if ($syncHash.VendorContact.ContainsKey($oldIp)) { $syncHash.VendorContact.Remove($oldIp) }
                                if ($syncHash.DeviceType.ContainsKey($oldIp)) { $syncHash.DeviceType.Remove($oldIp) }
                                if ($syncHash.WebUrl.ContainsKey($oldIp)) { $syncHash.WebUrl.Remove($oldIp) }
                                if ($syncHash.CheckType.ContainsKey($oldIp)) { $syncHash.CheckType.Remove($oldIp) }
                                if ($syncHash.Port.ContainsKey($oldIp)) { $syncHash.Port.Remove($oldIp) }

                                # 他の機器の接続先 (connectedTo) に旧IPが残っていると構成図のリンクが消えるため新IPへ付け替える
                                foreach ($ctKey in @($syncHash.ConnectedTo.Keys)) {
                                    $ctVal = [string]$syncHash.ConnectedTo[$ctKey]
                                    if ([string]::IsNullOrWhiteSpace($ctVal)) { continue }
                                    $parts = @($ctVal -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
                                    if ($parts -contains $oldIp) {
                                        $syncHash.ConnectedTo[$ctKey] = (@($parts | ForEach-Object { if ($_ -eq $oldIp) { $newIp } else { $_ } } | Select-Object -Unique) -join ',')
                                    }
                                }
                            }

                            if ($enabled) {
                                Initialize-DeviceLog -ip $newIp
                            }

                            Save-DevicesJson
                        }
                        finally {
                            [System.Threading.Monitor]::Exit($syncHash.DevicesLock)
                        }
                        Log-Audit -action "DEVICE_EDIT" -target $newIp -details "Device $name ($newIp) updated (was $oldIp)" -clientIp $request.RemoteEndPoint.Address.ToString() -reportsDirectory $ReportsDir
                        Write-JsonResponse $response @{ status = "success" }
                    }
                    else {
                        Write-JsonResponse $response @{ error = "Missing oldIp or newIp" } 400
                    }
                }
                elseif ($urlPath -eq "/api/devices/reorder" -and $method -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $jsonBody = $reader.ReadToEnd()
                    $payload = $jsonBody | ConvertFrom-Json

                    if ($null -ne $payload) {
                        [System.Threading.Monitor]::Enter($syncHash.DevicesLock)
                        try {
                            $newArr = [System.Collections.Generic.List[string]]::new()
                            foreach ($item in $payload) {
                                if ($item.ip) {
                                    $ipStr = [string]$item.ip
                                    $newArr.Add($ipStr)
                                    if ($syncHash.Devices -contains $ipStr) {
                                        $grpVal = if ($null -ne $item.group) { $item.group.Trim() } else { "" }
                                        if ($syncHash.Group.ContainsKey($ipStr) -and $syncHash.Group[$ipStr] -ne $grpVal) {
                                            $syncHash.X[$ipStr] = $null
                                            $syncHash.Y[$ipStr] = $null
                                        }
                                        $syncHash.Group[$ipStr] = $grpVal
                                    }
                                }
                            }
                            
                            $validArr = [System.Collections.Generic.List[string]]::new()
                            foreach ($ip in $newArr) {
                                if ($syncHash.Devices -contains $ip) { $validArr.Add($ip) }
                            }
                            
                            foreach ($ip in $syncHash.Devices) {
                                if (-not $validArr.Contains($ip)) { $validArr.Add($ip) }
                            }

                            $syncHash.Devices = $validArr.ToArray()
                            Save-DevicesJson
                        }
                        finally {
                            [System.Threading.Monitor]::Exit($syncHash.DevicesLock)
                        }
                        Write-JsonResponse $response @{ status = "success" }
                    }
                    else {
                        Write-JsonResponse $response @{ error = "Invalid payload" } 400
                    }
                }
                elseif ($urlPath -eq "/api/devices/positions" -and $method -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $jsonBody = $reader.ReadToEnd()
                    $payload = $jsonBody | ConvertFrom-Json

                    if ($null -ne $payload) {
                        [System.Threading.Monitor]::Enter($syncHash.DevicesLock)
                        try {
                            foreach ($item in $payload) {
                                $ip = $item.ip
                                if ($ip) {
                                    $syncHash.X[$ip] = $item.x
                                    $syncHash.Y[$ip] = $item.y
                                }
                            }
                            Save-DevicesJson -Routine
                        }
                        finally {
                            [System.Threading.Monitor]::Exit($syncHash.DevicesLock)
                        }
                        Write-JsonResponse $response @{ status = "success" }
                    }
                    else {
                        Write-JsonResponse $response @{ error = "Invalid payload" } 400
                    }
                }
                elseif ($urlPath -eq "/api/device/toggle" -and $method -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $jsonBody = $reader.ReadToEnd()
                    $payload = $jsonBody | ConvertFrom-Json

                    if ($payload.ip) {
                        $ipToToggle = $payload.ip.Trim()
                        if ($syncHash.Devices -contains $ipToToggle) {
                            $current = if ($syncHash.IsMonitored.ContainsKey($ipToToggle)) { $syncHash.IsMonitored[$ipToToggle] } else { $true }
                            $newEnabled = -not $current
                            $syncHash.IsMonitored[$ipToToggle] = $newEnabled
                            if ($newEnabled) {
                                Initialize-DeviceLog -ip $ipToToggle
                            }
                            Save-DevicesJson
                            
                            Write-JsonResponse $response @{ status = "success"; enabled = $newEnabled }
                        }
                        else {
                            Write-JsonResponse $response @{ error = "Device not found" } 404
                        }
                    }
                    else {
                        Write-JsonResponse $response @{ error = "Missing ip" } 400
                    }
                }
                elseif ($urlPath -eq "/api/devices/import" -and $method -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $jsonBody = $reader.ReadToEnd()
                    $payload = $jsonBody | ConvertFrom-Json

                    if ($null -ne $payload) {
                        $ipRegex = '^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
                        
                        $validPayload = @()
                        foreach ($item in $payload) {
                            if ($item.ip) {
                                $ip = $item.ip.Trim()
                                if ($ip -match $ipRegex) {
                                    $validPayload += $item
                                }
                            }
                        }

                        if ($validPayload.Count -gt 0) {
                            [System.Threading.Monitor]::Enter($syncHash.DevicesLock)
                            try {
                                $syncHash.Devices = @()
                                $syncHash.Community.Clear()
                                $syncHash.DeviceName.Clear()
                                $syncHash.IsMonitored.Clear()
                                $syncHash.Group.Clear()
                                $syncHash.Image.Clear()
                                $syncHash.ConnectedTo.Clear()
                                $syncHash.X.Clear()
                                $syncHash.Y.Clear()
                                $syncHash.Mac.Clear()
                                $syncHash.SnmpVersion.Clear()
                                $syncHash.SnmpUser.Clear()
                                $syncHash.SnmpAuthProto.Clear()
                                $syncHash.SnmpAuthPass.Clear()
                                $syncHash.SnmpPrivProto.Clear()
                                $syncHash.SnmpPrivPass.Clear()
                                $syncHash.ObrEnabled.Clear(); $syncHash.ObrPassword.Clear(); $syncHash.ObrStatus.Clear()
                                if ($syncHash.Remote) { $syncHash.Remote.Clear() }
                                $syncHash.Status.Clear()
                                $syncHash.Traffic.Clear()
                                $syncHash.SnmpDetail.Clear()
                                $syncHash.History.Clear()

                                $newArr = [System.Collections.Generic.List[string]]::new()
                                foreach ($item in $validPayload) {
                                    # 同じIPが複数行あると、同じ機器が二重に監視・表示されるため最初の1件だけ使う
                                    if ($newArr.Contains(([string]$item.ip).Trim())) { continue }
                                    # 起動時と同じ全項目を読み込む (以前は監視方式・ポート・保守連絡先等が読み込まれず消えていた)
                                    $ip = Set-DeviceRecordInSyncHash $item
                                    if (-not $ip) { continue }
                                    $newArr.Add($ip)
                                    # 平文で渡されたリモート接続パスワードは保存前に暗号化
                                    if ($syncHash.Remote.ContainsKey($ip)) {
                                        $rHash = $syncHash.Remote[$ip]
                                        if ($rHash.ContainsKey('password') -and -not [string]::IsNullOrWhiteSpace($rHash['password'])) {
                                            $rHash['password'] = Protect-SecretString ([string]$rHash['password'])
                                        }
                                    }
                                    if ($syncHash.IsMonitored[$ip]) {
                                        Initialize-DeviceLog -ip $ip
                                    }
                                }
                                $syncHash.Devices = $newArr.ToArray()
                            }
                            finally {
                                [System.Threading.Monitor]::Exit($syncHash.DevicesLock)
                            }
                            
                            Save-DevicesJson
                            # 重複を除いた、実際に取り込んだ台数を返す
                            Write-JsonResponse $response @{ status = "success"; count = @($syncHash.Devices).Count }
                        }
                        else {
                            Write-JsonResponse $response @{ error = "No valid devices found in payload" } 400
                        }
                    }
                    else {
                        Write-JsonResponse $response @{ error = "Invalid payload" } 400
                    }
                }
                elseif ($urlPath -eq "/api/devices/bulk-action" -and $method -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $jsonBody = $reader.ReadToEnd()
                    $payload = $jsonBody | ConvertFrom-Json

                    if ($payload.ips -and $payload.action) {
                        $action = $payload.action.Trim().ToLower()
                        $ips = @($payload.ips)
                        
                        [System.Threading.Monitor]::Enter($syncHash.DevicesLock)
                        try {
                            if ($action -eq "pause" -or $action -eq "disable") {
                                foreach ($ip in $ips) {
                                    if ($syncHash.Devices -contains $ip) {
                                        $syncHash.IsMonitored[$ip] = $false
                                    }
                                }
                            }
                            elseif ($action -eq "resume" -or $action -eq "enable") {
                                foreach ($ip in $ips) {
                                    if ($syncHash.Devices -contains $ip) {
                                        $syncHash.IsMonitored[$ip] = $true
                                        Initialize-DeviceLog -ip $ip
                                    }
                                }
                            }
                            elseif ($action -eq "delete") {
                                $newArr = [System.Collections.Generic.List[string]]::new()
                                foreach ($d in $syncHash.Devices) {
                                    if (-not $ips.Contains($d)) {
                                        $newArr.Add($d)
                                    }
                                    else {
                                        if ($syncHash.Community.ContainsKey($d)) { $syncHash.Community.Remove($d) }
                                        if ($syncHash.DeviceName.ContainsKey($d)) { $syncHash.DeviceName.Remove($d) }
                                        if ($syncHash.IsMonitored.ContainsKey($d)) { $syncHash.IsMonitored.Remove($d) }
                                        if ($syncHash.Group.ContainsKey($d)) { $syncHash.Group.Remove($d) }
                                        if ($syncHash.Image.ContainsKey($d)) { $syncHash.Image.Remove($d) }
                                        if ($syncHash.ConnectedTo.ContainsKey($d)) { $syncHash.ConnectedTo.Remove($d) }
                                        if ($syncHash.History.ContainsKey($d)) { $syncHash.History.Remove($d) }
                                        if ($syncHash.X.ContainsKey($d)) { $syncHash.X.Remove($d) }
                                        if ($syncHash.Y.ContainsKey($d)) { $syncHash.Y.Remove($d) }
                                        if ($syncHash.Mac.ContainsKey($d)) { $syncHash.Mac.Remove($d) }
                                        if ($syncHash.SnmpVersion.ContainsKey($d)) { $syncHash.SnmpVersion.Remove($d) }
                                        if ($syncHash.SnmpUser.ContainsKey($d)) { $syncHash.SnmpUser.Remove($d) }
                                        if ($syncHash.SnmpAuthProto.ContainsKey($d)) { $syncHash.SnmpAuthProto.Remove($d) }
                                        if ($syncHash.SnmpAuthPass.ContainsKey($d)) { $syncHash.SnmpAuthPass.Remove($d) }
                                        if ($syncHash.SnmpPrivProto.ContainsKey($d)) { $syncHash.SnmpPrivProto.Remove($d) }
                                        if ($syncHash.SnmpPrivPass.ContainsKey($d)) { $syncHash.SnmpPrivPass.Remove($d) }
                                        foreach ($obrTable in @($syncHash.ObrEnabled, $syncHash.ObrPassword, $syncHash.ObrStatus)) { if ($obrTable.ContainsKey($d)) { $obrTable.Remove($d) } }
                                        if ($syncHash.Remote -and $syncHash.Remote.ContainsKey($d)) { $syncHash.Remote.Remove($d) }
                                    }
                                }
                                $syncHash.Devices = $newArr.ToArray()

                                # 残った機器の接続先から、一括削除した機器を外す (単体削除と同じ扱い)
                                foreach ($ctKey in @($syncHash.ConnectedTo.Keys)) {
                                    $ctVal = [string]$syncHash.ConnectedTo[$ctKey]
                                    if ([string]::IsNullOrWhiteSpace($ctVal)) { continue }
                                    $parts = @($ctVal -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
                                    $kept = @($parts | Where-Object { -not $ips.Contains($_) })
                                    if ($kept.Count -ne $parts.Count) {
                                        $syncHash.ConnectedTo[$ctKey] = ($kept -join ',')
                                    }
                                }
                            }
                            elseif ($action -eq "change-group") {
                                $newGroup = if ($null -ne $payload.group) { $payload.group.Trim() } else { "" }
                                foreach ($ip in $ips) {
                                    if ($syncHash.Devices -contains $ip) {
                                        if ($syncHash.Group[$ip] -ne $newGroup) {
                                            $syncHash.X[$ip] = $null
                                            $syncHash.Y[$ip] = $null
                                        }
                                        $syncHash.Group[$ip] = $newGroup
                                    }
                                }
                            }
                        }
                        finally {
                            [System.Threading.Monitor]::Exit($syncHash.DevicesLock)
                        }
                        
                        Save-DevicesJson
                        Write-JsonResponse $response @{ status = "success" }
                    }
                    else {
                        Write-JsonResponse $response @{ error = "Missing ips or action" } 400
                    }
                }
                elseif ($urlPath -eq "/api/config" -and $method -eq "GET") {
                    Write-JsonResponse $response @{ 
                        pollInterval             = $syncHash.PollInterval
                        pingDataSize             = $syncHash.PingDataSize
                        loggingEnabled           = $syncHash.LoggingEnabled
                        highFreqTargetIps        = $syncHash.HighFreqTargetIps
                        outageThresh1Ms          = $syncHash.OutageThresh1Ms
                        outageThresh2Ms          = $syncHash.OutageThresh2Ms
                        latencyThreshMs          = $syncHash.LatencyThreshMs
                        latencyWarningMs         = $syncHash.LatencyWarningMs
                        consecutiveFailThresh    = $syncHash.ConsecutiveFailThresh
                        lossWarningThreshPercent = $syncHash.LossWarningThreshPercent
                        jitterWarningThreshMs    = $syncHash.JitterWarningThreshMs
                        logRetentionDays         = $syncHash.LogRetentionDays
                        webhookUrl               = $syncHash.WebhookUrl
                        webhookEnabled           = $syncHash.WebhookEnabled
                        webhookOfflineOnly       = $syncHash.WebhookOfflineOnly
                        soundEnabled             = $syncHash.SoundEnabled
                        soundVolume              = $syncHash.SoundVolume
                        emailEnabled             = $syncHash.EmailEnabled
                        smtpHost                 = $syncHash.SmtpHost
                        smtpPort                 = $syncHash.SmtpPort
                        smtpSsl                  = $syncHash.SmtpSsl
                        smtpUser                 = $syncHash.SmtpUser
                        smtpPass                 = if ($syncHash.SmtpPass) { "********" } else { "" }
                        smtpFrom                 = $syncHash.SmtpFrom
                        smtpTo                   = $syncHash.SmtpTo
                        syslogEnabled            = $syncHash.SyslogEnabled
                        syslogPort               = $syncHash.SyslogPort
                        trapPort                 = $syncHash.TrapPort
                        sslWarnDays              = $syncHash.SslWarnDays
                        uiMode                   = $syncHash.UiMode
                        bwThreshMbps             = $syncHash.BwThreshMbps
                        enableParentSuppression  = $syncHash.EnableParentSuppression
                    }
                }
                elseif ($urlPath -eq "/api/config" -and $method -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $jsonBody = $reader.ReadToEnd()
                    $payload = $jsonBody | ConvertFrom-Json

                    if ($null -ne $payload.pollInterval) {
                        # マイナスは「監視一時停止」の意味なのでそのまま。0.1秒未満・1時間超は範囲内に丸める
                        $v = [int]$payload.pollInterval
                        if ($v -gt 0) { $v = [math]::Min(3600000, [math]::Max(100, $v)) }
                        $syncHash.PollInterval = $v
                    }
                    if ($null -ne $payload.pingDataSize) {
                        # Ping で送れるデータは最大 65,500 バイト。超えると全機器の Ping が失敗し「全台オフライン」になる
                        $syncHash.PingDataSize = [math]::Min(65500, [math]::Max(0, [int]$payload.pingDataSize))
                    }
                    if ($null -ne $payload.loggingEnabled) {
                        $syncHash.LoggingEnabled = [bool]$payload.loggingEnabled
                    }
                    if ($null -ne $payload.highFreqTargetIps) {
                        $rawIps = [string]$payload.highFreqTargetIps
                        $safeIps = ($rawIps -split ',' | ForEach-Object {
                                $trimmed = $_.Trim()
                                if ($trimmed -match '^\d{1,3}(\.\d{1,3}){3}$') { $trimmed } else { $null }
                            } | Where-Object { $_ } | Select-Object -First 2) -join ','
                        $syncHash.HighFreqTargetIps = $safeIps
                    }
                    if ($null -ne $payload.outageThresh1Ms) {
                        $v = [int]$payload.outageThresh1Ms
                        if ($v -ge 100 -and $v -le 60000) { $syncHash.OutageThresh1Ms = $v }
                    }
                    if ($null -ne $payload.outageThresh2Ms) {
                        $v = [int]$payload.outageThresh2Ms
                        if ($v -ge 100 -and $v -le 600000) { $syncHash.OutageThresh2Ms = $v }
                    }
                    if ($null -ne $payload.latencyThreshMs) {
                        $v = [int]$payload.latencyThreshMs
                        if ($v -ge 1 -and $v -le 10000) { $syncHash.LatencyThreshMs = $v }
                    }
                    if ($null -ne $payload.latencyWarningMs) {
                        $v = [int]$payload.latencyWarningMs
                        if ($v -ge 1 -and $v -le 10000) { $syncHash.LatencyWarningMs = $v }
                    }
                    if ($null -ne $payload.consecutiveFailThresh) {
                        $v = [int]$payload.consecutiveFailThresh
                        if ($v -ge 1 -and $v -le 20) { $syncHash.ConsecutiveFailThresh = $v }
                    }
                    if ($null -ne $payload.lossWarningThreshPercent) {
                        $v = [double]$payload.lossWarningThreshPercent
                        if ($v -ge 0.1 -and $v -le 100.0) { $syncHash.LossWarningThreshPercent = $v }
                    }
                    if ($null -ne $payload.jitterWarningThreshMs) {
                        $v = [double]$payload.jitterWarningThreshMs
                        if ($v -ge 0.1 -and $v -le 1000.0) { $syncHash.JitterWarningThreshMs = $v }
                    }
                    if ($null -ne $payload.logRetentionDays) {
                        $v = [int]$payload.logRetentionDays
                        if ($v -ge 0 -and $v -le 365) {
                            $retentionChanged = ($syncHash.LogRetentionDays -ne $v)
                            $syncHash.LogRetentionDays = $v
                            # 古いレポートの削除はフォルダ全体を調べるので時間がかかる。設定を保存するたび (画面の操作ごと) に
                            # 実行すると画面全体が止まるため、保存期間が変わったときだけ実行する (普段の削除は 6 時間ごとの定期メンテナンスで行う)
                            if ($v -gt 0 -and $retentionChanged) {
                                try { Invoke-PurgeOldReports -reportsDirectory $ReportsDir -retentionDays $v -activeSessionDir $syncHash.SessionDir | Out-Null } catch {}
                            }
                        }
                    }
                    if ($null -ne $payload.webhookUrl) {
                        $syncHash.WebhookUrl = [string]$payload.webhookUrl
                    }
                    if ($null -ne $payload.webhookEnabled) {
                        $syncHash.WebhookEnabled = [bool]$payload.webhookEnabled
                    }
                    if ($null -ne $payload.webhookOfflineOnly) {
                        $syncHash.WebhookOfflineOnly = [bool]$payload.webhookOfflineOnly
                    }
                    if ($null -ne $payload.soundEnabled) {
                        $syncHash.SoundEnabled = [bool]$payload.soundEnabled
                    }
                    if ($null -ne $payload.soundVolume) {
                        $syncHash.SoundVolume = [math]::Min(1.0, [math]::Max(0.0, [double]$payload.soundVolume))
                    }

                    if ($null -ne $payload.emailEnabled) { $syncHash.EmailEnabled = [bool]$payload.emailEnabled }
                    if ($null -ne $payload.smtpHost) { $syncHash.SmtpHost = [string]$payload.smtpHost }
                    if ($null -ne $payload.smtpPort) {
                        $v = [int]$payload.smtpPort
                        if ($v -ge 1 -and $v -le 65535) { $syncHash.SmtpPort = $v }
                    }
                    if ($null -ne $payload.smtpSsl) { $syncHash.SmtpSsl = [bool]$payload.smtpSsl }
                    if ($null -ne $payload.smtpUser) { $syncHash.SmtpUser = [string]$payload.smtpUser }
                    if ($null -ne $payload.smtpPass -and [string]$payload.smtpPass -ne "********") { $syncHash.SmtpPass = [string]$payload.smtpPass }
                    if ($null -ne $payload.smtpFrom) { $syncHash.SmtpFrom = [string]$payload.smtpFrom }
                    if ($null -ne $payload.smtpTo) { $syncHash.SmtpTo = [string]$payload.smtpTo }

                    if ($null -ne $payload.syslogEnabled) { $syncHash.SyslogEnabled = [bool]$payload.syslogEnabled }
                    if ($null -ne $payload.syslogPort) {
                        # 範囲外のポート番号だと Syslog の受信が始められなくなるため、1〜65535 のときだけ反映する
                        $v = [int]$payload.syslogPort
                        if ($v -ge 1 -and $v -le 65535) { $syncHash.SyslogPort = $v }
                    }
                    if ($null -ne $payload.trapPort) {
                        $v = [int]$payload.trapPort
                        if ($v -ge 1 -and $v -le 65535) { $syncHash.TrapPort = $v }
                    }
if ($null -ne $payload.sslWarnDays) {
                        $v = [int]$payload.sslWarnDays
                        if ($v -ge 1 -and $v -le 3650) { $syncHash.SslWarnDays = $v }
                    }
                    if ($null -ne $payload.uiMode) { $syncHash.UiMode = [string]$payload.uiMode }
                    if ($null -ne $payload.bwThreshMbps) {
                        $v = [double]$payload.bwThreshMbps
                        if ($v -gt 0) { $syncHash.BwThreshMbps = $v }
                    }
                    if ($null -ne $payload.enableParentSuppression) {
                        $syncHash.EnableParentSuppression = [bool]$payload.enableParentSuppression
                    }

                    Log-Audit -action "CONFIG_UPDATE" -target "System" -details "System configuration updated" -clientIp $request.RemoteEndPoint.Address.ToString() -reportsDirectory $ReportsDir
                    
                    Write-JsonResponse $response @{ 
                        status                  = "success"
                        pollInterval            = $syncHash.PollInterval
                        pingDataSize            = $syncHash.PingDataSize
                        loggingEnabled          = $syncHash.LoggingEnabled
                        highFreqTargetIps       = $syncHash.HighFreqTargetIps
                        outageThresh1Ms         = $syncHash.OutageThresh1Ms
                        outageThresh2Ms         = $syncHash.OutageThresh2Ms
                        latencyThreshMs         = $syncHash.LatencyThreshMs
                        latencyWarningMs        = $syncHash.LatencyWarningMs
                        consecutiveFailThresh   = $syncHash.ConsecutiveFailThresh
                        logRetentionDays        = $syncHash.LogRetentionDays
                        webhookUrl              = $syncHash.WebhookUrl
                        webhookEnabled          = $syncHash.WebhookEnabled
                        webhookOfflineOnly      = $syncHash.WebhookOfflineOnly
                        soundEnabled            = $syncHash.SoundEnabled
                        soundVolume             = $syncHash.SoundVolume
                        emailEnabled            = $syncHash.EmailEnabled
                        syslogEnabled           = $syncHash.SyslogEnabled
                        uiMode                  = $syncHash.UiMode
                        bwThreshMbps            = $syncHash.BwThreshMbps
                        enableParentSuppression = $syncHash.EnableParentSuppression
                    }

                    # Save to file for persistence (DPAPI暗号化適用)
                    try {
                        $encSmtpPass = if ($syncHash.SmtpPass) { Protect-SecretString $syncHash.SmtpPass } else { "" }
                        $configObj = @{
                            pollInterval             = $syncHash.PollInterval
                            pingDataSize             = $syncHash.PingDataSize
                            loggingEnabled           = $syncHash.LoggingEnabled
                            highFreqTargetIps        = $syncHash.HighFreqTargetIps
                            outageThresh1Ms          = $syncHash.OutageThresh1Ms
                            outageThresh2Ms          = $syncHash.OutageThresh2Ms
                            latencyThreshMs          = $syncHash.LatencyThreshMs
                            latencyWarningMs         = $syncHash.LatencyWarningMs
                            consecutiveFailThresh    = $syncHash.ConsecutiveFailThresh
                            lossWarningThreshPercent = $syncHash.LossWarningThreshPercent
                            jitterWarningThreshMs    = $syncHash.JitterWarningThreshMs
                            logRetentionDays         = $syncHash.LogRetentionDays
                            webhookUrl               = $syncHash.WebhookUrl
                            webhookEnabled           = $syncHash.WebhookEnabled
                            webhookOfflineOnly       = $syncHash.WebhookOfflineOnly
                            soundEnabled             = $syncHash.SoundEnabled
                            soundVolume              = $syncHash.SoundVolume
                            emailEnabled             = $syncHash.EmailEnabled
                            smtpHost                 = $syncHash.SmtpHost
                            smtpPort                 = $syncHash.SmtpPort
                            smtpSsl                  = $syncHash.SmtpSsl
                            smtpUser                 = $syncHash.SmtpUser
                            smtpPass                 = $encSmtpPass
                            smtpFrom                 = $syncHash.SmtpFrom
                            smtpTo                   = $syncHash.SmtpTo
                            syslogEnabled            = $syncHash.SyslogEnabled
                            syslogPort               = $syncHash.SyslogPort
                            trapPort                 = $syncHash.TrapPort
sslWarnDays              = $syncHash.SslWarnDays
                            uiMode                   = $syncHash.UiMode
                            bwThreshMbps             = $syncHash.BwThreshMbps
                            enableParentSuppression  = $syncHash.EnableParentSuppression
                        }
                        # 画面に項目がない無人運用の設定は、config.json に書かれていた値をそのまま保つ
                        # (以前は保存のたびに消え、次の再起動で「ブラウザを閉じたら終了」に戻っていた)
                        if ($null -ne $syncHash.AutoShutdownInConfig) { $configObj.autoShutdownOnDisconnect = $syncHash.AutoShutdownInConfig }
                        # 変更前の config.json をスナップショットに退避してから、一時ファイル経由で安全に置き換える
                        Save-ConfigJsonSafely $configObj
}
                    catch {
                        Write-Host "Failed to save config.json: $_" -ForegroundColor Red
                    }
                }
                elseif ($urlPath -eq "/api/config/export" -and $method -eq "GET") {
                    # One-click full backup JSON (devices + config + positions)
                    $devicesJsonContent = if (Test-Path $devicesFileJson) { Get-Content $devicesFileJson -Raw -Encoding UTF8 | ConvertFrom-Json } else { @() }
                    # -Encoding UTF8: BOM のないファイルでも日本語の機器名が文字化けしないように
                    $configJsonContent = if (Test-Path $configFileJson) { Get-Content $configFileJson -Raw -Encoding UTF8 | ConvertFrom-Json } else { @{} }
                    
                    # 読み込んだ配列をそのまま ConvertTo-Json すると、PowerShell 5.1 では機器一覧が
                    # {"value":[...],"Count":N} という形で書き出され、復元時に機器が1台も戻らなかった。
                    # そのため、機器一覧と設定は元のJSONをそのまま組み立てて出力する
                    $devText = if ($null -ne $devicesJsonContent) { ConvertTo-Json -InputObject @($devicesJsonContent | ForEach-Object { $_ }) -Depth 10 } else { "[]" }
                    if (@($devicesJsonContent).Count -eq 0) { $devText = "[]" }
                    $cfgText = if ($null -ne $configJsonContent) { ConvertTo-Json -InputObject $configJsonContent -Depth 10 } else { "{}" }
                    $exportJson = "{`r`n  `"version`": `"2.0`",`r`n  `"exportDate`": `"$((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))`",`r`n  `"systemConfig`": $cfgText,`r`n  `"devices`": $devText`r`n}"
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($exportJson)
                    $fileName = "NetworkMonitor_Backup_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".json"
                    
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.Headers.Add("Content-Disposition", "attachment; filename=`"$fileName`"")
                    $response.ContentLength64 = $bytes.Length
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $response.OutputStream.Close()
                    continue
                }
                elseif ($urlPath -eq "/api/config/import" -and $method -eq "POST") {
                    # Restore from full backup JSON
                    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $jsonBody = $reader.ReadToEnd()
                    $payload = $jsonBody | ConvertFrom-Json
                    
                    if ($null -ne $payload -and ($null -ne $payload.devices -or $null -ne $payload.systemConfig)) {
                        # 1. Restore config.json if present
                        if ($null -ne $payload.systemConfig) {
                            $cfg = $payload.systemConfig
                            # 起動時と同じ全項目を反映する (以前はメール・Syslog・警告しきい値・親機器抑制などが反映されず、
                            # ファイルにだけ書かれて次の設定保存で失われていた)
                            Import-ConfigToSyncHash $cfg

                            Save-ConfigJsonSafely $cfg -AlwaysSnapshot
}
                        
                        # 2. Restore devices.json if present
                        # 以前のバージョンで書き出したバックアップは機器一覧が {"value":[...]} で包まれているので取り出す
                        $importDevices = $payload.devices
                        if ($null -ne $importDevices -and $null -ne $importDevices.PSObject.Properties['value']) { $importDevices = $importDevices.value }
                        $importDevices = @($importDevices | Where-Object { $null -ne $_ })
                        if ($importDevices.Count -gt 0) {
                            $validPayload = [System.Collections.Generic.List[object]]::new()
                            $ipRegex = '^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
                            foreach ($item in $importDevices) {
                                if ($item.ip -and $item.ip.Trim() -match $ipRegex) {
                                    $validPayload.Add($item)
                                }
                            }
                            
                            if ($validPayload.Count -gt 0) {
                                [System.Threading.Monitor]::Enter($syncHash.DevicesLock)
                                try {
                                    $syncHash.Devices = @()
                                    $syncHash.DeviceName.Clear(); $syncHash.Community.Clear(); $syncHash.Group.Clear()
                                    $syncHash.IsMonitored.Clear(); $syncHash.Image.Clear(); $syncHash.ConnectedTo.Clear()
                                    $syncHash.X.Clear(); $syncHash.Y.Clear()
                                    $syncHash.SnmpVersion.Clear(); $syncHash.SnmpUser.Clear(); $syncHash.SnmpAuthProto.Clear()
                                    $syncHash.SnmpAuthPass.Clear(); $syncHash.SnmpPrivProto.Clear(); $syncHash.SnmpPrivPass.Clear()
                                    $syncHash.ObrEnabled.Clear(); $syncHash.ObrPassword.Clear(); $syncHash.ObrStatus.Clear()
                                    $syncHash.Status.Clear(); $syncHash.Stats.Clear()
                                    $syncHash.Traffic.Clear(); $syncHash.SnmpDetail.Clear(); $syncHash.History.Clear()

                                    $newArr = [System.Collections.Generic.List[string]]::new()
                                    foreach ($item in $validPayload) {
                                        # 同じIPが複数行あると二重に監視・表示されるため最初の1件だけ使う
                                        if ($newArr.Contains(([string]$item.ip).Trim())) { continue }
                                        $ip = Set-DeviceRecordInSyncHash $item
                                        if (-not $ip) { continue }
                                        $newArr.Add($ip)
                                        if ($syncHash.IsMonitored[$ip]) { Initialize-DeviceLog -ip $ip }
                                    }
                                    $syncHash.Devices = $newArr.ToArray()
                                }
                                finally {
                                    [System.Threading.Monitor]::Exit($syncHash.DevicesLock)
                                }
                                Save-DevicesJson
                            }
                        }
                        Write-JsonResponse $response @{ status = "success"; message = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("6Kit5a6a44Go5qmf5Zmo5oOF5aCx44KS5q2j5bi444Gr5b6p5YWD44GX44G+44GX44Gf44CC")) }
                    }
                    else {
                        Write-JsonResponse $response @{ error = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("54Sh5Yq544Gq44OQ44OD44Kv44Ki44OD44OX44OV44Kh44Kk44Or5b2i5byP44Gn44GZ44CC")) } 400
                    }
                }
                elseif ($urlPath -eq "/api/webhook/test" -and $method -eq "POST") {
                    # Test Webhook endpoint (Async ThreadPool execution)
                    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $jsonBody = $reader.ReadToEnd()
                    $payload = $jsonBody | ConvertFrom-Json
                    $targetUrl = if ($payload.url) { [string]$payload.url } else { $syncHash.WebhookUrl }
                    
                    if ([string]::IsNullOrWhiteSpace($targetUrl)) {
                        Write-JsonResponse $response @{ error = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("V2ViaG9vayBVUkwg44GM6Kit5a6a44GV44KM44Gm44GE44G+44Gb44KT44CC")) } 400
                    }
                    else {
                        $respRef = $response
                        $urlRef = $targetUrl
                        Start-BackgroundScript -ArgumentList @($respRef, $urlRef) -ScriptBlock {
                            param($respRef, $urlRef)
                            try {
                                Send-WebhookNotification -url $urlRef -deviceName "システム監視マネージャー" -ip "127.0.0.1" -eventType "test" -details ([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("44OG44K544OI6YCa55+l44GM5q2j5bi444Gr5Y+X5L+h44GV44KM44G+44GX44Gf44CC"))) -ThrowOnError   # 失敗したら catch へ (以前は失敗しても「送信しました」と表示されていた)
                                Write-JsonResponse $respRef @{ status = "success"; message = "Webhook テスト通知を送信しました。" }
                            }
                            catch {
                                Write-JsonResponse $respRef @{ error = "送信失敗: $($_.Exception.Message)" } 500
                            }
                        }
                        continue
                    }
                }
                elseif ($urlPath -eq "/api/mtr" -and $method -eq "GET") {
                    $targetIp = $request.QueryString["ip"]
                    $action = $request.QueryString["action"] # "start", "status", or "stop"
                    
                    if ($action -eq "status") {
                        $state = $syncHash.MtrState
                        Write-JsonResponse $response @{ 
                            status  = "success"
                            running = $state.Running
                            output  = $state.Output
                        }
                        continue
                    }

                    if ($action -eq "stop") {
                        if ($syncHash.MtrState.Running) {
                            $syncHash.MtrState.StopRequested = $true
                            $mtrProc = $syncHash.MtrState.Process
                            if ($null -ne $mtrProc -and -not $mtrProc.HasExited) {
                                # taskkill kills tracert.exe process tree
                                try { & taskkill /F /T /PID $mtrProc.Id 2>$null } catch { }
                                try { $mtrProc.Kill() } catch { }
                            }
                            Write-JsonResponse $response @{ status = "stopping" }
                        }
                        else {
                            Write-JsonResponse $response @{ status = "not_running" }
                        }
                        continue
                    }

                    if ($targetIp) {
                        if ($targetIp -notmatch '^[a-zA-Z0-9][a-zA-Z0-9\.\-]*$') {   # 先頭が「-」だとコマンドのオプションとして扱われるため許可しない
                            Write-JsonResponse $response @{ error = "Invalid target IP address" } 400
                            continue
                        }
                        if ($syncHash.MtrState.Running) {
                            Write-JsonResponse $response @{ error = "Another MTR session is already running" } 409
                            continue
                        }

                        $syncHash.MtrState.Running = $true
                        $syncHash.MtrState.Output = ""
                        $syncHash.MtrState.Target = $targetIp
                        $syncHash.MtrState.Process = $null
                        $syncHash.MtrState.StopRequested = $false

                        $mtrTaskScript = {
                            param($tIp, $sync)
                            try {
                                $sync.MtrState.Output += "> Starting MTR Route Diagnostics for: $tIp`n"
                                $sync.MtrState.Output += "> Waiting for responses from routers... (Max 30 hops)`n`n"
                                
                                # Using tracert -d (no DNS) for speed
                                $pInfo = New-Object System.Diagnostics.ProcessStartInfo
                                $pInfo.FileName = "tracert.exe"
                                $pInfo.Arguments = "-d -h 30 -w 500 $tIp"
                                $pInfo.StandardOutputEncoding = [System.Text.Encoding]::GetEncoding(932)
                                $pInfo.StandardErrorEncoding = [System.Text.Encoding]::GetEncoding(932)
                                $pInfo.RedirectStandardOutput = $true
                                $pInfo.RedirectStandardError = $true
                                $pInfo.UseShellExecute = $false
                                $pInfo.CreateNoWindow = $true
                                
                                $proc = New-Object System.Diagnostics.Process
                                $proc.StartInfo = $pInfo
                                $null = $proc.Start()
                                $sync.MtrState.Process = $proc   # save ref for stop API
                                
                                while (-not $proc.HasExited) {
                                    $line = $proc.StandardOutput.ReadLine()
                                    if ($null -ne $line) {
                                        $sync.MtrState.Output += $line + "`n"
                                    }
                                    [System.Threading.Thread]::Sleep(50)
                                }
                                $sync.MtrState.Output += $proc.StandardOutput.ReadToEnd()
                                if ($sync.MtrState.StopRequested) {
                                    $sync.MtrState.Output += "`n> Diagnostics stopped by user.`n"
                                }
                                else {
                                    $sync.MtrState.Output += "`n> Diagnostics completed.`n"
                                }
                            }
                            catch {
                                $sync.MtrState.Output += "Error during MTR: $($_.Exception.Message)"
                            }
                            finally {
                                $sync.MtrState.Running = $false
                                $sync.MtrState.Process = $null
                                $sync.MtrState.StopRequested = $false
                            }
                        }
                        
                        $ps = [powershell]::Create().AddScript($mtrTaskScript).AddArgument($targetIp).AddArgument($syncHash)
                        # 終わったら Start-BackgroundScript 側で片付けられるよう一覧に登録する (以前は作りっぱなしで実行のたびにメモリが残った)
                        $null = $script:AsyncHttpJobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke() })
                        
                        Write-JsonResponse $response @{ status = "started" }
                    }
                    else {
                        Write-JsonResponse $response @{ error = "Missing ip" } 400
                    }
                }
                elseif ($urlPath -eq "/api/history" -and $method -eq "GET") {
                    $ip = $request.QueryString["ip"]
                    if (-not $ip) {
                        Write-JsonResponse $response @{ error = "Missing ip" } 400
                        continue
                    }
                    if ($ip -notmatch '^[a-zA-Z0-9\.\-]+$') {
                        Write-JsonResponse $response @{ error = "Invalid IP address" } 400
                        continue
                    }
                    
                    $safeIp = $ip -replace '[\\/:*?"<>|]', '_'
                    $csvPath = Join-Path $syncHash.SessionDir "${safeIp}.csv"
                    if (-not (Test-Path $csvPath)) {
                        $altSafeIp = $ip -replace '[\.:_]', '_'
                        $altCsvPath = Join-Path $syncHash.SessionDir "${altSafeIp}.csv"
                        if (Test-Path $altCsvPath) { $csvPath = $altCsvPath }
                    }
                    
                    if (Test-Path $csvPath) {
                        # 0.1秒監視ではCSVが数十MBになり、読み込み中はHTTP受付ループ全体が止まるため別スレッドで処理する
                        Start-BackgroundScript -ArgumentList @($response, $csvPath, $syncHash.SessionDir) -ScriptBlock {
                        param($response, $csvPath, $sessionDir)
                        try {
                            # Read CSV with Shift-JIS (CP932) encoding, support rotated _1.csv, and slice last 1000 rows before ConvertFrom-Csv
                            $baseNoExt = [System.IO.Path]::GetFileNameWithoutExtension($csvPath)
                            $rot1Path = Join-Path $sessionDir "${baseNoExt}_1.csv"
                            # 直近1000行だけをリングバッファで保持 (ファイル全体をメモリに読み込まない)
                            $dataLines = [System.Collections.Generic.Queue[string]]::new(1024)
                            $headerLine = $null
                            $segFiles = if (Test-Path $rot1Path) { @($rot1Path, $csvPath) } else { @($csvPath) }
                            foreach ($sf in $segFiles) {
                                # 監視ループが追記中でも読めるよう FileShare.ReadWrite で開き、読み終えたら必ず閉じる
                                $fsHist = [System.IO.FileStream]::new($sf, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                                $srHist = [System.IO.StreamReader]::new($fsHist, [System.Text.Encoding]::GetEncoding(932))
                                try {
                                    $firstLine = $true
                                    while ($null -ne ($ln = $srHist.ReadLine())) {
                                        if ([string]::IsNullOrWhiteSpace($ln) -or $ln.StartsWith("---")) {
                                            if (-not $firstLine) { break }
                                            continue
                                        }
                                        if ($firstLine) {
                                            $firstLine = $false
                                            if ($null -eq $headerLine) { $headerLine = $ln }
                                            continue
                                        }
                                        $dataLines.Enqueue($ln)
                                        if ($dataLines.Count -gt 1000) { $null = $dataLines.Dequeue() }
                                    }
                                }
                                finally {
                                    $srHist.Dispose()
                                    $fsHist.Dispose()
                                }
                            }
                            $tailLines = [System.Collections.Generic.List[string]]::new(1001)
                            if ($null -ne $headerLine) { $tailLines.Add($headerLine) }
                            foreach ($dl in $dataLines) { $tailLines.Add($dl) }
                            $rawRows = if ($tailLines.Count -gt 1) { @($tailLines | ConvertFrom-Csv) } else { @() }
                            $normalizedData = foreach ($r in $rawRows) {
                                $ts = if ($r.Timestamp) { $r.Timestamp } elseif ($r.'タイムスタンプ') { $r.'タイムスタンプ' } else { "" }
                                $lat = if ($null -ne $r.Latency_ms -and $r.Latency_ms -ne "") { $r.Latency_ms } elseif ($null -ne $r.'遅延_ms' -and $r.'遅延_ms' -ne "") { $r.'遅延_ms' } else { "0" }
                                $tx = if ($null -ne $r.Tx_Mbps -and $r.Tx_Mbps -ne "") { $r.Tx_Mbps } elseif ($null -ne $r.'送信_Mbps' -and $r.'送信_Mbps' -ne "") { $r.'送信_Mbps' } else { "0" }
                                $rx = if ($null -ne $r.Rx_Mbps -and $r.Rx_Mbps -ne "") { $r.Rx_Mbps } elseif ($null -ne $r.'受信_Mbps' -and $r.'受信_Mbps' -ne "") { $r.'受信_Mbps' } else { "0" }
                                
                                [PSCustomObject]@{
                                    Timestamp  = $ts
                                    'タイムスタンプ'  = $ts
                                    IP         = if ($r.IP) { $r.IP } elseif ($r.'IPアドレス') { $r.'IPアドレス' } else { "" }
                                    Status     = if ($r.Status) { $r.Status } elseif ($r.'ステータス') { $r.'ステータス' } else { "" }
                                    Latency_ms = $lat
                                    '遅延_ms'    = $lat
                                    Tx_Mbps    = $tx
                                    '送信_Mbps'  = $tx
                                    Rx_Mbps    = $rx
                                    '受信_Mbps'  = $rx
                                    Jitter_ms  = if ($null -ne $r.Jitter_ms -and $r.Jitter_ms -ne "") { $r.Jitter_ms } elseif ($null -ne $r.'ジッター_ms' -and $r.'ジッター_ms' -ne "") { $r.'ジッター_ms' } else { "0" }
                                }
                            }
                            Write-JsonResponse $response @{ status = "success"; data = $normalizedData }
                        }
                        catch {
                            Write-JsonResponse $response @{ error = "Failed to read history data" } 500
                        }
                        }
                    }
                    else {
                        Write-JsonResponse $response @{ error = "No history log found for this device" } 404
                    }
                }
                elseif ($urlPath -eq "/api/obr/history" -and $method -eq "GET") {
                    $ip = $request.QueryString["ip"]
                    if (-not $ip -or $ip -notmatch '^[a-zA-Z0-9\.\-]+$') {
                        Write-JsonResponse $response @{ error = "Invalid IP address" } 400
                        continue
                    }
                    # 長く動かすと CSV が 15 万行ほどになり、読み込み中に画面全体が止まらないよう別スレッドで処理する
                    Start-BackgroundScript -ArgumentList @($response, (Join-Path $modulesDir "ObrStatus.psm1"), $syncHash.SessionDir, $ip, ($syncHash.LoggingEnabled -ne $false)) -ScriptBlock {
                        param($response, $obrModulePath, $sessionDir, $ip, $loggingEnabled)
                        try {
                            Import-Module $obrModulePath -DisableNameChecking -ErrorAction Stop
                            $view = Get-ObrHistoryView -SessionDir $sessionDir -Ip $ip
                            $view.status = "success"
                            $view.loggingEnabled = $loggingEnabled
                            Write-JsonResponse $response $view
                        }
                        catch {
                            Write-JsonResponse $response @{ error = "Failed to read OBR history" } 500
                        }
                    }
                }
                elseif ($urlPath -eq "/api/iperf" -and $method -eq "GET") {
                    $targetIp = $request.QueryString["ip"]
                    $duration = $request.QueryString["t"]
                    $customOpts = $request.QueryString["opts"]
                    $bwThreshParam = $request.QueryString["bw"]   # bandwidth threshold in Mbps
                    $action = $request.QueryString["action"] # "start" or "status"
                    
                    if ($action -eq "status") {
                        # Return current output and running state
                        $state = $syncHash.IperfState
                        Write-JsonResponse $response @{ 
                            status  = "success"
                            running = $state.Running
                            output  = $state.Output
                            command = $state.Command
                        }
                        continue
                    }

                    if ($action -eq "stop") {
                        if ($syncHash.IperfState.Running) {
                            $syncHash.IperfState.StopRequested = $true
                            $iperfProc = $syncHash.IperfState.Process
                            if ($null -ne $iperfProc -and -not $iperfProc.HasExited) {
                                # taskkill /F /T kills the cmd.exe + its iperf3.exe child together
                                try { & taskkill /F /T /PID $iperfProc.Id 2>$null } catch { }
                                # Fallback: direct .Kill() on the cmd.exe handle
                                try { $iperfProc.Kill() } catch { }
                            }
                            Write-JsonResponse $response @{ status = "stopping" }
                        }
                        else {
                            Write-JsonResponse $response @{ status = "not_running" }
                        }
                        continue
                    }

                    if (-not $duration) { $duration = 5 }
                    if ($duration -and $duration -notmatch '^\d+$') {
                        Write-JsonResponse $response @{ error = "Invalid duration parameter" } 400
                        continue
                    }
                    # 計測時間は 1〜3600 秒に制限する (以前は上限がなく、0 は無期限・桁の打ち間違いで数日間計測が続き、
                    # その間は他の帯域計測ができなかった)
                    if ([int64]$duration -lt 1 -or [int64]$duration -gt 3600) {
                        Write-JsonResponse $response @{ error = "Duration must be between 1 and 3600 seconds" } 400
                        continue
                    }

                    if ($targetIp) {
                        if ($targetIp -notmatch '^[a-zA-Z0-9][a-zA-Z0-9\.\-]*$') {   # 先頭が「-」だとコマンドのオプションとして扱われるため許可しない
                            Write-JsonResponse $response @{ error = "Invalid target IP address" } 400
                            continue
                        }
                        if ($syncHash.IperfState.Running) {
                            Write-JsonResponse $response @{ error = "Another iperf measurement is already running" } 409
                            continue
                        }

                        # iperf3.exe の場所を探す
                        $iperfExe = Join-Path $syncHash.PSScriptRoot "iperf3.exe"
                        if (-not (Test-Path $iperfExe)) {
                            $iperfExe = Join-Path $syncHash.PSScriptRoot "iperf3.18_64\iperf3.exe"
                        }
                        if (-not (Test-Path $iperfExe)) {
                            $iperfExe = Get-Command iperf3 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
                        }
                        
                        if ($iperfExe -and (Test-Path $iperfExe)) {
                            # 実行コマンドの構築 (リアルタイム表示のために --forceflush と -i 1 を追加)
                            $cmdArgs = "-c $targetIp -t $duration -i 1 --forceflush"
                            # 毎回初期化する (HTTP受付ループの変数は要求をまたいで残るため、以前はオプション未指定の計測でも
                            # 前回の計測で指定した追加オプションがそのまま iperf3 に渡されていた)
                            $safeOpts = ""
                            if ($customOpts) {
                                $safeOpts = $customOpts -replace '[^a-zA-Z0-9\s\-]', ''
                                if ($safeOpts -notmatch "-i\s+\d+") {
                                    $cmdArgs += " $safeOpts"
                                }
                                else {
                                    # If -i is already present, just append the rest
                                    $cmdArgs = "-c $targetIp -t $duration --forceflush $safeOpts"
                                }
                            }
                            
                            # 非同期実行用のスクリプトブロック
                            $syncHash.IperfState.Running = $true
                            $syncHash.IperfState.Output = ""
                            $syncHash.IperfState.Command = "iperf3 $cmdArgs"
                            $syncHash.IperfState.Target = $targetIp
                            $syncHash.IperfState.StopRequested = $false
                            $syncHash.IperfState.Process = $null
                            # Parse bandwidth threshold (default from config or 10 Mbps)
                            $bwThreshMbps = if ($null -ne $syncHash.BwThreshMbps -and $syncHash.BwThreshMbps -gt 0) { [double]$syncHash.BwThreshMbps } else { 10.0 }
                            if ($bwThreshParam -match '^\d+(\.\d+)?$') { $bwThreshMbps = [double]$bwThreshParam }

                            $iperfTaskScript = {
                                param($exe, $tIp, $dur, $opts, $sync, $sessDir, $bwThresh, $reportsDir)
                                $safeIp = $tIp -replace '[\\/:*?"<>|]', '_'
                                $tmpLiveLog = Join-Path ([System.IO.Path]::GetTempPath()) "ndm_iperf_tmp_$([guid]::NewGuid().ToString('N')).log"
                                
                                # ログ保存先（機器別ログ iperf_${safeIp}.log の1つだけに一本化）
                                $primaryLogFile = Join-Path $sessDir "iperf_${safeIp}.log"
                                $preExecLines = if (Test-Path $primaryLogFile) {
                                    try { [System.IO.File]::ReadAllLines($primaryLogFile, [System.Text.Encoding]::UTF8) } catch { @() }
                                }
                                else { @() }
                                $logFiles = @($primaryLogFile)

                                # ヘルパー: ログファイルに追記
                                function Write-IperfLogs([string]$text) {
                                    foreach ($lf in $logFiles) {
                                        try {
                                            $text | Out-File -FilePath $lf -Append -Encoding UTF8
                                        }
                                        catch {}
                                    }
                                }

                                try {
                                    $sync.IperfState.Output = "Starting iperf3...`n"
                                    
                                    # iperf3 コマンド引数（--forceflush で 1s ごとに fflush を強制）
                                    $iperfArgs = "-c $tIp -t $dur -i 1 --forceflush"
                                    if ($opts) {
                                        if ($opts -notmatch "-i\s+\d+") {
                                            $iperfArgs += " $opts"
                                        }
                                        else {
                                            $iperfArgs = "-c $tIp -t $dur --forceflush $opts"
                                        }
                                    }

                                    $sync.IperfState.Command = "iperf3 $iperfArgs"

                                    $tsStart = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

                                    Write-IperfLogs "=== iperf3 Execution at $tsStart ==="
                                    Write-IperfLogs "Target IP: $tIp"
                                    Write-IperfLogs "Command: iperf3 $iperfArgs"
                                    Write-IperfLogs "-----------------------------------------------------------"

                                    # cmd.exe /c で OS レベルの stdout ファイルリダイレクト
                                    $cmdArguments = "/c `"`"$exe`" $iperfArgs > `"$tmpLiveLog`" 2>&1`""

                                    $pInfo = New-Object System.Diagnostics.ProcessStartInfo
                                    $pInfo.FileName = "cmd.exe"
                                    $pInfo.Arguments = $cmdArguments
                                    $pInfo.UseShellExecute = $false
                                    $pInfo.CreateNoWindow = $true

                                    $proc = New-Object System.Diagnostics.Process
                                    $proc.StartInfo = $pInfo
                                    $null = $proc.Start()
                                    $sync.IperfState.Process = $proc

                                    # ファイルが生成されるまで待機 (最大 3 秒)
                                    $waited = 0
                                    while (-not (Test-Path $tmpLiveLog) -and $waited -lt 3000 -and -not $proc.HasExited) {
                                        Start-Sleep -Milliseconds 100
                                        $waited += 100
                                    }

                                    # バイトオフセット追跡によるリアルタイム追尾ループ
                                    [long]$byteOffset = 0
                                    while (-not $proc.HasExited) {
                                        Start-Sleep -Milliseconds 200
                                        try {
                                            $fs = New-Object System.IO.FileStream(
                                                $tmpLiveLog,
                                                [System.IO.FileMode]::Open,
                                                [System.IO.FileAccess]::Read,
                                                [System.IO.FileShare]::ReadWrite)
                                            $fileLen = $fs.Length
                                            if ($fileLen -gt $byteOffset) {
                                                $null = $fs.Seek($byteOffset, [System.IO.SeekOrigin]::Begin)
                                                $readLen = [int]($fileLen - $byteOffset)
                                                $buf = New-Object byte[] $readLen
                                                $read = $fs.Read($buf, 0, $readLen)
                                                $byteOffset += $read
                                                $chunk = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
                                                foreach ($ln in ($chunk -split "`n")) {
                                                    $trimmed = $ln.TrimEnd("`r")
                                                    if ($trimmed) {
                                                        $nowTs = Get-Date -Format "HH:mm:ss"
                                                        $fl = "[$nowTs] $trimmed"
                                                        $sync.IperfState.Output += $fl + "`n"
                                                        Write-IperfLogs $fl
                                                    }
                                                }
                                            }
                                            $fs.Close()
                                        }
                                        catch { try { $fs.Close() } catch {} }
                                    }

                                    # プロセス終了後の残りデータをフラッシュ
                                    Start-Sleep -Milliseconds 300
                                    if (Test-Path $tmpLiveLog) {
                                        try {
                                            $fs = New-Object System.IO.FileStream(
                                                $tmpLiveLog,
                                                [System.IO.FileMode]::Open,
                                                [System.IO.FileAccess]::Read,
                                                [System.IO.FileShare]::ReadWrite)
                                            $fileLen = $fs.Length
                                            if ($fileLen -gt $byteOffset) {
                                                $null = $fs.Seek($byteOffset, [System.IO.SeekOrigin]::Begin)
                                                $readLen = [int]($fileLen - $byteOffset)
                                                $buf = New-Object byte[] $readLen
                                                $read = $fs.Read($buf, 0, $readLen)
                                                $chunk = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
                                                foreach ($ln in ($chunk -split "`n")) {
                                                    $trimmed = $ln.TrimEnd("`r")
                                                    if ($trimmed) {
                                                        $nowTs = Get-Date -Format "HH:mm:ss"
                                                        $fl = "[$nowTs] $trimmed"
                                                        $sync.IperfState.Output += $fl + "`n"
                                                        Write-IperfLogs $fl
                                                    }
                                                }
                                            }
                                            $fs.Close()
                                        }
                                        catch { try { $fs.Close() } catch {} }
                                    }

                                    if (-not $proc.HasExited) {
                                        try { & taskkill /F /T /PID $proc.Id 2>$null } catch {}
                                        try { $proc.Kill() } catch { }
                                    }
                                }
                                catch {
                                    $errMsg = "Error during execution: $($_.Exception.Message)"
                                    $sync.IperfState.Output += $errMsg
                                    Write-IperfLogs $errMsg
                                }
                                finally {
                                    try { if (Test-Path $tmpLiveLog) { Remove-Item $tmpLiveLog -Force -ErrorAction SilentlyContinue } } catch {}
                                    try {
                                        Get-ChildItem -Path $sessDir, $reportsDir -Filter "*tmp*.log" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                                        Get-ChildItem -Path $sessDir, $reportsDir -Filter "*temp*.log" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                                    }
                                    catch {}
                                    $tsEnd = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                                    $endLabel = if ($sync.IperfState.StopRequested) { "STOPPED by user" } else { "Finished" }
                                    Write-IperfLogs "=== iperf3 $endLabel at $tsEnd ==="
                                    Write-IperfLogs "-----------------------------------------------------------"

                                    # ── 統計サマリー集計 (TCP / UDP モード別最適化) ──────────────────────────────────────
                                    try {
                                        $primaryLogFile = Join-Path $sessDir "iperf_${safeIp}.log"
                                        $logContent = Get-Content $primaryLogFile -Encoding UTF8 -ErrorAction SilentlyContinue
                                        
                                        # UDPモード判定: コマンドオプションに -u/--udp が含まれるか、ログに出現するか
                                        $isUdpMode = ($iperfArgs -match '(\s|^)-u(\s|$)' -or $iperfArgs -match '--udp' -or ($opts -and ($opts -match '(\s|^)-u(\s|$)' -or $opts -match '--udp')))
                                        
                                        $bwValues = [System.Collections.Generic.List[double]]::new()
                                        $transferValues = [System.Collections.Generic.List[double]]::new() # MBytes
                                        $jitterValues = [System.Collections.Generic.List[double]]::new() # ms
                                        $totalTimeSec = 0.0
                                        $tcpRetransmits = 0
                                        $hasTcpRetr = $false
                                        $udpLostPackets = 0
                                        $udpTotalPackets = 0
                                        $udpLossPercent = 0.0
                                        $hasUdpLossInfo = $false
                                        $udpFinalJitter = $null

                                        foreach ($logLine in $logContent) {
                                            # UDP毎秒行: [  5]   0.00-1.00   sec  1.19 MBytes  10.0 Mbits/sec  0.035 ms  0/892 (0%)
                                            if ($logLine -match '\[\s*\d+\]\s+([0-9.]+)-([0-9.]+)\s+sec\s+([0-9.]+)\s+([KMG]?)Bytes\s+([0-9.]+)\s+([KMG]?)bits/sec\s+([0-9.]+)\s+ms\s+(\d+)/(\d+)\s+\(([0-9.]+)%\)') {
                                                $isUdpMode = $true
                                                $startT = [double]$Matches[1]
                                                $endT = [double]$Matches[2]
                                                $tfRaw = [double]$Matches[3]
                                                $tfUnit = $Matches[4]
                                                $bwRaw = [double]$Matches[5]
                                                $bwUnit = $Matches[6]
                                                $jitMs = [double]$Matches[7]
                                                $lost = [int]$Matches[8]
                                                $tot = [int]$Matches[9]
                                                $lossP = [double]$Matches[10]

                                                $bwMbps = switch ($bwUnit) {
                                                    'K' { $bwRaw / 1000.0 }
                                                    'G' { $bwRaw * 1000.0 }
                                                    default { $bwRaw }
                                                }
                                                $tfMBytes = switch ($tfUnit) {
                                                    'K' { $tfRaw / 1024.0 }
                                                    'G' { $tfRaw * 1024.0 }
                                                    default { $tfRaw }
                                                }

                                                if ($logLine -match 'receiver') {
                                                    $udpFinalJitter = $jitMs
                                                    $udpLostPackets = $lost
                                                    $udpTotalPackets = $tot
                                                    $udpLossPercent = $lossP
                                                    $hasUdpLossInfo = $true
                                                }
                                                elseif ($logLine -notmatch 'sender|SUM') {
                                                    $intervalLen = $endT - $startT
                                                    if ($intervalLen -gt 0.0 -and $intervalLen -le 1.5) {
                                                        $bwValues.Add($bwMbps)
                                                        $transferValues.Add($tfMBytes)
                                                        $jitterValues.Add($jitMs)
                                                        if ($endT -gt $totalTimeSec) { $totalTimeSec = $endT }
                                                    }
                                                }
                                            }
                                            # TCP毎秒行: [  5]   0.00-1.00   sec  11.2 MBytes  94.1 Mbits/sec  [0    200 KBytes]
                                            elseif ($logLine -match '\[\s*\d+\]\s+([0-9.]+)-([0-9.]+)\s+sec\s+([0-9.]+)\s+([KMG]?)Bytes\s+([0-9.]+)\s+([KMG]?)bits/sec(?:\s+(\d+))?' `
                                                    -and $logLine -notmatch 'sender|receiver|SUM') {
                                                $startT = [double]$Matches[1]
                                                $endT = [double]$Matches[2]
                                                $tfRaw = [double]$Matches[3]
                                                $tfUnit = $Matches[4]
                                                $bwRaw = [double]$Matches[5]
                                                $bwUnit = $Matches[6]
                                                $retr = $Matches[7]

                                                $bwMbps = switch ($bwUnit) {
                                                    'K' { $bwRaw / 1000.0 }
                                                    'G' { $bwRaw * 1000.0 }
                                                    default { $bwRaw }
                                                }
                                                $tfMBytes = switch ($tfUnit) {
                                                    'K' { $tfRaw / 1024.0 }
                                                    'G' { $tfRaw * 1024.0 }
                                                    default { $tfRaw }
                                                }
                                                $intervalLen = $endT - $startT
                                                if ($intervalLen -gt 0.0 -and $intervalLen -le 1.5) {
                                                    $bwValues.Add($bwMbps)
                                                    $transferValues.Add($tfMBytes)
                                                    if ($retr) {
                                                        $tcpRetransmits += [int]$retr
                                                        $hasTcpRetr = $true
                                                    }
                                                    if ($endT -gt $totalTimeSec) { $totalTimeSec = $endT }
                                                }
                                            }
                                            # TCP最終sender行の再送数チェック
                                            elseif ($logLine -match 'sender' -and $logLine -match '\[\s*\d+\]\s+([0-9.]+)-([0-9.]+)\s+sec\s+[0-9.]+\s+[KMG]?Bytes\s+[0-9.]+\s+[KMG]?bits/sec(?:\s+(\d+))') {
                                                if ($Matches[3]) {
                                                    $tcpRetransmits = [int]$Matches[3]
                                                    $hasTcpRetr = $true
                                                }
                                            }
                                        }

                                        if ($bwValues.Count -gt 0) {
                                            $n = $bwValues.Count
                                            $avg = ($bwValues | Measure-Object -Average).Average
                                            $maxBw = ($bwValues | Measure-Object -Maximum).Maximum
                                            $minBw = ($bwValues | Measure-Object -Minimum).Minimum
                                            $sorted = $bwValues | Sort-Object
                                            $median = if ($n % 2 -eq 0) {
                                                ([double]$sorted[$n / 2 - 1] + [double]$sorted[$n / 2]) / 2.0
                                            }
                                            else {
                                                [double]$sorted[($n - 1) / 2]
                                            }
                                            $variance = ($bwValues | ForEach-Object { [math]::Pow($_ - $avg, 2) } | Measure-Object -Sum).Sum / $n
                                            $stdDev = [math]::Sqrt($variance)
                                            $aboveCount = ($bwValues | Where-Object { $_ -ge $bwThresh }).Count
                                            $belowCount = $n - $aboveCount
                                            $abovePct = [math]::Round($aboveCount / $n * 100, 1)
                                            $belowPct = [math]::Round($belowCount / $n * 100, 1)

                                            $totTransferMB = ($transferValues | Measure-Object -Sum).Sum
                                            $totTransferStr = if ($totTransferMB -ge 1024.0) {
                                                ("{0:F2} GBytes" -f ($totTransferMB / 1024.0))
                                            }
                                            else {
                                                ("{0:F1} MBytes" -f $totTransferMB)
                                            }

                                            # Japanese labels via Base64 (avoids PS5 source-encoding issues)
                                            $iperfB64 = "eyJtZWRpYW4iOiLkuK3lpK7lgKQiLCJ0YXJnZXQiOiLmjqXntprlhYggKElQL+ODieODoeOCpOODsykiLCJ0aHJlc2giOiLluK/ln5/plr7lgKQiLCJsb3NzUmF0ZSI6IuODkeOCseODg+ODiOaQjeWkseeOhyAoUmF0ZSkiLCJldmFsVWRwR29vZCI6IuKchSDlhKrnp4DvvIhWb0lQ44O75pig5YOP5Lya6K2w44O744Oq44Ki44Or44K/44Kk44Og6YCa5L+h44Gr5pyA6YGp77yJIiwiaml0dGVyQXZnIjoi5bmz5Z2H44K444OD44K/44O8ICjmj7rjgonjgY4pIiwiZXZhbFRjcEdvb2QiOiLinIUg5YSq56eA44O75qW144KB44Gm5a6J5a6a77yI44OR44Kx44OD44OI5YaN6YCB44Gq44GX77yJIiwiaml0dGVyTWF4Ijoi5pyA5aSn44K444OD44K/44O8ICjmj7rjgonjgY4pIiwiYmVsb3ciOiLplr7lgKTmnKrmuoAiLCJtYXhNaW5CdyI6IuacgOWkp+W4r+WfnyAvIOacgOWwj+W4r+WfnyIsImV2YWxUaXRsZSI6IuWTgeizquipleS+oSIsImR1cmF0aW9uIjoi5ZCI6KiI6KiI5ris5pmC6ZaTIiwiZXZhbFRjcFdhcm4iOiLimqDvuI8g5rOo5oSP77yI44OR44Kx44OD44OI5YaN6YCB44GM55m655Sf77yJIiwiZXZhbFVkcEZhaXIiOiLwn5+iIOiJr+Wlve+8iOS4gOiIrOeahOOBqumAmuS/oeOBq+aUr+manOOBquOBl++8iSIsImhlYWRlclVkcCI6Ij09PT09PT09PT09PT09PT09PT09IGlwZXJmMyDntbHoqIjjgrXjg57jg6rjg7wgKFVEUCkgPT09PT09PT09PT09PT09PT09PT0iLCJhYm92ZSI6IumWvuWApOS7peS4iiIsInRyYW5zZmVyIjoi5ZCI6KiI44OH44O844K/6Lui6YCB6YePIiwiZXZhbFVkcFdhcm4iOiLimqDvuI8g6KaB6Kq/5p+777yI44OR44Kx44OD44OI56C05qOE44G+44Gf44Gv44K444OD44K/44O86YGO5aSn77yJIiwidGNwUmV0ciI6IlRDUOWGjemAgeODkeOCseODg+ODiOaVsCIsImZvb3RlciI6Ij09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PSIsImxvc3RQYWNrZXRzIjoi44OR44Kx44OD44OI5pCN5aSx5pWwIChMb3NzKSIsImF2Z0J3Ijoi5bmz5Z2H5biv5Z+fICjjgrnjg6vjg7zjg5fjg4Pjg4gpIiwiaGVhZGVyVGNwIjoiPT09PT09PT09PT09PT09PT09PT0gaXBlcmYzIOe1seioiOOCteODnuODquODvCAoVENQKSA9PT09PT09PT09PT09PT09PT09PSIsIm1pbkJ3Ijoi5pyA5bCP5biv5Z+fIiwicHJvdG9jb2wiOiLpgJrkv6Hjg5fjg63jg4jjgrPjg6siLCJzdGREZXYiOiLmqJnmupblgY/lt64iLCJtYXhCdyI6IuacgOWkp+W4r+WfnyJ9"
                                            $iL = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($iperfB64)) | ConvertFrom-Json

                                            $targetDisplay = if ($sync.DeviceName -and $sync.DeviceName.ContainsKey($tIp) -and $sync.DeviceName[$tIp] -ne $tIp) { "$tIp ($($sync.DeviceName[$tIp]))" } else { $tIp }

                                            $iLines = [System.Collections.Generic.List[string]]::new()
                                            $iLines.Add("")

                                            if ($isUdpMode) {
                                                # ─── UDP モード専用サマリー ───
                                                $avgJit = if ($jitterValues.Count -gt 0) { ($jitterValues | Measure-Object -Average).Average } else { 0.0 }
                                                $maxJit = if ($jitterValues.Count -gt 0) { ($jitterValues | Measure-Object -Maximum).Maximum } else { 0.0 }
                                                if ($null -ne $udpFinalJitter -and $udpFinalJitter -gt 0) { $avgJit = $udpFinalJitter }

                                                $evalUdp = if ($hasUdpLossInfo -and $udpLossPercent -eq 0.0 -and $avgJit -lt 5.0) {
                                                    $iL.evalUdpGood
                                                }
                                                elseif ($hasUdpLossInfo -and $udpLossPercent -lt 1.0 -and $avgJit -lt 20.0) {
                                                    $iL.evalUdpFair
                                                }
                                                else {
                                                    $iL.evalUdpWarn
                                                }

                                                $iLines.Add($iL.headerUdp)
                                                $iLines.Add($iL.target + "         : " + $targetDisplay)
                                                $iLines.Add($iL.protocol + "       : UDP")
                                                $iLines.Add($iL.duration + "       : " + ("{0:F1}" -f $totalTimeSec) + " sec")
                                                $iLines.Add($iL.transfer + "   : " + $totTransferStr)
                                                $iLines.Add($iL.avgBw + " : " + ("{0:F2}" -f $avg) + " Mbps")
                                                $iLines.Add($iL.maxMinBw + "   : " + ("{0:F2}" -f $maxBw) + " Mbps / " + ("{0:F2}" -f $minBw) + " Mbps")
                                                $iLines.Add($iL.jitterAvg + "   : " + ("{0:F3}" -f $avgJit) + " ms")
                                                $iLines.Add($iL.jitterMax + "   : " + ("{0:F3}" -f $maxJit) + " ms")
                                                if ($hasUdpLossInfo) {
                                                    $iLines.Add($iL.lostPackets + "     : " + $udpLostPackets + " / " + $udpTotalPackets + " パケット")
                                                    $iLines.Add($iL.lossRate + "     : " + ("{0:F2}" -f $udpLossPercent) + " %")
                                                }
                                                $iLines.Add($iL.thresh + "           : " + $bwThresh + " Mbps")
                                                $iLines.Add($iL.above + " (" + $bwThresh + " Mbps~) : " + $aboveCount + " / " + $abovePct + " %")
                                                $iLines.Add($iL.below + " (~" + $bwThresh + " Mbps) : " + $belowCount + " / " + $belowPct + " %")
                                                $iLines.Add($iL.evalTitle + "           : " + $evalUdp)
                                                $iLines.Add($iL.footer)
                                            }
                                            else {
                                                # ─── TCP モード専用サマリー ───
                                                $evalTcp = if ($hasTcpRetr -and $tcpRetransmits -gt 0) {
                                                    $iL.evalTcpWarn + " ($tcpRetransmits 回)"
                                                }
                                                else {
                                                    $iL.evalTcpGood
                                                }

                                                $iLines.Add($iL.headerTcp)
                                                $iLines.Add($iL.target + "         : " + $targetDisplay)
                                                $iLines.Add($iL.protocol + "       : TCP")
                                                $iLines.Add($iL.duration + "       : " + ("{0:F1}" -f $totalTimeSec) + " sec")
                                                $iLines.Add($iL.transfer + "   : " + $totTransferStr)
                                                $iLines.Add($iL.avgBw + " : " + ("{0:F2}" -f $avg) + " Mbps")
                                                $iLines.Add($iL.median + "             : " + ("{0:F2}" -f $median) + " Mbps")
                                                $iLines.Add($iL.maxBw + "             : " + ("{0:F2}" -f $maxBw) + " Mbps")
                                                $iLines.Add($iL.minBw + "             : " + ("{0:F2}" -f $minBw) + " Mbps")
                                                $iLines.Add($iL.stdDev + "           : " + ("{0:F2}" -f $stdDev) + " Mbps")
                                                if ($hasTcpRetr) {
                                                    $iLines.Add($iL.tcpRetr + "      : " + $tcpRetransmits + " 回")
                                                }
                                                $iLines.Add($iL.thresh + "           : " + $bwThresh + " Mbps")
                                                $iLines.Add($iL.above + " (" + $bwThresh + " Mbps~) : " + $aboveCount + " / " + $abovePct + " %")
                                                $iLines.Add($iL.below + " (~" + $bwThresh + " Mbps) : " + $belowCount + " / " + $belowPct + " %")
                                                $iLines.Add($iL.evalTitle + "           : " + $evalTcp)
                                                $iLines.Add($iL.footer)
                                            }

                                            $summaryText = ($iLines -join "`r`n")
                                            Write-IperfLogs $summaryText
                                            $sync.IperfState.Output += "`r`n" + $summaryText + "`r`n"
                                        }
                                        else {
                                            # 有効なデータ転送行が1件も得られなかった（コネクションエラー・相手停止・タイムアウト等）
                                            $isConnError = $false
                                            if ($logContent) {
                                                foreach ($l in $logContent) {
                                                    if ($l -match 'error\s*-\s*unable to connect|Connection refused|Connection reset|Timed out|No route to host|unable to receive control message|unable to resolve|interrupt\s*-') {
                                                        $isConnError = $true
                                                        break
                                                    }
                                                }
                                            }

                                            # コネクションエラーまたは完全失敗の場合、今回の実行ブロックをファイルから自動ロールバック
                                            if ($isConnError -or $sync.IperfState.StopRequested -or ($bwValues.Count -eq 0)) {
                                                try {
                                                    if ($preExecLines -and $preExecLines.Count -gt 0) {
                                                        # 過去の正常ログが存在する場合は、今回の失敗分を除去して過去ログのみで上書き再保存
                                                        [System.IO.File]::WriteAllLines($primaryLogFile, $preExecLines, [System.Text.Encoding]::UTF8)
                                                    }
                                                    else {
                                                        # 過去ログが元々存在しなかった（初回実行でエラー）場合はファイルごと安全に削除
                                                        if (Test-Path $primaryLogFile) { Remove-Item $primaryLogFile -Force -ErrorAction SilentlyContinue }
                                                    }
                                                    $nowTs = Get-Date -Format "HH:mm:ss"
                                                    $cleanMsg = "`r`n[$nowTs] ⚠️ コネクションエラー（接続失敗）が検知されたため、この失敗試行のログは自動削除されました。`r`n"
                                                    $sync.IperfState.Output += $cleanMsg
                                                }
                                                catch {}
                                            }
                                        }
                                    }
                                    catch {
                                        $summaryErr = "Summary calculation error: $($_.Exception.Message)"
                                        Write-IperfLogs $summaryErr
                                    }
                                    Write-IperfLogs "`r`n"
                                    $sync.IperfState.Running = $false
                                    $sync.IperfState.Process = $null
                                    $sync.IperfState.StopRequested = $false
                                }
                            }
                            
                            # 新しいスレッドで実行
                            $reportsDir = Join-Path $syncHash.PSScriptRoot "..\Reports"
                            if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }
                            $ps = [powershell]::Create().AddScript($iperfTaskScript).AddArgument($iperfExe).AddArgument($targetIp).AddArgument($duration).AddArgument($safeOpts).AddArgument($syncHash).AddArgument($syncHash.SessionDir).AddArgument($bwThreshMbps).AddArgument($reportsDir)
                            # 終わったら Start-BackgroundScript 側で片付けられるよう一覧に登録する (以前は作りっぱなしで実行のたびにメモリが残った)
                            $null = $script:AsyncHttpJobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke() })
                            
                            # Initial response
                            Write-JsonResponse $response @{ status = "started"; command = "iperf3 (Starting)" }
                        }
                        else {
                            Write-JsonResponse $response @{ error = "iperf3.exe not found on server" } 404
                        }
                    }
                    else {
                        Write-JsonResponse $response @{ error = "Missing ip" } 400
                    }
                }
                elseif ($urlPath -eq "/api/iperf/log" -and $method -eq "GET") {
                    # Latest device-specific iperf log download endpoint
                    $targetIp = $request.QueryString["ip"]
                    $targetSafeIp = if ($targetIp) { $targetIp -replace '[\\/:*?"<>|]', '_' } else { "" }
                    $primaryLog = if ($targetSafeIp) {
                        Join-Path $syncHash.SessionDir "iperf_${targetSafeIp}.log"
                    }
                    else {
                        Get-ChildItem -Path $syncHash.SessionDir -Filter "iperf_*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
                    }
                    if ($primaryLog -and (Test-Path $primaryLog)) {
                        try {
                            $rawL = [System.IO.File]::ReadAllLines($primaryLog, [System.Text.Encoding]::UTF8)
                            $cleanL = Clean-IperfLogLines $rawL
                            if ($cleanL.Count -gt 0) {
                                if ($cleanL.Count -lt $rawL.Count) {
                                    [System.IO.File]::WriteAllLines($primaryLog, $cleanL, [System.Text.Encoding]::UTF8)
                                }
                            }
                        }
                        catch {}

                        $logBytes = [System.IO.File]::ReadAllBytes($primaryLog)
                        $filename = [System.IO.Path]::GetFileName($primaryLog)
                        $response.ContentType = "text/plain; charset=utf-8"
                        $response.AddHeader("Content-Disposition", "attachment; filename=`"$filename`"")
                        $response.ContentLength64 = $logBytes.Length
                        $response.OutputStream.Write($logBytes, 0, $logBytes.Length)
                        $response.Close()
                    }
                    else {
                        Write-JsonResponse $response @{ error = "No iperf log found" } 404
                    }
                }
                elseif ($urlPath -eq "/api/iperf/server/status" -and $method -eq "GET") {
                    $st = $syncHash.IperfServerState
                    Write-JsonResponse $response @{
                        status    = "success"
                        running   = $st.Running
                        port      = $st.Port
                        startTime = $st.StartTime
                        output    = $st.Output
                        logFile   = $st.LogFile
                    }
                }
                elseif ($urlPath -eq "/api/iperf/server/start" -and $method -eq "POST") {
                    if ($syncHash.IperfServerState.Running) {
                        Write-JsonResponse $response @{ error = "iperf3 server is already running" } 409
                        continue
                    }

                    $bodyStr = ""
                    try {
                        $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                        $bodyStr = $reader.ReadToEnd()
                    }
                    catch {}

                    # 注意: $port は監視画面のHTTPポート (8081) を保持するスクリプト全体の変数のため別名にする
                    # (以前は $port = 5201 で上書きし、iperf3 サーバー起動後は画面からの操作が「外部サイトからの要求」として拒否されていた)
                    $iperfSrvPort = 5201
                    if ($bodyStr) {
                        try {
                            $json = $bodyStr | ConvertFrom-Json
                            if ($json.port -and [int]$json.port -ge 1 -and [int]$json.port -le 65535) { $iperfSrvPort = [int]$json.port }
                        }
                        catch {}
                    }

                    # iperf3.exe の場所を探す
                    $iperfExe = Join-Path $syncHash.PSScriptRoot "iperf3.exe"
                    if (-not (Test-Path $iperfExe)) {
                        $iperfExe = Join-Path $syncHash.PSScriptRoot "iperf3.18_64\iperf3.exe"
                    }
                    if (-not (Test-Path $iperfExe)) {
                        $iperfExe = Get-Command iperf3 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
                    }

                    if ($iperfExe -and (Test-Path $iperfExe)) {
                        $serverLogFile = Join-Path $syncHash.SessionDir "iperf_server.log"
                        $tsStart = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                        
                        $syncHash.IperfServerState.Running = $true
                        $syncHash.IperfServerState.Port = $iperfSrvPort
                        $syncHash.IperfServerState.StartTime = $tsStart
                        $syncHash.IperfServerState.LogFile = $serverLogFile
                        $syncHash.IperfServerState.Output = "=== iperf3 Server Started at $tsStart on Port $iperfSrvPort ===`n"

                        # Audit Log
                        Log-Audit -action "IPERF_SERVER_START" -target "Port $iperfSrvPort" -details "iperf3 server started" -clientIp $request.RemoteEndPoint.Address.ToString() -reportsDirectory $ReportsDir

                        # バックグラウンド実行
                        $serverTaskScript = {
                            param($exe, $srvPort, $sync, $sessDir, $logPath)
                            $tmpLiveLog = Join-Path ([System.IO.Path]::GetTempPath()) "ndm_iperf_srv_tmp_$([guid]::NewGuid().ToString('N')).log"

                            function Write-ServerLog([string]$text) {
                                try {
                                    $text | Out-File -FilePath $logPath -Append -Encoding UTF8
                                }
                                catch {}
                            }

                            try {
                                Write-ServerLog "-----------------------------------------------------------"
                                Write-ServerLog "=== iperf3 Server Session Started at $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) ==="
                                Write-ServerLog "Port: $srvPort"
                                Write-ServerLog "Command: iperf3 -s -p $srvPort -i 1 --forceflush"
                                Write-ServerLog "-----------------------------------------------------------"

                                $cmdArgs = "-s -p $srvPort -i 1 --forceflush"
                                $cmdArguments = "/c `"`"$exe`" $cmdArgs > `"$tmpLiveLog`" 2>&1`""

                                $pInfo = New-Object System.Diagnostics.ProcessStartInfo
                                $pInfo.FileName = "cmd.exe"
                                $pInfo.Arguments = $cmdArguments
                                $pInfo.UseShellExecute = $false
                                $pInfo.CreateNoWindow = $true

                                $proc = New-Object System.Diagnostics.Process
                                $proc.StartInfo = $pInfo
                                $null = $proc.Start()
                                $sync.IperfServerState.Process = $proc

                                # ファイル生成待機
                                $waited = 0
                                while (-not (Test-Path $tmpLiveLog) -and $waited -lt 3000 -and -not $proc.HasExited) {
                                    Start-Sleep -Milliseconds 100
                                    $waited += 100
                                }

                                [long]$byteOffset = 0
                                while (-not $proc.HasExited -and $sync.IperfServerState.Running) {
                                    Start-Sleep -Milliseconds 300
                                    if (-not (Test-Path $tmpLiveLog)) { continue }
                                    try {
                                        $fs = New-Object System.IO.FileStream(
                                            $tmpLiveLog,
                                            [System.IO.FileMode]::Open,
                                            [System.IO.FileAccess]::Read,
                                            [System.IO.FileShare]::ReadWrite)
                                        $fileLen = $fs.Length
                                        if ($fileLen -gt $byteOffset) {
                                            $null = $fs.Seek($byteOffset, [System.IO.SeekOrigin]::Begin)
                                            $readLen = [int]($fileLen - $byteOffset)
                                            $buf = New-Object byte[] $readLen
                                            $read = $fs.Read($buf, 0, $readLen)
                                            $byteOffset += $read
                                            $chunk = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
                                            foreach ($ln in ($chunk -split "`n")) {
                                                $trimmed = $ln.TrimEnd("`r")
                                                if ($trimmed) {
                                                    $nowTs = Get-Date -Format "HH:mm:ss"
                                                    $fl = "[$nowTs] $trimmed"
                                                    $sync.IperfServerState.Output += $fl + "`n"
                                                    Write-ServerLog $fl
                                                }
                                            }
                                        }
                                        $fs.Close()
                                    }
                                    catch { try { $fs.Close() } catch {} }
                                }

                                # 残りデータの吸い出し
                                Start-Sleep -Milliseconds 200
                                if (Test-Path $tmpLiveLog) {
                                    try {
                                        $fs = New-Object System.IO.FileStream(
                                            $tmpLiveLog,
                                            [System.IO.FileMode]::Open,
                                            [System.IO.FileAccess]::Read,
                                            [System.IO.FileShare]::ReadWrite)
                                        $fileLen = $fs.Length
                                        if ($fileLen -gt $byteOffset) {
                                            $null = $fs.Seek($byteOffset, [System.IO.SeekOrigin]::Begin)
                                            $readLen = [int]($fileLen - $byteOffset)
                                            $buf = New-Object byte[] $readLen
                                            $read = $fs.Read($buf, 0, $readLen)
                                            $chunk = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
                                            foreach ($ln in ($chunk -split "`n")) {
                                                $trimmed = $ln.TrimEnd("`r")
                                                if ($trimmed) {
                                                    $nowTs = Get-Date -Format "HH:mm:ss"
                                                    $fl = "[$nowTs] $trimmed"
                                                    $sync.IperfServerState.Output += $fl + "`n"
                                                    Write-ServerLog $fl
                                                }
                                            }
                                        }
                                        $fs.Close()
                                    }
                                    catch { try { $fs.Close() } catch {} }
                                }

                                if (-not $proc.HasExited) {
                                    try { & taskkill /F /T /PID $proc.Id 2>$null } catch {}
                                    try { $proc.Kill() } catch {}
                                }
                            }
                            catch {
                                $errMsg = "Error during server execution: $($_.Exception.Message)"
                                $sync.IperfServerState.Output += $errMsg + "`n"
                                Write-ServerLog $errMsg
                            }
                            finally {
                                try { if (Test-Path $tmpLiveLog) { Remove-Item $tmpLiveLog -Force -ErrorAction SilentlyContinue } } catch {}
                                $sync.IperfServerState.Running = $false
                                $sync.IperfServerState.Process = $null
                                $tsEnd = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                                Write-ServerLog "=== iperf3 Server Stopped at $tsEnd ==="
                                Write-ServerLog "-----------------------------------------------------------"
                            }
                        }

                        $serverPowerShell = [PowerShell]::Create().AddScript($serverTaskScript)
                        $null = $serverPowerShell.AddArgument($iperfExe)
                        $null = $serverPowerShell.AddArgument($iperfSrvPort)
                        $null = $serverPowerShell.AddArgument($syncHash)
                        $null = $serverPowerShell.AddArgument($syncHash.SessionDir)
                        $null = $serverPowerShell.AddArgument($serverLogFile)
                        $null = $serverPowerShell.BeginInvoke()

                        Write-JsonResponse $response @{ status = "success"; port = $iperfSrvPort; message = "iperf3 server started" }
                    }
                    else {
                        Write-JsonResponse $response @{ error = "iperf3.exe not found on server" } 404
                    }
                }
                elseif ($urlPath -eq "/api/iperf/server/stop" -and $method -eq "POST") {
                    if ($syncHash.IperfServerState.Running) {
                        $syncHash.IperfServerState.Running = $false
                        $srvProc = $syncHash.IperfServerState.Process
                        if ($null -ne $srvProc -and -not $srvProc.HasExited) {
                            try { & taskkill /F /T /PID $srvProc.Id 2>$null } catch {}
                            try { $srvProc.Kill() } catch {}
                        }
                        $nowTs = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                        $syncHash.IperfServerState.Output += "=== iperf3 Server Stopped by user at $nowTs ===`n"
                        Log-Audit -action "IPERF_SERVER_STOP" -target "Server" -details "iperf3 server stopped" -clientIp $request.RemoteEndPoint.Address.ToString() -reportsDirectory $ReportsDir
                        Write-JsonResponse $response @{ status = "stopped" }
                    }
                    else {
                        Write-JsonResponse $response @{ status = "not_running" }
                    }
                }
                elseif ($urlPath -eq "/api/iperf/server/log" -and $method -eq "GET") {
                    $serverLog = Join-Path $syncHash.SessionDir "iperf_server.log"
                    if ($serverLog -and (Test-Path $serverLog)) {
                        $logBytes = [System.IO.File]::ReadAllBytes($serverLog)
                        $filename = [System.IO.Path]::GetFileName($serverLog)
                        $response.ContentType = "text/plain; charset=utf-8"
                        $response.AddHeader("Content-Disposition", "attachment; filename=`"$filename`"")
                        $response.ContentLength64 = $logBytes.Length
                        $response.OutputStream.Write($logBytes, 0, $logBytes.Length)
                        $response.Close()
                    }
                    else {
                        Write-JsonResponse $response @{ error = "No iperf server log found" } 404
                    }
                }
                elseif ($urlPath -eq "/api/iperf/server/clear-log" -and $method -eq "POST") {
                    $syncHash.IperfServerState.Output = ""
                    Write-JsonResponse $response @{ status = "cleared" }
                }
                elseif ($urlPath -eq "/api/device/upload-image" -and $method -eq "POST") {
                    $ip = $request.Headers["X-Device-IP"]
                    $filename = $request.Headers["X-File-Name"]
                    $maxUploadBytes = 10MB
                    # 画面側は日本語のファイル名を送れるよう URL エンコードして送ってくるので元に戻す
                    if ($filename) { try { $filename = [System.Uri]::UnescapeDataString($filename) } catch {} }
                    $uploadExt = if ($filename) { [System.IO.Path]::GetExtension([System.IO.Path]::GetFileName($filename)).ToLower() } else { "" }
                    if (-not ($ip -and $filename)) {
                        Write-JsonResponse $response @{ error = "Missing IP or Filename headers" } 400
                    }
                    elseif ($uploadExt -notin @(".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".ico")) {
                        # HTML や SVG などを置けると、監視画面と同じ場所からスクリプトが動いてしまうため画像形式のみ許可
                        Write-JsonResponse $response @{ error = "画像ファイル (png / jpg / gif / webp / bmp / ico) のみアップロードできます" } 415
                    }
                    elseif ($request.ContentLength64 -gt $maxUploadBytes) {
                        Write-JsonResponse $response @{ error = "画像のサイズが大きすぎます (上限 10MB)" } 413
                    }
                    else {
                        $uploadsDir = Join-Path $publicDir "uploads"
                        if (-not (Test-Path $uploadsDir)) { New-Item -ItemType Directory -Path $uploadsDir | Out-Null }

                        # IP やファイル名に「..\」などが入っていても uploads フォルダの外に書き込まないよう、使える文字だけにする
                        $safeIp = $ip -replace '[^A-Za-z0-9._-]', '_'
                        $safeFilename = [System.IO.Path]::GetFileName($filename) -replace '[\\/:*?"<>|\x00-\x1f%#]', '_'
                        $destPath = Join-Path $uploadsDir "$($safeIp)_$safeFilename"

                        $inputStream = $request.InputStream
                        $fileStream = [System.IO.File]::Create($destPath)
                        $totalBytes = 0
                        $tooLarge = $false
                        try {
                            $buffer = New-Object byte[] 64kb
                            while (($bytesRead = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                                $totalBytes += $bytesRead
                                if ($totalBytes -gt $maxUploadBytes) { $tooLarge = $true; break }
                                $fileStream.Write($buffer, 0, $bytesRead)
                            }
                        }
                        finally {
                            $fileStream.Close()
                        }

                        if ($tooLarge) {
                            try { Remove-Item -LiteralPath $destPath -Force -ErrorAction SilentlyContinue } catch {}
                            Write-JsonResponse $response @{ error = "画像のサイズが大きすぎます (上限 10MB)" } 413
                        }
                        else {
                            $webPath = "/uploads/" + [System.Uri]::EscapeDataString("$($safeIp)_$safeFilename")
                            Write-JsonResponse $response @{ status = "success"; path = $webPath }
                        }
                    }
                }
                elseif ($urlPath -eq "/api/scan" -and $method -eq "GET") {
                    $startIp = $request.QueryString["start"]
                    $endIp = $request.QueryString["end"]
                    
                    if ($startIp -and $endIp) {
                        $startParts = $startIp.Split('.')
                        $endParts = $endIp.Split('.')
                        
                        $ipv4Regex = '^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
                        if ($startIp -notmatch $ipv4Regex -or $endIp -notmatch $ipv4Regex) {
                            # 末尾が 256 以上 (例: 10.0.0.99999) だと、その数だけ同時に Ping を送ってしまうため形式を厳密に検査
                            Write-JsonResponse $response @{ error = "Invalid IP address format (start/end)" } 400
                            continue
                        }
                        $startBase = "$($startParts[0]).$($startParts[1]).$($startParts[2])"
                        $endBase = "$($endParts[0]).$($endParts[1]).$($endParts[2])"
                        if ($startBase -ne $endBase) {
                            # 以前は終了側の上位3オクテットを無視して開始側の範囲だけを黙って調べていた
                            Write-JsonResponse $response @{ error = "Scan range must be within the same /24 network ($startBase.x)" } 400
                            continue
                        }

                        if ($startParts.Count -eq 4 -and $endParts.Count -eq 4) {
                            $base = $startBase
                            $startNum = [int]$startParts[3]
                            $endNum = [int]$endParts[3]
                            # 開始と終了が逆に入力された場合は入れ替える (以前は結果が常に0件になった)
                            if ($startNum -gt $endNum) { $tmpNum = $startNum; $startNum = $endNum; $endNum = $tmpNum }
                            $respRef = $response

                            Start-BackgroundScript -ArgumentList @($respRef, $base, $startNum, $endNum) -ScriptBlock {
                                param($respRef, $base, $startNum, $endNum)
                                try {
                                    $activeIps = [System.Collections.Generic.List[string]]::new()
                                    $pingTasks = @()
                                    for ($i = $startNum; $i -le $endNum; $i++) {
                                        $target = "$base.$i"
                                        $p = New-Object System.Net.NetworkInformation.Ping
                                        $pingTasks += @{ IP = $target; Ping = $p; Task = $p.SendPingAsync($target, 400) }
                                    }
                                    try {
                                        $taskArr = [System.Threading.Tasks.Task[]]($pingTasks | ForEach-Object { $_.Task })
                                        if ($taskArr.Count -gt 0) {
                                            $null = [System.Threading.Tasks.Task]::WaitAll($taskArr, 1500)
                                        }
                                    }
                                    catch {}
                                    foreach ($pt in $pingTasks) {
                                        try {
                                            if ($pt.Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and $pt.Task.Result.Status -eq 'Success') {
                                                $activeIps.Add($pt.IP)
                                            }
                                        }
                                        catch {}
                                        try { $pt.Ping.Dispose() } catch {}
                                    }

                                    Write-JsonResponse $respRef @{ activeIps = $activeIps.ToArray() }
                                }
                                catch {
                                    Write-JsonResponse $respRef @{ error = "Scan failed: $($_.Exception.Message)" } 500
                                }
                            }
                            continue
                        }
                        else {
                            Write-JsonResponse $response @{ error = "Invalid IP range format" } 400
                        }
                    }
                    else {
                        Write-JsonResponse $response @{ error = "Missing start or end parameters" } 400
                    }
                }
                elseif ($urlPath -eq "/api/traceroute" -and $method -eq "GET") {
                    $target = $request.QueryString["target"]
                    if (-not [string]::IsNullOrWhiteSpace($target)) {
                        $target = $target.Trim()
                        $ipRegex = '^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
                        if ($target -notmatch $ipRegex) {
                            Write-JsonResponse $response @{ error = "Invalid target IP address" } 400
                            continue
                        }

                        $respRef = $response
                        $targetRef = $target
                        Start-BackgroundScript -ArgumentList @($respRef, $targetRef) -ScriptBlock {
                            param($respRef, $targetRef)
                            try {
                                # 最大 20 区間まで調べる (応答しない区間が続いても 30 秒ほどで終わる長さ)
                                $traceOutput = tracert -d -h 20 -w 400 $targetRef
                                $hops = [System.Collections.Generic.List[hashtable]]::new()
                                foreach ($line in $traceOutput) {
                                    # 先頭がホップ番号の行だけを対象にする
                                    # (英語版Windowsでは1行目 "Tracing route to 8.8.8.8 ..." の宛先IPが最初のホップとして誤って記録されていた)
                                    if ($line -notmatch '^\s*\d+\s') { continue }
                                    $hopIp = if ($line -match '(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})') { $matches[1] } else { $null }
                                    # 3 回の計測のうち最後に得られた時間を代表値にする ("<1 ms" は 1 ms 未満)
                                    $times = [regex]::Matches($line, '(<?\d+)\s*ms')
                                    $latency = if ($times.Count -gt 0) { $times[$times.Count - 1].Groups[1].Value + " ms" } else { "" }
                                    $hops.Add(@{ ip = $hopIp; latency = $latency })
                                }
                                # 末尾の「応答なし」は表示しても意味がないので取り除く
                                while ($hops.Count -gt 0 -and $null -eq $hops[$hops.Count - 1].ip) { $hops.RemoveAt($hops.Count - 1) }

                                $reached = ($hops.Count -gt 0 -and $hops[$hops.Count - 1].ip -eq $targetRef)
                                # tracert では届かなくても Ping が通るなら、宛先まで到達できているものとして末尾に加える
                                if (-not $reached) {
                                    $pingRes = Test-Connection -ComputerName $targetRef -Count 1 -Quiet -ErrorAction SilentlyContinue
                                    if ($pingRes) {
                                        $hops.Add(@{ ip = $targetRef; latency = "" })
                                        $reached = $true
                                    }
                                }

                                Write-JsonResponse $respRef @{ hops = $hops.ToArray(); reached = $reached }
}
                            catch {
                                Write-JsonResponse $respRef @{ error = "Traceroute failed: $($_.Exception.Message)" } 500
                            }
                        }
                        continue
                    }
                    else {
                        Write-JsonResponse $response @{ error = "Missing target parameter" } 400
                    }
                }
                elseif ($urlPath -eq "/api/email/test" -and $method -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $jsonBody = $reader.ReadToEnd()
                    $payload = $jsonBody | ConvertFrom-Json
                    
                    $sHost = if ($payload.smtpHost) { [string]$payload.smtpHost } else { $syncHash.SmtpHost }
                    $sPort = if ($null -ne $payload.smtpPort) { [int]$payload.smtpPort } else { $syncHash.SmtpPort }
                    $sSsl = if ($null -ne $payload.smtpSsl) { [bool]$payload.smtpSsl } else { $syncHash.SmtpSsl }
                    $sUser = if ($payload.smtpUser) { [string]$payload.smtpUser } else { $syncHash.SmtpUser }
                    $sPass = if ($payload.smtpPass -and [string]$payload.smtpPass -ne "********") { [string]$payload.smtpPass } else { $syncHash.SmtpPass }
                    $sFrom = if ($payload.smtpFrom) { [string]$payload.smtpFrom } else { $syncHash.SmtpFrom }
                    $sTo = if ($payload.smtpTo) { [string]$payload.smtpTo } else { $syncHash.SmtpTo }
                    $clientIp = $request.RemoteEndPoint.Address.ToString()
                    $repDir = $ReportsDir
                    $respRef = $response

                    Start-BackgroundScript -ArgumentList @($respRef, $sHost, $sPort, $sSsl, $sUser, $sPass, $sFrom, $sTo, $clientIp, $repDir) -ScriptBlock {
                        param($respRef, $sHost, $sPort, $sSsl, $sUser, $sPass, $sFrom, $sTo, $clientIp, $repDir)
                        try {
                            $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                            $subj = "【テスト通知】ネットワーク機器監視システム (SMTPテスト)"
                            $body = "これはネットワーク機器監視システムからのテスト通知メールです。`n送信日時: $ts`n正常にSMTPメールサーバーと通信できています。"
                            
                            $sent = Send-EmailNotification -smtpHost $sHost -smtpPort $sPort -useSsl $sSsl -smtpUser $sUser -smtpPass $sPass -from $sFrom -to $sTo -subject $subj -body $body
                            if ($sent) {
                                Log-Audit -action "EMAIL_TEST" -target $sTo -details "Test email sent successfully via $sHost" -clientIp $clientIp -reportsDirectory $repDir
                                Write-JsonResponse $respRef @{ status = "success"; message = "Test email sent successfully" }
                            }
                            else {
                                Write-JsonResponse $respRef @{ error = "Failed to send email. Check SMTP settings and firewall." } 500
                            }
                        }
                        catch {
                            Write-JsonResponse $respRef @{ error = "Email test error: $($_.Exception.Message)" } 500
                        }
                    }
                    continue
                }
                elseif ($urlPath -eq "/api/syslog" -and $method -eq "GET") {
                    $logs = @()
                    [System.Threading.Monitor]::Enter($syncHash.SyslogQueue.SyncRoot)
                    try {
                        $logs = $syncHash.SyslogQueue.ToArray()
                    }
                    finally {
                        [System.Threading.Monitor]::Exit($syncHash.SyslogQueue.SyncRoot)
                    }
                    Write-JsonResponse $response @{
                        logs        = $logs
                        enabled     = [bool]$syncHash.SyslogEnabled
                        listenPort  = [int]$syncHash.SyslogListenPort
                        listenError = [string]$syncHash.SyslogListenError
                        trapListenPort  = [int]$syncHash.TrapListenPort
                        trapListenError = [string]$syncHash.TrapListenError
}
                }
                elseif ($urlPath -eq "/api/syslog/clear" -and $method -eq "POST") {
                    [System.Threading.Monitor]::Enter($syncHash.SyslogQueue.SyncRoot)
                    try {
                        $syncHash.SyslogQueue.Clear()
                    }
                    finally {
                        [System.Threading.Monitor]::Exit($syncHash.SyslogQueue.SyncRoot)
                    }
                    Log-Audit -action "SYSLOG_CLEAR" -target "SyslogQueue" -details "Syslog buffer cleared" -clientIp $request.RemoteEndPoint.Address.ToString() -reportsDirectory $ReportsDir
                    Write-JsonResponse $response @{ status = "success" }
                }
                elseif ($urlPath -eq "/api/audit-logs" -and $method -eq "GET") {
                    $auditFile = Join-Path $ReportsDir "audit.log"
                    $lines = @()
                    if (Test-Path $auditFile) {
                        try {
                            $all = [System.IO.File]::ReadAllLines($auditFile, [System.Text.Encoding]::UTF8)
                            $lines = @($all | Select-Object -Last 200)
                            [Array]::Reverse($lines)
                        }
                        catch {}
                    }
                    Write-JsonResponse $response @{ logs = $lines }
                }
                elseif ($urlPath -eq "/api/system/cleanup-reports" -and $method -eq "POST") {
                    $retDays = $syncHash.LogRetentionDays
                    try {
                        $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                        $jsonBody = $reader.ReadToEnd()
                        if (-not [string]::IsNullOrWhiteSpace($jsonBody)) {
                            $payload = $jsonBody | ConvertFrom-Json
                            if ($null -ne $payload.retentionDays) {
                                $retDays = [int]$payload.retentionDays
                            }
                        }
                    }
                    catch {}

                    if ($retDays -le 0) { $retDays = 30 } # 手動クリーンアップで0の場合は安全のため30日以上前を対象
                    $purgeRes = Invoke-PurgeOldReports -reportsDirectory $ReportsDir -retentionDays $retDays -activeSessionDir $syncHash.SessionDir
                    Log-Audit -action "CLEANUP_REPORTS" -target "Reports" -details "Manual cleanup executed (Retention: $retDays days). Deleted $($purgeRes.DeletedCount) sessions, freed $($purgeRes.FreedMb) MB." -clientIp $request.RemoteEndPoint.Address.ToString() -reportsDirectory $ReportsDir
                    Write-JsonResponse $response @{
                        status        = "success"
                        deletedCount  = $purgeRes.DeletedCount
                        freedMb       = $purgeRes.FreedMb
                        retentionDays = $retDays
                        details       = $purgeRes.Details
                    }
                }
                elseif ($urlPath -eq "/api/web-check" -and $method -eq "GET") {
                    $targetUrl = $request.QueryString["url"]
                    if ($targetUrl) {
                        # 応答の遅いURLだと最大4秒待つため、HTTP受付ループを止めないよう別スレッドで実行
                        Start-BackgroundScript -ArgumentList @($response, $targetUrl) -ScriptBlock {
                            param($response, $targetUrl)
                            try {
                                $res = Check-WebAndSslEndpoint -url $targetUrl
                                Write-JsonResponse $response $res
                            }
                            catch {
                                Write-JsonResponse $response @{ error = "Web check failed: $($_.Exception.Message)" } 500
                            }
                        }
                    }
                    else {
                        Write-JsonResponse $response @{ error = "Missing url" } 400
                    }
                }
                elseif ($urlPath -eq "/api/config-backup/run" -and $method -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $jsonBody = $reader.ReadToEnd()
                    $payload = $jsonBody | ConvertFrom-Json
                    $ip = $payload.ip
                    
                    if ($ip) {
                        $configsDir = Join-Path $ReportsDir "Configs"
                        if (-not (Test-Path $configsDir)) { New-Item -ItemType Directory -Path $configsDir -Force | Out-Null }
                        $tsStr = (Get-Date).ToString("yyyyMMdd_HHmmss")
                        $safeIp = $ip -replace '[\\/:*?"<>|]', '_'
                        $outFile = Join-Path $configsDir "${safeIp}_${tsStr}.txt"
                        
                        # Generate config snapshot (SNMP system metadata, interface details, and running parameters)
                        $devName = if ($syncHash.DeviceName.ContainsKey($ip)) { $syncHash.DeviceName[$ip] } else { $ip }
                        $vendor = if ($syncHash.VendorContact.ContainsKey($ip)) { $syncHash.VendorContact[$ip] } else { "N/A" }
                        $snmpD = if ($syncHash.SnmpDetail.ContainsKey($ip)) { $syncHash.SnmpDetail[$ip] } else { @{} }
                        
                        $cfgText = @"
================================================================================
 Network Device Configuration & Inventory Snapshot
 Device: $devName ($ip)
 Timestamp: $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
 Vendor Contact: $vendor
================================================================================
[SYSTEM_INFORMATION]
Hostname: $devName
IP Address: $ip
MAC Address: $(if ($syncHash.Mac.ContainsKey($ip)) { $syncHash.Mac[$ip] } else { "Unknown" })
Device Type: $(if ($syncHash.DeviceType.ContainsKey($ip)) { $syncHash.DeviceType[$ip] } else { "network" })
Vendor Contact: $vendor

[SNMP_CONFIGURATION]
SNMP Version: $(if ($syncHash.SnmpVersion.ContainsKey($ip)) { $syncHash.SnmpVersion[$ip] } else { "v2c" })
Community: $(if ($syncHash.Community.ContainsKey($ip)) { $syncHash.Community[$ip] } else { "public" })
Link Speed: $(if ($snmpD.speed) { $snmpD.speed } else { "N/A" })
WiFi Band: $(if ($snmpD.wifi) { $snmpD.wifi } else { "N/A" })

[INTERFACES & NEIGHBORS]
$(if ($snmpD.neighbors) { "Neighbors: " + ($snmpD.neighbors -join ", ") } else { "No LLDP/CDP neighbors detected." })
"@
                        [System.IO.File]::WriteAllText($outFile, $cfgText, [System.Text.Encoding]::UTF8)
                        Log-Audit -action "CONFIG_BACKUP" -target $ip -details "Configuration snapshot saved: $([System.IO.Path]::GetFileName($outFile))" -clientIp $request.RemoteEndPoint.Address.ToString() -reportsDirectory $ReportsDir
                        Write-JsonResponse $response @{ status = "success"; filename = [System.IO.Path]::GetFileName($outFile) }
                    }
                    else {
                        Write-JsonResponse $response @{ error = "Missing ip" } 400
                    }
                }
                elseif ($urlPath -eq "/api/config-backup/list" -and $method -eq "GET") {
                    $configsDir = Join-Path $ReportsDir "Configs"
                    $list = @()
                    if (Test-Path $configsDir) {
                        Get-ChildItem -Path $configsDir -Filter "*.txt" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object {
                            $parts = $_.BaseName -split '_'
                            $ipPart = if ($parts.Length -ge 3) { ($parts[0..($parts.Length - 3)]) -join '.' } else { $parts[0] }
                            $list += @{
                                filename  = $_.Name
                                ip        = $ipPart
                                timestamp = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
                                size      = "$([math]::Round($_.Length / 1024, 1)) KB"
                            }
                        }
                    }
                    Write-JsonResponse $response @{ backups = $list }
                }
                elseif ($urlPath -eq "/api/config-backup/diff" -and $method -eq "GET") {
                    $file1 = $request.QueryString["f1"]
                    $file2 = $request.QueryString["f2"]
                    $configsDir = Join-Path $ReportsDir "Configs"
                    $p1 = Join-Path $configsDir ([System.IO.Path]::GetFileName($file1))
                    $p2 = Join-Path $configsDir ([System.IO.Path]::GetFileName($file2))
                    
                    # f1/f2 が空だと Configs フォルダ自体を指してしまい、読み込みで例外になるためファイルであることも確認する
                    if ($file1 -and $file2 -and (Test-Path -LiteralPath $p1 -PathType Leaf) -and (Test-Path -LiteralPath $p2 -PathType Leaf)) {
                        $lines1 = [System.IO.File]::ReadAllLines($p1, [System.Text.Encoding]::UTF8)
                        $lines2 = [System.IO.File]::ReadAllLines($p2, [System.Text.Encoding]::UTF8)
                        
                        $diffResult = @()
                        $maxL = [math]::Max($lines1.Length, $lines2.Length)
                        for ($i = 0; $i -lt $maxL; $i++) {
                            $l1 = if ($i -lt $lines1.Length) { $lines1[$i] } else { "" }
                            $l2 = if ($i -lt $lines2.Length) { $lines2[$i] } else { "" }
                            if ($l1 -ne $l2) {
                                $diffResult += @{ line = ($i + 1); file1 = $l1; file2 = $l2; changed = $true }
                            }
                            else {
                                $diffResult += @{ line = ($i + 1); file1 = $l1; file2 = $l2; changed = $false }
                            }
                        }
                        Write-JsonResponse $response @{ diff = $diffResult }
                    }
                    else {
                        Write-JsonResponse $response @{ error = "Backup files not found" } 404
                    }
                }
                elseif ($urlPath -eq "/api/reports/export" -and $method -eq "GET") {
                    $period = if ($request.QueryString["period"]) { $request.QueryString["period"] } else { "today" }
                    $reportHtml = Generate-SessionReportHtml -sync $syncHash -period $period
                    $respBytes = [System.Text.Encoding]::UTF8.GetBytes($reportHtml)
                    $response.ContentType = "text/html; charset=utf-8"
                    $response.ContentLength64 = $respBytes.Length
                    $response.OutputStream.Write($respBytes, 0, $respBytes.Length)
                    $response.Close()
                }
                elseif ($urlPath -eq "/api/heartbeat") {
                    $syncHash.HasClientConnected = $true
                    $syncHash.LastClientActivity = [DateTime]::UtcNow
                    Write-JsonResponse $response @{ status = "alive"; time = [DateTime]::UtcNow.ToString("o") }
                }
                elseif ($urlPath -eq "/api/shutdown") {
                    # reason=unload は「ブラウザを閉じた・再読み込みした」ときに自動で送られる合図
                    # (「監視終了」ボタンからの明示的な終了には付かない)
                    $isUnloadSignal = ($request.QueryString["reason"] -eq "unload")
                    if ($isUnloadSignal -and $syncHash.AutoShutdownOnDisconnect -eq $false) {
                        # 無人運用モードでは、ブラウザを閉じても監視を続ける (以前はこの合図で終了していた)
                        Write-JsonResponse $response @{ status = "ignored"; message = "Unattended mode: keep running" }
                    }
                    else {
                        $syncHash.PendingShutdown = $true
                        # ページの再読み込み (F5) でも送られてくるため、すぐには止めず 10 秒待つ (その間に画面から通信があれば取り消す)
                        # 以前は 2 秒で、PC が重いときなどは再読み込みが間に合わず監視ごと終了していた
                        $waitSec = if ($isUnloadSignal) { 10 } else { 2 }
                        # 「監視終了」ボタンからの終了は、画面の定期通信が来ても取り消さない
                        if (-not $isUnloadSignal) { $syncHash.PendingShutdownForced = $true }
                        $syncHash.PendingShutdownTime = [DateTime]::UtcNow.AddSeconds($waitSec)
                        Write-JsonResponse $response @{ status = "success"; message = "Shutdown initiated" }
                        Write-Host "Shutdown signal received from browser." -ForegroundColor Yellow
                    }
                }
                elseif ($urlPath -eq "/api/health" -and $method -eq "GET") {
                    $nowUtc = [DateTime]::UtcNow
                    $uptimeSec = if ($syncHash.StartTime) { [int]($nowUtc - $syncHash.StartTime).TotalSeconds } else { 0 }
                    $hasPingLoop = ($null -ne $syncHash.LastPingLoopUtc)
                    $lastPing = if ($hasPingLoop) { $syncHash.LastPingLoopUtc } else { $nowUtc }
                    $pingAgeSec = if (-not $hasPingLoop -or $uptimeSec -lt 10) { 0.0 } else { [math]::Round(($nowUtc - $lastPing).TotalSeconds, 1) }
                    
                    # 起動後60秒以上経過していて、かつPingループが45秒以上止まっていれば異常
                    $isHealthy = $true
                    $msg = "OK"
                    if ($syncHash.StartTime -and ($nowUtc - $syncHash.StartTime).TotalSeconds -ge 60.0) {
                        if (-not $hasPingLoop -or $pingAgeSec -gt 45.0) {
                            $isHealthy = $false
                            $msg = "Ping runspace loop unresponsive (last seen: ${pingAgeSec}s ago)"
                        }
                    }

                    $healthData = @{
                        status           = if ($isHealthy) { "ok" } else { "unhealthy" }
                        message          = $msg
                        timestamp        = $nowUtc.ToString("o")
                        uptimeSec        = $uptimeSec
                        monitoredDevices = if ($syncHash.Devices) { $syncHash.Devices.Count } else { 0 }
                        lastPingLoopUtc  = $lastPing.ToString("o")
                        pingAgeSec       = $pingAgeSec
                        # 最後にログを保存できてからの秒数 (ドライブの書き込みが止まっていないかの目安)
                        diskWriteAgeSec  = if ($syncHash.LastDiskWriteUtc) { [math]::Round(($nowUtc - $syncHash.LastDiskWriteUtc).TotalSeconds, 1) } else { $null }
sessionDir       = $syncHash.SessionDir
                        sessionTimestamp = $syncHash.SessionTimestamp
                    }
                    $statusCode = if ($isHealthy) { 200 } else { 503 }
                    Write-JsonResponse $response $healthData $statusCode
                }
                elseif ($urlPath -eq "/api/snapshots/list" -and $method -eq "GET") {
                    $snapshots = Get-ConfigSnapshots -backupDir $syncHash.BackupDir
                    Write-JsonResponse $response @{ snapshots = $snapshots }
                }
                elseif ($urlPath -eq "/api/snapshots/restore" -and $method -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $payload = $reader.ReadToEnd() | ConvertFrom-Json
                    if ($null -eq $payload.fileName) {
                        Write-JsonResponse $response @{ error = "fileName is required" } 400
                    }
                    else {
                        $res = Restore-ConfigSnapshot -snapshotFileName $payload.fileName -backupDir $syncHash.BackupDir -targetDir $PSScriptRoot
                        if ($res.success) {
                            if ($res.restoredFile -eq "devices.json") {
                                try {
                                    $devJson = Join-Path $PSScriptRoot "devices.json"
                                    if (Test-Path $devJson) {
                                        $loadedDevs = Get-Content $devJson -Raw -Encoding UTF8 | ConvertFrom-Json
                                        [System.Threading.Monitor]::Enter($syncHash.DevicesLock)
                                        try {
                                            $restoredIps = [System.Collections.Generic.List[string]]::new()
                                            foreach ($d in $loadedDevs) {
                                                # 同じIPが複数行あると二重に監視・表示されるため最初の1件だけ使う
                                                if ($restoredIps.Contains(([string]$d.ip).Trim())) { continue }
                                                $rIp = Set-DeviceRecordInSyncHash $d
                                                if (-not $rIp) { continue }
                                                $restoredIps.Add($rIp)
                                                # 監視統計・履歴の器を用意 (復元で増えた機器も監視ループが扱えるように)
                                                if ($syncHash.IsMonitored[$rIp]) { Initialize-DeviceLog -ip $rIp }
                                            }
                                            $syncHash.Devices = $restoredIps.ToArray()
                                        }
                                        finally {
                                            [System.Threading.Monitor]::Exit($syncHash.DevicesLock)
                                        }
                                    }
                                }
                                catch {}
                            }
                            if ($res.restoredFile -eq "config.json") {
                                try {
                                    $cfgJsonPath = Join-Path $PSScriptRoot "config.json"
                                    if (Test-Path $cfgJsonPath) {
                                        Import-ConfigToSyncHash (Get-Content $cfgJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json)
                                    }
                                }
                                catch {}
                            }
                            Log-Audit -action "CONFIG_ROLLBACK" -target $payload.fileName -details "Restored configuration from snapshot: $($payload.fileName)" -clientIp $request.RemoteEndPoint.Address.ToString() -reportsDirectory $ReportsDir
                            Write-JsonResponse $response @{ status = "success"; message = "Restored from $($payload.fileName)"; restoredFile = $res.restoredFile }
                        }
                        else {
                            Write-JsonResponse $response @{ error = $res.error } 500
                        }
                    }
                }
                elseif ($urlPath -eq "/api/system/prerequisites" -and $method -eq "GET") {
                    $projRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
                    $diag = Test-SystemPrerequisites -projectRoot $projRoot
                    Write-JsonResponse $response $diag
                }
                elseif ($urlPath -eq "/api/system/install-module" -and $method -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $payload = $reader.ReadToEnd() | ConvertFrom-Json
                    $modName = if ($payload.module) { [string]$payload.module } else { "SNMP" }
                    
                    Write-Host "Installing PowerShell module '$modName' via API request..." -ForegroundColor Yellow
                    $installRes = Install-PrerequisiteModule -moduleName $modName
                    
                    if ($installRes.success) {
                        if ($modName -eq "SNMP") {
                            try {
                                $snmpModule = Get-Module -ListAvailable SNMP | Select-Object -First 1
                                if ($snmpModule) {
                                    Import-Module $snmpModule.Path -ErrorAction SilentlyContinue
                                    $mDir = Split-Path $snmpModule.Path
                                    $dPath = Join-Path $mDir "SharpSnmpLib.dll"
                                    if (Test-Path $dPath) { Add-Type -Path $dPath -ErrorAction SilentlyContinue }
                                }
                            }
                            catch {}
                        }
                        Log-Audit -action "MODULE_INSTALL" -target $modName -details "Installed PowerShell module: $modName" -clientIp $request.RemoteEndPoint.Address.ToString() -reportsDirectory $ReportsDir
                        Write-JsonResponse $response @{ status = "success"; message = "Module '$modName' successfully installed" }
                    }
                    else {
                        Write-JsonResponse $response @{ error = $installRes.error } 500
                    }
                }
                else {
                    Write-JsonResponse $response @{ error = "Not found" } 404
                }
            }
            catch {
                Write-JsonResponse $response @{ error = $_.Exception.Message } 500
            }
        }
        else {
            # Static files
            if ($urlPath -eq "/favicon.ico") {
                $response.StatusCode = 204
                try { $response.Close() } catch {}
                continue
            }
            if ($urlPath -eq "/") { $urlPath = "/index.html" }
            $safePath = $urlPath -replace "^/", "" -replace "/", "\"
            $filePath = Join-Path $publicDir $safePath

            # public フォルダの外を指すパスは拒否する
            # (以前は "/..%5c..%5cconfig.json" のような URL で public の外のファイル (設定ファイル等) を読み出せた)
            $publicRootFull = [System.IO.Path]::GetFullPath($publicDir).TrimEnd('\') + '\'
            $isInsidePublic = $false
            try { $isInsidePublic = ([System.IO.Path]::GetFullPath($filePath)).StartsWith($publicRootFull, [System.StringComparison]::OrdinalIgnoreCase) } catch { $isInsidePublic = $false }

            if ($isInsidePublic -and (Test-Path -LiteralPath $filePath -PathType Leaf)) {
                $ext = [System.IO.Path]::GetExtension($filePath)
                $response.ContentType = Get-MimeType $ext
                $response.StatusCode = 200
                [byte[]]$buffer = [System.IO.File]::ReadAllBytes($filePath)
                try { $response.ContentLength64 = $buffer.Length; $response.OutputStream.Write($buffer, 0, $buffer.Length) } catch {}
            }
            else {
                $response.StatusCode = 404
                $buffer = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found")
                try { $response.ContentLength64 = $buffer.Length; $response.OutputStream.Write($buffer, 0, $buffer.Length) } catch {}
            }
            try { $response.Close() } catch {}
        }
    }
}
finally {
    $syncHash.Running = $false

    if ($syncHash.Shutdown) {
        Write-Host "Stopping server..." -ForegroundColor Yellow
    }

    # Stop and close the background runspaces first to ensure no concurrent writes
    if ($null -ne $runspace) { try { $runspace.Close(); $runspace.Dispose() } catch {} }
    if ($null -ne $diskWriterRunspace) { try { $diskWriterRunspace.Close(); $diskWriterRunspace.Dispose() } catch {} }
    if ($null -ne $trapRunspace) { try { $trapRunspace.Close(); $trapRunspace.Dispose() } catch {} }
    if ($null -ne $obrRunspace) { try { $obrRunspace.Close(); $obrRunspace.Dispose() } catch {} }
    if ($null -ne $snmpRunspace) { try { $snmpRunspace.Close(); $snmpRunspace.Dispose() } catch {} }
    if ($null -ne $macRunspace) { try { $macRunspace.Close(); $macRunspace.Dispose() } catch {} }
    if ($null -ne $snmpDetailRunspace) { try { $snmpDetailRunspace.Close(); $snmpDetailRunspace.Dispose() } catch {} }
    if ($null -ne $asyncWorkerPool) { try { $asyncWorkerPool.Close(); $asyncWorkerPool.Dispose() } catch {} }

    # 終了時に、まだ書き込んでいない OBR の無線状態の履歴を保存する
    if ($syncHash.ObrHistoryQueue.Count -gt 0) {
        try { $null = Write-ObrHistoryRows -SessionDir $syncHash.SessionDir -Rows $syncHash.ObrHistoryQueue.ToArray() } catch {}
    }

    # Save remaining history and append summary block for each device
$devices = $syncHash.Devices
    if ($syncHash.LoggingEnabled -ne $false -and $null -ne $devices) {
        foreach ($ip in $devices) {
            $safeIp = $ip -replace '[\\/:*?"<>|]', '_'
            $csvPath = Join-Path $syncHash.SessionDir "${safeIp}.csv"
            if (-not (Test-Path $csvPath)) {
                $altSafeIp = $ip -replace '[\.:_]', '_'
                $altCsvPath = Join-Path $syncHash.SessionDir "${altSafeIp}.csv"
                if (Test-Path $altCsvPath) { $csvPath = $altCsvPath }
            }
            
            # Skip if the CSV log file does not exist (meaning the device was never monitored/initialized this session)
            if (-not (Test-Path $csvPath)) {
                continue
            }
            
            $historyList = $syncHash.History[$ip]
            $linesToSave = @()
            if ($null -ne $historyList) {
                [System.Threading.Monitor]::Enter($historyList.SyncRoot)
                try {
                    if ($historyList.Count -gt 0) {
                        $linesToSave = $historyList.ToArray()
                        $historyList.Clear()
                    }
                }
                finally {
                    [System.Threading.Monitor]::Exit($historyList.SyncRoot)
                }
            }

            # Create file with header if it doesn't exist
            if (-not (Test-Path $csvPath)) {
                $header = "タイムスタンプ,IPアドレス,ステータス,遅延_ms,帯域_Mbps,送信_Mbps,受信_Mbps,瞬断継続_sec,ジッター_ms`r`n"
                try {
                    [System.IO.File]::WriteAllText($csvPath, $header, [System.Text.Encoding]::GetEncoding(932))
                }
                catch {
                    Write-Host "Error creating CSV file on exit: $($_.Exception.Message)" -ForegroundColor Red
                }
            }

            if ($linesToSave.Count -gt 0) {
                $contentToAppend = ($linesToSave -join "`r`n") + "`r`n"
                try {
                    [System.IO.File]::AppendAllText($csvPath, $contentToAppend, [System.Text.Encoding]::GetEncoding(932))
                }
                catch {}
            }

            # Write summary block
            $stats = $syncHash.Stats[$ip]
            if ($null -ne $stats) {
                $total = $stats.Total
                $success = $stats.Success
                $failed = $stats.Failed
                $reachRate = if ($total -gt 0) { [math]::Round($success / $total * 100, 2) } else { 0 }
                
                $minLat = if ($stats.LatCount -gt 0 -and $stats.MinLat -ne [double]::MaxValue) { $stats.MinLat } else { 'N/A' }
                $maxLat = if ($stats.LatCount -gt 0) { $stats.MaxLat } else { 'N/A' }
                $avgLat = if ($stats.LatCount -gt 0) { [math]::Round($stats.SumLat / $stats.LatCount, 2) } else { 'N/A' }
                
                $Tstr = $syncHash.SessionTimestamp

                $maxOutageMs = if ($stats.MaxOutageSec -gt 0) { [math]::Round($stats.MaxOutageSec * 1000, 0) } else { 'N/A' }
                $out600ms = $stats.Outage600msCount
                $out5s = $stats.Outage5sCount
                $thresh1Label = "$($syncHash.OutageThresh1Ms)ms"
                $thresh2Label = if ($syncHash.OutageThresh2Ms -ge 1000) { "$([int]($syncHash.OutageThresh2Ms/1000))s" } else { "$($syncHash.OutageThresh2Ms)ms" }

                $packetLossRate = if ($total -gt 0) { [math]::Round(($failed / $total) * 100, 1) } else { 0 }
                $jitterVal = if ($stats.JitterCount -gt 0) {
                    [math]::Round($stats.JitterSum / $stats.JitterCount, 2)
                }
                else { 'N/A' }

                # Japanese labels via Base64 (avoids PS5 source-encoding issues)
                $pingB64 = "eyJoZWFkZXIiOiItLS0g6KiI5ris44K144Oe44Oq44O8IC0tLSIsImZhaWxlZCI6IuWkseaVl+aVsO+8iOW/nOetlOOBquOBl+ODu+OCv+OCpOODoOOCouOCpuODiO+8iSIsInJlYWNoIjoi5Yiw6YGU546HIC8g5o6l57aa5oCnICglKSIsIm91dGFnZURldGFpbENvbHMiOiJObyznnqzmlq3plovlp4vml6XmmYIs5b6p5pen5a6M5LqG5pel5pmCLOe2mee2muaZgumWk19tcyzliKTlrprljLrliIYiLCJwYWNrZXRMb3NzIjoi44OR44Kx44OD44OI5pCN5aSx546HICglKSIsImlwIjoiSVDjgqLjg4njg6zjgrkiLCJsYXRBdmciOiLlubPlnYfpgYXlu7YgKG1zKSIsImppdHRlciI6IuW5s+Wdh+OCuOODg+OCv+ODvCAobXMpIiwibm90ZSI6IuWCmeiAg++8iOeerOaWreWbnuaVsOOBrumbhuioiOOBq+OBpOOBhOOBpu+8iSIsIm91dGFnZURldGFpbE5vbmUiOiLvvIjopo/lrprplr7lgKTku6XkuIrjga7nnqzmlq3jga/nmbrnlJ/jgZfjgb7jgZvjgpPjgafjgZfjgZ/vvIkiLCJzdWNjZXNzIjoi5oiQ5Yqf5pWw77yI5b+c562U44GC44KK77yJIiwibm90ZVZhbCI6IuOCquODleODqeOCpOODs+OBi+OCieOCquODs+ODqeOCpOODs+OBq+W+qeW4sOOBl+OBn+aZgueCueOBp+OCq+OCpuODs+ODiOOAguOCu+ODg+OCt+ODp+ODs+e1guS6huaZgueCueOBp+e2mee2muS4reOBrueerOaWreOBr+WQq+OBv+OBvuOBm+OCkyIsIm91dGFnZUFib3ZlIjoi5Lul5LiK44Gu556s5pat5Zue5pWw77yI5pat44GM55m655Sf44GX44Gf5Zue5pWw77yJIiwibGF0TWluIjoi5pyA5bCP6YGF5bu2IChtcykiLCJ0b3RhbFBpbmdzIjoi57ePUGluZ+mAgeS/oeaVsO+8iOippuihjOWbnuaVsO+8iSIsInNlc3Npb24iOiLjgrvjg4Pjgrfjg6fjg7PvvIjoqIjmuKzlm57vvIkiLCJtYXhPdXRhZ2UiOiLmnIDlpKfnnqzmlq3mmYLplpPvvIjmnIDlpKfpgJrkv6HlgZzmraLmmYLplpPvvIkgKG1zKSIsIm91dGFnZURldGFpbEhlYWRlciI6Ii0tLSDnnqzmlq3jg7vpgJrkv6HliIfmlq0g55m655Sf5bGl5q205piO57SwIC0tLSIsImxhdE1heCI6IuacgOWkp+mBheW7tiAobXMpIn0="
                $pL = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($pingB64)) | ConvertFrom-Json

                $baseIntervalMs = if ($syncHash.PollInterval -gt 0) { [int]$syncHash.PollInterval } else { 1000 }
                $highFreqIps = if ($syncHash.HighFreqTargetIps) { ($syncHash.HighFreqTargetIps -split ',') | ForEach-Object { $_.Trim() } } else { @() }
                $isUltraHighFreq = ($baseIntervalMs -le 100)

                $devIntervalStr = if ($isUltraHighFreq) {
                    if ($highFreqIps -contains $ip) { "0.1s (100ms)" } else { "5.0s (5秒)" }
                }
                else {
                    if ($baseIntervalMs -ge 1000) {
                        if ($baseIntervalMs % 1000 -eq 0) { "$([int]($baseIntervalMs / 1000))s ($([int]($baseIntervalMs / 1000))秒)" } else { "$([math]::Round($baseIntervalMs / 1000, 1))s" }
                    }
                    else {
                        "$([math]::Round($baseIntervalMs / 1000, 2))s (${baseIntervalMs}ms)"
                    }
                }

                $lines = [System.Collections.Generic.List[string]]::new()
                $lines.Add("")
                $lines.Add($pL.header)
                $lines.Add($pL.ip + "," + $ip)
                $lines.Add("監視頻度（Ping間隔）," + $devIntervalStr)
                $lines.Add($pL.totalPings + "," + $total)
                $lines.Add($pL.success + "," + $success)
                $lines.Add($pL.failed + "," + $failed)
                $lines.Add($pL.reach + "," + $reachRate)
                $lines.Add($pL.packetLoss + "," + $packetLossRate)
                $lines.Add($pL.jitter + "," + $jitterVal)
                $lines.Add($pL.latMin + "," + $minLat)
                $lines.Add($pL.latMax + "," + $maxLat)
                $lines.Add($pL.latAvg + "," + $avgLat)
                $lines.Add($pL.maxOutage + "," + $maxOutageMs)
                $lines.Add($thresh1Label + $pL.outageAbove + "," + $out600ms)
                $lines.Add($thresh2Label + $pL.outageAbove + "," + $out5s)
                $lines.Add($pL.note + "," + $pL.noteVal)

                # 瞬断発生履歴明細（どこからどこまでの期間瞬断したか）の出力
                $lines.Add("")
                $lines.Add($pL.outageDetailHeader)
                if ($stats.OutageEvents -and $stats.OutageEvents.Count -gt 0) {
                    $lines.Add($pL.outageDetailCols)
                    $evIdx = 1
                    foreach ($ev in $stats.OutageEvents) {
                        $lines.Add("$evIdx,$($ev.StartTime),$($ev.EndTime),$($ev.DurationMs),$($ev.Category)")
                        $evIdx++
                    }
                }
                else {
                    $lines.Add($pL.outageDetailNone)
                }

                $summaryBlock = ($lines -join "`r`n") + "`r`n"
                try {
                    [System.IO.File]::AppendAllText($csvPath, $summaryBlock, [System.Text.Encoding]::GetEncoding(932))
                    Write-Host "Appended final summary for $ip to $csvPath" -ForegroundColor Cyan
                }
                catch {}
            }
        }
    }

    # Generate graphical HTML report in session directory (chart.js is embedded inline, no external file needed)
    if ($syncHash.LoggingEnabled -ne $false -and $syncHash.SessionDir -and (Test-Path $syncHash.SessionDir)) {
        try {
            $reportFile = Join-Path $syncHash.SessionDir "report.html"
            $null = Generate-SessionReportHtml -sync $syncHash -period "Session" -savePath $reportFile
            Write-Host "Generated graph inspection report: $reportFile" -ForegroundColor Green
        }
        catch {
            Write-Host "Error generating final HTML report: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # Auto-purge old reports exceeding retention days on server shutdown
    if ($syncHash.LogRetentionDays -gt 0) {
        try {
            Invoke-PurgeOldReports -reportsDirectory $ReportsDir -retentionDays $syncHash.LogRetentionDays -activeSessionDir $syncHash.SessionDir | Out-Null
        }
        catch {}
    }

    if ($null -ne $syncHash.IperfServerState.Process -and -not $syncHash.IperfServerState.Process.HasExited) {
        try { $syncHash.IperfServerState.Process.Kill() } catch {}
    }
    if ($null -ne $syncHash.IperfState.Process -and -not $syncHash.IperfState.Process.HasExited) {
        try { $syncHash.IperfState.Process.Kill() } catch {}
    }

    if ($null -ne $listener) { try { $listener.Stop(); $listener.Close() } catch {} }
    if ($null -ne $syslogRunspace) { try { $syslogRunspace.Close(); $syslogRunspace.Dispose() } catch {} }
    if ($null -ne $keyRunspace) { try { $keyRunspace.Close(); $keyRunspace.Dispose() } catch {} }
    Write-Host "Server stopped gracefully." -ForegroundColor Gray
}
