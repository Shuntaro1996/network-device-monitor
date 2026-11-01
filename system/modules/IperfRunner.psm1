# ==============================================================================
# IperfRunner.psm1 - Iperf3 帯域計測実行・リアルタイム解析・ロールバックモジュール
# ==============================================================================
# 【初心者向けの簡単な解説】
# iperf3 は、2 台の間で実際にデータを流して通信速度を測るツールです。
# このファイルには、iperf3 に渡すオプションの組み立てと、失敗した計測のログを元に戻す部品があります。
#
# 【このファイルにないもの】
# iperf3 の起動と結果の読み取りは Server.ps1 の /api/iperf にあります。
# 画面で入力された追加オプションの安全確認は Common.psm1 の ConvertTo-SafeIperfOptions です。
#
# 【変更するときの注意】
# テストは tests/Tools.Tests.ps1 です。オプションの順番もテストで確かめています。
# ==============================================================================

function Get-IperfCommandLine {
    <#
    .SYNOPSIS
        Iperf3の実行コマンド引数を構築します。
    .PARAMETER target
        計測の相手 (iperf3 サーバーが動いている機器)。
    .PARAMETER proto
        tcp または udp。udp のときだけ udpBw (流す速さ) を使います。TCP は回線の限界まで流すので指定が不要です。
    .PARAMETER reverse
        $true にすると、相手からこちらへの方向を測ります (-R)。
    .OUTPUTS
        引数の文字列の配列。ここでは値の安全確認をしないので、画面の入力値は呼び出し側で確認してください。
    #>
    param(
        [string]$target,
        [int]$port = 5201,
        [int]$time = 10,
        [string]$proto = "tcp",
        [string]$udpBw = "10M",
        [bool]$reverse = $false
    )
    $argsList = @("-c", $target, "-p", $port.ToString(), "-t", $time.ToString())
    if ($proto.ToLower() -eq "udp") {
        $argsList += @("-u", "-b", $udpBw)
    }
    if ($reverse) {
        $argsList += "-R"
    }
    return $argsList
}

function Test-IperfUdpOptions {
    <#
    .SYNOPSIS
        iperf3 の追加オプションが UDP の計測を指定しているかを判定します。
    .DESCRIPTION
        UDP の計測だけ --get-server-output を自動で付けるために使います。
        iperf3 は -uR のように短いオプションをまとめて書けて、--ud のように長い名前を省略して書くこともできるので、
        空白で区切った語ごとに判定します。
    .PARAMETER Options
        安全確認 (ConvertTo-SafeIperfOptions) を通したあとの文字列。
    .OUTPUTS
        UDP なら $true、それ以外は $false。
    .NOTES
        -cmatch で大文字と小文字を区別します (-u は UDP、-U は別のオプションです)。
        長い名前は 2 文字以上の省略で判定します (--u だけでは他のオプションと区別できません)。
    #>
    param([string]$Options)
    foreach ($word in @($Options -split '\s+' | Where-Object { $_ })) {
        if ($word.StartsWith("--")) {
            $longName = $word.Substring(2)
            if ($longName.Length -ge 2 -and "udp".StartsWith($longName, [System.StringComparison]::Ordinal)) { return $true }
        }
        elseif ($word -cmatch '^-[a-zA-Z]*u') {
            return $true
        }
    }
    return $false
}

function Get-IperfOutputRoute {
    <#
    .SYNOPSIS
        iperf3 の出力の 1 行を、クライアント側とサーバー側のどちらのログに書くかを判定します。
    .DESCRIPTION
        【初心者向けの簡単な解説】
        --get-server-output を付けると、計測の終わりに次の形で出力されます。
            (クライアント側の結果)
            Server output:
            (サーバー側のログ)
            iperf Done.
        「Server output:」から「iperf Done.」の手前までがサーバー側のログです。
        サーバー側の行をクライアント側のログに混ぜると、統計サマリーが同じ計測を二重に数えるので分けます。
    .PARAMETER InServerOutput
        前の行までにサーバー側のログに入っているか。前回の結果の InServerOutput を渡します。
    .OUTPUTS
        Route ("client" / "server" / "marker") と InServerOutput を持つハッシュテーブル。
        "marker" は区切りの行で、どちらのログにも書きません。
    .NOTES
        iperf3 の出力の形が変わると判定を直す必要があります。テストは tests/Tools.Tests.ps1 と tests/IperfServerLog.Tests.ps1 です。
    #>
    param([string]$Line, [bool]$InServerOutput)
    if ($Line -match '^\s*Server output:\s*$') { return @{ Route = "marker"; InServerOutput = $true } }
    if ($InServerOutput -and $Line -match '^\s*iperf Done\.\s*$') { return @{ Route = "client"; InServerOutput = $false } }
    if ($InServerOutput) { return @{ Route = "server"; InServerOutput = $true } }
    return @{ Route = "client"; InServerOutput = $false }
}

function Rollback-FailedIperfExecution {
    <#
    .SYNOPSIS
        Iperf3実行がコネクションエラー等で失敗した場合に、
        今回の試行ログブロックを自動的にロールバック（削除）します。
    .DESCRIPTION
        つながらなかった計測の記録が残ると、レポートに不要なエラーが並ぶために元へ戻します。
    .PARAMETER preExecLines
        計測を始める前のログの全行。空なら以前の記録がないので、ログファイルごと消します。
    .OUTPUTS
        処理できたら $true、書き込みに失敗したら $false。パスが空のときは何も返しません。
    #>
    param(
        [string]$logFilePath,
        [string[]]$preExecLines
    )
    if ([string]::IsNullOrWhiteSpace($logFilePath)) { return }
    try {
        if ($null -eq $preExecLines -or $preExecLines.Count -eq 0) {
            # 過去の正常ログが存在しない新規エラーファイルの場合はファイルごと削除
            if (Test-Path $logFilePath) {
                Remove-Item -Path $logFilePath -Force -ErrorAction SilentlyContinue
            }
        } else {
            # 過去の正常ログが存在する場合は今回の試行前状態にロールバック
            $restoredContent = ($preExecLines -join "`r`n") + "`r`n"
            [System.IO.File]::WriteAllText($logFilePath, $restoredContent, [System.Text.Encoding]::UTF8)
        }
        return $true
    } catch {
        return $false
    }
}

Export-ModuleMember -Function Get-IperfCommandLine, Test-IperfUdpOptions, Get-IperfOutputRoute, Rollback-FailedIperfExecution
