$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. (Join-Path $root 'src\core.ps1')
. (Join-Path $root 'src\quota-ledger.ps1')

function Assert($Condition, $Message) {
    if (-not $Condition) { throw $Message }
}

$dir = Join-Path $env:TEMP ('afs-shared-pool-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    $now = Get-Date
    $today = Get-AfsQuotaDayKey $now
    Write-AfsJson (Join-Path $dir 'game-quota-config.json') @{
        version = 4
        enabled = $true
        rules = @(
            @{
                id = 'shared:test1111'
                type = 'shared'
                name = '共享格子 A · chrome + code'
                dailyMinutes = 60
                processes = @('chrome', 'code')
                websites = @('example.com')
                shared = $true
            },
            @{id='process:unshared'; type='process'; name='Between shared cells'; dailyMinutes=30},
            @{
                id = 'shared:test2222'
                type = 'shared'
                name = '共享格子 B · spotify'
                dailyMinutes = 30
                processes = @('spotify')
                shared = $true
            }
        )
    }
    Write-AfsJson (Join-Path $dir 'game-quota-state.json') @{
        version = 4
        date = $today
        targets = @{
            'process:chrome' = 120.0
            'process:code' = 150.0
            'website:example.com' = 30.0
            'process:spotify' = 240.0
        }
    }
    Write-AfsJson (Join-Path $dir 'quota-lan-config.json') @{
        enabled = $true
        port = 8738
        poolMinutes = 60
    }
    Write-AfsJson (Join-Path $dir 'quota-lan-state.json') @{
        date = $today
        pools = @{
            'shared:test1111' = @{
                phoneUsedSeconds = 60.0
                phoneGroup = 'phone-a'
                phoneApps = @(@{ name = 'Phone App A'; seconds = 60.0 })
                updatedAt = $now.ToString('o')
            }
            'shared:test2222' = @{
                phoneUsedSeconds = 30.0
                phoneGroup = 'phone-b'
                phoneApps = @(@{ name = 'Phone App B'; seconds = 30.0 })
                updatedAt = $now.ToString('o')
            }
        }
    }

    $byRule = Get-AfsQuotaPcSharedByRule $dir $now
    Assert ($byRule['shared:test1111'].used -eq 300) 'Pool A must only sum its own PC members'
    Assert ($byRule['shared:test2222'].used -eq 240) 'Pool B must only sum its own PC members'
    Assert ($byRule['shared:test1111'].minutes -eq 60 -and @($byRule['shared:test1111'].apps).Count -eq 3) 'Pool A includes its website usage and detail'
    Assert ($byRule['shared:test2222'].minutes -eq 30 -and @($byRule['shared:test2222'].apps).Count -eq 1) 'Pool B keeps its own budget and detail'

    $view = Get-AfsQuotaPoolView $dir $now
    $quotaConfig = Read-AfsJson -Path (Join-Path $dir 'game-quota-config.json')
    $sharedUsage = Get-AfsQuotaSharedUsage $dir $now $quotaConfig.rules
    Assert ($sharedUsage['shared:test1111'].usedSeconds -eq 60 -and $sharedUsage['shared:test2222'].usedSeconds -eq 30) 'Quota endpoint and engine read each phone slice independently'
    Assert (@($view.pools).Count -eq 2) 'View must expose both shared pools'
    Assert ($view.sharedRules.Count -eq 2) 'View must list every shared rule id'
    $poolA = @($view.pools | Where-Object { $_.id -eq 'shared:test1111' })[0]
    $poolB = @($view.pools | Where-Object { $_.id -eq 'shared:test2222' })[0]
    Assert ($view.pools[0].id -eq $poolA.id -and $view.pools[1].id -eq $poolB.id) 'Pool order follows saved shared cells and keeps stable ids'
    Assert ($poolA.name -eq '跨设备格子 1' -and $poolB.name -eq '跨设备格子 2') 'Pool names use consecutive numbers across unshared cells'
    Assert ($poolA.total -eq 360 -and $poolA.remaining -eq 3240) 'Pool A must combine PC + its own phone slice'
    Assert ($poolB.total -eq 270 -and $poolB.remaining -eq 1530) 'Pool B must combine PC + its own phone slice'
    Assert ($poolA.phoneGroup -eq 'phone-a' -and $poolB.phoneGroup -eq 'phone-b') 'Each pool keeps its own phone binding'
    Assert (-not $poolA.exhausted -and -not $poolB.exhausted) 'Independent pools must not exhaust each other'

    # Writing one pool must not erase the other.
    Write-AfsQuotaLanState -DataDir $dir -Now $now -PhoneUsedSeconds 90 -PhoneGroup 'phone-b2' -PoolId 'shared:test2222'
    $afterWrite = Read-AfsQuotaLanState $dir $now
    Assert ($afterWrite.pools['shared:test1111'].phoneUsedSeconds -eq 60) 'Writing pool B must keep pool A intact'
    Assert ($afterWrite.pools['shared:test2222'].phoneUsedSeconds -eq 90) 'Writing pool B must update only pool B'

    # Legacy single-pool file: only the first shared rule claims it.
    Write-AfsJson (Join-Path $dir 'quota-lan-state.json') @{
        date = $today
        phoneUsedSeconds = 45.0
        phoneGroup = 'legacy-phone'
        phoneApps = @(@{ name = 'Legacy App'; seconds = 45.0 })
        updatedAt = $now.ToString('o')
    }
    $legacy = Get-AfsQuotaPoolView $dir $now
    $legacyA = @($legacy.pools | Where-Object { $_.id -eq 'shared:test1111' })[0]
    $legacyB = @($legacy.pools | Where-Object { $_.id -eq 'shared:test2222' })[0]
    Assert ($legacyA.phoneUsed -eq 45 -and $legacyA.phoneGroup -eq 'legacy-phone') 'Legacy phone slice belongs to the first shared rule'
    Assert ($legacyB.phoneUsed -eq 0 -and -not $legacyB.phoneGroup) 'Legacy phone slice must not leak into the second rule'
    'PASS: multiple shared cells keep independent PC and phone slices'
}
finally {
    Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
}
