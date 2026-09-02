# ==============================================================================
# SnmpService.psm1 - SNMP・ネットワークトポロジー探索・Web/SSL監視モジュール
# ==============================================================================

# Common モジュール（秘密情報復号など）をインポート
Import-Module (Join-Path $PSScriptRoot "Common.psm1") -ErrorAction SilentlyContinue

# ── 1. SharpSnmpLib の初期化 ────────────────────────────────────────────────

function Initialize-SnmpLibrary {
    param([string]$moduleDir)
    if ([string]::IsNullOrWhiteSpace($moduleDir)) { return }
    $dllPath = Join-Path $moduleDir "SharpSnmpLib.dll"
    if (Test-Path $dllPath) {
        Add-Type -Path $dllPath -ErrorAction SilentlyContinue
    }
}

# ── 2. Web / SSL証明書チェック ─────────────────────────────────────────────

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
        $req.ServerCertificateValidationCallback = { $true } # 自己署名証明書も許可
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

# ── 3. SNMP Get / Walk Unified (v1 / v2c / v3) ──────────────────────────────

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
    if ([string]::IsNullOrWhiteSpace($IP)) { return @() }
    
    # 暗号化パスワードの自動復号
    if ($AuthPass -and $AuthPass.StartsWith("enc:")) { $AuthPass = Unprotect-SecretString $AuthPass }
    if ($PrivPass -and $PrivPass.StartsWith("enc:")) { $PrivPass = Unprotect-SecretString $PrivPass }

    try {
        $ipAddr = [System.Net.IPAddress]::Parse($IP)
        $endpoint = New-Object System.Net.IPEndPoint $ipAddr, $Port
        
        if ($Version -eq "v3") {
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
            
            $result = @()
            foreach ($v in $resVars) {
                $result += New-Object PSObject -Property @{
                    OID = $v.Id.ToString()
                    Data = $v.Data.ToString()
                }
            }
            return $result
        } else {
            $variableList = New-Object Collections.Generic.List[Lextm.SharpSnmpLib.Variable]
            foreach ($oid in $Oids) {
                $variableList.Add($(New-Object Lextm.SharpSnmpLib.ObjectIdentifier $oid))
            }
            $versionEnum = if ($Version -eq "V1" -or $Version -eq "v1") { [Lextm.SharpSnmpLib.VersionCode]::V1 } else { [Lextm.SharpSnmpLib.VersionCode]::V2 }
            $message = [Lextm.SharpSnmpLib.Messaging.Messenger]::Get(
                $versionEnum, 
                $endpoint, 
                $Community, 
                $variableList, 
                $Timeout
            )
            $result = @()
            foreach ($v in $message) {
                $result += New-Object PSObject -Property @{
                    OID = $v.Id.ToString()
                    Data = $v.Data.ToString()
                }
            }
            return $result
        }
    } catch {
        return @()
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
    if ([string]::IsNullOrWhiteSpace($IP) -or [string]::IsNullOrWhiteSpace($OIDStart)) { return @() }

    # 暗号化パスワードの自動復号
    if ($AuthPass -and $AuthPass.StartsWith("enc:")) { $AuthPass = Unprotect-SecretString $AuthPass }
    if ($PrivPass -and $PrivPass.StartsWith("enc:")) { $PrivPass = Unprotect-SecretString $PrivPass }

    try {
        $ipAddr = [System.Net.IPAddress]::Parse($IP)
        $endpoint = New-Object System.Net.IPEndPoint $ipAddr, $Port
        $rootOid = New-Object Lextm.SharpSnmpLib.ObjectIdentifier $OIDStart
        
        $result = @()
        if ($Version -eq "v3") {
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
            
            $vList = New-Object Collections.Generic.List[Lextm.SharpSnmpLib.Variable]
            [Lextm.SharpSnmpLib.Messaging.Messenger]::Walk(
                [Lextm.SharpSnmpLib.VersionCode]::V3,
                $endpoint,
                (New-Object Lextm.SharpSnmpLib.OctetString $User),
                $rootOid,
                $vList,
                $Timeout,
                [Lextm.SharpSnmpLib.Messaging.WalkMode]::WithinSubtree,
                $privacyProvider,
                $report
            ) | Out-Null

            foreach ($v in $vList) {
                $result += New-Object PSObject -Property @{
                    OID = $v.Id.ToString()
                    Data = $v.Data.ToString()
                }
            }
        } else {
            $vList = New-Object Collections.Generic.List[Lextm.SharpSnmpLib.Variable]
            $versionEnum = if ($Version -eq "V1" -or $Version -eq "v1") { [Lextm.SharpSnmpLib.VersionCode]::V1 } else { [Lextm.SharpSnmpLib.VersionCode]::V2 }
            [Lextm.SharpSnmpLib.Messaging.Messenger]::Walk(
                $versionEnum,
                $endpoint,
                $Community,
                $rootOid,
                $vList,
                $Timeout,
                [Lextm.SharpSnmpLib.Messaging.WalkMode]::WithinSubtree
            ) | Out-Null

            foreach ($v in $vList) {
                $result += New-Object PSObject -Property @{
                    OID = $v.Id.ToString()
                    Data = $v.Data.ToString()
                }
            }
        }
        return $result
    } catch {
        return @()
    }
}

Export-ModuleMember -Function Initialize-SnmpLibrary, Check-WebAndSslEndpoint, Invoke-SnmpGetUnified, Invoke-SnmpWalkUnified
