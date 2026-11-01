# ==============================================================================
# Run-Tests.ps1 - Network Device Monitor Automated Test Runner
# ==============================================================================
# 【初心者向けの簡単な解説】
# このスクリプトは、システム全体の品質を保証するための「自動テスト総合管理ツール」です。
# system/tests/ フォルダ内にある「*.Tests.ps1」という名前のテストファイルをすべて自動検出して
# 順番に実行し、成功数・失敗数のサマリーを分かりやすく画面に表示します。
# Windows標準の PowerShell 5.1 (Pester 3.4.0) 環境および Pester未導入環境（自律フォールバック）
# の両方で100%確実に動作するように設計されています。
# ==============================================================================
param(
    [switch]$VerboseOutput,
    [string]$Filter = "*.Tests.ps1",
    [switch]$IncludeE2E,
    [switch]$IncludeUI,
    [switch]$All,
    [switch]$NoExit
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Network Device Monitor - Automated Test Suite" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# ── 0. UTF-8 BOM エンコーディング事前保護 ────────────────────────────────────
# PowerShell 5.1 で日本語コメントや特殊文字が文字化けするのを防ぐため、
# system/tests/ 配下の全スクリプト (.ps1) に UTF-8 BOM が付与されていることを確認・保証します。
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$allTestScripts = Get-ChildItem -Path $here -Filter "*.ps1" -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
    $_.FullName -notmatch '[\\/](temp_|backups|\.git)'
}
foreach ($tsFile in $allTestScripts) {
    try {
        $bytes = [System.IO.File]::ReadAllBytes($tsFile.FullName)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        if (-not $hasBom) {
            # UTF-8 として読めないファイルは Shift_JIS (CP932) で保存されたものとして読む
            # (常に UTF-8 で読むと、Shift_JIS のファイルの日本語が壊れたまま上書きされるため)
            try {
                $txt = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
            }
            catch [System.Text.DecoderFallbackException] {
                $txt = [System.Text.Encoding]::GetEncoding(932).GetString($bytes)
            }
            [System.IO.File]::WriteAllText($tsFile.FullName, $txt, $utf8Bom)
        }
    } catch {}
}

# ── 1. テスト環境セッション分離・衛生管理 (Hygiene) ─────────────────────────
function Reset-TestEnvironmentHygiene {
    Remove-Variable -Name "TestDrive" -Scope Global -ErrorAction SilentlyContinue
    if (Get-PSDrive -Name "TestDrive" -ErrorAction SilentlyContinue) {
        try { Remove-PSDrive -Name "TestDrive" -Force -ErrorAction SilentlyContinue } catch {}
    }
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}

Reset-TestEnvironmentHygiene

# ── 1b. 機器の一覧がないとき (取得した直後など) は見本を一時的に使う ──────────────
# devices.json は Git の管理対象外なので、取得した直後はありません。監視対象がないと一部のテストが動かないため、
# テストの間だけ見本 (実在しない説明用のアドレス) を置き、終わったら消します。
$devicesJsonPath = Join-Path $here "..\devices.json"
$createdSampleDevices = $false
if (-not (Test-Path -LiteralPath $devicesJsonPath)) {
    Copy-Item -LiteralPath (Join-Path $here "..\devices.example.json") -Destination $devicesJsonPath
    $createdSampleDevices = $true
    Write-Host "[INFO] devices.json was not found. Using devices.example.json during the tests." -ForegroundColor Gray
}

# ── 2. テストスクリプトの動的検出 ─────────────────────────────────────────────
$searchPattern = $Filter
if ($searchPattern -notlike "*.*" -and $searchPattern -notlike "*\**") {
    $searchPattern = "*$searchPattern*.Tests.ps1"
}

$discoveredList = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
$matched = Get-ChildItem -Path $here -Filter $searchPattern -File | Where-Object { $_.Name -like "*.Tests.ps1" } | Sort-Object Name
if ($matched) {
    foreach ($m in $matched) { $discoveredList.Add($m) }
}

# -IncludeE2E または -All 指定時の E2E-Lifecycle.Tests.ps1 確実な追加
if ($IncludeE2E -or $All) {
    $e2ePath = Join-Path $here "E2E-Lifecycle.Tests.ps1"
    if (Test-Path $e2ePath) {
        $e2eItem = Get-Item $e2ePath
        $alreadyDiscovered = $false
        foreach ($d in $discoveredList) {
            if ($d.FullName -eq $e2eItem.FullName) { $alreadyDiscovered = $true; break }
        }
        if (-not $alreadyDiscovered) {
            $discoveredList.Add($e2eItem)
        }
    }
}

