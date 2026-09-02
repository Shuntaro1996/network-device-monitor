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

if (-not (Get-Module -ListAvailable -Name SNMP)) {
    Write-Host "Checking SNMP module..." -ForegroundColor Yellow
    try {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null
        Install-Module -Name SNMP -Scope CurrentUser -Force -ErrorAction SilentlyContinue | Out-Null
    } catch {
        Write-Warning "Failed to install SNMP module: $($_.Exception.Message)"
    }
}
Import-Module SNMP -ErrorAction SilentlyContinue

# ── Import System Modules (Modular Architecture) ──────────────────────────────
$modulesDir = Join-Path $PSScriptRoot "modules"
if (Test-Path $modulesDir) {
    Import-Module (Join-Path $modulesDir "Common.psm1") -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modulesDir "AlertManager.psm1") -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modulesDir "ReportGenerator.psm1") -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modulesDir "SnmpService.psm1") -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modulesDir "PingEngine.psm1") -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modulesDir "IperfRunner.psm1") -Force -ErrorAction SilentlyContinue
}

# Clean up any leftover iperf3.exe processes from previous unclean exits
try {
    Get-Process -Name "iperf3" -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_.Kill(); Write-Host "Cleaned up leftover iperf3 process (PID: $($_.Id))" -ForegroundColor DarkGray } catch {}
    }
} catch {}

$port = 8081
$rootDir   = Split-Path -Parent $PSScriptRoot
$publicDir = Join-Path $PSScriptRoot "public"
# devices.txt is now inside the system folder
$devicesFileJson = Join-Path $PSScriptRoot "devices.json"
$devicesFileTxt  = Join-Path $PSScriptRoot "devices.txt"

    # Shared memory for background runspaces
    $syncHash = [hashtable]::Synchronized(@{})
    $syncHash.Status    = [hashtable]::Synchronized(@{})
    $syncHash.Bandwidth = [hashtable]::Synchronized(@{})
    $syncHash.Traffic   = [hashtable]::Synchronized(@{})
    $syncHash.Community = [hashtable]::Synchronized(@{})
    $syncHash.DeviceName  = [hashtable]::Synchronized(@{})
    $syncHash.IsMonitored = [hashtable]::Synchronized(@{})
    $syncHash.Group     = [hashtable]::Synchronized(@{})
    $syncHash.Image     = [hashtable]::Synchronized(@{})
    $syncHash.ConnectedTo = [hashtable]::Synchronized(@{})
    $syncHash.X         = [hashtable]::Synchronized(@{})
    $syncHash.Y         = [hashtable]::Synchronized(@{})
    $syncHash.Stats     = [hashtable]::Synchronized(@{})
    $syncHash.Mac       = [hashtable]::Synchronized(@{})  # MAC addresses
    $syncHash.SnmpDetail = [hashtable]::Synchronized(@{})  # link speed, neighbors, wifi band
    
    # Memo & Location & Web extensions
    $syncHash.Location      = [hashtable]::Synchronized(@{})
    $syncHash.VendorContact = [hashtable]::Synchronized(@{})
    $syncHash.TroubleMemo   = [hashtable]::Synchronized(@{})
    $syncHash.DeviceType    = [hashtable]::Synchronized(@{}) # network, web, server, etc.
    $syncHash.WebUrl        = [hashtable]::Synchronized(@{})
    $syncHash.SslExpiryDays = [hashtable]::Synchronized(@{})
    $syncHash.HttpStatus    = [hashtable]::Synchronized(@{})

    $syncHash.InterfaceErrors = [hashtable]::Synchronized(@{}) # Stores current error counts and deltas
    $syncHash.CheckType       = [hashtable]::Synchronized(@{}) # icmp or tcp
    $syncHash.Port            = [hashtable]::Synchronized(@{}) # TCP port for port monitoring
    
    # SNMPv3 security parameters
    $syncHash.SnmpVersion   = [hashtable]::Synchronized(@{})
    $syncHash.SnmpUser      = [hashtable]::Synchronized(@{})
    $syncHash.SnmpAuthProto = [hashtable]::Synchronized(@{})
    $syncHash.SnmpAuthPass  = [hashtable]::Synchronized(@{})
    $syncHash.SnmpPrivProto = [hashtable]::Synchronized(@{})
    $syncHash.SnmpPrivPass  = [hashtable]::Synchronized(@{})

    # Syslog memory buffer (max 500 lines)
    $syncHash.SyslogQueue   = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())

    # Config files paths
    $configFileJson  = Join-Path $PSScriptRoot "config.json"

    $syncHash.PollInterval      = 1000  # Default frontend/backend polling interval (ms)
    $syncHash.PingDataSize      = 1     # Default ping data size (bytes)
    $syncHash.LoggingEnabled    = $true # Default logging configuration
    $syncHash.HighFreqTargetIps = ""   # When PollInterval<=100ms, up to 2 IPs (comma-separated) are polled at high frequency
    $syncHash.OutageThresh1Ms   = 600  # Threshold 1 for outage count (ms)
    $syncHash.OutageThresh2Ms   = 5000 # Threshold 2 for outage count (ms)
    $syncHash.LatencyThreshMs   = 100  # Threshold for latency alert (ms)
    $syncHash.LatencyWarningMs  = 80   # 2段階アラート用: Warning遅延閾値 (ms)
    $syncHash.ConsecutiveFailThresh = 2 # 2段階アラート用: 障害判定に必要な連続失敗回数
    $syncHash.LogRetentionDays  = 30   # Auto-purge old reports older than N days (0=disabled)
    $syncHash.WebhookUrl        = ""   # Webhook URL for external notifications (Slack/Teams/Discord)
    $syncHash.WebhookEnabled    = $false
    $syncHash.WebhookOfflineOnly= $true
    $syncHash.SoundEnabled      = $true
    $syncHash.SoundVolume       = 0.5

    # Email (SMTP) settings
    $syncHash.EmailEnabled      = $false
    $syncHash.SmtpHost          = ""
    $syncHash.SmtpPort          = 587
    $syncHash.SmtpSsl           = $true
    $syncHash.SmtpUser          = ""
    $syncHash.SmtpPass          = ""
    $syncHash.SmtpFrom          = ""
    $syncHash.SmtpTo            = ""

    # Syslog settings
    $syncHash.SyslogEnabled     = $true
    $syncHash.SyslogPort        = 514
    $syncHash.SslWarnDays       = 30
    $syncHash.UiMode            = "detail"
    $syncHash.BwThreshMbps      = 10.0
    $syncHash.EnableParentSuppression = $true
    
    # Load Config from file if exists
    if (Test-Path $configFileJson) {
        try {
            $savedConfig = Get-Content $configFileJson -Raw | ConvertFrom-Json
            if ($null -ne $savedConfig.pollInterval)       { $syncHash.PollInterval       = [int]$savedConfig.pollInterval }
            if ($null -ne $savedConfig.pingDataSize)       { $syncHash.PingDataSize       = [int]$savedConfig.pingDataSize }
            if ($null -ne $savedConfig.loggingEnabled)     { $syncHash.LoggingEnabled     = [bool]$savedConfig.loggingEnabled }
            if ($null -ne $savedConfig.highFreqTargetIps)  { $syncHash.HighFreqTargetIps  = [string]$savedConfig.highFreqTargetIps }
            elseif ($null -ne $savedConfig.highFreqTargetIp) { $syncHash.HighFreqTargetIps = [string]$savedConfig.highFreqTargetIp }
            if ($null -ne $savedConfig.outageThresh1Ms)    { $syncHash.OutageThresh1Ms    = [int]$savedConfig.outageThresh1Ms }
            if ($null -ne $savedConfig.outageThresh2Ms)    { $syncHash.OutageThresh2Ms    = [int]$savedConfig.outageThresh2Ms }
            if ($null -ne $savedConfig.latencyThreshMs)    { $syncHash.LatencyThreshMs    = [int]$savedConfig.latencyThreshMs }
            if ($null -ne $savedConfig.latencyWarningMs)   { $syncHash.LatencyWarningMs   = [int]$savedConfig.latencyWarningMs }
            if ($null -ne $savedConfig.consecutiveFailThresh) { $syncHash.ConsecutiveFailThresh = [int]$savedConfig.consecutiveFailThresh }
            if ($null -ne $savedConfig.logRetentionDays)   { $syncHash.LogRetentionDays   = [int]$savedConfig.logRetentionDays }
            if ($null -ne $savedConfig.webhookUrl)         { $syncHash.WebhookUrl         = [string]$savedConfig.webhookUrl }
            if ($null -ne $savedConfig.webhookEnabled)     { $syncHash.WebhookEnabled     = [bool]$savedConfig.webhookEnabled }
            if ($null -ne $savedConfig.webhookOfflineOnly) { $syncHash.WebhookOfflineOnly = [bool]$savedConfig.webhookOfflineOnly }
            if ($null -ne $savedConfig.soundEnabled)       { $syncHash.SoundEnabled       = [bool]$savedConfig.soundEnabled }
            if ($null -ne $savedConfig.soundVolume)        { $syncHash.SoundVolume        = [double]$savedConfig.soundVolume }

            if ($null -ne $savedConfig.emailEnabled)       { $syncHash.EmailEnabled       = [bool]$savedConfig.emailEnabled }
            if ($null -ne $savedConfig.smtpHost)           { $syncHash.SmtpHost           = [string]$savedConfig.smtpHost }
            if ($null -ne $savedConfig.smtpPort)           { $syncHash.SmtpPort           = [int]$savedConfig.smtpPort }
            if ($null -ne $savedConfig.smtpSsl)            { $syncHash.SmtpSsl            = [bool]$savedConfig.smtpSsl }
            if ($null -ne $savedConfig.smtpUser)           { $syncHash.SmtpUser           = [string]$savedConfig.smtpUser }
            if ($null -ne $savedConfig.smtpPass)           {
                # DPAPI復号（平文であればそのまま読み込まれ、保存時に暗号化）
                $syncHash.SmtpPass = Unprotect-SecretString ([string]$savedConfig.smtpPass)
            }
            if ($null -ne $savedConfig.smtpFrom)           { $syncHash.SmtpFrom           = [string]$savedConfig.smtpFrom }
            if ($null -ne $savedConfig.smtpTo)             { $syncHash.SmtpTo             = [string]$savedConfig.smtpTo }

            if ($null -ne $savedConfig.syslogEnabled)      { $syncHash.SyslogEnabled      = [bool]$savedConfig.syslogEnabled }
            if ($null -ne $savedConfig.syslogPort)         { $syncHash.SyslogPort         = [int]$savedConfig.syslogPort }
            if ($null -ne $savedConfig.sslWarnDays)        { $syncHash.SslWarnDays        = [int]$savedConfig.sslWarnDays }
            if ($null -ne $savedConfig.uiMode)             { $syncHash.UiMode             = [string]$savedConfig.uiMode }
            if ($null -ne $savedConfig.bwThreshMbps)       { $syncHash.BwThreshMbps       = [double]$savedConfig.bwThreshMbps }
            if ($null -ne $savedConfig.enableParentSuppression) { $syncHash.EnableParentSuppression = [bool]$savedConfig.enableParentSuppression }
            Write-Host "Config loaded from $configFileJson" -ForegroundColor Green
        } catch {
            Write-Host "Failed to load config.json, using defaults." -ForegroundColor Yellow
        }
    }

    # Helper: Auto-purge old report session folders
    function Purge-OldReports {
        param([string]$reportsDir, [int]$retentionDays)
        if (-not (Test-Path $reportsDir) -or $retentionDays -le 0) { return }
        $cutoff = (Get-Date).AddDays(-$retentionDays)
        Get-ChildItem -Path $reportsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -match '^\d{8}_\d{6}$' -and $_.CreationTime -lt $cutoff) {
                try {
                    Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Host "Purged old report session: $($_.Name)" -ForegroundColor Gray
                } catch {}
            }
        }
    }

    # Helper: Send Webhook notification (Async-friendly)
    function Send-WebhookNotification {
        param(
            [string]$url,
            [string]$deviceName,
            [string]$ip,
            [string]$eventType,
            [string]$details = ""
        )
        if ([string]::IsNullOrWhiteSpace($url)) { return }
        $emoji = switch ($eventType) {
            "offline"   { [char]::ConvertFromUtf32(0x1F534) }
            "online"    { [char]::ConvertFromUtf32(0x1F7E2) }
            "latency"   { [char]::ConvertFromUtf32(0x26A0) }
            "test"      { [char]::ConvertFromUtf32(0x1F514) }
            default     { [char]::ConvertFromUtf32(0x1F4E2) }
        }
        $title = switch ($eventType) {
            "offline"   { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("5qmf5Zmo44Kq44OV44Op44Kk44Oz5qSc55+l")) }
            "online"    { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("5qmf5Zmo44Kq44Oz44Op44Kk44Oz5b6p5biw")) }
            "latency"   { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("6YGF5bu244Ki44Op44O844OI6LaF6YGO")) }
            "test"      { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("V2ViaG9va+ODhuOCueODiOmAnuefpQ==")) }
            default     { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("55uj6KaW44Ki44Op44O844OI")) }
        }
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $msgText = "$emoji **$title**`n[Target]: $deviceName ($ip)`n[Time]: $ts`n[Detail]: $details"
        
        $bodyObj = @{
            text       = $msgText
            content    = $msgText   # Discord compatibility
            title      = "$emoji $title"
            deviceName = $deviceName
            ip         = $ip
            eventType  = $eventType
            timestamp  = $ts
            details    = $details
        }
        $jsonPayload = $bodyObj | ConvertTo-Json -Depth 3
        
        try {
            $webReq = [System.Net.WebRequest]::Create($url)
            $webReq.Method = "POST"
            $webReq.ContentType = "application/json; charset=utf-8"
            $webReq.Timeout = 4000
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonPayload)
            $webReq.ContentLength = $bytes.Length
            $reqStream = $webReq.GetRequestStream()
            $reqStream.Write($bytes, 0, $bytes.Length)
            $reqStream.Close()
            $webResp = $webReq.GetResponse()
        } catch { }
    }

    # Helper: Send Email (SMTP) notification
    function Send-EmailNotification {
        param(
            [string]$smtpHost,
            [int]$smtpPort,
            [bool]$useSsl,
            [string]$smtpUser,
            [string]$smtpPass,
            [string]$from,
            [string]$to,
            [string]$subject,
            [string]$body
        )
        if ([string]::IsNullOrWhiteSpace($smtpHost) -or [string]::IsNullOrWhiteSpace($to)) { return $false }
        try {
            $mail = New-Object System.Net.Mail.MailMessage
            $mail.From = New-Object System.Net.Mail.MailAddress (if ($from) { $from } else { "monitor@localhost" })
            foreach ($addr in ($to -split '[,;]')) {
                if ($addr.Trim()) { $mail.To.Add($addr.Trim()) }
            }
            $mail.Subject = $subject
            $mail.Body = $body
            $mail.IsBodyHtml = $false
            $mail.BodyEncoding = [System.Text.Encoding]::UTF8
            $mail.SubjectEncoding = [System.Text.Encoding]::UTF8

            $smtp = New-Object System.Net.Mail.SmtpClient($smtpHost, $smtpPort)
            $smtp.EnableSsl = $useSsl
            $smtp.Timeout = 8000
            if (-not [string]::IsNullOrWhiteSpace($smtpUser)) {
                $smtp.Credentials = New-Object System.Net.NetworkCredential($smtpUser, $smtpPass)
            }
            $smtp.Send($mail)
            $mail.Dispose()
            $smtp.Dispose()
            return $true
        } catch {
            Write-Warning "SMTP notification error: $($_.Exception.Message)"
            return $false
        }
    }

    # Helper: Log Audit record
    function Log-Audit {
        param(
            [string]$action,
            [string]$target,
            [string]$details = "",
            [string]$clientIp = "127.0.0.1",
            [string]$reportsDirectory
        )
        try {
            if (-not $reportsDirectory) { $reportsDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) "Reports" }
            if (-not (Test-Path $reportsDirectory)) { New-Item -ItemType Directory -Path $reportsDirectory -Force | Out-Null }
            $auditFile = Join-Path $reportsDirectory "audit.log"
            $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            $line = "[$ts] [$clientIp] [Action: $action] [Target: $target] $details"
            $line | Out-File -FilePath $auditFile -Append -Encoding UTF8
        } catch {}
    }

    # Helper: Auto-purge old Reports/ directories exceeding retention days
    function Invoke-PurgeOldReports {
        param(
            [string]$reportsDirectory,
            [int]$retentionDays = 30,
            [string]$activeSessionDir = ""
        )
        $result = @{
            Success = $true
            DeletedCount = 0
            FreedBytes = [long]0
            FreedMb = 0.0
            Details = @()
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
            $subDirs = Get-ChildItem -Path $reportsDirectory -Directory -ErrorAction SilentlyContinue

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
                    } catch {}
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
                    } catch {
                        Write-Warning "Failed to purge old report session $($dir.FullName): $($_.Exception.Message)"
                    }
                }
            }
            $result.FreedMb = [math]::Round($result.FreedBytes / 1MB, 2)
            if ($result.DeletedCount -gt 0) {
                try {
                    $logMsg = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [Retention Policy] Purged $($result.DeletedCount) old session(s), freed $($result.FreedMb) MB.`r`n"
                    [System.IO.File]::AppendAllText((Join-Path $PSScriptRoot "debug.log"), $logMsg, [System.Text.Encoding]::UTF8)
                } catch {}
            }
        } catch {
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
    # Generate-SessionReportHtml is imported from ReportGenerator.psm1

    # Helper: Check HTTP/HTTPS response & SSL Certificate Expiry
    function Check-WebAndSslEndpoint {
        param([string]$url, [int]$timeoutMs = 4000)
        $res = @{
            Success = $false
            StatusCode = 0
            ResponseTimeMs = 0
            SslDaysRemaining = $null
            SslSubject = ""
            SslIssuer = ""
            Error = ""
        }
        if ([string]::IsNullOrWhiteSpace($url)) { return $res }
        if ($url -notmatch '^https?://') { $url = "http://$url" }
        
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $req = [System.Net.HttpWebRequest]::Create($url)
            $req.Timeout = $timeoutMs
            $req.AllowAutoRedirect = $true
            $req.ServerCertificateValidationCallback = { $true } # Accept self-signed for inspection
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
        } catch [System.Net.WebException] {
            $sw.Stop()
            $res.ResponseTimeMs = [int]$sw.ElapsedMilliseconds
            if ($_.Response) {
                $res.StatusCode = [int]$_.Response.StatusCode
                $_.Response.Close()
            }
            $res.Error = $_.Exception.Message
        } catch {
            $sw.Stop()
            $res.Error = $_.Exception.Message
        }
        return $res
    }

    # Iperf Session State
    $syncHash.IperfState = [hashtable]::Synchronized(@{
        Running        = $false
        Output         = ""
        Command        = ""
        Target         = ""
        LastUpdate     = 0
        StopRequested  = $false
        Process        = $null
    })

    # Iperf Server Session State
    $syncHash.IperfServerState = [hashtable]::Synchronized(@{
        Running        = $false
        Port           = 5201
        Output         = ""
        Process        = $null
        StartTime      = ""
        LogFile        = ""
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
    $syncHash.History   = [hashtable]::Synchronized(@{})
    $syncHash.Running   = $true
    $syncHash.Devices   = @()
    $syncHash.Shutdown  = $false  # flag for Enter-key exit
    $syncHash.PendingShutdown = $false
    $syncHash.PendingShutdownTime = [DateTime]::MinValue
    $syncHash.HasClientConnected = $false
    $syncHash.LastClientActivity = [DateTime]::UtcNow
    $syncHash.AutoShutdownOnDisconnect = $true
    $syncHash.HeartbeatTimeoutSec = 60  # ブラウザのバックグラウンドスロットリングやタブ切替・リロードでの誤終了を防ぐため60秒に設定
    $syncHash.DevicesLock = [object]::new()  # Issue 5: デバイス設定保存専用ロックオブジェクト（$syncHash全体ロックを回避）
    $syncHash.Listener  = $null   # will be set after listener creation
    $syncHash.PSScriptRoot = $PSScriptRoot
 
    $cleanLines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path $devicesFileJson) {
        try {
            $rawJson = Get-Content $devicesFileJson -Raw -Encoding UTF8
            if ([string]::IsNullOrWhiteSpace($rawJson)) {
                $jsonContent = @()
            } else {
                $jsonContent = $rawJson | ConvertFrom-Json
            }
            if ($null -ne $jsonContent) {
                foreach ($d in $jsonContent) {
                    $ip = [string]$d.ip
                    if (-not [string]::IsNullOrWhiteSpace($ip)) {
                        $cleanLines.Add($ip)
                        $syncHash.Community[$ip]   = if ($null -ne $d.community) { [string]$d.community } else { "public" }
                        $syncHash.DeviceName[$ip]  = if ($null -ne $d.name) { [string]$d.name } else { $ip }
                        $syncHash.IsMonitored[$ip] = if ($null -ne $d.enabled) { [bool]$d.enabled } else { $true }
                        $syncHash.Group[$ip]       = if ($null -ne $d.group) { [string]$d.group } else { "" }
                        $syncHash.Image[$ip]       = if ($null -ne $d.image) { [string]$d.image } else { "" }
                        $syncHash.ConnectedTo[$ip] = if ($null -ne $d.connectedTo) { [string]$d.connectedTo } else { "" }
                        $syncHash.X[$ip]           = if ($null -ne $d.x) { $d.x } else { $null }
                        $syncHash.Y[$ip]           = if ($null -ne $d.y) { $d.y } else { $null }
                        $syncHash.Mac[$ip]         = if ($null -ne $d.mac) { [string]$d.mac } else { "" }
                        $syncHash.Location[$ip]      = if ($null -ne $d.location) { [string]$d.location } else { "" }
                        $syncHash.VendorContact[$ip] = if ($null -ne $d.vendorContact) { [string]$d.vendorContact } else { "" }
                        $syncHash.TroubleMemo[$ip]   = if ($null -ne $d.troubleMemo) { [string]$d.troubleMemo } else { "" }
                        $syncHash.DeviceType[$ip]    = if ($null -ne $d.deviceType) { [string]$d.deviceType } else { "network" }
                        $syncHash.WebUrl[$ip]        = if ($null -ne $d.webUrl) { [string]$d.webUrl } else { "" }
                        $syncHash.CheckType[$ip]     = if ($null -ne $d.checkType) { [string]$d.checkType } else { "icmp" }
                        $syncHash.Port[$ip]          = if ($null -ne $d.port) { [int]$d.port } else { 0 }
                        
                        # Load SNMPv3 parameters (DPAPI自動復号)
                        $syncHash.SnmpVersion[$ip]   = if ($null -ne $d.snmpVersion) { [string]$d.snmpVersion } else { "v2c" }
                        $syncHash.SnmpUser[$ip]      = if ($null -ne $d.snmpUser) { [string]$d.snmpUser } else { "" }
                        $syncHash.SnmpAuthProto[$ip] = if ($null -ne $d.snmpAuthProto) { [string]$d.snmpAuthProto } else { "none" }
                        $syncHash.SnmpAuthPass[$ip]  = if ($null -ne $d.snmpAuthPass) { Unprotect-SecretString ([string]$d.snmpAuthPass) } else { "" }
                        $syncHash.SnmpPrivProto[$ip] = if ($null -ne $d.snmpPrivProto) { [string]$d.snmpPrivProto } else { "none" }
                        $syncHash.SnmpPrivPass[$ip]  = if ($null -ne $d.snmpPrivPass) { Unprotect-SecretString ([string]$d.snmpPrivPass) } else { "" }
                    }
                }
            }
        } catch {
            Write-Host "Error reading devices.json: $_" -ForegroundColor Red
        }
    } elseif (Test-Path $devicesFileTxt) {
    $migratedArray = @()
    foreach ($line in [System.IO.File]::ReadAllLines($devicesFileTxt)) {
        $line = $line.Trim()
        if ($line -ne "") {
            $ip = ""
            $comm = "public"
            if ($line -match "^([^,]+),(.*)$") {
                $ip = $matches[1].Trim()
                $comm = $matches[2].Trim()
            } else {
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
        # Issue 5: $syncHash全体ではなく専用のDevicesLockオブジェクトのみをロックし、Pingループをブロックしない
        [System.Threading.Monitor]::Enter($syncHash.DevicesLock)
        try {
            $outArray = @()
            foreach ($ip in $syncHash.Devices) {
                $outArray += @{
                    ip = $ip
                    community = if ($syncHash.Community.ContainsKey($ip)) { $syncHash.Community[$ip] } else { "public" }
                    name = if ($syncHash.DeviceName.ContainsKey($ip)) { $syncHash.DeviceName[$ip] } else { $ip }
                    enabled = if ($syncHash.IsMonitored.ContainsKey($ip)) { $syncHash.IsMonitored[$ip] } else { $true }
                    group = if ($syncHash.Group.ContainsKey($ip)) { $syncHash.Group[$ip] } else { "" }
                    image = if ($syncHash.Image.ContainsKey($ip)) { $syncHash.Image[$ip] } else { "" }
                    connectedTo = if ($syncHash.ConnectedTo.ContainsKey($ip)) { $syncHash.ConnectedTo[$ip] } else { "" }
                    x = if ($syncHash.X.ContainsKey($ip)) { $syncHash.X[$ip] } else { $null }
                    y = if ($syncHash.Y.ContainsKey($ip)) { $syncHash.Y[$ip] } else { $null }
                    mac = if ($syncHash.Mac.ContainsKey($ip)) { $syncHash.Mac[$ip] } else { "" }
                    location = if ($syncHash.Location.ContainsKey($ip)) { $syncHash.Location[$ip] } else { "" }
                    vendorContact = if ($syncHash.VendorContact.ContainsKey($ip)) { $syncHash.VendorContact[$ip] } else { "" }
                    troubleMemo = if ($syncHash.TroubleMemo.ContainsKey($ip)) { $syncHash.TroubleMemo[$ip] } else { "" }
                    deviceType = if ($syncHash.DeviceType.ContainsKey($ip)) { $syncHash.DeviceType[$ip] } else { "network" }
                    webUrl = if ($syncHash.WebUrl.ContainsKey($ip)) { $syncHash.WebUrl[$ip] } else { "" }
                    checkType = if ($syncHash.CheckType.ContainsKey($ip)) { $syncHash.CheckType[$ip] } else { "icmp" }
                    port = if ($syncHash.Port.ContainsKey($ip)) { $syncHash.Port[$ip] } else { 0 }
                    
                    # SNMPv3 properties (DPAPI暗号化保存)
                    snmpVersion = if ($syncHash.SnmpVersion.ContainsKey($ip)) { $syncHash.SnmpVersion[$ip] } else { "v2c" }
                    snmpUser = if ($syncHash.SnmpUser.ContainsKey($ip)) { $syncHash.SnmpUser[$ip] } else { "" }
                    snmpAuthProto = if ($syncHash.SnmpAuthProto.ContainsKey($ip)) { $syncHash.SnmpAuthProto[$ip] } else { "none" }
                    snmpAuthPass = if ($syncHash.SnmpAuthPass.ContainsKey($ip) -and $syncHash.SnmpAuthPass[$ip]) { Protect-SecretString $syncHash.SnmpAuthPass[$ip] } else { "" }
                    snmpPrivProto = if ($syncHash.SnmpPrivProto.ContainsKey($ip)) { $syncHash.SnmpPrivProto[$ip] } else { "none" }
                    snmpPrivPass = if ($syncHash.SnmpPrivPass.ContainsKey($ip) -and $syncHash.SnmpPrivPass[$ip]) { Protect-SecretString $syncHash.SnmpPrivPass[$ip] } else { "" }
                }
            }
            $jsonStr = ConvertTo-Json -InputObject $outArray -Depth 5
            
            $devicesFileJson = Join-Path $syncHash.PSScriptRoot "devices.json"
            $tmpFile = $devicesFileJson + ".tmp"
            for ($retry = 0; $retry -lt 5; $retry++) {
                try {
                    $jsonStr | Out-File -FilePath $tmpFile -Encoding UTF8
                    Move-Item -Path $tmpFile -Destination $devicesFileJson -Force
                    break
                } catch {
                    try { [System.IO.File]::AppendAllText((Join-Path $syncHash.PSScriptRoot "debug.log"), "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] Save-DevicesJson error: $($_.Exception.Message)`r`n", [System.Text.Encoding]::UTF8) } catch {}
                    Start-Sleep -Milliseconds 100
                }
            }
        } finally {
            [System.Threading.Monitor]::Exit($syncHash.DevicesLock)
        }
    }
}

. ([scriptblock]::Create($saveDevicesJsonScript.ToString()))

$snmpHelpersScript = {
    # Dynamically load SharpSnmpLib if not already loaded
    $snmpModule = Get-Module -ListAvailable SNMP | Select-Object -First 1
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
        
        $ipAddr = [System.Net.IPAddress]::Parse($IP)
        $endpoint = New-Object System.Net.IPEndPoint $ipAddr, $Port
        
        if ($Version -eq "v3") {
            try {
                $discovery = New-Object Lextm.SharpSnmpLib.Messaging.Discovery 1, 1, 1024
                $report = [Lextm.SharpSnmpLib.Messaging.SnmpMessageExtension]::GetResponse($discovery, $Timeout, $endpoint)
                
                $authProvider = [Lextm.SharpSnmpLib.Security.DefaultPrivacyProvider]::DefaultPair.AuthenticationProvider
                if ($AuthProto -eq "MD5") {
                    $authProvider = New-Object Lextm.SharpSnmpLib.Security.MD5AuthenticationProvider (New-Object Lextm.SharpSnmpLib.OctetString $AuthPass)
                } elseif ($AuthProto -eq "SHA") {
                    $authProvider = New-Object Lextm.SharpSnmpLib.Security.SHA1AuthenticationProvider (New-Object Lextm.SharpSnmpLib.OctetString $AuthPass)
                }
                
                $privacyProvider = $null
                if ($PrivProto -eq "DES" -and $AuthProto -ne "none") {
                    $privacyProvider = New-Object Lextm.SharpSnmpLib.Security.DESPrivacyProvider (New-Object Lextm.SharpSnmpLib.OctetString $PrivPass), $authProvider
                } else {
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
                        OID = $v.Id.ToString()
                        Data = $v.Data.ToString()
                    }
                }
            } catch {
                Write-Warning "SNMPv3 Get Error for ${IP}: $($_.ToString())"
            }
        } else {
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
                        OID = $v.Id.ToString()
                        Data = $v.Data.ToString()
                    }
                }
            } catch {
                Write-Warning "SNMPv2 Get Error for ${IP}: $($_.ToString())"
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
                } elseif ($AuthProto -eq "SHA") {
                    $authProvider = New-Object Lextm.SharpSnmpLib.Security.SHA1AuthenticationProvider (New-Object Lextm.SharpSnmpLib.OctetString $AuthPass)
                }
                
                $privacyProvider = $null
                if ($PrivProto -eq "DES" -and $AuthProto -ne "none") {
                    $privacyProvider = New-Object Lextm.SharpSnmpLib.Security.DESPrivacyProvider (New-Object Lextm.SharpSnmpLib.OctetString $PrivPass), $authProvider
                } else {
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
                    } else {
                        $nextVar = $resVars[0]
                        $nextOid = $nextVar.Id
                        
                        if ($nextOid.ToString().StartsWith($rootOid.ToString())) {
                            New-Object PSObject -Property @{
                                OID = $nextOid.ToString()
                                Data = $nextVar.Data.ToString()
                            }
                            $currentOid = $nextOid
                        } else {
                            $keepWalking = $false
                        }
                    }
                }
            } catch {
                Write-Warning "SNMPv3 Walk Error for ${IP}: $($_.ToString())"
            }
        } else {
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
                        OID = $v.Id.ToString()
                        Data = $v.Data.ToString()
                    }
                }
            } catch {
                Write-Warning "SNMPv2 Walk Error for ${IP}: $($_.ToString())"
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
} catch {}

