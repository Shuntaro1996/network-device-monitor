# ==============================================================================
# RemoteExec.Tests.ps1 - リモート制御・再起動・コマンド実行 自動テスト (Pester)
# ==============================================================================

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Resolve-Path (Join-Path $here "..\..")
$moduleDir = Join-Path $projectRoot "system\modules"

Import-Module (Join-Path $moduleDir "Common.psm1") -Force
Import-Module (Join-Path $moduleDir "RemoteExec.psm1") -Force

Describe "1. RemoteExec モジュールロード & インターフェース検証" {
    It "RemoteExec.psm1 から Invoke-RemoteDeviceCommand が正常にエクスポートされていること" {
        $cmd = Get-Command -Name "Invoke-RemoteDeviceCommand" -ErrorAction SilentlyContinue
        $cmd | Should Not BeNullOrEmpty
        $cmd.ModuleName | Should Be "RemoteExec"
    }
}

Describe "2. リモート制御 安全対策 & 入力バリデーション" {
    It "リモート制御が無効（enabled = $false）の場合は REMOTE_DISABLED で即時終了すること" {
        $dev = @{
            ip     = "192.168.1.100"
            name   = "Test-Switch"
            remote = @{
                enabled  = $false
                protocol = "custom"
            }
        }
        $result = Invoke-RemoteDeviceCommand -Device $dev -Action "reboot"
        $result.success | Should Be $false
        $result.status | Should Be "REMOTE_DISABLED"
        $result.exitCode | Should Be -1
        $result.stderr | Should Match "disabled"
    }

    It "対象IP/ホスト名が未設定の場合は INVALID_TARGET を返すこと" {
        $dev = @{
            ip     = ""
            name   = "Empty-IP"
            remote = @{
                enabled  = $true
                protocol = "custom"
                host     = ""
            }
        }
        $result = Invoke-RemoteDeviceCommand -Device $dev -Action "reboot"
        $result.success | Should Be $false
        $result.status | Should Be "INVALID_TARGET"
    }

    It "action = 'command' で commandId も customCommand も未指定の場合は NO_COMMAND_SPECIFIED を返すこと" {
        $dev = @{
            ip     = "127.0.0.1"
            name   = "Local-Test"
            remote = @{
                enabled  = $true
                protocol = "custom"
            }
        }
        $result = Invoke-RemoteDeviceCommand -Device $dev -Action "command"
        $result.success | Should Be $false
        $result.status | Should Be "NO_COMMAND_SPECIFIED"
    }

    It "存在しない commandId を指定した場合は COMMAND_NOT_FOUND を返すこと" {
        $dev = @{
            ip     = "127.0.0.1"
            name   = "Local-Test"
            remote = @{
                enabled  = $true
                protocol = "custom"
                commands = @(
                    @{ id = "cmd-1"; name = "Check Status"; command = "echo OK" }
                )
            }
        }
        $result = Invoke-RemoteDeviceCommand -Device $dev -Action "command" -CommandId "non-existent-id"
        $result.success | Should Be $false
        $result.status | Should Be "COMMAND_NOT_FOUND"
    }

    It "custom プロトコルで rebootCommand が未設定のまま再起動を試みた場合は NO_REBOOT_COMMAND を返すこと" {
        $dev = @{
            ip     = "127.0.0.1"
            name   = "Local-Test"
            remote = @{
                enabled       = $true
                protocol      = "custom"
                rebootCommand = ""
            }
        }
        $result = Invoke-RemoteDeviceCommand -Device $dev -Action "reboot"
        $result.success | Should Be $false
        $result.status | Should Be "NO_REBOOT_COMMAND"
    }

    It "未対応のプロトコルが渡された場合は UNSUPPORTED_PROTOCOL を返すこと" {
        $dev = @{
            ip     = "127.0.0.1"
            name   = "Local-Test"
            remote = @{
                enabled  = $true
                protocol = "telnet-unknown"
            }
        }
        $result = Invoke-RemoteDeviceCommand -Device $dev -Action "command" -CustomCommand "echo test"
        $result.success | Should Be $false
        $result.status | Should Be "UNSUPPORTED_PROTOCOL"
    }
}

