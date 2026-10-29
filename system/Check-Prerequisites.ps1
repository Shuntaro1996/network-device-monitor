# ==============================================================================
# Check-Prerequisites.ps1 - Ultra-Fast System Prerequisite & Module Check
# ==============================================================================
param(
    [switch]$AutoInstall
)

# 1. Ensure console font supports Japanese characters (only invokes Add-Type if legacy non-JP font is active)
try {
    $psConsoleReg = "HKCU:\Console\%SystemRoot%_System32_WindowsPowerShell_v1.0_powershell.exe"
    $needFontFix = $false
    if (Test-Path $psConsoleReg) {
        $regProps = Get-ItemProperty -Path $psConsoleReg -ErrorAction SilentlyContinue
        if ($regProps -and ($regProps.FaceName -eq "Lucida Console" -or $regProps.FaceName -eq "Consolas")) {
            $jpFontName = [char]0xFF2D + [char]0xFF33 + " " + [char]0x30B4 + [char]0x30B7 + [char]0x30C3 + [char]0x30AF
            Set-ItemProperty -Path $psConsoleReg -Name "FaceName" -Value $jpFontName -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $psConsoleReg -Name "FontFamily" -Value 54 -ErrorAction SilentlyContinue
            $needFontFix = $true
        }
    }
    if ($needFontFix) {
        $consoleFontCode = @'
using System;
using System.Runtime.InteropServices;
public class NDMConsoleFontHelper {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CONSOLE_FONT_INFO_EX {
        public uint cbSize;
        public uint nFont;
        public short dwFontSizeX;
        public short dwFontSizeY;
        public int FontFamily;
        public int FontWeight;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string FaceName;
    }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool GetCurrentConsoleFontEx(IntPtr hOut, bool bMax, ref CONSOLE_FONT_INFO_EX lpFont);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool SetCurrentConsoleFontEx(IntPtr hOut, bool bMax, ref CONSOLE_FONT_INFO_EX lpFont);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);
    public static void EnsureJapaneseFont() {
        try {
            IntPtr hOut = GetStdHandle(-11);
            if (hOut != IntPtr.Zero && hOut != new IntPtr(-1)) {
                CONSOLE_FONT_INFO_EX info = new CONSOLE_FONT_INFO_EX();
                info.cbSize = (uint)Marshal.SizeOf(info);
                if (GetCurrentConsoleFontEx(hOut, false, ref info)) {
                    info.FontFamily = 54;
                    if (info.dwFontSizeY <= 0) info.dwFontSizeY = 16;
                    if (info.FontWeight <= 0) info.FontWeight = 400;
                    info.FaceName = "\uFF2D\uFF33 \u30B4\u30B7\u30C3\u30AF";
                    SetCurrentConsoleFontEx(hOut, false, ref info);
                }
            }
        } catch {}
    }
}
'@
        if (-not ("NDMConsoleFontHelper" -as [type])) {
            Add-Type -TypeDefinition $consoleFontCode -ErrorAction SilentlyContinue
        }
        [NDMConsoleFontHelper]::EnsureJapaneseFont()
    }
} catch {}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir

# Fast inline module lookup ($env:PSModulePath direct directory inspection, < 2ms)
function Find-ModuleFast([string]$modName) {
    foreach ($mp in ($env:PSModulePath -split ';')) {
        if ([string]::IsNullOrWhiteSpace($mp)) { continue }
        $modRoot = Join-Path $mp $modName
        if ([System.IO.Directory]::Exists($modRoot)) {
            try {
                $subDirs = [System.IO.Directory]::GetDirectories($modRoot)
                if ($subDirs -and $subDirs.Length -gt 0) {
                    for ($i = $subDirs.Length - 1; $i -ge 0; $i--) {
                        $sd = $subDirs[$i]
                        $ver = [System.IO.Path]::GetFileName($sd)
                        if ([System.IO.File]::Exists((Join-Path $sd "$modName.psd1")) -or [System.IO.File]::Exists((Join-Path $sd "$modName.psm1"))) {
                            return @{ installed = $true; version = $ver }
                        }
                    }
                }
                if ([System.IO.File]::Exists((Join-Path $modRoot "$modName.psd1")) -or [System.IO.File]::Exists((Join-Path $modRoot "$modName.psm1"))) {
                    return @{ installed = $true; version = "1.0" }
                }
            } catch {}
        }
    }
    return @{ installed = $false; version = "" }
}

$psVer = $PSVersionTable.PSVersion.ToString()
$isPsCompatible = ($PSVersionTable.PSVersion.Major -ge 5)

