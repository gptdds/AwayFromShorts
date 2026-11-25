# Shared daily quota pool between the PC app and the phone app.
#
# Model (user decision 2026-11-02):
#   One pool, one minute budget, two devices. Each side reports the seconds it
#   spent today inside the pool; the pool is exhausted when the SUM reaches the
#   budget. The PC side owns the pool because it is the only side that can kill
#   processes; the phone reports its own slice over the LAN every few seconds.
#
# Why the PC slice is not stored in the ledger: it is computed live from
# game-quota-state.json. One number, one writer -- two files that both store
# "used seconds" would drift apart the moment one of them fails to write.
#
# Files (DataDir):
#   quota-lan-config.json  { enabled, port, token, poolMinutes }
#   quota-lan-state.json   { date, phoneUsedSeconds, phoneGroup, phoneApps, updatedAt }
#
# Per-app detail (2026-11-02): the pool is one number, but a number alone cannot
# answer "what did the phone actually spend it on". Each side therefore also
# reports the apps/processes inside its slice, and both panels list both sides:
# the PC panel shows PC processes + phone apps, the phone shows phone apps +
# PC processes. Detail is display-only -- it never feeds back into the budget.
#
# Pool size: the dailyMinutes of the first rule flagged "shared" wins, so the
# PC panel stays the single place where the budget is edited. poolMinutes in the
# config file is only the fallback for when no rule is flagged yet.

function Get-AfsQuotaLanConfigPath { param([string]$DataDir) Join-Path $DataDir 'quota-lan-config.json' }
function Get-AfsQuotaLanStatePath { param([string]$DataDir) Join-Path $DataDir 'quota-lan-state.json' }

function New-AfsQuotaLanToken {
    ('afs' + [Guid]::NewGuid().ToString('N').Substring(0, 16))
}

# Token doubles as the "is this thing set up" flag: a pool without a token would
# accept writes from any device on the same wifi.
function Get-AfsQuotaLanConfig {
    param([string]$DataDir)
    $path = Get-AfsQuotaLanConfigPath $DataDir
    $cfg = @{ enabled = $false; port = 8738; token = ''; poolMinutes = 60 }
    if (Test-Path -LiteralPath $path) {
        try {
            $raw = Read-AfsJson -Path $path
            foreach ($k in @('enabled', 'port', 'token', 'poolMinutes')) {
                if ($raw.ContainsKey($k) -and $null -ne $raw[$k]) { $cfg[$k] = $raw[$k] }
            }
        } catch { }
    }
    $cfg.enabled = [bool]$cfg.enabled
    $port = 0
    if ([int]::TryParse([string]$cfg.port, [ref]$port) -and $port -ge 1024 -and $port -le 65535) {
        $cfg.port = $port
    } else {
        $cfg.port = 8738
    }
    $minutes = 0
    if ([int]::TryParse([string]$cfg.poolMinutes, [ref]$minutes) -and $minutes -ge 1 -and $minutes -le 1440) {
        $cfg.poolMinutes = $minutes
    } else {
        $cfg.poolMinutes = 60
    }
    $token = ([string]$cfg.token).Trim()
    if ($token -notmatch '^[A-Za-z0-9_-]{8,64}$') { $cfg.token = '' } else { $cfg.token = $token }
    $cfg
}

function Save-AfsQuotaLanConfig {
    param([string]$DataDir, [hashtable]$Config)
    Write-AfsJson -Path (Get-AfsQuotaLanConfigPath $DataDir) -Object @{
        enabled     = [bool]$Config.enabled
        port        = [int]$Config.port
        token       = [string]$Config.token
        poolMinutes = [int]$Config.poolMinutes
    }
}

function ConvertTo-AfsQuotaLanApps {
    param($Apps = @())
    $out = @()
    foreach ($a in @($Apps)) {
        if ($null -eq $a) { continue }
        $name = ([string]$a.name).Trim()
        if (-not $name -or $name.Length -gt 64) { continue }
        $sec = 0.0
        if (-not [double]::TryParse([string]$a.seconds, [ref]$sec)) { continue }
        if ([double]::IsNaN($sec) -or [double]::IsInfinity($sec) -or $sec -le 0) { continue }
        $out += @{ name = $name; seconds = [Math]::Round([Math]::Min($sec, 86400.0), 1) }
        if ($out.Count -ge 30) { break }
    }
    @($out)
}

