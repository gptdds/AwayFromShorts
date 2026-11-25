# LAN endpoint that lets the phone share the PC quota pool (and only that).
#
# Why TCP instead of HttpListener: HttpListener needs a URL ACL reservation for
# a non-admin account, and this app runs from a scheduled task under the normal
# user. A raw TcpListener binds 0.0.0.0 without any reservation -- same trick the
# config panel already uses.
#
# Surface is deliberately tiny: exactly one path, one token, two verbs.
#   GET  /quota?token=...               -> pool view, no writes
#   POST /quota?token=...  {usedSeconds, group} -> legacy single-pool report
#   POST /quota?token=...  {pools:[{id, group, usedSeconds, apps}]} -> multi-pool report
# A device on the same wifi without the token gets 403 and nothing else.
#
# Runs from the scheduled task 'AwayFromShorts-QuotaLan', hidden window.
param([string]$DataDir = $PSScriptRoot)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'core.ps1')
. (Join-Path $PSScriptRoot 'quota-ledger.ps1')

$logPath = Join-Path $DataDir 'quota-lan.log'

function Write-LanLog {
    param([string]$Level, [string]$Msg)
    try {
        $line = '{0}  {1,-4} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Msg
        Add-Content -Path $logPath -Value $line
        $lines = [System.IO.File]::ReadAllLines($logPath)
        if ($lines.Count -gt 220) { [System.IO.File]::WriteAllLines($logPath, $lines[-200..-1]) }
    } catch { }
}

function Send-LanResponse {
    param($Stream, [int]$Status, [string]$Type, [string]$Body)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $head = "HTTP/1.1 $Status`r`nContent-Type: $Type`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($hb, 0, $hb.Length)
    if ($bytes.Length -gt 0) { $Stream.Write($bytes, 0, $bytes.Length) }
    $Stream.Flush()
}

function Send-LanJson {
    param($Stream, [int]$Status, $Obj)
    Send-LanResponse -Stream $Stream -Status $Status -Type 'application/json; charset=utf-8' -Body (ConvertTo-Json $Obj -Depth 8 -Compress)
}

function Find-LanHeaderEnd {
    param([byte[]]$Bytes)
    for ($i = 0; $i -le $Bytes.Length - 4; $i++) {
        if ($Bytes[$i] -eq 13 -and $Bytes[$i + 1] -eq 10 -and $Bytes[$i + 2] -eq 13 -and $Bytes[$i + 3] -eq 10) { return $i }
    }
    -1
}

# Byte-accurate request reader. A char-based reader is wrong here: Content-Length
# counts bytes, and every Chinese character in a body is three of them.
function Read-LanRequest {
    param($Client)
    $stream = $Client.GetStream()
    $Client.ReceiveTimeout = 6000
    $Client.SendTimeout = 6000
    $buffer = New-Object byte[] 4096
    $all = New-Object System.Collections.Generic.List[byte]
    $headerEnd = -1
    while ($headerEnd -lt 0) {
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { return $null }
        for ($i = 0; $i -lt $read; $i++) { $all.Add($buffer[$i]) }
        $headerEnd = Find-LanHeaderEnd $all.ToArray()
        if ($all.Count -gt 32768) { return $null }
    }
    $snapshot = $all.ToArray()
    $headerText = [System.Text.Encoding]::ASCII.GetString($snapshot, 0, $headerEnd)
    $contentLength = 0
    foreach ($line in ($headerText -split "`r`n")) {
        if ($line -match '^(?i)Content-Length:\s*(\d+)') { $contentLength = [int]$Matches[1] }
    }
    if ($contentLength -lt 0 -or $contentLength -gt 65536) { $contentLength = 0 }
    $bodyBytes = New-Object System.Collections.Generic.List[byte]
    $have = $snapshot.Length - ($headerEnd + 4)
    if ($have -gt 0) { for ($i = 0; $i -lt [Math]::Min($have, $contentLength); $i++) { $bodyBytes.Add($snapshot[$headerEnd + 4 + $i]) } }
    while ($bodyBytes.Count -lt $contentLength) {
        $read = $stream.Read($buffer, 0, [Math]::Min($buffer.Length, $contentLength - $bodyBytes.Count))
        if ($read -le 0) { break }
        for ($i = 0; $i -lt $read; $i++) { $bodyBytes.Add($buffer[$i]) }
    }
    $lines = $headerText -split "`r`n"
    if ($lines.Count -gt 0 -and $lines[0] -match '^([A-Za-z]+)\s+(\S+)\s+HTTP/') {
        $request = @{ method = $Matches[1].ToUpperInvariant(); target = $Matches[2] }
    } else {
        return $null
    }
    $request.stream = $stream
    $request.body = [System.Text.Encoding]::UTF8.GetString($bodyBytes.ToArray())
    $request
}

