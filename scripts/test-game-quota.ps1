$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\src\game-quota.ps1" -LibraryOnly
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
$now = [datetime]'2026-10-28T12:00:00'
$noOverride = Join-Path $env:TEMP ('afs-no-quota-override-' + [guid]::NewGuid().ToString('N'))
$lockedWindow = Get-AfsQuotaEditWindow -Now $now -OverridePath $noOverride -MasterEnabled $true -QuotaEnabled $true
Assert (-not $lockedWindow.allowed -and -not $lockedWindow.unlocked) 'Active quota keeps the configured edit window'
$masterOffWindow = Get-AfsQuotaEditWindow -Now $now -OverridePath $noOverride -MasterEnabled $false -QuotaEnabled $true
Assert ($masterOffWindow.allowed -and $masterOffWindow.unlocked -eq 'master-off') 'Master switch off unlocks quota editing'
$quotaOffWindow = Get-AfsQuotaEditWindow -Now $now -OverridePath $noOverride -MasterEnabled $true -QuotaEnabled $false
Assert ($quotaOffWindow.allowed -and $quotaOffWindow.unlocked -eq 'quota-off') 'Quota switch off unlocks quota editing'
$s = @{date='2026-10-28'; usedSeconds=0.0}
$s = Update-AfsGameQuota $s $now 1 $true 7200
$s = Update-AfsGameQuota $s $now.AddSeconds(1) 1 $true 7200
Assert ($s.usedSeconds -eq 2) 'Shared foreground total'
$s = Update-AfsGameQuota $s $now.AddSeconds(2) 1 $false 7200
Assert ($s.usedSeconds -eq 2) 'Background must not count'
$s = Update-AfsGameQuota $s $now.AddHours(2) 7200 $true 7200
Assert ($s.usedSeconds -eq 2) 'Sleep must not count'
$s.usedSeconds = 7199.5
$s = Update-AfsGameQuota $s $now 1 $true 7200
Assert ($s.exhausted -and $s.usedSeconds -eq 7200) 'Stop at shared allowance'
$s = Update-AfsGameQuota $s ([datetime]'2026-10-29T00:00:00.250') 1 $true 7200
Assert (-not $s.exhausted -and $s.usedSeconds -eq 0.25) 'Midnight split and reset'
Assert (Test-AfsGameProcess 'VALORANT-Win64-Shipping' '') 'Valorant detection'
Assert (Test-AfsGameProcess 'steamwebhelper' '') 'Steam foreground web UI'
Assert (Test-AfsGameProcess 'game' 'D:\Library\steamapps\common\Example\game.exe') 'Other Steam library'
Assert (-not (Test-AfsGameProcess 'steamservice' 'C:\Steam\steamservice.exe')) 'Background service exclusion'
Assert (-not (Test-AfsGameProcess 'editor' 'C:\Tools\editor.exe')) 'Unrelated app exclusion'
$custom = ConvertTo-AfsQuotaConfig @{enabled=$true; dailyMinutes=45; includeSteam=$false; includeValorant=$false; processes=@('Chrome.exe','chrome','Code')}
Assert ($custom.processes.Count -eq 2 -and $custom.dailyMinutes -eq 45) 'Normalize custom selection'
Assert (Test-AfsGameProcess 'chrome' 'C:\Chrome\chrome.exe' $custom) 'Selected app matches'
$websiteConfig = ConvertTo-AfsAppQuotaConfig @{version=5; enabled=$true; rules=@(
    @{type='website'; name='https://EXAMPLE.com/path'; dailyMinutes=1; days=@(1..7)}
    @{type='process'; name='editor.exe'; dailyMinutes=10; days=@(1..7)}
)}
$websiteId = 'website:example.com'
Assert ($websiteConfig.rules[0].id -eq $websiteId) 'Normalize website rule to its domain'
Assert ((Get-AfsQuotaWebsiteMatches 'www.example.com' $websiteConfig.rules) -eq $websiteId) 'Website rule includes subdomains'
Assert (-not (Get-AfsQuotaWebsiteMatches 'otherexample.com' $websiteConfig.rules)) 'Website rule matches on label boundaries'
$wwwRule = @{type='website'; name='www.example.com'; id='website:www.example.com'}
Assert ((Get-AfsQuotaWebsiteMatches 'example.com' @($wwwRule)) -eq $wwwRule.id) 'Bare domain uses the saved www quota'
Assert ((Get-AfsQuotaWebsiteMatches 'www.example.com' @($wwwRule)) -eq $wwwRule.id) 'The saved www host continues to use the same quota'
Assert (-not (Get-AfsQuotaWebsiteMatches 'otherexample.com' @($wwwRule))) 'Bare alias matches only the exact domain'
Assert (-not (Get-AfsQuotaMatches 'chrome' '' $websiteConfig.rules)) 'Website rule cannot terminate the browser process'
Assert (-not (Test-AfsQuotaAppendOnly -Current $null -Incoming $websiteConfig)) 'Allow adding a custom website and process outside edit hours'
$websiteState = Update-AfsAppQuotaState $null $websiteConfig $now
$websiteState.targets[$websiteId] = 59.0
$websiteState = Update-AfsAppQuotaState $websiteState $websiteConfig $now 2 @($websiteId)
Assert ($websiteState.apps[$websiteId].exhausted -and $websiteState.apps[$websiteId].usedSeconds -eq 60) 'Website reaches its daily limit independently'
Assert ($websiteState.apps['process:editor'].usedSeconds -eq 0) 'Website use does not count toward an unrelated process'
$memberConfig = ConvertTo-AfsAppQuotaConfig @{version=5; enabled=$true; rules=@(
    @{type='website'; name='example.com'; dailyMinutes=1; processes=@('writer.exe')}
    @{type='process'; name='editor.exe'; dailyMinutes=1; processes=@('helper.exe'); shared=$true}
)}
Assert ((Get-AfsQuotaMatches 'writer' '' $memberConfig.rules) -eq $websiteId) 'Website cell enforces its added process'
Assert ((Get-AfsForegroundQuotaTarget 'helper' '' $memberConfig.rules) -eq 'process:helper') 'Process cell meters its added process'
Assert ('process:helper' -in @(Get-AfsQuotaRuleTargetIds $memberConfig.rules[1])) 'Shared ledger includes the added process'
$memberState = Update-AfsAppQuotaState $null $memberConfig $now 2 @('process:writer')
$memberState = Update-AfsAppQuotaState $memberState $memberConfig $now 3 @($websiteId)
Assert ($memberState.apps[$websiteId].usedSeconds -eq 5) 'Website and added process share one allowance'
$mixedBase = ConvertTo-AfsAppQuotaConfig @{enabled=$true; rules=@(
    @{type='shared'; id='shared:website123'; name='Mixed'; dailyMinutes=1; processes=@('writer.exe')}
)}
$mixedConfig = ConvertTo-AfsAppQuotaConfig @{enabled=$true; rules=@(
    @{type='shared'; id='shared:website123'; name='Mixed'; dailyMinutes=1; processes=@('writer.exe')
      websites=@('https://MIXED.example/path','www.mixed.example'); shared=$true}
)}
$mixedCell = $mixedConfig.rules[0]
$matchedSites = @(Get-AfsQuotaWebsiteMatches 'www.mixed.example' $mixedConfig.rules)
Assert ($mixedCell.websites[0] -eq 'mixed.example') 'Website member is saved as a normalized domain'
Assert ($matchedSites.Count -eq 1 -and $matchedSites[0] -in @(Get-AfsQuotaTargetIds $mixedCell)) 'Overlapping websites in the same cell are metered once'
Assert ($null -eq (Test-AfsQuotaAppendOnly -Current $mixedBase -Incoming $mixedConfig)) 'A website can be added outside edit hours'
$withoutSite = ConvertTo-AfsAppQuotaConfig @{enabled=$true; rules=@(
    @{type='shared'; id='shared:website123'; name='Mixed'; dailyMinutes=1; processes=@('writer.exe'); shared=$true}
)}
Assert ([bool](Test-AfsQuotaAppendOnly -Current $mixedConfig -Incoming $withoutSite)) 'Website members cannot be removed outside edit hours'
$mixedState = Update-AfsAppQuotaState $null $mixedConfig $now 2 @('process:writer')
$mixedState = Update-AfsAppQuotaState $mixedState $mixedConfig $now 3 $matchedSites
Assert ($mixedState.apps[$mixedCell.id].usedSeconds -eq 5) 'Adding a website charges the same allowance as the existing process'
Assert ((Get-AfsQuotaWebsiteMatches 'mixed.example' @($mixedCell)) -in @(Get-AfsQuotaRuleTargetIds $mixedCell)) 'Cross-device ledger includes matched website targets'
$websiteConfig.rules[0].shared = $true
$websiteConfig = ConvertTo-AfsAppQuotaConfig $websiteConfig
Assert ($websiteConfig.rules[0].shared) 'Website rule retains cross-device sharing when saved'
$websiteState = Update-AfsAppQuotaState $websiteState $websiteConfig $now 0 @() 0 0 @{
    'website:example.com' = @{usedSeconds=20; minutes=1}
}
Assert ($websiteState.apps[$websiteId].exhausted) 'Website pool enforces combined PC and phone usage'
Assert (-not (Test-AfsGameProcess 'steam' '' $custom)) 'Unselected preset excluded'
Assert (-not (Test-AfsGameProcess 'VALORANT' '' $custom)) 'Unselected Valorant excluded'
$legacy = ConvertTo-AfsQuotaConfig @{enabled=$true; dailyMinutes=120}
Assert ($legacy.includeSteam -and $legacy.includeValorant) 'Legacy settings migration'
foreach ($bad in @(
    @{enabled=$true; dailyMinutes=0},
    @{enabled=$true; dailyMinutes=1441},
    @{enabled=$true; dailyMinutes=1.5},
    @{enabled=$true; dailyMinutes=60; includeSteam=$false; includeValorant=$false; processes=@()},
    @{enabled=$true; dailyMinutes=60; processes=@('C:\app.exe')},
    @{enabled=$true; dailyMinutes=60; processes=@('powershell.exe')}
)) {
    $rejected = $false
    try { ConvertTo-AfsQuotaConfig $bad | Out-Null } catch { $rejected = $true }
    Assert $rejected 'Invalid custom settings must be rejected'
}
$keep = @{date='2026-10-28';usedSeconds=5400.0}
$keep = Update-AfsGameQuota $keep $now 1 $true 3600
Assert ($keep.exhausted -and $keep.usedSeconds -eq 5400) 'Lowering limit preserves used time'
$keep = Update-AfsGameQuota $keep $now 0 $false 7200
Assert ($keep.remainingSeconds -eq 1800) 'Raising limit uses original usage'
$tmp = Join-Path $env:TEMP ('afs-quota-test-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    Write-AfsJson $tmp $s
    $r = Read-AfsGameQuotaState $tmp ([datetime]'2026-10-29') 7200
    Assert ($r.usedSeconds -eq 0.25) 'Persistence across restart'
    [IO.File]::WriteAllText($tmp, '{broken')
    $r = Read-AfsGameQuotaState $tmp $now 7200
    Assert ($r.usedSeconds -eq 7200 -and $r.error) 'Corrupt state must not grant time'
} finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
# Exercise real termination and relaunch handling using harmless hidden children.
foreach ($attempt in 1..2) {
    $child = Start-Process powershell.exe -ArgumentList '-NoProfile -Command "Start-Sleep -Seconds 60"' -WindowStyle Hidden -PassThru
    try {
        $failures = @(Stop-AfsGameQuotaProcesses @([pscustomobject]@{Id=$child.Id; ProcessName='steam'; Path=''}))
        $child.WaitForExit(5000) | Out-Null
        Assert ($child.HasExited -and $failures.Count -eq 0) 'Termination and relaunch interception'
    } finally { if (-not $child.HasExited) { $child.Kill() }; $child.Dispose() }
}
$cfg = ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(
    @{type='steam';dailyMinutes=30},
    @{type='valorant';dailyMinutes=60},
    @{type='process';name='Chrome.exe';dailyMinutes=15}
)}
Assert ($cfg.rules.Count -eq 3 -and $cfg.rules[2].id -eq 'process:chrome') 'Independent rule normalization'
$s = @{date='2026-10-28';apps=@{}}
$s = Update-AfsAppQuotaState $s $cfg $now 1 @('steam')
Assert ($s.apps.steam.usedSeconds -eq 1 -and $s.apps.valorant.usedSeconds -eq 0) 'Foreground counts only matching app'
$s.targets.steam=1800.0
$s = Update-AfsAppQuotaState $s $cfg $now 1 @('valorant')
Assert ($s.apps.steam.exhausted -and -not $s.apps.valorant.exhausted -and $s.apps.valorant.usedSeconds -eq 1) 'One app exhaustion does not block another'
$shared=ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(@{type='games';dailyMinutes=40})}
$merged=Update-AfsAppQuotaState $s $shared $now 1 @('valorant')
Assert ($merged.apps.games.usedSeconds -eq 1802 -and $merged.apps.games.remainingSeconds -eq 598) 'Merged group sums prior individual usage'
Assert (@(Get-AfsQuotaMatches 'steam' '' $shared.rules)[0] -eq 'games') 'Steam matches shared group'
Assert (@(Get-AfsQuotaMatches 'VALORANT' '' $shared.rules)[0] -eq 'games') 'Valorant matches shared group'
$split=Update-AfsAppQuotaState $merged $cfg $now
Assert ($split.apps.steam.usedSeconds -eq 1800 -and $split.apps.valorant.usedSeconds -eq 2) 'Split restores exact per-app usage'
Assert ((Get-AfsForegroundQuotaTarget 'VALORANT' 'D:\steamapps\common\VALORANT\app.exe' $shared.rules) -eq 'valorant') 'Shared foreground interval counted once'
$groupState=@{date='2026-10-28';targets=@{steam=2399.5;valorant=0.0}}
$groupState=Update-AfsAppQuotaState $groupState $shared $now 1 @('valorant')
Assert ($groupState.apps.games.exhausted -and $groupState.apps.games.usedSeconds -eq 2400) 'Shared cap stops combined usage'
$noCount=Update-AfsAppQuotaState $split $cfg $now 600 @('valorant')
Assert ($noCount.targets.valorant -eq 2) 'Suspension not counted by per-target ledger'
$rejected=$false
try { ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(@{type='games';dailyMinutes=30},@{type='steam';dailyMinutes=30})} | Out-Null } catch { $rejected=$true }
Assert $rejected 'Cannot put same preset in shared and independent groups simultaneously'
Assert (@(Get-AfsQuotaMatches 'chrome' '' $cfg.rules)[0] -eq 'process:chrome') 'Custom app mapping'
$migrated = ConvertTo-AfsAppQuotaConfig @{enabled=$true;dailyMinutes=120;includeSteam=$true;includeValorant=$true;processes=@()}
Assert ($migrated.rules.Count -eq 2 -and $migrated.rules[0].dailyMinutes -eq 120) 'Legacy shared config migrates'
$legacyState=Update-AfsAppQuotaState @{date='2026-10-28';usedSeconds=99.0} $migrated $now
Assert ($legacyState.apps.steam.usedSeconds -eq 99 -and $legacyState.apps.valorant.usedSeconds -eq 99) 'Migration preserves usage'
$s=Update-AfsAppQuotaState $s $cfg ([datetime]'2026-10-29T08:00:00')
Assert ($s.apps.steam.usedSeconds -eq 0 -and $s.apps.valorant.usedSeconds -eq 0) 'Independent quota-day reset'
foreach ($time in @('2026-10-28T01:00:00','2026-10-28T12:00:00','2026-10-28T23:59:59')) {
    Assert (-not (Get-AfsQuotaEditWindow ([datetime]$time)).allowed) 'Outside the adjustment window must lock'
}
foreach ($time in @('2026-10-28T00:00:00','2026-10-28T00:59:59')) {
    Assert ((Get-AfsQuotaEditWindow ([datetime]$time)).allowed) 'Adjustment window must allow editing'
}
Assert ((Get-AfsQuotaEditWindow ([datetime]'2026-10-28T23:00:00')).next -like '2026-10-29T00:00:00*') 'Next edit window is tomorrow'
$children=@()
try {
    foreach ($i in 1..2) { $children += Start-Process powershell.exe -ArgumentList '-NoProfile -Command "Start-Sleep -Seconds 60"' -WindowStyle Hidden -PassThru }
    $fake=@([pscustomobject]@{Id=$children[0].Id;ProcessName='steam';Path=''},[pscustomobject]@{Id=$children[1].Id;ProcessName='VALORANT';Path=''})
    $failures=@(Stop-AfsAppQuotaProcesses $fake @($cfg.rules | Where-Object { $_.id -eq 'steam' }))
    $children[0].WaitForExit(5000) | Out-Null
    Assert ($children[0].HasExited -and -not $children[1].HasExited -and $failures.Count -eq 0) 'Only exhausted app is terminated'
} finally { foreach ($c in $children) { if (-not $c.HasExited) { $c.Kill() }; $c.Dispose() } }

