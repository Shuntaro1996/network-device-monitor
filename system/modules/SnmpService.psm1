# ==============================================================================
# SnmpService.psm1 - SNMP・ネットワークトポロジー探索・Web/SSL監視モジュール
# ==============================================================================
# 【初心者向けの簡単な解説】
# SNMP は、機器から通信量やポートの状態などを読み取るための決まりごとです。
# このファイルには次の部品があります。
#   - Web サイトの応答と SSL 証明書の有効期限の確認
#   - 機器への問い合わせ (Get は指定した項目だけ、Walk はまとめて読む)
#   - 機器から届く SNMP Trap (通知) の読み解き
#
# 【変更するときの注意】
# - 問い合わせの関数は SharpSnmpLib に依存します。Trap の読み解きは外部ライブラリなしで動きます。
# - 問い合わせの失敗は例外にせず、空の配列を返します。「値が 0」と「読めなかった」を混同しないでください。
# - Trap は外部から届くデータなので、形式が不正でも止まらないよう、範囲の確認を外さないでください。
# - Trap のテストは tests/Monitor.Tests.ps1 の 8b です。問い合わせは実機がないと確かめられません。
# ==============================================================================

# Common モジュール（秘密情報復号など）をインポート
Import-Module (Join-Path $PSScriptRoot "Common.psm1") -DisableNameChecking -ErrorAction SilentlyContinue

# ── 1. SharpSnmpLib の初期化 ────────────────────────────────────────────────

function Initialize-SnmpLibrary {
    # moduleDir にある SharpSnmpLib.dll を読み込む。ファイルがなければ何もしない
    param([string]$moduleDir)
    if ([string]::IsNullOrWhiteSpace($moduleDir)) { return }
    $dllPath = Join-Path $moduleDir "SharpSnmpLib.dll"
    if (Test-Path $dllPath) {
        Add-Type -Path $dllPath -ErrorAction SilentlyContinue
    }
}

# ── 2. Web / SSL証明書チェック ─────────────────────────────────────────────

