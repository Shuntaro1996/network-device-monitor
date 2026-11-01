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

Export-ModuleMember -Function Get-IperfCommandLine, Rollback-FailedIperfExecution