# Split target into path + params without System.Web (not loadable in PS 5.1).
function Get-LanTarget {
    param([string]$Target)
    $path = $Target
    $params = @{}
    $q = $Target.IndexOf('?')
    if ($q -ge 0) {
        $path = $Target.Substring(0, $q)
        foreach ($pair in ($Target.Substring($q + 1) -split '&')) {
            if (-not $pair) { continue }
            $eq = $pair.IndexOf('=')
            if ($eq -lt 0) { $params[$pair] = '' ; continue }
            $k = [Uri]::UnescapeDataString($pair.Substring(0, $eq))
            $v = [Uri]::UnescapeDataString($pair.Substring($eq + 1))
            $params[$k] = $v
        }
    }
    @{ path = $path; params = $params }
}

function Test-LanToken {
    param([hashtable]$Params, [string]$Expected)
    $given = ''
    if ($Params.ContainsKey('token')) { $given = [string]$Params['token'] }
    if (-not $given) { return $false }
    # Constant-ish compare; these tokens are short-lived secrets on a home LAN.
    [string]::Equals($given, $Expected, [StringComparison]::Ordinal)
}

function Read-LanQuotaReport {
    param($Obj)
    if ($null -eq $Obj) { return $null }
    $used = -1.0
    if ($null -ne $Obj.usedSeconds) { [void][double]::TryParse([string]$Obj.usedSeconds, [ref]$used) }
    if ($used -lt 0 -or [double]::IsNaN($used) -or [double]::IsInfinity($used) -or $used -gt 86400) { return $null }
    $apps = @()
    $hasApps = $false
    if ($null -ne $Obj.apps) {
        $hasApps = $true
        foreach ($a in @($Obj.apps)) {
            if ($null -eq $a) { continue }
            $apps += @{ name = [string]$a.name; seconds = [string]$a.seconds }
            if ($apps.Count -ge 30) { break }
        }
    }
    @{
        id = [string]$Obj.id
        used = $used
        group = [string]$Obj.group
        apps = @($apps)
        hasApps = $hasApps
    }
}

function Get-LanAddresses {
    try {
        @([System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' -and -not [System.Net.IPAddress]::IsLoopback($_) } |
            ForEach-Object { $_.IPAddressToString })
    } catch { @() }
}

# ---------------------------------------------------------------- main

$cfg = Get-AfsQuotaLanConfig $DataDir
if (-not $cfg.enabled) { exit 0 }
if (-not $cfg.token) { Write-LanLog 'WARN' 'no token configured, refusing to listen'; exit 0 }
$port = [int]$cfg.port

$listener = $null
try {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $port)
    $listener.Start()
} catch {
    Write-LanLog 'WARN' ("port $port busy, another instance is probably running")
    exit 0
}

# Inbound rule covers every profile on purpose. Windows classifies plenty of home
# wifi networks as "Public" (this one is), and a Private-only rule then blocks the
# phone with no visible error -- the pool just silently never syncs. What guards
# this endpoint is the token, not the profile: without it a stranger on the same
# wifi gets 403 and cannot read or write anything.
try {
    $existing = Get-NetFirewallRule -DisplayName 'AwayFromShorts Quota LAN' -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-NetFirewallRule -DisplayName 'AwayFromShorts Quota LAN' -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort $port -Profile Any -ErrorAction Stop | Out-Null
        Write-LanLog 'INFO' "firewall rule added for tcp/$port"
    } else {
        Set-NetFirewallRule -DisplayName 'AwayFromShorts Quota LAN' -Profile Any -ErrorAction Stop
        $existing | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -Protocol TCP -LocalPort $port
        Write-LanLog 'INFO' "firewall rule updated for tcp/$port"
    }
} catch {
    Write-LanLog 'WARN' ('firewall rule failed: ' + $_.Exception.Message)
}

Write-LanLog 'INFO' ("listening on 0.0.0.0:$port  addresses=" + ((Get-LanAddresses) -join ','))

