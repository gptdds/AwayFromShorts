# Runs in the interactive desktop; independent of study/scheduled blocking.
param([string]$DataDir = $PSScriptRoot, [switch]$LibraryOnly)
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
    param([object[]]$Processes, [object[]]$Rules)
    foreach ($proc in $Processes) {
        if (@(Get-AfsQuotaMatches $proc.ProcessName $proc.Path $Rules).Count -eq 0) { continue }
        try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop }
        catch { if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) { $proc.ProcessName } }
    }
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
$mutex = New-Object Threading.Mutex($false, 'Local\AwayFromShorts-GameQuota')
$owned = $false
try {
    try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { return }
    $state = $null
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $lastTick = $watch.Elapsed.TotalSeconds
    $foregroundIds = @()
    # Cross-device pool: the phone posts its slice every few seconds, this loop
    # re-reads it at most every 2s. Reading on every 1s tick would double the
    # file IO for no visible gain -- 2s is already "locked before you notice".
    $lastSharedRead = -99.0
    $sharedUsed = 0.0
    $poolMinutes = 0
    while ($true) {
        $tick = $watch.Elapsed.TotalSeconds
        $elapsed = $tick - $lastTick
        $lastTick = $tick
        $now = Get-Date
        if (-not (Test-Path -LiteralPath $configFile)) { Start-Sleep -Seconds 1; continue }
        $config = ConvertTo-AfsAppQuotaConfig (Read-AfsJson $configFile)
        if ($null -eq $state) { $state = Read-AfsAppQuotaState $stateFile $now }
        $sharedRule = $null
        foreach ($r in $config.rules) { if ($r.ContainsKey('shared') -and [bool]$r.shared) { $sharedRule = $r } }
        if ($null -ne $sharedRule) {
            if (($tick - $lastSharedRead) -ge 2) {
                $lastSharedRead = $tick
                $lanCfg = Get-AfsQuotaLanConfig $DataDir
                if ($lanCfg.enabled) {
                    $sharedUsed = [double](Read-AfsQuotaLanState $DataDir $now).phoneUsedSeconds
                } else {
                    $sharedUsed = 0.0
                }
                $poolMinutes = [int]$sharedRule.dailyMinutes
            }
        } else {
            $sharedUsed = 0.0; $poolMinutes = 0
        }
        $state = Update-AfsAppQuotaState $state $config $now $elapsed $foregroundIds $sharedUsed $poolMinutes
        $hwnd = [AfsWin32.Native]::GetForegroundWindow()
        $foregroundId = [uint32]0
        if ($hwnd -ne [IntPtr]::Zero) { [void][AfsWin32.Native]::GetWindowThreadProcessId($hwnd, [ref]$foregroundId) }
        $foregroundIds = @()
        $failed = @()
        $exhaustedRules = @($config.rules | Where-Object { $state.apps[$_.id].exhausted })
        if ($config.enabled -and $exhaustedRules.Count -gt 0) {
            # Fetch executable paths in one OS query instead of opening every
            # process individually (slow for protected/elevated processes).
            $sessionId = (Get-Process -Id $PID).SessionId
            $processes = @(Get-CimInstance Win32_Process -Filter "SessionId=$sessionId" | ForEach-Object {
                [pscustomobject]@{Id=$_.ProcessId; ProcessName=($_.Name -replace '\.exe$', ''); Path=$_.ExecutablePath}
            })
            $failed = @(Stop-AfsAppQuotaProcesses $processes $exhaustedRules)
        }
        if ($config.enabled -and $foregroundId -gt 0) {
            # Normal counting only needs the foreground process. Scanning every
            # process each second delayed heartbeats and discarded valid usage.
            $proc = Get-Process -Id $foregroundId -ErrorAction SilentlyContinue
            if ($proc) {
                $path = ''
                try { $path = $proc.Path } catch { }
                $availableRules = @($config.rules | Where-Object { -not $state.apps[$_.id].exhausted }); $foregroundIds = @(Get-AfsForegroundQuotaTarget $proc.ProcessName $path $availableRules)
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