$testFiles = @($discoveredList)

if (-not $testFiles -or $testFiles.Count -eq 0) {
    if (-not ($IncludeUI -or $All)) {
        Write-Warning "No test files matching '$Filter' found in $here."
        if (-not $NoExit) { exit 0 }
        return
    }
}

Write-Host "[INFO] Discovered $($testFiles.Count) test file(s):" -ForegroundColor Gray
foreach ($f in $testFiles) {
    Write-Host "  - $($f.Name)" -ForegroundColor Gray
}

# ── 2. Pester フレームワークの検出 ──────────────────────────────────────────
$hasPester = $false
$pesterModule = $null
try {
    $pesterModule = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
    if ($pesterModule) {
        Import-Module $pesterModule -ErrorAction Stop
        $hasPester = $true
    }
} catch {
    $hasPester = $false
}

$suiteExitCode = 0

if ($hasPester) {
    $pVersion = (Get-Module Pester).Version
    Write-Host "[INFO] Pester $pVersion detected. Executing native test runner..." -ForegroundColor Green
    
    $totalCount   = 0
    $passedCount  = 0
    $failedCount  = 0
    $skippedCount = 0

    $testPaths = @($testFiles | ForEach-Object { $_.FullName })

    try {
        if ([type]::GetType("PesterConfiguration")) {
            # Pester 5+
            $config = [PesterConfiguration]::Default
            $config.Run.Path = $testPaths
            $config.Run.PassThru = $true
            $config.Output.Verbosity = if ($VerboseOutput) { 'Detailed' } else { 'Normal' }
            $pesterResult = Invoke-Pester -Configuration $config
            if ($pesterResult) {
                $totalCount   = $pesterResult.TotalCount
                $passedCount  = $pesterResult.PassedCount
                $failedCount  = $pesterResult.FailedCount
                $skippedCount = $pesterResult.SkippedCount
            }
        } else {
            # Pester 3.4.0 / 4.x
            foreach ($tf in $testFiles) {
                Reset-TestEnvironmentHygiene
                Write-Host "`n>>> [TEST RUNNER] Executing $($tf.Name) <<<" -ForegroundColor Cyan
                $res = Invoke-Pester -Script $tf.FullName -PassThru
                if ($res) {
                    $totalCount   += $res.TotalCount
                    $passedCount  += $res.PassedCount
                    $failedCount  += $res.FailedCount
                    $skippedCount += $res.SkippedCount
                }
                Reset-TestEnvironmentHygiene
            }
        }
    } catch {
        Write-Host "[ERROR] Pester execution encountered an error: $($_.Exception.Message)" -ForegroundColor Red
        $failedCount++
    }

    Write-Host "`n==========================================================" -ForegroundColor Cyan
    Write-Host "  Test Suite Summary (Pester $pVersion)" -ForegroundColor Cyan
    Write-Host "  Total:   $totalCount"
    Write-Host "  Passed:  $passedCount" -ForegroundColor Green
    Write-Host "  Failed:  $failedCount" -ForegroundColor $(if ($failedCount -eq 0) { "Green" } else { "Red" })
    if ($skippedCount -gt 0) {
        Write-Host "  Skipped: $skippedCount" -ForegroundColor Yellow
    }
    Write-Host "==========================================================" -ForegroundColor Cyan

    if ($failedCount -gt 0) {
        $suiteExitCode = 1
    }
} else {
    Write-Host "[INFO] Pester not found in environment. Using built-in autonomous test runner..." -ForegroundColor Yellow
    
    # ── Pester互換アサーションエミュレータ ──
    $global:testTotalCount = 0
    $global:testPassCount  = 0
    $global:testFailCount  = 0

    function global:Describe {
        param([string]$Title, [scriptblock]$Fixture)
        Write-Host "`n=== $Title ===" -ForegroundColor Cyan
        & $Fixture
    }

    function global:Context {
        param([string]$Title, [scriptblock]$Fixture)
        Write-Host "`n--- $Title ---" -ForegroundColor DarkCyan
        & $Fixture
    }

    function global:BeforeAll {
        param([scriptblock]$Fixture)
        & $Fixture
    }

    function global:AfterAll {
        param([scriptblock]$Fixture)
        & $Fixture
    }

    function global:BeforeEach {
        param([scriptblock]$Fixture)
        & $Fixture
    }

    function global:AfterEach {
        param([scriptblock]$Fixture)
        & $Fixture
    }

    function global:It {
        param([string]$Title, [scriptblock]$Test)
        $global:testTotalCount++
        try {
            & $Test
            Write-Host "  [PASS] $Title" -ForegroundColor Green
            $global:testPassCount++
        } catch {
            Write-Host "  [FAIL] $Title" -ForegroundColor Red
            Write-Host "         $($_.Exception.Message)" -ForegroundColor DarkRed
            $global:testFailCount++
        }
    }

    function global:Should {
        [CmdletBinding()]
        param(
            [Parameter(ValueFromPipeline = $true)]$Actual,
            [Parameter(Position = 0, ValueFromRemainingArguments = $true)]$RemainingArgs,
            [switch]$Not,
            [switch]$BeNullOrEmpty,
            [switch]$Be,
            [switch]$BeGreaterThan,
            [switch]$BeLessThan,
            [switch]$Match,
            [switch]$BeOfType,
            [switch]$Contain,
            [switch]$BeTrue,
            [switch]$BeFalse,
            [object]$Expected
        )

        $isNot = $Not.IsPresent
        $op = ""
        $exp = $Expected

        # パラメータ指定（スイッチ）と位置引数（Pester 3.x 形式）の両立
        if ($RemainingArgs -and $RemainingArgs.Count -gt 0) {
            $idx = 0
            if ([string]$RemainingArgs[$idx] -eq "Not") {
                $isNot = -not $isNot
                $idx++
            }
            if ($idx -lt $RemainingArgs.Count) {
                $op = [string]$RemainingArgs[$idx]
                $idx++
            }
            if ($idx -lt $RemainingArgs.Count) {
                $exp = $RemainingArgs[$idx]
            }
        } else {
            if ($BeNullOrEmpty)      { $op = "BeNullOrEmpty" }
            elseif ($Be)             { $op = "Be" }
            elseif ($BeGreaterThan)  { $op = "BeGreaterThan" }
            elseif ($BeLessThan)     { $op = "BeLessThan" }
            elseif ($Match)          { $op = "Match" }
            elseif ($BeOfType)       { $op = "BeOfType" }
            elseif ($Contain)        { $op = "Contain" }
            elseif ($BeTrue)         { $op = "BeTrue" }
            elseif ($BeFalse)        { $op = "BeFalse" }
        }

        switch ($op) {
            "BeNullOrEmpty" {
                $isNull = [string]::IsNullOrEmpty([string]$Actual)
                if ($isNot -and $isNull) { throw "Expected NOT null or empty, but was null/empty." }
                if (-not $isNot -and -not $isNull) { throw "Expected null or empty, but was: $Actual" }
            }
            "Be" {
                $isEqual = ($Actual -eq $exp)
                if ($isNot -and $isEqual) { throw "Expected NOT equal to '$exp', but was equal." }
                if (-not $isNot -and -not $isEqual) { throw "Expected '$exp', but got '$Actual'" }
            }
            "BeGreaterThan" {
                $isGt = ($Actual -gt $exp)
                if ($isNot -and $isGt) { throw "Expected NOT greater than '$exp', but was '$Actual'" }
                if (-not $isNot -and -not $isGt) { throw "Expected greater than '$exp', but was '$Actual'" }
            }
            "BeLessThan" {
                $isLt = ($Actual -lt $exp)
                if ($isNot -and $isLt) { throw "Expected NOT less than '$exp', but was '$Actual'" }
                if (-not $isNot -and -not $isLt) { throw "Expected less than '$exp', but was '$Actual'" }
            }
            "Match" {
                $isMatch = ([string]$Actual -match [string]$exp)
                if ($isNot -and $isMatch) { throw "Expected NOT to match pattern '$exp', but matched: '$Actual'" }
                if (-not $isNot -and -not $isMatch) { throw "Expected to match pattern '$exp', but got: '$Actual'" }
            }
            "BeOfType" {
                $targetType = if ($exp -is [type]) { $exp } else { [type]::GetType([string]$exp) }
                $isType = ($null -ne $Actual -and ($targetType.IsInstanceOfType($Actual) -or $Actual.GetType().FullName -eq $targetType.FullName))
                if ($isNot -and $isType) { throw "Expected NOT of type '$targetType', but was." }
                if (-not $isNot -and -not $isType) { throw "Expected of type '$targetType', but was: $($Actual.GetType().FullName)" }
            }
            "Contain" {
                $doesContain = ($Actual -contains $exp -or ([string]$Actual).Contains([string]$exp))
                if ($isNot -and $doesContain) { throw "Expected NOT to contain '$exp', but did." }
                if (-not $isNot -and -not $doesContain) { throw "Expected to contain '$exp', but did not." }
            }
            "BeTrue" {
                $isTrue = ($Actual -eq $true)
                if ($isNot -and $isTrue) { throw "Expected NOT to be true, but was true." }
                if (-not $isNot -and -not $isTrue) { throw "Expected true, but was: $Actual" }
            }
            "BeFalse" {
                $isFalse = ($Actual -eq $false)
                if ($isNot -and $isFalse) { throw "Expected NOT to be false, but was false." }
                if (-not $isNot -and -not $isFalse) { throw "Expected false, but was: $Actual" }
            }
            default {
                if ($op) {
                    $isEq = ($Actual -eq $exp)
                    if ($isNot -and $isEq) { throw "Expected NOT equal to '$exp', but was equal." }
                    if (-not $isNot -and -not $isEq) { throw "Expected '$exp', but got '$Actual'" }
                }
            }
        }
    }

    foreach ($tf in $testFiles) {
        Reset-TestEnvironmentHygiene
        Write-Host "`n>>> [TEST RUNNER] Executing $($tf.Name) <<<" -ForegroundColor Cyan
        . $tf.FullName
        Reset-TestEnvironmentHygiene
    }

    Write-Host "`n==========================================================" -ForegroundColor Cyan
    Write-Host "  Test Suite Summary (Fallback Runner)" -ForegroundColor Cyan
    Write-Host "  Total:   $global:testTotalCount"
    Write-Host "  Passed:  $global:testPassCount" -ForegroundColor Green
    Write-Host "  Failed:  $global:testFailCount" -ForegroundColor $(if ($global:testFailCount -eq 0) { "Green" } else { "Red" })
    Write-Host "==========================================================" -ForegroundColor Cyan

    if ($global:testFailCount -gt 0) {
        $suiteExitCode = 1
    }
}