Describe "3. コマンド実行 & 結果構造体フォーマット検証 (Custom Protocol)" {
    It "安全なテストコマンドを実行し、完全な構造体 (exitCode 0, COMPLETED) を返すこと" {
        $dev = @{
            ip     = "127.0.0.1"
            name   = "Server-01"
            remote = @{
                enabled  = $true
                protocol = "custom"
                commands = @(
                    @{ id = "cmd-status"; name = "Status Check"; command = "echo RemoteCommandOK" }
                )
            }
        }
        $res = Invoke-RemoteDeviceCommand -Device $dev -Action "command" -CommandId "cmd-status"
        $res.success | Should Be $true
        $res.status | Should Be "COMPLETED"
        $res.exitCode | Should Be 0
        $res.target | Should Be "127.0.0.1"
        $res.deviceName | Should Be "Server-01"
        $res.remoteType | Should Be "custom"
        $res.action | Should Be "command"
        $res.command | Should Be "echo RemoteCommandOK"
        $res.stdout | Should Be "RemoteCommandOK"
        $res.stderr | Should Be ""
        $res.executionTimeMs | Should BeGreaterThan -1
        $res.timestamp | Should Not BeNullOrEmpty
    }

    It "カスタムコマンドのテンプレート変数 ({ip}, {name}, {user}, {port}) が正しく置換されること" {
        $dev = @{
            ip     = "10.20.30.40"
            name   = "CoreRouter"
            remote = @{
                enabled  = $true
                protocol = "custom"
                port     = 2222
                user     = "netadmin"
            }
        }
        $template = "echo HOST={ip} NAME={name} USER={user} PORT={port}"
        $res = Invoke-RemoteDeviceCommand -Device $dev -Action "command" -CustomCommand $template
        $res.success | Should Be $true
        $res.stdout | Should Be "HOST=10.20.30.40 NAME=CoreRouter USER=netadmin PORT=2222"
    }

    It "コマンドが異常終了 (非ゼロ終了コード) の場合は status 'FAILED' と exitCode を返すこと" {
        $dev = @{
            ip     = "127.0.0.1"
            name   = "Local-Fail-Test"
            remote = @{
                enabled  = $true
                protocol = "custom"
            }
        }
        $res = Invoke-RemoteDeviceCommand -Device $dev -Action "command" -CustomCommand "cmd.exe /c exit 5"
        $res.success | Should Be $false
        $res.status | Should Be "FAILED"
        $res.exitCode | Should Be 5
    }
}

