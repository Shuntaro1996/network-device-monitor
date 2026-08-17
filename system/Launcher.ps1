<#
.SYNOPSIS
    対象IPごとに個別の監視ウィンドウを立ち上げるランチャー（systemフォルダ配下用）
#>
# 入力ファイルは1つ上の階層（ルート）にある devices.txt
$rootDir = (Resolve-Path "$PSScriptRoot\..").Path
$InputFile = Join-Path $rootDir "devices.txt"

if (-not (Test-Path $InputFile)) {
    Write-Warning "devices.txt が見つかりません。バッチファイルと同じ階層に作成してください。"
    Start-Sleep -Seconds 3
    exit
}

# ルートディレクトリの停止シグナルを削除
$stopSignal = Join-Path $rootDir ".stop_signal"
if (Test-Path $stopSignal) {
    Remove-Item $stopSignal -Force
}

$addresses = Get-Content $InputFile | Where-Object { $_.Trim() -ne "" } | ForEach-Object { $_.Trim() } | Select-Object -Unique

if ($addresses.Count -eq 0) {
    Write-Warning "監視対象のIPアドレスが devices.txt に記載されていません。"
    Start-Sleep -Seconds 3
    exit
}

Write-Host "合計 $($addresses.Count) 個のアドレスの監視ウィンドウを立ち上げます..." -ForegroundColor Cyan

# 現在のディレクトリー（system）からスクリプトを呼び出し、
# 新ウィンドウの作業ディレクトリはルートディレクトリにする

foreach ($addr in $addresses) {
    Write-Host "[$addr] の監視プロセスを起動中..."
    Start-Process powershell -WorkingDirectory $rootDir -ArgumentList "-NoExit", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "system\Monitor-SingleDevice.ps1", "-TargetAddress", $addr
    Start-Sleep -Milliseconds 200
}

Write-Host "すべての監視プロセスの起動が完了しました。ランチャーはまもなく自動で閉じます。" -ForegroundColor Green
Start-Sleep -Seconds 2
