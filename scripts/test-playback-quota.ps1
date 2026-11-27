$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\src\game-quota.ps1" -LibraryOnly

function Assert($Condition, $Message) {
    if (-not $Condition) { throw $Message }
}

$now = [datetime]'2026-11-25T12:00:00'
$tmp = Join-Path $env:TEMP ('afs-playback-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    $client = 'em-monitor-test01'
    Save-AfsPlaybackHeartbeat -DataDir $tmp -ClientId $client -Now $now -Reports @(
        @{tabId=11; host='www.youtube.com'; title='Background video'; playing=$true; background=$true}
        @{tabId=12; host='www.bilibili.com'; title='Foreground video'; playing=$true; background=$false}
        @{tabId=13; host='not a host'; title='Ignored'; playing=$true; background=$true}
    ) | Out-Null

    $snapshot = Get-AfsPlaybackSnapshot $tmp $now
    Assert ($snapshot.connected) 'A fresh monitor heartbeat must be connected'
    Assert (@($snapshot.active).Count -eq 2) 'Invalid hosts must be dropped'
    Assert (@($snapshot.backgroundHosts) -contains 'www.youtube.com') 'Background playback host missing'
    Assert (@($snapshot.backgroundHosts) -notcontains 'www.bilibili.com') 'Foreground playback must not be reported as background'

    $cfg = ConvertTo-AfsAppQuotaConfig @{enabled=$true; rules=@(
        @{type='website';name='youtube.com';dailyMinutes=10;days=@(1..7)}
        @{type='website';name='bilibili.com';dailyMinutes=10;days=@(1..7)}
    )}
    Assert ([bool]$cfg.playback.enabled) 'Background playback must count toward website quotas by default'
    $ids = @(Get-AfsPlaybackTargetIds $snapshot $cfg.rules)
    Assert ($ids.Count -eq 1 -and $ids[0] -eq 'website:youtube.com') 'Only the background website may be charged'
    $hostMap = Get-AfsPlaybackRuleHostMap $snapshot $cfg.rules
    Assert ($hostMap['website:youtube.com'] -eq 'www.youtube.com') 'Playback history must keep the reporting host'

    $state = Update-AfsAppQuotaState $null $cfg $now
    $state = Update-AfsAppQuotaState $state $cfg $now 5 @() 0 0 $null -BackgroundPlaybackIds $ids
    Assert ($state.targets['website:youtube.com'] -eq 5) 'Background media must consume the website allowance'
    Assert ($state.apps['website:youtube.com'].playbackSeconds -eq 5) 'Playback seconds must be attributed to the rule'
    Assert ($state.apps['website:bilibili.com'].usedSeconds -eq 0) 'Unrelated rules must stay untouched'

    $state = Update-AfsAppQuotaState $state $cfg $now 1 @('website:youtube.com') 0 0 $null -BackgroundPlaybackIds $ids
    Assert ($state.targets['website:youtube.com'] -eq 6) 'Foreground and background overlap must count once'
    Assert ($state.apps['website:youtube.com'].playbackSeconds -eq 5) 'Foreground overlap must not inflate background statistics'

    $offCfg = ConvertTo-AfsAppQuotaConfig @{enabled=$true; playback=@{enabled=$false}; rules=@(
        @{type='website';name='youtube.com';dailyMinutes=10;days=@(1..7)}
    )}
    $offState = Update-AfsAppQuotaState $null $offCfg $now
    $offState = Update-AfsAppQuotaState $offState $offCfg $now 5 @() 0 0 $null -BackgroundPlaybackIds $ids
    Assert ($offState.targets['website:youtube.com'] -eq 0) 'Switch off must stop background playback from consuming website quota'
    Assert ($offState.apps['website:youtube.com'].playbackSeconds -eq 0) 'Switch off must not record background playback seconds'
    $offState = Update-AfsAppQuotaState $offState $offCfg $now 2 @('website:youtube.com') 0 0 $null -BackgroundPlaybackIds $ids
    Assert ($offState.targets['website:youtube.com'] -eq 2) 'Foreground website time must still count when background playback is off'

    $sharedCfg = ConvertTo-AfsAppQuotaConfig @{enabled=$true; rules=@(
        @{type='shared';id='shared:play0001';name='Video';dailyMinutes=10;websites=@('youtube.com','bilibili.com')}
    )}
    $sharedState = Update-AfsAppQuotaState $null $sharedCfg $now
    $sharedState = Update-AfsAppQuotaState $sharedState $sharedCfg $now 5 @() 0 0 $null -BackgroundPlaybackIds @('website:youtube.com','website:bilibili.com')
    Assert ($sharedState.apps['shared:play0001'].usedSeconds -eq 5) 'Two background websites in one shared cell must count wall time once'

    $history = @{version=1;days=@{}}
    $history = Add-AfsPlaybackHistory $history $now 12.5 'www.youtube.com'
    Save-AfsPlaybackHistory $tmp $history
    $view = Get-AfsPlaybackView $tmp $now
    Assert ($view.todaySeconds -eq 12.5) 'Today playback total must be persisted'
    Assert (@($view.hosts).Count -eq 1 -and $view.hosts[0].host -eq 'www.youtube.com') 'Host totals must be persisted'
    Assert (@($view.days).Count -eq 7) 'Trend must expose seven quota days'

    Save-AfsPlaybackHeartbeat -DataDir $tmp -ClientId $client -Now $now.AddSeconds(-60) -Reports @(
        @{tabId=21; host='youtube.com'; title='Stale'; playing=$true; background=$true}
    ) | Out-Null
    $stale = Get-AfsPlaybackSnapshot $tmp $now
    Assert (-not $stale.connected) 'A stale monitor heartbeat must not stay connected'
    Assert (@($stale.active).Count -eq 0) 'Stale playback must not be charged'

    $state.targets['website:youtube.com'] = 600
    $state = Update-AfsAppQuotaState $state $cfg $now
    $closeTabs = @(Get-AfsPlaybackCloseTabs -Reports @(
        @{tabId=31; host='m.youtube.com'; playing=$true; background=$true}
        @{tabId=32; host='bilibili.com'; playing=$true; background=$true}
    ) -Config $cfg -State $state -Now $now)
    Assert ($closeTabs.Count -eq 1 -and $closeTabs[0] -eq 31) 'Exhausted background tabs must be selected for closing'
    $closeOff = @(Get-AfsPlaybackCloseTabs -Reports @(
        @{tabId=33; host='m.youtube.com'; playing=$true; background=$true}
    ) -Config $offCfg -State $state -Now $now)
    Assert ($closeOff.Count -eq 0) 'Switch off must not close background playback tabs'

    $workerDir = Join-Path $env:TEMP ('afs-playback-worker-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workerDir -Force | Out-Null
    $worker = $null
    try {
        Write-AfsJson (Join-Path $workerDir 'game-quota-config.json') @{enabled=$false; rules=@()}
        $mutexName = 'Local\AwayFromShorts-GameQuotaTest-' + [guid]::NewGuid().ToString('N')
        $worker = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $PSScriptRoot '..\src\game-quota.ps1') + '"'),
            '-DataDir', ('"' + $workerDir + '"'), '-MutexName', ('"' + $mutexName + '"')
        )
        $statePath = Join-Path $workerDir 'game-quota-state.json'
        $deadline = (Get-Date).AddSeconds(8)
        while (-not (Test-Path -LiteralPath $statePath) -and -not $worker.HasExited -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 200
        }
        Assert (-not $worker.HasExited) 'The quota worker must stay running after startup'
        Assert (Test-Path -LiteralPath $statePath) 'The quota worker must write its initial state'
        Assert (-not (Test-Path -LiteralPath (Join-Path $workerDir 'game-quota-error.log'))) 'The quota worker must start without an exception'
    } finally {
        if ($worker -and -not $worker.HasExited) {
            $worker.Kill()
            $worker.WaitForExit(3000) | Out-Null
        }
        if ($worker) { $worker.Dispose() }
        Remove-Item -LiteralPath $workerDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    'PASS: background playback quota, de-duplication, history and close enforcement'
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
