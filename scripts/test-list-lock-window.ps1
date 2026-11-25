# Offline regression: lists are append-only while force mode is enabled.
#   - force enabled: removing any list entry is rejected ("widen"),
#     adding a blocked entry is allowed, adding a whitelist entry is rejected
#   - force disabled: black/white lists can be freely edited
#   - hard blocks stay for schedule / force switch only (they define the window itself)
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-list-lock-window.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\core.ps1')

$script:Fails = 0
function Check([string]$Name, $Cond, [string]$Detail = '') {
    if ($Cond) { Write-Host ("PASS  " + $Name) }
    else { Write-Host ("FAIL  " + $Name + "   " + $Detail); $script:Fails++ }
}

function New-TestCfg {
    param(
        [bool]$Force = $true,
        [string[]]$WlProcs = @(),
        [string[]]$WlSites = @(),
        [string[]]$BlockedProcs = @(),
        [string[]]$BlockedSites = @()
    )
    $c = Get-AfsDefaultConfig
    $c.force.enabled = $Force
    $c.whitelist.processes = @($WlProcs)
    $c.whitelist.sites = @($WlSites)
    $c.schedule.windows[0].blockedProcesses = @($BlockedProcs)
    $c.schedule.windows[0].blockedSites = @($BlockedSites)
    $c
}

function Get-Diff($Cur, $Inc) { Get-AfsConfigLockDiff -Current $Cur -Incoming $Inc }

# same verdict webui.ps1 applies while force.enabled is on
function Test-Rejected($D, [bool]$ForceEnabled) {
    if ($D.hardMsg) { return $true }
    if ($ForceEnabled -and $D.widenMsg) { return $true }
    return $false
}

$cur = New-TestCfg -WlProcs @('wallpaper*', 'Teams') -WlSites @('mail.example.com') `
    -BlockedProcs @('chrome', 'discord') -BlockedSites @('douyin.com', 'tiktok.com')

function IncCfg {
    param([bool]$Force = $true, [string[]]$WlProcs = @('wallpaper*', 'Teams'), [string[]]$WlSites = @('mail.example.com'),
          [string[]]$BlockedProcs = @('chrome', 'discord'), [string[]]$BlockedSites = @('douyin.com', 'tiktok.com'))
    New-TestCfg -Force $Force -WlProcs $WlProcs -WlSites $WlSites -BlockedProcs $BlockedProcs -BlockedSites $BlockedSites
}

# ---------- 1) force enabled: removals are rejected ----------
$d = Get-Diff $cur (IncCfg -BlockedProcs @('chrome'))
Check 'force-on: remove blocked process -> widen' (($d.widenKeys -contains 'windowProcesses:0') -and -not $d.hardMsg -and (Test-Rejected $d $true)) ("widen=" + ($d.widenKeys -join ','))

$d = Get-Diff $cur (IncCfg -BlockedSites @('douyin.com'))
Check 'force-on: remove blocked site -> widen' (($d.widenKeys -contains 'windowSites:0') -and (Test-Rejected $d $true)) ("widen=" + ($d.widenKeys -join ','))

$d = Get-Diff $cur (IncCfg -WlProcs @('wallpaper*'))
Check 'force-on: remove whitelist process -> widen' (($d.widenKeys -contains 'whitelist') -and (Test-Rejected $d $true)) ("widen=" + ($d.widenKeys -join ','))

$d = Get-Diff $cur (IncCfg -WlSites @())
Check 'force-on: remove whitelist site -> widen' (($d.widenKeys -contains 'whitelist') -and (Test-Rejected $d $true)) ("widen=" + ($d.widenKeys -join ','))

# ---------- 2) force disabled: removals are allowed ----------
$curOff = New-TestCfg -Force $false -WlProcs @('wallpaper*', 'Teams') -WlSites @('mail.example.com') `
    -BlockedProcs @('chrome', 'discord') -BlockedSites @('douyin.com', 'tiktok.com')

$d = Get-Diff $curOff (IncCfg -Force $false -BlockedProcs @('chrome'))
Check 'force-off: remove blocked process -> allowed' (-not (Test-Rejected $d $false)) ("widen=" + ($d.widenKeys -join ','))

$d = Get-Diff $curOff (IncCfg -Force $false -BlockedSites @('douyin.com'))
Check 'force-off: remove blocked site -> allowed' (-not (Test-Rejected $d $false)) ("widen=" + ($d.widenKeys -join ','))