function New-AfsQuotaLanPoolState {
    @{ phoneUsedSeconds = 0.0; phoneGroup = ''; phoneApps = @(); updatedAt = '' }
}

# Shared cells are read straight from the quota config. quota-ledger.ps1 is also
# loaded by the LAN helper on its own, so this deliberately stays dependency-free.
function Get-AfsQuotaSharedRules {
    param([string]$DataDir)
    $path = Join-Path $DataDir 'game-quota-config.json'
    $out = @()
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $cfg = Read-AfsJson -Path $path
        foreach ($rule in @($cfg.rules)) {
            if ($null -eq $rule -or -not $rule.ContainsKey('shared') -or -not [bool]$rule.shared) { continue }
            $id = [string]$rule.id
            if (-not $id) { continue }
            $minutes = 0
            if (-not [int]::TryParse([string]$rule.dailyMinutes, [ref]$minutes) -or $minutes -lt 1) { $minutes = 120 }
            $out += @{
                id = $id
                name = '跨设备格子 ' + ($out.Count + 1)
                type = [string]$rule.type
                dailyMinutes = $minutes
                processes = @($rule.processes | Where-Object { $_ })
                websites = @($rule.websites | Where-Object { $_ })
            }
        }
    } catch { }
    @($out)
}

# Phone slice. A ledger entry from another day is worthless: leaving it in place
# would charge yesterday's minutes to today's pool right after midnight.
#
# state:
#   { date, pools: { "<pc-rule-id>": { phoneUsedSeconds, phoneGroup, phoneApps, updatedAt } } }
# The old top-level single-pool fields are still read/written for compatibility
# with older phone builds and older state files.
function Read-AfsQuotaLanState {
    param([string]$DataDir, [datetime]$Now)
    $path = Get-AfsQuotaLanStatePath $DataDir
    $today = Get-AfsQuotaDayKey $Now
    $empty = New-AfsQuotaLanPoolState
    $state = @{
        date = $today
        pools = @{}
        phoneUsedSeconds = 0.0
        phoneGroup = ''
        phoneApps = @()
        updatedAt = ''
    }
    if (-not (Test-Path -LiteralPath $path)) { return $state }
    try {
        $raw = Read-AfsJson -Path $path
        if ([string]$raw.date -ne $today) { return $state }
        $legacy = New-AfsQuotaLanPoolState
        $legacyOk = $false
        $used = 0.0
        if ([double]::TryParse([string]$raw.phoneUsedSeconds, [ref]$used) -and
            -not [double]::IsNaN($used) -and -not [double]::IsInfinity($used) -and $used -ge 0) {
            $legacy.phoneUsedSeconds = [Math]::Min($used, 86400.0)
            $legacy.phoneGroup = [string]$raw.phoneGroup
            $legacy.phoneApps = @(ConvertTo-AfsQuotaLanApps $raw.phoneApps)
            $legacy.updatedAt = [string]$raw.updatedAt
            $legacyOk = $true
        }
        if ($raw.ContainsKey('pools') -and $null -ne $raw.pools) {
            foreach ($id in @($raw.pools.Keys)) {
                $p = $raw.pools[$id]
                if ($null -eq $p) { continue }
                $u = 0.0
                if (-not [double]::TryParse([string]$p.phoneUsedSeconds, [ref]$u)) { continue }
                if ([double]::IsNaN($u) -or [double]::IsInfinity($u) -or $u -lt 0) { continue }
                $state.pools[[string]$id] = @{
                    phoneUsedSeconds = [Math]::Min($u, 86400.0)
                    phoneGroup = [string]$p.phoneGroup
                    phoneApps = @(ConvertTo-AfsQuotaLanApps $p.phoneApps)
                    updatedAt = [string]$p.updatedAt
                }
            }
        }
        # Old state files have no pools map. Keep the slice under a sentinel and
        # let the first shared rule claim it when the view is built.
        if ($legacyOk -and $state.pools.Count -eq 0) { $state.pools[''] = $legacy }
        $first = $null
        if ($state.pools.ContainsKey('')) { $first = $state.pools[''] }
        elseif ($state.pools.Count -gt 0) {
            foreach ($id in @($state.pools.Keys)) { $first = $state.pools[$id]; break }
        }
        if ($null -ne $first) {
            $state.phoneUsedSeconds = [double]$first.phoneUsedSeconds
            $state.phoneGroup = [string]$first.phoneGroup
            $state.phoneApps = @($first.phoneApps)
            $state.updatedAt = [string]$first.updatedAt
        }
    } catch { }
    $state
}