$iperfPath = Join-Path $scriptDir "iperf3.18_64\iperf3.exe"
$hasIperf = [System.IO.File]::Exists($iperfPath)
if (-not $hasIperf) {
    $altIperf = Join-Path $projectRoot "tools\iperf3.exe"
    if ([System.IO.File]::Exists($altIperf)) {
        $hasIperf = $true
        $iperfPath = $altIperf
    }
}

$pesterInfo = Find-ModuleFast "Pester"
$snmpInfo   = Find-ModuleFast "SNMP"

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "  Network Device Monitor - システム前提環境チェック" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. PowerShell Version
if ($isPsCompatible) {
    Write-Host " [OK] PowerShell バージョン : $psVer (適合)" -ForegroundColor Green
} else {
    Write-Host " [NG] PowerShell バージョン : $psVer (PowerShell 5.1 以上が必要です)" -ForegroundColor Red
}

# 2. Execution Policy
Write-Host " [OK] 実行ポリシー         : Bypass / 実行可能" -ForegroundColor Green

# 3. Iperf3 Tool
if ($hasIperf) {
    Write-Host " [OK] Iperf3 帯域計測ツール : 利用可能 ($iperfPath)" -ForegroundColor Green
} else {
    Write-Host " [!]  Iperf3 帯域計測ツール : 未検出 (system\iperf3.18_64\iperf3.exe を配置すると有効になります)" -ForegroundColor Yellow
}

# 4. Pester Test Framework
if ($pesterInfo.installed) {
    Write-Host " [OK] Pester 自動テスト     : インストール済み (v$($pesterInfo.version))" -ForegroundColor Green
} else {
    Write-Host " [-]  Pester 自動テスト     : 未インストール (開発・テスト時のみ必要)" -ForegroundColor DarkGray
}

# 5. SNMP Module
if ($snmpInfo.installed) {
    Write-Host " [OK] SNMP 通信モジュール   : インストール済み (v$($snmpInfo.version))" -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host " 全ての必須コンポーネントが正常に確認されました。起動します...`n" -ForegroundColor Green
    exit 0
} else {
    Write-Host " [NG] SNMP 通信モジュール   : 未インストール" -ForegroundColor Red
    Write-Host "     ※ SNMP トラフィック監視や機器詳細の取得に必要です。" -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Cyan
    
    $shouldInstall = $false
    if ($AutoInstall) {
        $shouldInstall = $true
    } else {
        Write-Host ""
        $answer = Read-Host "SNMP モジュールを今すぐ自動インストールしますか？ [Y: はい / N: スキップ] (デフォルト: Y)"
        if ([string]::IsNullOrWhiteSpace($answer) -or $answer.Trim().ToUpper() -eq "Y") {
            $shouldInstall = $true
        }
    }

    if ($shouldInstall) {
        Write-Host "`nPowerShell Gallery から SNMP モジュールをインストール中..." -ForegroundColor Cyan
        Write-Host "（NuGet プロバイダーと SNMP モジュールをユーザー環境に自動導入します）" -ForegroundColor Gray
        
        $moduleCommon = Join-Path $scriptDir "modules\Common.psm1"
        if ([System.IO.File]::Exists($moduleCommon)) {
            Import-Module $moduleCommon -Force -DisableNameChecking -ErrorAction SilentlyContinue
        }
        $res = Install-PrerequisiteModule -moduleName "SNMP"
        if ($res.success) {
            Write-Host " [OK] SNMP モジュールのインストールに成功しました！" -ForegroundColor Green
            Write-Host "監視サーバーを起動します...`n" -ForegroundColor Green
            exit 0
        } else {
            Write-Host " [NG] インストールに失敗しました: $($res.error)" -ForegroundColor Red
            Write-Host "インターネット未接続環境の場合は、インターネット接続を確認するか、" -ForegroundColor Yellow
            Write-Host "管理者権限の PowerShell で 'Install-Module -Name SNMP -Scope CurrentUser' を実行してください。" -ForegroundColor Yellow
            Write-Host "`n（※ Ping 死活監視機能は SNMP モジュールなしでもそのまま起動・利用可能です）`n" -ForegroundColor Gray
            Start-Sleep -Seconds 2
            exit 0
        }
    } else {
        Write-Host "`nSNMP モジュールのインストールをスキップしました。" -ForegroundColor Yellow
        Write-Host "（※ Ping 死活監視機能はそのまま起動・利用可能です）`n" -ForegroundColor Gray
        exit 0
    }
}
