# Offline regression for desktop freeze periods.
# Covers weekday ownership across midnight, the freeze master switch,
# stronger freeze reasons, persistence, and force-mode tighten-only storage.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\core.ps1')

$script:Fails = 0
$script:Passes = 0
function Check([string]$Name, $Condition, [string]$Detail = '') {
    if ($Condition) {
        Write-Host ('PASS  ' + $Name)
        $script:Passes++
    } else {
        Write-Host ('FAIL  ' + $Name + '   ' + $Detail)
        $script:Fails++
    }
}

$oldConfigPath = Get-AfsConfigPath
$tempDir = Join-Path $env:TEMP ('afs-freeze-window-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
Set-AfsConfigPath -Path (Join-Path $tempDir 'config.json')

try {
    $cfg = Get-AfsDefaultConfig
    Check 'default freeze enabled' ([bool]$cfg.freeze.enabled)

    $cfg.enabled = $true
    $cfg.force.enabled = $false
    $cfg.studyHold.enabled = $false
    $cfg.schedule.days = @(1) # Monday
    $cfg.schedule.windows = @(@{ start = '23:00'; end = '01:00' })

    $monLate = [datetime]'2026-11-23T23:30:00' # Monday
    $tueEarly = [datetime]'2026-11-24T00:30:00' # Tuesday
    $tueAfter = [datetime]'2026-11-24T01:00:00'

    $sMon = Get-AfsActiveState -Config $cfg -Now $monLate
    $sTue = Get-AfsActiveState -Config $cfg -Now $tueEarly
    $sAfter = Get-AfsActiveState -Config $cfg -Now $tueAfter
    Check 'Monday 23:30 in overnight window' ($sMon.active -and $sMon.reason -eq 'schedule')
    Check 'Tuesday 00:30 follows Monday start day' ($sTue.active -and $sTue.reason -eq 'schedule')
    Check 'Tuesday 01:00 releases overnight window' (-not $sAfter.active)
    Check 'enabled schedule freezes apps' (Test-AfsProcessFreezeActive -Config $cfg -State $sTue)

    $cfg.freeze.enabled = $false
    $paused = Get-AfsActiveState -Config $cfg -Now $tueEarly
    Check 'freeze switch disables the shared schedule inside its window' (-not $paused.active -and $paused.reason -eq 'freeze-disabled')
    Check 'freeze switch off bypasses ordinary process freeze' (-not (Test-AfsProcessFreezeActive -Config $cfg -State $paused))
    Check 'paused schedule has no next activation' ($null -eq (Get-AfsNextActiveTime -Config $cfg -Now $monLate))

    $browserPayload = Get-AfsBrowserClosePath
    Write-AfsJson -Path $browserPayload -Object @{targets=@('edge'); restartAll=$false}
    Remove-AfsBrowserClose
    Check 'release clears stale browser payload without restart' (-not (Test-Path -LiteralPath $browserPayload))
    Write-AfsJson -Path $browserPayload -Object @{restartAll=$true}
    Remove-AfsBrowserClose
    Check 'release preserves the one-time browser policy reload' (Test-Path -LiteralPath $browserPayload)

    $cfg.force.enabled = $true
    $cfg.force.weekdays = @(1)
    $forced = Get-AfsActiveState -Config $cfg -Now $monLate
    Check 'force starts inside the configured window with ordinary freeze paused' ($forced.active -and $forced.reason -eq 'force')
    Check 'force still freezes apps while ordinary freeze is paused' (Test-AfsProcessFreezeActive -Config $cfg -State $forced)
    Check 'configured force stays inactive outside the window' (-not (Test-AfsForceActive -Config $cfg -Now $tueAfter).active)
    $cfg.schedule.days = @(1..7)
    $cfg.schedule.windows = @(@{start='00:00'; end='06:00'})
    $cfg.force.weekdays = @(1..7)
    $midnight = $tueEarly.Date
    $adjustment = Get-AfsForceAdjustmentWindow -Now $midnight
    Check 'adjustment opens at midnight even while force is active' ($adjustment.allowed -and (Test-AfsForceActive -Config $cfg -Now $midnight).active)
    Check 'adjustment remains open through 00:59:59' ((Get-AfsForceAdjustmentWindow -Now $midnight.AddHours(1).AddSeconds(-1)).allowed)
    Check 'adjustment closes at 01:00 while force remains active' (-not (Get-AfsForceAdjustmentWindow -Now $midnight.AddHours(1)).allowed -and (Test-AfsForceActive -Config $cfg -Now $midnight.AddHours(1)).active)
    Check 'end of freeze at 06:00 does not reopen adjustment' (-not (Get-AfsForceAdjustmentWindow -Now $midnight.AddHours(6)).allowed -and -not (Test-AfsForceActive -Config $cfg -Now $midnight.AddHours(6)).active)
    $cfg.schedule.days = @(1)
    $cfg.schedule.windows = @(@{ start = '23:00'; end = '01:00' })
    $cfg.force.enabled = $false
    $cfg.freeze.enabled = $false
    $manualBlock = @{ active = $true; reason = 'override-block' }
    Check 'manual block still freezes apps while the schedule is paused' (Test-AfsProcessFreezeActive -Config $cfg -State $manualBlock)
    Check 'non-strong reason does not freeze' (-not (Test-AfsProcessFreezeActive -Config $cfg -State @{ active = $true; reason = 'schedule' }))
    & {
        function Test-AfsStudyDone { $false }
        function Get-AfsCheckinPenaltyActive { @{active=$false} }
        $cfg.studyHold.enabled = $true
        $pausedHold = Get-AfsActiveState -Config $cfg -Now $tueAfter
        Check 'paused freeze does not trigger incomplete study hold' ($pausedHold.reason -eq 'freeze-disabled')
        $cfg.freeze.enabled = $true
        $activeHold = Get-AfsActiveState -Config $cfg -Now $tueAfter
        Check 'study hold resumes with freeze enabled' ($activeHold.active -and $activeHold.reason -eq 'study-hold')
        function Get-AfsCheckinPenaltyActive { @{active=$true} }
        $cfg.freeze.enabled = $false
        $pausedPenalty = Get-AfsActiveState -Config $cfg -Now $tueAfter
        Check 'paused freeze does not trigger check-in penalty' ($pausedPenalty.reason -eq 'freeze-disabled')
        $cfg.studyHold.enabled = $false
    }

    $cfg2 = Get-AfsDefaultConfig
    $cfg2.enabled = $true
    $cfg2.force.enabled = $false
    $cfg2.studyHold.enabled = $false
    $cfg2.schedule.days = @(2) # Tuesday start day only
    $cfg2.schedule.windows = @(@{ start = '23:00'; end = '01:00' })
    $sWrongStartDay = Get-AfsActiveState -Config $cfg2 -Now $tueEarly
    Check 'Tuesday 00:30 does not use Tuesday as start day' (-not $sWrongStartDay.active)

    $cfg2.schedule.days = @(1)
    $next = Get-AfsNextActiveTime -Config $cfg2 -Now ([datetime]'2026-11-23T22:30:00')
    Check 'next freeze time uses the configured start time' ($next -eq '2026-11-23 23:00')

    $saved = Set-AfsConfigSafe -InputConfig $cfg2
    $loaded = Get-AfsConfig
    Check 'freeze switch persists' ([bool]$loaded.freeze.enabled -eq [bool]$cfg2.freeze.enabled)
    Check 'schedule persists' ((@($loaded.schedule.days) -join ',') -eq '1')

    $cur = Get-AfsDefaultConfig
    $cur.freeze.enabled = $false
    $inc = Get-AfsDefaultConfig
    $inc.freeze.enabled = $true
    $diffTighten = Get-AfsConfigLockDiff -Current $cur -Incoming $inc
    Check 'turning freeze on is a tighten change' ($diffTighten.queueKeys -contains 'freezeSwitch' -and -not $diffTighten.widenMsg)
    $patch = New-AfsPendingPatch -Current $cur -Incoming $inc
    Check 'pending patch carries freeze enable' ([bool]$patch.patch.freeze.enabled -and [int]$patch.total -ge 1)
    $merged = Merge-AfsPendingTighten -Base $cur -Patch $patch.patch
    Check 'pending merge applies freeze enable' ([bool]$merged.freeze.enabled)

    $cur.freeze.enabled = $true
    $inc.freeze.enabled = $false
    $diffWiden = Get-AfsConfigLockDiff -Current $cur -Incoming $inc
    Check 'turning freeze off is a widen change' ($diffWiden.widenKeys -contains 'freezeSwitch')
    $blocked = Test-AfsConfigLockViolation -Current $cur -Incoming $inc -ForceActive
    Check 'force-active switch-off is rejected' ([bool]$blocked)

    Write-Host ''
    Write-Host ("Freeze window: {0} checks passed, {1} failed" -f $script:Passes, $script:Fails)
} finally {
    Set-AfsConfigPath -Path $oldConfigPath
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Fails -gt 0) { exit 1 }
