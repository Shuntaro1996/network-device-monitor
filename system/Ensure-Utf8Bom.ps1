# ==============================================================================
# Ensure-Utf8Bom.ps1 - UTF-8 BOM Verification & Enforcement Tool for PS 5.1
# ==============================================================================
param(
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

# Resolve project root directory automatically
$projectRoot = if ($PSScriptRoot) {
    if ([System.IO.File]::Exists((Join-Path $PSScriptRoot "Server.ps1"))) {
        Split-Path -Parent $PSScriptRoot
    } else {
        $PSScriptRoot
    }
} else {
    $PWD.Path
}

$scanDirs = @(
    (Join-Path $projectRoot "system"),
    (Join-Path $projectRoot "system\modules"),
    (Join-Path $projectRoot "system\tests")
)

$targetFileInfos = [System.Collections.Generic.Dictionary[string, System.IO.FileInfo]]::new([System.StringComparer]::OrdinalIgnoreCase)

# Fast non-recursive scan of script directories (.ps1 and .psm1) using DirectoryInfo.GetFiles
# (Fetches FileInfo metadata including Length and LastWriteTimeUtc in bulk from OS directory table)
foreach ($dir in $scanDirs) {
    if ([System.IO.Directory]::Exists($dir)) {
        $dirInfo = [System.IO.DirectoryInfo]::new($dir)
        foreach ($ext in @("*.ps1", "*.psm1")) {
            foreach ($fi in $dirInfo.GetFiles($ext)) {
                if (-not $targetFileInfos.ContainsKey($fi.FullName)) {
                    $targetFileInfos[$fi.FullName] = $fi
                }
            }
        }
    }
}

# Load BOM metadata cache for fast startup when -Quiet is used
$cacheFile = Join-Path $projectRoot "system\.bom_cache"
$bomCache = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$cacheDirty = $false

if ($Quiet -and [System.IO.File]::Exists($cacheFile)) {
    try {
        foreach ($line in [System.IO.File]::ReadAllLines($cacheFile)) {
            $parts = $line -split '\|', 2
            if ($parts.Length -eq 2) {
                $bomCache[$parts[0]] = $parts[1]
            }
        }
    } catch {}
}

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$fixedCount = 0
$okCount = 0

if (-not $Quiet) {
    Write-Host "=== UTF-8 BOM Verification (Total: $($targetFileInfos.Count) files) ===" -ForegroundColor Cyan
}

foreach ($kv in $targetFileInfos.GetEnumerator()) {
    $f = $kv.Key
    $fi = $kv.Value
    $sig = "$($fi.Length):$($fi.LastWriteTimeUtc.Ticks)"

    $relName = if ($f.StartsWith($projectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $f.Substring($projectRoot.Length).TrimStart('\', '/')
    } else {
        $f
    }

    if ($Quiet -and $bomCache.ContainsKey($relName) -and $bomCache[$relName] -eq $sig) {
        $okCount++
        continue
    }

    $hasBom = $false
    $fs = [System.IO.File]::OpenRead($f)
    try {
        if ($fs.Length -ge 3) {
            $b0 = $fs.ReadByte()
            $b1 = $fs.ReadByte()
            $b2 = $fs.ReadByte()
            $hasBom = ($b0 -eq 0xEF -and $b1 -eq 0xBB -and $b2 -eq 0xBF)
        }
    } finally {
        $fs.Close()
    }

    if (-not $hasBom) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($f)
            # UTF-8 として正しく読めるかを厳密に確認する。読めない場合は Shift_JIS (CP932) で保存されたファイルとみなす
            # (以前は常に UTF-8 として読んで上書きしていたため、Shift_JIS で保存されたファイルの日本語が
            #  「?」などに置き換わり、元に戻せない形で壊れていた。PowerShell 5.1 も BOM なしは CP932 として読む)
            $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
            $sourceEncName = "UTF-8"
            try {
                $text = $strictUtf8.GetString($bytes)
            }
            catch [System.Text.DecoderFallbackException] {
                $text = [System.Text.Encoding]::GetEncoding(932).GetString($bytes)
                $sourceEncName = "Shift_JIS"
            }
            [System.IO.File]::WriteAllText($f, $text, $utf8Bom)
            Write-Host "[BOM FIXED] $relName (from $sourceEncName)" -ForegroundColor Yellow
            $fixedCount++
            $fiUpdated = [System.IO.FileInfo]::new($f)
            $sig = "$($fiUpdated.Length):$($fiUpdated.LastWriteTimeUtc.Ticks)"
        }
        catch {
            # 他のソフトが開いている等で書き換えられないファイルがあっても、残りのファイルの確認は続ける
            Write-Host "[BOM SKIP]  $relName ($($_.Exception.Message))" -ForegroundColor Red
            continue
        }
    } else {
        if (-not $Quiet) {
            Write-Host "[BOM OK]    $relName" -ForegroundColor Green
        }
        $okCount++
    }

    $bomCache[$relName] = $sig
    $cacheDirty = $true
}

if ($cacheDirty -or (-not $Quiet)) {
    try {
        $cacheLines = [System.Collections.Generic.List[string]]::new()
        foreach ($ck in $bomCache.Keys) {
            $cacheLines.Add("$ck|$($bomCache[$ck])")
        }
        [System.IO.File]::WriteAllLines($cacheFile, $cacheLines)
    } catch {}
}

if (-not $Quiet) {
    Write-Host "`nResult: OK=$okCount, Fixed=$fixedCount" -ForegroundColor Cyan
}
