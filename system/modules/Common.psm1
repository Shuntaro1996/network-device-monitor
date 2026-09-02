# ==============================================================================
# Common.psm1 - 共通ユーティリティ・セキュリティ・ログモジュール
# ==============================================================================

Add-Type -AssemblyName System.Security

# ── 1. 秘密情報暗号化・復号 (Windows DPAPI) ───────────────────────────────────

function Protect-SecretString {
    <#
    .SYNOPSIS
        平文文字列を現在のWindowsユーザーの資格情報を用いてDPAPIで暗号化します。
    #>
    param([string]$plainText)
    if ([string]::IsNullOrEmpty($plainText)) { return "" }
    if ($plainText.StartsWith("enc:")) { return $plainText } # 既に暗号化済み
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($plainText)
        $encBytes = [System.Security.Cryptography.ProtectedData]::Protect(
            $bytes,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return "enc:" + [System.Convert]::ToBase64String($encBytes)
    } catch {
        Write-Warning "DPAPI encryption failed: $($_.Exception.Message)"
        return $plainText
    }
}

function Unprotect-SecretString {
    <#
    .SYNOPSIS
        DPAPIで暗号化された文字列（enc:...）を復号します。平文の場合はそのまま返します。
    #>
    param([string]$cipherText)
    if ([string]::IsNullOrEmpty($cipherText)) { return "" }
    if (-not $cipherText.StartsWith("enc:")) { return $cipherText } # 平文互換
    try {
        $b64 = $cipherText.Substring(4)
        $encBytes = [System.Convert]::FromBase64String($b64)
        $decBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $encBytes,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [System.Text.Encoding]::UTF8.GetString($decBytes)
    } catch {
        Write-Warning "DPAPI decryption failed: $($_.Exception.Message)"
        return ""
    }
}

# ── 2. ログ記録 ─────────────────────────────────────────────────────────────

function Log-Audit {
    param(
        [string]$action,
        [string]$target,
        [string]$details,
        [string]$clientIp = "127.0.0.1",
        [string]$reportsDirectory
    )
    try {
        if (-not $reportsDirectory) { return }
        $auditFile = Join-Path $reportsDirectory "audit.log"
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $logLine = "[$ts] ACTION: $action | TARGET: $target | DETAILS: $details | CLIENT: $clientIp`r`n"
        [System.IO.File]::AppendAllText($auditFile, $logLine, [System.Text.Encoding]::UTF8)
    } catch {}
}

function Write-ServerLog {
    param(
        [string]$message,
        [string]$level = "INFO",
        [string]$baseDir = $null
    )
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$ts] [$level] $message"
    switch ($level) {
        "ERROR"   { Write-Host $line -ForegroundColor Red }
        "WARN"    { Write-Host $line -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $line -ForegroundColor Green }
        default   { Write-Host $line -ForegroundColor Gray }
    }
    if ($baseDir) {
        try {
            $logPath = Join-Path $baseDir "debug.log"
            [System.IO.File]::AppendAllText($logPath, "$line`r`n", [System.Text.Encoding]::UTF8)
        } catch {}
    }
}

# ── 3. HTTP / JSON レスポンス ───────────────────────────────────────────────

function Write-JsonResponse {
    param(
        $response,
        $data,
        [int]$statusCode = 200
    )
    try {
        $json = $data | ConvertTo-Json -Depth 10 -Compress
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
        $response.ContentType = "application/json; charset=utf-8"
        $response.StatusCode = $statusCode
        $response.ContentLength64 = $buffer.Length
        $response.OutputStream.Write($buffer, 0, $buffer.Length)
        $response.Close()
    } catch {
        try { $response.Close() } catch {}
    }
}

function Get-MimeType {
    param([string]$ext)
    switch ($ext.ToLower()) {
        ".html" { "text/html; charset=utf-8" }
        ".css"  { "text/css; charset=utf-8" }
        ".js"   { "application/javascript; charset=utf-8" }
        ".json" { "application/json; charset=utf-8" }
        ".png"  { "image/png" }
        ".jpg"  { "image/jpeg" }
        ".jpeg" { "image/jpeg" }
        ".ico"  { "image/x-icon" }
        ".svg"  { "image/svg+xml" }
        ".txt"  { "text/plain; charset=utf-8" }
        ".csv"  { "text/csv; charset=shift_jis" }
        default { "application/octet-stream" }
    }
}

