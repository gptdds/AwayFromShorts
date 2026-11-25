# Offline regression for per-window freeze lists.
# Covers legacy migration, explicit empty lists, cross-midnight windows,
# force mode, persistence, lock direction, and pending-tighten merging.
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-window-lists.ps1

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
$tempDir = Join-Path $env:TEMP ('afs-window-lists-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
Set-AfsConfigPath -Path (Join-Path $tempDir 'config.json')
[IO.File]::WriteAllText((Join-Path $tempDir 'hub-state.json'),
    ('{"lastPush":"' + (Get-Date).ToString('o') + '"}'), (New-Object Text.UTF8Encoding($false)))

try {
    $defaultCfg = Get-AfsDefaultConfig
    Check 'default config has no top-level site list' (-not $defaultCfg.ContainsKey('blockedSites'))
    Check 'default config has no top-level process list' (-not $defaultCfg.ContainsKey('blockedProcesses'))
    Check 'default window owns its site list' (@($defaultCfg.schedule.windows[0].blockedSites).Count -gt 0)
    Check 'default window owns its process list' (@($defaultCfg.schedule.windows[0].blockedProcesses).Count -gt 0)

    $cfg = Get-AfsDefaultConfig
    $cfg.enabled = $true
    $cfg.force.enabled = $false
    $cfg.studyHold.enabled = $false
    $cfg.schedule.days = @(1..7)
    $cfg.browser.urlBlock = $true
    $cfg.schedule.windows = @(
        @{
            start = '00:00'
            end = '06:00'
            blockedSites = @('douyin.com')
            blockedProcesses = @('steam')
        },
        @{
            start = '12:00'
            end = '13:00'
            blockedSites = @()
            blockedProcesses = @()
        },
        @{
            start = '22:00'
            end = '23:00'
        }
    )

    $s0 = Get-AfsActiveState -Config $cfg -Now ([datetime]'2026-11-25T01:00:00')
    Check '01:00 hits first window' ($s0.active -and $s0.reason -eq 'schedule' -and [int]$s0.windowIndex -eq 0)
    Check 'window 0 uses its own processes' ((@(Get-AfsProcessKillList -Config $cfg -State $s0) -join ',') -eq 'steam')
    Check 'window 0 uses its own sites' ((@(Get-AfsEffectiveBlockList -Config $cfg -State $s0 -Field blockedSites) -join ',') -eq 'douyin.com')

    $s1 = Get-AfsActiveState -Config $cfg -Now ([datetime]'2026-11-25T12:30:00')
    Check '12:30 hits explicit-empty window' ($s1.active -and [int]$s1.windowIndex -eq 1)
    Check 'explicit empty sites stay empty' (@(Get-AfsEffectiveBlockList -Config $cfg -State $s1 -Field blockedSites).Count -eq 0)
    Check 'explicit empty processes stay empty' (@(Get-AfsProcessKillList -Config $cfg -State $s1).Count -eq 0)

    $s2 = Get-AfsActiveState -Config $cfg -Now ([datetime]'2026-11-25T22:30:00')
    Check '22:30 hits missing-field window' ($s2.active -and [int]$s2.windowIndex -eq 2)
    Check 'missing site field means empty, not global fallback' (@(Get-AfsEffectiveBlockList -Config $cfg -State $s2 -Field blockedSites).Count -eq 0)
    Check 'missing process field means empty, not global fallback' (@(Get-AfsProcessKillList -Config $cfg -State $s2).Count -eq 0)

    $sig0 = Get-AfsBrowserPolicySignature -Config $cfg -State $s0
    $sig1 = Get-AfsBrowserPolicySignature -Config $cfg -State $s1
    $sig2 = Get-AfsBrowserPolicySignature -Config $cfg -State $s2
    Check 'browser policy signature tracks window 0' ($sig0 -ne $sig1 -and $sig0 -ne $sig2)
    Check 'browser policy signature treats missing list as empty' ($sig1 -eq $sig2)

    $saved = Set-AfsConfigSafe -InputConfig $cfg
    $loaded = Get-AfsConfig
    Check 'custom window fields persist' (
        (@($loaded.schedule.windows[0].blockedProcesses) -join ',') -eq 'steam' -and
        (@($loaded.schedule.windows[0].blockedSites) -join ',') -eq 'douyin.com'
    )
    Check 'explicit empty fields persist as present empty arrays' (
        $loaded.schedule.windows[1].ContainsKey('blockedSites') -and
        @($loaded.schedule.windows[1].blockedSites).Count -eq 0 -and
        $loaded.schedule.windows[1].ContainsKey('blockedProcesses') -and
        @($loaded.schedule.windows[1].blockedProcesses).Count -eq 0
    )
    Check 'missing fields are normalized to present empty arrays' (
        $loaded.schedule.windows[2].ContainsKey('blockedSites') -and
        @($loaded.schedule.windows[2].blockedSites).Count -eq 0 -and
        $loaded.schedule.windows[2].ContainsKey('blockedProcesses') -and
        @($loaded.schedule.windows[2].blockedProcesses).Count -eq 0
    )

    # Legacy top-level lists migrate into every existing window, while explicit
    # window lists (including empty arrays) keep precedence.
    $legacy = @{
        version = 1
        enabled = $true
        schedule = @{
            days = @(1..7)
            windows = @(
                @{ start = '00:00'; end = '06:00' },
                @{ start = '12:00'; end = '13:00'; blockedSites = @(); blockedProcesses = @() }
            )
        }
        freeze = @{ enabled = $true }
        blockWebsites = $true
        blockedSites = @('douyin.com', 'youtube.com')
        blockedProcesses = @('"C:\Apps\Bili23.exe"', 'steam')
        whitelist = @{ sites = @(); processes = @() }
        override = @{ mode = 'none'; until = $null }
        force = @{ enabled = $false; until = $null; weekdays = @() }
        web = @{ port = 8737 }
        browser = @{ urlBlock = $false; targets = @('edge','chrome') }
    }
    Set-AfsConfigSafe -InputConfig $legacy | Out-Null
    $migrated = Get-AfsConfig
    Check 'legacy top-level site list removed after migration' (-not $migrated.ContainsKey('blockedSites'))
    Check 'legacy top-level process list removed after migration' (-not $migrated.ContainsKey('blockedProcesses'))
    Check 'legacy site list copied into missing window list' (
        (@($migrated.schedule.windows[0].blockedSites) -join ',') -eq 'douyin.com,youtube.com'
    )
    Check 'legacy process list copied and path reduced to process name' (
        (@($migrated.schedule.windows[0].blockedProcesses) -join ',') -eq 'Bili23.exe,steam'
    )
    Check 'legacy migration does not overwrite explicit empty lists' (
        @($migrated.schedule.windows[1].blockedSites).Count -eq 0 -and
        @($migrated.schedule.windows[1].blockedProcesses).Count -eq 0
    )

    # Lock direction: force on -> add to a window is tighten, delete is widen.
    $cur = Get-AfsDefaultConfig
    $cur.force.enabled = $true
    $cur.schedule.windows = @(@{
        start = '00:00'
        end = '06:00'
        blockedProcesses = @('steam')
        blockedSites = @()
    })
    $add = Get-AfsDefaultConfig
    $add.force.enabled = $true
    $add.schedule.windows = @(@{
        start = '00:00'
        end = '06:00'
        blockedProcesses = @('steam', 'discord')
        blockedSites = @()
    })
    $dAdd = Get-AfsConfigLockDiff -Current $cur -Incoming $add
    Check 'force-on: add window process -> queue' (($dAdd.queueKeys -contains 'windowProcesses:0') -and -not $dAdd.widenMsg)

    $del = Get-AfsDefaultConfig
    $del.force.enabled = $true
    $del.schedule.windows = @(@{
        start = '00:00'
        end = '06:00'
        blockedProcesses = @()
        blockedSites = @()
    })
    $dDel = Get-AfsConfigLockDiff -Current $cur -Incoming $del
    Check 'force-on: remove window process -> widen' (($dDel.widenKeys -contains 'windowProcesses:0') -and [bool]$dDel.widenMsg)

    $np = New-AfsPendingPatch -Current $cur -Incoming $add
    Check 'pending patch carries window addition' ([int]$np.total -ge 1 -and @($np.patch.schedule.windows).Count -eq 1)
    $merged = Merge-AfsPendingTighten -Base $cur -Patch $np.patch
    Check 'pending merge keeps old window item and adds new one' (
        (@($merged.schedule.windows[0].blockedProcesses) -contains 'steam') -and
        (@($merged.schedule.windows[0].blockedProcesses) -contains 'discord')
    )

    # Force mode follows the currently active window's own list.
    $forceCfg = Get-AfsDefaultConfig
    $forceCfg.enabled = $true
    $forceCfg.force.enabled = $true
    $forceCfg.force.weekdays = @(1..7)
    $forceCfg.schedule.days = @(1..7)
    $forceCfg.schedule.windows = @(@{
        start = '00:00'
        end = '06:00'
        blockedProcesses = @('steam')
        blockedSites = @('douyin.com')
    })
    $fs = Get-AfsActiveState -Config $forceCfg -Now ([datetime]'2026-11-25T01:00:00')
    Check 'force state carries active window' ($fs.active -and $fs.reason -eq 'force' -and [int]$fs.windowIndex -eq 0)
    Check 'force uses window process list' ((@(Get-AfsProcessKillList -Config $forceCfg -State $fs) -join ',') -eq 'steam')
    Check 'force uses window site list' ((@(Get-AfsEffectiveBlockList -Config $forceCfg -State $fs -Field blockedSites) -join ',') -eq 'douyin.com')

    # Cross-midnight ownership: Tuesday 00:30 belongs to Monday's 23:00-01:00 window.
    $cross = Get-AfsDefaultConfig
    $cross.schedule.days = @(1)
    $cross.schedule.windows = @(@{
        start = '23:00'
        end = '01:00'
        blockedProcesses = @('crossproc')
        blockedSites = @()
    })
    $cs = Get-AfsActiveState -Config $cross -Now ([datetime]'2026-11-24T00:30:00')
    Check 'cross-midnight window keeps its own list' (
        $cs.active -and [int]$cs.windowIndex -eq 0 -and
        ((@(Get-AfsProcessKillList -Config $cross -State $cs) -join ',') -eq 'crossproc')
    )

    Write-Host ''
    Write-Host ("Window lists: {0} checks passed, {1} failed" -f $script:Passes, $script:Fails)
} finally {
    Set-AfsConfigPath -Path $oldConfigPath
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Fails -gt 0) { exit 1 }
