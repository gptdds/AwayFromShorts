# Runs in the interactive desktop; independent of study/scheduled blocking.
param(
    [string]$DataDir = $PSScriptRoot,
    [switch]$LibraryOnly,
    [string]$MutexName = 'Local\AwayFromShorts-GameQuota'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\core.ps1"
. "$PSScriptRoot\quota-rules.ps1"
. "$PSScriptRoot\quota-ledger.ps1"


function Update-AfsGameQuota {
    param([hashtable]$State, [datetime]$Now, [double]$Elapsed, [bool]$WasForeground, [int]$LimitSeconds)
    $date = $Now.ToString('yyyy-MM-dd')
    if ($State.date -ne $date) {
        $State.date = $date
        $State.usedSeconds = 0.0
        # Only the part of this interval after local midnight belongs to today.
        $Elapsed = [Math]::Min($Elapsed, $Now.TimeOfDay.TotalSeconds)
    }
    # Ignore suspension/sleep and large polling gaps; use monotonic elapsed time.
    if ($WasForeground -and $Elapsed -gt 0 -and $Elapsed -le 5) {
        $State.usedSeconds = [Math]::Max([double]$State.usedSeconds, [Math]::Min([double]$LimitSeconds, [double]$State.usedSeconds + $Elapsed))
    }
    $State.limitSeconds = $LimitSeconds
    $State.remainingSeconds = [Math]::Max(0.0, $LimitSeconds - [double]$State.usedSeconds)
    $State.exhausted = ($State.remainingSeconds -le 0)
    $State.updatedAt = $Now.ToString('o')
    return $State
}

function Read-AfsGameQuotaState {
    param([string]$Path, [datetime]$Now, [int]$LimitSeconds)
    if (-not (Test-Path -LiteralPath $Path)) { return @{date=$Now.ToString('yyyy-MM-dd'); usedSeconds=0.0} }
    try {
        $s = Read-AfsJson $Path
        if ($s.date -notmatch '^\d{4}-\d{2}-\d{2}$' -or $null -eq $s.usedSeconds -or
            [double]$s.usedSeconds -lt 0 -or [double]::IsNaN([double]$s.usedSeconds) -or
            [double]::IsInfinity([double]$s.usedSeconds)) { throw 'Invalid quota state' }
        return $s
    } catch {
        # Never silently grant another daily allowance after a damaged file.
        return @{date=$Now.ToString('yyyy-MM-dd'); usedSeconds=[double]$LimitSeconds; error='Quota state unreadable'}
    }
}

function Stop-AfsGameQuotaProcesses {
    param([object[]]$Processes, [hashtable]$Config)
    foreach ($proc in $Processes) {
        $path = ''
        try { $path = $proc.Path } catch { }
        if (-not (Test-AfsGameProcess $proc.ProcessName $path $Config)) { continue }
        try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop }
        catch { if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) { $proc.ProcessName } }
    }
}

function Stop-AfsAppQuotaProcesses {
    param([object[]]$Processes, [object[]]$Rules, [datetime]$Now=(Get-Date))
    $activeRules = @($Rules | Where-Object { Test-AfsQuotaRuleActive $_ $Now })
    foreach ($proc in $Processes) {
        if (@(Get-AfsQuotaMatches $proc.ProcessName $proc.Path $activeRules).Count -eq 0) { continue }
        try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop }
        catch { if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) { $proc.ProcessName } }
    }
}

function Get-AfsQuotaBrowserHost {
    param([IntPtr]$Window)
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        $root = [Windows.Automation.AutomationElement]::FromHandle($Window)
        $edits = [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Edit)
        foreach ($element in $root.FindAll([Windows.Automation.TreeScope]::Descendants, $edits)) {
            if ($element.Current.AutomationId -ne 'addressEdit' -and
                $element.Current.Name -notin @('Address and search bar','地址和搜索栏','地址和搜尋列','地址栏和搜索栏')) { continue }
            $parent = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($element)
            while ($parent -and $parent.Current.ControlType -ne [Windows.Automation.ControlType]::Document -and
                -not $parent.Equals($root)) {
                $parent = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($parent)
            }
            if (-not $parent -or -not $parent.Equals($root)) { continue }
            if ($element.Current.HasKeyboardFocus -or $element.Current.IsOffscreen) { return }
            $pattern = $null
            if ($element.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
                return (ConvertTo-AfsQuotaWebsiteHost $pattern.Current.Value)
            }
        }
    } catch { }
}

