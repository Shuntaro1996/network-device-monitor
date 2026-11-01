# ==============================================================================
# RemoteExec.psm1 - リモート機器制御・再起動・コマンド実行モジュール
# ==============================================================================
# 【初心者向けの簡単な解説】
# このモジュールは、登録されたネットワーク機器やサーバーに対して、
# SSH接続、Windowsリモート管理（WinRM / shutdown.exe）、またはカスタムコマンドを
# 使って「再起動」や「任意コマンドの実行」を安全に行うためのバックエンドエンジンです。
# タイムアウト監視により、機器が応答しない場合でもプロセスが残り続けるのを防ぎます。
#
# 【処理の流れ】
#   Server.ps1 の /api/device/remote-exec または /api/device/fetch-log
#   → Invoke-RemoteDeviceCommand (設定の確認と実行するコマンドの決定)
#   → Invoke-RemoteSsh / Invoke-RemoteWinRm / Invoke-RemoteCustom (プロトコルごとの実行)
#   → Invoke-ProcessWithTimeout (外部プログラムの起動と時間切れの監視)
#
# 【変更するときの注意】
# - パスワードやコマンドをコマンドラインの文字列に直接入れないでください。
#   他のプログラムから見えるうえ、記号で引数がずれて意図しないコマンドが動くおそれがあります。
#   引数は ConvertTo-ProcessArgument を通し、パスワードは環境変数で渡します。
# - 失敗は例外にせず、status に理由を入れた結果を返します。画面はこの status で表示を分けています。
# - テストは tests/RemoteExec.Tests.ps1 と tests/DeviceLog.Tests.ps1 です。
# ==============================================================================

# ── 1. 外部プロセス実行エンジン (タイムアウト強制終了 & 非同期I/O対応) ────────

function Invoke-ProcessWithTimeout {
    <#
    .SYNOPSIS
        外部プロセスを起動し、指定秒数以内に終了しない場合は強制終了（Kill）します。
        標準出力・標準エラー出力をデッドロックなしで非同期取得します。
    .PARAMETER Arguments
        コマンドライン引数の文字列。外部から来た値は ConvertTo-ProcessArgument を通してから入れてください。
    .PARAMETER EnvironmentVariables
        起動するプログラムだけに渡す環境変数。パスワードの受け渡しに使います。
    .OUTPUTS
        success / status / exitCode / stdout / stderr / executionTimeMs を持つハッシュテーブル。
        status は COMPLETED (終了コード 0)、FAILED (0 以外)、TIMEOUT、START_FAILED、ERROR のいずれかです。
    .NOTES
        時間切れのときは、途中までの出力を返さず stdout を空にします。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $false)]
        [string]$Arguments = "",

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSec = 15,

        [Parameter(Mandatory = $false)]
        [hashtable]$EnvironmentVariables = $null
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $pInfo = New-Object System.Diagnostics.ProcessStartInfo
    $pInfo.FileName = $FileName
    $pInfo.Arguments = $Arguments
    $pInfo.RedirectStandardOutput = $true
    $pInfo.RedirectStandardError = $true
    $pInfo.UseShellExecute = $false
    $pInfo.CreateNoWindow = $true

    if ($null -ne $EnvironmentVariables) {
        foreach ($key in $EnvironmentVariables.Keys) {
            $pInfo.EnvironmentVariables[$key] = [string]$EnvironmentVariables[$key]
        }
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $pInfo

    try {
        $started = $proc.Start()
        if (-not $started) {
            return @{
                success         = $false
                status          = "START_FAILED"
                exitCode        = -1
                stdout          = ""
                stderr          = "Failed to start process: $FileName"
                executionTimeMs = [int]$sw.ElapsedMilliseconds
            }
        }
    } catch {
        return @{
            success         = $false
            status          = "ERROR"
            exitCode        = -1
            stdout          = ""
            stderr          = "Process execution error: $($_.Exception.Message)"
            executionTimeMs = [int]$sw.ElapsedMilliseconds
        }
    }

    # 非同期ストリーム読み込み (バッファ充満によるデッドロック防止)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    $timeoutMs = [Math]::Max(1000, $TimeoutSec * 1000)
    $exited = $proc.WaitForExit($timeoutMs)

    if (-not $exited) {
        # cmd.exe / powershell.exe から起動された子プロセスも残さないよう、プロセスツリーごと終了する
        # (.NET Framework には Kill($true) が無いため taskkill /T を使い、失敗時は本体だけでも終了)
        try {
            $null = Start-Process -FilePath "taskkill.exe" -ArgumentList "/T /F /PID $($proc.Id)" -WindowStyle Hidden -PassThru -Wait -ErrorAction Stop
        } catch {}
        try {
            if (-not $proc.HasExited) { $proc.Kill() }
        } catch {}

        $sw.Stop()
        return @{
            success         = $false
            status          = "TIMEOUT"
            exitCode        = -1
            stdout          = ""
            stderr          = "Execution timed out after $TimeoutSec seconds. Process was terminated."
            executionTimeMs = [int]$sw.ElapsedMilliseconds
        }
    }

    $sw.Stop()
    $stdoutStr = ""
    $stderrStr = ""
    try {
        if (-not $stdoutTask.IsCompleted) { [void]$stdoutTask.Wait(5000) }
        $stdoutStr = $stdoutTask.Result
    } catch {
        try { $stdoutStr = $proc.StandardOutput.ReadToEnd() } catch {}
    }
    try {
        if (-not $stderrTask.IsCompleted) { [void]$stderrTask.Wait(2000) }
        $stderrStr = $stderrTask.Result
    } catch {
        try { $stderrStr = $proc.StandardError.ReadToEnd() } catch {}
    }

    $exitCode = $proc.ExitCode
    $proc.Close()

    return @{
        success         = ($exitCode -eq 0)
        status          = if ($exitCode -eq 0) { "COMPLETED" } else { "FAILED" }
        exitCode        = $exitCode
        stdout          = if ($null -ne $stdoutStr) { $stdoutStr.Trim() } else { "" }
        stderr          = if ($null -ne $stderrStr) { $stderrStr.Trim() } else { "" }
        executionTimeMs = [int]$sw.ElapsedMilliseconds
    }
}

