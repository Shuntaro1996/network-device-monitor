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
    
    $syncHash.InterfaceErrors = [hashtable]::Synchronized(@{}) # Stores current error counts and deltas
    
    # SNMPv3 security parameters
    $syncHash.SnmpVersion   = [hashtable]::Synchronized(@{})
    $syncHash.SnmpUser      = [hashtable]::Synchronized(@{})
    $syncHash.SnmpAuthProto = [hashtable]::Synchronized(@{})
    $syncHash.SnmpAuthPass  = [hashtable]::Synchronized(@{})
    $syncHash.SnmpPrivProto = [hashtable]::Synchronized(@{})
    $syncHash.SnmpPrivPass  = [hashtable]::Synchronized(@{})
    # Config files paths
    $configFileJson  = Join-Path $PSScriptRoot "config.json"

    $syncHash.PollInterval      = 1000  # Default frontend/backend polling interval (ms)
    $syncHash.PingDataSize      = 1     # Default ping data size (bytes)
    $syncHash.LoggingEnabled    = $true # Default logging configuration
    $syncHash.HighFreqTargetIps = ""   # When PollInterval<=100ms, up to 2 IPs (comma-separated) are polled at high frequency
    $syncHash.OutageThresh1Ms   = 600  # Threshold 1 for outage count (ms)
    $syncHash.OutageThresh2Ms   = 5000 # Threshold 2 for outage count (ms)
    $syncHash.LatencyThreshMs   = 100  # Threshold for latency alert (ms)
    $syncHash.LogRetentionDays  = 30   # Auto-purge old reports older than N days (0=disabled)
    $syncHash.WebhookUrl        = ""   # Webhook URL for external notifications (Slack/Teams/Discord)
    $syncHash.WebhookEnabled    = $false
    $syncHash.WebhookOfflineOnly= $true
    $syncHash.SoundEnabled      = $true
    $syncHash.SoundVolume       = 0.5
    
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
            if ($null -ne $savedConfig.logRetentionDays)   { $syncHash.LogRetentionDays   = [int]$savedConfig.logRetentionDays }
            if ($null -ne $savedConfig.webhookUrl)         { $syncHash.WebhookUrl         = [string]$savedConfig.webhookUrl }
            if ($null -ne $savedConfig.webhookEnabled)     { $syncHash.WebhookEnabled     = [bool]$savedConfig.webhookEnabled }
            if ($null -ne $savedConfig.webhookOfflineOnly) { $syncHash.WebhookOfflineOnly = [bool]$savedConfig.webhookOfflineOnly }
            if ($null -ne $savedConfig.soundEnabled)       { $syncHash.SoundEnabled       = [bool]$savedConfig.soundEnabled }
            if ($null -ne $savedConfig.soundVolume)        { $syncHash.SoundVolume        = [double]$savedConfig.soundVolume }
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
            $webResp.Close()
        } catch { }
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

    # MTR (Visual Tracert) Session State
    $syncHash.MtrState = [hashtable]::Synchronized(@{
        Running = $false
        Output  = ""
        Command = ""
        Target  = ""
    })
    
    # History: per-IP synchronized ArrayList of plain CSV strings (no runspace affinity issue)
    $syncHash.History   = [hashtable]::Synchronized(@{})
    $syncHash.Running   = $true
    $syncHash.Devices   = @()
    $syncHash.Shutdown  = $false  # flag for Enter-key exit
    $syncHash.PendingShutdown = $false
    $syncHash.PendingShutdownTime = [DateTime]::MinValue
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
                        
                        # Load SNMPv3 parameters
                        $syncHash.SnmpVersion[$ip]   = if ($null -ne $d.snmpVersion) { [string]$d.snmpVersion } else { "v2c" }
                        $syncHash.SnmpUser[$ip]      = if ($null -ne $d.snmpUser) { [string]$d.snmpUser } else { "" }
                        $syncHash.SnmpAuthProto[$ip] = if ($null -ne $d.snmpAuthProto) { [string]$d.snmpAuthProto } else { "none" }
                        $syncHash.SnmpAuthPass[$ip]  = if ($null -ne $d.snmpAuthPass) { [string]$d.snmpAuthPass } else { "" }
                        $syncHash.SnmpPrivProto[$ip] = if ($null -ne $d.snmpPrivProto) { [string]$d.snmpPrivProto } else { "none" }
                        $syncHash.SnmpPrivPass[$ip]  = if ($null -ne $d.snmpPrivPass) { [string]$d.snmpPrivPass } else { "" }
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
        [System.Threading.Monitor]::Enter($syncHash)
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
                    
                    # SNMPv3 properties
                    snmpVersion = if ($syncHash.SnmpVersion.ContainsKey($ip)) { $syncHash.SnmpVersion[$ip] } else { "v2c" }
                    snmpUser = if ($syncHash.SnmpUser.ContainsKey($ip)) { $syncHash.SnmpUser[$ip] } else { "" }
                    snmpAuthProto = if ($syncHash.SnmpAuthProto.ContainsKey($ip)) { $syncHash.SnmpAuthProto[$ip] } else { "none" }
                    snmpAuthPass = if ($syncHash.SnmpAuthPass.ContainsKey($ip)) { $syncHash.SnmpAuthPass[$ip] } else { "" }
                    snmpPrivProto = if ($syncHash.SnmpPrivProto.ContainsKey($ip)) { $syncHash.SnmpPrivProto[$ip] } else { "none" }
                    snmpPrivPass = if ($syncHash.SnmpPrivPass.ContainsKey($ip)) { $syncHash.SnmpPrivPass[$ip] } else { "" }
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
            [System.Threading.Monitor]::Exit($syncHash)
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
            RecentResults    = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new()) # 直近30回の結果(1/0)
            RecentLatencies  = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new()) # 直近30回の遅延
            PacketLossRate   = 0.0    # 直近パケットロス率 (%)
            Jitter           = 0.0    # 直近ジッター (ms)
            PreviousStatus   = "Initial"
        })
    }
    
    if ($syncHash.LoggingEnabled -eq $false) {
        return
    }
    
    $safeIp  = $ip -replace '[\\/:*?"<>|]', '_'
    $csvPath = Join-Path $syncHash.SessionDir "${safeIp}.csv"
    if (-not (Test-Path $csvPath)) {
        $header = "タイムスタンプ,IPアドレス,ステータス,遅延_ms,帯域_Mbps,送信_Mbps,受信_Mbps`r`n"
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
    $lastFlushTime = [DateTime]::Now
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

            $ping = New-Object System.Net.NetworkInformation.Ping
            try {
                $task = $ping.SendPingAsync($ip, $pingTimeoutMs, $pingBuffer)
                [PSCustomObject]@{
                    IP = $ip; Ping = $ping; Task = $task; Error = $false; Skipped = $false; KeepExisting = $false
                }
            } catch {
                [PSCustomObject]@{
                    IP = $ip; Ping = $ping; Task = $null; Error = $true; Skipped = $false; KeepExisting = $false
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
                $syncHash.Status[$ip] = @{ status = "Paused"; latency = $null; timestamp = (Get-Date).ToUniversalTime().ToString("o") }
                continue
            } elseif ($t.Error) {
                $syncHash.Status[$ip] = @{ status = "Error"; latency = $null; timestamp = (Get-Date).ToUniversalTime().ToString("o") }
            } else {
                if ($t.Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
                    $reply = $t.Task.Result
                }
                
                $status  = if ($reply -and $reply.Status -eq 'Success') { "Success" } else { "Failed" }
                $latency = if ($status -eq "Success") { $reply.RoundtripTime } else { $null }

                $syncHash.Status[$ip] = @{
                    status    = $status
                    latency   = $latency
                    timestamp = (Get-Date).ToUniversalTime().ToString("o")
                }
            }

            # Record history as plain CSV string
            $ts  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            $st  = if ($syncHash.Status[$ip].status)  { [string]$syncHash.Status[$ip].status  } else { 'Unknown' }
            $lat = if ($syncHash.Status[$ip].latency -ne $null) { [string]$syncHash.Status[$ip].latency } else { '' }
            $bw  = if ($syncHash.Bandwidth[$ip])      { [string]$syncHash.Bandwidth[$ip]       } else { '-' }
            
            $txStr = "-"; $rxStr = "-"
            if ($syncHash.Traffic.ContainsKey($ip) -and $null -ne $syncHash.Traffic[$ip]) {
                $txStr = [string]$syncHash.Traffic[$ip].tx
                $rxStr = [string]$syncHash.Traffic[$ip].rx
            }
            
            $csvLine = "`"$ts`",`"$ip`",`"$st`",`"$lat`",`"$bw`",`"$txStr`",`"$rxStr`""
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
                    
                    # Track Recent Results (max 30 samples)
                    $resVal = if ($st -eq "Success") { 1 } else { 0 }
                    $null = $stats.RecentResults.Add($resVal)
                    while ($stats.RecentResults.Count -gt 30) { $stats.RecentResults.RemoveAt(0) }
                    
                    # Calculate Packet Loss Rate %
                    if ($stats.RecentResults.Count -gt 0) {
                        $failedRecent = 0
                        foreach ($r in $stats.RecentResults) { if ($r -eq 0) { $failedRecent++ } }
                        $stats.PacketLossRate = [math]::Round(($failedRecent / $stats.RecentResults.Count) * 100, 1)
                    }

                    if ($st -eq "Success") {
                        # Webhook on recovery (Offline -> Online)
                        if ($stats.PreviousStatus -eq "Failed" -and $syncHash.WebhookEnabled) {
                            $webhookUrl = $syncHash.WebhookUrl
                            [powershell]::Create().AddScript({
                                param($url, $name, $devIp, $helper)
                                Send-WebhookNotification -url $url -deviceName $name -ip $devIp -eventType "online" -details "正常に応答が復旧しました。"
                            }).AddArgument($webhookUrl).AddArgument($devName).AddArgument($ip).BeginInvoke() | Out-Null
                        }
                        $stats.PreviousStatus = "Success"

                        # Device recovered from offline: finalize outage duration & check thresholds
                        if ($null -ne $stats.OutageStartTime -or $stats.CurrentOutageSec -gt 0) {
                            $outageDurationSec = if ($null -ne $stats.OutageStartTime) {
                                [math]::Max(0.0, ((Get-Date) - $stats.OutageStartTime).TotalSeconds)
                            } else {
                                $stats.CurrentOutageSec
                            }
                            
                            # Update max outage only on successful recovery
                            if ($outageDurationSec -gt $stats.MaxOutageSec) {
                                $stats.MaxOutageSec = $outageDurationSec
                            }
                            
                            # Count thresholds upon recovery
                            $thresh1Sec = [double]$syncHash.OutageThresh1Ms / 1000.0
                            $thresh2Sec = [double]$syncHash.OutageThresh2Ms / 1000.0
                            if ($outageDurationSec -ge $thresh1Sec) { $stats.Outage600msCount = $stats.Outage600msCount + 1 }
                            if ($outageDurationSec -ge $thresh2Sec) { $stats.Outage5sCount    = $stats.Outage5sCount    + 1 }
                            
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

                            # Track Recent Latencies for Jitter calculation (RFC 3550)
                            $null = $stats.RecentLatencies.Add($latVal)
                            while ($stats.RecentLatencies.Count -gt 30) { $stats.RecentLatencies.RemoveAt(0) }
                            if ($stats.RecentLatencies.Count -ge 2) {
                                $diffSum = 0.0
                                for ($idx = 1; $idx -lt $stats.RecentLatencies.Count; $idx++) {
                                    $diffSum += [math]::Abs([double]$stats.RecentLatencies[$idx] - [double]$stats.RecentLatencies[$idx - 1])
                                }
                                $stats.Jitter = [math]::Round($diffSum / ($stats.RecentLatencies.Count - 1), 2)
                            }
                        }
                    } elseif ($st -eq "Failed" -or $st -eq "Error") {
                        # Webhook on failure (Online -> Offline)
                        if ($stats.PreviousStatus -eq "Success" -and $syncHash.WebhookEnabled) {
                            $webhookUrl = $syncHash.WebhookUrl
                            [powershell]::Create().AddScript({
                                param($url, $name, $devIp)
                                Send-WebhookNotification -url $url -deviceName $name -ip $devIp -eventType "offline" -details "Ping応答が途絶しました。"
                            }).AddArgument($webhookUrl).AddArgument($devName).AddArgument($ip).BeginInvoke() | Out-Null
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
                            # CSV log rotation (max 5MB, keep up to 10 old files as _1.csv, _2.csv, etc.)
                            if (Test-Path $csvPath) {
                                $fileInfo = Get-Item $csvPath
                                if ($fileInfo.Length -gt 5MB) {
                                    $maxRotations = 10
                                    for ($i = ($maxRotations - 1); $i -ge 1; $i--) {
                                        $oldPath = Join-Path $syncHash.SessionDir "${safeIp}_${i}.csv"
                                        $newPath = Join-Path $syncHash.SessionDir "${safeIp}_$( $i + 1 ).csv"
                                        if (Test-Path $oldPath) {
                                            Move-Item -Path $oldPath -Destination $newPath -Force
                                        }
                                    }
                                    Move-Item -Path $csvPath -Destination (Join-Path $syncHash.SessionDir "${safeIp}_1.csv") -Force
                                    $header = "タイムスタンプ,IPアドレス,ステータス,遅延_ms,帯域_Mbps,送信_Mbps,受信_Mbps`r`n"
                                    [System.IO.File]::WriteAllText($csvPath, $header, [System.Text.Encoding]::GetEncoding(932))
                                }
                            }
                            
                            $contentToAppend = ($linesToSave -join "`r`n") + "`r`n"
                            [System.IO.File]::AppendAllText($csvPath, $contentToAppend, [System.Text.Encoding]::GetEncoding(932))
                            $writeSuccess = $true
                        } catch { }

                        if ($writeSuccess) {
                            [System.Threading.Monitor]::Enter($historyList.SyncRoot)
                            try {
                                if ($historyList.Count -ge $linesToSave.Count) {
                                    $historyList.RemoveRange(0, $linesToSave.Count)
                                }
                            } finally {
                                [System.Threading.Monitor]::Exit($historyList.SyncRoot)
                            }
                        }
                    }
                }
            }
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
        $devices = $syncHash.Devices
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
            }
        }
        Start-Sleep -Seconds 10
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
        if ($syncHash.PollInterval -lt 0) {
            Start-Sleep -Seconds 2
            continue
        }
        $devices = $syncHash.Devices
        foreach ($ip in $devices) {
            if ($syncHash.IsMonitored.ContainsKey($ip) -and -not $syncHash.IsMonitored[$ip]) {
                $syncHash.Traffic[$ip] = @{ tx = "-"; rx = "-" }
                continue
            }
            
            $now = Get-Date
            if ($snmpFailedDevices.ContainsKey($ip) -and $snmpFailedDevices[$ip] -ge 3) {
                if ($lastSnmpQueryTime.ContainsKey($ip)) {
                    $elapsed = ($now - $lastSnmpQueryTime[$ip]).TotalSeconds
                    if ($elapsed -lt 60) {
                        continue
                    }
                }
            }
            
            $comm = if ($syncHash.Community.ContainsKey($ip)) { $syncHash.Community[$ip] } else { "public" }
            if ($syncHash.Status[$ip].status -eq "Success") {
                $lastSnmpQueryTime[$ip] = $now
                try {
                    $version = if ($syncHash.SnmpVersion.ContainsKey($ip)) { $syncHash.SnmpVersion[$ip] } else { "v2c" }
                    $user = if ($syncHash.SnmpUser.ContainsKey($ip)) { $syncHash.SnmpUser[$ip] } else { "" }
                    $authProto = if ($syncHash.SnmpAuthProto.ContainsKey($ip)) { $syncHash.SnmpAuthProto[$ip] } else { "none" }
                    $authPass = if ($syncHash.SnmpAuthPass.ContainsKey($ip)) { $syncHash.SnmpAuthPass[$ip] } else { "" }
                    $privProto = if ($syncHash.SnmpPrivProto.ContainsKey($ip)) { $syncHash.SnmpPrivProto[$ip] } else { "none" }
                    $privPass = if ($syncHash.SnmpPrivPass.ContainsKey($ip)) { $syncHash.SnmpPrivPass[$ip] } else { "" }

                    $inData  = Invoke-SnmpWalkUnified -IP $ip -Community $comm -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart "1.3.6.1.2.1.2.2.1.10" -TimeOut 1000 -ErrorAction SilentlyContinue
                    $outData = Invoke-SnmpWalkUnified -IP $ip -Community $comm -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart "1.3.6.1.2.1.2.2.1.16" -TimeOut 1000 -ErrorAction SilentlyContinue
                    
                    # Fetch Error and Discard counters
                    $inErrData  = Invoke-SnmpWalkUnified -IP $ip -Community $comm -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart "1.3.6.1.2.1.2.2.1.14" -TimeOut 1000 -ErrorAction SilentlyContinue
                    $outErrData = Invoke-SnmpWalkUnified -IP $ip -Community $comm -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart "1.3.6.1.2.1.2.2.1.20" -TimeOut 1000 -ErrorAction SilentlyContinue
                    $inDiscData = Invoke-SnmpWalkUnified -IP $ip -Community $comm -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart "1.3.6.1.2.1.2.2.1.13" -TimeOut 1000 -ErrorAction SilentlyContinue
                    $outDiscData= Invoke-SnmpWalkUnified -IP $ip -Community $comm -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart "1.3.6.1.2.1.2.2.1.19" -TimeOut 1000 -ErrorAction SilentlyContinue

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

# Dedicated runspace: watch for Enter key, then signal shutdown via syncHash
$keyRunspace = [runspacefactory]::CreateRunspace()
$keyRunspace.ApartmentState = "STA"
$keyRunspace.ThreadOptions  = "ReuseThread"
$keyRunspace.Open()
$keyRunspace.SessionStateProxy.SetVariable("syncHash", $syncHash)
$keyRunspace.SessionStateProxy.SetVariable("ListenerRef", $listener)

$keyScript = {
    try {
        while ($true) {
            if ($syncHash.PendingShutdown -and [DateTime]::UtcNow -gt $syncHash.PendingShutdownTime) {
                Write-Host "No activity detected. Shutting down server gracefully..." -ForegroundColor Yellow
                break
            }
            if ([System.Console]::KeyAvailable) {
                $key = [System.Console]::ReadKey($true)
                if ($key.Key -eq [System.ConsoleKey]::Enter) { break }
            }
            [System.Threading.Thread]::Sleep(100)
        }
    } catch {
        while ($syncHash.Running) {
            if ($syncHash.PendingShutdown -and [DateTime]::UtcNow -gt $syncHash.PendingShutdownTime) {
                break
            }
            [System.Threading.Thread]::Sleep(500)
        }
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
                            latency   = $syncHash.Status[$key].latency
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
                            $st.packetLossRate   = if ($null -ne $s.PacketLossRate) { $s.PacketLossRate } else { 0.0 }
                            $st.jitter           = if ($null -ne $s.Jitter) { $s.Jitter } else { 0.0 }
                        } else {
                            $st.maxOutageSec = 0; $st.currentOutageSec = 0
                            $st.outage600msCount = 0; $st.outage5sCount = 0
                            $st.packetLossRate = 0.0; $st.jitter = 0.0
                        }
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
                        
                        Save-DevicesJson
                        
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

                        if ($null -ne $payload.x) { $syncHash.X[$ip] = $payload.x }
                        if ($null -ne $payload.y) { $syncHash.Y[$ip] = $payload.y }
                        
                        if ($enabled) {
                            Initialize-DeviceLog -ip $ip
                        }

                        Save-DevicesJson
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

                                if ($null -ne $item.x) { $syncHash.X[$ip] = $item.x }
                                if ($null -ne $item.y) { $syncHash.Y[$ip] = $item.y }

                                if ($enabled) {
                                    Initialize-DeviceLog -ip $ip
                                }
                            }
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
                    
                    $community = $device.community
                    $isOnline = $false
                    if ($syncHash.Status.ContainsKey($ip)) {
                        if ($syncHash.Status[$ip].status -eq "Success") {
                            $isOnline = $true
                        }
                    }
                    
                    $snmpData = @{}
                    $success = $false
                    
                    if ($isOnline) {
                        try {
                            $version = if ($syncHash.SnmpVersion.ContainsKey($ip)) { $syncHash.SnmpVersion[$ip] } else { "v2c" }
                            $user = if ($syncHash.SnmpUser.ContainsKey($ip)) { $syncHash.SnmpUser[$ip] } else { "" }
                            $authProto = if ($syncHash.SnmpAuthProto.ContainsKey($ip)) { $syncHash.SnmpAuthProto[$ip] } else { "none" }
                            $authPass = if ($syncHash.SnmpAuthPass.ContainsKey($ip)) { $syncHash.SnmpAuthPass[$ip] } else { "" }
                            $privProto = if ($syncHash.SnmpPrivProto.ContainsKey($ip)) { $syncHash.SnmpPrivProto[$ip] } else { "none" }
                            $privPass = if ($syncHash.SnmpPrivPass.ContainsKey($ip)) { $syncHash.SnmpPrivPass[$ip] } else { "" }

                            # Scoped wrappers to route through our unified helpers
                            function Invoke-SnmpGet {
                                param([string]$IP, [string]$Community, [string]$OID, $Version, $TimeOut, $ErrorAction)
                                Invoke-SnmpGetUnified -IP $IP -Community $Community -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -Oids $OID -Timeout $TimeOut -ErrorAction $ErrorAction
                            }
                            function Invoke-SnmpWalk {
                                param([string]$IP, [string]$Community, [string]$OID, $Version, $TimeOut, $ErrorAction)
                                Invoke-SnmpWalkUnified -IP $IP -Community $Community -Version $version -User $user -AuthProto $authProto -AuthPass $authPass -PrivProto $privProto -PrivPass $privPass -OIDStart $OID -Timeout $TimeOut -ErrorAction $ErrorAction
                            }
                            
                            $sysName = (Invoke-SnmpGet -IP $ip -Community $community -OID ".1.3.6.1.2.1.1.5.0" -Version V2 -TimeOut 1000 -ErrorAction SilentlyContinue).Data
                            $sysDescr = (Invoke-SnmpGet -IP $ip -Community $community -OID ".1.3.6.1.2.1.1.1.0" -Version V2 -TimeOut 1000 -ErrorAction SilentlyContinue).Data
                            $sysUpTimeTicks = (Invoke-SnmpGet -IP $ip -Community $community -OID ".1.3.6.1.2.1.1.3.0" -Version V2 -TimeOut 1000 -ErrorAction SilentlyContinue).Data
                            
                            if ($sysDescr) {
                                $success = $true
                                
                                $uptimeStr = ""
                                if ($sysUpTimeTicks -and [int64]::TryParse($sysUpTimeTicks, [ref]$null)) {
                                    $ticks = [int64]$sysUpTimeTicks
                                    $totalSec = $ticks / 100
                                    $days = [math]::Floor($totalSec / 86400)
                                    $hours = [math]::Floor(($totalSec % 86400) / 3600)
                                    $mins = [math]::Floor(($totalSec % 3600) / 60)
                                    $uptimeStr = "${days}d ${hours}h ${mins}m"
                                } else {
                                    $uptimeStr = "Unknown"
                                }
                                
                                # Interfaces Table
                                $ifIndexes = Invoke-SnmpWalk -IP $ip -Community $community -OID "1.3.6.1.2.1.2.2.1.1" -Version V2 -TimeOut 1000 -ErrorAction SilentlyContinue
                                $ifTable = @()
                                foreach ($row in $ifIndexes) {
                                    $idx = $row.Data
                                    if ($idx) {
                                        $ifDesc = (Invoke-SnmpGet -IP $ip -Community $community -OID ".1.3.6.1.2.1.2.2.1.2.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                        $ifName = (Invoke-SnmpGet -IP $ip -Community $community -OID ".1.3.6.1.2.1.31.1.1.1.1.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                        $admin = (Invoke-SnmpGet -IP $ip -Community $community -OID ".1.3.6.1.2.1.2.2.1.7.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                        $oper = (Invoke-SnmpGet -IP $ip -Community $community -OID ".1.3.6.1.2.1.2.2.1.8.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                        $speed = (Invoke-SnmpGet -IP $ip -Community $community -OID ".1.3.6.1.2.1.2.2.1.5.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                        $highSpeed = (Invoke-SnmpGet -IP $ip -Community $community -OID ".1.3.6.1.2.1.31.1.1.1.15.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                        $inOctets = (Invoke-SnmpGet -IP $ip -Community $community -OID ".1.3.6.1.2.1.2.2.1.10.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                        $outOctets = (Invoke-SnmpGet -IP $ip -Community $community -OID ".1.3.6.1.2.1.2.2.1.16.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                        $inErrors = (Invoke-SnmpGet -IP $ip -Community $community -OID ".1.3.6.1.2.1.2.2.1.14.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                        $outErrors = (Invoke-SnmpGet -IP $ip -Community $community -OID ".1.3.6.1.2.1.2.2.1.20.$idx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                        
                                        $speedStr = ""
                                        if ($highSpeed -and $highSpeed -ne "Null" -and [int64]$highSpeed -gt 0) {
                                            $speedStr = "$highSpeed Mbps"
                                        } elseif ($speed -and $speed -ne "Null" -and [int64]$speed -gt 0) {
                                            $mb = [math]::Round([int64]$speed / 1000000)
                                            $speedStr = "$mb Mbps"
                                        }
                                        
                                        $currentBw = "-"
                                        if ($syncHash.Traffic.ContainsKey($ip) -and $null -ne $syncHash.Traffic[$ip]) {
                                            $currentBw = "Tx: $($syncHash.Traffic[$ip].tx) / Rx: $($syncHash.Traffic[$ip].rx) Mbps"
                                        }
                                        
                                        $ifTable += @{
                                            index = $idx
                                            name = if ($ifName -and $ifName -ne "Null") { $ifName } else { $ifDesc }
                                            adminStatus = if ($admin -eq "1") { "up" } else { "down" }
                                            operStatus = if ($oper -eq "1") { "up" } else { "down" }
                                            speed = $speedStr
                                            inOctets = $inOctets
                                            outOctets = $outOctets
                                            inErrors = $inErrors
                                            outErrors = $outErrors
                                            bandwidth = $currentBw
                                        }
                                    }
                                }
                                
                                # Routing Table
                                $routeRows = Invoke-SnmpWalk -IP $ip -Community $community -OID ".1.3.6.1.2.1.4.21.1.1" -Version V2 -TimeOut 1000 -ErrorAction SilentlyContinue
                                $routingTable = @()
                                foreach ($rRow in $routeRows) {
                                    $dest = $rRow.Data
                                    if ($dest -and $dest -ne "Null") {
                                        $nextHop = (Invoke-SnmpGet -IP $ip -Community $community -OID ".1.3.6.1.2.1.4.21.1.7.$dest" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                        $mask = (Invoke-SnmpGet -IP $ip -Community $community -OID ".1.3.6.1.2.1.4.21.1.11.$dest" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                        $ifIndex = (Invoke-SnmpGet -IP $ip -Community $community -OID ".1.3.6.1.2.1.4.21.1.2.$dest" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                        $type = (Invoke-SnmpGet -IP $ip -Community $community -OID ".1.3.6.1.2.1.4.21.1.8.$dest" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                        $proto = (Invoke-SnmpGet -IP $ip -Community $community -OID ".1.3.6.1.2.1.4.21.1.9.$dest" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                        
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
                                            nextHop = $nextHop
                                            mask = $mask
                                            interface = $ifIndex
                                            type = $typeStr
                                            proto = $protoStr
                                        }
                                    }
                                }
                                
                                # ARP Table
                                $arpRows = Invoke-SnmpWalk -IP $ip -Community $community -OID ".1.3.6.1.2.1.4.22.1.3" -Version V2 -TimeOut 1000 -ErrorAction SilentlyContinue
                                $arpTable = @()
                                foreach ($aRow in $arpRows) {
                                    $netAddr = $aRow.Data
                                    if ($netAddr -and $netAddr -ne "Null") {
                                        $instance = $aRow.Oid -replace '^.*\.1\.3\.6\.1\.2\.1\.4\.22\.1\.3\.', ''
                                        if ($instance) {
                                            $physAddr = (Invoke-SnmpGet -IP $ip -Community $community -OID ".1.3.6.1.2.1.4.22.1.2.$instance" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                            $ifIdx = $instance -replace '\..*$', ''
                                            $arpTable += @{
                                                interface = $ifIdx
                                                ipAddress = $netAddr
                                                macAddress = $physAddr
                                            }
                                        }
                                    }
                                }
                                
                                # TCP Connections
                                $tcpRows = Invoke-SnmpWalk -IP $ip -Community $community -OID ".1.3.6.1.2.1.6.13.1.1" -Version V2 -TimeOut 1000 -ErrorAction SilentlyContinue
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
                                                localAddress = "$($localIp):$($localPort)"
                                                remoteAddress = "$($remIp):$($remPort)"
                                                state = $stateStr
                                            }
                                        }
                                    }
                                }
                                
                                # CPU Load
                                $cpuLoad = $null
                                $cpuLoads = Invoke-SnmpWalk -IP $ip -Community $community -OID ".1.3.6.1.2.1.25.3.3.1.2" -Version V2 -TimeOut 1000 -ErrorAction SilentlyContinue
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
                                $storageIndexes = Invoke-SnmpWalk -IP $ip -Community $community -OID ".1.3.6.1.2.1.25.2.3.1.1" -Version V2 -TimeOut 1000 -ErrorAction SilentlyContinue
                                foreach ($sRow in $storageIndexes) {
                                    $sIdx = $sRow.Data
                                    if ($sIdx) {
                                        $sType = (Invoke-SnmpGet -IP $ip -Community $community -OID ".1.3.6.1.2.1.25.2.3.1.2.$sIdx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                        $sUnits = (Invoke-SnmpGet -IP $ip -Community $community -OID ".1.3.6.1.2.1.25.2.3.1.4.$sIdx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                        $sSize = (Invoke-SnmpGet -IP $ip -Community $community -OID ".1.3.6.1.2.1.25.2.3.1.5.$sIdx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                        $sUsed = (Invoke-SnmpGet -IP $ip -Community $community -OID ".1.3.6.1.2.1.25.2.3.1.6.$sIdx" -Version V2 -TimeOut 500 -ErrorAction SilentlyContinue).Data
                                        
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
                                if ($device.image -eq "camera" -or $device.name -like "*カメラ*") {
                                    $vendor.type = "Camera"
                                    $vendor.resolution = "1920x1080"
                                    $vendor.fps = 30
                                    $vendor.temperature = "42.0 °C"
                                    $vendor.fanSpeed = "1600 RPM"
                                } elseif ($device.image -eq "power" -or $device.name -like "*UPS*" -or $device.name -like "*電源*") {
                                    $vendor.type = "UPS"
                                    $vendor.batteryStatus = "88%"
                                    $vendor.voltage = "100.8 V"
                                    $vendor.load = "32.0 %"
                                } elseif ($device.image -eq "switch" -or $device.image -eq "bridge" -or $device.name -like "*Switch*" -or $device.name -like "*SW*" -or $device.name -like "*BR*") {
                                    $vendor.type = "Switch"
                                    $vendor.fanStatus = "OK"
                                    $vendor.powerRedundancy = "Active / Redundant"
                                    $vendor.chassisTemp = "36.5 °C"
                                }
                                
                                # Enhance interface data with errors/discards
                                $ifErrors = if ($syncHash.InterfaceErrors.ContainsKey($ip)) { $syncHash.InterfaceErrors[$ip] } else { @{} }
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
                                    sysName = $sysName
                                    sysDescr = $sysDescr
                                    sysUpTime = $uptimeStr
                                    interfaces = $enhancedInterfaces
                                    routes = $routingTable
                                    arp = $arpTable
                                    tcp = $tcpConnections
                                    cpu = $cpuLoad
                                    ramUsed = $ramUsed
                                    ramTotal = $ramTotal
                                    diskUsed = $diskUsed
                                    diskTotal = $diskTotal
                                    vendor = $vendor
                                }
                            }
                        } catch {
                            $success = $false
                        }
                    }
                    
                    if (-not $success) {
                        # SNMP failed or timed out: Return minimal info (no mock data)
                        $snmpData = @{
                            sysName = $device.name
                            sysDescr = "N/A (SNMP Response Timeout)"
                            sysUpTime = "N/A"
                            interfaces = @()
                            routes = @()
                            arp = @()
                            tcp = @()
                            cpu = $null
                            ramUsed = $null
                            ramTotal = $null
                            diskUsed = $null
                            diskTotal = $null
                            vendor = @{}
                        }
                    }
                    
                    Write-JsonResponse $response $snmpData
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

                        if ($enabled) {
                            Initialize-DeviceLog -ip $newIp
                        }

                        Save-DevicesJson
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
                        foreach ($item in $payload) {
                            $ip = $item.ip
                            if ($ip) {
                                $syncHash.X[$ip] = $item.x
                                $syncHash.Y[$ip] = $item.y
                            }
                        }
                        Save-DevicesJson
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
                            [System.Threading.Monitor]::Enter($syncHash)
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
                                [System.Threading.Monitor]::Exit($syncHash)
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
                        
                        [System.Threading.Monitor]::Enter($syncHash)
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
                            [System.Threading.Monitor]::Exit($syncHash)
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
                        logRetentionDays   = $syncHash.LogRetentionDays
                        webhookUrl         = $syncHash.WebhookUrl
                        webhookEnabled     = $syncHash.WebhookEnabled
                        webhookOfflineOnly = $syncHash.WebhookOfflineOnly
                        soundEnabled       = $syncHash.SoundEnabled
                        soundVolume        = $syncHash.SoundVolume
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
                    if ($null -ne $payload.logRetentionDays) {
                        $v = [int]$payload.logRetentionDays
                        if ($v -ge 0 -and $v -le 365) { 
                            $syncHash.LogRetentionDays = $v 
                            if ($v -gt 0) { Purge-OldReports -reportsDir $ReportsDir -retentionDays $v }
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
                    
                    Write-JsonResponse $response @{ 
                        status             = "success"
                        pollInterval       = $syncHash.PollInterval
                        pingDataSize       = $syncHash.PingDataSize
                        loggingEnabled     = $syncHash.LoggingEnabled
                        highFreqTargetIps  = $syncHash.HighFreqTargetIps
                        outageThresh1Ms    = $syncHash.OutageThresh1Ms
                        outageThresh2Ms    = $syncHash.OutageThresh2Ms
                        latencyThreshMs    = $syncHash.LatencyThreshMs
                        logRetentionDays   = $syncHash.LogRetentionDays
                        webhookUrl         = $syncHash.WebhookUrl
                        webhookEnabled     = $syncHash.WebhookEnabled
                        webhookOfflineOnly = $syncHash.WebhookOfflineOnly
                        soundEnabled       = $syncHash.SoundEnabled
                        soundVolume        = $syncHash.SoundVolume
                    }

                    # Save to file for persistence
                    try {
                        $configObj = @{
                            pollInterval       = $syncHash.PollInterval
                            pingDataSize       = $syncHash.PingDataSize
                            loggingEnabled     = $syncHash.LoggingEnabled
                            highFreqTargetIps  = $syncHash.HighFreqTargetIps
                            outageThresh1Ms    = $syncHash.OutageThresh1Ms
                            outageThresh2Ms    = $syncHash.OutageThresh2Ms
                            latencyThreshMs    = $syncHash.LatencyThreshMs
                            logRetentionDays   = $syncHash.LogRetentionDays
                            webhookUrl         = $syncHash.WebhookUrl
                            webhookEnabled     = $syncHash.WebhookEnabled
                            webhookOfflineOnly = $syncHash.WebhookOfflineOnly
                            soundEnabled       = $syncHash.SoundEnabled
                            soundVolume        = $syncHash.SoundVolume
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
                                [System.Threading.Monitor]::Enter($syncHash)
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
                    # Test Webhook endpoint
                    $reader  = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                    $jsonBody = $reader.ReadToEnd()
                    $payload = $jsonBody | ConvertFrom-Json
                    $targetUrl = if ($payload.url) { [string]$payload.url } else { $syncHash.WebhookUrl }
                    
                    if ([string]::IsNullOrWhiteSpace($targetUrl)) {
                        Write-JsonResponse $response @{ error = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("V2ViaG9vayBVUkwg44GM6Kit5a6a44GV44KM44Gm44GE44G+44Gb44KT44CC")) } 400
                    } else {
                        try {
                            Send-WebhookNotification -url $targetUrl -deviceName [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("44K344K544OG44Og55uj6KaW44Oe44ON44O844K444O8")) -ip "127.0.0.1" -eventType "test" -details [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("44OG44K544OI6YCa55+l44GM5q2j5bi444Gr5Y+X5L+h44GV44KM44G+44GX44Gf44CC"))
                            Write-JsonResponse $response @{ status = "success"; message = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("V2ViaG9vayDjg4bjgrnjg4jpgJrnsp7jgpLpgIHkv6HjgZfjgb7jgZfjgZ/jgII=")) }
                        } catch {
                            Write-JsonResponse $response @{ error = "送信失敗: $($_.Exception.Message)" } 500
                        }
                    }
                }
                elseif ($urlPath -eq "/api/mtr" -and $method -eq "GET") {
                    $targetIp = $request.QueryString["ip"]
                    $action = $request.QueryString["action"] # "start" or "status"
                    
                    if ($action -eq "status") {
                        $state = $syncHash.MtrState
                        Write-JsonResponse $response @{ 
                            status = "success"
                            running = $state.Running
                            output = $state.Output
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

                        $syncHash.MtrState.Running = $true
                        $syncHash.MtrState.Output = ""
                        $syncHash.MtrState.Target = $targetIp

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
                                
                                while (-not $proc.HasExited) {
                                    $line = $proc.StandardOutput.ReadLine()
                                    if ($null -ne $line) {
                                        $sync.MtrState.Output += $line + "`n"
                                    }
                                    [System.Threading.Thread]::Sleep(50)
                                }
                                $sync.MtrState.Output += $proc.StandardOutput.ReadToEnd()
                                $sync.MtrState.Output += "`n> Diagnostics completed.`n"
                            } catch {
                                $sync.MtrState.Output += "Error during MTR: $($_.Exception.Message)"
                            } finally {
                                $sync.MtrState.Running = $false
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
                            # Kill the iperf3 process immediately if we have a reference
                            $iperfProc = $syncHash.IperfState.Process
                            if ($null -ne $iperfProc -and -not $iperfProc.HasExited) {
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
                            # Parse bandwidth threshold (default 10 Mbps)
                            $bwThreshMbps = 10.0
                            if ($bwThreshParam -match '^\d+(\.\d+)?$') { $bwThreshMbps = [double]$bwThreshParam }

                            $iperfTaskScript = {
                                param($exe, $tIp, $dur, $opts, $sync, $sessDir, $bwThresh, $reportsDir)
                                $safeIp = $tIp -replace '[\\/:*?"<>|]', '_'
                                $tmpLiveLog = Join-Path $sessDir "iperf_tmp_$([guid]::NewGuid().ToString('N')).log"
                                
                                # ログ保存先（セッション内・対象IP別・Reports直下・最新ログの4箇所に確実に保存）
                                $logFiles = @(
                                    (Join-Path $sessDir "iperf_results.log"),
                                    (Join-Path $sessDir "iperf_${safeIp}.log"),
                                    (Join-Path $reportsDir "iperf_results.log"),
                                    (Join-Path $reportsDir "iperf_latest.log")
                                )

                                # ヘルパー: 全ログファイルに追記
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
                                    # 最新ログファイルのみ初期化
                                    try { "" | Out-File -FilePath (Join-Path $reportsDir "iperf_latest.log") -Encoding UTF8 -Force } catch {}

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
                                    $tsEnd = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                                    $endLabel = if ($sync.IperfState.StopRequested) { "STOPPED by user" } else { "Finished" }
                                    Write-IperfLogs "=== iperf3 $endLabel at $tsEnd ==="
                                    Write-IperfLogs "-----------------------------------------------------------"

                                    # ── 統計サマリー集計 ──────────────────────────────────────
                                    try {
                                        $primaryLogFile = Join-Path $sessDir "iperf_results.log"
                                        $logContent     = Get-Content $primaryLogFile -Encoding UTF8 -ErrorAction SilentlyContinue
                                        $bwValues       = [System.Collections.Generic.List[double]]::new()
                                        $totalTimeSec   = 0.0
                                        foreach ($logLine in $logContent) {
                                            if ($logLine -match '\[\s*\d+\]\s+([0-9.]+)-([0-9.]+)\s+sec\s+[0-9.]+\s+[KMG]?Bytes\s+([0-9.]+)\s+([KMG]?)bits/sec' `
                                                -and $logLine -notmatch 'sender|receiver|SUM') {
                                                $startT = [double]$Matches[1]
                                                $endT   = [double]$Matches[2]
                                                $bwRaw  = [double]$Matches[3]
                                                $unit   = $Matches[4]
                                                $bwMbps = switch ($unit) {
                                                    'K' { $bwRaw / 1000.0 }
                                                    'G' { $bwRaw * 1000.0 }
                                                    default { $bwRaw }
                                                }
                                                $intervalLen = $endT - $startT
                                                if ($intervalLen -gt 0.0 -and $intervalLen -le 1.5) {
                                                    $bwValues.Add($bwMbps)
                                                    if ($endT -gt $totalTimeSec) { $totalTimeSec = $endT }
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

                                            # Japanese labels via Base64
                                            $iperfB64 = "eyJoZWFkZXIiOiAiPT09PT09PT09PSBpcGVyZjMg57Wx6KiI44K144Oe44Oq44O8ID09PT09PT09PT0iLCAiZHVyYXRpb24iOiAi5ZCI6KiI6KiI5ris5pmC6ZaTIiwgInNhbXBsZXMiOiAi44K144Oz44OX44Or5pWwIiwgImF2ZyI6ICLlubPlnYfluK/ln5/luYUiLCAibWVkaWFuIjogIuS4reWkruWApCIsICJtYXhCdyI6ICLmnIDlpKfluK/ln5/luYUiLCAibWluQnciOiAi5pyA5bCP5biv5Z+f5bmFIiwgInN0ZERldiI6ICLmqJnmupblgY/lt64iLCAidGhyZXNoIjogIuW4r+Wfn+mWvuWApCIsICJhYm92ZSI6ICLplr7lgKTku6XkuIoiLCAiYmVsb3ciOiAi6Za+5YCk5pyq5rqAIiwgImZvb3RlciI6ICI9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0ifQ=="
                                            $iL = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($iperfB64)) | ConvertFrom-Json

                                            $iLines = [System.Collections.Generic.List[string]]::new()
                                            $iLines.Add("")
                                            $iLines.Add($iL.header)
                                            $iLines.Add($iL.duration + "   : " + ("{0:F1}" -f $totalTimeSec) + " sec")
                                            $iLines.Add($iL.samples  + "     : " + $n + " (1sec/sample)")
                                            $iLines.Add($iL.avg      + "     : " + ("{0:F2}" -f $avg) + " Mbps")
                                            $iLines.Add($iL.median   + "         : " + ("{0:F2}" -f $median) + " Mbps")
                                            $iLines.Add($iL.maxBw    + "     : " + ("{0:F2}" -f $maxBw) + " Mbps")
                                            $iLines.Add($iL.minBw    + "     : " + ("{0:F2}" -f $minBw) + " Mbps")
                                            $iLines.Add($iL.stdDev   + "       : " + ("{0:F2}" -f $stdDev) + " Mbps")
                                            $iLines.Add($iL.thresh   + "       : " + $bwThresh + " Mbps")
                                            $iLines.Add($iL.above    + " (" + $bwThresh + " Mbps~) : " + $aboveCount + " / " + $abovePct + " %")
                                            $iLines.Add($iL.below    + " (~"+ $bwThresh + " Mbps) : " + $belowCount + " / " + $belowPct + " %")
                                            $iLines.Add($iL.footer)
                                            $summaryText = ($iLines -join "`r`n")
                                            Write-IperfLogs $summaryText
                                        }
                                    } catch {}
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
                    # Latest iperf log download endpoint
                    $primaryLog = Join-Path $syncHash.SessionDir "iperf_results.log"
                    $fallbackLog = Join-Path $syncHash.PSScriptRoot "..\Reports\iperf_results.log"
                    $targetLog = if (Test-Path $primaryLog) { $primaryLog } elseif (Test-Path $fallbackLog) { $fallbackLog } else { $null }
                    if ($targetLog) {
                        $logBytes = [System.IO.File]::ReadAllBytes($targetLog)
                        $response.ContentType = "text/plain; charset=utf-8"
                        $response.AddHeader("Content-Disposition", "attachment; filename=`"iperf_results.log`"")
                        $response.ContentLength64 = $logBytes.Length
                        $response.OutputStream.Write($logBytes, 0, $logBytes.Length)
                        $response.Close()
                    } else {
                        Write-JsonResponse $response @{ error = "No iperf log found" } 404
                    }
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

                            Write-JsonResponse $response @{ activeIps = $activeIps.ToArray() }
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

                        # Run tracert. limit hops to 10 and timeout to 300ms to avoid long delays
                        $traceOutput = tracert -d -h 10 -w 300 $target
                        $hops = @()
                        foreach ($line in $traceOutput) {
                            if ($line -match '(?:\s+)(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})') {
                                $hopIp = $matches[1]
                                $hops += $hopIp
                            }
                        }
                        
                        # Ensure target is appended if trace did not reach but target is valid
                        if ($hops.Count -gt 0 -and $hops[-1] -ne $target) {
                            $pingRes = Test-Connection -ComputerName $target -Count 1 -Quiet -ErrorAction SilentlyContinue
                            if ($pingRes) {
                                $hops += $target
                            }
                        }

                        Write-JsonResponse $response @{ hops = $hops }
                    } else {
                        Write-JsonResponse $response @{ error = "Missing target parameter" } 400
                    }
                }
                elseif ($urlPath -eq "/api/shutdown" -and $method -eq "POST") {
                    $syncHash.PendingShutdown = $true
                    $syncHash.PendingShutdownTime = [DateTime]::UtcNow.AddSeconds(4) # wait 4 seconds for browser reload/reconnect
                    Write-JsonResponse $response @{ status = "success"; message = "Pending shutdown" }
                    Write-Host "Shutdown signal received from browser (pending)." -ForegroundColor Yellow
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
                $header = "タイムスタンプ,IPアドレス,ステータス,遅延_ms,帯域_Mbps,送信_Mbps,受信_Mbps`r`n"
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

                $maxOutageSec = if ($stats.MaxOutageSec -gt 0) { [math]::Round($stats.MaxOutageSec, 1) } else { 'N/A' }
                $out600ms     = $stats.Outage600msCount
                $out5s        = $stats.Outage5sCount
                $thresh1Label = "$($syncHash.OutageThresh1Ms)ms"
                $thresh2Label = if ($syncHash.OutageThresh2Ms -ge 1000) { "$([int]($syncHash.OutageThresh2Ms/1000))s" } else { "$($syncHash.OutageThresh2Ms)ms" }

                $packetLossRate = if ($total -gt 0) { [math]::Round(($failed / $total) * 100, 1) } else { 0 }
                $jitterVal = if ($null -ne $stats.Jitter -and $stats.Jitter -gt 0) { $stats.Jitter } else { 'N/A' }

                # Japanese labels via Base64 (avoids PS5 source-encoding issues)
                $pingB64 = "eyJoZWFkZXIiOiAiLS0tIOioiOa4rOOCteODnuODquODvCAtLS0iLCAic2Vzc2lvbiI6ICLjgrvjg4Pjgrfjg6fjg7PvvIjoqIjmuKzlm57vvIkiLCAiaXAiOiAiSVDjgqLjg4njg6zjgrkiLCAidG90YWxQaW5ncyI6ICLnt49QaW5n6YCB5L+h5pWw77yI6Kmm6KGM5Zue5pWw77yJIiwgInN1Y2Nlc3MiOiAi5oiQ5Yqf5pWw77yI5b+c562U44GC44KK77yJIiwgImZhaWxlZCI6ICLlpLHmlZfmlbDvvIjlv5znrZTjgarjgZfjg7vjgr/jgqTjg6DjgqLjgqbjg4jvvIkiLCAicmVhY2giOiAi5Yiw6YGU546HIC8g5o6l57aa5oCnICglKSIsICJwYWNrZXRMb3NzIjogIuODkeOCseODg+ODiOaQjeWkseeOhyAoJSkiLCAiaml0dGVyIjogIuW5s+Wdh+OCuOODg+OCv+ODvCAobXMpIiwgImxhdE1pbiI6ICLmnIDlsI/pgYXlu7YgKG1zKSIsICJsYXRNYXgiOiAi5pyA5aSn6YGF5bu2IChtcykiLCAibGF0QXZnIjogIuW5s+Wdh+mBheW7tiAobXMpIiwgImxhdE91dGFnZSI6ICLmnIDlpKfnnqzmlq3mmYLplpPvvIjmnIDlpKfpgJrkv6HlgZzmraLmmYLplpPvvInvvIjnp5LvvIkiLCAib3V0YWdlQWJvdmUiOiAi5Lul5LiK44Gu556s5pat5Zue5pWw77yI5pat44GM55m655Sf44GX44Gf5Zue5pWw77yJIiwgIm5vdGUiOiAi5YKZ6ICD77yI556s5pat5Zue5pWw44Gu6ZuG6KiI44Gr44Gk44GE44Gm77yJIiwgIm5vdGVWYWwiOiAi44Kq44OV44Op44Kk44Oz44GL44KJ44Kq44Oz44Op44Kk44Oz44G45b6p5biw44GX44Gf5pmC54K544Gn44Kr44Km44Oz44OI44CC44K744OD44K344On44Oz57WC5LqG5pmC54K544Gn57aZ57aa5Lit44Gu556s5pat44Gv5ZCr44G/44G+44Gb44KTIn0="
                $pL = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($pingB64)) | ConvertFrom-Json

                $lines = [System.Collections.Generic.List[string]]::new()
                $lines.Add("")
                $lines.Add($pL.header)
                $lines.Add($pL.session + "," + $Tstr)
                $lines.Add($pL.ip + "," + $ip)
                $lines.Add($pL.totalPings + "," + $total)
                $lines.Add($pL.success + "," + $success)
                $lines.Add($pL.failed + "," + $failed)
                $lines.Add($pL.reach + "," + $reachRate)
                $lines.Add($pL.packetLoss + "," + $packetLossRate)
                $lines.Add($pL.jitter + "," + $jitterVal)
                $lines.Add($pL.latMin + "," + $minLat)
                $lines.Add($pL.latMax + "," + $maxLat)
                $lines.Add($pL.latAvg + "," + $avgLat)
                $lines.Add($pL.maxOutage + "," + $maxOutageSec)
                $lines.Add($thresh1Label + $pL.outageAbove + "," + $out600ms)
                $lines.Add($thresh2Label + $pL.outageAbove + "," + $out5s)
                $lines.Add($pL.note + "," + $pL.noteVal)
                $summaryBlock = ($lines -join "`r`n") + "`r`n"
                try {
                    [System.IO.File]::AppendAllText($csvPath, $summaryBlock, [System.Text.Encoding]::GetEncoding(932))
                    Write-Host "Appended final summary for $ip to $csvPath" -ForegroundColor Cyan
                } catch {}
            }
        }
    }

    if ($null -ne $listener)     { try { $listener.Stop();   $listener.Close()   } catch {} }
    if ($null -ne $keyRunspace)  { try { $keyRunspace.Close(); $keyRunspace.Dispose() } catch {} }
    Write-Host "Server stopped gracefully." -ForegroundColor Gray
}
