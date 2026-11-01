# ==============================================================================
# AlertManager.Tests.ps1 - Webhook・メール通知の単体テスト
# ==============================================================================
# 【初心者向けの簡単な解説】
# 通知の処理は、外部のサービス (Slack やメールサーバー) へデータを送ります。
# テストで本物へ送らないよう、このPCの中だけで動く「模擬サーバー」を立てて受け取り、
# 届いた内容と、通知の処理が返した結果を確かめます。
#
# 【変更するときの注意】
# - 模擬サーバーは 127.0.0.1 だけで待ち受けます。外部の宛先を書かないでください。
# - 模擬サーバーは別スレッドで動きます。Get-FreeTestPort で空きポートを探しているので、
#   起動を待ってから送信します (待つ時間は Start-Sleep の値です)。
# - Stop-FakeServer は結果を待ちますが、上限を超えると止めて $null を返します。
#   テストが固まらないようにするためです。
# ==============================================================================

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$moduleDir = Join-Path (Split-Path -Parent $here) "modules"
Import-Module (Join-Path $moduleDir "Common.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $moduleDir "AlertManager.psm1") -Force -DisableNameChecking

function Get-FreeTestPort {
    # ポート番号に 0 を指定すると Windows が空きを選ぶので、その番号を調べて閉じる
    $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $freePort = $probe.LocalEndpoint.Port
    $probe.Stop()
    return $freePort
}

function Start-FakeWebhookServer {
    # 1 回だけ HTTP の要求を受け取り、指定の状態コードを返す模擬サーバー。受け取った内容 (文字列) が結果になる
    param([int]$Port, [int]$StatusCode)
    $shell = [PowerShell]::Create()
    $null = $shell.AddScript({
            param($Port, $StatusCode)
            $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
            $listener.Start()
            $client = $listener.AcceptTcpClient()
            $stream = $client.GetStream()
            $stream.ReadTimeout = 3000
            $buffer = New-Object byte[] 65536
            $received = New-Object System.IO.MemoryStream
            $text = ""
            # 本文は分かれて届くことがあるので、Content-Length の長さがそろうまで読む
            while ($true) {
                $count = $stream.Read($buffer, 0, $buffer.Length)
                if ($count -le 0) { break }
                $received.Write($buffer, 0, $count)
                $text = [System.Text.Encoding]::UTF8.GetString($received.ToArray())
                $headerEnd = $text.IndexOf("`r`n`r`n")
                if ($headerEnd -ge 0 -and $text -match 'Content-Length:\s*(\d+)') {
                    $headerBytes = [System.Text.Encoding]::UTF8.GetByteCount($text.Substring(0, $headerEnd + 4))
                    if (($received.Length - $headerBytes) -ge [int]$Matches[1]) { break }
                }
            }
            $reply = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $StatusCode X`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
            $stream.Write($reply, 0, $reply.Length)
            $stream.Flush()
            Start-Sleep -Milliseconds 100
            $client.Close()
            $listener.Stop()
            return $text
        }).AddArgument($Port).AddArgument($StatusCode)
    return @{ Shell = $shell; Handle = $shell.BeginInvoke() }
}

function Start-FakeSmtpServer {
    # メールサーバーのやりとりを最小限まねて、受け取った行をまとめて結果にする模擬サーバー
    param([int]$Port)
    $shell = [PowerShell]::Create()
    $null = $shell.AddScript({
            param($Port)
            $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
            $listener.Start()
            $client = $listener.AcceptTcpClient()
            $stream = $client.GetStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $writer = New-Object System.IO.StreamWriter($stream)
            $writer.AutoFlush = $true
            $writer.NewLine = "`r`n"
            $lines = New-Object System.Collections.ArrayList
            $writer.WriteLine("220 fake")
            $inData = $false
            while ($null -ne ($line = $reader.ReadLine())) {
                $null = $lines.Add($line)
                # DATA のあとは「.」だけの行まで本文が続く
                if ($inData) {
                    if ($line -eq ".") { $inData = $false; $writer.WriteLine("250 ok") }
                    continue
                }
                if ($line -match '^DATA') { $inData = $true; $writer.WriteLine("354 go"); continue }
                if ($line -match '^QUIT') { $writer.WriteLine("221 bye"); break }
                $writer.WriteLine("250 ok")
            }
            $client.Close()
            $listener.Stop()
            return ($lines -join "`n")
        }).AddArgument($Port)
    return @{ Shell = $shell; Handle = $shell.BeginInvoke() }
}

function Stop-FakeServer {
    # 模擬サーバーの終了を待って、受け取った内容を返す
    param($Server)
    $finished = $Server.Handle.AsyncWaitHandle.WaitOne(8000)
    $output = if ($finished) { $Server.Shell.EndInvoke($Server.Handle) } else { $Server.Shell.Stop(); $null }
    $Server.Shell.Dispose()
    return [string]($output | Select-Object -Last 1)
}

Describe "AlertManager Send-WebhookNotification (Webhook 通知)" {
    It "URL が空のときは何もしないこと" {
        Send-WebhookNotification -url "" -deviceName "A" -ip "10.0.0.1" -eventType "test" | Should BeNullOrEmpty
    }

    It "http / https 以外の URL は拒否し、ファイルを書き込まないこと" {
        $target = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_Webhook_$(Get-Random).txt"
        $fileUrl = ([System.Uri]$target).AbsoluteUri
        try {
            Send-WebhookNotification -url $fileUrl -deviceName "A" -ip "10.0.0.1" -eventType "test" | Should Be $false
            (Test-Path -LiteralPath $target) | Should Be $false
            $thrown = $false
            try { Send-WebhookNotification -url $fileUrl -deviceName "A" -ip "10.0.0.1" -eventType "test" -ThrowOnError } catch { $thrown = $true }
            $thrown | Should Be $true
        } finally {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        }
    }

    It "機器の情報を UTF-8 の JSON で送り、200 なら成功を返すこと" {
        $port = Get-FreeTestPort
        $server = Start-FakeWebhookServer -Port $port -StatusCode 200
        Start-Sleep -Milliseconds 700
        $name = "コアスイッチ"
        $result = Send-WebhookNotification -url "http://127.0.0.1:$port/hook" -deviceName $name -ip "10.0.0.9" -eventType "offline" -details "x<y" -severity "WARNING"
        $raw = Stop-FakeServer $server

        $result | Should Be $true
        $raw | Should Match "POST /hook"
        $raw | Should Match "application/json; charset=utf-8"
        $body = $raw.Substring($raw.IndexOf("`r`n`r`n") + 4) | ConvertFrom-Json
        $body.deviceName | Should Be $name
        $body.ip | Should Be "10.0.0.9"
        $body.severity | Should Be "WARNING"
        $body.eventType | Should Be "offline"
        $body.details | Should Be "x<y"
        # text は Slack / Teams 用、content は Discord 用で、同じ内容を入れている
        $body.content | Should Be $body.text
    }

    It "相手が 500 を返したら失敗を返し、-ThrowOnError では例外にすること" {
        $port = Get-FreeTestPort
        $server = Start-FakeWebhookServer -Port $port -StatusCode 500
        Start-Sleep -Milliseconds 700
        $result = Send-WebhookNotification -url "http://127.0.0.1:$port/" -deviceName "A" -ip "10.0.0.1" -eventType "test"
        $null = Stop-FakeServer $server
        $result | Should Be $false

        $port2 = Get-FreeTestPort
        $server2 = Start-FakeWebhookServer -Port $port2 -StatusCode 500
        Start-Sleep -Milliseconds 700
        $thrown = $false
        try { Send-WebhookNotification -url "http://127.0.0.1:$port2/" -deviceName "A" -ip "10.0.0.1" -eventType "test" -ThrowOnError } catch { $thrown = $true }
        $null = Stop-FakeServer $server2
        $thrown | Should Be $true
    }

    It "相手に接続できないときは失敗を返し、例外にしないこと" {
        $port = Get-FreeTestPort
        Send-WebhookNotification -url "http://127.0.0.1:$port/" -deviceName "A" -ip "10.0.0.1" -eventType "test" | Should Be $false
    }
}

Describe "AlertManager Send-EmailNotification (メール通知)" {
    It "送信先のサーバーや宛先がないときは失敗を返すこと" {
        Send-EmailNotification -smtpHost "" -smtpPort 25 -useSsl $false -smtpUser "" -smtpPass "" -from "" -to "a@example.test" -subject "s" -body "b" | Should Be $false
        Send-EmailNotification -smtpHost "127.0.0.1" -smtpPort 25 -useSsl $false -smtpUser "" -smtpPass "" -from "" -to " " -subject "s" -body "b" | Should Be $false
    }

    It "メールサーバーに接続できないときは失敗を返し、例外にしないこと" {
        $port = Get-FreeTestPort
        Send-EmailNotification -smtpHost "127.0.0.1" -smtpPort $port -useSsl $false -smtpUser "" -smtpPass "" -from "m@example.test" -to "a@example.test" -subject "s" -body "b" -WarningAction SilentlyContinue | Should Be $false
    }

    It "カンマとセミコロンで区切った宛先すべてに送ること" {
        $port = Get-FreeTestPort
        $server = Start-FakeSmtpServer -Port $port
        Start-Sleep -Milliseconds 700
        $result = Send-EmailNotification -smtpHost "127.0.0.1" -smtpPort $port -useSsl $false -smtpUser "" -smtpPass "" -from "m@example.test" -to "a@example.test, b@example.test;c@example.test" -subject "sub" -body "hello" -WarningAction SilentlyContinue
        $log = Stop-FakeServer $server

        $result | Should Be $true
        $log | Should Match "MAIL FROM:<m@example.test>"
        $log | Should Match "RCPT TO:<a@example.test>"
        $log | Should Match "RCPT TO:<b@example.test>"
        $log | Should Match "RCPT TO:<c@example.test>"
    }

    It "差出人を省略すると monitor@localhost を使うこと" {
        $port = Get-FreeTestPort
        $server = Start-FakeSmtpServer -Port $port
        Start-Sleep -Milliseconds 700
        $result = Send-EmailNotification -smtpHost "127.0.0.1" -smtpPort $port -useSsl $false -smtpUser "" -smtpPass "" -from "" -to "a@example.test" -subject "sub" -body "hello" -WarningAction SilentlyContinue
        $log = Stop-FakeServer $server

        $result | Should Be $true
        $log | Should Match "MAIL FROM:<monitor@localhost>"
    }
}