# ── 3. Headless Browser UI 自動テスト (Playwright) ───────────────────────────
if ($IncludeUI -or $All) {
    Write-Host "`n==========================================================" -ForegroundColor Cyan
    Write-Host "  Headless Browser UI Automated Test (Playwright)" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan

    $uiScript = Join-Path $here "ui_verification.py"
    if (-not (Test-Path $uiScript)) {
        Write-Host "[ERROR] UI verification script not found: $uiScript" -ForegroundColor Red
        $suiteExitCode = 1
    } else {
        $hasPython = (Get-Command "python" -ErrorAction SilentlyContinue) -ne $null
        if (-not $hasPython) {
            Write-Host "[WARNING] Python is not installed or not found in PATH." -ForegroundColor Yellow
            Write-Host "          To run UI tests, please install Python 3.8+ and run: pip install playwright" -ForegroundColor Gray
        } else {
            Write-Host "[INFO] Python detected. Verifying Playwright package..." -ForegroundColor Gray
            $checkProc = & python -c "import playwright; print('PLAYWRIGHT_OK')" 2>$null
            if ($checkProc -notmatch "PLAYWRIGHT_OK") {
                Write-Host "[WARNING] Playwright is not installed in Python environment." -ForegroundColor Yellow
                Write-Host "          To run UI tests, please execute: pip install playwright" -ForegroundColor Gray
            } else {
                Write-Host "[INFO] Executing Playwright UI verification suite..." -ForegroundColor Green
                & python $uiScript
                $pyExit = $LASTEXITCODE
                if ($pyExit -ne 0) {
                    Write-Host "[FAIL] UI automated verification failed with exit code $pyExit." -ForegroundColor Red
                    $suiteExitCode = 1
                } else {
                    Write-Host "[PASS] UI automated verification passed successfully." -ForegroundColor Green
                }
            }
        }
    }
}

Reset-TestEnvironmentHygiene

if ($createdSampleDevices) { Remove-Item -LiteralPath $devicesJsonPath -Force -ErrorAction SilentlyContinue }

if (-not $NoExit -and $suiteExitCode -ne 0) {
    exit $suiteExitCode
}
if (-not $NoExit) {
    exit 0
}