function Get-AfsQuotaLanPoolState {
    param([hashtable]$State, [string]$PoolId, [switch]$AllowLegacy)
    if ($State.pools.ContainsKey([string]$PoolId)) { return $State.pools[[string]$PoolId] }
    if ($AllowLegacy -and $State.pools.ContainsKey('')) { return $State.pools[''] }
    New-AfsQuotaLanPoolState
}

# Merge reports into the per-pool state. A report only replaces its own pool;
# other pools and their phone slices stay untouched.
function Get-AfsQuotaSharedUsage {
    param([string]$DataDir, [datetime]$Now, [object[]]$Rules)
    $pools = @{}
    $sharedRules = @($Rules | Where-Object { $_.shared })
    if ($sharedRules.Count -eq 0 -or -not (Get-AfsQuotaLanConfig $DataDir).enabled) { return $pools }
    $state = Read-AfsQuotaLanState $DataDir $Now
    $legacyAvailable = $state.pools.ContainsKey('')
    foreach ($rule in $sharedRules) {
        $id = [string]$rule.id
        $allowLegacy = $legacyAvailable -and -not $state.pools.ContainsKey($id)
        $pool = Get-AfsQuotaLanPoolState -State $state -PoolId $id -AllowLegacy:$allowLegacy
        if ($allowLegacy) { $legacyAvailable = $false }
        $pools[$id] = @{usedSeconds=[double]$pool.phoneUsedSeconds; minutes=[int]$rule.dailyMinutes}
    }
    return $pools
}

function Write-AfsQuotaLanPools {
    param([string]$DataDir, [datetime]$Now, [hashtable]$Reports)
    $state = Read-AfsQuotaLanState $DataDir $Now
    foreach ($id in @($Reports.Keys)) {
        $r = $Reports[$id]
        if ($null -eq $r) { continue }
        $used = [Math]::Max(0.0, [Math]::Min([double]$r.phoneUsedSeconds, 86400.0))
        $state.pools[[string]$id] = @{
            phoneUsedSeconds = $used
            phoneGroup = [string]$r.phoneGroup
            phoneApps = @(ConvertTo-AfsQuotaLanApps $r.phoneApps)
            updatedAt = $Now.ToString('o')
        }
    }
    # Keep the legacy top-level copy pointed at a deterministic first pool.
    $first = $null
    if ($state.pools.ContainsKey('')) { $first = $state.pools[''] }
    elseif ($state.pools.Count -gt 0) {
        foreach ($id in @($state.pools.Keys)) { $first = $state.pools[$id]; break }
    }
    if ($null -eq $first) { $first = New-AfsQuotaLanPoolState }
    Write-AfsJson -Path (Get-AfsQuotaLanStatePath $DataDir) -Object @{
        date = (Get-AfsQuotaDayKey $Now)
        pools = $state.pools
        phoneUsedSeconds = [double]$first.phoneUsedSeconds
        phoneGroup = [string]$first.phoneGroup
        phoneApps = @($first.phoneApps)
        updatedAt = [string]$first.updatedAt
    }
}