# ── 4. デバイス一覧保存 (暗号化対応) ───────────────────────────────────────

function Save-DevicesJson {
    param(
        [hashtable]$syncHash,
        [string]$filePath
    )
    try {
        $devArray = @()
        $devList = $syncHash.Devices
        if ($null -ne $devList) {
            foreach ($ip in $devList) {
                # SNMPパスワードは保存時に自動暗号化
                $rawAuthPass = if ($syncHash.SnmpAuthPass.ContainsKey($ip)) { $syncHash.SnmpAuthPass[$ip] } else { "" }
                $rawPrivPass = if ($syncHash.SnmpPrivPass.ContainsKey($ip)) { $syncHash.SnmpPrivPass[$ip] } else { "" }
                $encAuthPass = if ($rawAuthPass) { Protect-SecretString $rawAuthPass } else { "" }
                $encPrivPass = if ($rawPrivPass) { Protect-SecretString $rawPrivPass } else { "" }

                $d = @{
                    ip            = $ip
                    name          = if ($syncHash.DeviceName.ContainsKey($ip))    { $syncHash.DeviceName[$ip] }    else { $ip }
                    group         = if ($syncHash.Group.ContainsKey($ip))         { $syncHash.Group[$ip] }         else { "" }
                    location      = if ($syncHash.Location.ContainsKey($ip))      { $syncHash.Location[$ip] }      else { "" }
                    troubleMemo   = if ($syncHash.TroubleMemo.ContainsKey($ip))   { $syncHash.TroubleMemo[$ip] }   else { "" }
                    mac           = if ($syncHash.Mac.ContainsKey($ip))           { $syncHash.Mac[$ip] }           else { "" }
                    deviceType    = if ($syncHash.DeviceType.ContainsKey($ip))    { $syncHash.DeviceType[$ip] }    else { "network" }
                    image         = if ($syncHash.DeviceImage.ContainsKey($ip))   { $syncHash.DeviceImage[$ip] }   else { "" }
                    vendorContact = if ($syncHash.VendorContact.ContainsKey($ip)) { $syncHash.VendorContact[$ip] } else { "" }
                    webUrl        = if ($syncHash.WebUrl.ContainsKey($ip))        { $syncHash.WebUrl[$ip] }        else { "" }
                    checkType     = if ($syncHash.CheckType.ContainsKey($ip))     { $syncHash.CheckType[$ip] }     else { "icmp" }
                    port          = if ($syncHash.Port.ContainsKey($ip))          { $syncHash.Port[$ip] }          else { 0 }
                    enabled       = if ($syncHash.Enabled.ContainsKey($ip))       { $syncHash.Enabled[$ip] }       else { $true }
                    community     = if ($syncHash.Community.ContainsKey($ip))     { $syncHash.Community[$ip] }     else { "public" }
                    snmpVersion   = if ($syncHash.SnmpVersion.ContainsKey($ip))   { $syncHash.SnmpVersion[$ip] }   else { "v2c" }
                    snmpUser      = if ($syncHash.SnmpUser.ContainsKey($ip))      { $syncHash.SnmpUser[$ip] }      else { "" }
                    snmpAuthProto = if ($syncHash.SnmpAuthProto.ContainsKey($ip)) { $syncHash.SnmpAuthProto[$ip] } else { "none" }
                    snmpAuthPass  = $encAuthPass
                    snmpPrivProto = if ($syncHash.SnmpPrivProto.ContainsKey($ip)) { $syncHash.SnmpPrivProto[$ip] } else { "none" }
                    snmpPrivPass  = $encPrivPass
                    connectedTo   = if ($syncHash.ConnectedTo.ContainsKey($ip))   { $syncHash.ConnectedTo[$ip] }   else { "" }
                    x             = if ($syncHash.TopoX.ContainsKey($ip))         { $syncHash.TopoX[$ip] }         else { $null }
                    y             = if ($syncHash.TopoY.ContainsKey($ip))         { $syncHash.TopoY[$ip] }         else { $null }
                }
                $devArray += $d
            }
        }
        $json = $devArray | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($filePath, $json, [System.Text.Encoding]::UTF8)
        return $true
    } catch {
        Write-Warning "Failed to save devices.json: $($_.Exception.Message)"
        return $false
    }
}

