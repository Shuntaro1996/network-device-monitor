# ==============================================================================
# Ensure-Utf8Bom.ps1 - PowerShell 5.1 用 UTF-8 BOM 付与スクリプト
# ==============================================================================
$files = @(
    "system\Server.ps1",
    "system\Watchdog.ps1",
    "system\Check-Prerequisites.ps1",
    "tests\Monitor.Tests.ps1",
    "tests\Run-Tests.ps1"
) + (Get-ChildItem -Path "system\modules\*.psm1" | ForEach-Object { $_.FullName })

$utf8Bom = New-Object System.Text.UTF8Encoding($true)

foreach ($f in $files) {
    if (Test-Path $f) {
        $resolved = (Resolve-Path $f).Path
        $bytes = [System.IO.File]::ReadAllBytes($resolved)
        if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
            $text = [System.IO.File]::ReadAllText($resolved, [System.Text.Encoding]::UTF8)
            [System.IO.File]::WriteAllText($resolved, $text, $utf8Bom)
            Write-Host "[BOM FIXED] $f" -ForegroundColor Yellow
        } else {
            Write-Host "[BOM OK] $f" -ForegroundColor Green
        }
    }
}