# Compatibility wrapper used by older tests and callers.
function Write-AfsQuotaLanState {
    param([string]$DataDir, [datetime]$Now, [double]$PhoneUsedSeconds, [string]$PhoneGroup, $PhoneApps = @(), [string]$PoolId = '')
    $reports = @{}
    $reports[[string]$PoolId] = @{
        phoneUsedSeconds = $PhoneUsedSeconds
        phoneGroup = $PhoneGroup
        phoneApps = $PhoneApps
    }
    Write-AfsQuotaLanPools -DataDir $DataDir -Now $Now -Reports $reports
}

# Human label for a quota target id. Only used for the per-app detail rows, so a
# generic fallback is fine: process:xxx is the raw process name, which is exactly
# what the PC panel shows for a normal single-app bucket.
function Get-AfsQuotaTargetLabel {
    param([string]$Id)
    if ($Id -eq 'valorant') { return '无畏契约' }
    if ($Id -eq 'steam') { return 'Steam' }
    if ($Id -like 'process:*') { return $Id.Substring(8) }
    if ($Id -like 'website:*') { return $Id.Substring(8) }
    if (-not $Id) { return '未命名' }
    $Id
}

# Target ids one shared rule charges (same expansion as Get-AfsQuotaTargetIds in
# quota-rules.ps1 -- duplicated on purpose so this file stays loadable on its own).
function Get-AfsQuotaRuleTargetIds {
    param($Rule)
    if ($Rule.type -eq 'games') { 'valorant'; 'steam' }
    elseif ($Rule.type -ne 'shared') { [string]$Rule.id }
    foreach ($processName in @($Rule.processes | Where-Object { $_ } | Select-Object -Unique)) {
        'process:' + $processName
    }
    foreach ($website in @($Rule.websites | Where-Object { $_ } | Select-Object -Unique)) {
        'website:' + $website
    }
}

# PC slice for every shared rule. Each rule is its own independent pool.
function Get-AfsQuotaPcSharedByRule {
    param([string]$DataDir, [datetime]$Now)
    $out = @{}
    $gameCfgPath = Join-Path $DataDir 'game-quota-config.json'
    $statePath = Join-Path $DataDir 'game-quota-state.json'
    $rules = Get-AfsQuotaSharedRules $DataDir
    foreach ($rule in @($rules)) { $out[[string]$rule.id] = @{ used = 0.0; minutes = [int]$rule.dailyMinutes; apps = @() } }
    if (-not (Test-Path -LiteralPath $statePath) -or $rules.Count -eq 0) { return $out }
    try {
        $state = Read-AfsJson -Path $statePath
        if ([string]$state.date -ne (Get-AfsQuotaDayKey $Now)) { return $out }
        $entries = $state.apps
        foreach ($rule in @($rules)) {
            $total = 0.0
            $detail = @()
            foreach ($id in @(Get-AfsQuotaRuleTargetIds $rule)) {
                $seconds = 0.0
                if ($state.targets -and $state.targets.ContainsKey($id)) {
                    $seconds = [double]$state.targets[$id]
                } elseif ($null -ne $entries -and $entries.ContainsKey($id)) {
                    $seconds = [double]$entries[$id].usedSeconds
                }
                if ($seconds -le 0) { continue }
                $total += $seconds
                $detail += @{ name = (Get-AfsQuotaTargetLabel $id); seconds = [Math]::Round($seconds, 1) }
            }
            $out[[string]$rule.id] = @{ used = $total; minutes = [int]$rule.dailyMinutes; apps = @($detail) }
        }
    } catch { }
    $out
}

# Aggregate compatibility wrapper.
function Get-AfsQuotaPcSharedUsed {
    param([string]$DataDir, [datetime]$Now)
    $byRule = Get-AfsQuotaPcSharedByRule $DataDir $Now
    $total = 0.0
    $apps = @()
    $minutes = 0
    foreach ($id in @($byRule.Keys)) {
        if ($minutes -le 0) { $minutes = [int]$byRule[$id].minutes }
        $total += [double]$byRule[$id].used
        $apps += @($byRule[$id].apps)
    }
    @{ used = $total; minutes = $minutes; apps = @($apps) }
}