# ── 5. 自動スナップショット & ロールバック ───────────────────────────────────

function Backup-ConfigSnapshot {
    <#
    .SYNOPSIS
        devices.json または config.json を変更前に system/backups/ 配下へ自動スナップショット退避します。
        最新 N世代（デフォルト20世代）を保持し、古いファイルは自動ローテーション削除します。
    #>
    param(
        [string]$targetFilePath,
        [string]$backupDir,
        [int]$maxGenerations = 20
    )
    if (-not (Test-Path $targetFilePath)) { return $null }
    try {
        if (-not (Test-Path $backupDir)) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        }
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($targetFilePath) # "devices" or "config"
        $ts = (Get-Date).ToString("yyyyMMdd_HHmmss_fff")
        $snapshotName = "${baseName}_${ts}.json"
        $snapshotPath = Join-Path $backupDir $snapshotName

        Copy-Item -Path $targetFilePath -Destination $snapshotPath -Force

        # 古いスナップショットのローテーション削除 (ファイル名が yyyyMMdd_HHmmss_fff なので Name 降順が最も堅牢)
        $existing = Get-ChildItem -Path $backupDir -Filter "${baseName}_*.json" | Sort-Object Name -Descending
        if ($existing.Count -gt $maxGenerations) {
            $toDelete = $existing | Select-Object -Skip $maxGenerations
            foreach ($f in $toDelete) {
                try { Remove-Item -Path $f.FullName -Force } catch {}
            }
        }
        return $snapshotPath
    } catch {
        Write-Warning "Backup-ConfigSnapshot failed: $($_.Exception.Message)"
        return $null
    }
}

function Get-ConfigSnapshots {
    <#
    .SYNOPSIS
        system/backups/ 配下に保存されているスナップショット一覧を取得します。
    #>
    param([string]$backupDir)
    if (-not (Test-Path $backupDir)) { return @() }
    try {
        $files = Get-ChildItem -Path $backupDir -Filter "*.json" | Sort-Object Name -Descending
        $arr = @(
            foreach ($f in $files) {
                $type = if ($f.Name.StartsWith("devices_")) { "devices" } elseif ($f.Name.StartsWith("config_")) { "config" } else { "other" }
                [PSCustomObject]@{
                    fileName  = $f.Name
                    type      = $type
                    createdAt = $f.CreationTime.ToString("yyyy-MM-dd HH:mm:ss")
                    sizeBytes = $f.Length
                }
            }
        )
        return $arr
    } catch {
        return @()
    }
}

