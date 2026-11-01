# ==============================================================================
# AlertManager.psm1 - Webhook・メール通知・多段アラート管理モジュール
# ==============================================================================
# 【初心者向けの簡単な解説】
# 機器に障害が起きたときなどに、外部へ知らせる部品です。
# - Webhook: Slack / Teams / Discord などが用意した URL へ、通知の内容を送ります。
# - メール: SMTP サーバー (メールを配送するサーバー) を通して送ります。
# 音で知らせる機能は画面側 (app.js) にあり、このファイルにはありません。
#
# 【呼び出し元】
# Server.ps1 の Ping 監視 (障害と復旧の通知) と、設定画面の「テスト送信」です。
# 監視の処理を止めないよう、Server.ps1 は別スレッドからこの関数を呼びます。
#
# 【変更するときの注意】
# - 通知に失敗しても監視を止めないよう、通常は例外を投げずに $false を返します。
#   テスト送信だけは失敗の理由を画面に出すため、-ThrowOnError で例外にします。
# - テストは tests/AlertManager.Tests.ps1 です。送信内容を変えたら確認してください。
# ==============================================================================

# Common モジュールの Unprotect-SecretString を利用可能にする
Import-Module (Join-Path $PSScriptRoot "Common.psm1") -DisableNameChecking -ErrorAction SilentlyContinue

function Send-WebhookNotification {
    <#
    .SYNOPSIS
        Webhook（Discord, Slack, Teams等）へJSON通知を送信します。
        Warning（注意）/ Critical（障害）の多段階レベルに対応。
    .OUTPUTS
        送れたら $true、失敗したら $false。URL が空のときは通知を使わない設定なので、何も返しません。
    .NOTES
        4 秒で打ち切ります。相手が応答しないときに、通知の待ち時間が長引かないようにするためです。
    #>
    param(
        [string]$url,
        [string]$deviceName,
        [string]$ip,
        [string]$eventType,
        [string]$details = "",
        [string]$severity = "CRITICAL", # WARNING or CRITICAL
        [switch]$ThrowOnError           # テスト送信用: 失敗時に理由を例外で返す
    )
    if ([string]::IsNullOrWhiteSpace($url)) { return }

    # http / https 以外 (file: など) を受け付けると、通知内容がPC内のファイルに書き込まれてしまうため送らない
    $uriObj = $null
    if (-not [System.Uri]::TryCreate($url.Trim(), [System.UriKind]::Absolute, [ref]$uriObj) -or $uriObj.Scheme -notin @("http", "https")) {
        if ($ThrowOnError) { throw "Webhook URL は http:// または https:// で始まる必要があります" }
        return $false
    }

    # 出来事の種類ごとの絵文字と見出し。種類を増やすときは、下の 2 つの switch の両方に追加する
    $emoji = switch ($eventType.ToLower()) {
        "offline"   { [char]::ConvertFromUtf32(0x1F534) } # 🔴
        "online"    { [char]::ConvertFromUtf32(0x1F7E2) } # 🟢
        "warning"   { [char]::ConvertFromUtf32(0x26A0) }  # ⚠️
        "critical"  { [char]::ConvertFromUtf32(0x1F6A8) } # 🚨
        "latency"   { [char]::ConvertFromUtf32(0x26A0) }  # ⚠️
        "test"      { [char]::ConvertFromUtf32(0x1F514) } # 🔔
        default     { [char]::ConvertFromUtf32(0x1F4E2) } # 📢
    }

    $title = switch ($eventType.ToLower()) {
        "offline"   { "【障害発生】機器オフライン検知" }
        "online"    { "【正常復旧】機器オンライン復帰" }
        "warning"   { "【注意・警告】監視閾値超過 / 遅延悪化" }
        "critical"  { "【重度障害】通信断・連続応答失敗" }
        "latency"   { "【遅延警告】応答時間悪化" }
        "test"      { "【テスト通知】Webhook疎通テスト" }
        default     { "ネットワーク監視アラート" }
    }

    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $msgText = "$emoji **$title**`n[重要度]: $severity`n[対象機器]: $deviceName ($ip)`n[検知日時]: $ts`n[詳細]: $details"

    # 受け取るサービスによって読む項目が違うので、同じ内容を複数の項目に入れる
    # Slack / Teams は text、Discord は content を表示する。それ以外の項目は自作の受信側が機器ごとに処理するためのもの
    $bodyObj = @{
        text       = $msgText
        content    = $msgText   # Discord compatibility
        title      = "$emoji $title"
        severity   = $severity
        deviceName = $deviceName
        ip         = $ip
        eventType  = $eventType
        timestamp  = $ts
        details    = $details
    }
    $jsonPayload = $bodyObj | ConvertTo-Json -Depth 3

    try {
        $webReq = [System.Net.WebRequest]::Create($uriObj)
        $webReq.Method = "POST"
        $webReq.ContentType = "application/json; charset=utf-8"
        $webReq.Timeout = 4000
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonPayload)
        $webReq.ContentLength = $bytes.Length
        $reqStream = $webReq.GetRequestStream()
        try {
            $reqStream.Write($bytes, 0, $bytes.Length)
        } finally {
            $reqStream.Close()
        }
        $webResp = $null
        try {
            $webResp = $webReq.GetResponse()
            return $true
        } catch [System.Net.WebException] {
            # 接続の失敗に加え、相手が 500 などを返したときもここに来る
            # 応答を閉じないと接続が残り続けるので、失敗のときも閉じる
            $webErr = $_.Exception
            if ($webErr.Response) {
                try { $webErr.Response.Close(); $webErr.Response.Dispose() } catch {}
            }
            if ($ThrowOnError) { throw $webErr.Message }
            return $false
        } finally {
            if ($null -ne $webResp) {
                try { $webResp.Close(); $webResp.Dispose() } catch {}
            }
        }
    } catch {
        if ($ThrowOnError) { throw }
        return $false
    }
}

function Send-EmailNotification {
    <#
    .SYNOPSIS
        SMTP経由でアラートメールを送信します。
        パスワードがDPAPI暗号化（enc:...）されている場合は自動復号して利用します。
    .PARAMETER to
        宛先。カンマまたはセミコロンで区切って複数指定できます。
    .PARAMETER from
        差出人。省略すると monitor@localhost を使います。
    .OUTPUTS
        送れたら $true、失敗したら $false。失敗の理由は警告として出力し、例外にはしません。
    .NOTES
        8 秒で打ち切ります。smtpUser が空のときは認証なしで送ります。
    #>
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
    $mail = $null
    $smtp = $null
    try {
        # 暗号化パスワードの自動復号
        $actualPass = if ($smtpPass -and $smtpPass.StartsWith("enc:")) {
            Unprotect-SecretString $smtpPass
        } else {
            $smtpPass
        }

        $mail = New-Object System.Net.Mail.MailMessage
        $mail.From = New-Object System.Net.Mail.MailAddress($(if ($from) { $from } else { "monitor@localhost" }))
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
            $smtp.Credentials = New-Object System.Net.NetworkCredential($smtpUser, $actualPass)
        }
        $smtp.Send($mail)
        return $true
    } catch {
        Write-Warning "SMTP notification error: $($_.Exception.Message)"
        return $false
    } finally {
        # 送信に失敗したときも接続を閉じる (閉じないと失敗のたびに接続が残り続ける)
        if ($mail) { try { $mail.Dispose() } catch {} }
        if ($smtp) { try { $smtp.Dispose() } catch {} }
    }
}

Export-ModuleMember -Function Send-WebhookNotification, Send-EmailNotification
