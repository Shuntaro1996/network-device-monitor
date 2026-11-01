# ==============================================================================
# ReportChart.Tests.ps1 - 点検報告書のグラフの横軸のテスト
# ==============================================================================
# 【初心者向けの簡単な解説】
# 記録の時刻は秒までなので、0.1 秒ごとに測ると同じ時刻の点がいくつもできます。
# これらが縦に重ならず、1 秒の中に順番に並ぶことを確かめます。
#
# 【実機への影響】
# 通信はしません。ファイルは一時フォルダの中だけで作ります。
#
# 【変更するときの注意】
# - グラフの描画そのもの (Chart.js) はブラウザでしか確かめられないので、ここでは渡すデータを確かめます。
# ==============================================================================

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$systemDir = Split-Path -Parent $here
Import-Module (Join-Path $systemDir "modules\ReportGenerator.psm1") -Force -DisableNameChecking

Describe "Get-ChartTimeAxis (グラフの横軸の位置)" {
    It "同じ秒の点を 1 秒の中に均等に並べること" {
        $result = @(Get-ChartTimeAxis -Times @("00:00:01", "00:00:01", "00:00:01", "00:00:01", "00:00:02"))
        ($result -join ",") | Should Be "1,1.25,1.5,1.75,2"
    }

    It "位置が必ず右へ進むこと (線が縦に重ならないこと)" {
        $times = @("06:11:27") * 8 + @("06:11:28") * 9 + @("06:11:29") * 10
        $result = @(Get-ChartTimeAxis -Times $times)
        $result.Count | Should Be 27
        for ($i = 1; $i -lt $result.Count; $i++) {
            ($result[$i] -gt $result[$i - 1]) | Should Be $true
        }
    }

    It "時刻が HH:mm:ss のとおりの秒数になること" {
        @(Get-ChartTimeAxis -Times @("01:02:03"))[0] | Should Be 3723
    }

    It "1 秒に 1 点のときは、秒の位置のままにすること" {
        (@(Get-ChartTimeAxis -Times @("00:00:10", "00:00:15")) -join ",") | Should Be "10,15"
    }

    It "日付が変わっても線が左へ戻らないこと" {
        (@(Get-ChartTimeAxis -Times @("23:59:59", "00:00:00")) -join ",") | Should Be "86399,86400"
    }

    It "時刻として読めないものは `$null にして、位置の数は変えないこと" {
        $result = @(Get-ChartTimeAxis -Times @("00:00:01", "", "abc", "00:00:02"))
        $result.Count | Should Be 4
        $result[0] | Should Be 1
        ($null -eq $result[1]) | Should Be $true
        ($null -eq $result[2]) | Should Be $true
        $result[3] | Should Be 2
    }

    It "入力が空でも例外にしないこと" {
        @(Get-ChartTimeAxis -Times @()).Count | Should Be 0
    }
}

Describe "Generate-SessionReportHtml (報告書に渡すグラフのデータ)" {
    It "時刻ごとの横軸の位置を報告書に含め、数値の横軸で描くこと" {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_ReportChart_$([Guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $tempDir
        try {
            $lines = @(
                "タイムスタンプ,IPアドレス,ステータス,遅延_ms,帯域_Mbps,送信_Mbps,受信_Mbps,瞬断継続_sec,ジッター_ms",
                '"2026-11-02 06:11:27","127.0.0.2","Success","7","-","-","-","",""',
                '"2026-11-02 06:11:27","127.0.0.2","Success","11","-","-","-","",""',
                '"2026-11-02 06:11:28","127.0.0.2","Success","9","-","-","-","","4"'
            )
            [System.IO.File]::WriteAllLines((Join-Path $tempDir "127.0.0.2.csv"), $lines, [System.Text.Encoding]::GetEncoding(932))
            $sync = @{
                SessionDir = $tempDir
                PSScriptRoot = $systemDir
                Devices = @("127.0.0.2")
                Status = @{ "127.0.0.2" = @{ status = "Success" } }
                Stats = @{ "127.0.0.2" = @{ Total = 3; Success = 3; Failed = 0; MinLat = 7; MaxLat = 11; SumLat = 27; LatCount = 3; MaxOutageSec = 0; Outage600msCount = 0; Outage5sCount = 0; JitterSum = 4; JitterCount = 1 } }
                DeviceName = @{ "127.0.0.2" = "Sample" }
                Group = @{ "127.0.0.2" = "T" }
                PollInterval = 100
                HighFreqTargetIps = "127.0.0.2"
            }
            $html = Generate-SessionReportHtml -sync $sync -period "Session"
            $html | Should Match '"timeX":\[22287,22287\.5,22288\]'
            $html | Should Match "type: 'linear'"
            $html | Should Not Match "allTimestamps"
        }
        finally {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
