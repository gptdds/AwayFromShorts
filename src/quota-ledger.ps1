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

# Phone slice. A ledger entry from another day is worthless: leaving it in place
# would charge yesterday's minutes to today's pool right after midnight.
function Read-AfsQuotaLanState {
    param([string]$DataDir, [datetime]$Now)
    $path = Get-AfsQuotaLanStatePath $DataDir
    $today = $Now.ToString('yyyy-MM-dd')
    $state = @{ date = $today; phoneUsedSeconds = 0.0; phoneGroup = ''; phoneApps = @(); updatedAt = '' }
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
        # Per-app detail is optional: an older phone build posts only usedSeconds,
        # so a missing array must not invalidate the slice itself.
        $apps = @()
        if ($raw.ContainsKey('phoneApps') -and $null -ne $raw.phoneApps) {
            foreach ($a in @($raw.phoneApps)) {
                if ($null -eq $a) { continue }
                $name = ([string]$a.name).Trim()
                if (-not $name -or $name.Length -gt 64) { continue }
                $sec = 0.0
                if (-not [double]::TryParse([string]$a.seconds, [ref]$sec)) { continue }
                if ([double]::IsNaN($sec) -or [double]::IsInfinity($sec) -or $sec -le 0) { continue }
                $apps += @{ name = $name; seconds = [Math]::Min($sec, 86400.0) }
                if ($apps.Count -ge 30) { break }
            }
        }
        $state.phoneApps = $apps
    } catch { }
    $state
}

function Write-AfsQuotaLanState {
    param([string]$DataDir, [datetime]$Now, [double]$PhoneUsedSeconds, [string]$PhoneGroup, $PhoneApps = @())
    $used = [Math]::Max(0.0, [Math]::Min([double]$PhoneUsedSeconds, 86400.0))
    $apps = @()
    foreach ($a in @($PhoneApps)) {
        if ($null -eq $a) { continue }
        $name = ([string]$a.name).Trim()
        if (-not $name -or $name.Length -gt 64) { continue }
        $sec = 0.0
        if (-not [double]::TryParse([string]$a.seconds, [ref]$sec)) { continue }
        if ([double]::IsNaN($sec) -or [double]::IsInfinity($sec) -or $sec -le 0) { continue }
        $apps += @{ name = $name; seconds = [Math]::Round([Math]::Min($sec, 86400.0), 1) }
        if ($apps.Count -ge 30) { break }
    }
    Write-AfsJson -Path (Get-AfsQuotaLanStatePath $DataDir) -Object @{
        date             = $Now.ToString('yyyy-MM-dd')
        phoneUsedSeconds = $used
        phoneGroup       = [string]$PhoneGroup
        phoneApps        = @($apps)
        updatedAt        = $Now.ToString('o')
    }
}

# Human label for a quota target id. Only used for the per-app detail rows, so a
# generic fallback is fine: process:xxx is the raw process name, which is exactly
# what the PC panel shows for a normal single-app bucket.
function Get-AfsQuotaTargetLabel {
    param([string]$Id)
    if ($Id -eq 'valorant') { return '无畏契约' }
    if ($Id -eq 'steam') { return 'Steam' }
    if ($Id -like 'process:*') { return $Id.Substring(8) }
    if (-not $Id) { return '未命名' }
    $Id
}

# Target ids one shared rule charges (same expansion as Get-AfsQuotaTargetIds in
# quota-rules.ps1 -- duplicated on purpose so this file stays loadable on its own).
function Get-AfsQuotaRuleTargetIds {
    param($Rule)
    if ([string]$Rule.type -eq 'games') {
        $ids = @('valorant', 'steam')
        foreach ($p in @($Rule.processes | Where-Object { $_ })) { $ids += ('process:' + [string]$p) }
        return @($ids | Select-Object -Unique)
    }
    @([string]$Rule.id)
}

# Sum of the seconds the PC spent inside the shared pool today.
function Get-AfsQuotaPcSharedUsed {
    param([string]$DataDir, [datetime]$Now)
    $total = 0.0
    $limits = @()
    $detail = @()
    $gameCfgPath = Join-Path $DataDir 'game-quota-config.json'
    $statePath = Join-Path $DataDir 'game-quota-state.json'
    if (-not (Test-Path -LiteralPath $gameCfgPath) -or -not (Test-Path -LiteralPath $statePath)) {
        return @{ used = 0.0; minutes = 0; apps = @() }
    }
    try {
        $cfg = Read-AfsJson -Path $gameCfgPath
        $state = Read-AfsJson -Path $statePath
        if ([string]$state.date -ne $Now.ToString('yyyy-MM-dd')) { return @{ used = 0.0; minutes = 0; apps = @() } }
        $entries = $state.apps
        foreach ($rule in @($cfg.rules)) {
            if ($null -eq $rule -or -not $rule.ContainsKey('shared') -or -not [bool]$rule.shared) { continue }
            if ($null -eq $rule.id) { continue }
            $limits += [int]$rule.dailyMinutes
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
        }
    } catch { }
    $minutes = 0
    if ($limits.Count -gt 0) { $minutes = $limits[0] }
    @{ used = $total; minutes = $minutes; apps = @($detail) }
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
        # 双端明细：各端自己那一份花在哪些应用/进程上。只用于展示，不参与判定。
        pcApps      = @($pc.apps)
        phoneApps   = @($state.phoneApps)
        phoneGroup  = [string]$state.phoneGroup
        phoneAt     = [string]$state.updatedAt
        phoneOnline = (Get-AfsQuotaPhoneOnline -UpdatedAt $state.updatedAt -Now $Now)
        updatedAt   = $Now.ToString('o')
    }
}