$lastPoolWrite = @{}
$lastPoolUsed = @{}
$lastConfigCheck = Get-Date
$lastEnabled = $true
while ($true) {
    $pending = $false
    try { $pending = $listener.Pending() } catch { break }
    if (-not $pending) {
        Start-Sleep -Milliseconds 120
        # Re-read the config every 15s so turning the pool off in the panel also
        # stops this listener. Port changes still need a restart (rebinding a
        # live listener would drop whatever request is mid-flight).
        $nowCheck = Get-Date
        if (($nowCheck - $lastConfigCheck).TotalSeconds -ge 15) {
            $lastConfigCheck = $nowCheck
            $live = Get-AfsQuotaLanConfig $DataDir
            $lastEnabled = [bool]$live.enabled
            if (-not $lastEnabled -or -not $live.token) {
                Write-LanLog 'INFO' 'disabled in config, stopping'
                break
            }
        }
        continue
    }
    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
        $req = Read-LanRequest $client
        if ($null -eq $req) { continue }
        $t = Get-LanTarget $req.target
        if ($t.path -ne '/quota') {
            Send-LanResponse -Stream $req.stream -Status 404 -Type 'text/plain; charset=utf-8' -Body '404'
            continue
        }
        $cfg = Get-AfsQuotaLanConfig $DataDir
        if (-not (Test-LanToken $t.params $cfg.token)) {
            Write-LanLog 'WARN' 'rejected request with bad or missing token'
            Send-LanJson -Stream $req.stream -Status 403 -Obj @{ ok = $false; error = 'forbidden' }
            continue
        }
        $now = Get-Date
        if ($req.method -eq 'POST') {
            $reports = @()
            if ($req.body) {
                try {
                    $o = $req.body | ConvertFrom-Json -ErrorAction Stop
                    if ($null -ne $o.pools) {
                        foreach ($p in @($o.pools)) {
                            $report = Read-LanQuotaReport $p
                            if ($null -ne $report) { $reports += $report }
                        }
                    } elseif ($null -ne $o.usedSeconds) {
                        # Old phone build: no pool id. The first shared rule claims it.
                        $legacy = Read-LanQuotaReport $o
                        if ($null -ne $legacy) { $reports += $legacy }
                    }
                } catch { }
            }
            if ($reports.Count -gt 0) {
                $sharedRules = @(Get-AfsQuotaSharedRules $DataDir)
                $legacyId = if ($sharedRules.Count -gt 0) { [string]$sharedRules[0].id } else { '' }
                $stateBefore = Read-AfsQuotaLanState -DataDir $DataDir -Now $now
                $writeReports = @{}
                $index = 0
                foreach ($report in $reports) {
                    $id = [string]$report.id
                    if (-not $id) { $id = $legacyId }
                    if (-not $id) { $index++; continue }
                    $prevUsed = if ($lastPoolUsed.ContainsKey($id)) { [double]$lastPoolUsed[$id] } else { -1.0 }
                    $prevAt = if ($lastPoolWrite.ContainsKey($id)) { [datetime]$lastPoolWrite[$id] } else { [datetime]::MinValue }
                    # 2s coalescing: the phone polls every 3s, but a sticky network can
                    # retry in a burst and write the same number five times.
                    if (([Math]::Abs([double]$report.used - $prevUsed) -gt 0.4) -or (($now - $prevAt).TotalSeconds -ge 2)) {
                        $apps = @($report.apps)
                        # 旧版手机只报总数（body 里没有 apps）：沿用上一次的明细，
                        # 否则升级前攒下的「哪个应用花了多少」会被每次轮询清空。
                        if (-not $report.hasApps) {
                            $existing = Get-AfsQuotaLanPoolState -State $stateBefore -PoolId $id -AllowLegacy:($index -eq 0)
                            $apps = @($existing.phoneApps)
                        }
                        $writeReports[$id] = @{
                            phoneUsedSeconds = [double]$report.used
                            phoneGroup = [string]$report.group
                            phoneApps = @($apps)
                        }
                        $lastPoolWrite[$id] = $now
                        $lastPoolUsed[$id] = [double]$report.used
                    }
                    $index++
                }
                if ($writeReports.Count -gt 0) { Write-AfsQuotaLanPools -DataDir $DataDir -Now $now -Reports $writeReports }
            }
        }
        $view = Get-AfsQuotaPoolView -DataDir $DataDir -Now $now
        Send-LanJson -Stream $req.stream -Status 200 -Obj $view
    } catch {
        Write-LanLog 'ERROR' $_.Exception.Message
    } finally {
        if ($client) { try { $client.Close() } catch { } }
    }
}
$listener.Stop()