function Restore-ConfigSnapshot {
    <#
    .SYNOPSIS
        指定されたスナップショットから設定ファイルを復元します。
        安全のため、復元直前の現行ファイルも直前スナップショットとして自動退避します。
    #>
    param(
        [string]$snapshotFileName,
        [string]$backupDir,
        [string]$targetDir
    )
    $sourcePath = Join-Path $backupDir $snapshotFileName
    if (-not (Test-Path $sourcePath)) {
        return @{ success = $false; error = "Snapshot file not found: $snapshotFileName" }
    }

    $targetFileName = if ($snapshotFileName.StartsWith("devices_")) { "devices.json" } elseif ($snapshotFileName.StartsWith("config_")) { "config.json" } else { $null }
    if (-not $targetFileName) {
        return @{ success = $false; error = "Unknown snapshot type" }
    }

    $destPath = Join-Path $targetDir $targetFileName
    try {
        # 復元前に現行ファイルを安全スナップショット退避
        if (Test-Path $destPath) {
            $null = Backup-ConfigSnapshot -targetFilePath $destPath -backupDir $backupDir
        }
        Copy-Item -Path $sourcePath -Destination $destPath -Force
        return @{ success = $true; restoredFile = $targetFileName; fromSnapshot = $snapshotFileName }
    } catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

# ── 6. 前提環境・モジュール診断 & 自動インストール ─────────────────────────────

function Test-SystemPrerequisites {
    <#
    .SYNOPSIS
        Network Device Monitor の実行に必要なモジュール・ツール・実行環境を検査します。
    #>
    param([string]$projectRoot = $null)
    if (-not $projectRoot) {
        $projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
    }

    # 1. PowerShell バージョン
    $psVer = $PSVersionTable.PSVersion.ToString()
    $isPsCompatible = ($PSVersionTable.PSVersion.Major -ge 5)

    # 2. 実行ポリシー
    $execPolicy = try { (Get-ExecutionPolicy).ToString() } catch { "Unknown" }
    $isPolicyOk = ($execPolicy -in @("Bypass", "Unrestricted", "RemoteSigned"))

    # 3. NuGet パッケージプロバイダー
    $nuGetProvider = try { Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { $null }
    $hasNuGet = ($null -ne $nuGetProvider)

    # 4. SNMP モジュール (トラフィック監視・機器詳細・トポロジー探索に必須)
    $snmpMod = try { Get-Module -ListAvailable -Name SNMP -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { $null }
    $hasSnmp = ($null -ne $snmpMod)
    $snmpVersion = if ($hasSnmp) { $snmpMod.Version.ToString() } else { "" }
    $snmpPath = if ($hasSnmp) { $snmpMod.Path } else { "" }

    # 5. Pester モジュール (自動テストフレームワーク)
    $pesterMod = try { Get-Module -ListAvailable -Name Pester -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { $null }
    $hasPester = ($null -ne $pesterMod)
    $pesterVersion = if ($hasPester) { $pesterMod.Version.ToString() } else { "" }

    # 6. Iperf3 実行バイナリ (帯域計測ツール)
    $iperfPath = Join-Path $projectRoot "tools\iperf3.exe"
    $hasIperf = (Test-Path $iperfPath)
    if (-not $hasIperf) {
        $cmdIperf = Get-Command "iperf3.exe" -ErrorAction SilentlyContinue
        if ($cmdIperf) {
            $hasIperf = $true
            $iperfPath = $cmdIperf.Source
        }
    }

    # 7. ポート 8081 の競合状態
    $port = 8081
    $isPortAvailable = $true
    try {
        $listenerTest = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $port)
        $listenerTest.Start()
        $listenerTest.Stop()
    } catch {
        $isPortAvailable = $false
    }

    # 総合判定 (SNMP と PowerShell 互換性、Iperf3 が整っていれば OK)
    $allReady = ($isPsCompatible -and $hasSnmp -and $hasIperf)

    return @{
        allReady         = $allReady
        psVersion        = $psVer
        isPsCompatible   = $isPsCompatible
        executionPolicy  = $execPolicy
        isPolicyOk       = $isPolicyOk
        hasNuGet         = $hasNuGet
        snmpModule       = @{
            installed   = $hasSnmp
            version     = $snmpVersion
            path        = $snmpPath
            requiredFor = "SNMPインターフェース帯域監視、機器詳細情報、隣接トポロジー探索"
            critical    = $true
        }
        pesterModule     = @{
            installed   = $hasPester
            version     = $pesterVersion
            requiredFor = "Pester による品質保証・単体/結合自動テスト"
            critical    = $false
        }
        iperf3           = @{
            available   = $hasIperf
            path        = $iperfPath
            requiredFor = "Iperf3 帯域・スループット・ジッター計測"
            critical    = $false
        }
        portAvailable    = $isPortAvailable
    }
}

function Install-PrerequisiteModule {
    <#
    .SYNOPSIS
        指定された PowerShell モジュールをインストールします。
    #>
    param([string]$moduleName = "SNMP")
    try {
        # NuGet パッケージプロバイダーの確認・導入
        $nuGet = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
        if (-not $nuGet) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
        }

        # モジュールインストール
        Install-Module -Name $moduleName -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop | Out-Null
        return @{ success = $true; message = "Module $moduleName successfully installed." }
    } catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

Export-ModuleMember -Function Protect-SecretString, Unprotect-SecretString, Log-Audit, Write-ServerLog, Write-JsonResponse, Get-MimeType, Save-DevicesJson, Backup-ConfigSnapshot, Get-ConfigSnapshots, Restore-ConfigSnapshot, Test-SystemPrerequisites, Install-PrerequisiteModule