# Issue 1: 古いセッションレポートの自動クリーンアップ（起動時に保持日数を超過した過去ログをパージ）
if ($syncHash.LogRetentionDays -gt 0) {
    try {
        Invoke-PurgeOldReports -reportsDirectory $ReportsDir -retentionDays $syncHash.LogRetentionDays -activeSessionDir $syncHash.SessionDir | Out-Null
    } catch {}
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
        })
    }
    
    if ($syncHash.LoggingEnabled -eq $false) {
        return
    }
    
    $safeIp  = $ip -replace '[\\/:*?"<>|]', '_'
    $csvPath = Join-Path $syncHash.SessionDir "${safeIp}.csv"
    if (-not (Test-Path $csvPath)) {
        $header = "タイムスタンプ,IPアドレス,ステータス,遅延_ms,帯域_Mbps,送信_Mbps,受信_Mbps,瞬断継続_sec,ジッター_ms`r`n"
        try {
            [System.IO.File]::WriteAllText($csvPath, $header, [System.Text.Encoding]::GetEncoding(932))
        } catch {
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
            } else {
                $Data | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
            }
            return $true
        } catch {
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
$runspace.ThreadOptions  = "ReuseThread"
$runspace.Open()
$runspace.SessionStateProxy.SetVariable("syncHash", $syncHash)

$pingScript = {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastFlushTime          = [DateTime]::Now
    $lastCheckpointTime     = [DateTime]::Now   # 60秒ごとに Stats を _checkpoint.json へ保存
    $lastSlowPingTime = [DateTime]::MinValue
    
    while ($syncHash.Running) {
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
        } else { @() }

        $now = [DateTime]::Now
        # In ultra-high-freq mode, non-target devices are polled at low-rate interval (5.0 seconds = 5000ms)
        $isSlowPingDue = ($isUltraHighFreq -and ($now - $lastSlowPingTime).TotalMilliseconds -ge 5000)
        if ($isSlowPingDue -or -not $isUltraHighFreq) {
            $lastSlowPingTime = $now
        }

        # Initiate asynchronous ping for devices
        $dataSize = if ($syncHash.PingDataSize) { [int]$syncHash.PingDataSize } else { 32 }
        $pingBuffer = New-Object byte[] $dataSize
        for ($i=0; $i -lt $dataSize; $i++) { $pingBuffer[$i] = 0 }

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
                if (-not $isTarget -and -not $isSlowPingDue) {
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
                } else {
                    1000
                }
            } else {
                [math]::Min(1000, [math]::Max(200, $syncHash.PollInterval))
            }

            # ── TCPポート死活監視 または ICMP Ping の切り替え ──
            $isTcpCheck = ($syncHash.CheckType.ContainsKey($ip) -and $syncHash.CheckType[$ip] -eq "tcp" -and $syncHash.Port.ContainsKey($ip) -and $syncHash.Port[$ip] -gt 0)
            if ($isTcpCheck) {
                $targetPort = [int]$syncHash.Port[$ip]
                $tcpClient = New-Object System.Net.Sockets.TcpClient
                try {
                    $swTcp = [System.Diagnostics.Stopwatch]::StartNew()
                    $task = [System.Threading.Tasks.Task]::Factory.FromAsync(
                        $tcpClient.BeginConnect,
                        $tcpClient.EndConnect,
                        $ip,
                        $targetPort,
                        $null
                    )
                    [PSCustomObject]@{
                        IP = $ip; Ping = $null; TcpClient = $tcpClient; Task = $task; Stopwatch = $swTcp; IsTcp = $true; Port = $targetPort; Error = $false; Skipped = $false; KeepExisting = $false
                    }
                } catch {
                    try { $tcpClient.Close(); $tcpClient.Dispose() } catch {}
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
            } catch {
                [PSCustomObject]@{
                    IP = $ip; Ping = $ping; TcpClient = $null; Task = $null; Stopwatch = $null; IsTcp = $false; Port = 0; Error = $true; Skipped = $false; KeepExisting = $false
                }
            }
        }

        # Wait for all active pings to complete (up to PollInterval or 1000ms)
        $waitTimeout = if ($isUltraHighFreq) { [math]::Max(80, $syncHash.PollInterval) } else { if ($syncHash.PollInterval -gt 0) { $syncHash.PollInterval } else { 1000 } }
        $validTasks = @($tasks | Where-Object { $null -ne $_.Task })
        if ($validTasks.Count -gt 0) {
            try {
                $taskArray = [System.Threading.Tasks.Task[]]($validTasks.Task)
                [System.Threading.Tasks.Task]::WaitAll($taskArray, $waitTimeout) | Out-Null
            } catch { }
            # Issue 4: 未完了タスクをさらに短時間待機してからDisposeし、リソースリークを防ぐ
            foreach ($vt in $validTasks) {
                if ($vt.Task.Status -notin @([System.Threading.Tasks.TaskStatus]::RanToCompletion,
                                             [System.Threading.Tasks.TaskStatus]::Faulted,
                                             [System.Threading.Tasks.TaskStatus]::Canceled)) {
                    try { $vt.Task.Wait(50) | Out-Null } catch { }
                }
            }
        }

        # Process results
        foreach ($t in $tasks) {
            $ip = $t.IP
            if ($t.KeepExisting) {
                # Non-target during dual-rate intermediate cycle: keep last status without modification
                continue
            }

            $reply = $null
            if ($t.Skipped) {
                $syncHash.Status[$ip] = @{ status = "Paused"; rawStatus = "Paused"; latency = $null; checkType = (if ($t.IsTcp) { "tcp" } else { "icmp" }); port = $t.Port; timestamp = (Get-Date).ToUniversalTime().ToString("o") }
                continue
            } elseif ($t.Error) {
                $syncHash.Status[$ip] = @{ status = "Error"; rawStatus = "Failed"; latency = $null; checkType = (if ($t.IsTcp) { "tcp" } else { "icmp" }); port = $t.Port; timestamp = (Get-Date).ToUniversalTime().ToString("o") }
            } else {
                if ($t.IsTcp) {
                    if ($t.Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
                        $status = "Success"
                        $latency = [math]::Max(1, [int]$t.Stopwatch.ElapsedMilliseconds)
                    } else {
                        $status = "Failed"
                        $latency = $null
                    }
                    try { $t.TcpClient.Close(); $t.TcpClient.Dispose() } catch {}
                } else {
                    if ($t.Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
                        $reply = $t.Task.Result
                    }
                    $status  = if ($reply -and $reply.Status -eq 'Success') { "Success" } else { "Failed" }
                    $latency = if ($status -eq "Success") { $reply.RoundtripTime } else { $null }
                }

                # ── 2段階ステータス判定 (Success / Warning / Failed) ──
                $stObj = $syncHash.Stats[$ip]
                $evalStatus = $status
                if ($null -ne $stObj) {
                    if ($status -eq "Success") {
                        $stObj.ConsecutiveFails = 0
                    } else {
                        if ($null -eq $stObj.ConsecutiveFails) { $stObj.ConsecutiveFails = 0 }
                        $stObj.ConsecutiveFails = $stObj.ConsecutiveFails + 1
                    }
                    $latVal = if ($latency) { [double]$latency } else { 0.0 }
                    $warnThresh = if ($syncHash.LatencyWarningMs) { $syncHash.LatencyWarningMs } else { 80 }
                    $failThresh = if ($syncHash.ConsecutiveFailThresh) { $syncHash.ConsecutiveFailThresh } else { 2 }
                    $evalStatus = Evaluate-DeviceStatus -isSuccess ($status -eq "Success") -latencyMs $latVal -consecutiveFails $stObj.ConsecutiveFails -latencyWarningMs $warnThresh -consecutiveFailThresh $failThresh
                }

                $syncHash.Status[$ip] = @{
                    status    = $evalStatus
                    rawStatus = $status
                    latency   = $latency
                    checkType = if ($t.IsTcp) { "tcp" } else { "icmp" }
                    port      = $t.Port
                    timestamp = (Get-Date).ToUniversalTime().ToString("o")
                }
            }

            # Record history as plain CSV string
            $ts  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            $st  = if ($syncHash.Status[$ip].status)  { [string]$syncHash.Status[$ip].status  } else { 'Unknown' }
            $lat = if ($syncHash.Status[$ip].latency -ne $null) { [string]$syncHash.Status[$ip].latency } else { '' }
            $bw  = if ($syncHash.Bandwidth[$ip])      { [string]$syncHash.Bandwidth[$ip]       } else { '-' }

            # Outage duration for this record: 0 when online, current elapsed seconds when offline
            $outageSec = ''
            $statsNow = $syncHash.Stats[$ip]
            if ($null -ne $statsNow) {
                if ($st -eq 'Failed' -or $st -eq 'Error') {
                    $outageSec = if ($null -ne $statsNow.OutageStartTime) {
                        [math]::Round([math]::Max(0.0, ((Get-Date) - $statsNow.OutageStartTime).TotalSeconds), 1)
                    } elseif ($statsNow.CurrentOutageSec -gt 0) {
                        [math]::Round($statsNow.CurrentOutageSec, 1)
                    } else { 0.0 }
                } else {
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
            } else { '' }

            $csvLine = "`"$ts`",`"$ip`",`"$st`",`"$lat`",`"$bw`",`"$txStr`",`"$rxStr`",`"$outageSec`",`"$jitterVal`""
            if ($syncHash.History.ContainsKey($ip)) {
                $null = $syncHash.History[$ip].Add($csvLine)
            }

            # Update stats
            $stats = $syncHash.Stats[$ip]
            if ($null -ne $stats) {
                [System.Threading.Monitor]::Enter($stats.SyncRoot)
                try {
                    $stats.Total = $stats.Total + 1
                    $devName = if ($syncHash.DeviceName.ContainsKey($ip)) { $syncHash.DeviceName[$ip] } else { $ip }
                    
                    # Track Recent Results (max 30 samples) - use RemoveRange for O(1) efficiency
                    $resVal = if ($st -eq "Success") { 1 } else { 0 }
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
                                $allParentsDown = $true
                                foreach ($pIp in $parentIps) {
                                    if ($syncHash.Status.ContainsKey($pIp)) {
                                        $pSt = $syncHash.Status[$pIp].status
                                        if ($pSt -eq "Success" -or $pSt -eq "Online") {
                                            $allParentsDown = $false
                                            break
                                        }
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

                    if ($st -eq "Success") {
                        # Webhook & Email on recovery (Offline -> Online)
                        if ($stats.PreviousStatus -eq "Failed") {
                            if ($syncHash.WebhookEnabled) {
                                $webhookUrl = $syncHash.WebhookUrl
                                $capturedName = $devName; $capturedIp = $ip
                                [System.Threading.ThreadPool]::QueueUserWorkItem({
                                    try { Send-WebhookNotification -url $webhookUrl -deviceName $capturedName -ip $capturedIp -eventType "online" -details "正常に応答が復旧しました。" } catch {}
                                }.GetNewClosure()) | Out-Null
                            }
                            if ($syncHash.EmailEnabled -and $syncHash.SmtpHost -and $syncHash.SmtpTo) {
                                $sHost = $syncHash.SmtpHost; $sPort = $syncHash.SmtpPort; $sSsl = $syncHash.SmtpSsl
                                $sUser = $syncHash.SmtpUser; $sPass = $syncHash.SmtpPass; $sFrom = $syncHash.SmtpFrom; $sTo = $syncHash.SmtpTo
                                $capturedName = $devName; $capturedIp = $ip
                                [System.Threading.ThreadPool]::QueueUserWorkItem({
                                    try {
                                        $subj = "[復旧通知] ネットワーク機器 $capturedName ($capturedIp) がオンラインに復旧しました"
                                        $body = "ネットワーク機器 $capturedName ($capturedIp) のPing応答が正常に復旧しました。`n発生時刻: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
                                        Send-EmailNotification -smtpHost $sHost -smtpPort $sPort -useSsl $sSsl -smtpUser $sUser -smtpPass $sPass -from $sFrom -to $sTo -subject $subj -body $body
                                    } catch {}
                                }.GetNewClosure()) | Out-Null
                            }
                        }
                        $stats.PreviousStatus = "Success"

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
                            if ($isThresh2) { $stats.Outage5sCount    = $stats.Outage5sCount    + 1 }

                            # 規定閾値1以上の瞬断イベントを明細として記録（最大200件まで保持）
                            if ($isThresh1 -or $isThresh2) {
                                $categoryLabel = if ($isThresh2) {
                                    if ($syncHash.OutageThresh2Ms -ge 1000) { "$([int]($syncHash.OutageThresh2Ms/1000))s以上 (重大)" } else { "$($syncHash.OutageThresh2Ms)ms以上" }
                                } else {
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
                                } finally {
                                    [System.Threading.Monitor]::Exit($stats.OutageEvents.SyncRoot)
                                }
                            }
                            
                            # Reset current outage tracking
                            $stats.OutageStartTime  = $null
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
                                $stats.Jitter      = [math]::Round($diffSum / ($stats.RecentLatencies.Count - 1), 2)
                                $stats.JitterSum   = $stats.JitterSum + $stats.Jitter
                                $stats.JitterCount = $stats.JitterCount + 1
                            }
                        }
                    } elseif ($st -eq "Failed" -or $st -eq "Error") {
                        # Webhook & Email on failure (Online -> Offline) only if not suppressed by parent offline
                        if ($stats.PreviousStatus -eq "Success") {
                            if (-not $isSuppressed) {
                                if ($syncHash.WebhookEnabled) {
                                    $webhookUrl = $syncHash.WebhookUrl
                                    $capturedName = $devName; $capturedIp = $ip
                                    [System.Threading.ThreadPool]::QueueUserWorkItem({
                                        try { Send-WebhookNotification -url $webhookUrl -deviceName $capturedName -ip $capturedIp -eventType "offline" -details "Ping応答が途絶しました。" } catch {}
                                    }.GetNewClosure()) | Out-Null
                                }
                                if ($syncHash.EmailEnabled -and $syncHash.SmtpHost -and $syncHash.SmtpTo) {
                                    $sHost = $syncHash.SmtpHost; $sPort = $syncHash.SmtpPort; $sSsl = $syncHash.SmtpSsl
                                    $sUser = $syncHash.SmtpUser; $sPass = $syncHash.SmtpPass; $sFrom = $syncHash.SmtpFrom; $sTo = $syncHash.SmtpTo
                                    $capturedName = $devName; $capturedIp = $ip
                                    [System.Threading.ThreadPool]::QueueUserWorkItem({
                                        try {
                                            $subj = "[障害検知] ネットワーク機器 $capturedName ($capturedIp) がオフラインになりました"
                                            $body = "ネットワーク機器 $capturedName ($capturedIp) のPing応答が途絶しました。`n発生時刻: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
                                            Send-EmailNotification -smtpHost $sHost -smtpPort $sPort -useSsl $sSsl -smtpUser $sUser -smtpPass $sPass -from $sFrom -to $sTo -subject $subj -body $body
                                        } catch {}
                                    }.GetNewClosure()) | Out-Null
                                }
                            } else {
                                Write-Host "Alert suppressed for $ip (Parent device is down)" -ForegroundColor Yellow
                            }
                        }
                        $stats.PreviousStatus = "Failed"

                        $stats.Failed = $stats.Failed + 1
                        
                        # Start or accumulate outage duration (do not update MaxOutageSec until recovery)
                        if ($null -eq $stats.OutageStartTime) {
                            $stats.OutageStartTime = Get-Date
                            $pollSec = if ($syncHash.PollInterval -gt 0) { [double]$syncHash.PollInterval / 1000.0 } else { 1.0 }
                            $stats.CurrentOutageSec = $pollSec
                        } else {
                            $stats.CurrentOutageSec = ((Get-Date) - $stats.OutageStartTime).TotalSeconds
                        }
                    }
                } finally {
                    [System.Threading.Monitor]::Exit($stats.SyncRoot)
                }
            }
            if ($null -ne $t.Ping) {
                $t.Ping.Dispose()
            }
        }

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
            } else {
                foreach ($ip in $devicesToFlush) {
                    $historyList = $syncHash.History[$ip]
                    if ($null -eq $historyList) { continue }
                    
                    $linesToSave = @()
                    [System.Threading.Monitor]::Enter($historyList.SyncRoot)
                    try {
                        if ($historyList.Count -gt 0) {
                            $linesToSave = $historyList.ToArray()
                        }
                    } finally {
                        [System.Threading.Monitor]::Exit($historyList.SyncRoot)
                    }
                    
                    if ($linesToSave.Count -gt 0) {
                        $safeIp  = $ip -replace '[\\/:*?"<>|]', '_'
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
                        } catch {
                            # CSV書き込み失敗をdebug.logに記録
                            try {
                                $errMsg = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] CSV write failed for ${ip}: $($_.Exception.Message)`r`n"
                                [System.IO.File]::AppendAllText((Join-Path $syncHash.PSScriptRoot "debug.log"), $errMsg, [System.Text.Encoding]::UTF8)
                            } catch {}
                        }

                        if ($writeSuccess) {
                            [System.Threading.Monitor]::Enter($historyList.SyncRoot)
                            try {
                                if ($historyList.Count -ge $linesToSave.Count) {
                                    $historyList.RemoveRange(0, $linesToSave.Count)
                                }
                            } finally {
                                [System.Threading.Monitor]::Exit($historyList.SyncRoot)
                            }
                        } else {
                            # 書き込み失敗時: メモリキューが上限（5000件）を超えたら古いエントリを強制削除してメモリ暴走を防ぐ
                            [System.Threading.Monitor]::Enter($historyList.SyncRoot)
                            try {
                                $maxQueueSize = 5000
                                if ($historyList.Count -gt $maxQueueSize) {
                                    $dropCount = $historyList.Count - $maxQueueSize
                                    $historyList.RemoveRange(0, $dropCount)
                                }
                            } finally {
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
            $lastCheckpointTime = [DateTime]::Now
            try {
                $checkpoint = @{}
                foreach ($ip in $syncHash.Devices) {
                    $s = $syncHash.Stats[$ip]
                    if ($null -eq $s) { continue }
                    $checkpoint[$ip] = @{
                        savedAt       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                        total         = $s.Total
                        success       = $s.Success
                        failed        = $s.Failed
                        reachRate     = if ($s.Total -gt 0) { [math]::Round($s.Success / $s.Total * 100, 2) } else { 0 }
                        packetLoss    = if ($s.Total -gt 0) { [math]::Round($s.Failed  / $s.Total * 100, 1) } else { 0 }
                        minLat        = if ($s.LatCount -gt 0 -and $s.MinLat -ne [double]::MaxValue) { $s.MinLat } else { $null }
                        maxLat        = if ($s.LatCount -gt 0) { $s.MaxLat } else { $null }
                        avgLat        = if ($s.LatCount -gt 0) { [math]::Round($s.SumLat / $s.LatCount, 2) } else { $null }
                        maxOutageSec  = if ($s.MaxOutageSec -gt 0) { [math]::Round($s.MaxOutageSec, 1) } else { 0 }
                        avgJitter     = if ($s.JitterCount -gt 0) { [math]::Round($s.JitterSum / $s.JitterCount, 2) } else { $null }
                        outage600ms   = $s.Outage600msCount
                        outage5s      = $s.Outage5sCount
                    }
                }
                $cpJson = $checkpoint | ConvertTo-Json -Depth 4
                $cpPath = Join-Path $syncHash.SessionDir "_checkpoint.json"
                [System.IO.File]::WriteAllText($cpPath, $cpJson, [System.Text.Encoding]::UTF8)

                # ── ロールアップキャッシュ更新 (長期データ・点検報告書の高速化) ──
                if ($syncHash.SessionDir) {
                    foreach ($devIp in $syncHash.Devices) {
                        $sIp = $devIp -replace '[\\/:*?"<>|]', '_'
                        $devCsv = Join-Path $syncHash.SessionDir "${sIp}.csv"
                        if (Test-Path $devCsv) {
                            try {
                                $csvLines = [System.IO.File]::ReadAllLines($devCsv, [System.Text.Encoding]::GetEncoding(932))
                                $dataLines = @($csvLines | Where-Object { $_ -and -not $_.StartsWith("---") })
                                if ($dataLines.Count -gt 1) {
                                    $parsed = $dataLines | ConvertFrom-Csv
                                    $pts = @()
                                    foreach ($r in $parsed) {
                                        $tStr = if ($r.タイムスタンプ) { $r.タイムスタンプ } elseif ($r.Timestamp) { $r.Timestamp } else { "" }
                                        $tShort = if ($tStr.Length -ge 19) { $tStr.Substring(11, 8) } else { $tStr }
                                        $latR = if ($r.遅延_ms) { $r.遅延_ms } elseif ($r.Latency_ms) { $r.Latency_ms } else { "" }
                                        $pts += @{
                                            t   = $tShort
                                            lat = if ($latR -match '^\d+(\.\d+)?$') { [double]$latR } else { $null }
                                            jit = $null
                                            tx  = $null
                                            rx  = $null
                                            st  = if ($r.ステータス) { $r.ステータス } else { "Success" }
                                        }
                                    }
                                    Update-RollupCache -sessionDir $syncHash.SessionDir -ip $devIp -timeSeries $pts
                                }
                            } catch {}
                        }
                    }
                }
            } catch { }
        }

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
# 2. Start background BANDWIDTH runspace (10s loop)
# ─────────────────────────────────────────
$bwRunspace = [runspacefactory]::CreateRunspace()
$bwRunspace.ApartmentState = "STA"
$bwRunspace.ThreadOptions  = "ReuseThread"
$bwRunspace.Open()
$bwRunspace.SessionStateProxy.SetVariable("syncHash", $syncHash)
$bwRunspace.SessionStateProxy.SetVariable("AppDir",   $PSScriptRoot)

$bwScriptBlock = {
    $bwScriptPath = Join-Path $AppDir "Measure-Bandwidth.ps1"
    while ($syncHash.Running) {
        try {
            $devices = $syncHash.Devices
            if ($null -ne $devices) {
                foreach ($ip in $devices) {
                    if ($syncHash.IsMonitored.ContainsKey($ip) -and -not $syncHash.IsMonitored[$ip]) {
                        $syncHash.Bandwidth[$ip] = "-"
                        continue
                    }
                    try {
                        if ($syncHash.Status[$ip].status -eq "Success") {
                            $output = & $bwScriptPath -IpList $ip -NoCsv -NoReport *>&1 | Out-String
                            if ($output -match "Result:\s*([\d\.]+)\s*Mbps") {
                                $syncHash.Bandwidth[$ip] = $matches[1]
                            } else {
                                $syncHash.Bandwidth[$ip] = "Failed"
                            }
                        } else {
                            $syncHash.Bandwidth[$ip] = "-"
                        }
                    } catch {
                        $syncHash.Bandwidth[$ip] = "Error"
                        try {
                            $errMsg = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] Bandwidth measure error for ${ip}: $($_.Exception.Message)`r`n"
                            [System.IO.File]::AppendAllText((Join-Path $AppDir "debug.log"), $errMsg, [System.Text.Encoding]::UTF8)
                        } catch {}
                    }
                }
            }
            Start-Sleep -Seconds 10
        } catch {
            Start-Sleep -Seconds 5
        }
    }
}
$bwPipeline = $bwRunspace.CreatePipeline()
$null = $bwPipeline.Commands.AddScript($bwScriptBlock)
$bwAsyncResult = $bwPipeline.InvokeAsync()

# ─────────────────────────────────────────
# 2.5 Start background SNMP runspace (5s loop)
# ─────────────────────────────────────────
$snmpRunspace = [runspacefactory]::CreateRunspace()
$snmpRunspace.ApartmentState = "STA"
$snmpRunspace.ThreadOptions  = "ReuseThread"
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
                if ($syncHash.Status.ContainsKey($ip) -and $syncHash.Status[$ip].status -eq "Success") {
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
                        $inErrData  = Invoke-SnmpWalkUnified -IP $ip -Community $comm -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart "1.3.6.1.2.1.2.2.1.14" -TimeOut 800 -ErrorAction SilentlyContinue
                        $outErrData = Invoke-SnmpWalkUnified -IP $ip -Community $comm -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart "1.3.6.1.2.1.2.2.1.20" -TimeOut 800 -ErrorAction SilentlyContinue
                        $inDiscData = Invoke-SnmpWalkUnified -IP $ip -Community $comm -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart "1.3.6.1.2.1.2.2.1.13" -TimeOut 800 -ErrorAction SilentlyContinue
                        $outDiscData= Invoke-SnmpWalkUnified -IP $ip -Community $comm -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart "1.3.6.1.2.1.2.2.1.19" -TimeOut 800 -ErrorAction SilentlyContinue

                        if ($inData -and $outData) {
                            $snmpFailedDevices[$ip] = 0
                            $totalIn = 0; $totalOut = 0
                            foreach ($x in $inData)  { if ($x.Data -notmatch "Null") { $totalIn += [uint64]($x.Data) } }
                            foreach ($x in $outData) { if ($x.Data -notmatch "Null") { $totalOut += [uint64]($x.Data) } }
                            
                            if ($lastOctets.ContainsKey($ip)) {
                                $prev = $lastOctets[$ip]
                                $sec = ($now - $prev.time).TotalSeconds
                                if ($sec -gt 0) {
                                    $deltaIn = $totalIn - $prev.in
                                    $deltaOut = $totalOut - $prev.out
                                    if ($deltaIn -lt 0) { $deltaIn += 4294967296 }
                                    if ($deltaOut -lt 0) { $deltaOut += 4294967296 }
                                    
                                    $rxMbps = [math]::Round(($deltaIn * 8) / $sec / 1000000, 2)
                                    $txMbps = [math]::Round(($deltaOut * 8) / $sec / 1000000, 2)
                                    $syncHash.Traffic[$ip] = @{ tx = $txMbps; rx = $rxMbps }
                                }
                            } else {
                                $syncHash.Traffic[$ip] = @{ tx = "Calc..."; rx = "Calc..." }
                            }
                            $lastOctets[$ip] = @{ in = $totalIn; out = $totalOut; time = $now }

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
                                        $currentIpErrors[$idx].dInErr  = [math]::Max(0, $currentIpErrors[$idx].inErr - $prevE.inErr)
                                        $currentIpErrors[$idx].dOutErr = [math]::Max(0, $currentIpErrors[$idx].outErr - $prevE.outErr)
                                        $currentIpErrors[$idx].dInDisc = [math]::Max(0, $currentIpErrors[$idx].inDisc - $prevE.inDisc)
                                        $currentIpErrors[$idx].dOutDisc= [math]::Max(0, $currentIpErrors[$idx].outDisc - $prevE.outDisc)
                                    }
                                }
                            }
                            $lastErrors[$ip] = $currentIpErrors
                            $syncHash.InterfaceErrors[$ip] = $currentIpErrors
                        } else {
                            $snmpFailedDevices[$ip] = [int]($snmpFailedDevices[$ip]) + 1
                            $syncHash.Traffic[$ip] = @{ tx = "-"; rx = "-" }
                        }
                    } catch {
                        $snmpFailedDevices[$ip] = [int]($snmpFailedDevices[$ip]) + 1
                        $syncHash.Traffic[$ip] = @{ tx = "Error"; rx = "Error" }
                    }
                } else {
                    $syncHash.Traffic[$ip] = @{ tx = "-"; rx = "-" }
                }
            }
            $sleepSec = if ($null -ne $syncHash.PollInterval) { [math]::Max(1, [int]($syncHash.PollInterval / 1000)) } else { 5 }
            Start-Sleep -Seconds $sleepSec
        } catch {
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
$macRunspace.ThreadOptions  = "ReuseThread"
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
        } catch {
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
        } catch {
            try { [System.IO.File]::AppendAllText((Join-Path $syncHash.PSScriptRoot "debug.log"), "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] Get-MacFromSnmp error for ${ip}: $($_.Exception.Message)`r`n", [System.Text.Encoding]::UTF8) } catch {}
        }
        return $null
    }

    # Wait a few seconds on first run for ping runspace to populate ARP cache
    Start-Sleep -Seconds 8

    $devices = $syncHash.Devices
    $changed = $false

    foreach ($ip in $devices) {
        # Do not query the MAC address for devices whose monitoring is disabled (enabled is false)
        if ($syncHash.IsMonitored.ContainsKey($ip) -and -not $syncHash.IsMonitored[$ip]) { continue }

        # Query MAC address
        $mac = Get-MacFromArp -ip $ip
        if ([string]::IsNullOrWhiteSpace($mac)) {
            $comm = if ($syncHash.Community.ContainsKey($ip)) { $syncHash.Community[$ip] } else { 'public' }
            $mac = Get-MacFromSnmp -ip $ip -community $comm
        }

        if (-not [string]::IsNullOrWhiteSpace($mac)) {
            $existingMac = if ($syncHash.Mac.ContainsKey($ip)) { $syncHash.Mac[$ip] } else { "" }
            if ($mac -ne $existingMac) {
                $syncHash.Mac[$ip] = $mac
                $changed = $true
            }
        }
    }

    # If MAC addresses changed, save thread-safely to devices.json
    if ($changed) {
        Save-DevicesJson
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
$snmpDetailRunspace.ThreadOptions  = "ReuseThread"
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
        } catch {
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
        } catch {
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
            } catch {
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
                    if     ($ch -le 14)  { return "2.4 GHz (Ch $ch)" }
                    elseif ($ch -le 64)  { return "5 GHz (Ch $ch)" }
                    elseif ($ch -le 177) { return "5 GHz (Ch $ch)" }
                    else                 { return "6 GHz (Ch $ch)" }
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
        } catch {
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
                } elseif ($r.Data -match '^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$') {
                    $hex = $r.Data -replace ':', ''
                } elseif ($r.Data -match '^[0-9A-Fa-f]{2}(-[0-9A-Fa-f]{2}){5}$') {
                    $hex = $r.Data -replace '-', ''
                } elseif ($r.Data -match 'Hex-STRING:\s*([0-9A-Fa-f\s]+)') {
                    $hex = $matches[1] -replace '\s', ''
                } else {
                    continue
                }
                
                if ($hex.Length -eq 12) {
                    $formatted = ($hex -split '(?<=\G.{2})(?=.)') -join ':'
                    $mac = $formatted.ToUpper()
                    if (-not $list.Contains($mac)) { $list.Add($mac) }
                }
            }
        } catch {
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
                ip = $ip
                name = $name
                mac = $mac
                image = $image
                status = if ($syncHash.Status.ContainsKey($ip)) { $syncHash.Status[$ip].status } else { 'Failed' }
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
                    } else {
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
            Save-DevicesJson
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
                $speed    = Get-InterfaceSpeed -ip $ip -community $comm
                $neighbors = Get-Neighbors     -ip $ip -community $comm
                $wifiBand  = Get-WirelessBand  -ip $ip -community $comm

                $syncHash.SnmpDetail[$ip] = @{
                    speed     = if ($speed)     { $speed }     else { '' }
                    neighbors = if ($neighbors) { $neighbors } else { '' }
                    wifiBand  = if ($wifiBand)  { $wifiBand }  else { '' }
                }
            } catch {
                try { [System.IO.File]::AppendAllText((Join-Path $syncHash.PSScriptRoot "debug.log"), "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] SNMPDetailRunspace inner query error for ${ip}: $($_.Exception.Message)`r`n", [System.Text.Encoding]::UTF8) } catch {}
            }
        }
        Update-AutoTopology
        $sleepSec = if ($null -ne $syncHash.PollInterval) { [math]::Max(5, [int]($syncHash.PollInterval * 6 / 1000)) } else { 30 }
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
$syslogRunspace.ThreadOptions  = "ReuseThread"
$syslogRunspace.Open()
$syslogRunspace.SessionStateProxy.SetVariable("syncHash", $syncHash)