# Phone slice is only trusted while it keeps arriving: the phone polls every 3s,
# so 20s of silence means it left the wifi (or died), not that it is idle.
function Get-AfsQuotaPhoneOnline {
    param([string]$UpdatedAt, [datetime]$Now)
    if (-not $UpdatedAt) { return $false }
    try {
        $stamp = [datetime]::Parse($UpdatedAt)
        $age = ($Now - $stamp).TotalSeconds
        return ($age -ge -5 -and $age -le 20)
    } catch { return $false }
}

# Everything the phone needs in one shot. The top-level fields mirror the first
# pool for older APKs; new APKs use the pools array and select by rule id.
function Get-AfsQuotaPoolView {
    param([string]$DataDir, [datetime]$Now)
    $cfg = Get-AfsQuotaLanConfig $DataDir
    $state = Read-AfsQuotaLanState $DataDir $Now
    $pcByRule = Get-AfsQuotaPcSharedByRule $DataDir $Now
    $rules = @(Get-AfsQuotaSharedRules $DataDir)
    $pools = @()
    $firstPool = $null
    $index = 0
    foreach ($rule in $rules) {
        $pc = $pcByRule[[string]$rule.id]
        if ($null -eq $pc) { $pc = @{ used = 0.0; minutes = [int]$rule.dailyMinutes; apps = @() } }
        $phoneState = Get-AfsQuotaLanPoolState -State $state -PoolId ([string]$rule.id) -AllowLegacy:($index -eq 0)
        $minutes = if ([int]$pc.minutes -gt 0) { [int]$pc.minutes } else { [int]$rule.dailyMinutes }
        $limit = $minutes * 60.0
        $phoneUsed = [double]$phoneState.phoneUsedSeconds
        $pcUsed = [double]$pc.used
        $total = $pcUsed + $phoneUsed
        $pool = @{
            id          = [string]$rule.id
            name        = [string]$rule.name
            poolMinutes = $minutes
            limitSec    = $limit
            pcUsed      = $pcUsed
            phoneUsed   = $phoneUsed
            total       = $total
            remaining   = [Math]::Max(0.0, $limit - $total)
            exhausted   = (($limit - $total) -le 0)
            pcApps      = @($pc.apps)
            phoneApps   = @($phoneState.phoneApps)
            phoneGroup  = [string]$phoneState.phoneGroup
            phoneAt     = [string]$phoneState.updatedAt
            phoneOnline = (Get-AfsQuotaPhoneOnline -UpdatedAt $phoneState.updatedAt -Now $Now)
            updatedAt   = $Now.ToString('o')
        }
        $pools += $pool
        if ($null -eq $firstPool) { $firstPool = $pool }
        $index++
    }
    $firstId = ''
    if ($null -ne $firstPool) { $firstId = [string]$firstPool.id }
    $sharedIds = @($pools | ForEach-Object { [string]$_.id })
    $view = @{
        date        = (Get-AfsQuotaDayKey $Now)
        enabled     = [bool]$cfg.enabled
        pools       = @($pools)
        sharedRule  = $firstId
        sharedRules = $sharedIds
        updatedAt   = $Now.ToString('o')
    }
    # Legacy single-pool fields. Keep them when no shared rule exists as well;
    # old phone builds then see the fallback pool size instead of an empty view.
    if ($null -ne $firstPool) {
        foreach ($key in @('poolMinutes','limitSec','pcUsed','phoneUsed','total','remaining','exhausted','pcApps','phoneApps','phoneGroup','phoneAt','phoneOnline')) {
            $view[$key] = $firstPool[$key]
        }
    } else {
        $view.poolMinutes = [int]$cfg.poolMinutes
        $view.limitSec = [double]$cfg.poolMinutes * 60.0
        $view.pcUsed = 0.0
        $view.phoneUsed = 0.0
        $view.total = 0.0
        $view.remaining = $view.limitSec
        $view.exhausted = $false
        $view.pcApps = @()
        $view.phoneApps = @()
        $view.phoneGroup = ''
        $view.phoneAt = ''
        $view.phoneOnline = $false
    }
    $view
}
