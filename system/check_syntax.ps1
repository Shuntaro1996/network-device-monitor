$errors = $null
$tokens = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    'c:\Users\shuns\.gemini\antigravity\scratch\NetworkDeviceMonitor\system\Server.ps1',
    [ref]$tokens,
    [ref]$errors
)
$cnt = $errors.Count
Write-Host "ErrorCount:$cnt"
foreach ($e in $errors) {
    $ln = $e.Extent.StartLineNumber
    $msg = $e.Message
    Write-Host "Line${ln}: $msg"
}
