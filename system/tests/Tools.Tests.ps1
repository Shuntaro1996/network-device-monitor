# ==============================================================================
# Tools.Tests.ps1 - 帯域計測の部品と文字コード検査ツールの単体テスト
# ==============================================================================
# 【初心者向けの簡単な解説】
# 次の 2 つを、一時フォルダの中だけで確かめます。実際の iperf3 は起動しません。
# - IperfRunner.psm1: iperf3 に渡すオプションの組み立てと、失敗した計測のログの巻き戻し
# - Ensure-Utf8Bom.ps1: PowerShell 5.1 の文字化けを防ぐ BOM (ファイル先頭の目印) の付与
#
# 【変更するときの注意】
# - Ensure-Utf8Bom.ps1 はファイルを書き換えるツールです。必ず一時フォルダへコピーしてから実行してください。
#   そのまま実行すると、このプロジェクトのファイルが対象になります。
# - 日本語の確認文字は、このファイル自体の文字コードに影響されないよう [char] で組み立てています。
# ==============================================================================

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$systemDir = Split-Path -Parent $here
Import-Module (Join-Path $systemDir "modules\IperfRunner.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $systemDir "modules\Common.psm1") -Force -DisableNameChecking

function New-TestFolder {
    # テストごとに重ならない一時フォルダを作る
    $path = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_Tools_$(Get-Random)"
    $null = New-Item -ItemType Directory -Path $path -Force
    return $path
}

Describe "Stop-All.bat (機器ごとの監視ウィンドウの一括終了)" {
    It "Stop-All.bat と同じフォルダに停止の合図を置くこと" {
        # 実際のフォルダに合図を残さないよう、一時フォルダへコピーして実行する
        $dir = New-TestFolder
        try {
            Copy-Item -LiteralPath (Join-Path $systemDir "tools\Stop-All.bat") -Destination $dir
            $null = & cmd.exe /c (Join-Path $dir "Stop-All.bat") 2>&1
            (Test-Path -LiteralPath (Join-Path $dir ".stop_signal")) | Should Be $true
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "合図を読む側も Stop-All.bat と同じフォルダを見ていること" {
        foreach ($name in @("Launcher.ps1", "Monitor-SingleDevice.ps1")) {
            [System.IO.File]::ReadAllText((Join-Path $systemDir "tools\$name"), [System.Text.Encoding]::UTF8) | Should Match 'Join-Path \$PSScriptRoot "\.stop_signal"'
        }
    }
}

Describe "system フォルダの整理 (道具から見たファイルの場所)" {
    It "Watchdog.ps1 が呼ぶ起動前の点検ツールが tools フォルダにあること" {
        $watchdog = [System.IO.File]::ReadAllText((Join-Path $systemDir "Watchdog.ps1"), [System.Text.Encoding]::UTF8)
        foreach ($name in @("Ensure-Utf8Bom.ps1", "Check-Prerequisites.ps1")) {
            $watchdog | Should Match ([regex]::Escape("`"tools\$name`""))
            (Test-Path -LiteralPath (Join-Path $systemDir "tools\$name")) | Should Be $true
        }
    }

    It "tools のスクリプトが 1 つ上の system フォルダを基準にしていること" {
        $prereq = [System.IO.File]::ReadAllText((Join-Path $systemDir "tools\Check-Prerequisites.ps1"), [System.Text.Encoding]::UTF8)
        $prereq | Should Match ([regex]::Escape('$scriptDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)'))
        $bandwidth = [System.IO.File]::ReadAllText((Join-Path $systemDir "tools\Start-BandwidthServer.ps1"), [System.Text.Encoding]::UTF8)
        $bandwidth | Should Match ([regex]::Escape('$SystemDir  = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)'))
        $launcher = [System.IO.File]::ReadAllText((Join-Path $systemDir "tools\Launcher.ps1"), [System.Text.Encoding]::UTF8)
        $launcher | Should Match ([regex]::Escape('"system\tools\Monitor-SingleDevice.ps1"'))
        $launcher | Should Match ([regex]::Escape('"system\devices.json"'))
    }

    It "Service-Setup.bat がプロジェクトの最上位の Start-Monitor.bat を登録すること" {
        $setup = [System.IO.File]::ReadAllText((Join-Path $systemDir "tools\Service-Setup.bat"), [System.Text.Encoding]::GetEncoding(932))
        $setup | Should Match ([regex]::Escape('%~dp0..\..\Start-Monitor.bat'))
        $setup | Should Not Match ([regex]::Escape('%~dp0..\Start-Monitor.bat'))
    }
}

Describe "IperfRunner Get-IperfCommandLine (iperf3 のオプションの組み立て)" {
    It "指定がなければ TCP の既定値にすること" {
        (Get-IperfCommandLine -target "10.0.0.1") -join " " | Should Be "-c 10.0.0.1 -p 5201 -t 10"
    }

    It "UDP の帯域と逆方向の指定を追加すること (大文字の UDP でも認識する)" {
        (Get-IperfCommandLine -target "h" -port 6000 -time 3 -proto "UDP" -udpBw "5M" -reverse $true) -join " " | Should Be "-c h -p 6000 -t 3 -u -b 5M -R"
    }

    It "TCP のときは UDP の帯域の指定を使わないこと" {
        (Get-IperfCommandLine -target "h" -udpBw "5M") -join " " | Should Be "-c h -p 5201 -t 10"
    }
}

Describe "ConvertTo-SafeIperfOptions (iperf3 の追加オプションの安全確認)" {
    It "計測に使う普通のオプションは残すこと" {
        ConvertTo-SafeIperfOptions -Options "-R -P 4 -u -b 10M" | Should Be "-R -P 4 -u -b 10M"
        ConvertTo-SafeIperfOptions -Options "--reverse --parallel 2 --format m --port 5202 --length 1K" | Should Be "--reverse --parallel 2 --format m --port 5202 --length 1K"
    }

    It "小文字の -f と -i は取り除かないこと (大文字の -F と -I とは別のオプション)" {
        ConvertTo-SafeIperfOptions -Options "-f m -i 1" | Should Be "-f m -i 1"
    }

    It "ファイルを扱うオプションを、値と一緒に取り除くこと" {
        ConvertTo-SafeIperfOptions -Options "-F secret -R" | Should Be "-R"
        ConvertTo-SafeIperfOptions -Options "--file secret" | Should Be ""
        ConvertTo-SafeIperfOptions -Options "--logfile out -u" | Should Be "-u"
        ConvertTo-SafeIperfOptions -Options "--pidfile p" | Should Be ""
        ConvertTo-SafeIperfOptions -Options "-I p -t 3" | Should Be "-t 3"
    }

    It "まとめ書きと値の続け書きも取り除くこと" {
        ConvertTo-SafeIperfOptions -Options "-RF secret -P 2" | Should Be "-P 2"
        ConvertTo-SafeIperfOptions -Options "-Fsecret" | Should Be ""
    }

    It "長い名前の省略形も取り除くこと" {
        ConvertTo-SafeIperfOptions -Options "--log out" | Should Be ""
        ConvertTo-SafeIperfOptions -Options "--fi secret" | Should Be ""
        ConvertTo-SafeIperfOptions -Options "--pid p" | Should Be ""
    }

    It "コマンドをつなぐ記号とパスの記号を消すこと" {
        ConvertTo-SafeIperfOptions -Options "-R; del & calc | x" | Should Be "-R del calc x"
        ConvertTo-SafeIperfOptions -Options "-b ..\10M" | Should Be "-b 10M"
    }

    It "空の入力は空文字を返すこと" {
        ConvertTo-SafeIperfOptions -Options "" | Should Be ""
    }

    It "Server.ps1 がこの関数を使っていること" {
        $serverSource = [System.IO.File]::ReadAllText((Join-Path $systemDir "Server.ps1"), [System.Text.Encoding]::UTF8)
        $serverSource | Should Match 'ConvertTo-SafeIperfOptions -Options \$customOpts'
    }
}

Describe "IperfRunner Test-IperfUdpOptions (UDP の計測かの判定)" {
    It "UDP の書き方をすべて認識すること (まとめ書きと省略形を含む)" {
        foreach ($options in @("-u", "-u -b 10M", "-R -u", "-uR", "-Ru", "--udp", "--ud -b 1M")) {
            Test-IperfUdpOptions -Options $options | Should Be $true
        }
    }

    It "UDP 以外は認識しないこと (値に含まれる u や、大文字の -U も対象外)" {
        foreach ($options in @("", "-R", "-P 4", "-b 10M", "--parallel 2", "--username u", "-U", "--u", "user")) {
            Test-IperfUdpOptions -Options $options | Should Be $false
        }
    }
}

Describe "IperfRunner Get-IperfOutputRoute (サーバー側のログの振り分け)" {
    It "iperf3 の出力の順番どおりに、クライアント側とサーバー側へ分けること" {
        $inServer = $false
        $routes = foreach ($line in @("[  5]  0.00-1.00 sec client", "Server output:", "Accepted connection", "[  5]  0.00-1.00 sec server", "iperf Done.")) {
            $result = Get-IperfOutputRoute -Line $line -InServerOutput $inServer
            $inServer = $result.InServerOutput
            $result.Route
        }
        ($routes -join ",") | Should Be "client,marker,server,server,client"
        $inServer | Should Be $false
    }

    It "サーバー側のログがなければ、すべてクライアント側にすること" {
        $result = Get-IperfOutputRoute -Line "iperf Done." -InServerOutput $false
        $result.Route | Should Be "client"
        $result.InServerOutput | Should Be $false
    }
}

Describe "IperfRunner Rollback-FailedIperfExecution (失敗した計測のログの巻き戻し)" {
    It "パスが空のときは何もしないこと" {
        Rollback-FailedIperfExecution -logFilePath "" | Should BeNullOrEmpty
    }

    It "以前の記録がなければ、ログファイルごと消すこと" {
        $dir = New-TestFolder
        try {
            $log = Join-Path $dir "new.log"
            Set-Content -LiteralPath $log -Value "error"
            Rollback-FailedIperfExecution -logFilePath $log -preExecLines @() | Should Be $true
            (Test-Path -LiteralPath $log) | Should Be $false
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "以前の記録があれば、計測前の内容に戻すこと" {
        $dir = New-TestFolder
        try {
            $log = Join-Path $dir "old.log"
            Set-Content -LiteralPath $log -Value "failed attempt"
            Rollback-FailedIperfExecution -logFilePath $log -preExecLines @("line1", "line2") | Should Be $true
            (@(Get-Content -LiteralPath $log) -join "|") | Should Be "line1|line2"
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "消すファイルがなくても成功を返すこと" {
        $dir = New-TestFolder
        try {
            Rollback-FailedIperfExecution -logFilePath (Join-Path $dir "none.log") -preExecLines $null | Should Be $true
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "Ensure-Utf8Bom.ps1 (BOM の検査と付与)" {
    # ツールはプロジェクトの場所を自分の位置から判断するので、一時フォルダに同じ形のフォルダを作って動かす
    function New-BomTestProject {
        $root = New-TestFolder
        $system = Join-Path $root "system"
        $null = New-Item -ItemType Directory -Path (Join-Path $system "tools")
        Copy-Item -LiteralPath (Join-Path $systemDir "tools\Ensure-Utf8Bom.ps1") -Destination (Join-Path $system "tools")
        # ツールは 1 つ上のフォルダに Server.ps1 があれば、そこを system と判断する。これがないと検査対象が見つからず、何もしないで終わる
        [System.IO.File]::WriteAllText((Join-Path $system "Server.ps1"), "# placeholder", (New-Object System.Text.UTF8Encoding($true)))
        return $system
    }
    # 「日本語」の 3 文字
    $japanese = "# x" + [char]0x65E5 + [char]0x672C + [char]0x8A9E
    $noBom = New-Object System.Text.UTF8Encoding($false)
    $withBom = New-Object System.Text.UTF8Encoding($true)

    function Test-HasBom([string]$Path) {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    }

    It "BOM のない UTF-8 のファイルに、日本語を壊さず BOM を付けること" {
        $system = New-BomTestProject
        try {
            $file = Join-Path $system "NoBom.ps1"
            [System.IO.File]::WriteAllText($file, $japanese, $noBom)
            $null = & (Join-Path $system "tools\Ensure-Utf8Bom.ps1") *>&1
            Test-HasBom $file | Should Be $true
            [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8) | Should Be $japanese
        } finally {
            Remove-Item -LiteralPath (Split-Path -Parent $system) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "tools フォルダのファイルも検査の対象にすること" {
        $system = New-BomTestProject
        try {
            $file = Join-Path $system "tools\NoBom.ps1"
            [System.IO.File]::WriteAllText($file, $japanese, $noBom)
            $null = & (Join-Path $system "tools\Ensure-Utf8Bom.ps1") *>&1
            Test-HasBom $file | Should Be $true
        } finally {
            Remove-Item -LiteralPath (Split-Path -Parent $system) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Shift_JIS のファイルも、日本語を壊さず UTF-8 に直すこと" {
        $system = New-BomTestProject
        try {
            $file = Join-Path $system "Sjis.ps1"
            [System.IO.File]::WriteAllText($file, $japanese, [System.Text.Encoding]::GetEncoding(932))
            $null = & (Join-Path $system "tools\Ensure-Utf8Bom.ps1") *>&1
            Test-HasBom $file | Should Be $true
            [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8) | Should Be $japanese
        } finally {
            Remove-Item -LiteralPath (Split-Path -Parent $system) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "すでに BOM があるファイルは書き換えないこと" {
        $system = New-BomTestProject
        try {
            $file = Join-Path $system "HasBom.ps1"
            [System.IO.File]::WriteAllText($file, $japanese, $withBom)
            $before = [System.IO.File]::GetLastWriteTimeUtc($file)
            $null = & (Join-Path $system "tools\Ensure-Utf8Bom.ps1") *>&1
            [System.IO.File]::GetLastWriteTimeUtc($file) | Should Be $before
        } finally {
            Remove-Item -LiteralPath (Split-Path -Parent $system) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "くり返し実行しても内容が変わらないこと (-Quiet の確認結果の記録も含む)" {
        $system = New-BomTestProject
        try {
            $file = Join-Path $system "Twice.ps1"
            [System.IO.File]::WriteAllText($file, $japanese, $noBom)
            $null = & (Join-Path $system "tools\Ensure-Utf8Bom.ps1") -Quiet *>&1
            # 1 回目で BOM が付いたことを確かめてから、2 回目で変わらないことを見る
            Test-HasBom $file | Should Be $true
            $size = (Get-Item -LiteralPath $file).Length
            $null = & (Join-Path $system "tools\Ensure-Utf8Bom.ps1") -Quiet *>&1
            (Get-Item -LiteralPath $file).Length | Should Be $size
            [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8) | Should Be $japanese
        } finally {
            Remove-Item -LiteralPath (Split-Path -Parent $system) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
