# ==============================================================================
# Common.psm1 - 共通ユーティリティ・セキュリティ・ログモジュール
# ==============================================================================
# 【初心者向けの簡単な解説】
# 他のファイルから共通で使う部品を集めたファイルです。主な内容は次のとおりです。
#   1. パスワードの暗号化と復号        2. 操作履歴とログの記録
#   3. HTTP の応答とセキュリティの判定  4. 機器一覧の保存
#   5. 設定のスナップショット (自動の控え) と復元
#   6. 必要なモジュールの確認とインストール  7. バックグラウンド処理の土台 (Runspace) の作成
#
# 【変更するときの注意】
# - 関数を追加したら、ファイル末尾の Export-ModuleMember にも追加してください。
#   追加しないと、他のファイルから呼び出せません。
# - Runspace (別スレッド) の中ではこのモジュールの関数が見えないことがあります。
#   各スクリプトブロックで Import-Module するか、New-AppRunspace で読み込んでください。
# - テストは tests/Monitor.Tests.ps1、tests/RemoteExec.Tests.ps1、tests/Tools.Tests.ps1 にあります。
# ==============================================================================

Add-Type -AssemblyName System.Security

# ── 1. 秘密情報暗号化・復号 (Windows DPAPI) ───────────────────────────────────

function Protect-SecretString {
    <#
    .SYNOPSIS
        平文文字列を現在のWindowsユーザーの資格情報を用いてDPAPIで暗号化します。
    .DESCRIPTION
        【初心者向けの簡単な解説】
        DPAPI は Windows の暗号化の機能で、鍵の管理を Windows に任せられます。
        暗号化したユーザー本人しか復号できないので、devices.json を別のPCや別のユーザーへコピーすると読めなくなります。
    .OUTPUTS
        "enc:" で始まる暗号文。入力が空なら空文字。すでに "enc:" で始まる値はそのまま返すので、二重には暗号化しません。
    .NOTES
        【注意】暗号化に失敗すると、警告を出して入力をそのまま (平文のまま) 返します。
        呼び出し側は、結果が "enc:" で始まるとは限らないことに注意してください。
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
    .OUTPUTS
        復号した文字列。復号できないとき (別のユーザーが暗号化した値など) は、警告を出して空文字を返します。
        例外にしないので、呼び出し側は空文字かどうかで失敗を判断してください。
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
    <#
    .SYNOPSIS
        設定の変更やリモート操作などを、操作履歴 (reportsDirectory の audit.log) に 1 行追記します。
    .DESCRIPTION
        複数のスレッドやプログラムが同時に書いても行が混ざらないよう、名前付きミューテックス
        (プログラムをまたいで使える順番待ちの札) で順番に書き込みます。5MB を超えると audit_1.log に切り替えます。
    .NOTES
        記録の失敗で本来の操作を止めないよう、失敗しても例外にしません。パスワードを details に入れないでください。
        順番待ちが 3 秒を超えても書き込みは続けます (記録を落とさないことを優先しています)。
    #>
    param(
        [string]$action,
        [string]$target,
        [string]$details,
        [string]$clientIp = "127.0.0.1",
        [string]$reportsDirectory
    )
    try {
        if (-not $reportsDirectory) { return }
        if (-not (Test-Path $reportsDirectory)) { New-Item -ItemType Directory -Path $reportsDirectory -Force | Out-Null }
        $auditFile = Join-Path $reportsDirectory "audit.log"
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        # 改行を含む値 (複数行のカスタムコマンド等) で1件の記録が複数行に分かれ、
        # 別の記録に見えてしまう (なりすまし行を書き込める) のを防ぐため、各項目の改行を置き換える
        $oneLine = { param($v) ([string]$v) -replace "`r`n|`r|`n", " | " }
        $logLine = "[$ts] [$(& $oneLine $clientIp)] [Action: $(& $oneLine $action)] [Target: $(& $oneLine $target)] $(& $oneLine $details)`r`n"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($logLine)

        $mutex = $null
        $hasMutex = $false
        try {
            $mutex = New-Object System.Threading.Mutex($false, "Local\NDM_AuditLog_Mutex")
            try {
                $hasMutex = $mutex.WaitOne(3000)
            } catch [System.Threading.AbandonedMutexException] {
                $hasMutex = $true
            }

            for ($attempt = 0; $attempt -lt 15; $attempt++) {
                try {
                    if (Test-Path $auditFile) {
                        $aInfo = Get-Item $auditFile -ErrorAction SilentlyContinue
                        if ($aInfo -and $aInfo.Length -gt 5MB) {
                            $rotAudit = Join-Path $reportsDirectory "audit_1.log"
                            Move-Item -Path $auditFile -Destination $rotAudit -Force -ErrorAction SilentlyContinue
                        }
                    }
                    $fs = [System.IO.File]::Open($auditFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
                    try {
                        $fs.Write($bytes, 0, $bytes.Length)
                        $fs.Flush()
                        break
                    } finally {
                        $fs.Dispose()
                    }
                } catch [System.IO.IOException] {
                    Start-Sleep -Milliseconds (Get-Random -Minimum 10 -Maximum 30)
                } catch {
                    break
                }
            }
        } finally {
            if ($hasMutex -and $mutex) {
                try { $mutex.ReleaseMutex() } catch {}
            }
            if ($mutex) {
                $mutex.Dispose()
            }
        }
    } catch {}
}

function Write-ServerLog {
    <#
    .SYNOPSIS
        メッセージを画面に色付きで表示し、baseDir を指定したときは debug.log にも追記します。
    .PARAMETER level
        INFO / WARN / ERROR / SUCCESS。表示の色だけが変わります。
    .NOTES
        debug.log は 5MB を超えると debug_1.log に切り替えます。書き込みの失敗は無視します。
    #>
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
            if (Test-Path $logPath) {
                $dInfo = Get-Item $logPath -ErrorAction SilentlyContinue
                if ($dInfo -and $dInfo.Length -gt 5MB) {
                    $rotDebug = Join-Path $baseDir "debug_1.log"
                    Move-Item -Path $logPath -Destination $rotDebug -Force -ErrorAction SilentlyContinue
                }
            }
            [System.IO.File]::AppendAllText($logPath, "$line`r`n", [System.Text.Encoding]::UTF8)
        } catch {}
    }
}