if ($LibraryOnly) { return }

# Start the LAN quota endpoint as a child of this task instead of registering a
# second scheduled task: Register-ScheduledTask needs admin, and this task
# already runs elevated, so the child inherits the rights needed for the
# firewall rule. The child exits immediately when the port is already taken,
# so the 1-minute repetition of this task cannot stack up instances.
$lanScript = Join-Path $PSScriptRoot 'quota-lan.ps1'
if (Test-Path -LiteralPath $lanScript) {
    try {
        $lanCfg = Get-AfsQuotaLanConfig $DataDir
        if ($lanCfg.enabled -and $lanCfg.token) {
            $inUse = $false
            try { $inUse = @(Get-NetTCPConnection -LocalPort ([int]$lanCfg.port) -State Listen -ErrorAction SilentlyContinue).Count -gt 0 } catch { }
            if (-not $inUse) {
                Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $lanScript + '"')
                ) | Out-Null
            }
        }
    } catch { }
}

$configFile = Join-Path $DataDir 'game-quota-config.json'
$stateFile = Join-Path $DataDir 'game-quota-state.json'
$mutex = New-Object Threading.Mutex($false, $MutexName)
$owned = $false
try {
    try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { return }
    $state = $null
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $lastTick = $watch.Elapsed.TotalSeconds
    $foregroundIds = @()
    $masterEnabled = $true
    # Cross-device pool: the phone posts its slice every few seconds, this loop
    # re-reads it at most every 2s. Reading on every 1s tick would double the
    # file IO for no visible gain -- 2s is already "locked before you notice".
    $lastSharedRead = -99.0
    # rule id -> @{ usedSeconds; minutes }. Each cross-device cell keeps its own
    # phone slice, so exhaustion of one pool must not drain another.
    $sharedPools = @{}
    # Background playback history is kept in memory by this single writer and
    # flushed periodically; per-tick writes would multiply disk IO for 1s data.
    $playbackHistory = Read-AfsPlaybackHistory -DataDir $DataDir
    $lastPlaybackHistoryWrite = -99.0
    $playbackHistoryDirty = $false
    while ($true) {
        $tick = $watch.Elapsed.TotalSeconds
        $elapsed = $tick - $lastTick
        $lastTick = $tick
        $now = Get-Date
        if (-not (Test-Path -LiteralPath $configFile)) { Start-Sleep -Seconds 1; continue }
        $config = ConvertTo-AfsAppQuotaConfig (Read-AfsJson $configFile)
        # 总开关是时间限额的上游：关掉总开关时，限额既不计时也不关闭应用。
        # 保留已用量，重新打开总开关后从原来的剩余时间继续。
        try { $masterEnabled = [bool](Get-AfsConfig).enabled } catch { }
        $quotaEnabled = $masterEnabled -and [bool]$config.enabled
        if ($null -eq $state) { $state = Read-AfsAppQuotaState $stateFile $now }
        if (($tick - $lastSharedRead) -ge 2) {
            $lastSharedRead = $tick
            $sharedPools = Get-AfsQuotaSharedUsage $DataDir $now $config.rules
        }
        if (-not $quotaEnabled) { $foregroundIds = @() }
        $activeRules = @($config.rules | Where-Object { Test-AfsQuotaRuleActive $_ $now })
        $playbackSnapshot = Get-AfsPlaybackSnapshot $DataDir $now
        $playbackIds = @()
        $playbackRuleHosts = @{}
        if ($quotaEnabled -and [bool]$config.playback.enabled) {
            $playbackIds = @(Get-AfsPlaybackTargetIds $playbackSnapshot $config.rules)
            $playbackRuleHosts = Get-AfsPlaybackRuleHostMap $playbackSnapshot $config.rules
        }
        $stateDayBefore = [string]$state.date
        $playbackBefore = @{}
        if ($state.playback -is [hashtable]) {
            foreach ($ruleId in @($state.playback.Keys)) { $playbackBefore[[string]$ruleId] = [double]$state.playback[$ruleId] }
        }
        $state = Update-AfsAppQuotaState $state $config $now $elapsed $foregroundIds 0 0 $sharedPools -BackgroundPlaybackIds $playbackIds
        if ([string]$state.date -ne $stateDayBefore) { $playbackBefore = @{} }
        foreach ($ruleId in @($state.playback.Keys)) {
            $before = 0.0
            if ($playbackBefore.ContainsKey([string]$ruleId)) { $before = [double]$playbackBefore[[string]$ruleId] }
            $credited = [double]$state.playback[$ruleId] - $before
            if ($credited -le 0) { continue }
            $hostName = ''
            if ($playbackRuleHosts.ContainsKey([string]$ruleId)) { $hostName = [string]$playbackRuleHosts[[string]$ruleId] }
            Add-AfsPlaybackHistory -History $playbackHistory -Now $now -Seconds $credited -HostName $hostName | Out-Null
            $playbackHistoryDirty = $true
        }
        if ($playbackHistoryDirty -and ($tick - $lastPlaybackHistoryWrite) -ge 20) {
            Save-AfsPlaybackHistory $DataDir $playbackHistory
            $lastPlaybackHistoryWrite = $tick
            $playbackHistoryDirty = $false
        }
        $hwnd = [AfsWin32.Native]::GetForegroundWindow()
        $foregroundId = [uint32]0
        if ($hwnd -ne [IntPtr]::Zero) { [void][AfsWin32.Native]::GetWindowThreadProcessId($hwnd, [ref]$foregroundId) }
        $foregroundIds = @()
        $failed = @()
        $exhaustedRules = @($activeRules | Where-Object { $state.apps[$_.id].exhausted })
        $exhaustedApps = @($exhaustedRules | Where-Object { $_.type -in @('games','steam','valorant','process') -or $_.processes })
        if ($quotaEnabled -and $exhaustedApps.Count -gt 0) {
            # Fetch executable paths in one OS query instead of opening every
            # process individually (slow for protected/elevated processes).
            $sessionId = (Get-Process -Id $PID).SessionId
            $processes = @(Get-CimInstance Win32_Process -Filter "SessionId=$sessionId" | ForEach-Object {
                [pscustomobject]@{Id=$_.ProcessId; ProcessName=($_.Name -replace '\.exe$', ''); Path=$_.ExecutablePath}
            })
            $failed = @(Stop-AfsAppQuotaProcesses $processes $exhaustedApps $now)
        }
        if ($quotaEnabled -and $foregroundId -gt 0) {
            # Normal counting only needs the foreground process. Scanning every
            # process each second delayed heartbeats and discarded valid usage.
            $proc = Get-Process -Id $foregroundId -ErrorAction SilentlyContinue
            if ($proc) {
                $path = ''
                try { $path = $proc.Path } catch { }
                $availableRules = @($activeRules | Where-Object { -not $state.apps[$_.id].exhausted })
                $foregroundIds = @(Get-AfsForegroundQuotaTarget $proc.ProcessName $path $availableRules)
                if ($proc.ProcessName -in @('chrome','msedge','brave','vivaldi') -and
                    @($activeRules | Where-Object { $_.type -eq 'website' -or $_.websites }).Count) {
                    $websiteHost = Get-AfsQuotaBrowserHost $hwnd
                    if (@(Get-AfsQuotaWebsiteMatches $websiteHost $exhaustedRules).Count) {
                        try {
                            Add-Type -AssemblyName System.Windows.Forms
                            if ((Get-AfsQuotaBrowserHost $hwnd) -eq $websiteHost -and
                                [AfsWin32.Native]::GetForegroundWindow() -eq $hwnd) {
                                [Windows.Forms.SendKeys]::SendWait('^w')
                            }
                        } catch { $failed += $websiteHost }
                    } else {
                        $websiteRules = @($availableRules | Where-Object {
                            ($_.type -eq 'website' -or $_.websites) -and $foregroundIds[0] -notin @(Get-AfsQuotaTargetIds $_)
                        })
                        $foregroundIds += @(Get-AfsQuotaWebsiteMatches $websiteHost $websiteRules)
                    }
                }
            }
        }
        $state.foregroundIds = $foregroundIds
        $state.foreground = ($foregroundIds.Count -gt 0)
        $state.closeFailures = $failed
        $state.updatedAt = (Get-Date).ToString('o')
        $state.sampleSeconds = $elapsed
        Write-AfsJson $stateFile $state
        $delayMs = [Math]::Max(1, [int](1000 - 1000 * ($watch.Elapsed.TotalSeconds - $tick)))
        Start-Sleep -Milliseconds $delayMs
    }
} catch {
    [IO.File]::AppendAllText((Join-Path $DataDir 'game-quota-error.log'), ((Get-Date).ToString('o') + ' ' + $_.ToString() + [Environment]::NewLine))
    throw
} finally {
    if ($owned) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
