# ==============================================================================
# Run-InCopy.ps1 - プロジェクトのコピーで自動テストを実行するスクリプト
# ==============================================================================
# 【初心者向けの簡単な解説】
# テストはサーバーを起動し、ログや設定ファイルも書き換えます。実際に使っているフォルダで動かすと、
# 登録済みの機器へ通信したり、動作中の監視と重なったりするおそれがあります。
# そこで一時フォルダへコピーを作り、その中だけでテストを動かして、最後にコピーを消します。
#
# 【コピーしないもの】
# - devices.json / config.json: 実機の情報が入っているため。機器の一覧がないときは、
#   Run-Tests.ps1 が見本 (devices.example.json) を使います。
# - backups / debug.log など: 実機の情報が入っていることがあり、テストにも不要なため。
# - Reports / .git: 容量が大きく、テストに不要なため。
#
# 【使い方】
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File system\tests\Run-InCopy.ps1
#   全テストと画面テストを実行します。合格なら終了コード 0、不合格なら 0 以外を返します。
#
#   -Filter を付けると、名前が一致するテストファイルだけを実行します (E2E と画面テストは追加しません)。
#     例: -Filter "Monitor.Tests.ps1"
#
# 【変更するときの注意】
# - コピーしないものを減らすと、実機の情報を使ってテストが動くおそれがあります。
# - 最後の削除は、自分で作った一時フォルダであることを確かめてから行っています。この確認は外さないでください。
# - Windows PowerShell 5.1 で動かす必要があるので、powershell.exe を明示して起動しています
#   (pwsh 7 では一部のテストが動きません)。
# ==============================================================================
param(
    [string]$Filter = ""
)

$ErrorActionPreference = "Stop"

# このスクリプトは system\tests にあるので、2 つ上がプロジェクトの直下
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$namePrefix = "NDM_TestCopy_"
$copyRoot = Join-Path ([System.IO.Path]::GetTempPath()) ($namePrefix + [Guid]::NewGuid().ToString("N"))

# 結果が分からないまま合格に見えないよう、テストが最後まで動くまでは不合格の値にしておく
$exitCode = 1

try {
    # ── 1. コピーを作る ─────────────────────────────────────────────────────
    # system 以外は直下のファイルだけをコピーする (Reports や .git はコピーしない)
    $null = New-Item -ItemType Directory -Path $copyRoot
    Get-ChildItem -LiteralPath $projectRoot -File | Copy-Item -Destination $copyRoot

    # robocopy は、指定した名前のファイルとフォルダを除いて、フォルダごとコピーできる
    # /E: 空のフォルダも含める  /NFL /NDL /NJH /NJS /NP: 一覧を出さない  /R:1 /W:1: 失敗時の再試行を短くする
    $excludeFiles = @("devices.json", "config.json", "debug.log", "debug_1.log", ".bom_cache", "*.broken_*")
    $excludeDirs = @("backups", "__pycache__")
    $null = & robocopy (Join-Path $projectRoot "system") (Join-Path $copyRoot "system") /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 /XF @excludeFiles /XD @excludeDirs
    # robocopy の終了コードは 8 未満が成功 (0 以外でも失敗とは限らない)
    if ($LASTEXITCODE -ge 8) { throw "Failed to copy the project (robocopy exit code $LASTEXITCODE)." }

    # ── 2. コピーの中でテストを実行する ─────────────────────────────────────
    $runTests = Join-Path $copyRoot "system\tests\Run-Tests.ps1"
    # 外側の @() は外さないこと。if の結果は要素が 1 つだと文字列になり、そのまま渡すと 1 文字ずつの引数に分かれて起動に失敗する
    $testArgs = @(if ($Filter) { "-Filter", $Filter } else { "-All" })
    Write-Host "[INFO] Running tests in a temporary copy: $copyRoot" -ForegroundColor Gray
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runTests @testArgs
    $exitCode = $LASTEXITCODE
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    # ── 3. コピーを消す ─────────────────────────────────────────────────────
    # 間違って別のフォルダを消さないよう、一時フォルダの直下で、このスクリプトが付けた名前の場合だけ消す
    $isOurCopy = ((Split-Path -Leaf $copyRoot).StartsWith($namePrefix)) -and
                 ((Split-Path -Parent $copyRoot).TrimEnd('\') -eq ([System.IO.Path]::GetTempPath()).TrimEnd('\'))
    if ($isOurCopy -and (Test-Path -LiteralPath $copyRoot)) {
        try { Remove-Item -LiteralPath $copyRoot -Recurse -Force }
        catch { Write-Host "[WARNING] Could not delete the temporary copy: $copyRoot" -ForegroundColor Yellow }
    }
}

exit $exitCode
