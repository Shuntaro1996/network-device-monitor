# ==============================================================================
# AlertManager.psm1 - Webhook・メール通知・多段アラート管理モジュール
# ==============================================================================

# Common モジュールの Unprotect-SecretString を利用可能にする
Import-Module (Join-Path $PSScriptRoot "Common.psm1") -ErrorAction SilentlyContinue

function Send-WebhookNotification {
    <#
    .SYNOPSIS
        Webhook（Discord, Slack, Teams等）へJSON通知を送信します。
        Warning（注意）/ Critical（障害）の多段階レベルに対応。
    #>
    param(
        [string]$url,
        [string]$deviceName,
        [string]$ip,
        [string]$eventType,
        [string]$details = "",
        [string]$severity = "CRITICAL"  # WARNING or CRITICAL
    )
    if ([string]::IsNullOrWhiteSpace($url)) { return }

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
        if ($null -ne $webResp) { $webResp.Close() }
        return $true
    } catch {
        return $false
    }
}

function Send-EmailNotification {
    <#
    .SYNOPSIS
        SMTP経由でアラートメールを送信します。
        パスワードがDPAPI暗号化（enc:...）されている場合は自動復号して利用します。
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
    try {
        # 暗号化パスワードの自動復号
        $actualPass = if ($smtpPass -and $smtpPass.StartsWith("enc:")) {
            Unprotect-SecretString $smtpPass
        } else {
            $smtpPass
        }

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
            $smtp.Credentials = New-Object System.Net.NetworkCredential($smtpUser, $actualPass)
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

Export-ModuleMember -Function Send-WebhookNotification, Send-EmailNotification