# ---- shared cell with extra processes (e.g. 无畏契约 + Steam + pvzge-0.16.1) ----
$sharedExtra = ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(@{type='games';dailyMinutes=40;processes=@('pvzge-0.16.1.exe')})}
Assert ($sharedExtra.rules.Count -eq 1 -and $sharedExtra.rules[0].id -eq 'games') 'Shared cell keeps a single id'
Assert (@($sharedExtra.rules[0].processes).Count -eq 1 -and $sharedExtra.rules[0].processes[0] -eq 'pvzge-0.16.1') 'Extra process normalized (lowercase, no .exe)'
Assert ($sharedExtra.rules[0].name -like '*pvzge-0.16.1*（共享）') 'Shared cell name lists all members'
Assert (@(Get-AfsQuotaTargetIds $sharedExtra.rules[0]).Count -eq 3) 'Shared cell has three targets'
Assert ((Get-AfsForegroundQuotaTarget 'pvzge-0.16.1' 'C:\Games\pvzge-0.16.1.exe' $sharedExtra.rules) -eq 'process:pvzge-0.16.1') 'Extra process maps to its own target'
Assert ((Get-AfsForegroundQuotaTarget 'VALORANT' '' $sharedExtra.rules) -eq 'valorant') 'Valorant still maps correctly'
Assert (@(Get-AfsQuotaMatches 'pvzge-0.16.1' 'C:\Games\pvzge-0.16.1.exe' $sharedExtra.rules)[0] -eq 'games') 'Extra process matches the shared cell for closing'
$sharedState=@{date='2026-10-28';targets=@{valorant=100.0;steam=50.0;'process:pvzge-0.16.1'=0.0}}
$sharedState=Update-AfsAppQuotaState $sharedState $sharedExtra $now 1 @('process:pvzge-0.16.1')
Assert ($sharedState.apps.games.usedSeconds -eq 151 -and -not $sharedState.apps.games.exhausted) 'Extra process consumes the same shared allowance'
$sharedState.targets.valorant = 3900.0
$sharedState=Update-AfsAppQuotaState $sharedState $sharedExtra $now 1 @('process:pvzge-0.16.1')
Assert ($sharedState.apps.games.exhausted) 'Shared cap reached by combined usage'
$rejDup=$false
try { ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(@{type='games';dailyMinutes=30;processes=@('steam')})} | Out-Null } catch { $rejDup=$true }
Assert $rejDup 'Steam cannot be added twice into the shared cell'
$rejPath=$false
try { ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(@{type='games';dailyMinutes=30;processes=@('C:\evil.exe')})} | Out-Null } catch { $rejPath=$true }
Assert $rejPath 'Path-like extra process rejected'
$rejProtected=$false
try { ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(@{type='games';dailyMinutes=30;processes=@('powershell')})} | Out-Null } catch { $rejProtected=$true }
Assert $rejProtected 'Protected process rejected inside shared cell'
$noExtra = ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(@{type='games';dailyMinutes=30})}
Assert ($noExtra.rules[0].name -eq '无畏契约 + Steam（共享）' -and -not $noExtra.rules[0].ContainsKey('processes')) 'Shared cell without extras stays unchanged'
# ---- 自由共享格子: 任意应用共用一个额度，id 稳定 ----
$customShared = ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(
    @{id='shared:abc12345';type='shared';name='工作共享';dailyMinutes=30;processes=@('Chrome.exe','code')}
)}
Assert ($customShared.rules.Count -eq 1 -and $customShared.rules[0].id -eq 'shared:abc12345') 'Custom shared cell keeps stable id'
Assert ($customShared.rules[0].name -eq '工作共享' -and @($customShared.rules[0].processes).Count -eq 2) 'Custom shared cell keeps name and members'
Assert (@(Get-AfsQuotaTargetIds $customShared.rules[0]).Count -eq 2) 'Custom shared cell has two target ids'
Assert ((Get-AfsForegroundQuotaTarget 'chrome' 'C:\Apps\chrome.exe' $customShared.rules) -eq 'process:chrome') 'Custom shared foreground maps to its member'
Assert (@(Get-AfsQuotaMatches 'code' 'C:\Apps\Code.exe' $customShared.rules)[0] -eq 'shared:abc12345') 'Custom shared cell closes every member'
$customState=@{date='2026-10-28';targets=@{'process:chrome'=100.0;'process:code'=50.0}}
$customState=Update-AfsAppQuotaState $customState $customShared $now 1 @('process:chrome')
Assert ($customState.apps.'shared:abc12345'.usedSeconds -eq 151 -and -not $customState.apps.'shared:abc12345'.exhausted) 'Custom shared members consume one allowance'
$emptyShared = ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(
    @{id='shared:empty123';type='shared';name='手机共享池';dailyMinutes=120}
)}
Assert ($emptyShared.rules[0].id -eq 'shared:empty123' -and -not $emptyShared.rules[0].ContainsKey('processes')) 'Empty custom shared cell is allowed'
Assert (@(Get-AfsQuotaTargetIds $emptyShared.rules[0]).Count -eq 0) 'Empty custom shared cell has no PC targets'
$rejSharedDup=$false
try { ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(
    @{id='shared:abc12345';type='shared';dailyMinutes=30;processes=@('chrome')},
    @{type='process';name='chrome';dailyMinutes=15}
)} | Out-Null } catch { $rejSharedDup=$true }
Assert $rejSharedDup 'Custom shared cell cannot duplicate another cell member'
# ---- 多个跨设备共享池: 手机用量按规则 id 分别记账 ----
$multiShared = ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(
    @{id='shared:poolaaaa';type='shared';name='池 A';dailyMinutes=60;processes=@('chrome');shared=$true},
    @{id='shared:poolbbbb';type='shared';name='池 B';dailyMinutes=30;processes=@('code');shared=$true}
)}
Assert ($multiShared.rules.Count -eq 2 -and @($multiShared.rules | Where-Object { $_.shared }).Count -eq 2) 'Multiple shared rules are allowed'
$multiState=@{date='2026-10-28';targets=@{'process:chrome'=100.0;'process:code'=200.0}}
$multiPools=@{
    'shared:poolaaaa'=@{usedSeconds=2000.0;minutes=60}
    'shared:poolbbbb'=@{usedSeconds=200.0;minutes=30}
}
$multiState=Update-AfsAppQuotaState $multiState $multiShared $now 1 @('process:chrome','process:code') 0 0 $multiPools
Assert ($multiState.apps.'shared:poolaaaa'.chargedSeconds -eq 2101) 'Pool A charges only its own phone slice'
Assert ($multiState.apps.'shared:poolbbbb'.chargedSeconds -eq 401) 'Pool B charges only its own phone slice'
Assert (-not $multiState.apps.'shared:poolaaaa'.exhausted -and -not $multiState.apps.'shared:poolbbbb'.exhausted) 'Independent pools stay under their own limits'
$drainedPools=@{
    'shared:poolaaaa'=@{usedSeconds=3600.0;minutes=60}
    'shared:poolbbbb'=@{usedSeconds=0.0;minutes=30}
}
$beforeA=$multiState.targets['process:chrome']; $beforeB=$multiState.targets['process:code']
$multiState=Update-AfsAppQuotaState $multiState $multiShared $now 1 @('process:chrome','process:code') 0 0 $drainedPools
Assert ($multiState.targets['process:chrome'] -eq $beforeA) 'Exhausted pool A must stop charging its member'
Assert ($multiState.targets['process:code'] -eq ($beforeB + 1)) 'Pool B must keep charging while pool A is exhausted'
# ---- 规定时间以外的「只进不出」: 加可以, 删/改时长不行, 但限额开关随时可关 ----
$qBase = ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(
    @{type='games';dailyMinutes=60;processes=@('pvzge-0.16.1')},
    @{type='process';name='chrome';dailyMinutes=15}
)}
$qAddProc = ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(
    @{type='games';dailyMinutes=60;processes=@('pvzge-0.16.1','lively')},
    @{type='process';name='chrome';dailyMinutes=15}
)}
Assert ($null -eq (Test-AfsQuotaAppendOnly -Current $qBase -Incoming $qAddProc)) 'Off-window: adding a shared-cell process is allowed'
$qDelProc = ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(
    @{type='games';dailyMinutes=60;processes=@()},
    @{type='process';name='chrome';dailyMinutes=15}
)}
Assert ([bool](Test-AfsQuotaAppendOnly -Current $qBase -Incoming $qDelProc)) 'Off-window: removing a shared-cell process is rejected'
$qAddApp = ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(
    @{type='games';dailyMinutes=60;processes=@('pvzge-0.16.1')},
    @{type='process';name='chrome';dailyMinutes=15},
    @{type='process';name='notepad';dailyMinutes=120}
)}
Assert ($null -eq (Test-AfsQuotaAppendOnly -Current $qBase -Incoming $qAddApp)) 'Off-window: adding an app (120 min) is allowed'
$qAddShared = ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(
    @{type='games';dailyMinutes=60;processes=@('pvzge-0.16.1')},
    @{type='process';name='chrome';dailyMinutes=15},
    @{id='shared:newcell01';type='shared';name='新共享';dailyMinutes=120;processes=@('notepad','calc')}
)}
Assert ($null -eq (Test-AfsQuotaAppendOnly -Current $qBase -Incoming $qAddShared)) 'Off-window: adding a custom shared cell at 120 min is allowed'
$qAddEmptyShared = ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(
    @{type='games';dailyMinutes=60;processes=@('pvzge-0.16.1')},
    @{type='process';name='chrome';dailyMinutes=15},
    @{id='shared:newcell02';type='shared';name='手机共享池';dailyMinutes=120}
)}
Assert ($null -eq (Test-AfsQuotaAppendOnly -Current $qBase -Incoming $qAddEmptyShared)) 'Off-window: adding an empty custom shared cell is allowed'
$qAddBig = ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(
    @{type='games';dailyMinutes=60;processes=@('pvzge-0.16.1')},
    @{type='process';name='chrome';dailyMinutes=15},
    @{type='process';name='notepad';dailyMinutes=1440}
)}
Assert ([bool](Test-AfsQuotaAppendOnly -Current $qBase -Incoming $qAddBig)) 'Off-window: adding an app above 120 min is rejected'
$qDelRule = ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(@{type='games';dailyMinutes=60;processes=@('pvzge-0.16.1')})}
Assert ([bool](Test-AfsQuotaAppendOnly -Current $qBase -Incoming $qDelRule)) 'Off-window: removing an app is rejected'
$qChgTime = ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(
    @{type='games';dailyMinutes=90;processes=@('pvzge-0.16.1')},
    @{type='process';name='chrome';dailyMinutes=15}
)}
Assert ([bool](Test-AfsQuotaAppendOnly -Current $qBase -Incoming $qChgTime)) 'Off-window: changing the daily minutes is rejected'
$qOff = ConvertTo-AfsAppQuotaConfig @{enabled=$false;rules=@(
    @{type='games';dailyMinutes=60;processes=@('pvzge-0.16.1')},
    @{type='process';name='chrome';dailyMinutes=15}
)}
Assert ($null -eq (Test-AfsQuotaAppendOnly -Current $qBase -Incoming $qOff)) 'Off-window: switching the quota off is allowed'
Assert (-not (Test-AfsQuotaAppendOnly -Current $qOff -Incoming $qBase)) 'Off-window: enabling existing quota rules is allowed'
$qSplit = ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(
    @{type='valorant';dailyMinutes=60},@{type='steam';dailyMinutes=60},
    @{type='process';name='chrome';dailyMinutes=15}
)}
Assert ([bool](Test-AfsQuotaAppendOnly -Current $qBase -Incoming $qSplit)) 'Off-window: splitting the shared cell is rejected'
Assert ($null -eq (Test-AfsQuotaAppendOnly -Current $qBase -Incoming $qBase)) 'Off-window: unchanged config is allowed'
$qPlaybackOn = ConvertTo-AfsAppQuotaConfig @{enabled=$true;playback=@{enabled=$true};rules=@(
    @{type='process';name='chrome';dailyMinutes=15}
)}
$qPlaybackOff = ConvertTo-AfsAppQuotaConfig @{enabled=$true;playback=@{enabled=$false};rules=@(
    @{type='process';name='chrome';dailyMinutes=15}
)}
Assert ([bool](Test-AfsQuotaAppendOnly -Current $qPlaybackOn -Incoming $qPlaybackOff)) 'Off-window: turning background playback counting off is rejected'
Assert ($null -eq (Test-AfsQuotaAppendOnly -Current $qPlaybackOff -Incoming $qPlaybackOn)) 'Off-window: turning background playback counting on is allowed'
$rejectedPlayback = $false
try {
    ConvertTo-AfsAppQuotaConfig @{enabled=$true;playback=@{enabled='yes'};rules=@(
        @{type='process';name='chrome';dailyMinutes=15}
    )} | Out-Null
} catch { $rejectedPlayback = $true }
Assert $rejectedPlayback 'Background playback switch must be a boolean'
# ---- 每条时间限额的生效星期 ----
$legacyDays = ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(
    @{type='process';name='chrome';dailyMinutes=15}
)}
Assert (($legacyDays.rules[0].days -join ',') -eq '1,2,3,4,5,6,7') 'Legacy quota rules default to all seven days'
$weekdayCfg = ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(
    @{type='process';name='chrome';dailyMinutes=15;days=@(2)}
    @{type='process';name='notepad';dailyMinutes=20;days=@(1,3,5)}
)}
$monday = [datetime]'2026-10-26T12:00:00'
$tuesday = [datetime]'2026-10-27T12:00:00'
Assert ((Get-AfsQuotaWeekday $monday) -eq 1 -and (Get-AfsQuotaWeekday ([datetime]'2026-11-01T12:00:00')) -eq 7) 'Weekday numbering is Monday=1 and Sunday=7'
Assert (-not (Test-AfsQuotaRuleActive $weekdayCfg.rules[0] $monday) -and (Test-AfsQuotaRuleActive $weekdayCfg.rules[0] $tuesday)) 'Rule weekday gating'
$weekdayState = @{date='2026-10-26';targets=@{'process:chrome'=0.0;'process:notepad'=0.0}}
$weekdayState = Update-AfsAppQuotaState $weekdayState $weekdayCfg $monday 10 @('process:chrome','process:notepad')
Assert ($weekdayState.targets['process:chrome'] -eq 0 -and -not $weekdayState.apps.'process:chrome'.activeToday) 'Inactive weekday does not accumulate'
Assert ($weekdayState.targets['process:notepad'] -ge 0 -and $weekdayState.apps.'process:notepad'.activeToday) 'Only enabled weekday participates'
$weekdayState = Update-AfsAppQuotaState $weekdayState $weekdayCfg $tuesday 1 @('process:chrome')
Assert ($weekdayState.targets['process:chrome'] -eq 1 -and $weekdayState.apps.'process:chrome'.activeToday) 'Enabled weekday accumulates foreground seconds'
$qDayChanged = ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(
    @{type='process';name='chrome';dailyMinutes=15;days=@(1,2)}
)}
Assert ([bool](Test-AfsQuotaAppendOnly -Current $legacyDays -Incoming $qDayChanged)) 'Off-window: changing quota weekdays is rejected'
foreach ($badDays in @(@(), @(0), @(8), @(1,2,2.5))) {
    $rejectedDays = $false
    try {
        ConvertTo-AfsAppQuotaConfig @{enabled=$true;rules=@(@{type='process';name='chrome';dailyMinutes=15;days=$badDays})} | Out-Null
    } catch { $rejectedDays = $true }
    Assert $rejectedDays 'Invalid weekday values are rejected'
}
'PASS: independent app quotas, selective termination, weekday gating, migration, midnight, edit window boundaries and legacy regressions'