# ── 2. ヘルパー: プロパティ取得 ──────────────────────────────────────────────

function Get-ObjectProperty {
    # ハッシュテーブルと、JSON から読んだオブジェクトのどちらからでも値を取り出す。なければ defaultValue を返す
    # 機器の設定は、読み込み元によって形が違うために使っている
    param($obj, [string]$propertyName, $defaultValue = $null)
    if ($null -eq $obj) { return $defaultValue }
    if ($obj -is [System.Collections.IDictionary] -or $obj -is [hashtable]) {
        if ($obj.ContainsKey($propertyName)) { return $obj[$propertyName] }
        return $defaultValue
    }
    if ($null -ne $obj.PSObject -and $null -ne $obj.PSObject.Properties[$propertyName]) {
        return $obj.$propertyName
    }
    return $defaultValue
}

function ConvertTo-ProcessArgument {
    <#
    .SYNOPSIS
        文字列を Windows のコマンドライン引数 1 個として安全に渡せる形に変換します。
    .DESCRIPTION
        【初心者向けの簡単な解説】
        ssh.exe などに渡す引数は、最終的に 1 本の文字列に連結されます。
        値の中に " や \ が含まれていると、引数の区切りがずれて別のオプションとして
        解釈されてしまう（例: ssh の -oProxyCommand でPC上のコマンドが動く）おそれがあります。
        Microsoft C ランタイムの引数解析ルールに従ってエスケープし、必ず 1 個の引数として届けます。
    #>
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value) { $Value = "" }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
        } elseif ($ch -eq '"') {
            # 引用符直前の \ は 2 倍にし、引用符自体も \" にする
            [void]$sb.Append([char]'\', ($backslashes * 2 + 1))
            [void]$sb.Append('"')
            $backslashes = 0
        } else {
            if ($backslashes -gt 0) { [void]$sb.Append([char]'\', $backslashes) }
            [void]$sb.Append($ch)
            $backslashes = 0
        }
    }
    # 閉じ引用符の直前の \ も 2 倍にする
    if ($backslashes -gt 0) { [void]$sb.Append([char]'\', ($backslashes * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Get-SshAskPassScript {
    <#
    .SYNOPSIS
        ssh のパスワード自動入力用 askpass (.cmd) の中身を返します。
    .DESCRIPTION
        【初心者向けの簡単な解説】
        パスワード本体は環境変数 NDM_SSH_PASS で渡し、このスクリプトがそれを出力します。
        cmd の echo は日本語などの非 ASCII 文字を Shift-JIS 等に変換して文字化けさせるため、
        非 ASCII 文字を含むときだけ PowerShell で UTF-8 のまま出力します（少し遅いが確実）。
    #>
    param([string]$Password)

    if ($null -ne $Password -and $Password -match '[^\x00-\x7F]') {
        return "@echo off`r`npowershell.exe -NoProfile -NonInteractive -Command `"`$b=[Text.Encoding]::UTF8.GetBytes(`$env:NDM_SSH_PASS+[char]10);`$o=[Console]::OpenStandardOutput();`$o.Write(`$b,0,`$b.Length);`$o.Flush()`"`r`n"
    }
    return "@echo off`r`nsetlocal EnableDelayedExpansion`r`necho(!NDM_SSH_PASS!`r`n"
}

# ── 3. プロトコル別リモート実行実装 ───────────────────────────────────────────

function Invoke-RemoteSsh {
    <#
    .SYNOPSIS
        Windows 標準の ssh.exe で、相手の機器でコマンドを実行します。
    .PARAMETER authType
        key は鍵ファイル、password はパスワード。それ以外は認証情報なしで試します。
    .OUTPUTS
        Invoke-ProcessWithTimeout と同じ形の結果。
    .NOTES
        - 初めて接続する相手の鍵は自動で登録します (StrictHostKeyChecking=accept-new)。
          登録済みの鍵が変わったときは、なりすましの可能性があるので接続を拒否します。
        - パスワード認証では、パスワードを受け渡す小さな .cmd を一時フォルダに作り、終わったら消します。
          .cmd にパスワード自体は書きません。
        - BatchMode=yes は、入力を求められたときに待たず失敗させる設定です。
    #>
    param(
        [string]$hostName,
        [int]$port,
        [string]$user,
        [string]$password,
        [string]$keyPath,
        [string]$authType,
        [string]$command,
        [int]$timeoutSec
    )

    # Windows 標準 OpenSSH クライアントを検出
    $sshCmd = "ssh.exe"
    if (Test-Path "C:\Windows\System32\OpenSSH\ssh.exe") {
        $sshCmd = "C:\Windows\System32\OpenSSH\ssh.exe"
    }

    $sshArgs = [System.Collections.Generic.List[string]]::new()
    $sshArgs.Add("-o StrictHostKeyChecking=accept-new")
    $sshArgs.Add("-o ConnectTimeout=$timeoutSec")
    $sshArgs.Add("-o ServerAliveInterval=5")
    $sshArgs.Add("-o ServerAliveCountMax=2")

    if ($port -gt 0 -and $port -ne 22) {
        $sshArgs.Add("-p $port")
    }

    # 接続先やユーザー名が "-" で始まると ssh のオプションとして解釈されるため拒否
    if ($hostName.StartsWith("-") -or $user.StartsWith("-")) {
        return @{
            success         = $false
            status          = "INVALID_TARGET"
            exitCode        = -1
            stdout          = ""
            stderr          = "Host name and user name must not start with '-'."
            executionTimeMs = 0
        }
    }

    $envVars = @{}
    $tempAskPass = $null

    try {
        if ($authType -eq "key" -and -not [string]::IsNullOrWhiteSpace($keyPath)) {
            $sshArgs.Add("-i " + (ConvertTo-ProcessArgument $keyPath))
            $sshArgs.Add("-o BatchMode=yes")
        } elseif ($authType -eq "password" -and -not [string]::IsNullOrWhiteSpace($password)) {
            # OpenSSH 8.4+ / Windows OpenSSH でのパスワード自動投入 (SSH_ASKPASS_REQUIRE=force)
            # パスワードはファイルに書かず環境変数で渡し、遅延展開 (!VAR!) で出力するため & | % などの記号も安全
            $tempAskPass = Join-Path $env:TEMP ("ndm_askpass_" + [System.Guid]::NewGuid().ToString("N") + ".cmd")
            (Get-SshAskPassScript -Password $password) | Out-File -FilePath $tempAskPass -Encoding ASCII -Force
            $envVars["NDM_SSH_PASS"] = $password
            $envVars["SSH_ASKPASS"] = $tempAskPass
            $envVars["SSH_ASKPASS_REQUIRE"] = "force"
            $envVars["DISPLAY"] = "1"
        } else {
            $sshArgs.Add("-o BatchMode=yes")
        }

        $destination = if (-not [string]::IsNullOrWhiteSpace($user)) { "$user@$hostName" } else { $hostName }
        $sshArgs.Add((ConvertTo-ProcessArgument $destination))
        $sshArgs.Add((ConvertTo-ProcessArgument $command))

        $argumentsString = [string]::Join(" ", $sshArgs)
        $procResult = Invoke-ProcessWithTimeout -FileName $sshCmd -Arguments $argumentsString -TimeoutSec $timeoutSec -EnvironmentVariables $envVars
        return $procResult
    } finally {
        if ($null -ne $tempAskPass -and (Test-Path $tempAskPass)) {
            try { Remove-Item -Path $tempAskPass -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

function Invoke-RemoteWinRm {
    <#
    .SYNOPSIS
        Windows のリモート管理 (WinRM) で、相手の Windows でコマンドを実行します。再起動にも使います。
    .PARAMETER rebootCommand
        再起動のときに使うコマンド。空なら、下のコメントの順で再起動の方法を選びます。
    .OUTPUTS
        Invoke-ProcessWithTimeout と同じ形の結果。
    .NOTES
        引数の port は現在使っていません (Invoke-Command は既定のポートで接続します)。
        パスワードは環境変数で渡し、起動した PowerShell の中で読み取ったらすぐ消します。
    #>
    param(
        [string]$hostName,
        [int]$port,
        [string]$user,
        [string]$password,
        [string]$authType,
        [string]$action,
        [string]$command,
        [string]$rebootCommand,
        [int]$timeoutSec
    )

    $hasCredential = ($authType -eq "password" -and -not [string]::IsNullOrWhiteSpace($user) -and -not [string]::IsNullOrWhiteSpace($password))

    # 再起動アクション:
    #  - 再起動コマンドが登録されていれば、それを WinRM (Invoke-Command) で実行
    #  - 未登録でもパスワード認証が設定されていれば、その資格情報で Restart-Computer を実行
    #  - どちらもなければ、このPCのログインユーザー権限で shutdown.exe /m \\host を実行
    if ($action -eq "reboot") {
        if (-not [string]::IsNullOrWhiteSpace($rebootCommand)) {
            $command = $rebootCommand
        } elseif ($hasCredential) {
            $command = "Restart-Computer -Force"
        }
    }
    if ($action -eq "reboot" -and [string]::IsNullOrWhiteSpace($rebootCommand) -and -not $hasCredential) {
        $shutdownCmd = "shutdown.exe"
        if (Test-Path "C:\Windows\System32\shutdown.exe") {
            $shutdownCmd = "C:\Windows\System32\shutdown.exe"
        }
        $args = "/m " + (ConvertTo-ProcessArgument "\\$hostName") + " /r /t 0 /f /d p:4:1 /c `"Remote reboot initiated by NetworkDeviceMonitor`""
        return (Invoke-ProcessWithTimeout -FileName $shutdownCmd -Arguments $args -TimeoutSec $timeoutSec)
    }

    # 任意コマンドアクション: powershell.exe / Invoke-Command
    $psCmd = "powershell.exe"
    if (Test-Path "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe") {
        $psCmd = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    }

    # 実行スクリプトは固定文にし、接続先・認証情報・コマンドは環境変数で渡す
    # （コマンド文字列がスクリプトの構文に混ざらないため、このPC上で余計な処理が動くことを防ぐ）
    $envVars = @{
        NDM_REMOTE_HOST = $hostName
        NDM_REMOTE_CMD  = $command
    }
    if ($hasCredential) {
        $envVars["NDM_REMOTE_USER"] = $user
        $envVars["NDM_REMOTE_PASS"] = $password
    }

    # -EncodedCommand はエラー出力が CLIXML 形式になるため、固定文を -Command で渡す（利用者の入力は含まれない）
    $sbText = @(
        '$ProgressPreference = ''SilentlyContinue'''
        '$h = $env:NDM_REMOTE_HOST; $c = $env:NDM_REMOTE_CMD; $u = $env:NDM_REMOTE_USER; $p = $env:NDM_REMOTE_PASS'
        'Remove-Item Env:NDM_REMOTE_HOST, Env:NDM_REMOTE_CMD, Env:NDM_REMOTE_USER, Env:NDM_REMOTE_PASS -ErrorAction SilentlyContinue'
        '$icParams = @{ ComputerName = $h; ScriptBlock = [ScriptBlock]::Create($c) }'
        'if (-not [string]::IsNullOrEmpty($u) -and -not [string]::IsNullOrEmpty($p)) { $sec = ConvertTo-SecureString -String $p -AsPlainText -Force; $icParams.Credential = New-Object System.Management.Automation.PSCredential($u, $sec) }'
        'Invoke-Command @icParams'
    ) -join '; '

    $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command " + (ConvertTo-ProcessArgument $sbText)
    return (Invoke-ProcessWithTimeout -FileName $psCmd -Arguments $arguments -TimeoutSec $timeoutSec -EnvironmentVariables $envVars)
}

function Invoke-RemoteCustom {
    <#
    .SYNOPSIS
        登録されたコマンドを、このPC上で cmd.exe から実行します (相手の機器ではありません)。
    .OUTPUTS
        Invoke-ProcessWithTimeout と同じ形の結果。
    .NOTES
        【注意】{ip} {name} {user} {port} は、エスケープせず文字のまま置き換えます。
        機器名などに & や | が含まれると、cmd.exe が別のコマンドとして実行します。
        信頼できる設定だけで使う前提の機能です。
    #>
    param(
        [string]$hostName,
        [string]$deviceName,
        [int]$port,
        [string]$user,
        [string]$commandTemplate,
        [int]$timeoutSec
    )

    # 注意: custom プロトコルは「このPC上で」cmd.exe 経由でコマンドを実行する仕様です。
    # 外部サイトからの API 呼び出しは Server.ps1 の CSRF ガード (Test-ApiRequestAllowed) で拒否しています。
    # テンプレート変数の置換 ({ip}, {name}, {user}, {port})
    # ※ {command} はコマンド自身を指すため置換しない（以前はテンプレート全体が自分自身に展開されていた）
    $resolvedCmd = $commandTemplate
    $resolvedCmd = $resolvedCmd.Replace("{ip}", $hostName)
    $resolvedCmd = $resolvedCmd.Replace("{name}", $deviceName)
    $resolvedCmd = $resolvedCmd.Replace("{user}", $user)
    $resolvedCmd = $resolvedCmd.Replace("{port}", [string]$port)

    # cmd.exe /s /c 経由で実行
    $cmdExe = "cmd.exe"
    if (Test-Path "C:\Windows\System32\cmd.exe") {
        $cmdExe = "C:\Windows\System32\cmd.exe"
    }
    $args = "/s /c `"$resolvedCmd`""
    return (Invoke-ProcessWithTimeout -FileName $cmdExe -Arguments $args -TimeoutSec $timeoutSec)
}

# ── 4. メイン公開関数: Invoke-RemoteDeviceCommand ────────────────────────────

function Invoke-RemoteDeviceCommand {
    <#
    .SYNOPSIS
        対象機器に対して、設定されたプロトコル（SSH / WinRM / Custom）に基づき
        リモート再起動または任意コマンドを実行し、統一された結果オブジェクトを返します。
    .PARAMETER Device
        機器の設定。remote の中、または直下に enabled / protocol / host / user などを持ちます。
        password は復号したものを渡します (復号は呼び出し側の Server.ps1 で行います)。
    .PARAMETER Action
        reboot は再起動、command はコマンド実行です。
    .PARAMETER CommandId
        登録済みコマンドの ID。CustomCommand があれば、そちらを優先します。
    .PARAMETER TimeoutSec
        時間切れまでの秒数。1〜300 の範囲外なら 15 秒にします。
    .OUTPUTS
        success / status / exitCode / target / deviceName / remoteType / action / command / stdout / stderr /
        executionTimeMs / timestamp を持つハッシュテーブル。実行前に止めたときの status は次のとおりです。
        REMOTE_DISABLED / INVALID_TARGET / NO_REBOOT_COMMAND / COMMAND_NOT_FOUND / NO_COMMAND_SPECIFIED / UNSUPPORTED_PROTOCOL
    .NOTES
        status を増やしたら、画面 (app.js) の表示も確認してください。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Device,

        [Parameter(Mandatory = $true)]
        [ValidateSet("reboot", "command")]
        [string]$Action,

        [Parameter(Mandatory = $false)]
        [string]$CommandId,

        [Parameter(Mandatory = $false)]
        [string]$CustomCommand,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSec = 15
    )

    $targetIp = Get-ObjectProperty $Device "ip" ""
    $deviceName = Get-ObjectProperty $Device "name" $targetIp

    # remote 設定オブジェクトの抽出 (ネストオブジェクトまたは直下プロパティに対応)
    $remoteConfig = Get-ObjectProperty $Device "remote" $null
    if ($null -eq $remoteConfig) {
        $remoteConfig = $Device
    }

    $enabled = Get-ObjectProperty $remoteConfig "enabled" $false
    $isEnabled = [bool]($enabled -is [bool] -and $enabled -or ("$enabled" -ne "false" -and "$enabled" -ne "" -and $enabled -ne $false))

    $protocol = [string](Get-ObjectProperty $remoteConfig "protocol" "ssh")
    if ([string]::IsNullOrWhiteSpace($protocol)) { $protocol = "ssh" }
    $protocol = $protocol.ToLower().Trim()

    $hostName = [string](Get-ObjectProperty $remoteConfig "host" "")
    if ([string]::IsNullOrWhiteSpace($hostName)) { $hostName = $targetIp }

    $port = [int](Get-ObjectProperty $remoteConfig "port" 0)
    if ($port -le 0) {
        if ($protocol -eq "ssh") { $port = 22 }
        elseif ($protocol -eq "winrm") { $port = 5985 }
        else { $port = 0 }
    }

    $authType = [string](Get-ObjectProperty $remoteConfig "authType" "none")
    $user     = [string](Get-ObjectProperty $remoteConfig "user" "")
    $password = [string](Get-ObjectProperty $remoteConfig "password" "")
    $keyPath  = [string](Get-ObjectProperty $remoteConfig "keyPath" "")
    $rebootCmd = [string](Get-ObjectProperty $remoteConfig "rebootCommand" "")
    $commands = Get-ObjectProperty $remoteConfig "commands" @()

    $nowTs = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    # リモート制御が無効化されている場合の安全ガード
    if (-not $isEnabled) {
        return @{
            success         = $false
            status          = "REMOTE_DISABLED"
            exitCode        = -1
            target          = $targetIp
            deviceName      = $deviceName
            remoteType      = $protocol
            action          = $Action
            command         = ""
            stdout          = ""
            stderr          = "Remote management is disabled for device '$deviceName' ($targetIp)."
            executionTimeMs = 0
            timestamp       = $nowTs
        }
    }

    # 対象ホスト名・IPが未設定の場合
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        return @{
            success         = $false
            status          = "INVALID_TARGET"
            exitCode        = -1
            target          = $targetIp
            deviceName      = $deviceName
            remoteType      = $protocol
            action          = $Action
            command         = ""
            stdout          = ""
            stderr          = "No valid target IP address or hostname specified."
            executionTimeMs = 0
            timestamp       = $nowTs
        }
    }

    # 実行対象コマンドの解決
    $resolvedCommand = ""
    if ($Action -eq "reboot") {
        if ($protocol -eq "ssh") {
            $resolvedCommand = if (-not [string]::IsNullOrWhiteSpace($rebootCmd)) { $rebootCmd } else { "sudo reboot" }
        } elseif ($protocol -eq "winrm") {
            $resolvedCommand = if (-not [string]::IsNullOrWhiteSpace($rebootCmd)) { $rebootCmd }
                elseif ($authType -eq "password" -and -not [string]::IsNullOrWhiteSpace($user) -and -not [string]::IsNullOrWhiteSpace($password)) { "Restart-Computer -Force" }
                else { "shutdown.exe /m \\$hostName /r /t 0 /f" }
        } elseif ($protocol -eq "custom") {
            if ([string]::IsNullOrWhiteSpace($rebootCmd)) {
                return @{
                    success         = $false
                    status          = "NO_REBOOT_COMMAND"
                    exitCode        = -1
                    target          = $targetIp
                    deviceName      = $deviceName
                    remoteType      = $protocol
                    action          = $Action
                    command         = ""
                    stdout          = ""
                    stderr          = "No rebootCommand configured for custom protocol on device '$deviceName'."
                    executionTimeMs = 0
                    timestamp       = $nowTs
                }
            }
            $resolvedCommand = $rebootCmd
        }
    } else {
        # Action -eq "command"
        if (-not [string]::IsNullOrWhiteSpace($CustomCommand)) {
            $resolvedCommand = $CustomCommand
        } elseif (-not [string]::IsNullOrWhiteSpace($CommandId)) {
            $found = $false
            if ($null -ne $commands) {
                foreach ($cmdItem in $commands) {
                    $cId = Get-ObjectProperty $cmdItem "id" ""
                    if ($cId -eq $CommandId) {
                        $resolvedCommand = [string](Get-ObjectProperty $cmdItem "command" "")
                        $found = $true
                        break
                    }
                }
            }
            if (-not $found -or [string]::IsNullOrWhiteSpace($resolvedCommand)) {
                return @{
                    success         = $false
                    status          = "COMMAND_NOT_FOUND"
                    exitCode        = -1
                    target          = $targetIp
                    deviceName      = $deviceName
                    remoteType      = $protocol
                    action          = $Action
                    command         = ""
                    stdout          = ""
                    stderr          = "Preset command ID '$CommandId' was not found for device '$deviceName'."
                    executionTimeMs = 0
                    timestamp       = $nowTs
                }
            }
        } else {
            return @{
                success         = $false
                status          = "NO_COMMAND_SPECIFIED"
                exitCode        = -1
                target          = $targetIp
                deviceName      = $deviceName
                remoteType      = $protocol
                action          = $Action
                command         = ""
                stdout          = ""
                stderr          = "Neither commandId nor customCommand was specified for execution."
                executionTimeMs = 0
                timestamp       = $nowTs
            }
        }
    }

    # タイムアウト値の安全性バリデーション (デフォルト15秒, 範囲 1〜300秒)
    if ($TimeoutSec -le 0 -or $TimeoutSec -gt 300) { $TimeoutSec = 15 }

    # プロトコル別ハンドラ呼び出し
    $execResult = $null
    switch ($protocol) {
        "ssh" {
            $execResult = Invoke-RemoteSsh -hostName $hostName -port $port -user $user -password $password -keyPath $keyPath -authType $authType -command $resolvedCommand -timeoutSec $TimeoutSec
        }
        "winrm" {
            $execResult = Invoke-RemoteWinRm -hostName $hostName -port $port -user $user -password $password -authType $authType -action $Action -command $resolvedCommand -rebootCommand $rebootCmd -timeoutSec $TimeoutSec
        }
        "custom" {
            $execResult = Invoke-RemoteCustom -hostName $hostName -deviceName $deviceName -port $port -user $user -commandTemplate $resolvedCommand -timeoutSec $TimeoutSec
        }
        default {
            return @{
                success         = $false
                status          = "UNSUPPORTED_PROTOCOL"
                exitCode        = -1
                target          = $targetIp
                deviceName      = $deviceName
                remoteType      = $protocol
                action          = $Action
                command         = $resolvedCommand
                stdout          = ""
                stderr          = "Unsupported remote protocol: '$protocol'. Supported protocols are 'ssh', 'winrm', and 'custom'."
                executionTimeMs = 0
                timestamp       = $nowTs
            }
        }
    }

    return @{
        success         = [bool]$execResult.success
        status          = [string]$execResult.status
        exitCode        = [int]$execResult.exitCode
        target          = [string]$targetIp
        deviceName      = [string]$deviceName
        remoteType      = [string]$protocol
        action          = [string]$Action
        command         = [string]$resolvedCommand
        stdout          = [string]$execResult.stdout
        stderr          = [string]$execResult.stderr
        executionTimeMs = [int]$execResult.executionTimeMs
        timestamp       = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
}

# ── 3. 機器ログ取得用コマンドプリセット管理 ────────────────────────────────────

function Get-DeviceLogPresets {
    <#
    .SYNOPSIS
        機器種別およびOSごとの推奨ログ取得コマンドプリセット一覧を返します。
    .DESCRIPTION
        Cisco, Yamaha, Linux (journalctl, dmesg, syslog), Windows (Get-WinEvent, Get-EventLog),
        およびカスタムコマンド入力の定義リストを配列で返却します。
    #>
    [CmdletBinding()]
    param()

    return @(
        @{
            id          = "cisco_show_logging"
            name        = "Cisco / ネットワーク機器: show logging"
            command     = "show logging"
            category    = "network"
            protocol    = "ssh"
            description = "Ciscoルーター・スイッチの内部ログバッファを出力します"
        },
        @{
            id          = "yamaha_show_log"
            name        = "Yamaha ルーター: show log"
            command     = "show log"
            category    = "network"
            protocol    = "ssh"
            description = "ヤマハルーター（RTX/NVR等）のシステムログを出力します"
        },
        @{
            id          = "linux_journalctl"
            name        = "Linux: journalctl (直近200行)"
            command     = "journalctl -n 200 --no-pager"
            category    = "linux"
            protocol    = "ssh"
            description = "systemd標準ログの最新200行を取得します"
        },
        @{
            id          = "linux_dmesg"
            name        = "Linux: カーネルメッセージ (dmesg)"
            command     = "dmesg -T | tail -n 200"
            category    = "linux"
            protocol    = "ssh"
            description = "カーネル起動・ハードウェア認識ログ最新200行を取得します"
        },
        @{
            id          = "linux_syslog"
            name        = "Linux: システムログ (/var/log/syslog)"
            command     = "tail -n 200 /var/log/syslog"
            category    = "linux"
            protocol    = "ssh"
            description = "Ubuntu/Debian系などのシステムログ最新200行を取得します"
        },
        @{
            id          = "windows_winevent_sys"
            name        = "Windows: システムイベントログ (直近100件)"
            command     = "Get-WinEvent -LogName System -MaxEvents 100 | Format-Table TimeCreated, Id, LevelDisplayName, Message -AutoSize | Out-String -Width 4096"
            category    = "windows"
            protocol    = "winrm"
            description = "Windowsシステムイベントログの最新100件を取得します"
        },
        @{
            id          = "windows_winevent_app"
            name        = "Windows: アプリケーションイベントログ (直近100件)"
            command     = "Get-WinEvent -LogName Application -MaxEvents 100 | Format-Table TimeCreated, Id, LevelDisplayName, Message -AutoSize | Out-String -Width 4096"
            category    = "windows"
            protocol    = "winrm"
            description = "Windowsアプリケーションイベントログの最新100件を取得します"
        },
        @{
            id          = "windows_eventlog_sys"
            name        = "Windows: 従来イベントログ (Get-EventLog System)"
            command     = "Get-EventLog -LogName System -Newest 100 | Format-Table TimeGenerated, EventID, EntryType, Message -AutoSize | Out-String -Width 4096"
            category    = "windows"
            protocol    = "winrm"
            description = "Windows旧式イベントログ (Get-EventLog) の最新100件を取得します"
        },
        @{
            id          = "custom"
            name        = "カスタムコマンド入力"
            command     = ""
            category    = "custom"
            protocol    = "custom"
            description = "任意のログ調査コマンドを入力して実行します"
        }
    )
}

# ── 4. ログファイル保存ヘルパー (自己記述型ヘッダー & UTF-8保存) ───────────────

function Save-DeviceLogFile {
    <#
    .SYNOPSIS
        取得した機器ログを Reports/device_logs/{IP}_{timestamp}.log に自己記述型ヘッダー付きで保存します。
    .PARAMETER ReportsDirectory
        Reports フォルダの絶対パスまたは相対パス。
    .PARAMETER Ip
        対象機器のIPアドレス。
    .PARAMETER DeviceName
        対象機器の表示名。
    .PARAMETER Protocol
        リモート接続プロトコル (ssh, winrm, custom等)。
    .PARAMETER Command
        実行したログ取得コマンド。
    .PARAMETER LogContent
        取得されたログテキスト (stdout)。
    .PARAMETER Status
        実行ステータス (COMPLETED, TIMEOUT, FAILED等)。
    .PARAMETER ExitCode
        終了コード。
    .PARAMETER DurationMs
        実行所要時間 (ミリ秒)。
    .PARAMETER Timestamp
        ファイル名に使用するタイムスタンプ文字列 (省略時は yyyyMMdd_HHmmss)。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReportsDirectory,

        [Parameter(Mandatory = $true)]
        [string]$Ip,

        [Parameter(Mandatory = $false)]
        [string]$DeviceName = "",

        [Parameter(Mandatory = $false)]
        [string]$Protocol = "unknown",

        [Parameter(Mandatory = $false)]
        [string]$Command = "",

        [Parameter(Mandatory = $false)]
        [string]$LogContent = "",

        [Parameter(Mandatory = $false)]
        [string]$Status = "COMPLETED",

        [Parameter(Mandatory = $false)]
        [int]$ExitCode = 0,

        [Parameter(Mandatory = $false)]
        [int]$DurationMs = 0,

        [Parameter(Mandatory = $false)]
        [string]$Timestamp = $null
    )

    try {
        if ([string]::IsNullOrWhiteSpace($ReportsDirectory)) {
            $ReportsDirectory = "Reports"
        }

        $deviceLogsDir = Join-Path $ReportsDirectory "device_logs"
        if (-not (Test-Path $deviceLogsDir)) {
            New-Item -ItemType Directory -Path $deviceLogsDir -Force | Out-Null
        }

        $safeIp = $Ip -replace '[\\/:*?"<>|]', '_'
        if ([string]::IsNullOrWhiteSpace($safeIp)) { $safeIp = "unknown_ip" }

        $now = Get-Date
        $tsStr = if (-not [string]::IsNullOrWhiteSpace($Timestamp)) {
            $Timestamp -replace '[\\/:*?"<>|]', '_'
        } else {
            $now.ToString("yyyyMMdd_HHmmss")
        }

        $fileName = "${safeIp}_${tsStr}.log"
        $filePath = Join-Path $deviceLogsDir $fileName
        $relativeFilePath = "Reports/device_logs/$fileName"

        $content = if ($null -ne $LogContent) { [string]$LogContent } else { "" }

        # 5MB disk write guard
        $maxDiskBytes = 5 * 1024 * 1024
        $isDiskTruncated = $false
        if ($content.Length -gt $maxDiskBytes) {
            $content = $content.Substring(0, $maxDiskBytes) + "`r`n`r`n--- [DISK LOG TRUNCATED: 5MB超過のため保存を制限しました] ---"
            $isDiskTruncated = $true
        }

        $rawSizeBytes = [System.Text.Encoding]::UTF8.GetByteCount($content)
        $lineCount = if ([string]::IsNullOrEmpty($content)) { 0 } else { ($content -split "`r?`n").Count }
        $devName = if (-not [string]::IsNullOrWhiteSpace($DeviceName)) { $DeviceName } else { $Ip }
        $headerTs = $now.ToString("yyyy-MM-dd HH:mm:ss")

        $header = @"
================================================================================
 Network Device Monitor - Remote Device Log
 Device: $devName ($Ip)
 Protocol: $Protocol
 Command: $Command
 Timestamp: $headerTs
 Status: $Status | ExitCode: $ExitCode | Duration: ${DurationMs}ms
 Lines: $lineCount | Size: $rawSizeBytes bytes
================================================================================
[OUTPUT]

"@

        $fullLogText = $header + $content
        [System.IO.File]::WriteAllText($filePath, $fullLogText, [System.Text.Encoding]::UTF8)

        return @{
            success         = $true
            fileName        = $fileName
            filePath        = $relativeFilePath
            fullPath        = $filePath
            lineCount       = $lineCount
            sizeBytes       = $rawSizeBytes
            timestamp       = $headerTs
            isDiskTruncated = $isDiskTruncated
        }
    } catch {
        return @{
            success         = $false
            error           = $_.Exception.Message
            fileName        = ""
            filePath        = ""
            fullPath        = ""
            lineCount       = 0
            sizeBytes       = 0
            timestamp       = ""
            isDiskTruncated = $false
        }
    }
}

Export-ModuleMember -Function Invoke-RemoteDeviceCommand, Get-DeviceLogPresets, Save-DeviceLogFile, Get-ObjectProperty, ConvertTo-ProcessArgument, Get-SshAskPassScript, Invoke-ProcessWithTimeout
