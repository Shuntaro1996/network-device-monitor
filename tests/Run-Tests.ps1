# ==============================================================================
# Run-Tests.ps1 - Network Device Monitor Test Runner
# ==============================================================================
param(
    [switch]$VerboseOutput
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$testFile = Join-Path $here "Monitor.Tests.ps1"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Network Device Monitor - Automated Test Suite" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# Pester モジュールの検出
$hasPester = $false
try {
    if (Get-Module -ListAvailable -Name Pester) {
        Import-Module Pester -ErrorAction Stop
        $hasPester = $true
    }
} catch {
    $hasPester = $false
}

if ($hasPester) {
    Write-Host "[INFO] Pester framework detected. Executing native Invoke-Pester..." -ForegroundColor Green
    try {
        if ([type]::GetType("PesterConfiguration")) {
            $config = [PesterConfiguration]::Default
            $config.Run.Path = $testFile
            $config.Output.Verbosity = if ($VerboseOutput) { 'Detailed' } else { 'Normal' }
            Invoke-Pester -Configuration $config
        } else {
            Invoke-Pester -Script $testFile
        }
    } catch {
        Invoke-Pester -Script $testFile
    }
} else {
    Write-Host "[INFO] Pester not found in environment. Using built-in autonomous test runner..." -ForegroundColor Yellow
    
    # ── Pester互換アサーションエミュレータ ──
    $global:testPassCount = 0
    $global:testFailCount = 0

    function global:Describe {
        param([string]$Title, [scriptblock]$Fixture)
        Write-Host "`n=== $Title ===" -ForegroundColor Cyan
        & $Fixture
    }

    function global:It {
        param([string]$Title, [scriptblock]$Test)
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
        param(
            [Parameter(ValueFromPipeline = $true)]$Actual,
            [switch]$Not,
            [switch]$BeNullOrEmpty,
            [switch]$Be,
            [switch]$BeGreaterThan,
            [object]$Expected
        )
        if ($BeNullOrEmpty) {
            $isNull = [string]::IsNullOrEmpty([string]$Actual)
            if ($Not -and $isNull) { throw "Expected NOT null or empty, but was null/empty." }
            if (-not $Not -and -not $isNull) { throw "Expected null or empty, but was: $Actual" }
            return
        }
        if ($Be) {
            $isEqual = ($Actual -eq $Expected)
            if ($Not -and $isEqual) { throw "Expected NOT equal to '$Expected', but was equal." }
            if (-not $Not -and -not $isEqual) { throw "Expected '$Expected', but got '$Actual'" }
            return
        }
        if ($BeGreaterThan) {
            if ($Actual -le $Expected) { throw "Expected greater than '$Expected', but was '$Actual'" }
            return
        }
    }

    . $testFile

    Write-Host "`n==========================================================" -ForegroundColor Cyan
    Write-Host "  Test Summary: PASS = $global:testPassCount, FAIL = $global:testFailCount" -ForegroundColor $(if ($global:testFailCount -eq 0) { "Green" } else { "Red" })
    Write-Host "==========================================================" -ForegroundColor Cyan

    if ($global:testFailCount -gt 0) {
        exit 1
    }
}