$d = Get-Diff $curOff (IncCfg -Force $false -WlProcs @('wallpaper*'))
Check 'force-off: remove whitelist process -> allowed' (-not (Test-Rejected $d $false)) ("widen=" + ($d.widenKeys -join ','))

$d = Get-Diff $curOff (IncCfg -Force $false -WlSites @())
Check 'force-off: remove whitelist site -> allowed' (-not (Test-Rejected $d $false)) ("widen=" + ($d.widenKeys -join ','))

$d = Get-Diff $curOff (IncCfg -Force $false -WlProcs @('wallpaper*', 'Teams', 'Lively'))
Check 'force-off: add whitelist process -> allowed' (-not (Test-Rejected $d $false)) ("widen=" + ($d.widenKeys -join ','))

# ---------- 3) tightening directions keep working while force is enabled ----------
$d = Get-Diff $cur (IncCfg -BlockedProcs @('chrome', 'discord', 'firefox'))
Check 'force-on: add blocked process -> allowed' (($d.queueKeys -contains 'windowProcesses:0') -and -not (Test-Rejected $d $true)) ("queue=" + ($d.queueKeys -join ','))

$d = Get-Diff $cur (IncCfg -WlProcs @('wallpaper*', 'Teams', 'Lively'))
Check 'force-on: add whitelist process -> rejected' (($d.widenKeys -contains 'wlProcs') -and (Test-Rejected $d $true)) ("widen=" + ($d.widenKeys -join ','))

# ---------- 4) hard blocks are only schedule / force itself ----------
$cur2 = New-TestCfg -WlProcs @('wallpaper*') -BlockedProcs @('chrome')
$inc2 = New-TestCfg -WlProcs @('wallpaper*') -BlockedProcs @('chrome')
$inc2.schedule.windows = @(@{ start = '08:00'; end = '10:00' })
$d = Get-Diff $cur2 $inc2
Check 'schedule change -> hard' (($d.hardKeys -contains 'schedule.windows') -and (Test-Rejected $d $false)) ("hard=" + ($d.hardKeys -join ','))

$inc3 = New-TestCfg -WlProcs @('wallpaper*') -BlockedProcs @('chrome')
$inc3.force.enabled = $false
$d = Get-Diff $cur2 $inc3
Check 'force switch -> hard' (($d.hardKeys -contains 'force') -and (Test-Rejected $d $false)) ("hard=" + ($d.hardKeys -join ','))

# ---------- 5) Set-AfsConfigSafe no longer resurrects removed entries ----------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('afs-lockwin-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    [IO.File]::WriteAllText((Join-Path $tmp 'hub-state.json'), ('{"lastPush":"' + (Get-Date).ToString('o') + '"}'), (New-Object Text.UTF8Encoding($false)))
    Set-AfsConfigPath (Join-Path $tmp 'config.json')

    Set-AfsConfigSafe -InputConfig (New-TestCfg -WlProcs @('wallpaper*') -BlockedProcs @('chrome', 'discord') -BlockedSites @('douyin.com')) | Out-Null
    $disk = Get-AfsConfig
    Check 'seed: lists written to the window' ((@($disk.schedule.windows[0].blockedProcesses).Count -eq 2) -and (@($disk.schedule.windows[0].blockedSites).Count -eq 1)) ''

    # Set-AfsConfigSafe itself is a low-level writer; API-level force lock is checked above.
    Set-AfsConfigSafe -InputConfig (New-TestCfg -WlProcs @() -BlockedProcs @('chrome') -BlockedSites @()) | Out-Null
    $disk = Get-AfsConfig
    Check 'removal persists (no union guard)' `
        ((@($disk.schedule.windows[0].blockedProcesses).Count -eq 1) -and (@($disk.schedule.windows[0].blockedSites).Count -eq 0) -and (@($disk.whitelist.processes).Count -eq 0)) `
        ('procs=' + @($disk.schedule.windows[0].blockedProcesses).Count + ' sites=' + @($disk.schedule.windows[0].blockedSites).Count + ' wl=' + @($disk.whitelist.processes).Count)
} finally {
    Set-AfsConfigPath $null
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Fails -eq 0) { Write-Host 'ALL PASS'; exit 0 }
Write-Host ($script:Fails.ToString() + ' FAILED'); exit 1