# ── 3. HTTP / JSON レスポンス ───────────────────────────────────────────────

function Write-JsonResponse {
    <#
    .SYNOPSIS
        データを JSON にして HTTP の応答として送り、接続を閉じます。
    .NOTES
        相手が先に切断していても処理を止めないよう、失敗は例外にしません。
        この関数のあとは同じ応答に書き込めないので、呼び出し側はすぐに処理を終えてください。
    #>
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

function Test-ApiRequestAllowed {
    <#
    .SYNOPSIS
        /api/* へのリクエストが「この監視画面自身」から来たものかを判定します（CSRF 対策）。
    .DESCRIPTION
        【初心者向けの簡単な解説】
        監視サーバーは自分のPC（localhost）からしか接続を受け付けませんが、同じPCのブラウザで
        開いた「別のWebサイト」が裏でこっそりAPIを呼ぶことはできてしまいます。
        ブラウザはリクエストに「どのサイトから来たか」（Origin / Sec-Fetch-Site ヘッダー）を
        自動で付けるので、それが監視画面以外なら拒否します。
        PowerShell やテストツールなどブラウザ以外からの呼び出しはこれらのヘッダーを付けないため、
        従来どおり利用できます。
    #>
    param(
        [string]$Origin,
        [string]$SecFetchSite,
        [int]$Port
    )

    # same-site は「同じPCの別ポートのサイト」も含むため、same-origin / none 以外は拒否
    if (-not [string]::IsNullOrWhiteSpace($SecFetchSite)) {
        $site = $SecFetchSite.Trim().ToLower()
        if ($site -ne "same-origin" -and $site -ne "none") { return $false }
    }

    if (-not [string]::IsNullOrWhiteSpace($Origin)) {
        $allowed = @("http://localhost:$Port", "http://127.0.0.1:$Port", "http://[::1]:$Port")
        $normalized = $Origin.Trim().TrimEnd('/')
        foreach ($a in $allowed) {
            if ([string]::Equals($normalized, $a, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        return $false
    }

    return $true
}

function Test-ClientAddressAllowed {
    <#
    .SYNOPSIS
        接続してきた相手が「このPC自身」かどうかを、接続元の IP アドレスで判定します。
    .DESCRIPTION
        【初心者向けの簡単な解説】
        待ち受け先を http://localhost にしていても、Windows は「宛先名が localhost」と書かれた通信を
        ネットワーク側からも受け取ってしまいます。宛先名は送る側が自由に書けるので、当てになりません。
        そこで偽れない接続元のアドレスを見て、このPC自身 (127.0.0.1 や ::1) からの接続だけを許可します。
    #>
    param([System.Net.IPAddress]$Address)

    if ($null -eq $Address) { return $false }
    # ::ffff:127.0.0.1 は IPv6 の形で書いた 127.0.0.1 なので、IPv4 に直してから判定する
    if ($Address.IsIPv4MappedToIPv6) { $Address = $Address.MapToIPv4() }
    return [System.Net.IPAddress]::IsLoopback($Address)
}

function Test-LogSourceAllowed {
    <#
    .SYNOPSIS
        Syslog / SNMP Trap の送信元が、登録済みの機器かどうかを判定します。
    .DESCRIPTION
        【初心者向けの簡単な解説】
        Syslog と Trap は同じネットワークの誰からでも届きます。そのままでは、無関係な機器のログや
        偽の警報が一覧に混ざるので、機器一覧に登録されたアドレスから届いたものだけを受け付けます。
    .PARAMETER SourceIp
        受信したデータの送信元アドレス。
    .PARAMETER Devices
        登録済みの機器のアドレスの一覧 ($syncHash.Devices)。
    .OUTPUTS
        登録済みなら $true、それ以外は $false。
    .NOTES
        UDP の送信元は偽装できるので、悪意のある相手を完全に防ぐものではありません。
        機器の管理用とは別のアドレスから送る機器は、そのアドレスも登録しないと受け付けません。
    #>
    param([string]$SourceIp, [string[]]$Devices)

    if ([string]::IsNullOrWhiteSpace($SourceIp) -or $null -eq $Devices) { return $false }
    # ::ffff:192.168.1.1 は IPv6 の形で書いた 192.168.1.1 なので、IPv4 の形にそろえて比べる
    $normalized = $SourceIp -replace '^::ffff:', ''
    return ($Devices -contains $normalized)
}

function ConvertTo-SafeIperfOptions {
    <#
    .SYNOPSIS
        画面で入力された iperf3 の追加オプションから、危険な記号と、PC 内のファイルを扱うオプションを取り除きます。
    .DESCRIPTION
        【初心者向けの簡単な解説】
        iperf3 には、ファイルの中身を相手へ送る (-F / --file) ものや、ファイルに書き込むもの
        (-I / --pidfile, --logfile) があります。計測には不要で、悪用すると情報が漏れるので使わせません。
        入力: 画面で入力された文字列。結果: 安全なオプションだけの文字列 (何も残らなければ空文字)。
    .NOTES
        【なぜ語ごとに判定するのか】
        iperf3 は -RF のように短いオプションをまとめて書けて、--log のように長い名前を省略して書くこともできます。
        決まった文字列を探すだけではこれらを見逃すので、空白で区切った語ごとに判定しています。
        【変更するときの注意】
        - -F と -I の大文字と小文字は別のオプションです (-f は単位、-i は間隔)。比較は大文字と小文字を区別してください。
        - 長い名前は 2 文字以上の省略で判定します。--l や --f だけでは他のオプションと区別できず、iperf3 も受け付けません。
        - 取り除いたオプションの値も、続く語が「-」で始まらなければ一緒に取り除きます。
    #>
    param([string]$Options)

    $blockedLongNames = @("file", "logfile", "pidfile")
    # 英数字・空白・ハイフン以外を消すので、「;」「&」などでの別コマンドの実行や「.」「\」でのパス指定はできない
    $words = @(($Options -replace '[^a-zA-Z0-9\s\-]', '') -split '\s+' | Where-Object { $_ })
    $kept = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $words.Count; $index++) {
        $word = $words[$index]
        $isBlocked = $false
        if ($word.StartsWith("--")) {
            $longName = $word.Substring(2)
            if ($longName.Length -ge 2) {
                foreach ($blocked in $blockedLongNames) {
                    if ($blocked.StartsWith($longName, [System.StringComparison]::Ordinal)) { $isBlocked = $true }
                }
            }
        }
        elseif ($word.StartsWith("-")) {
            # -cmatch は大文字と小文字を区別する
            $isBlocked = $word -cmatch '[FI]'
        }

        if ($isBlocked) {
            if (($index + 1) -lt $words.Count -and -not $words[$index + 1].StartsWith("-")) { $index++ }
            continue
        }
        $kept.Add($word)
    }
    return ($kept -join " ")
}

function Get-MimeType {
    # 拡張子 (".html" など) から、ブラウザへ伝えるファイルの種類を返す。知らない拡張子はダウンロード扱いにする
    # 応答に nosniff を付けているので、.js や .css の種類が違うとブラウザが読み込みを拒否する
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
    <#
    .SYNOPSIS
        同期Hashtableの最新デバイス設定を devices.json へ安全に保存します（排他ロック・バックアップ・アトミック書き込み対応）。
    .DESCRIPTION
        一時ファイルへ書いてから置き換えるので、書き込みの途中で止まっても devices.json が壊れません。
        置き換える前に、今のファイルをスナップショットとして控えます。パスワードは暗号化して保存します。
    .OUTPUTS
        保存できたら $true、できなければ $false。
    .NOTES
        【注意】実際の監視中は、Server.ps1 の中にある同じ名前の関数 (-Routine 付き) が使われます。
        こちらは主にテストから呼ばれており、OBR の設定 (obrEnabled / obrPassword) を保存しません。
        保存する項目を増やすときは、Server.ps1 の関数を必ず直してください。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [Alias("Sync")]
        [object]$syncHash = $null,

        [Parameter(Mandatory = $false, Position = 1)]
        [Alias("Path")]
        [object]$filePath = ""
    )

    # 引数の順序・型への柔軟対応 (Save-DevicesJson $syncHash または Save-DevicesJson $filePath または 順序逆)
    if ($syncHash -is [string] -and ($filePath -is [hashtable] -or $null -eq $filePath -or [string]::IsNullOrWhiteSpace($filePath))) {
        if ($filePath -is [hashtable]) {
            $temp = $syncHash
            $syncHash = $filePath
            $filePath = $temp
        } else {
            $filePath = [string]$syncHash
            $syncHash = $null
        }
    }

    # 引数未指定時のフォールバック ($global:syncHash, $script:syncHash, 呼び出し元スコープ)
    if ($null -eq $syncHash) {
        if (Get-Variable -Name "syncHash" -Scope Global -ErrorAction SilentlyContinue) {
            $syncHash = (Get-Variable -Name "syncHash" -Scope Global).Value
        } elseif (Get-Variable -Name "syncHash" -Scope Script -ErrorAction SilentlyContinue) {
            $syncHash = (Get-Variable -Name "syncHash" -Scope Script).Value
        } elseif (Get-Variable -Name "syncHash" -Scope 1 -ErrorAction SilentlyContinue) {
            $syncHash = (Get-Variable -Name "syncHash" -Scope 1).Value
        }
    }

    if ($null -eq $syncHash) {
        Write-Warning "Save-DevicesJson: syncHash is null."
        return $false
    }

    $filePath = [string]$filePath
    if ([string]::IsNullOrWhiteSpace($filePath)) {
        if ($syncHash.PSScriptRoot) {
            $filePath = Join-Path $syncHash.PSScriptRoot "devices.json"
        } elseif ($PSScriptRoot) {
            $filePath = Join-Path (Split-Path -Parent $PSScriptRoot) "devices.json"
        } else {
            $filePath = "devices.json"
        }
    }

    $lockObj = if ($syncHash -and $syncHash.DevicesLock) { $syncHash.DevicesLock } else { $null }
    $hasLock = $false
    if ($null -ne $lockObj) {
        [System.Threading.Monitor]::Enter($lockObj)
        $hasLock = $true
    }

    try {
        $outArray = @()
        $devList = if ($syncHash -and $syncHash.Devices) { $syncHash.Devices } else { @() }
        foreach ($ip in $devList) {
            # SNMPパスワードは保存時に自動暗号化 (二重暗号化を防止)
            $rawAuthPass = if ($syncHash.SnmpAuthPass -and $syncHash.SnmpAuthPass.ContainsKey($ip)) { $syncHash.SnmpAuthPass[$ip] } else { "" }
            $rawPrivPass = if ($syncHash.SnmpPrivPass -and $syncHash.SnmpPrivPass.ContainsKey($ip)) { $syncHash.SnmpPrivPass[$ip] } else { "" }
            $encAuthPass = if ($rawAuthPass) {
                if ($rawAuthPass.StartsWith("enc:")) { $rawAuthPass } else { Protect-SecretString $rawAuthPass }
            } else { "" }
            $encPrivPass = if ($rawPrivPass) {
                if ($rawPrivPass.StartsWith("enc:")) { $rawPrivPass } else { Protect-SecretString $rawPrivPass }
            } else { "" }

            # 実行時キー（Image, IsMonitored, X, Y）の統一とフォールバック
            $img = if ($syncHash.Image -and $syncHash.Image.ContainsKey($ip)) { $syncHash.Image[$ip] }
                   elseif ($syncHash.DeviceImage -and $syncHash.DeviceImage.ContainsKey($ip)) { $syncHash.DeviceImage[$ip] }
                   else { "" }

            $monitored = if ($syncHash.IsMonitored -and $syncHash.IsMonitored.ContainsKey($ip)) { [bool]$syncHash.IsMonitored[$ip] }
                         elseif ($syncHash.Enabled -and $syncHash.Enabled.ContainsKey($ip)) { [bool]$syncHash.Enabled[$ip] }
                         else { $true }

            $posX = if ($syncHash.X -and $syncHash.X.ContainsKey($ip)) { $syncHash.X[$ip] }
                    elseif ($syncHash.TopoX -and $syncHash.TopoX.ContainsKey($ip)) { $syncHash.TopoX[$ip] }
                    else { $null }

            $posY = if ($syncHash.Y -and $syncHash.Y.ContainsKey($ip)) { $syncHash.Y[$ip] }
                    elseif ($syncHash.TopoY -and $syncHash.TopoY.ContainsKey($ip)) { $syncHash.TopoY[$ip] }
                    else { $null }

            $d = @{
                ip            = $ip
                name          = if ($syncHash.DeviceName -and $syncHash.DeviceName.ContainsKey($ip)) { $syncHash.DeviceName[$ip] } else { $ip }
                community     = if ($syncHash.Community -and $syncHash.Community.ContainsKey($ip)) { $syncHash.Community[$ip] } else { "public" }
                enabled       = $monitored
                group         = if ($syncHash.Group -and $syncHash.Group.ContainsKey($ip)) { $syncHash.Group[$ip] } else { "" }
                image         = $img
                connectedTo   = if ($syncHash.ConnectedTo -and $syncHash.ConnectedTo.ContainsKey($ip)) { $syncHash.ConnectedTo[$ip] } else { "" }
                x             = $posX
                y             = $posY
                mac           = if ($syncHash.Mac -and $syncHash.Mac.ContainsKey($ip)) { $syncHash.Mac[$ip] } else { "" }
                vendorContact = if ($syncHash.VendorContact -and $syncHash.VendorContact.ContainsKey($ip)) { $syncHash.VendorContact[$ip] } else { "" }
                deviceType    = if ($syncHash.DeviceType -and $syncHash.DeviceType.ContainsKey($ip)) { $syncHash.DeviceType[$ip] } else { "network" }
                webUrl        = if ($syncHash.WebUrl -and $syncHash.WebUrl.ContainsKey($ip)) { $syncHash.WebUrl[$ip] } else { "" }
                checkType     = if ($syncHash.CheckType -and $syncHash.CheckType.ContainsKey($ip)) { $syncHash.CheckType[$ip] } else { "icmp" }
                port          = if ($syncHash.Port -and $syncHash.Port.ContainsKey($ip)) { $syncHash.Port[$ip] } else { 0 }
                snmpVersion   = if ($syncHash.SnmpVersion -and $syncHash.SnmpVersion.ContainsKey($ip)) { $syncHash.SnmpVersion[$ip] } else { "v2c" }
                snmpUser      = if ($syncHash.SnmpUser -and $syncHash.SnmpUser.ContainsKey($ip)) { $syncHash.SnmpUser[$ip] } else { "" }
                snmpAuthProto = if ($syncHash.SnmpAuthProto -and $syncHash.SnmpAuthProto.ContainsKey($ip)) { $syncHash.SnmpAuthProto[$ip] } else { "none" }
                snmpAuthPass  = $encAuthPass
                snmpPrivProto = if ($syncHash.SnmpPrivProto -and $syncHash.SnmpPrivProto.ContainsKey($ip)) { $syncHash.SnmpPrivProto[$ip] } else { "none" }
                snmpPrivPass  = $encPrivPass
            }

            # リモート管理設定の保存処理 (パスワードはDPAPIで自動暗号化)
            $rawRemote = if ($syncHash.Remote -and $syncHash.Remote.ContainsKey($ip)) { $syncHash.Remote[$ip] } else { $null }
            if ($null -ne $rawRemote) {
                $rPass = if ($rawRemote -is [hashtable]) {
                    if ($rawRemote.ContainsKey('password')) { [string]$rawRemote['password'] } else { "" }
                } else {
                    if ($rawRemote.password) { [string]$rawRemote.password } else { "" }
                }
                $encRemotePass = if ($rPass) {
                    if ($rPass.StartsWith("enc:")) { $rPass } else { Protect-SecretString $rPass }
                } else { "" }

                $rCmds = if ($rawRemote -is [hashtable]) {
                    if ($rawRemote.ContainsKey('commands')) { $rawRemote['commands'] } else { @() }
                } else {
                    if ($rawRemote.commands) { $rawRemote.commands } else { @() }
                }

                $cmdArray = @()
                if ($null -ne $rCmds) {
                    foreach ($ci in $rCmds) {
                        $cId   = if ($ci -is [hashtable]) { if ($ci.ContainsKey('id')) { [string]$ci['id'] } else { "" } } else { if ($ci.id) { [string]$ci.id } else { "" } }
                        $cName = if ($ci -is [hashtable]) { if ($ci.ContainsKey('name')) { [string]$ci['name'] } else { "" } } else { if ($ci.name) { [string]$ci.name } else { "" } }
                        $cCmd  = if ($ci -is [hashtable]) { if ($ci.ContainsKey('command')) { [string]$ci['command'] } else { "" } } else { if ($ci.command) { [string]$ci.command } else { "" } }
                        $cDesc = if ($ci -is [hashtable]) { if ($ci.ContainsKey('description')) { [string]$ci['description'] } else { "" } } else { if ($ci.description) { [string]$ci.description } else { "" } }
                        $cmdArray += @{
                            id          = $cId
                            name        = $cName
                            command     = $cCmd
                            description = $cDesc
                        }
                    }
                }

                $rEnabled = if ($rawRemote -is [hashtable]) {
                    if ($rawRemote.ContainsKey('enabled')) { [bool]$rawRemote['enabled'] } else { $false }
                } else {
                    if ($null -ne $rawRemote.enabled) { [bool]$rawRemote.enabled } else { $false }
                }
                $rProtocol = if ($rawRemote -is [hashtable]) {
                    if ($rawRemote.ContainsKey('protocol')) { [string]$rawRemote['protocol'] } else { "ssh" }
                } else {
                    if ($rawRemote.protocol) { [string]$rawRemote.protocol } else { "ssh" }
                }
                $rHost = if ($rawRemote -is [hashtable]) {
                    if ($rawRemote.ContainsKey('host')) { [string]$rawRemote['host'] } else { $ip }
                } else {
                    if ($rawRemote.host) { [string]$rawRemote.host } else { $ip }
                }
                $rPort = if ($rawRemote -is [hashtable]) {
                    if ($rawRemote.ContainsKey('port')) { [int]$rawRemote['port'] } else { 0 }
                } else {
                    if ($rawRemote.port) { [int]$rawRemote.port } else { 0 }
                }
                $rAuthType = if ($rawRemote -is [hashtable]) {
                    if ($rawRemote.ContainsKey('authType')) { [string]$rawRemote['authType'] } else { "none" }
                } else {
                    if ($rawRemote.authType) { [string]$rawRemote.authType } else { "none" }
                }
                $rUser = if ($rawRemote -is [hashtable]) {
                    if ($rawRemote.ContainsKey('user')) { [string]$rawRemote['user'] } else { "" }
                } else {
                    if ($rawRemote.user) { [string]$rawRemote.user } else { "" }
                }
                $rKeyPath = if ($rawRemote -is [hashtable]) {
                    if ($rawRemote.ContainsKey('keyPath')) { [string]$rawRemote['keyPath'] } else { "" }
                } else {
                    if ($rawRemote.keyPath) { [string]$rawRemote.keyPath } else { "" }
                }
                $rRebootCmd = if ($rawRemote -is [hashtable]) {
                    if ($rawRemote.ContainsKey('rebootCommand')) { [string]$rawRemote['rebootCommand'] } else { "" }
                } else {
                    if ($rawRemote.rebootCommand) { [string]$rawRemote.rebootCommand } else { "" }
                }

                $remoteObj = @{
                    enabled       = $rEnabled
                    protocol      = $rProtocol
                    host          = $rHost
                    port          = $rPort
                    authType      = $rAuthType
                    user          = $rUser
                    password      = $encRemotePass
                    keyPath       = $rKeyPath
                    rebootCommand = $rRebootCmd
                    commands      = $cmdArray
                }
                $d['remote'] = $remoteObj
            }

            $outArray += $d
        }

        $jsonStr = if ($outArray.Count -eq 0) { "[]" } else { ConvertTo-Json -InputObject $outArray -Depth 10 }

        for ($retry = 0; $retry -lt 5; $retry++) {
            $tmpFile = "$filePath.$([Guid]::NewGuid().ToString('N')).tmp"
            try {
                try {
                    $jsonStr | Out-File -FilePath $tmpFile -Encoding UTF8
                    if (Test-Path $filePath) {
                        $backupDir = if ($syncHash -and $syncHash.BackupDir) { $syncHash.BackupDir } else { Join-Path (Split-Path -Parent $filePath) "backups" }
                        $null = Backup-ConfigSnapshot -targetFilePath $filePath -backupDir $backupDir
                    }
                    Move-Item -Path $tmpFile -Destination $filePath -Force
                    return $true
                } finally {
                    if (Test-Path $tmpFile) {
                        try { Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue } catch {}
                    }
                }
            } catch {
                if ($syncHash -and $syncHash.PSScriptRoot) {
                    try { [System.IO.File]::AppendAllText((Join-Path $syncHash.PSScriptRoot "debug.log"), "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] Save-DevicesJson error: $($_.Exception.Message)`r`n", [System.Text.Encoding]::UTF8) } catch {}
                }
                Start-Sleep -Milliseconds 100
            }
        }
        return $false
    } finally {
        if ($hasLock) {
            [System.Threading.Monitor]::Exit($lockObj)
        }
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
        [int]$maxGenerations = 20,
        # 0より大きいと、直前のスナップショットがこの秒数以内なら新しく作らない
        # (構成図で機器をドラッグするたびに保存されるため、毎回作ると20世代がすぐに入れ替わり、
        #  一括削除などの「戻したい時点」のスナップショットが数十秒で消えていた)
        [int]$minIntervalSec = 0
    )
    if (-not (Test-Path $targetFilePath)) { return $null }
    try {
        if (-not (Test-Path $backupDir)) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        }
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($targetFilePath) # "devices" or "config"
        if ($minIntervalSec -gt 0) {
            $latest = Get-ChildItem -Path $backupDir -Filter "${baseName}_*.json" -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
            # スナップショットの作成時刻はファイル名 (yyyyMMdd_HHmmss_fff) から読む (コピー元の更新日時が引き継がれるため)
            if ($latest -and $latest.Name -match "^${baseName}_(\d{8}_\d{6})") {
                $latestTime = [datetime]::ParseExact($matches[1], "yyyyMMdd_HHmmss", $null)
                if (((Get-Date) - $latestTime).TotalSeconds -lt $minIntervalSec) { return $latest.FullName }
            }
        }
        $ts = (Get-Date).ToString("yyyyMMdd_HHmmss_fff")
        $snapshotName = "${baseName}_${ts}.json"
        $snapshotPath = Join-Path $backupDir $snapshotName
        $dupIdx = 1
        while (Test-Path $snapshotPath) {
            $snapshotName = "${baseName}_${ts}_${dupIdx}.json"
            $snapshotPath = Join-Path $backupDir $snapshotName
            $dupIdx++
        }

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
    .OUTPUTS
        新しい順の一覧 (fileName / type / createdAt / sizeBytes)。フォルダがないときや読めないときは空の配列。
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
    .OUTPUTS
        success が $true なら restoredFile と fromSnapshot を、$false なら error を持つハッシュテーブル。
    .NOTES
        ファイルを書き戻すだけです。動作中の監視へ反映する処理は呼び出し側 (Server.ps1) にあります。
    #>
    param(
        [string]$snapshotFileName,
        [string]$backupDir,
        [string]$targetDir
    )
    # ファイル名に「..\」などを含めてバックアップフォルダの外のファイルを読み込ませないよう、名前の形式を限定する
    if ([string]::IsNullOrWhiteSpace($snapshotFileName) -or
        $snapshotFileName -ne [System.IO.Path]::GetFileName($snapshotFileName) -or
        $snapshotFileName -notmatch '^(devices|config)_[A-Za-z0-9_.\-]+\.json$' -or
        $snapshotFileName.Contains('..')) {
        return @{ success = $false; error = "Invalid snapshot file name: $snapshotFileName" }
    }
    $sourcePath = Join-Path $backupDir $snapshotFileName
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        return @{ success = $false; error = "Snapshot file not found: $snapshotFileName" }
    }

    $targetFileName = if ($snapshotFileName.StartsWith("devices_")) { "devices.json" } elseif ($snapshotFileName.StartsWith("config_")) { "config.json" } else { $null }
    if (-not $targetFileName) {
        return @{ success = $false; error = "Unknown snapshot type" }
    }

    $destPath = Join-Path $targetDir $targetFileName
    try {
        # 同一ミリ秒でのバックアップ上書き競合を防ぐため、復元元のバイト列を先にメモリへ確保
        $sourceBytes = [System.IO.File]::ReadAllBytes($sourcePath)
        # 壊れたスナップショットで現在の設定を上書きしないよう、JSON として読めることを先に確認する
        try {
            $null = ([System.Text.Encoding]::UTF8.GetString($sourceBytes).TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop)
        }
        catch {
            return @{ success = $false; error = "Snapshot file is not valid JSON: $snapshotFileName" }
        }
        # 復元前に現行ファイルを安全スナップショット退避
        if (Test-Path $destPath) {
            $null = Backup-ConfigSnapshot -targetFilePath $destPath -backupDir $backupDir
        }
        [System.IO.File]::WriteAllBytes($destPath, $sourceBytes)
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
    .DESCRIPTION
        起動時と画面の診断から呼ばれるので、時間のかかる Get-Module はできるだけ避け、
        先にフォルダを直接調べています。Get-Module は最後の手段です。
    .OUTPUTS
        allReady (必須のものがそろっているか) と各項目の結果を持つハッシュテーブル。
        allReady は PowerShell のバージョン、SNMP モジュール、iperf3 で判定します。実行ポリシーや Pester は含みません。
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

    # 3. NuGet パッケージプロバイダー (高速ファイルシステム判定優先)
    $hasNuGet = $false
    foreach ($nuGetDir in @(
        (Join-Path $env:ProgramFiles "PackageManagement\ProviderAssemblies\nuget"),
        (Join-Path $env:LOCALAPPDATA "PackageManagement\ProviderAssemblies\nuget")
    )) {
        if ($nuGetDir -and [System.IO.Directory]::Exists($nuGetDir)) {
            $hasNuGet = $true
            break
        }
    }

    # 高速モジュール探索ヘルパー ($env:PSModulePath のディレクトリ直接検査 + フォールバック)
    $findModuleFast = {
        param([string]$modName)
        $modPaths = ($env:PSModulePath -split ';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        foreach ($mp in $modPaths) {
            $modRoot = Join-Path $mp $modName
            if ([System.IO.Directory]::Exists($modRoot)) {
                # 1. バージョンサブフォルダ (例: SNMP\1.0.0.1\SNMP.psd1) の高速チェック
                try {
                    $subDirs = [System.IO.Directory]::GetDirectories($modRoot)
                    if ($subDirs -and $subDirs.Length -gt 0) {
                        for ($i = $subDirs.Length - 1; $i -ge 0; $i--) {
                            $sd = $subDirs[$i]
                            $verCandidate = [System.IO.Path]::GetFileName($sd)
                            $psd1 = Join-Path $sd "$modName.psd1"
                            $psm1 = Join-Path $sd "$modName.psm1"
                            if ([System.IO.File]::Exists($psd1)) {
                                return @{ installed = $true; version = $verCandidate; path = $psd1 }
                            } elseif ([System.IO.File]::Exists($psm1)) {
                                return @{ installed = $true; version = $verCandidate; path = $psm1 }
                            }
                        }
                    }
                    # 2. 直下に .psd1 / .psm1 がある場合
                    $directPsd1 = Join-Path $modRoot "$modName.psd1"
                    if ([System.IO.File]::Exists($directPsd1)) {
                        $ver = "1.0"
                        try {
                            $txt = [System.IO.File]::ReadAllText($directPsd1)
                            if ($txt -match "ModuleVersion\s*=\s*['`"]([^'`"]+)['`"]") { $ver = $matches[1] }
                        } catch {}
                        return @{ installed = $true; version = $ver; path = $directPsd1 }
                    }
                } catch {}
            }
        }
        $m = try { Get-Module -ListAvailable -Name $modName -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { $null }
        if ($null -ne $m) {
            return @{ installed = $true; version = $m.Version.ToString(); path = $m.Path }
        }
        return @{ installed = $false; version = ""; path = "" }
    }

    # 4. SNMP モジュール (トラフィック監視・機器詳細・トポロジー探索に必須)
    $snmpRes = & $findModuleFast "SNMP"
    $hasSnmp = [bool]$snmpRes.installed
    $snmpVersion = [string]$snmpRes.version
    $snmpPath = [string]$snmpRes.path

    # 5. Pester モジュール (自動テストフレームワーク)
    $pesterRes = & $findModuleFast "Pester"
    $hasPester = [bool]$pesterRes.installed
    $pesterVersion = [string]$pesterRes.version

    # 6. Iperf3 実行バイナリ (帯域計測ツール)
    $candidatePaths = @(
        (Join-Path $projectRoot "system\iperf3.18_64\iperf3.exe"),
        (Join-Path $projectRoot "tools\iperf3.exe")
    )
    $iperfPath = ""
    $hasIperf = $false
    foreach ($cand in $candidatePaths) {
        if (Test-Path $cand) {
            $hasIperf = $true
            $iperfPath = $cand
            break
        }
    }
    if (-not $hasIperf) {
        $cmdIperf = Get-Command "iperf3.exe" -ErrorAction SilentlyContinue
        if ($cmdIperf) {
            $hasIperf = $true
            $iperfPath = $cmdIperf.Source
        }
    }

    # 7. ポートの競合状態 (config.json から設定ポートを取得、デフォルト 8081)
    $port = 8081
    $configPath = Join-Path $projectRoot "system\config.json"
    if (Test-Path $configPath) {
        try {
            $cfg = Get-Content -Raw $configPath | ConvertFrom-Json
            if ($cfg.port) { $port = [int]$cfg.port }
        } catch {}
    }
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
    .OUTPUTS
        success が $true なら message を、$false なら error を持つハッシュテーブル。
    .NOTES
        インターネットから取得して、現在のユーザーにインストールします。許可するモジュールは下の一覧で限定しています。
        一覧を増やすと、API から指定できるモジュールも増えるので、必要なものだけを追加してください。
    #>
    param([string]$moduleName = "SNMP")
    # インストールすると中のプログラムが動かせるようになるので、このアプリで必要なものだけを許可する
    if ($moduleName -notin @("SNMP")) {
        return @{ success = $false; error = "Module '$moduleName' is not allowed." }
    }
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

# ── 7. バックグラウンド Runspace 生成ファクトリ ─────────────────────────────

function New-AppRunspace {
    <#
    .SYNOPSIS
        モジュール定義と共通変数がセットアップされたバックグラウンド Runspace を生成します。
    .DESCRIPTION
        【初心者向けの簡単な解説】
        Runspace は、PowerShell の処理を別スレッドで動かすための入れ物です。
        入れ物の中からは外の関数や変数が見えないので、最初に必要なものを渡しておきます。
    .PARAMETER ModulesToImport
        読み込むモジュール。パス、または modules フォルダの中の名前で指定します。省略すると modules フォルダの全部を読み込みます。
    .PARAMETER VariablesToSet
        Runspace の中で使う変数 (名前と値のハッシュテーブル)。syncHash は別の引数で渡します。
    .OUTPUTS
        開いた状態の Runspace。使い終わったら呼び出し側で閉じてください。開けないときは例外になります。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [hashtable]$syncHash,

        [Parameter(Mandatory = $false, Position = 1)]
        [string[]]$ModulesToImport,

        [Parameter(Mandatory = $false, Position = 2)]
        [hashtable]$VariablesToSet,

        [Parameter(Mandatory = $false)]
        [ValidateSet("STA", "MTA")]
        [string]$ApartmentState = "STA",

        [Parameter(Mandatory = $false)]
        [ValidateSet("Default", "ReuseThread", "NewThread")]
        [string]$ThreadOptions = "ReuseThread"
    )

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

    # モジュール探索ディレクトリの解決
    $modulesDir = $PSScriptRoot
    if ($syncHash -and $syncHash.PSScriptRoot) {
        $candidate = Join-Path $syncHash.PSScriptRoot "modules"
        if (Test-Path $candidate) { $modulesDir = $candidate }
    }

    if ($ModulesToImport -and $ModulesToImport.Count -gt 0) {
        foreach ($mod in $ModulesToImport) {
            if (Test-Path $mod) {
                $iss.ImportPSModule($mod)
            } else {
                $modFile = Join-Path $modulesDir "$mod.psm1"
                if (Test-Path $modFile) {
                    $iss.ImportPSModule($modFile)
                } else {
                    $iss.ImportPSModule($mod)
                }
            }
        }
    } else {
        if (Test-Path $modulesDir) {
            Get-ChildItem -Path $modulesDir -Filter "*.psm1" -ErrorAction SilentlyContinue | ForEach-Object {
                $iss.ImportPSModule($_.FullName)
            }
        }
    }

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
    $rs.ApartmentState = [System.Threading.ApartmentState]::$ApartmentState
    $rs.ThreadOptions  = [System.Management.Automation.Runspaces.PSThreadOptions]::$ThreadOptions

    try {
        $rs.Open()
    } catch {
        if ($null -ne $rs) {
            try { $rs.Dispose() } catch {}
        }
        throw "Failed to open background Runspace: $($_.Exception.Message)"
    }

    if ($syncHash) {
        $rs.SessionStateProxy.SetVariable("syncHash", $syncHash)
    }
    if ($VariablesToSet) {
        foreach ($key in $VariablesToSet.Keys) {
            $rs.SessionStateProxy.SetVariable($key, $VariablesToSet[$key])
        }
    }

    return $rs
}

Export-ModuleMember -Function Protect-SecretString, Unprotect-SecretString, Log-Audit, Write-ServerLog, Write-JsonResponse, Test-ApiRequestAllowed, Test-ClientAddressAllowed, Test-LogSourceAllowed, ConvertTo-SafeIperfOptions, Get-MimeType, Save-DevicesJson, Backup-ConfigSnapshot, Get-ConfigSnapshots, Restore-ConfigSnapshot, Test-SystemPrerequisites, Install-PrerequisiteModule, New-AppRunspace