$syslogScriptBlock = {
    $port = if ($syncHash.SyslogPort) { $syncHash.SyslogPort } else { 514 }
    $udpClient = $null
    try {
        $udpClient = New-Object System.Net.Sockets.UdpClient($port)
        $udpClient.Client.ReceiveTimeout = 1000
    } catch {
        try {
            $udpClient = New-Object System.Net.Sockets.UdpClient(1514)
            $udpClient.Client.ReceiveTimeout = 1000
        } catch {}
    }

    $remoteEP = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)

    while ($syncHash.Running) {
        if (-not $syncHash.SyslogEnabled -or $null -eq $udpClient) {
            Start-Sleep -Milliseconds 500
            continue
        }

        try {
            $bytes = $udpClient.Receive([ref]$remoteEP)
            if ($null -ne $bytes -and $bytes.Length -gt 0) {
                $rawMsg = [System.Text.Encoding]::UTF8.GetString($bytes)
                $srcIp  = $remoteEP.Address.ToString()
                $ts     = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                
                $severity = "Informational"
                $cleanMsg = $rawMsg
                if ($rawMsg -match '^<(\d{1,3})>(.*)$') {
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
                }

                [System.Threading.Monitor]::Enter($syncHash.SyslogQueue.SyncRoot)
                try {
                    $syncHash.SyslogQueue.Insert(0, $logEntry)
                    while ($syncHash.SyslogQueue.Count -gt 500) {
                        $syncHash.SyslogQueue.RemoveAt($syncHash.SyslogQueue.Count - 1)
                    }
                } finally {
                    [System.Threading.Monitor]::Exit($syncHash.SyslogQueue.SyncRoot)
                }
            }
        } catch [System.Net.Sockets.SocketException] {
            # Timeout is normal for non-blocking receive
        } catch {
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
# Helper: Serve JSON response
# ─────────────────────────────────────────
function Write-JsonResponse($response, $data, $statusCode=200) {
    if ($response.OutputStream.CanWrite) {
        $response.StatusCode  = $statusCode
        $response.ContentType = "application/json; charset=utf-8"
        $response.Headers.Add("Access-Control-Allow-Origin", "*")
        $json   = ($data | ConvertTo-Json -Depth 5 -Compress) -join "`n"
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
        try {
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        } catch {}
        try { $response.Close() } catch {}
    }
}

# Helper: MIME types
function Get-MimeType($ext) {
    switch ($ext.ToLower()) {
        ".html" { return "text/html" }
        ".css"  { return "text/css" }
        ".js"   { return "application/javascript" }
        ".png"  { return "image/png" }
        ".jpg"  { return "image/jpeg" }
        ".svg"  { return "image/svg+xml" }
        default { return "application/octet-stream" }
    }
}



# ─────────────────────────────────────────
# 3. HTTP Server – non-blocking with async GetContext
# ─────────────────────────────────────────
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
try {
    $listener.Start()
    $syncHash.Listener = $listener   # share reference for ThreadPool closures
    Write-Host "Network Monitor Server running at http://localhost:$port/" -ForegroundColor Green
    Write-Host "Press [Enter] to stop and save logs." -ForegroundColor Yellow
} catch {
    Write-Host "Failed to start HTTP listener: $($_.Exception.Message)" -ForegroundColor Red
    $syncHash.Running = $false
    $runspace.Close(); $runspace.Dispose()
    exit
}

# Dedicated runspace: watch for Enter key, browser disconnect, or shutdown signal
$keyRunspace = [runspacefactory]::CreateRunspace()
$keyRunspace.ApartmentState = "STA"
$keyRunspace.ThreadOptions  = "ReuseThread"
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
        } catch { }

        # 2. Browser shutdown signal (/api/shutdown beacon)
        if ($syncHash.PendingShutdown -and [DateTime]::UtcNow -gt $syncHash.PendingShutdownTime) {
            Write-Host "Browser shutdown signal received. Shutting down server gracefully..." -ForegroundColor Yellow
            break
        }

        # 3. Client heartbeat & disconnect detection (Auto-shutdown when browser closed)
        #    タイムアウトを20秒に設定: F5リロードやWi-Fi→有線切替による瞬断（通常3〜10秒）での誤終了を防ぐ
        if ($syncHash.AutoShutdownOnDisconnect -ne $false) {
            $timeoutSec = if ($syncHash.HeartbeatTimeoutSec) { [int]$syncHash.HeartbeatTimeoutSec } else { 20 }
            
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
$keyPipeline = $keyRunspace.CreatePipeline()
$null = $keyPipeline.Commands.AddScript($keyScript)
$null = $keyPipeline.InvokeAsync()

try {
    while ($listener.IsListening) {
        $context = $null
        try { $context = $listener.GetContext() } catch { break }
        if ($null -eq $context) { break }

        $request  = $context.Request
        $response = $context.Response
        $urlPath  = $request.Url.LocalPath
        $method   = $request.HttpMethod

        # Update client activity on any request from browser
        $syncHash.HasClientConnected = $true
        $syncHash.LastClientActivity = [DateTime]::UtcNow

        if ($urlPath -ne "/api/shutdown") {
            if ($syncHash.PendingShutdown) {
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
                                ip = $ip
                                community = if ($syncHash.Community.ContainsKey($ip)) { $syncHash.Community[$ip] } else { "public" }
                                name = if ($syncHash.DeviceName.ContainsKey($ip)) { $syncHash.DeviceName[$ip] } else { $ip }
                                enabled = if ($syncHash.IsMonitored.ContainsKey($ip)) { $syncHash.IsMonitored[$ip] } else { $true }
                                group = if ($syncHash.Group.ContainsKey($ip)) { $syncHash.Group[$ip] } else { "" }
                                image = if ($syncHash.Image.ContainsKey($ip)) { $syncHash.Image[$ip] } else { "" }
                                connectedTo = if ($syncHash.ConnectedTo.ContainsKey($ip)) { $syncHash.ConnectedTo[$ip] } else { "" }
                                x = if ($syncHash.X.ContainsKey($ip)) { $syncHash.X[$ip] } else { $null }
                                y = if ($syncHash.Y.ContainsKey($ip)) { $syncHash.Y[$ip] } else { $null }
                                mac = if ($syncHash.Mac.ContainsKey($ip)) { $syncHash.Mac[$ip] } else { "" }
                                location = if ($syncHash.Location.ContainsKey($ip)) { $syncHash.Location[$ip] } else { "" }
                                vendorContact = if ($syncHash.VendorContact.ContainsKey($ip)) { $syncHash.VendorContact[$ip] } else { "" }
                                troubleMemo = if ($syncHash.TroubleMemo.ContainsKey($ip)) { $syncHash.TroubleMemo[$ip] } else { "" }
                                deviceType = if ($syncHash.DeviceType.ContainsKey($ip)) { $syncHash.DeviceType[$ip] } else { "network" }
                                webUrl = if ($syncHash.WebUrl.ContainsKey($ip)) { $syncHash.WebUrl[$ip] } else { "" }
                                checkType = if ($syncHash.CheckType.ContainsKey($ip)) { $syncHash.CheckType[$ip] } else { "icmp" }
                                port = if ($syncHash.Port.ContainsKey($ip)) { $syncHash.Port[$ip] } else { 0 }
                                sslExpiryDays = if ($syncHash.SslExpiryDays.ContainsKey($ip)) { $syncHash.SslExpiryDays[$ip] } else { $null }
                                httpStatus = if ($syncHash.HttpStatus.ContainsKey($ip)) { $syncHash.HttpStatus[$ip] } else { $null }
                                snmpVersion = if ($syncHash.SnmpVersion.ContainsKey($ip)) { $syncHash.SnmpVersion[$ip] } else { "v2c" }
                                snmpUser = if ($syncHash.SnmpUser.ContainsKey($ip)) { $syncHash.SnmpUser[$ip] } else { "" }
                                snmpAuthProto = if ($syncHash.SnmpAuthProto.ContainsKey($ip)) { $syncHash.SnmpAuthProto[$ip] } else { "none" }
                                snmpAuthPass = if ($syncHash.SnmpAuthPass.ContainsKey($ip)) { $syncHash.SnmpAuthPass[$ip] } else { "" }
                                snmpPrivProto = if ($syncHash.SnmpPrivProto.ContainsKey($ip)) { $syncHash.SnmpPrivProto[$ip] } else { "none" }
                                snmpPrivPass = if ($syncHash.SnmpPrivPass.ContainsKey($ip)) { $syncHash.SnmpPrivPass[$ip] } else { "" }
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
                    } finally {
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
                        $st.bandwidth = if ($syncHash.Bandwidth.ContainsKey($key)) { $syncHash.Bandwidth[$key] } else { "Waiting..." }
                        
                        if ($syncHash.Traffic.ContainsKey($key) -and $null -ne $syncHash.Traffic[$key]) {
                            $st.tx = $syncHash.Traffic[$key].tx
                            $st.rx = $syncHash.Traffic[$key].rx
                        } else {
                            $st.tx = "-"
                            $st.rx = "-"
                        }
                        $st.mac = if ($syncHash.Mac.ContainsKey($key)) { $syncHash.Mac[$key] } else { '' }
                        if ($syncHash.SnmpDetail.ContainsKey($key)) {
                            $d = $syncHash.SnmpDetail[$key]
                            $st.speed     = $d.speed
                            $st.neighbors = $d.neighbors
                            $st.wifiBand  = $d.wifiBand
                        } else {
                            $st.speed = ''; $st.neighbors = ''; $st.wifiBand = ''
                        }
                        if ($syncHash.InterfaceErrors.ContainsKey($key)) {
                            $st.errors = $syncHash.InterfaceErrors[$key]
                        } else {
                            $st.errors = @{}
                        }
                        # Include max outage stats
                        if ($syncHash.Stats.ContainsKey($key)) {
                            $s = $syncHash.Stats[$key]
                            $curOutage = if ($null -ne $s.OutageStartTime) {
                                [math]::Max(0.0, ((Get-Date) - $s.OutageStartTime).TotalSeconds)
                            } elseif ($s.CurrentOutageSec -gt 0) {
                                $s.CurrentOutageSec
                            } else {
                                0.0
                            }
                            $st.maxOutageSec     = if ($s.MaxOutageSec -gt 0) { [math]::Round($s.MaxOutageSec, 1) } else { 0 }
                            $st.currentOutageSec = if ($curOutage -gt 0) { [math]::Round($curOutage, 1) } else { 0 }
                            $st.outage600msCount = $s.Outage600msCount
                            $st.outage5sCount    = $s.Outage5sCount
                            $st.outageEvents     = if ($s.OutageEvents) { @($s.OutageEvents | Select-Object -Last 5) } else { @() }
                            $st.packetLossRate   = if ($null -ne $s.PacketLossRate) { $s.PacketLossRate } else { 0.0 }
                            $st.jitter           = if ($null -ne $s.Jitter) { $s.Jitter } else { 0.0 }
                            $st.avgJitter        = if ($s.JitterCount -gt 0) { [math]::Round($s.JitterSum / $s.JitterCount, 2) } else { 0.0 }
                        } else {
                            $st.maxOutageSec = 0; $st.currentOutageSec = 0
                            $st.outage600msCount = 0; $st.outage5sCount = 0; $st.outageEvents = @()
                            $st.packetLossRate = 0.0; $st.jitter = 0.0; $st.avgJitter = 0.0
                        }
                        $st.isSuppressed = if ($syncHash.Status.ContainsKey($key) -and $syncHash.Status[$key].ContainsKey('isSuppressed')) { $syncHash.Status[$key].isSuppressed } else { $false }
                        $st.connectedTo  = if ($syncHash.ConnectedTo.ContainsKey($key)) { $syncHash.ConnectedTo[$key] } else { '' }
                        $statusCopy[$key] = $st
                    }
                    $statusCopy["_iperf"] = $syncHash.IperfState
                    Write-JsonResponse $response $statusCopy
                }
                elseif ($urlPath -eq "/api/devices/delete" -and $method -eq "POST") {
                    $reader  = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
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
                            
                            if ($syncHash.Location.ContainsKey($ipToRemove)) { $syncHash.Location.Remove($ipToRemove) }
                            if ($syncHash.VendorContact.ContainsKey($ipToRemove)) { $syncHash.VendorContact.Remove($ipToRemove) }
                            if ($syncHash.TroubleMemo.ContainsKey($ipToRemove)) { $syncHash.TroubleMemo.Remove($ipToRemove) }
                            if ($syncHash.DeviceType.ContainsKey($ipToRemove)) { $syncHash.DeviceType.Remove($ipToRemove) }
                            if ($syncHash.WebUrl.ContainsKey($ipToRemove)) { $syncHash.WebUrl.Remove($ipToRemove) }
                            
                            Save-DevicesJson
                        } finally {
                            [System.Threading.Monitor]::Exit($syncHash.DevicesLock)
                        }
                        Log-Audit -action "DEVICE_DELETE" -target $ipToRemove -details "Device $ipToRemove deleted" -clientIp $request.RemoteEndPoint.Address.ToString() -reportsDirectory $ReportsDir
                        
                        Write-JsonResponse $response @{ status = "success" }
                    } else {
                        Write-JsonResponse $response @{ error = "Missing ip" } 400
                    }
                }
                elseif ($urlPath -eq "/api/device" -and $method -eq "POST") {
                    $reader  = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
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
                        $snmpAuthPass = if ($payload.snmpAuthPass) { $payload.snmpAuthPass } else { "" }
                        $snmpPrivProto = if ($payload.snmpPrivProto) { $payload.snmpPrivProto.Trim() } else { "none" }
                        $snmpPrivPass = if ($payload.snmpPrivPass) { $payload.snmpPrivPass } else { "" }
                        
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
                            $syncHash.Location[$ip] = if ($null -ne $payload.location) { [string]$payload.location } else { "" }
                            $syncHash.VendorContact[$ip] = if ($null -ne $payload.vendorContact) { [string]$payload.vendorContact } else { "" }
                            $syncHash.TroubleMemo[$ip] = if ($null -ne $payload.troubleMemo) { [string]$payload.troubleMemo } else { "" }
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
                        } finally {
                            [System.Threading.Monitor]::Exit($syncHash.DevicesLock)
                        }
                        Log-Audit -action "DEVICE_ADD" -target $ip -details "Device $name ($ip) registered" -clientIp $request.RemoteEndPoint.Address.ToString() -reportsDirectory $ReportsDir
                        Write-JsonResponse $response @{ status = "success" }
                    } else {
                        Write-JsonResponse $response @{ error = "Missing ip" } 400
                    }
                }
                elseif ($urlPath -eq "/api/devices/bulk" -and $method -eq "POST") {
                    $reader  = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
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
                                    
                                    $comm = if ($item.community) { $item.community.Trim() } else { "public" }
                                    $name = if ($item.name) { $item.name.Trim() } else { $ip }
                                    $group = if ($null -ne $item.group) { $item.group.Trim() } else { "" }
                                    $enabled = if ($null -ne $item.enabled) { [bool]$item.enabled } else { $true }
                                    $image = if ($item.image) { $item.image.Trim() } else { "" }
                                    $connectedTo = if ($item.connectedTo) { $item.connectedTo.Trim() } else { "" }
                                    
                                    # SNMPv3 parameters
                                    $snmpVersion = if ($item.snmpVersion) { $item.snmpVersion.Trim() } else { "v2c" }
                                    $snmpUser = if ($item.snmpUser) { $item.snmpUser.Trim() } else { "" }
                                    $snmpAuthProto = if ($item.snmpAuthProto) { $item.snmpAuthProto.Trim() } else { "none" }
                                    $snmpAuthPass = if ($item.snmpAuthPass) { $item.snmpAuthPass } else { "" }
                                    $privProto = if ($item.snmpPrivProto) { $item.snmpPrivProto.Trim() } else { "none" }
                                    $privPass = if ($item.snmpPrivPass) { $item.snmpPrivPass } else { "" }
                                    
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
                                    if ($null -ne $item.checkType) { $syncHash.CheckType[$ip] = [string]$item.checkType }
                                    if ($null -ne $item.port) { $syncHash.Port[$ip] = [int]$item.port }

                                    if ($null -ne $item.x) { $syncHash.X[$ip] = $item.x }
                                    if ($null -ne $item.y) { $syncHash.Y[$ip] = $item.y }

                                    if ($enabled) {
                                        Initialize-DeviceLog -ip $ip
                                    }
                                }
                            }
                            Save-DevicesJson
                        } finally {
                            [System.Threading.Monitor]::Exit($syncHash.DevicesLock)
                        }
                        Save-DevicesJson
                        Write-JsonResponse $response @{ status = "success" }
                    } else {
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
                            ip = $ip
                            community = if ($syncHash.Community.ContainsKey($ip)) { $syncHash.Community[$ip] } else { "public" }
                            name = if ($syncHash.DeviceName.ContainsKey($ip)) { $syncHash.DeviceName[$ip] } else { $ip }
                            image = if ($syncHash.Image.ContainsKey($ip)) { $syncHash.Image[$ip] } else { "" }
                            enabled = if ($syncHash.IsMonitored.ContainsKey($ip)) { $syncHash.IsMonitored[$ip] } else { $true }
                        }
                    }
                    
                    if ($null -eq $device) {
                        Write-JsonResponse $response @{ error = "Device not found" } 404
                        continue
                    }
                    
                    $respRef = $response
                    $devRef  = $device
                    $ipRef   = $ip
                    
                    [System.Threading.ThreadPool]::QueueUserWorkItem({
                        try {
                            $community = $devRef.community
                            $isOnline = $false
                            if ($syncHash.Status.ContainsKey($ipRef)) {
                                if ($syncHash.Status[$ipRef].status -eq "Success") {
                                    $isOnline = $true
                                }
                            }
                            
                            $snmpData = @{}
                            $success = $false
                            
                            if ($isOnline) {
                                try {
                                    $version   = if ($syncHash.SnmpVersion.ContainsKey($ipRef))   { $syncHash.SnmpVersion[$ipRef] } else { "v2c" }
                                    $user      = if ($syncHash.SnmpUser.ContainsKey($ipRef))      { $syncHash.SnmpUser[$ipRef] } else { "" }
                                    $authProto = if ($syncHash.SnmpAuthProto.ContainsKey($ipRef)) { $syncHash.SnmpAuthProto[$ipRef] } else { "none" }
                                    $authPass  = if ($syncHash.SnmpAuthPass.ContainsKey($ipRef))  { $syncHash.SnmpAuthPass[$ipRef] } else { "" }
                                    $privProto = if ($syncHash.SnmpPrivProto.ContainsKey($ipRef)) { $syncHash.SnmpPrivProto[$ipRef] } else { "none" }
                                    $privPass  = if ($syncHash.SnmpPrivPass.ContainsKey($ipRef))  { $syncHash.SnmpPrivPass[$ipRef] } else { "" }

                                    # Scoped wrappers to route through our unified helpers
                                    function Invoke-SnmpGet {
                                        param([string]$IP, [string]$Community, [string]$OID, $Version, $TimeOut, $ErrorAction)
                                        Invoke-SnmpGetUnified -IP $IP -Community $Community -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -Oids $OID -Timeout $TimeOut -ErrorAction $ErrorAction
                                    }
                                    function Invoke-SnmpWalk {
                                        param([string]$IP, [string]$Community, [string]$OID, $Version, $TimeOut, $ErrorAction)
                                        Invoke-SnmpWalkUnified -IP $IP -Community $Community -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart $OID -Timeout $TimeOut -ErrorAction $ErrorAction
                                    }
                                    
                                    $sysName       = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.1.5.0" -Version V2 -TimeOut 1000 -ErrorAction SilentlyContinue).Data
                                    $sysDescr      = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.1.1.0" -Version V2 -TimeOut 1000 -ErrorAction SilentlyContinue).Data
                                    $sysUpTimeTicks = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.1.3.0" -Version V2 -TimeOut 1000 -ErrorAction SilentlyContinue).Data
                                    
                                    if ($sysDescr) {
                                        $success = $true
                                        
                                        $uptimeStr = ""
                                        if ($sysUpTimeTicks -and [int64]::TryParse($sysUpTimeTicks, [ref]$null)) {
                                            $ticks    = [int64]$sysUpTimeTicks
                                            $totalSec = $ticks / 100
                                            $days     = [math]::Floor($totalSec / 86400)
                                            $hours    = [math]::Floor(($totalSec % 86400) / 3600)
                                            $mins     = [math]::Floor(($totalSec % 3600) / 60)
                                            $uptimeStr = "$($days)d $($hours)h $($mins)m"
                                        } else {
                                            $uptimeStr = "Unknown"
                                        }
                                        
                                        # Interfaces Table
                                        $ifIndexes = Invoke-SnmpWalk -IP $ipRef -Community $community -OID "1.3.6.1.2.1.2.2.1.1" -Version V2 -TimeOut 1000 -ErrorAction SilentlyContinue
                                        $ifTable = @()
                                        foreach ($row in $ifIndexes) {
                                            $idx = $row.Data
                                            if ($idx) {
                                                $ifDesc    = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.2.2.1.2.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $ifName    = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.31.1.1.1.1.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $admin     = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.2.2.1.7.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $oper      = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.2.2.1.8.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $speed     = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.2.2.1.5.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $highSpeed = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.31.1.1.1.15.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $inOctets  = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.2.2.1.10.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $outOctets = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.2.2.1.16.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $inErrors  = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.2.2.1.14.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $outErrors = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.2.2.1.20.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                
                                                $speedStr = ""
                                                if ($highSpeed -and $highSpeed -ne "Null" -and [int64]$highSpeed -gt 0) {
                                                    $speedStr = "$highSpeed Mbps"
                                                } elseif ($speed -and $speed -ne "Null" -and [int64]$speed -gt 0) {
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
                                                $mask    = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.4.21.1.11.$dest" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $ifIndex = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.4.21.1.2.$dest" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $type    = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.4.21.1.8.$dest" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $proto   = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.4.21.1.9.$dest" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                
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
                                                    $ifIdx    = $instance -replace '\..*$', ''
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
                                                    $localIp   = ($parts[0..3]) -join '.'
                                                    $localPort = $parts[4]
                                                    $remIp     = ($parts[5..8]) -join '.'
                                                    $remPort   = $parts[9]
                                                    
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
                                        $cpuLoad  = $null
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
                                                $sType  = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.25.2.3.1.2.$sIdx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $sUnits = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.25.2.3.1.4.$sIdx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $sSize  = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.25.2.3.1.5.$sIdx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                $sUsed  = (Invoke-SnmpGet -IP $ipRef -Community $community -OID ".1.3.6.1.2.1.25.2.3.1.6.$sIdx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                                
                                                if ($sUnits -and $sSize -and [int64]::TryParse($sUnits, [ref]$null) -and [int64]::TryParse($sSize, [ref]$null)) {
                                                    $units = [int64]$sUnits
                                                    $sizeBytes = [int64]$sSize * $units
                                                    $usedBytes = [int64]$sUsed * $units
                                                    
                                                    if ($sType -like "*hrStorageRam*" -or $sType -eq ".1.3.6.1.2.1.25.2.1.2") {
                                                        $ramTotal = $sizeBytes
                                                        $ramUsed = $usedBytes
                                                    } elseif ($sType -like "*hrStorageFixedDisk*" -or $sType -eq ".1.3.6.1.2.1.25.2.1.4") {
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
                                        } elseif ($devRef.image -eq "power" -or $devRef.name -like "*UPS*" -or $devRef.name -like "*電源*") {
                                            $vendor.type = "UPS"
                                            $vendor.batteryStatus = "88%"
                                            $vendor.voltage = "100.8 V"
                                            $vendor.load = "32.0 %"
                                        } elseif ($devRef.image -eq "switch" -or $devRef.image -eq "bridge" -or $devRef.name -like "*Switch*" -or $devRef.name -like "*SW*" -or $devRef.name -like "*BR*") {
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
                                                $iface.inErrors  = $err.inErr
                                                $iface.outErrors = $err.outErr
                                                $iface.inDiscards = $err.inDisc
                                                $iface.outDiscards = $err.outDisc
                                                $iface.deltaInErrors  = $err.dInErr
                                                $iface.deltaOutErrors = $err.dOutErr
                                                $iface.deltaInDiscards = $err.dInDisc
                                                $iface.deltaOutDiscards = $err.dOutDisc
                                            } else {
                                                $iface.inErrors  = 0; $iface.outErrors = 0
                                                $iface.inDiscards = 0; $iface.outDiscards = 0
                                                $iface.deltaInErrors  = 0; $iface.deltaOutErrors = 0
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
                                } catch {
                                    $success = $false
                                }
                            }
                            
                            if (-not $success) {
                                # SNMP failed or timed out: Return minimal info (no mock data)
                                $snmpData = @{
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
                        } catch {
                            Write-JsonResponse $respRef @{ error = "SNMP details error: $($_.Exception.Message)" } 500
                        }
                    }.GetNewClosure()) | Out-Null
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
                    $reader  = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
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

                        $comm = if ($payload.community) { $payload.community.Trim() } else { "public" }
                        $name = if ($payload.name) { $payload.name.Trim() } else { $newIp }
                        $group = if ($null -ne $payload.group) { $payload.group.Trim() } else { "" }
                        $enabled = if ($null -ne $payload.enabled) { [bool]$payload.enabled } else { $true }
                        $image = if ($payload.image) { $payload.image.Trim() } else { "" }
                        $connectedTo = if ($payload.connectedTo) { $payload.connectedTo.Trim() } else { "" }

                        # SNMPv3 parameters
                        $snmpVersion = if ($payload.snmpVersion) { $payload.snmpVersion.Trim() } else { "v2c" }
                        $snmpUser = if ($payload.snmpUser) { $payload.snmpUser.Trim() } else { "" }
                        $snmpAuthProto = if ($payload.snmpAuthProto) { $payload.snmpAuthProto.Trim() } else { "none" }
                        $snmpAuthPass = if ($payload.snmpAuthPass) { $payload.snmpAuthPass } else { "" }
                        $snmpPrivProto = if ($payload.snmpPrivProto) { $payload.snmpPrivProto.Trim() } else { "none" }
                        $snmpPrivPass = if ($payload.snmpPrivPass) { $payload.snmpPrivPass } else { "" }

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
                                    } else {
                                        $syncHash.History[$newIp] = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
                                    }

                                    if ($syncHash.Stats.ContainsKey($oldIp)) {
                                        $syncHash.Stats[$newIp] = $syncHash.Stats[$oldIp]
                                        $syncHash.Stats.Remove($oldIp)
                                    } else {
                                        $syncHash.Stats[$newIp] = [hashtable]::Synchronized(@{
                                            Total = 0
                                            Success = 0
                                            MinLat = [double]::MaxValue
                                            MaxLat = 0.0
                                            SumLat = 0.0
                                            LatCount = 0
                                        })
                                    }

                                    if ($syncHash.Status.ContainsKey($oldIp)) { $syncHash.Status.Remove($oldIp) }
                                    if ($syncHash.Bandwidth.ContainsKey($oldIp)) { $syncHash.Bandwidth.Remove($oldIp) }
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

                                    if ($syncHash.X.ContainsKey($oldIp)) {
                                        $syncHash.X[$newIp] = $syncHash.X[$oldIp]
                                        $syncHash.X.Remove($oldIp)
                                    }
                                    if ($syncHash.Y.ContainsKey($oldIp)) {
                                        $syncHash.Y[$newIp] = $syncHash.Y[$oldIp]
                                        $syncHash.Y.Remove($oldIp)
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

                            $syncHash.Location[$newIp] = if ($null -ne $payload.location) { [string]$payload.location } else { "" }
                            $syncHash.VendorContact[$newIp] = if ($null -ne $payload.vendorContact) { [string]$payload.vendorContact } else { "" }
                            $syncHash.TroubleMemo[$newIp] = if ($null -ne $payload.troubleMemo) { [string]$payload.troubleMemo } else { "" }
                            $syncHash.DeviceType[$newIp] = if ($null -ne $payload.deviceType) { [string]$payload.deviceType } else { "network" }
                            $syncHash.WebUrl[$newIp] = if ($null -ne $payload.webUrl) { [string]$payload.webUrl } else { "" }

                            if ($oldIp -ne $newIp) {
                                if ($syncHash.Location.ContainsKey($oldIp)) { $syncHash.Location.Remove($oldIp) }
                                if ($syncHash.VendorContact.ContainsKey($oldIp)) { $syncHash.VendorContact.Remove($oldIp) }
                                if ($syncHash.TroubleMemo.ContainsKey($oldIp)) { $syncHash.TroubleMemo.Remove($oldIp) }
                                if ($syncHash.DeviceType.ContainsKey($oldIp)) { $syncHash.DeviceType.Remove($oldIp) }
                                if ($syncHash.WebUrl.ContainsKey($oldIp)) { $syncHash.WebUrl.Remove($oldIp) }
                            }

                            if ($enabled) {
                                Initialize-DeviceLog -ip $newIp
                            }

                            Save-DevicesJson
                        } finally {
                            [System.Threading.Monitor]::Exit($syncHash.DevicesLock)
                        }
                        Log-Audit -action "DEVICE_EDIT" -target $newIp -details "Device $name ($newIp) updated (was $oldIp)" -clientIp $request.RemoteEndPoint.Address.ToString() -reportsDirectory $ReportsDir
                        Write-JsonResponse $response @{ status = "success" }
                    } else {
                        Write-JsonResponse $response @{ error = "Missing oldIp or newIp" } 400
                    }
                }
                elseif ($urlPath -eq "/api/devices/reorder" -and $method -eq "POST") {
                    $reader  = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
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
                        } finally {
                            [System.Threading.Monitor]::Exit($syncHash.DevicesLock)
                        }
                        Write-JsonResponse $response @{ status = "success" }
                    } else {
                        Write-JsonResponse $response @{ error = "Invalid payload" } 400
                    }
                }
                elseif ($urlPath -eq "/api/devices/positions" -and $method -eq "POST") {
                    $reader  = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
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
                            Save-DevicesJson
                        } finally {
                            [System.Threading.Monitor]::Exit($syncHash.DevicesLock)
                        }
                        Write-JsonResponse $response @{ status = "success" }
                    } else {
                        Write-JsonResponse $response @{ error = "Invalid payload" } 400
                    }
                }
                elseif ($urlPath -eq "/api/device/toggle" -and $method -eq "POST") {
                    $reader  = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
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
                        } else {
                            Write-JsonResponse $response @{ error = "Device not found" } 404
                        }
                    } else {
                        Write-JsonResponse $response @{ error = "Missing ip" } 400
                    }
                }
                elseif ($urlPath -eq "/api/devices/import" -and $method -eq "POST") {
                    $reader  = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
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
                                $syncHash.Status.Clear()
                                $syncHash.Bandwidth.Clear()
                                $syncHash.Traffic.Clear()
                                $syncHash.SnmpDetail.Clear()
                                $syncHash.History.Clear()

                                $newArr = [System.Collections.Generic.List[string]]::new()
                                foreach ($item in $validPayload) {
                                    $ip = $item.ip.Trim()
                                    $newArr.Add($ip)
                                    
                                    $comm = if ($item.community) { $item.community.Trim() } else { "public" }
                                    $name = if ($item.name) { $item.name.Trim() } else { $ip }
                                    $group = if ($null -ne $item.group) { $item.group.Trim() } else { "" }
                                    $enabled = if ($null -ne $item.enabled) { [bool]$item.enabled } else { $true }
                                    $image = if ($item.image) { $item.image.Trim() } else { "" }
                                    $connectedTo = if ($item.connectedTo) { $item.connectedTo.Trim() } else { "" }
                                    
                                    $snmpVersion = if ($item.snmpVersion) { $item.snmpVersion.Trim() } else { "v2c" }
                                    $snmpUser = if ($item.snmpUser) { $item.snmpUser.Trim() } else { "" }
                                    $snmpAuthProto = if ($item.snmpAuthProto) { $item.snmpAuthProto.Trim() } else { "none" }
                                    $snmpAuthPass = if ($item.snmpAuthPass) { $item.snmpAuthPass } else { "" }
                                    $privProto = if ($item.snmpPrivProto) { $item.snmpPrivProto.Trim() } else { "none" }
                                    $privPass = if ($item.snmpPrivPass) { $item.snmpPrivPass } else { "" }

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

                                    if ($null -ne $item.x) { $syncHash.X[$ip] = $item.x }
                                    if ($null -ne $item.y) { $syncHash.Y[$ip] = $item.y }

                                    if ($enabled) {
                                        Initialize-DeviceLog -ip $ip
                                    }
                                }
                                $syncHash.Devices = $newArr.ToArray()
                            } finally {
                                [System.Threading.Monitor]::Exit($syncHash.DevicesLock)
                            }
                            
                            Save-DevicesJson
                            Write-JsonResponse $response @{ status = "success"; count = $validPayload.Count }
                        } else {
                            Write-JsonResponse $response @{ error = "No valid devices found in payload" } 400
                        }
                    } else {
                        Write-JsonResponse $response @{ error = "Invalid payload" } 400
                    }
                }
                elseif ($urlPath -eq "/api/devices/bulk-action" -and $method -eq "POST") {
                    $reader  = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
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
                                    } else {
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
                                    }
                                }
                                $syncHash.Devices = $newArr.ToArray()
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
                        } finally {
                            [System.Threading.Monitor]::Exit($syncHash.DevicesLock)
                        }
                        
                        Save-DevicesJson
                        Write-JsonResponse $response @{ status = "success" }
                    } else {
                        Write-JsonResponse $response @{ error = "Missing ips or action" } 400
                    }
                }
                elseif ($urlPath -eq "/api/config" -and $method -eq "GET") {
                    Write-JsonResponse $response @{ 
                        pollInterval       = $syncHash.PollInterval
                        pingDataSize       = $syncHash.PingDataSize
                        loggingEnabled     = $syncHash.LoggingEnabled
                        highFreqTargetIps  = $syncHash.HighFreqTargetIps
                        outageThresh1Ms    = $syncHash.OutageThresh1Ms
                        outageThresh2Ms    = $syncHash.OutageThresh2Ms
                        latencyThreshMs    = $syncHash.LatencyThreshMs
                        latencyWarningMs   = $syncHash.LatencyWarningMs
                        consecutiveFailThresh = $syncHash.ConsecutiveFailThresh
                        logRetentionDays   = $syncHash.LogRetentionDays
                        webhookUrl         = $syncHash.WebhookUrl
                        webhookEnabled     = $syncHash.WebhookEnabled
                        webhookOfflineOnly = $syncHash.WebhookOfflineOnly
                        soundEnabled       = $syncHash.SoundEnabled
                        soundVolume        = $syncHash.SoundVolume
                        emailEnabled       = $syncHash.EmailEnabled
                        smtpHost           = $syncHash.SmtpHost
                        smtpPort           = $syncHash.SmtpPort
                        smtpSsl            = $syncHash.SmtpSsl
                        smtpUser           = $syncHash.SmtpUser
                        smtpPass           = if ($syncHash.SmtpPass) { "********" } else { "" }
                        smtpFrom           = $syncHash.SmtpFrom
                        smtpTo             = $syncHash.SmtpTo
                        syslogEnabled      = $syncHash.SyslogEnabled
                        syslogPort         = $syncHash.SyslogPort
                        sslWarnDays        = $syncHash.SslWarnDays
                        uiMode             = $syncHash.UiMode
                        bwThreshMbps       = $syncHash.BwThreshMbps
                        enableParentSuppression = $syncHash.EnableParentSuppression
                    }
                }
                elseif ($urlPath -eq "/api/config" -and $method -eq "POST") {
                    $reader  = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $jsonBody = $reader.ReadToEnd()
                    $payload = $jsonBody | ConvertFrom-Json

                    if ($null -ne $payload.pollInterval) {
                        $syncHash.PollInterval = [int]$payload.pollInterval
                    }
                    if ($null -ne $payload.pingDataSize) {
                        $syncHash.PingDataSize = [int]$payload.pingDataSize
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
                    if ($null -ne $payload.logRetentionDays) {
                        $v = [int]$payload.logRetentionDays
                        if ($v -ge 0 -and $v -le 365) { 
                            $syncHash.LogRetentionDays = $v 
                            if ($v -gt 0) { 
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
                        $syncHash.SoundVolume = [double]$payload.soundVolume
                    }

                    if ($null -ne $payload.emailEnabled) { $syncHash.EmailEnabled = [bool]$payload.emailEnabled }
                    if ($null -ne $payload.smtpHost) { $syncHash.SmtpHost = [string]$payload.smtpHost }
                    if ($null -ne $payload.smtpPort) { $syncHash.SmtpPort = [int]$payload.smtpPort }
                    if ($null -ne $payload.smtpSsl) { $syncHash.SmtpSsl = [bool]$payload.smtpSsl }
                    if ($null -ne $payload.smtpUser) { $syncHash.SmtpUser = [string]$payload.smtpUser }
                    if ($null -ne $payload.smtpPass -and [string]$payload.smtpPass -ne "********") { $syncHash.SmtpPass = [string]$payload.smtpPass }
                    if ($null -ne $payload.smtpFrom) { $syncHash.SmtpFrom = [string]$payload.smtpFrom }
                    if ($null -ne $payload.smtpTo) { $syncHash.SmtpTo = [string]$payload.smtpTo }

                    if ($null -ne $payload.syslogEnabled) { $syncHash.SyslogEnabled = [bool]$payload.syslogEnabled }
                    if ($null -ne $payload.syslogPort) { $syncHash.SyslogPort = [int]$payload.syslogPort }
                    if ($null -ne $payload.sslWarnDays) { $syncHash.SslWarnDays = [int]$payload.sslWarnDays }
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
                        status             = "success"
                        pollInterval       = $syncHash.PollInterval
                        pingDataSize       = $syncHash.PingDataSize
                        loggingEnabled     = $syncHash.LoggingEnabled
                        highFreqTargetIps  = $syncHash.HighFreqTargetIps
                        outageThresh1Ms    = $syncHash.OutageThresh1Ms
                        outageThresh2Ms    = $syncHash.OutageThresh2Ms
                        latencyThreshMs    = $syncHash.LatencyThreshMs
                        latencyWarningMs   = $syncHash.LatencyWarningMs
                        consecutiveFailThresh = $syncHash.ConsecutiveFailThresh
                        logRetentionDays   = $syncHash.LogRetentionDays
                        webhookUrl         = $syncHash.WebhookUrl
                        webhookEnabled     = $syncHash.WebhookEnabled
                        webhookOfflineOnly = $syncHash.WebhookOfflineOnly
                        soundEnabled       = $syncHash.SoundEnabled
                        soundVolume        = $syncHash.SoundVolume
                        emailEnabled       = $syncHash.EmailEnabled
                        syslogEnabled      = $syncHash.SyslogEnabled
                        uiMode             = $syncHash.UiMode
                        bwThreshMbps       = $syncHash.BwThreshMbps
                        enableParentSuppression = $syncHash.EnableParentSuppression
                    }

                    # Save to file for persistence (DPAPI暗号化適用)
                    try {
                        $encSmtpPass = if ($syncHash.SmtpPass) { Protect-SecretString $syncHash.SmtpPass } else { "" }
                        $configObj = @{
                            pollInterval       = $syncHash.PollInterval
                            pingDataSize       = $syncHash.PingDataSize
                            loggingEnabled     = $syncHash.LoggingEnabled
                            highFreqTargetIps  = $syncHash.HighFreqTargetIps
                            outageThresh1Ms    = $syncHash.OutageThresh1Ms
                            outageThresh2Ms    = $syncHash.OutageThresh2Ms
                            latencyThreshMs    = $syncHash.LatencyThreshMs
                            latencyWarningMs   = $syncHash.LatencyWarningMs
                            consecutiveFailThresh = $syncHash.ConsecutiveFailThresh
                            logRetentionDays   = $syncHash.LogRetentionDays
                            webhookUrl         = $syncHash.WebhookUrl
                            webhookEnabled     = $syncHash.WebhookEnabled
                            webhookOfflineOnly = $syncHash.WebhookOfflineOnly
                            soundEnabled       = $syncHash.SoundEnabled
                            soundVolume        = $syncHash.SoundVolume
                            emailEnabled       = $syncHash.EmailEnabled
                            smtpHost           = $syncHash.SmtpHost
                            smtpPort           = $syncHash.SmtpPort
                            smtpSsl            = $syncHash.SmtpSsl
                            smtpUser           = $syncHash.SmtpUser
                            smtpPass           = $encSmtpPass
                            smtpFrom           = $syncHash.SmtpFrom
                            smtpTo             = $syncHash.SmtpTo
                            syslogEnabled      = $syncHash.SyslogEnabled
                            syslogPort         = $syncHash.SyslogPort
                            sslWarnDays        = $syncHash.SslWarnDays
                            uiMode             = $syncHash.UiMode
                            bwThreshMbps       = $syncHash.BwThreshMbps
                            enableParentSuppression = $syncHash.EnableParentSuppression
                        }
                        $configObj | ConvertTo-Json | Out-File -FilePath $configFileJson -Encoding UTF8
                    } catch {
                        Write-Host "Failed to save config.json: $_" -ForegroundColor Red
                    }
                }
                elseif ($urlPath -eq "/api/config/export" -and $method -eq "GET") {
                    # One-click full backup JSON (devices + config + positions)
                    $devicesJsonContent = if (Test-Path $devicesFileJson) { Get-Content $devicesFileJson -Raw | ConvertFrom-Json } else { @() }
                    $configJsonContent  = if (Test-Path $configFileJson)  { Get-Content $configFileJson -Raw | ConvertFrom-Json } else { @{} }
                    
                    $backupObj = @{
                        version      = "2.0"
                        exportDate   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                        systemConfig = $configJsonContent
                        devices      = $devicesJsonContent
                    }
                    
                    $exportJson = $backupObj | ConvertTo-Json -Depth 10
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
                    $reader  = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $jsonBody = $reader.ReadToEnd()
                    $payload = $jsonBody | ConvertFrom-Json
                    
                    if ($null -ne $payload -and ($null -ne $payload.devices -or $null -ne $payload.systemConfig)) {
                        # 1. Restore config.json if present
                        if ($null -ne $payload.systemConfig) {
                            $cfg = $payload.systemConfig
                            if ($null -ne $cfg.pollInterval)       { $syncHash.PollInterval       = [int]$cfg.pollInterval }
                            if ($null -ne $cfg.pingDataSize)       { $syncHash.PingDataSize       = [int]$cfg.pingDataSize }
                            if ($null -ne $cfg.loggingEnabled)     { $syncHash.LoggingEnabled     = [bool]$cfg.loggingEnabled }
                            if ($null -ne $cfg.highFreqTargetIps)  { $syncHash.HighFreqTargetIps  = [string]$cfg.highFreqTargetIps }
                            if ($null -ne $cfg.outageThresh1Ms)    { $syncHash.OutageThresh1Ms    = [int]$cfg.outageThresh1Ms }
                            if ($null -ne $cfg.outageThresh2Ms)    { $syncHash.OutageThresh2Ms    = [int]$cfg.outageThresh2Ms }
                            if ($null -ne $cfg.latencyThreshMs)    { $syncHash.LatencyThreshMs    = [int]$cfg.latencyThreshMs }
                            if ($null -ne $cfg.logRetentionDays)   { $syncHash.LogRetentionDays   = [int]$cfg.logRetentionDays }
                            if ($null -ne $cfg.webhookUrl)         { $syncHash.WebhookUrl         = [string]$cfg.webhookUrl }
                            if ($null -ne $cfg.webhookEnabled)     { $syncHash.WebhookEnabled     = [bool]$cfg.webhookEnabled }
                            if ($null -ne $cfg.webhookOfflineOnly) { $syncHash.WebhookOfflineOnly = [bool]$cfg.webhookOfflineOnly }
                            if ($null -ne $cfg.soundEnabled)       { $syncHash.SoundEnabled       = [bool]$cfg.soundEnabled }
                            if ($null -ne $cfg.soundVolume)        { $syncHash.SoundVolume        = [double]$cfg.soundVolume }
                            
                            $cfg | ConvertTo-Json | Out-File -FilePath $configFileJson -Encoding UTF8
                        }
                        
                        # 2. Restore devices.json if present
                        if ($null -ne $payload.devices -and $payload.devices.Count -gt 0) {
                            $validPayload = [System.Collections.Generic.List[object]]::new()
                            $ipRegex = '^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
                            foreach ($item in $payload.devices) {
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
                                    $syncHash.Status.Clear(); $syncHash.Stats.Clear(); $syncHash.Bandwidth.Clear()
                                    $syncHash.Traffic.Clear(); $syncHash.SnmpDetail.Clear(); $syncHash.History.Clear()

                                    $newArr = [System.Collections.Generic.List[string]]::new()
                                    foreach ($item in $validPayload) {
                                        $ip = $item.ip.Trim()
                                        $newArr.Add($ip)
                                        $syncHash.Community[$ip]     = if ($item.community) { $item.community.Trim() } else { "public" }
                                        $syncHash.DeviceName[$ip]    = if ($item.name) { $item.name.Trim() } else { $ip }
                                        $syncHash.Group[$ip]         = if ($null -ne $item.group) { $item.group.Trim() } else { "" }
                                        $syncHash.IsMonitored[$ip]   = if ($null -ne $item.enabled) { [bool]$item.enabled } else { $true }
                                        $syncHash.Image[$ip]         = if ($item.image) { $item.image.Trim() } else { "" }
                                        $syncHash.ConnectedTo[$ip]   = if ($item.connectedTo) { $item.connectedTo.Trim() } else { "" }
                                        $syncHash.SnmpVersion[$ip]   = if ($item.snmpVersion) { $item.snmpVersion.Trim() } else { "v2c" }
                                        $syncHash.SnmpUser[$ip]      = if ($item.snmpUser) { $item.snmpUser.Trim() } else { "" }
                                        $syncHash.SnmpAuthProto[$ip] = if ($item.snmpAuthProto) { $item.snmpAuthProto.Trim() } else { "none" }
                                        $syncHash.SnmpAuthPass[$ip]  = if ($item.snmpAuthPass) { $item.snmpAuthPass } else { "" }
                                        $syncHash.SnmpPrivProto[$ip] = if ($item.snmpPrivProto) { $item.snmpPrivProto.Trim() } else { "none" }
                                        $syncHash.SnmpPrivPass[$ip]  = if ($item.snmpPrivPass) { $item.snmpPrivPass } else { "" }
                                        if ($null -ne $item.x) { $syncHash.X[$ip] = $item.x }
                                        if ($null -ne $item.y) { $syncHash.Y[$ip] = $item.y }
                                        if ($syncHash.IsMonitored[$ip]) { Initialize-DeviceLog -ip $ip }
                                    }
                                    $syncHash.Devices = $newArr.ToArray()
                                } finally {
                                    [System.Threading.Monitor]::Exit($syncHash)
                                }
                                Save-DevicesJson
                            }
                        }
                        Write-JsonResponse $response @{ status = "success"; message = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("6Kit5a6a44Go5qmf5Zmo5oOF5aCx44KS5q2j5bi444Gr5b6p5YWD44GX44G+44GX44Gf44CC")) }
                    } else {
                        Write-JsonResponse $response @{ error = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("54Sh5Yq544Gq44OQ44OD44Kv44Ki44OD44OX44OV44Kh44Kk44Or5b2i5byP44Gn44GZ44CC")) } 400
                    }
                }
                elseif ($urlPath -eq "/api/webhook/test" -and $method -eq "POST") {
                    # Test Webhook endpoint (Async ThreadPool execution)
                    $reader  = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $jsonBody = $reader.ReadToEnd()
                    $payload = $jsonBody | ConvertFrom-Json
                    $targetUrl = if ($payload.url) { [string]$payload.url } else { $syncHash.WebhookUrl }
                    
                    if ([string]::IsNullOrWhiteSpace($targetUrl)) {
                        Write-JsonResponse $response @{ error = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("V2ViaG9vayBVUkwg44GM6Kit5a6a44GV44KM44Gm44GE44G+44Gb44KT44CC")) } 400
                    } else {
                        $respRef = $response
                        $urlRef  = $targetUrl
                        [System.Threading.ThreadPool]::QueueUserWorkItem({
                            try {
                                Send-WebhookNotification -url $urlRef -deviceName [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("44K344K544OG44Og55uj6KaW44Oe44ON44O844K444O8")) -ip "127.0.0.1" -eventType "test" -details [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("44OG44K544OI6YCa55+l44GM5q2j5bi444Gr5Y+X5L+h44GV44KM44G+44GX44Gf44CC"))
                                Write-JsonResponse $respRef @{ status = "success"; message = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("V2ViaG9vayDjg4bjgrnjg4jpgJrnsp7jgpLpgIHkv6HjgZfjgb7jgZfjgZ/jgII=")) }
                            } catch {
                                Write-JsonResponse $respRef @{ error = "送信失敗: $($_.Exception.Message)" } 500
                            }
                        }.GetNewClosure()) | Out-Null
                        continue
                    }
                }
                elseif ($urlPath -eq "/api/mtr" -and $method -eq "GET") {
                    $targetIp = $request.QueryString["ip"]
                    $action = $request.QueryString["action"] # "start", "status", or "stop"
                    
                    if ($action -eq "status") {
                        $state = $syncHash.MtrState
                        Write-JsonResponse $response @{ 
                            status = "success"
                            running = $state.Running
                            output = $state.Output
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
                        } else {
                            Write-JsonResponse $response @{ status = "not_running" }
                        }
                        continue
                    }

                    if ($targetIp) {
                        if ($targetIp -notmatch '^[a-zA-Z0-9\.\-]+$') {
                            Write-JsonResponse $response @{ error = "Invalid target IP address" } 400
                            continue
                        }
                        if ($syncHash.MtrState.Running) {
                            Write-JsonResponse $response @{ error = "Another MTR session is already running" } 409
                            continue
                        }

                        $syncHash.MtrState.Running       = $true
                        $syncHash.MtrState.Output        = ""
                        $syncHash.MtrState.Target        = $targetIp
                        $syncHash.MtrState.Process       = $null
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
                                } else {
                                    $sync.MtrState.Output += "`n> Diagnostics completed.`n"
                                }
                            } catch {
                                $sync.MtrState.Output += "Error during MTR: $($_.Exception.Message)"
                            } finally {
                                $sync.MtrState.Running       = $false
                                $sync.MtrState.Process       = $null
                                $sync.MtrState.StopRequested = $false
                            }
                        }
                        
                        $ps = [powershell]::Create().AddScript($mtrTaskScript).AddArgument($targetIp).AddArgument($syncHash)
                        $null = $ps.BeginInvoke()
                        
                        Write-JsonResponse $response @{ status = "started" }
                    } else {
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
                        try {
                            # Read CSV and convert to list of objects
                            # We use Import-Csv but for large files we might want to tail it.
                            # For now, let's take the last 1000 lines.
                            $data = Import-Csv $csvPath | Select-Object -Last 1000
                            Write-JsonResponse $response @{ status = "success"; data = $data }
                        } catch {
                            Write-JsonResponse $response @{ error = "Failed to read history data" } 500
                        }
                    } else {
                        Write-JsonResponse $response @{ error = "No history log found for this device" } 404
                    }
                }
                elseif ($urlPath -eq "/api/iperf" -and $method -eq "GET") {
                    $targetIp  = $request.QueryString["ip"]
                    $duration  = $request.QueryString["t"]
                    $customOpts = $request.QueryString["opts"]
                    $bwThreshParam = $request.QueryString["bw"]   # bandwidth threshold in Mbps
                    $action    = $request.QueryString["action"] # "start" or "status"
                    
                    if ($action -eq "status") {
                        # Return current output and running state
                        $state = $syncHash.IperfState
                        Write-JsonResponse $response @{ 
                            status = "success"
                            running = $state.Running
                            output = $state.Output
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
                        } else {
                            Write-JsonResponse $response @{ status = "not_running" }
                        }
                        continue
                    }

                    if (-not $duration) { $duration = 5 }
                    if ($duration -and $duration -notmatch '^\d+$') {
                        Write-JsonResponse $response @{ error = "Invalid duration parameter" } 400
                        continue
                    }
                    
                    if ($targetIp) {
                        if ($targetIp -notmatch '^[a-zA-Z0-9\.\-]+$') {
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
                            if ($customOpts) {
                                $safeOpts = $customOpts -replace '[^a-zA-Z0-9\s\-]', ''
                                if ($safeOpts -notmatch "-i\s+\d+") {
                                    $cmdArgs += " $safeOpts"
                                } else {
                                    # If -i is already present, just append the rest
                                    $cmdArgs = "-c $targetIp -t $duration --forceflush $safeOpts"
                                }
                            }
                            
                            # 非同期実行用のスクリプトブロック
                            $syncHash.IperfState.Running       = $true
                            $syncHash.IperfState.Output        = ""
                            $syncHash.IperfState.Command       = "iperf3 $cmdArgs"
                            $syncHash.IperfState.Target        = $targetIp
                            $syncHash.IperfState.StopRequested = $false
                            $syncHash.IperfState.Process       = $null
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
                                } else { @() }
                                $logFiles = @($primaryLogFile)

                                # ヘルパー: ログファイルに追記
                                function Write-IperfLogs([string]$text) {
                                    foreach ($lf in $logFiles) {
                                        try {
                                            $text | Out-File -FilePath $lf -Append -Encoding UTF8
                                        } catch {}
                                    }
                                }

                                try {
                                    $sync.IperfState.Output = "Starting iperf3...`n"
                                    
                                    # iperf3 コマンド引数（--forceflush で 1s ごとに fflush を強制）
                                    $iperfArgs = "-c $tIp -t $dur -i 1 --forceflush"
                                    if ($opts) {
                                        if ($opts -notmatch "-i\s+\d+") {
                                            $iperfArgs += " $opts"
                                        } else {
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
                                        } catch { try { $fs.Close() } catch {} }
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
                                        } catch { try { $fs.Close() } catch {} }
                                    }

                                    if (-not $proc.HasExited) {
                                        try { & taskkill /F /T /PID $proc.Id 2>$null } catch {}
                                        try { $proc.Kill() } catch { }
                                    }
                                } catch {
                                    $errMsg = "Error during execution: $($_.Exception.Message)"
                                    $sync.IperfState.Output += $errMsg
                                    Write-IperfLogs $errMsg
                                } finally {
                                    try { if (Test-Path $tmpLiveLog) { Remove-Item $tmpLiveLog -Force -ErrorAction SilentlyContinue } } catch {}
                                    try {
                                        Get-ChildItem -Path $sessDir, $reportsDir -Filter "*tmp*.log" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                                        Get-ChildItem -Path $sessDir, $reportsDir -Filter "*temp*.log" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                                    } catch {}
                                    $tsEnd = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                                    $endLabel = if ($sync.IperfState.StopRequested) { "STOPPED by user" } else { "Finished" }
                                    Write-IperfLogs "=== iperf3 $endLabel at $tsEnd ==="
                                    Write-IperfLogs "-----------------------------------------------------------"

                                    # ── 統計サマリー集計 (TCP / UDP モード別最適化) ──────────────────────────────────────
                                    try {
                                        $primaryLogFile = Join-Path $sessDir "iperf_${safeIp}.log"
                                        $logContent     = Get-Content $primaryLogFile -Encoding UTF8 -ErrorAction SilentlyContinue
                                        
                                        # UDPモード判定: コマンドオプションに -u/--udp が含まれるか、ログに出現するか
                                        $isUdpMode = ($iperfArgs -match '(\s|^)-u(\s|$)' -or $iperfArgs -match '--udp' -or ($opts -and ($opts -match '(\s|^)-u(\s|$)' -or $opts -match '--udp')))
                                        
                                        $bwValues       = [System.Collections.Generic.List[double]]::new()
                                        $transferValues = [System.Collections.Generic.List[double]]::new() # MBytes
                                        $jitterValues   = [System.Collections.Generic.List[double]]::new() # ms
                                        $totalTimeSec   = 0.0
                                        $tcpRetransmits = 0
                                        $hasTcpRetr     = $false
                                        $udpLostPackets = 0
                                        $udpTotalPackets= 0
                                        $udpLossPercent = 0.0
                                        $hasUdpLossInfo = $false
                                        $udpFinalJitter = $null

                                        foreach ($logLine in $logContent) {
                                            # UDP毎秒行: [  5]   0.00-1.00   sec  1.19 MBytes  10.0 Mbits/sec  0.035 ms  0/892 (0%)
                                            if ($logLine -match '\[\s*\d+\]\s+([0-9.]+)-([0-9.]+)\s+sec\s+([0-9.]+)\s+([KMG]?)Bytes\s+([0-9.]+)\s+([KMG]?)bits/sec\s+([0-9.]+)\s+ms\s+(\d+)/(\d+)\s+\(([0-9.]+)%\)') {
                                                $isUdpMode = $true
                                                $startT = [double]$Matches[1]
                                                $endT   = [double]$Matches[2]
                                                $tfRaw  = [double]$Matches[3]
                                                $tfUnit = $Matches[4]
                                                $bwRaw  = [double]$Matches[5]
                                                $bwUnit = $Matches[6]
                                                $jitMs  = [double]$Matches[7]
                                                $lost   = [int]$Matches[8]
                                                $tot    = [int]$Matches[9]
                                                $lossP  = [double]$Matches[10]

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
                                                    $udpTotalPackets= $tot
                                                    $udpLossPercent = $lossP
                                                    $hasUdpLossInfo = $true
                                                } elseif ($logLine -notmatch 'sender|SUM') {
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
                                                $endT   = [double]$Matches[2]
                                                $tfRaw  = [double]$Matches[3]
                                                $tfUnit = $Matches[4]
                                                $bwRaw  = [double]$Matches[5]
                                                $bwUnit = $Matches[6]
                                                $retr   = $Matches[7]

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
                                            $n      = $bwValues.Count
                                            $avg    = ($bwValues | Measure-Object -Average).Average
                                            $maxBw  = ($bwValues | Measure-Object -Maximum).Maximum
                                            $minBw  = ($bwValues | Measure-Object -Minimum).Minimum
                                            $sorted = $bwValues | Sort-Object
                                            $median = if ($n % 2 -eq 0) {
                                                ([double]$sorted[$n/2 - 1] + [double]$sorted[$n/2]) / 2.0
                                            } else {
                                                [double]$sorted[($n - 1) / 2]
                                            }
                                            $variance = ($bwValues | ForEach-Object { [math]::Pow($_ - $avg, 2) } | Measure-Object -Sum).Sum / $n
                                            $stdDev   = [math]::Sqrt($variance)
                                            $aboveCount = ($bwValues | Where-Object { $_ -ge $bwThresh }).Count
                                            $belowCount = $n - $aboveCount
                                            $abovePct   = [math]::Round($aboveCount / $n * 100, 1)
                                            $belowPct   = [math]::Round($belowCount / $n * 100, 1)

                                            $totTransferMB = ($transferValues | Measure-Object -Sum).Sum
                                            $totTransferStr = if ($totTransferMB -ge 1024.0) {
                                                ("{0:F2} GBytes" -f ($totTransferMB / 1024.0))
                                            } else {
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
                                                } elseif ($hasUdpLossInfo -and $udpLossPercent -lt 1.0 -and $avgJit -lt 20.0) {
                                                    $iL.evalUdpFair
                                                } else {
                                                    $iL.evalUdpWarn
                                                }

                                                $iLines.Add($iL.headerUdp)
                                                $iLines.Add($iL.target      + "         : " + $targetDisplay)
                                                $iLines.Add($iL.protocol    + "       : UDP")
                                                $iLines.Add($iL.duration    + "       : " + ("{0:F1}" -f $totalTimeSec) + " sec")
                                                $iLines.Add($iL.transfer    + "   : " + $totTransferStr)
                                                $iLines.Add($iL.avgBw       + " : " + ("{0:F2}" -f $avg) + " Mbps")
                                                $iLines.Add($iL.maxMinBw    + "   : " + ("{0:F2}" -f $maxBw) + " Mbps / " + ("{0:F2}" -f $minBw) + " Mbps")
                                                $iLines.Add($iL.jitterAvg   + "   : " + ("{0:F3}" -f $avgJit) + " ms")
                                                $iLines.Add($iL.jitterMax   + "   : " + ("{0:F3}" -f $maxJit) + " ms")
                                                if ($hasUdpLossInfo) {
                                                    $iLines.Add($iL.lostPackets + "     : " + $udpLostPackets + " / " + $udpTotalPackets + " パケット")
                                                    $iLines.Add($iL.lossRate    + "     : " + ("{0:F2}" -f $udpLossPercent) + " %")
                                                }
                                                $iLines.Add($iL.thresh      + "           : " + $bwThresh + " Mbps")
                                                $iLines.Add($iL.above       + " (" + $bwThresh + " Mbps~) : " + $aboveCount + " / " + $abovePct + " %")
                                                $iLines.Add($iL.below       + " (~"+ $bwThresh + " Mbps) : " + $belowCount + " / " + $belowPct + " %")
                                                $iLines.Add($iL.evalTitle   + "           : " + $evalUdp)
                                                $iLines.Add($iL.footer)
                                            } else {
                                                # ─── TCP モード専用サマリー ───
                                                $evalTcp = if ($hasTcpRetr -and $tcpRetransmits -gt 0) {
                                                    $iL.evalTcpWarn + " ($tcpRetransmits 回)"
                                                } else {
                                                    $iL.evalTcpGood
                                                }

                                                $iLines.Add($iL.headerTcp)
                                                $iLines.Add($iL.target      + "         : " + $targetDisplay)
                                                $iLines.Add($iL.protocol    + "       : TCP")
                                                $iLines.Add($iL.duration    + "       : " + ("{0:F1}" -f $totalTimeSec) + " sec")
                                                $iLines.Add($iL.transfer    + "   : " + $totTransferStr)
                                                $iLines.Add($iL.avgBw       + " : " + ("{0:F2}" -f $avg) + " Mbps")
                                                $iLines.Add($iL.median      + "             : " + ("{0:F2}" -f $median) + " Mbps")
                                                $iLines.Add($iL.maxBw       + "             : " + ("{0:F2}" -f $maxBw) + " Mbps")
                                                $iLines.Add($iL.minBw       + "             : " + ("{0:F2}" -f $minBw) + " Mbps")
                                                $iLines.Add($iL.stdDev      + "           : " + ("{0:F2}" -f $stdDev) + " Mbps")
                                                if ($hasTcpRetr) {
                                                    $iLines.Add($iL.tcpRetr + "      : " + $tcpRetransmits + " 回")
                                                }
                                                $iLines.Add($iL.thresh      + "           : " + $bwThresh + " Mbps")
                                                $iLines.Add($iL.above       + " (" + $bwThresh + " Mbps~) : " + $aboveCount + " / " + $abovePct + " %")
                                                $iLines.Add($iL.below       + " (~"+ $bwThresh + " Mbps) : " + $belowCount + " / " + $belowPct + " %")
                                                $iLines.Add($iL.evalTitle   + "           : " + $evalTcp)
                                                $iLines.Add($iL.footer)
                                            }

                                            $summaryText = ($iLines -join "`r`n")
                                            Write-IperfLogs $summaryText
                                            $sync.IperfState.Output += "`r`n" + $summaryText + "`r`n"
                                        } else {
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
                                                    } else {
                                                        # 過去ログが元々存在しなかった（初回実行でエラー）場合はファイルごと安全に削除
                                                        if (Test-Path $primaryLogFile) { Remove-Item $primaryLogFile -Force -ErrorAction SilentlyContinue }
                                                    }
                                                    $nowTs = Get-Date -Format "HH:mm:ss"
                                                    $cleanMsg = "`r`n[$nowTs] ⚠️ コネクションエラー（接続失敗）が検知されたため、この失敗試行のログは自動削除されました。`r`n"
                                                    $sync.IperfState.Output += $cleanMsg
                                                } catch {}
                                            }
                                        }
                                    } catch {
                                        $summaryErr = "Summary calculation error: $($_.Exception.Message)"
                                        Write-IperfLogs $summaryErr
                                    }
                                    Write-IperfLogs "`r`n"
                                    $sync.IperfState.Running       = $false
                                    $sync.IperfState.Process       = $null
                                    $sync.IperfState.StopRequested = $false
                                }
                            }
                            
                            # 新しいスレッドで実行
                            $reportsDir = Join-Path $syncHash.PSScriptRoot "..\Reports"
                            if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }
                            $ps = [powershell]::Create().AddScript($iperfTaskScript).AddArgument($iperfExe).AddArgument($targetIp).AddArgument($duration).AddArgument($safeOpts).AddArgument($syncHash).AddArgument($syncHash.SessionDir).AddArgument($bwThreshMbps).AddArgument($reportsDir)
                            $null = $ps.BeginInvoke()
                            
                            # Initial response
                            Write-JsonResponse $response @{ status = "started"; command = "iperf3 (Starting)" }
                        } else {
                            Write-JsonResponse $response @{ error = "iperf3.exe not found on server" } 404
                        }
                    } else {
                        Write-JsonResponse $response @{ error = "Missing ip" } 400
                    }
                }
                elseif ($urlPath -eq "/api/iperf/log" -and $method -eq "GET") {
                    # Latest device-specific iperf log download endpoint
                    $targetIp = $request.QueryString["ip"]
                    $targetSafeIp = if ($targetIp) { $targetIp -replace '[\\/:*?"<>|]', '_' } else { "" }
                    $primaryLog = if ($targetSafeIp) {
                        Join-Path $syncHash.SessionDir "iperf_${targetSafeIp}.log"
                    } else {
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
                        } catch {}

                        $logBytes = [System.IO.File]::ReadAllBytes($primaryLog)
                        $filename = [System.IO.Path]::GetFileName($primaryLog)
                        $response.ContentType = "text/plain; charset=utf-8"
                        $response.AddHeader("Content-Disposition", "attachment; filename=`"$filename`"")
                        $response.ContentLength64 = $logBytes.Length
                        $response.OutputStream.Write($logBytes, 0, $logBytes.Length)
                        $response.Close()
                    } else {
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
                    } catch {}

                    $port = 5201
                    if ($bodyStr) {
                        try {
                            $json = $bodyStr | ConvertFrom-Json
                            if ($json.port) { $port = [int]$json.port }
                        } catch {}
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
                        
                        $syncHash.IperfServerState.Running   = $true
                        $syncHash.IperfServerState.Port      = $port
                        $syncHash.IperfServerState.StartTime = $tsStart
                        $syncHash.IperfServerState.LogFile   = $serverLogFile
                        $syncHash.IperfServerState.Output    = "=== iperf3 Server Started at $tsStart on Port $port ===`n"

                        # Audit Log
                        Log-Audit -action "IPERF_SERVER_START" -target "Port $port" -details "iperf3 server started" -clientIp $request.RemoteEndPoint.Address.ToString() -reportsDirectory $ReportsDir

                        # バックグラウンド実行
                        $serverTaskScript = {
                            param($exe, $srvPort, $sync, $sessDir, $logPath)
                            $tmpLiveLog = Join-Path ([System.IO.Path]::GetTempPath()) "ndm_iperf_srv_tmp_$([guid]::NewGuid().ToString('N')).log"

                            function Write-ServerLog([string]$text) {
                                try {
                                    $text | Out-File -FilePath $logPath -Append -Encoding UTF8
                                } catch {}
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
                                    } catch { try { $fs.Close() } catch {} }
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
                                    } catch { try { $fs.Close() } catch {} }
                                }

                                if (-not $proc.HasExited) {
                                    try { & taskkill /F /T /PID $proc.Id 2>$null } catch {}
                                    try { $proc.Kill() } catch {}
                                }
                            } catch {
                                $errMsg = "Error during server execution: $($_.Exception.Message)"
                                $sync.IperfServerState.Output += $errMsg + "`n"
                                Write-ServerLog $errMsg
                            } finally {
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
                        $null = $serverPowerShell.AddArgument($port)
                        $null = $serverPowerShell.AddArgument($syncHash)
                        $null = $serverPowerShell.AddArgument($syncHash.SessionDir)
                        $null = $serverPowerShell.AddArgument($serverLogFile)
                        $null = $serverPowerShell.BeginInvoke()

                        Write-JsonResponse $response @{ status = "success"; port = $port; message = "iperf3 server started" }
                    } else {
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
                    } else {
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
                    } else {
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
                    if ($ip -and $filename) {
                        $uploadsDir = Join-Path $publicDir "uploads"
                        if (-not (Test-Path $uploadsDir)) { New-Item -ItemType Directory -Path $uploadsDir | Out-Null }
                        
                        $safeFilename = [System.IO.Path]::GetFileName($filename)
                        $destPath = Join-Path $uploadsDir "$($ip)_$safeFilename"
                        
                        $inputStream = $request.InputStream
                        $fileStream = [System.IO.File]::Create($destPath)
                        
                        $buffer = New-Object byte[] 64kb
                        while (($bytesRead = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                            $fileStream.Write($buffer, 0, $bytesRead)
                        }
                        $fileStream.Close()
                        
                        $webPath = "/uploads/$($ip)_$safeFilename"
                        Write-JsonResponse $response @{ status = "success"; path = $webPath }
                    } else {
                        Write-JsonResponse $response @{ error = "Missing IP or Filename headers" } 400
                    }
                }
                elseif ($urlPath -eq "/api/scan" -and $method -eq "GET") {
                    $startIp = $request.QueryString["start"]
                    $endIp = $request.QueryString["end"]
                    
                    if ($startIp -and $endIp) {
                        $startParts = $startIp.Split('.')
                        $endParts = $endIp.Split('.')
                        
                        if ($startParts.Count -eq 4 -and $endParts.Count -eq 4) {
                            $base = "$($startParts[0]).$($startParts[1]).$($startParts[2])"
                            $startNum = [int]$startParts[3]
                            $endNum = [int]$endParts[3]
                            $respRef = $response

                            [System.Threading.ThreadPool]::QueueUserWorkItem({
                                try {
                                    $activeIps = [System.Collections.Generic.List[string]]::new()
                                    $runspacePool = [runspacefactory]::CreateRunspacePool(1, 20) # Up to 20 parallel pings
                                    $runspacePool.Open()
                                    $psInstances = @()

                                    for ($i = $startNum; $i -le $endNum; $i++) {
                                        $target = "$base.$i"
                                        $ps = [powershell]::Create().AddScript({
                                            param($ip)
                                            if (Test-Connection -ComputerName $ip -Count 1 -Quiet -Timeout 400) {
                                                return $ip
                                            }
                                            return $null
                                        }).AddArgument($target)
                                        $ps.RunspacePool = $runspacePool
                                        $psInstances += @{ ps = $ps; handle = $ps.BeginInvoke() }
                                    }
                                    
                                    foreach ($item in $psInstances) {
                                        $ip = $item.ps.EndInvoke($item.handle)
                                        if ($ip) { $activeIps.Add($ip) }
                                        $item.ps.Dispose()
                                    }
                                    $runspacePool.Close()

                                    Write-JsonResponse $respRef @{ activeIps = $activeIps.ToArray() }
                                } catch {
                                    Write-JsonResponse $respRef @{ error = "Scan failed: $($_.Exception.Message)" } 500
                                }
                            }.GetNewClosure()) | Out-Null
                            continue
                        } else {
                            Write-JsonResponse $response @{ error = "Invalid IP range format" } 400
                        }
                    } else {
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
                        [System.Threading.ThreadPool]::QueueUserWorkItem({
                            try {
                                # Run tracert. limit hops to 10 and timeout to 300ms to avoid long delays
                                $traceOutput = tracert -d -h 10 -w 300 $targetRef
                                $hops = @()
                                foreach ($line in $traceOutput) {
                                    if ($line -match '(?:\s+)(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})') {
                                        $hopIp = $matches[1]
                                        $hops += $hopIp
                                    }
                                }
                                
                                # Ensure target is appended if trace did not reach but target is valid
                                if ($hops.Count -gt 0 -and $hops[-1] -ne $targetRef) {
                                    $pingRes = Test-Connection -ComputerName $targetRef -Count 1 -Quiet -ErrorAction SilentlyContinue
                                    if ($pingRes) {
                                        $hops += $targetRef
                                    }
                                }

                                Write-JsonResponse $respRef @{ hops = $hops }
                            } catch {
                                Write-JsonResponse $respRef @{ error = "Traceroute failed: $($_.Exception.Message)" } 500
                            }
                        }.GetNewClosure()) | Out-Null
                        continue
                    } else {
                        Write-JsonResponse $response @{ error = "Missing target parameter" } 400
                    }
                }
                elseif ($urlPath -eq "/api/email/test" -and $method -eq "POST") {
                    $reader  = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $jsonBody = $reader.ReadToEnd()
                    $payload = $jsonBody | ConvertFrom-Json
                    
                    $sHost = if ($payload.smtpHost) { [string]$payload.smtpHost } else { $syncHash.SmtpHost }
                    $sPort = if ($null -ne $payload.smtpPort) { [int]$payload.smtpPort } else { $syncHash.SmtpPort }
                    $sSsl  = if ($null -ne $payload.smtpSsl) { [bool]$payload.smtpSsl } else { $syncHash.SmtpSsl }
                    $sUser = if ($payload.smtpUser) { [string]$payload.smtpUser } else { $syncHash.SmtpUser }
                    $sPass = if ($payload.smtpPass -and [string]$payload.smtpPass -ne "********") { [string]$payload.smtpPass } else { $syncHash.SmtpPass }
                    $sFrom = if ($payload.smtpFrom) { [string]$payload.smtpFrom } else { $syncHash.SmtpFrom }
                    $sTo   = if ($payload.smtpTo) { [string]$payload.smtpTo } else { $syncHash.SmtpTo }
                    $clientIp = $request.RemoteEndPoint.Address.ToString()
                    $repDir = $ReportsDir
                    $respRef = $response

                    [System.Threading.ThreadPool]::QueueUserWorkItem({
                        try {
                            $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                            $subj = "【テスト通知】ネットワーク機器監視システム (SMTPテスト)"
                            $body = "これはネットワーク機器監視システムからのテスト通知メールです。`n送信日時: $ts`n正常にSMTPメールサーバーと通信できています。"
                            
                            $sent = Send-EmailNotification -smtpHost $sHost -smtpPort $sPort -useSsl $sSsl -smtpUser $sUser -smtpPass $sPass -from $sFrom -to $sTo -subject $subj -body $body
                            if ($sent) {
                                Log-Audit -action "EMAIL_TEST" -target $sTo -details "Test email sent successfully via $sHost" -clientIp $clientIp -reportsDirectory $repDir
                                Write-JsonResponse $respRef @{ status = "success"; message = "Test email sent successfully" }
                            } else {
                                Write-JsonResponse $respRef @{ error = "Failed to send email. Check SMTP settings and firewall." } 500
                            }
                        } catch {
                            Write-JsonResponse $respRef @{ error = "Email test error: $($_.Exception.Message)" } 500
                        }
                    }.GetNewClosure()) | Out-Null
                    continue
                }
                elseif ($urlPath -eq "/api/syslog" -and $method -eq "GET") {
                    $logs = @()
                    [System.Threading.Monitor]::Enter($syncHash.SyslogQueue.SyncRoot)
                    try {
                        $logs = $syncHash.SyslogQueue.ToArray()
                    } finally {
                        [System.Threading.Monitor]::Exit($syncHash.SyslogQueue.SyncRoot)
                    }
                    Write-JsonResponse $response @{ logs = $logs }
                }
                elseif ($urlPath -eq "/api/syslog/clear" -and $method -eq "POST") {
                    [System.Threading.Monitor]::Enter($syncHash.SyslogQueue.SyncRoot)
                    try {
                        $syncHash.SyslogQueue.Clear()
                    } finally {
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
                        } catch {}
                    }
                    Write-JsonResponse $response @{ logs = $lines }
                }
                elseif ($urlPath -eq "/api/system/cleanup-reports" -and $method -eq "POST") {
                    $retDays = $syncHash.LogRetentionDays
                    try {
                        $reader  = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                        $jsonBody = $reader.ReadToEnd()
                        if (-not [string]::IsNullOrWhiteSpace($jsonBody)) {
                            $payload = $jsonBody | ConvertFrom-Json
                            if ($null -ne $payload.retentionDays) {
                                $retDays = [int]$payload.retentionDays
                            }
                        }
                    } catch {}

                    if ($retDays -le 0) { $retDays = 30 } # 手動クリーンアップで0の場合は安全のため30日以上前を対象
                    $purgeRes = Invoke-PurgeOldReports -reportsDirectory $ReportsDir -retentionDays $retDays -activeSessionDir $syncHash.SessionDir
                    Log-Audit -action "CLEANUP_REPORTS" -target "Reports" -details "Manual cleanup executed (Retention: $retDays days). Deleted $($purgeRes.DeletedCount) sessions, freed $($purgeRes.FreedMb) MB." -clientIp $request.RemoteEndPoint.Address.ToString() -reportsDirectory $ReportsDir
                    Write-JsonResponse $response @{
                        status = "success"
                        deletedCount = $purgeRes.DeletedCount
                        freedMb = $purgeRes.FreedMb
                        retentionDays = $retDays
                        details = $purgeRes.Details
                    }
                }
                elseif ($urlPath -eq "/api/web-check" -and $method -eq "GET") {
                    $targetUrl = $request.QueryString["url"]
                    if ($targetUrl) {
                        $res = Check-WebAndSslEndpoint -url $targetUrl
                        Write-JsonResponse $response $res
                    } else {
                        Write-JsonResponse $response @{ error = "Missing url" } 400
                    }
                }
                elseif ($urlPath -eq "/api/config-backup/run" -and $method -eq "POST") {
                    $reader  = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
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
                        $loc = if ($syncHash.Location.ContainsKey($ip)) { $syncHash.Location[$ip] } else { "N/A" }
                        $vendor = if ($syncHash.VendorContact.ContainsKey($ip)) { $syncHash.VendorContact[$ip] } else { "N/A" }
                        $snmpD = if ($syncHash.SnmpDetail.ContainsKey($ip)) { $syncHash.SnmpDetail[$ip] } else { @{} }
                        
                        $cfgText = @"
================================================================================
 Network Device Configuration & Inventory Snapshot
 Device: $devName ($ip)
 Timestamp: $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
 Location: $loc
 Vendor Contact: $vendor
================================================================================
[SYSTEM_INFORMATION]
Hostname: $devName
IP Address: $ip
MAC Address: $(if ($syncHash.Mac.ContainsKey($ip)) { $syncHash.Mac[$ip] } else { "Unknown" })
Device Type: $(if ($syncHash.DeviceType.ContainsKey($ip)) { $syncHash.DeviceType[$ip] } else { "network" })
Location: $loc
Vendor Contact: $vendor
Trouble Memo: $(if ($syncHash.TroubleMemo.ContainsKey($ip)) { $syncHash.TroubleMemo[$ip] } else { "" })

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
                    } else {
                        Write-JsonResponse $response @{ error = "Missing ip" } 400
                    }
                }
                elseif ($urlPath -eq "/api/config-backup/list" -and $method -eq "GET") {
                    $configsDir = Join-Path $ReportsDir "Configs"
                    $list = @()
                    if (Test-Path $configsDir) {
                        Get-ChildItem -Path $configsDir -Filter "*.txt" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object {
                            $parts = $_.BaseName -split '_'
                            $ipPart = if ($parts.Length -ge 3) { ($parts[0..($parts.Length-3)]) -join '.' } else { $parts[0] }
                            $list += @{
                                filename = $_.Name
                                ip = $ipPart
                                timestamp = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
                                size = "$([math]::Round($_.Length / 1024, 1)) KB"
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
                    
                    if ((Test-Path $p1) -and (Test-Path $p2)) {
                        $lines1 = [System.IO.File]::ReadAllLines($p1, [System.Text.Encoding]::UTF8)
                        $lines2 = [System.IO.File]::ReadAllLines($p2, [System.Text.Encoding]::UTF8)
                        
                        $diffResult = @()
                        $maxL = [math]::Max($lines1.Length, $lines2.Length)
                        for ($i = 0; $i -lt $maxL; $i++) {
                            $l1 = if ($i -lt $lines1.Length) { $lines1[$i] } else { "" }
                            $l2 = if ($i -lt $lines2.Length) { $lines2[$i] } else { "" }
                            if ($l1 -ne $l2) {
                                $diffResult += @{ line = ($i + 1); file1 = $l1; file2 = $l2; changed = $true }
                            } else {
                                $diffResult += @{ line = ($i + 1); file1 = $l1; file2 = $l2; changed = $false }
                            }
                        }
                        Write-JsonResponse $response @{ diff = $diffResult }
                    } else {
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
                    $syncHash.PendingShutdown = $true
                    $syncHash.PendingShutdownTime = [DateTime]::UtcNow.AddSeconds(2) # wait 2 seconds for clean exit
                    Write-JsonResponse $response @{ status = "success"; message = "Shutdown initiated" }
                    Write-Host "Shutdown signal received from browser." -ForegroundColor Yellow
                }
                else {
                    Write-JsonResponse $response @{ error = "Not found" } 404
                }
            } catch {
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

            if (Test-Path $filePath -PathType Leaf) {
                $ext = [System.IO.Path]::GetExtension($filePath)
                $response.ContentType = Get-MimeType $ext
                $response.StatusCode  = 200
                [byte[]]$buffer = [System.IO.File]::ReadAllBytes($filePath)
                try { $response.ContentLength64 = $buffer.Length; $response.OutputStream.Write($buffer, 0, $buffer.Length) } catch {}
            } else {
                $response.StatusCode = 404
                $buffer = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found")
                try { $response.ContentLength64 = $buffer.Length; $response.OutputStream.Write($buffer, 0, $buffer.Length) } catch {}
            }
            try { $response.Close() } catch {}
        }
    }
} finally {
    $syncHash.Running = $false

    if ($syncHash.Shutdown) {
        Write-Host "Stopping server..." -ForegroundColor Yellow
    }

    # Stop and close the background runspaces first to ensure no concurrent writes
    if ($null -ne $runspace)     { try { $runspace.Close();   $runspace.Dispose()   } catch {} }
    if ($null -ne $bwRunspace)   { try { $bwRunspace.Close(); $bwRunspace.Dispose() } catch {} }
    if ($null -ne $snmpRunspace) { try { $snmpRunspace.Close(); $snmpRunspace.Dispose() } catch {} }

    # Save remaining history and append summary block for each device
    $devices = $syncHash.Devices
    if ($syncHash.LoggingEnabled -ne $false -and $null -ne $devices) {
        foreach ($ip in $devices) {
            $safeIp  = $ip -replace '[\\/:*?"<>|]', '_'
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
                } finally {
                    [System.Threading.Monitor]::Exit($historyList.SyncRoot)
                }
            }

            # Create file with header if it doesn't exist
            if (-not (Test-Path $csvPath)) {
                $header = "タイムスタンプ,IPアドレス,ステータス,遅延_ms,帯域_Mbps,送信_Mbps,受信_Mbps,瞬断継続_sec,ジッター_ms`r`n"
                try {
                    [System.IO.File]::WriteAllText($csvPath, $header, [System.Text.Encoding]::GetEncoding(932))
                } catch {
                    Write-Host "Error creating CSV file on exit: $($_.Exception.Message)" -ForegroundColor Red
                }
            }

            if ($linesToSave.Count -gt 0) {
                $contentToAppend = ($linesToSave -join "`r`n") + "`r`n"
                try {
                    [System.IO.File]::AppendAllText($csvPath, $contentToAppend, [System.Text.Encoding]::GetEncoding(932))
                } catch {}
            }

            # Write summary block
            $stats = $syncHash.Stats[$ip]
            if ($null -ne $stats) {
                $total     = $stats.Total
                $success   = $stats.Success
                $failed    = $stats.Failed
                $reachRate = if ($total -gt 0) { [math]::Round($success / $total * 100, 2) } else { 0 }
                
                $minLat    = if ($stats.LatCount -gt 0 -and $stats.MinLat -ne [double]::MaxValue) { $stats.MinLat } else { 'N/A' }
                $maxLat    = if ($stats.LatCount -gt 0) { $stats.MaxLat } else { 'N/A' }
                $avgLat    = if ($stats.LatCount -gt 0) { [math]::Round($stats.SumLat / $stats.LatCount, 2) } else { 'N/A' }
                
                $Tstr = $syncHash.SessionTimestamp

                $maxOutageMs  = if ($stats.MaxOutageSec -gt 0) { [math]::Round($stats.MaxOutageSec * 1000, 0) } else { 'N/A' }
                $out600ms     = $stats.Outage600msCount
                $out5s        = $stats.Outage5sCount
                $thresh1Label = "$($syncHash.OutageThresh1Ms)ms"
                $thresh2Label = if ($syncHash.OutageThresh2Ms -ge 1000) { "$([int]($syncHash.OutageThresh2Ms/1000))s" } else { "$($syncHash.OutageThresh2Ms)ms" }

                $packetLossRate = if ($total -gt 0) { [math]::Round(($failed / $total) * 100, 1) } else { 0 }
                $jitterVal = if ($stats.JitterCount -gt 0) {
                    [math]::Round($stats.JitterSum / $stats.JitterCount, 2)
                } else { 'N/A' }

                # Japanese labels via Base64 (avoids PS5 source-encoding issues)
                $pingB64 = "eyJoZWFkZXIiOiItLS0g6KiI5ris44K144Oe44Oq44O8IC0tLSIsImZhaWxlZCI6IuWkseaVl+aVsO+8iOW/nOetlOOBquOBl+ODu+OCv+OCpOODoOOCouOCpuODiO+8iSIsInJlYWNoIjoi5Yiw6YGU546HIC8g5o6l57aa5oCnICglKSIsIm91dGFnZURldGFpbENvbHMiOiJObyznnqzmlq3plovlp4vml6XmmYIs5b6p5pen5a6M5LqG5pel5pmCLOe2mee2muaZgumWk19tcyzliKTlrprljLrliIYiLCJwYWNrZXRMb3NzIjoi44OR44Kx44OD44OI5pCN5aSx546HICglKSIsImlwIjoiSVDjgqLjg4njg6zjgrkiLCJsYXRBdmciOiLlubPlnYfpgYXlu7YgKG1zKSIsImppdHRlciI6IuW5s+Wdh+OCuOODg+OCv+ODvCAobXMpIiwibm90ZSI6IuWCmeiAg++8iOeerOaWreWbnuaVsOOBrumbhuioiOOBq+OBpOOBhOOBpu+8iSIsIm91dGFnZURldGFpbE5vbmUiOiLvvIjopo/lrprplr7lgKTku6XkuIrjga7nnqzmlq3jga/nmbrnlJ/jgZfjgb7jgZvjgpPjgafjgZfjgZ/vvIkiLCJzdWNjZXNzIjoi5oiQ5Yqf5pWw77yI5b+c562U44GC44KK77yJIiwibm90ZVZhbCI6IuOCquODleODqeOCpOODs+OBi+OCieOCquODs+ODqeOCpOODs+OBq+W+qeW4sOOBl+OBn+aZgueCueOBp+OCq+OCpuODs+ODiOOAguOCu+ODg+OCt+ODp+ODs+e1guS6huaZgueCueOBp+e2mee2muS4reOBrueerOaWreOBr+WQq+OBv+OBvuOBm+OCkyIsIm91dGFnZUFib3ZlIjoi5Lul5LiK44Gu556s5pat5Zue5pWw77yI5pat44GM55m655Sf44GX44Gf5Zue5pWw77yJIiwibGF0TWluIjoi5pyA5bCP6YGF5bu2IChtcykiLCJ0b3RhbFBpbmdzIjoi57ePUGluZ+mAgeS/oeaVsO+8iOippuihjOWbnuaVsO+8iSIsInNlc3Npb24iOiLjgrvjg4Pjgrfjg6fjg7PvvIjoqIjmuKzlm57vvIkiLCJtYXhPdXRhZ2UiOiLmnIDlpKfnnqzmlq3mmYLplpPvvIjmnIDlpKfpgJrkv6HlgZzmraLmmYLplpPvvIkgKG1zKSIsIm91dGFnZURldGFpbEhlYWRlciI6Ii0tLSDnnqzmlq3jg7vpgJrkv6HliIfmlq0g55m655Sf5bGl5q205piO57SwIC0tLSIsImxhdE1heCI6IuacgOWkp+mBheW7tiAobXMpIn0="
                $pL = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($pingB64)) | ConvertFrom-Json

                $baseIntervalMs = if ($syncHash.PollInterval -gt 0) { [int]$syncHash.PollInterval } else { 1000 }
                $highFreqIps = if ($syncHash.HighFreqTargetIps) { ($syncHash.HighFreqTargetIps -split ',') | ForEach-Object { $_.Trim() } } else { @() }
                $isUltraHighFreq = ($baseIntervalMs -le 100)

                $devIntervalStr = if ($isUltraHighFreq) {
                    if ($highFreqIps -contains $ip) { "0.1s (100ms)" } else { "5.0s (5秒)" }
                } else {
                    if ($baseIntervalMs -ge 1000) {
                        if ($baseIntervalMs % 1000 -eq 0) { "$([int]($baseIntervalMs / 1000))s ($([int]($baseIntervalMs / 1000))秒)" } else { "$([math]::Round($baseIntervalMs / 1000, 1))s" }
                    } else {
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
                } else {
                    $lines.Add($pL.outageDetailNone)
                }

                $summaryBlock = ($lines -join "`r`n") + "`r`n"
                try {
                    [System.IO.File]::AppendAllText($csvPath, $summaryBlock, [System.Text.Encoding]::GetEncoding(932))
                    Write-Host "Appended final summary for $ip to $csvPath" -ForegroundColor Cyan
                } catch {}
            }
        }
    }

    # Generate graphical HTML report in session directory (chart.js is embedded inline, no external file needed)
    if ($syncHash.LoggingEnabled -ne $false -and $syncHash.SessionDir -and (Test-Path $syncHash.SessionDir)) {
        try {
            $reportFile = Join-Path $syncHash.SessionDir "report.html"
            $null = Generate-SessionReportHtml -sync $syncHash -period "Session" -savePath $reportFile
            Write-Host "Generated graph inspection report: $reportFile" -ForegroundColor Green
        } catch {
            Write-Host "Error generating final HTML report: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # Auto-purge old reports exceeding retention days on server shutdown
    if ($syncHash.LogRetentionDays -gt 0) {
        try {
            Invoke-PurgeOldReports -reportsDirectory $ReportsDir -retentionDays $syncHash.LogRetentionDays -activeSessionDir $syncHash.SessionDir | Out-Null
        } catch {}
    }

    if ($null -ne $syncHash.IperfServerState.Process -and -not $syncHash.IperfServerState.Process.HasExited) {
        try { $syncHash.IperfServerState.Process.Kill() } catch {}
    }
    if ($null -ne $syncHash.IperfState.Process -and -not $syncHash.IperfState.Process.HasExited) {
        try { $syncHash.IperfState.Process.Kill() } catch {}
    }

    if ($null -ne $listener)       { try { $listener.Stop();   $listener.Close()   } catch {} }
    if ($null -ne $syslogRunspace) { try { $syslogRunspace.Close(); $syslogRunspace.Dispose() } catch {} }
    if ($null -ne $keyRunspace)    { try { $keyRunspace.Close(); $keyRunspace.Dispose() } catch {} }
    Write-Host "Server stopped gracefully." -ForegroundColor Gray
}
