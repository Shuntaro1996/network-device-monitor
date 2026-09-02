# ==============================================================================
# IperfRunner.psm1 - Iperf3 帯域計測実行・リアルタイム解析・ロールバックモジュール
# ==============================================================================

function Get-IperfCommandLine {
    <#
    .SYNOPSIS
        Iperf3の実行コマンド引数を構築します。
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
