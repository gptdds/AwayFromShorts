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
#   quota-lan-state.json   { date, phoneUsedSeconds, phoneGroup, updatedAt }
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

# Phone slice. A ledger entry from another day is worthless: leaving it in place
# would charge yesterday's minutes to today's pool right after midnight.
function Read-AfsQuotaLanState {
    param([string]$DataDir, [datetime]$Now)
    $path = Get-AfsQuotaLanStatePath $DataDir
    $today = $Now.ToString('yyyy-MM-dd')
    $state = @{ date = $today; phoneUsedSeconds = 0.0; phoneGroup = ''; updatedAt = '' }
    if (-not (Test-Path -LiteralPath $path)) { return $state }
    try {
        $raw = Read-AfsJson -Path $path
        if ([string]$raw.date -ne $today) { return $state }
        $used = 0.0
        if (-not [double]::TryParse([string]$raw.phoneUsedSeconds, [ref]$used)) { return $state }
        if ([double]::IsNaN($used) -or [double]::IsInfinity($used) -or $used -lt 0) { return $state }
        $state.phoneUsedSeconds = [Math]::Min($used, 86400.0)
        $state.phoneGroup = [string]$raw.phoneGroup
        $state.updatedAt = [string]$raw.updatedAt
    } catch { }
    $state
}

function Write-AfsQuotaLanState {
    param([string]$DataDir, [datetime]$Now, [double]$PhoneUsedSeconds, [string]$PhoneGroup)
    $used = [Math]::Max(0.0, [Math]::Min([double]$PhoneUsedSeconds, 86400.0))
    Write-AfsJson -Path (Get-AfsQuotaLanStatePath $DataDir) -Object @{
        date             = $Now.ToString('yyyy-MM-dd')
        phoneUsedSeconds = $used
        phoneGroup       = [string]$PhoneGroup
        updatedAt        = $Now.ToString('o')
    }
}

# Sum of the seconds the PC spent inside the shared pool today.
function Get-AfsQuotaPcSharedUsed {
    param([string]$DataDir, [datetime]$Now)
    $total = 0.0
    $limits = @()
    $gameCfgPath = Join-Path $DataDir 'game-quota-config.json'
    $statePath = Join-Path $DataDir 'game-quota-state.json'
    if (-not (Test-Path -LiteralPath $gameCfgPath) -or -not (Test-Path -LiteralPath $statePath)) {
        return @{ used = 0.0; minutes = 0 }
    }
    try {
        $cfg = Read-AfsJson -Path $gameCfgPath
        $state = Read-AfsJson -Path $statePath
        if ([string]$state.date -ne $Now.ToString('yyyy-MM-dd')) { return @{ used = 0.0; minutes = 0 } }
        $apps = $state.apps
        foreach ($rule in @($cfg.rules)) {
            if ($null -eq $rule -or -not $rule.ContainsKey('shared') -or -not [bool]$rule.shared) { continue }
            if ($null -eq $rule.id) { continue }
            $limits += [int]$rule.dailyMinutes
            $entry = $null
            if ($apps -and $apps.ContainsKey([string]$rule.id)) { $entry = $apps[[string]$rule.id] }
            elseif ($state.targets -and $state.targets.ContainsKey([string]$rule.id)) {
                $total += [double]$state.targets[[string]$rule.id]
                continue
            }
            if ($null -ne $entry) { $total += [double]$entry.usedSeconds }
        }
    } catch { }
    $minutes = 0
    if ($limits.Count -gt 0) { $minutes = $limits[0] }
    @{ used = $total; minutes = $minutes }
}

# Everything the phone needs in one shot. Called once per poll, so it stays
# deliberately allocation-light: two small JSON reads, no scanning.
function Get-AfsQuotaPoolView {
    param([string]$DataDir, [datetime]$Now)
    $cfg = Get-AfsQuotaLanConfig $DataDir
    $state = Read-AfsQuotaLanState $DataDir $Now
    $pc = Get-AfsQuotaPcSharedUsed $DataDir $Now
    $minutes = if ($pc.minutes -gt 0) { [int]$pc.minutes } else { [int]$cfg.poolMinutes }
    $limit = $minutes * 60.0
    $phone = [double]$state.phoneUsedSeconds
    $pcUsed = [double]$pc.used
    $total = $pcUsed + $phone
    @{
        date        = $Now.ToString('yyyy-MM-dd')
        enabled     = [bool]$cfg.enabled
        poolMinutes = $minutes
        limitSec    = $limit
        pcUsed      = $pcUsed
        phoneUsed   = $phone
        total       = $total
        remaining   = [Math]::Max(0.0, $limit - $total)
        exhausted   = (($limit - $total) -le 0)
        updatedAt   = $Now.ToString('o')
    }
}
