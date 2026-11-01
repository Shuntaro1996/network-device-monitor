# ==============================================================================
# AppJs.Tests.ps1 - app.js の関数のテストを Pester から実行する
# ==============================================================================
# 【初心者向けの簡単な解説】
# テストの中身は app-functions.check.js にあります (JavaScript なので Node.js で動かします)。
# このファイルはそれを 1 回実行し、結果の 1 件ごとに Pester の合否として表示します。
#
# 【Node.js がないとき】
# Node.js はこのツールの動作には不要で、開発者のパソコンにないことがあります。
# そのときは理由を表示して省略し、全体のテストは止めません。
#
# 【変更するときの注意】
# テストを追加するときは app-functions.check.js に書いてください。このファイルの変更は不要です。
# ==============================================================================

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$publicDir = Join-Path (Split-Path -Parent $here) "public"
$checkScript = Join-Path $here "app-functions.check.js"
$nodeCommand = Get-Command node -ErrorAction SilentlyContinue

Describe "app.js の関数 (画面なしで確認)" {
    if (-not $nodeCommand) {
        Write-Host "  [SKIP] Node.js was not found. Skipping the app.js function tests." -ForegroundColor Yellow
        return
    }

    # 結果の JSON は日本語を含むので、画面出力ではなく一時ファイルで受け取る
    $resultFile = Join-Path ([System.IO.Path]::GetTempPath()) "NDM_AppJs_$(Get-Random).json"
    $nodeOutput = & $nodeCommand.Source $checkScript $publicDir $resultFile 2>&1 | Out-String
    $hasResult = Test-Path -LiteralPath $resultFile

    It "テストの実行そのものが最後まで動くこと" {
        if (-not $hasResult) { throw "app-functions.check.js did not finish: $nodeOutput" }
    }

    if ($hasResult) {
        # PowerShell 5.1 の ConvertFrom-Json は配列を 1 つのまとまりとして渡すので、ForEach-Object で 1 件ずつに分ける
        $results = @([System.IO.File]::ReadAllText($resultFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json | ForEach-Object { $_ })
        Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
        foreach ($result in $results) {
            It $result.name {
                if (-not $result.ok) { throw $result.message }
            }
        }
    }
}