function Check-WebAndSslEndpoint {
    <#
    .SYNOPSIS
        URL に接続して、応答と SSL 証明書の残り日数を確認します。
    .OUTPUTS
        Success / StatusCode / ResponseTimeMs / SslDaysRemaining / SslSubject / SslIssuer / Error を持つハッシュテーブル。
        404 や 500 が返ると Success は $false で、StatusCode に番号が入ります。
    .NOTES
        監視対象の機器は自己署名証明書が多いので、証明書の検証はしません。
        期限を読むための確認で、相手が本物かどうかは確かめていません。
    #>
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
        $req.ServerCertificateValidationCallback = [TrustAllCertsPolicy]::Callback # 自己署名証明書も許可（C#デリゲートでRunspace非依存）
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
        # $_ はエラー記録なので、応答は $_.Exception.Response にある (以前は常に空で、404 等でも状態コードが 0 になり、
        #  応答も閉じられずに接続が残り、同じサイトへの次の確認がタイムアウトしていた)
        $errResp = $_.Exception.Response
        if ($errResp) {
            $res.StatusCode = [int]$errResp.StatusCode
            try { $errResp.Close() } catch {}
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
    <#
    .SYNOPSIS
        指定した項目 (OID) の値を機器から読み取ります。v1 / v2c / v3 に対応します。
    .PARAMETER Community
        v1 / v2c の合言葉。v3 では使いません。
    .PARAMETER AuthPass
        v3 の認証パスワード。暗号化された値 ("enc:" で始まる) は自動で復号します。PrivPass も同じです。
    .PARAMETER Oids
        読み取る項目の番号の一覧。
    .OUTPUTS
        OID と Data を持つオブジェクトの配列。失敗すると空の配列を返し、例外にはしません。
    .NOTES
        v3 の認証は MD5 / SHA、暗号化は DES だけに対応します。AES を指定しても暗号化なしの扱いになります。
    #>
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
    <#
    .SYNOPSIS
        OIDStart より下の項目をまとめて読み取ります (例: すべてのポートの通信量)。
    .OUTPUTS
        OID と Data を持つオブジェクトの配列。失敗すると空の配列を返し、例外にはしません。
    .NOTES
        引数と認証の扱いは Invoke-SnmpGetUnified と同じです。v3 の設定を直すときは両方を直してください。
    #>
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

# ── SNMP Trap の解析 ─────────────────────────────────────────────────────────
# 【初心者向けの簡単な解説】
# SNMP Trap は、機器が「ポートが切れた」「再起動した」などを自分から知らせてくる通知です。
# データは BER という「種類・長さ・中身」を繰り返す形式の 2 進データで届くので、ここで読み解きます。
# SNMP モジュールが入っていない PC でも受信できるよう、外部ライブラリは使いません。

function Read-BerElement {
    # $offset の位置にある 1 要素の「種類 (tag)・中身の開始位置・中身の長さ」を返す
    param([byte[]]$buffer, [int]$offset, [int]$limit)
    if ($offset + 2 -gt $limit) { throw "BER: データが途中で切れています" }
    $tag = [int]$buffer[$offset]
    $lengthByte = [int]$buffer[$offset + 1]
    $valueStart = $offset + 2
    $length = $lengthByte
    if ($lengthByte -ge 0x80) {
        $lengthBytes = $lengthByte -band 0x7F
        if ($lengthBytes -lt 1 -or $lengthBytes -gt 4 -or ($valueStart + $lengthBytes) -gt $limit) { throw "BER: 長さの形式が不正です" }
        $length = [long]0
        for ($i = 0; $i -lt $lengthBytes; $i++) { $length = ($length * 256) + $buffer[$valueStart + $i] }
        $valueStart += $lengthBytes
    }
    if ($valueStart + $length -gt $limit) { throw "BER: 長さがデータの範囲を超えています" }
    return @{ Tag = $tag; ValueStart = $valueStart; Length = [int]$length; End = $valueStart + [int]$length }
}

function ConvertFrom-BerOid {
    # OID の 2 進データを "1.3.6.1..." の文字に直す
    # 先頭の 1 バイトに最初の 2 つの番号が入り、以降は 1 バイトの 7 ビットずつをつなげて 1 つの番号にする (最上位ビットが 1 なら続きがある)
    param([byte[]]$buffer, [int]$start, [int]$length)
    if ($length -lt 1) { return "" }
    $first = [int]$buffer[$start]
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add([string][math]::Min(2, [math]::Floor($first / 40)))
    $parts.Add([string]($first - (40 * [math]::Min(2, [math]::Floor($first / 40)))))
    [uint64]$value = 0
    for ($i = $start + 1; $i -lt $start + $length; $i++) {
        $value = ($value * 128) + ($buffer[$i] -band 0x7F)
        if (($buffer[$i] -band 0x80) -eq 0) {
            $parts.Add([string]$value)
            $value = 0
        }
    }
    return ($parts -join ".")
}

function ConvertFrom-BerValue {
    # 変数の中身を、画面に出せる文字に直す
    param([byte[]]$buffer, [hashtable]$element)
    $start = $element.ValueStart
    $length = $element.Length
    # 中身が空の値 (noSuchObject など) はよく届く正常なデータ。読み飛ばす
    if ($length -le 0) { return "" }
    switch ($element.Tag) {
        0x02 {
            # INTEGER (符号付き整数)
            if ($length -eq 0) { return "0" }
            [long]$number = if ($buffer[$start] -ge 0x80) { -1 } else { 0 }
            for ($i = 0; $i -lt [math]::Min($length, 8); $i++) { $number = ($number * 256) + $buffer[$start + $i] }
            return [string]$number
        }
        0x04 {
            # OCTET STRING: 文字として読めれば文字で、読めなければ 16 進で表す
            $isText = $true
            for ($i = $start; $i -lt $start + $length; $i++) {
                $b = $buffer[$i]
                if ($b -lt 0x20 -and $b -ne 0x09 -and $b -ne 0x0A -and $b -ne 0x0D) { $isText = $false; break }
            }
            if ($isText) { return [System.Text.Encoding]::UTF8.GetString($buffer, $start, $length) }
            return ([System.BitConverter]::ToString($buffer, $start, $length) -replace '-', ':')
        }
        0x05 { return "" }
        0x06 { return (ConvertFrom-BerOid $buffer $start $length) }
        0x40 {
            # IpAddress
            if ($length -eq 4) { return "$($buffer[$start]).$($buffer[$start + 1]).$($buffer[$start + 2]).$($buffer[$start + 3])" }
            return ""
        }
        { $_ -in @(0x41, 0x42, 0x43, 0x46) } {
            # Counter32 / Gauge32 / TimeTicks / Counter64 (符号なし整数)
            # 大きな値は先頭に 0 が付いて 9 バイトになるので、先頭の 0 を飛ばしてから読む
            [uint64]$number = 0
            $first = $start
            while ($first -lt ($start + $length - 1) -and $buffer[$first] -eq 0) { $first++ }
            $lastExclusive = [math]::Min($start + $length, $first + 8)
            for ($i = $first; $i -lt $lastExclusive; $i++) { $number = ($number * 256) + $buffer[$i] }
            return [string]$number
        }
        default { return ([System.BitConverter]::ToString($buffer, $start, $length) -replace '-', ':') }
    }
}

function ConvertFrom-SnmpTrapPacket {
    <#
    .SYNOPSIS
        受信した UDP データを SNMP Trap (v1 / v2c Trap / v2c Inform) として解析します。
        SNMPv3 は暗号化されていて読めないため Version = "v3" だけを返します。形式が不正なときは例外を投げます。
    .OUTPUTS
        Version / Pdu ("Trap" または "Inform") / PduTagOffset / TrapOid / Enterprise / AgentAddress / UptimeTicks / VarBinds を持つハッシュテーブル。
        Server.ps1 は PduTagOffset の位置の 1 バイトを書き換えて、Inform への返事を作ります。
    .NOTES
        コミュニティ名の確認はしていません。どの機器からの通知でも読み解きます。
    #>
    param([Parameter(Mandatory = $true)][byte[]]$Packet)

    $message = Read-BerElement $Packet 0 $Packet.Length
    if ($message.Tag -ne 0x30) { throw "SNMP のデータではありません" }
    $limit = $message.End

    $versionEl = Read-BerElement $Packet $message.ValueStart $limit
    if ($versionEl.Tag -ne 0x02) { throw "SNMP のバージョンを読み取れません" }
    $versionCode = [int](ConvertFrom-BerValue $Packet $versionEl)
    if ($versionCode -eq 3) { return @{ Version = "v3"; Pdu = "Trap"; VarBinds = @() } }
    if ($versionCode -ne 0 -and $versionCode -ne 1) { throw "未対応の SNMP バージョンです: $versionCode" }

    $communityEl = Read-BerElement $Packet $versionEl.End $limit
    if ($communityEl.Tag -ne 0x04) { throw "コミュニティ名を読み取れません" }
    $pduEl = Read-BerElement $Packet $communityEl.End $limit

    $result = @{
        Version     = if ($versionCode -eq 0) { "v1" } else { "v2c" }
        Pdu         = "Trap"
        PduTagOffset = $communityEl.End
        TrapOid     = ""
        TrapName    = ""
        Enterprise  = ""
        AgentAddress = ""
        UptimeTicks = ""
        VarBinds    = @()
    }

    $pos = $pduEl.ValueStart
    if ($pduEl.Tag -eq 0xA4) {
        # SNMPv1 Trap: 送信元の種類・アドレス・Trap 番号が決まった順で並ぶ
        if ($versionCode -ne 0) { throw "バージョンと Trap の形式が一致しません" }
        $enterpriseEl = Read-BerElement $Packet $pos $pduEl.End
        $result.Enterprise = ConvertFrom-BerValue $Packet $enterpriseEl
        $agentEl = Read-BerElement $Packet $enterpriseEl.End $pduEl.End
        $result.AgentAddress = ConvertFrom-BerValue $Packet $agentEl
        $genericEl = Read-BerElement $Packet $agentEl.End $pduEl.End
        $generic = [int](ConvertFrom-BerValue $Packet $genericEl)
        $specificEl = Read-BerElement $Packet $genericEl.End $pduEl.End
        $specific = [int](ConvertFrom-BerValue $Packet $specificEl)
        $timeEl = Read-BerElement $Packet $specificEl.End $pduEl.End
        $result.UptimeTicks = ConvertFrom-BerValue $Packet $timeEl
        # v2c と同じ形の番号にそろえる (RFC 3584 の対応表)
        $result.TrapOid = if ($generic -ge 0 -and $generic -le 5) { "1.3.6.1.6.3.1.1.5.$($generic + 1)" } else { "$($result.Enterprise).0.$specific" }
        $pos = $timeEl.End
    }
    elseif ($pduEl.Tag -eq 0xA7 -or $pduEl.Tag -eq 0xA6) {
        # SNMPv2c Trap / Inform: 番号類は変数の一覧の中に入っている
        if ($versionCode -ne 1) { throw "バージョンと Trap の形式が一致しません" }
        if ($pduEl.Tag -eq 0xA6) { $result.Pdu = "Inform" }
        $requestIdEl = Read-BerElement $Packet $pos $pduEl.End
        $errorEl = Read-BerElement $Packet $requestIdEl.End $pduEl.End
        $errorIndexEl = Read-BerElement $Packet $errorEl.End $pduEl.End
        $pos = $errorIndexEl.End
    }
    else {
        throw ("Trap ではない SNMP データです (種類: 0x{0:X2})" -f $pduEl.Tag)
    }

    # 変数の一覧 (上限 50 個。悪意あるデータで処理が重くならないようにする)
    $listEl = Read-BerElement $Packet $pos $pduEl.End
    if ($listEl.Tag -ne 0x30) { throw "変数の一覧を読み取れません" }
    $binds = [System.Collections.Generic.List[hashtable]]::new()
    $pos = $listEl.ValueStart
    while ($pos -lt $listEl.End -and $binds.Count -lt 50) {
        $bindEl = Read-BerElement $Packet $pos $listEl.End
        if ($bindEl.Tag -ne 0x30) { throw "変数の形式が不正です" }
        $oidEl = Read-BerElement $Packet $bindEl.ValueStart $bindEl.End
        $valueEl = Read-BerElement $Packet $oidEl.End $bindEl.End
        $oid = ConvertFrom-BerValue $Packet $oidEl
        $value = ConvertFrom-BerValue $Packet $valueEl
        if ($oid -eq "1.3.6.1.2.1.1.3.0") { $result.UptimeTicks = $value }
        elseif ($oid -eq "1.3.6.1.6.3.1.1.4.1.0") { $result.TrapOid = $value }
        else { $binds.Add(@{ Oid = $oid; Value = $value }) }
        $pos = $bindEl.End
    }
    $result.VarBinds = $binds.ToArray()
    return $result
}

function Get-SnmpTrapDisplay {
    <#
    .SYNOPSIS
        解析済みの Trap を、画面に出す重要度と説明文に直します。
    .OUTPUTS
        Severity と Message を持つハッシュテーブル。知らない番号は「機器固有の通知」(Notice) にします。
    .NOTES
        画面の負担を抑えるため、Message は 2,000 文字で切ります。外部から届く文字を含むので、画面では escapeHTML を通してください。
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Trap)

    $known = @{
        "1.3.6.1.6.3.1.1.5.1" = @{ Name = "coldStart"; Text = "機器が起動しました（電源投入など）"; Severity = "Notice" }
        "1.3.6.1.6.3.1.1.5.2" = @{ Name = "warmStart"; Text = "機器が再起動しました"; Severity = "Notice" }
        "1.3.6.1.6.3.1.1.5.3" = @{ Name = "linkDown"; Text = "ポートの接続が切れました"; Severity = "Warning" }
        "1.3.6.1.6.3.1.1.5.4" = @{ Name = "linkUp"; Text = "ポートの接続が回復しました"; Severity = "Informational" }
        "1.3.6.1.6.3.1.1.5.5" = @{ Name = "authenticationFailure"; Text = "SNMP の認証に失敗しました（コミュニティ名の誤りなど）"; Severity = "Warning" }
        "1.3.6.1.6.3.1.1.5.6" = @{ Name = "egpNeighborLoss"; Text = "隣接するルーターとの接続が失われました"; Severity = "Warning" }
    }
    $info = if ($known.ContainsKey([string]$Trap.TrapOid)) { $known[[string]$Trap.TrapOid] } else { @{ Name = [string]$Trap.TrapOid; Text = "機器固有の通知"; Severity = "Notice" } }

    $bindText = @($Trap.VarBinds | ForEach-Object { "$($_.Oid)=$($_.Value)" }) -join ", "
    $message = "[SNMP Trap $($Trap.Version)] $($info.Name): $($info.Text)"
    if ($bindText) { $message += " | $bindText" }
    if ($message.Length -gt 2000) { $message = $message.Substring(0, 2000) + "...(省略)" }
    return @{ Severity = $info.Severity; Message = $message }
}

Export-ModuleMember -Function Initialize-SnmpLibrary, Check-WebAndSslEndpoint, Invoke-SnmpGetUnified, Invoke-SnmpWalkUnified, ConvertFrom-SnmpTrapPacket, Get-SnmpTrapDisplay
