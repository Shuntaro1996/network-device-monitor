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

function New-TestFolder {
    # テストごとに重ならない一時フォルダを作る
    $path = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_Tools_$(Get-Random)"
    $null = New-Item -ItemType Directory -Path $path -Force
    return $path
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
        $null = New-Item -ItemType Directory -Path $system
        Copy-Item -LiteralPath (Join-Path $systemDir "Ensure-Utf8Bom.ps1") -Destination $system
        # ツールは Server.ps1 があるフォルダを system と判断する。これがないと検査対象が見つからず、何もしないで終わる
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
            $null = & (Join-Path $system "Ensure-Utf8Bom.ps1") *>&1
            Test-HasBom $file | Should Be $true
            [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8) | Should Be $japanese
        } finally {
            Remove-Item -LiteralPath (Split-Path -Parent $system) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Shift_JIS のファイルも、日本語を壊さず UTF-8 に直すこと" {
        $system = New-BomTestProject
        try {
            $file = Join-Path $system "Sjis.ps1"
            [System.IO.File]::WriteAllText($file, $japanese, [System.Text.Encoding]::GetEncoding(932))
            $null = & (Join-Path $system "Ensure-Utf8Bom.ps1") *>&1
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
            $null = & (Join-Path $system "Ensure-Utf8Bom.ps1") *>&1
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
            $null = & (Join-Path $system "Ensure-Utf8Bom.ps1") -Quiet *>&1
            # 1 回目で BOM が付いたことを確かめてから、2 回目で変わらないことを見る
            Test-HasBom $file | Should Be $true
            $size = (Get-Item -LiteralPath $file).Length
            $null = & (Join-Path $system "Ensure-Utf8Bom.ps1") -Quiet *>&1
            (Get-Item -LiteralPath $file).Length | Should Be $size
            [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8) | Should Be $japanese
        } finally {
            Remove-Item -LiteralPath (Split-Path -Parent $system) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
