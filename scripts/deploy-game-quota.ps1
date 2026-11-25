# Enable the approved 120-minute foreground allowance on this PC.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$appSrc = Join-Path $env:LOCALAPPDATA 'AwayFromShorts\src'
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $child = Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '"') -Verb RunAs -WindowStyle Hidden -PassThru -Wait
    exit $child.ExitCode
}
if (-not (Test-Path (Join-Path $appSrc 'webui.ps1'))) { throw 'AwayFromShorts is not installed' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Stop-ScheduledTask -TaskName 'AwayFromShorts-GameQuota' -ErrorAction SilentlyContinue
Stop-ScheduledTask -TaskName 'AwayFromShorts-WebUI' -ErrorAction SilentlyContinue
foreach ($file in @('game-quota.ps1','quota-rules.ps1','quota-ledger.ps1','quota-lan.ps1','register-game-quota-task.ps1','webui.ps1','web\index.html','uninstall.ps1')) {
    $dest = Join-Path $appSrc $file
    if (Test-Path $dest) { Copy-Item -LiteralPath $dest -Destination "$dest.bak-$stamp" }
    Copy-Item -LiteralPath (Join-Path $root "src\$file") -Destination $dest -Force
}
. (Join-Path $appSrc 'core.ps1')
$configPath = Join-Path $appSrc 'game-quota-config.json'
if (Test-Path $configPath) { Copy-Item -LiteralPath $configPath -Destination "$configPath.bak-$stamp" }
if (-not (Test-Path $configPath)) {
    Write-AfsJson $configPath @{version=1; enabled=$true; dailyMinutes=120; mode='foreground'; reset='local-midnight'}
}
& (Join-Path $appSrc 'register-game-quota-task.ps1')
Start-ScheduledTask -TaskName 'AwayFromShorts-WebUI'