Describe "4. タイムアウト監視 & プロセス強制終了 (Timeout Kill)" {
    It "指定秒数 (1秒) を超える長時間プロセスが安全に強制終了され、status 'TIMEOUT' を返すこと" {
        $dev = @{
            ip     = "127.0.0.1"
            name   = "Timeout-Target"
            remote = @{
                enabled  = $true
                protocol = "custom"
            }
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        # 10秒スリープするスクリプトをタイムアウト1秒で実行
        $res = Invoke-RemoteDeviceCommand -Device $dev -Action "command" -CustomCommand "powershell.exe -NoProfile -Command Start-Sleep 10" -TimeoutSec 1
        $sw.Stop()

        $res.success | Should Be $false
        $res.status | Should Be "TIMEOUT"
        $res.exitCode | Should Be -1
        $res.stderr | Should Match "timed out after 1 seconds"
        # 3秒以内に制御が返ること (ハングアップ防止の検証)
        $sw.ElapsedMilliseconds | Should BeLessThan 3500
    }
}

Describe "5. リモート設定の永続化 & DPAPI パスワード暗号化 (Common.psm1)" {
    It "Save-DevicesJson で remote オブジェクトが devices.json に保存され、パスワードが DPAPI 暗号化されること" {
        $testJsonPath = Join-Path $here "temp_devices_remote_test.json"
        try {
            $sync = @{
                Devices     = @("192.168.10.1")
                DevicesLock = New-Object object
                Remote      = @{
                    "192.168.10.1" = @{
                        enabled       = $true
                        protocol      = "ssh"
                        host          = "192.168.10.1"
                        port          = 22
                        authType      = "password"
                        user          = "admin"
                        password      = "PlainPasswordToBeEncrypted#999"
                        keyPath       = ""
                        rebootCommand = "sudo reboot"
                        commands      = @(
                            @{
                                id          = "cmd-1"
                                name        = "Check Interfaces"
                                command     = "ip addr show"
                                description = "Display network interface configs"
                            }
                        )
                    }
                }
            }

            $saved = Save-DevicesJson $sync $testJsonPath
            $saved | Should Be $true
            Test-Path $testJsonPath | Should Be $true

            $rawContent = Get-Content $testJsonPath -Raw -Encoding UTF8
            $parsed = $rawContent | ConvertFrom-Json

            $parsed | Should Not BeNullOrEmpty
            $targetDev = $parsed[0]
            $targetDev.remote | Should Not BeNullOrEmpty
            $targetDev.remote.enabled | Should Be $true
            $targetDev.remote.protocol | Should Be "ssh"
            $targetDev.remote.password.StartsWith("enc:") | Should Be $true
            $targetDev.remote.password | Should Not Be "PlainPasswordToBeEncrypted#999"

            # 復号テスト: Unprotect-SecretString で元の平文に戻ること
            $decrypted = Unprotect-SecretString $targetDev.remote.password
            $decrypted | Should Be "PlainPasswordToBeEncrypted#999"

            # ネスト配列 (commands) の Depth 10 保持検証
            $targetDev.remote.commands.Count | Should Be 1
            $targetDev.remote.commands[0].id | Should Be "cmd-1"
            $targetDev.remote.commands[0].command | Should Be "ip addr show"
        } finally {
            if (Test-Path $testJsonPath) {
                Remove-Item -Path $testJsonPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe "6. 監査ログ記録 (Log-Audit / Reports/audit.log)" {
    It "リモート再起動 (REMOTE_REBOOT) およびコマンド実行 (REMOTE_EXEC) が Reports/audit.log に正しく記録されること" {
        $tempReportsDir = Join-Path $here "temp_reports_audit_test"
        try {
            if (-not (Test-Path $tempReportsDir)) {
                New-Item -ItemType Directory -Path $tempReportsDir -Force | Out-Null
            }

            Log-Audit -action "REMOTE_REBOOT" -target "192.168.1.1" -details "Device: CoreRouter | Action: reboot | Command: sudo reboot | Status: COMPLETED | ExitCode: 0 | Duration: 120ms" -clientIp "127.0.0.1" -reportsDirectory $tempReportsDir
            Log-Audit -action "REMOTE_EXEC" -target "192.168.1.1" -details "Device: CoreRouter | Action: command | Command: uptime | Status: COMPLETED | ExitCode: 0 | Duration: 45ms" -clientIp "127.0.0.1" -reportsDirectory $tempReportsDir

            $auditFile = Join-Path $tempReportsDir "audit.log"
            Test-Path $auditFile | Should Be $true

            $lines = Get-Content $auditFile -Encoding UTF8
            $lines.Count | Should Be 2

            # 1行目: REMOTE_REBOOT
            $lines[0] | Should Match "\[Action: REMOTE_REBOOT\]"
            $lines[0] | Should Match "\[Target: 192\.168\.1\.1\]"
            $lines[0] | Should Match "sudo reboot"

            # 2行目: REMOTE_EXEC
            $lines[1] | Should Match "\[Action: REMOTE_EXEC\]"
            $lines[1] | Should Match "uptime"
        } finally {
            if (Test-Path $tempReportsDir) {
                Remove-Item -Path $tempReportsDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe "7. HTTP REST API (/api/device/remote-exec) エンドポイント統合テスト" {
    BeforeAll {
        # 空きポート選定
        $tcpListener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $tcpListener.Start()
        $global:apiTestPort = $tcpListener.LocalEndpoint.Port
        $tcpListener.Stop()

        $global:apiSyncHash = @{
            Devices    = @("127.0.0.1", "10.0.0.1")
            DeviceName = @{ "127.0.0.1" = "LocalLoopback"; "10.0.0.1" = "DisabledDevice" }
            Remote     = @{
                "127.0.0.1" = @{
                    enabled       = $true
                    protocol      = "custom"
                    rebootCommand = "echo HTTP_REBOOT_SUCCESS"
                    commands      = @(
                        @{ id = "cmd-api-check"; name = "API Check"; command = "echo HTTP_COMMAND_SUCCESS" }
                    )
                }
                "10.0.0.1" = @{
                    enabled  = $false
                    protocol = "custom"
                }
            }
        }

        $global:apiServerRs = [powershell]::Create()
        $global:apiServerRs.AddScript({
            param($port, $moduleDir, $reportsDir, $syncHash)
            Import-Module (Join-Path $moduleDir "Common.psm1") -Force
            Import-Module (Join-Path $moduleDir "RemoteExec.psm1") -Force

            $listener = New-Object System.Net.HttpListener
            $listener.Prefixes.Add("http://127.0.0.1:$port/")
            $listener.Start()

            $running = $true
            while ($running -and $listener.IsListening) {
                try {
                    $context = $listener.GetContext()
                    $request = $context.Request
                    $response = $context.Response
                    $localPath = $request.Url.LocalPath

                    if ($request.HttpMethod -eq "POST" -and $localPath -eq "/api/shutdown") {
                        Write-JsonResponse $response @{ status = "ok" } 200
                        $running = $false
                        break
                    }

                    if ($request.HttpMethod -eq "POST" -and $localPath -eq "/api/device/remote-exec") {
                        $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                        $jsonBody = $reader.ReadToEnd()
                        $reader.Close()

                        $payload = $null
                        try { if ($jsonBody) { $payload = $jsonBody | ConvertFrom-Json } } catch {}

                        if ($null -eq $payload) {
                            Write-JsonResponse $response @{ error = "Invalid JSON body"; success = $false; status = "INVALID_REQUEST" } 400
                            continue
                        }

                        $ip = if ($payload.ip) { [string]$payload.ip.Trim() } else { "" }
                        $action = if ($payload.action) { [string]$payload.action.Trim().ToLower() } else { "" }
                        $commandId = if ($payload.commandId) { [string]$payload.commandId.Trim() } else { $null }
                        $customCommand = if ($payload.customCommand) { [string]$payload.customCommand.Trim() } else { $null }
                        $timeoutSec = if ($payload.timeoutSec) { [int]$payload.timeoutSec } else { 15 }

                        if ([string]::IsNullOrWhiteSpace($ip)) {
                            Write-JsonResponse $response @{ error = "Target IP address is required"; success = $false; status = "MISSING_IP" } 400
                            continue
                        }

                        if ($action -ne "reboot" -and $action -ne "command") {
                            Write-JsonResponse $response @{ error = "Invalid action: must be 'reboot' or 'command'"; success = $false; status = "INVALID_ACTION" } 400
                            continue
                        }

                        if (-not ($syncHash.Devices -contains $ip)) {
                            Write-JsonResponse $response @{ error = "Device '$ip' not found"; success = $false; status = "DEVICE_NOT_FOUND" } 404
                            continue
                        }

                        $remoteCfg = if ($syncHash.Remote -and $syncHash.Remote.ContainsKey($ip)) { $syncHash.Remote[$ip] } else { $null }
                        if ($null -eq $remoteCfg) {
                            Write-JsonResponse $response @{ error = "Remote execution not configured for device '$ip'"; success = $false; status = "NOT_CONFIGURED" } 400
                            continue
                        }

                        # Subexpression evaluation fix
                        $isEnabled = [bool]$(if ($remoteCfg.ContainsKey('enabled')) { $remoteCfg['enabled'] } else { $false })
                        if (-not $isEnabled) {
                            Write-JsonResponse $response @{ error = "Remote management is disabled for device '$ip'"; success = $false; status = "REMOTE_DISABLED" } 400
                            continue
                        }

                        $deviceName = if ($syncHash.DeviceName -and $syncHash.DeviceName.ContainsKey($ip)) { $syncHash.DeviceName[$ip] } else { $ip }
                        $deviceArg = @{
                            ip     = $ip
                            name   = $deviceName
                            remote = $remoteCfg
                        }

                        $execResult = Invoke-RemoteDeviceCommand -Device $deviceArg -Action $action -CommandId $commandId -CustomCommand $customCommand -TimeoutSec $timeoutSec
                        Log-Audit -action ($action.ToUpper()) -target $ip -details "Test API Exec" -clientIp "127.0.0.1" -reportsDirectory $reportsDir
                        Write-JsonResponse $response $execResult 200
                    } else {
                        Write-JsonResponse $response @{ error = "Not found" } 404
                    }
                } catch {
                    break
                }
            }
            try { $listener.Stop(); $listener.Close() } catch {}
        }).AddArgument($global:apiTestPort).AddArgument($moduleDir).AddArgument($here).AddArgument($global:apiSyncHash) | Out-Null

        $global:apiServerHandle = $global:apiServerRs.BeginInvoke()
        Start-Sleep -Milliseconds 400
    }

    AfterAll {
        try {
            $null = Invoke-RestMethod -Uri "http://127.0.0.1:$($global:apiTestPort)/api/shutdown" -Method Post -TimeoutSec 2 -ErrorAction SilentlyContinue
        } catch {}
        if ($global:apiServerRs) {
            try { $global:apiServerRs.EndInvoke($global:apiServerHandle) | Out-Null } catch {}
            $global:apiServerRs.Dispose()
        }
    }

    It "POST /api/device/remote-exec (command) が 200 OK を返し、正常にコマンド実行結果を取得できること" {
        $uri = "http://127.0.0.1:$($global:apiTestPort)/api/device/remote-exec"
        $body = @{
            ip        = "127.0.0.1"
            action    = "command"
            commandId = "cmd-api-check"
        } | ConvertTo-Json
        $res = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json; charset=utf-8"
        $res.success | Should Be $true
        $res.status | Should Be "COMPLETED"
        $res.stdout.Trim() | Should Be "HTTP_COMMAND_SUCCESS"
    }

    It "POST /api/device/remote-exec (reboot) が 200 OK を返し、再起動コマンドが実行されること" {
        $uri = "http://127.0.0.1:$($global:apiTestPort)/api/device/remote-exec"
        $body = @{
            ip     = "127.0.0.1"
            action = "reboot"
        } | ConvertTo-Json
        $res = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json; charset=utf-8"
        $res.success | Should Be $true
        $res.status | Should Be "COMPLETED"
        $res.stdout.Trim() | Should Be "HTTP_REBOOT_SUCCESS"
    }

    It "POST /api/device/remote-exec で remote.enabled = `$false の機器は HTTP 400 REMOTE_DISABLED を返すこと" {
        $uri = "http://127.0.0.1:$($global:apiTestPort)/api/device/remote-exec"
        $body = @{
            ip     = "10.0.0.1"
            action = "reboot"
        } | ConvertTo-Json
        $statusCode = 0
        $errStatus = ""
        try {
            $null = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json; charset=utf-8"
        } catch {
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            $rawJson = ""
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $rawJson = $_.ErrorDetails.Message
            } elseif ($_.Exception.Response) {
                try {
                    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $rawJson = $reader.ReadToEnd()
                } catch {}
            }
            if ($rawJson) {
                try {
                    $errJson = $rawJson | ConvertFrom-Json
                    $errStatus = $errJson.status
                } catch {}
            }
        }
        $statusCode | Should Be 400
        $errStatus | Should Be "REMOTE_DISABLED"
    }

    It "POST /api/device/remote-exec で未登録IPの場合は HTTP 404 DEVICE_NOT_FOUND を返すこと" {
        $uri = "http://127.0.0.1:$($global:apiTestPort)/api/device/remote-exec"
        $body = @{
            ip     = "192.168.254.254"
            action = "reboot"
        } | ConvertTo-Json
        $statusCode = 0
        try {
            $null = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json; charset=utf-8"
        } catch {
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
        }
        $statusCode | Should Be 404
    }

    It "POST /api/device/remote-exec で無効な action が渡された場合は HTTP 400 INVALID_ACTION を返すこと" {
        $uri = "http://127.0.0.1:$($global:apiTestPort)/api/device/remote-exec"
        $body = @{
            ip     = "127.0.0.1"
            action = "destroy"
        } | ConvertTo-Json
        $statusCode = 0
        try {
            $null = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType "application/json; charset=utf-8"
        } catch {
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
        }
        $statusCode | Should Be 400
    }
}


Describe "8. コマンド引数の安全なエスケープ & ローカル実行防止" {
    # 実際の Windows 引数解析 (CommandLineToArgvW) で検証する
    # ※ テスト用 exe を生成・起動する方式はアプリ制御ポリシー (Smart App Control 等) でブロックされるため使わない
    if (-not ("NdmArgParser" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class NdmArgParser {
    [DllImport("shell32.dll", SetLastError = true)]
    static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string cmdLine, out int numArgs);
    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr hMem);
    public static string[] Split(string cmdLine) {
        int n;
        IntPtr ptr = CommandLineToArgvW(cmdLine, out n);
        try {
            string[] result = new string[n];
            for (int i = 0; i < n; i++) {
                result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(ptr, i * IntPtr.Size));
            }
            return result;
        } finally { LocalFree(ptr); }
    }
}
"@
    }

    $cases = @(
        'plain',
        'show running-config',
        'echo "hello world"',
        'C:\path with space\',
        'a\\"b',
        '" -oProxyCommand=calc.exe "',
        'tail -n 100 /var/log/syslog | grep "err" & echo %PATH%',
        ''
    )

    foreach ($case in $cases) {
        It "引数 [$case] が 1 個の引数として元の文字列どおりに届くこと" {
            $argStr = "prog.exe " + (ConvertTo-ProcessArgument $case) + " " + (ConvertTo-ProcessArgument "tail")
            $parsed = [NdmArgParser]::Split($argStr)
            $parsed.Count | Should Be 3
            $parsed[1] | Should BeExactly $case
            $parsed[2] | Should Be "tail"
        }
    }

    It "SSH の接続先が '-' で始まる場合はオプション扱いされないよう INVALID_TARGET で拒否すること" {
        $dev = @{
            ip     = "192.0.2.10"
            name   = "Bad-Host"
            remote = @{ enabled = $true; protocol = "ssh"; host = "-oProxyCommand=calc.exe"; authType = "none" }
        }
        $result = Invoke-RemoteDeviceCommand -Device $dev -Action "command" -CustomCommand "uptime" -TimeoutSec 5
        $result.success | Should Be $false
        $result.status | Should Be "INVALID_TARGET"
    }

    It "WinRM のコマンドに構文を壊す文字列が含まれていても、このPC上では実行されないこと" {
        $marker = Join-Path $env:TEMP ("ndm_inject_" + [System.Guid]::NewGuid().ToString("N") + ".txt")
        $evil = "} } ; New-Item -ItemType File -Path '$marker' ; & { {"
        $dev = @{
            ip     = "192.0.2.11"
            name   = "WinRM-Inject-Test"
            remote = @{ enabled = $true; protocol = "winrm"; host = "ndm-test-host.invalid"; authType = "none" }
        }
        $result = Invoke-RemoteDeviceCommand -Device $dev -Action "command" -CustomCommand $evil -TimeoutSec 30
        (Test-Path $marker) | Should Be $false
        $result.success | Should Be $false
        if (Test-Path $marker) { Remove-Item $marker -Force -ErrorAction SilentlyContinue }
    }

    It "SSH パスワード用 askpass ファイルにパスワードが書き込まれないこと（環境変数経由）" {
        $src = Get-Content (Join-Path $moduleDir "RemoteExec.psm1") -Raw -Encoding UTF8
        $src | Should Match 'NDM_SSH_PASS'
        $src | Should Not Match 'echo \$safePass'
    }

}

Describe "9. カスタム {command} 置換 & WinRM 再起動コマンド解決" {
    It "カスタムコマンド内の {command} がテンプレート自身に展開されないこと" {
        $dev = @{
            ip     = "192.0.2.20"
            name   = "Custom-Tpl"
            remote = @{ enabled = $true; protocol = "custom" }
        }
        $result = Invoke-RemoteDeviceCommand -Device $dev -Action "command" -CustomCommand "echo X{command}Y {ip}" -TimeoutSec 10
        $result.success | Should Be $true
        $result.stdout | Should Be "X{command}Y 192.0.2.20"
    }

    It "WinRM 再起動で再起動コマンドが登録されていれば、shutdown.exe ではなくそのコマンドが使われること" {
        $dev = @{
            ip     = "192.0.2.21"
            name   = "WinRM-RebootCmd"
            remote = @{ enabled = $true; protocol = "winrm"; host = "ndm-test-host.invalid"; authType = "none"; rebootCommand = "Get-Date" }
        }
        $result = Invoke-RemoteDeviceCommand -Device $dev -Action "reboot" -TimeoutSec 30
        $result.command | Should Be "Get-Date"
        $result.success | Should Be $false
        $result.stderr | Should Match "ndm-test-host.invalid"
    }

    It "WinRM 再起動でパスワード認証が設定されていれば Restart-Computer をその資格情報で実行すること" {
        $dev = @{
            ip     = "192.0.2.22"
            name   = "WinRM-Cred"
            remote = @{ enabled = $true; protocol = "winrm"; host = "ndm-test-host.invalid"; authType = "password"; user = "u"; password = "p" }
        }
        $result = Invoke-RemoteDeviceCommand -Device $dev -Action "reboot" -TimeoutSec 30
        $result.command | Should Be "Restart-Computer -Force"
        $result.success | Should Be $false
        $result.stderr | Should Match "ndm-test-host.invalid"
    }
}

Describe "10. リモート実行の非同期化 (HTTP 受付ループを止めない)" {
    It "remote-exec / fetch-log の実行が Start-BackgroundScript（別スレッド）で行われること" {
        $serverSrc = Get-Content (Join-Path $projectRoot "system\Server.ps1") -Raw -Encoding UTF8
        $pattern = 'Start-BackgroundScript[^\n]*\n[^\n]*\n\s*Import-Module \$remoteExecModule[^\n]*\n\s*try \{\s*\$execResult = Invoke-RemoteDeviceCommand'
        [regex]::Matches($serverSrc, $pattern).Count | Should Be 2
    }
}

Describe "11. タイムアウト時の子プロセス終了・非 ASCII パスワード・入力値の堅牢化" {
    It "タイムアウト時に cmd.exe から起動された子プロセス (ping) も終了されること" {
        $marker = "-n 47 127.0.0.47"
        $result = Invoke-ProcessWithTimeout -FileName "cmd.exe" -Arguments "/c ping $marker > nul" -TimeoutSec 1
        $result.status | Should Be "TIMEOUT"
        Start-Sleep -Milliseconds 500
        $left = @(Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" | Where-Object { $_.CommandLine -like "*$marker*" })
        $left | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch {} }
        $left.Count | Should Be 0
    }

    function Invoke-AskPassForBytes([string]$pass) {
        $tmp = Join-Path $env:TEMP ("ndm_askpass_test_" + [guid]::NewGuid().ToString("N") + ".cmd")
        try {
            (Get-SshAskPassScript -Password $pass) | Out-File -FilePath $tmp -Encoding ASCII -Force
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $tmp
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.CreateNoWindow = $true
            $psi.EnvironmentVariables["NDM_SSH_PASS"] = $pass
            $p = [System.Diagnostics.Process]::Start($psi)
            $ms = New-Object System.IO.MemoryStream
            $p.StandardOutput.BaseStream.CopyTo($ms)
            $p.WaitForExit()
            return ,$ms.ToArray()
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It "非 ASCII を含むパスワードが UTF-8 のまま askpass から出力されること" {
        $pass = "p@ss" + [char]0x30D1 + [char]0x30B9 + [char]0x00E9 + "&%!"
        $bytes = Invoke-AskPassForBytes $pass
        $expected = [Text.Encoding]::UTF8.GetBytes($pass + "`n")
        [Convert]::ToBase64String($bytes) | Should Be ([Convert]::ToBase64String($expected))
    }

    It "ASCII のみのパスワードは従来の高速な cmd 版 askpass を使い、記号も崩れないこと" {
        $pass = 'a&b|c%d^e<f>g'
        (Get-SshAskPassScript -Password $pass) | Should Match '!NDM_SSH_PASS!'
        $text = [Text.Encoding]::ASCII.GetString((Invoke-AskPassForBytes $pass)).TrimEnd("`r", "`n")
        $text | Should Be $pass
    }

    It "timeoutSec が TryParse で検証され、数値以外でも 500 エラーにならないこと" {
        $serverSrc = Get-Content (Join-Path $projectRoot "system\Server.ps1") -Raw -Encoding UTF8
        [regex]::Matches($serverSrc, '\[int\]::TryParse\(\[string\]\$payload\.timeoutSec').Count | Should Be 2
        $serverSrc | Should Not Match '\[int\]\$payload\.timeoutSec'
    }

    It "CSRF チェック関数が使えない場合でも例外で落ちず、ブラウザからの要求は遮断されること" {
        $serverSrc = Get-Content (Join-Path $projectRoot "system\Server.ps1") -Raw -Encoding UTF8
        $serverSrc | Should Match 'try \{\s*\$apiAllowed = Test-ApiRequestAllowed'
        $serverSrc | Should Match '\$apiAllowed = \[string\]::IsNullOrEmpty\(\$reqOrigin\) -and \[string\]::IsNullOrEmpty\(\$reqFetchSite\)'
    }

    It "リモート実行の確認画面で安全チェックが最初は外れていること" {
        $html = Get-Content (Join-Path $projectRoot "system\public\index.html") -Raw -Encoding UTF8
        $html | Should Not Match 'id="confirm-safety-checkbox"[^>]*\bchecked\b'
        $js = Get-Content (Join-Path $projectRoot "system\public\app.js") -Raw -Encoding UTF8
        $js | Should Match 'confirmSafetyCheckbox\.checked = false;'
        $js | Should Not Match 'confirmSafetyCheckbox\.checked = true;'
    }
}
