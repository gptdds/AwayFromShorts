# Shared validation/matching for the quota worker and settings API.
function ConvertTo-AfsQuotaDays {
    param($Days)
    if ($null -eq $Days) { return @(1..7) }
    $values = @($Days)
    if ($values.Count -eq 0) { throw '每条限额规则至少选择一个生效星期' }
    $seen = @{}
    foreach ($value in $values) {
        $day = 0
        if (-not [int]::TryParse([string]$value, [ref]$day) -or $day -lt 1 -or $day -gt 7) {
            throw '限额生效星期必须是 1 到 7（周一为 1，周日为 7）'
        }
        $seen[$day] = $true
    }
    return @($seen.Keys | ForEach-Object { [int]$_ } | Sort-Object)
}

function Get-AfsQuotaWeekday {
    param([datetime]$Now)
    if ($Now.DayOfWeek -eq [DayOfWeek]::Sunday) { return 7 }
    return [int]$Now.DayOfWeek
}

function Test-AfsQuotaRuleActive {
    param($Rule, [datetime]$Now)
    $days = if ($null -ne $Rule -and $Rule.ContainsKey('days')) { @($Rule.days) } else { @(1..7) }
    return ((Get-AfsQuotaWeekday $Now) -in $days)
}

function ConvertTo-AfsQuotaConfig {
    param([hashtable]$Config)
    $minutes = 0
    if (-not [int]::TryParse([string]$Config.dailyMinutes, [ref]$minutes) -or $minutes -lt 1 -or $minutes -gt 1440) {
        throw '每日时长请输入 1 到 1440 的整数分钟'
    }
    foreach ($key in @('enabled','includeSteam','includeValorant')) {
        if ($Config.ContainsKey($key) -and $Config[$key] -isnot [bool]) { throw '启用和应用选择必须为布尔值' }
    }
    $steam = $true; $valorant = $true
    if ($Config.ContainsKey('includeSteam')) { $steam = $Config.includeSteam }
    if ($Config.ContainsKey('includeValorant')) { $valorant = $Config.includeValorant }
    $names = @()
    $protected = @('powershell','pwsh','cmd','conhost','system','registry','idle','svchost','explorer','services','wininit','winlogon','lsass','dwm','csrss','smss','sihost','taskeng','taskhostw','fontdrvhost')
    foreach ($entry in @($Config.processes)) {
        if ($null -eq $entry) { continue }
        if ($entry -isnot [string]) { throw '应用名称格式不正确' }
        $name = ($entry.Trim() -replace '(?i)\.exe$', '').ToLowerInvariant()
        if (-not $name -or $name.Length -gt 128 -or $name -match '[\\/:*?"<>|\r\n]') { throw '请输入应用进程名称，例如 chrome.exe，不要输入路径' }
        if ($name -in $protected) { throw "不能限制系统或计时器依赖的进程：$name" }
        $names += $name
    }
    $names = @($names | Sort-Object -Unique)
    if ($names.Count -gt 100) { throw '最多选择 100 个应用' }
    if ($Config.enabled -and -not $steam -and -not $valorant -and $names.Count -eq 0) { throw '请至少选择一个应用' }
    return @{version=2; enabled=[bool]$Config.enabled; dailyMinutes=$minutes; includeSteam=$steam; includeValorant=$valorant; processes=$names; mode='foreground'; reset='local-midnight'}
}

function Test-AfsGameProcess {
    param([string]$Name, [string]$Path, [hashtable]$Config)
    $n = $Name -replace '(?i)\.exe$', ''
    if ($null -eq $Config) { $Config = @{includeSteam=$true; includeValorant=$true; processes=@()} }
    if ($n -in @($Config.processes)) { return $true }
    # Wallpaper Engine(动态壁纸)常装在 steamapps\common\wallpaper_engine\ 下, 但它是
    # 常驻桌面组件不是游戏 —— 命中时直接豁免: 既不计数, 也不会在额度耗尽时被连带杀掉。
    if ($Path -match '(?i)[\\/]wallpaper_engine[\\/]') { return $false }
    if ($n -eq 'wallpaper64') { return $false }
    if ($Config.includeValorant -and ($n -in @('VALORANT','VALORANT-Win64-Shipping','无畏契约登录器') -or $Path -match '(?i)[\\/]VALORANT[\\/].*\.exe$')) { return $true }
    return ($Config.includeSteam -and ($n -in @('steam','steamwebhelper') -or $Path -match '(?i)[\\/]steamapps[\\/]common[\\/]'))
}

function ConvertTo-AfsAppQuotaConfig {
    param([hashtable]$Config)
    if (-not $Config.ContainsKey('rules')) {
        $old = ConvertTo-AfsQuotaConfig $Config
        $rules = @()
        if ($old.includeValorant) { $rules += @{type='valorant'; name='无畏契约'; dailyMinutes=$old.dailyMinutes; days=@(1..7)} }
        if ($old.includeSteam) { $rules += @{type='steam'; name='Steam（含 Steam 游戏）'; dailyMinutes=$old.dailyMinutes; days=@(1..7)} }
        foreach ($name in $old.processes) { $rules += @{type='process'; name=$name; dailyMinutes=$old.dailyMinutes; days=@(1..7)} }
        $Config = @{enabled=$old.enabled; rules=$rules}
    }
    if ($Config.enabled -isnot [bool]) { throw '启用状态格式不正确' }
    $rules = @(); $ids = @{}
    foreach ($r in @($Config.rules)) {
        if ($null -eq $r) { throw '应用规则不能为空' }
        $check = @{enabled=$false; dailyMinutes=$r.dailyMinutes; includeSteam=$false; includeValorant=$false; processes=@()}
        $type = [string]$r.type
        $memberConfig = ConvertTo-AfsQuotaConfig @{
            enabled=$false; dailyMinutes=1; includeSteam=$false; includeValorant=$false
            processes=@($r.processes | Where-Object { $_ -is [string] })
        }
        $extraProcs = @($memberConfig.processes)
        $websites = @(
            foreach ($entry in @($r.websites | Where-Object { $null -ne $_ })) {
                if ($entry -isnot [string]) { throw '网站格式不正确' }
                $websiteHost = ConvertTo-AfsQuotaWebsiteHost $entry
                if (-not $websiteHost) { throw '请输入有效的网站域名或 HTTP(S) 网址' }
                $websiteHost
            }
        )
        if ($websites.Count -gt 100) { throw '每个格子最多添加 100 个网站' }
        switch ($type) {
            'games' {
                # 共享格子 = 无畏契约 + Steam + 可选附加进程(同一个 id 'games', 共用一份额度)
                $id='games'
                foreach ($n in $extraProcs) {
                    if ($n -in @('steam','steamwebhelper','valorant','valorant-win64-shipping')) { throw "无畏契约 / Steam 已经在共享格子里，不用重复添加：$n" }
                }
                $name = if ($extraProcs.Count -gt 0) { '无畏契约 + Steam + ' + ($extraProcs -join ' + ') + '（共享）' } else { '无畏契约 + Steam（共享）' }
            }
            'steam' { $id='steam'; $name='Steam（含 Steam 游戏）' }
            'valorant' { $id='valorant'; $name='无畏契约' }
            'website' {
                $name = ConvertTo-AfsQuotaWebsiteHost ([string]$r.name)
                if (-not $name) { throw '请输入有效的网站域名或 HTTP(S) 网址' }
                $id = 'website:' + $name
            }
            'process' {
                $check.processes = @($r.name)
                $valid = ConvertTo-AfsQuotaConfig $check
                if ($valid.processes.Count -ne 1) { throw '请输入应用进程名' }
                $name = $valid.processes[0]; $id = 'process:' + $name
                if ($name -in @('steam','steamwebhelper')) { $id='steam'; $type='steam'; $name='Steam（含 Steam 游戏）' }
                if ($name -in @('valorant','valorant-win64-shipping','无畏契约登录器')) { $id='valorant'; $type='valorant'; $name='无畏契约' }
            }
            'shared' {
                # 自由共享格子：用户自己选成员，共用一个额度。id 必须稳定，
                # 否则每次改名 / 加成员都会被当成删除旧格子再新建。
                $id = ([string]$r.id).Trim()
                if ($id) {
                    if ($id -notmatch '^shared:[A-Za-z0-9_-]{8,64}$') { throw '共享格子标识无效' }
                } else {
                    $id = 'shared:' + [Guid]::NewGuid().ToString('N')
                }
                $customName = ([string]$r.name).Trim()
                if ($customName.Length -gt 80) { throw '共享格子名称不能超过 80 个字符' }
                $name = if ($customName) { $customName } elseif ($extraProcs.Count -gt 0) { '共享格子 · ' + ($extraProcs -join ' + ') } else { '共享格子' }
            }
            default { throw '应用规则类型不正确' }
        }
        $valid = ConvertTo-AfsQuotaConfig $check
        $days = ConvertTo-AfsQuotaDays $r.days
        if ($ids.ContainsKey($id)) { throw "应用重复：$name" }
        $ids[$id]=$true
        $rule = @{id=$id; type=$type; name=$name; dailyMinutes=$valid.dailyMinutes; days=@($days)}
        if ($extraProcs.Count -gt 0) { $rule.processes = $extraProcs }
        if ($websites.Count -gt 0) { $rule.websites = $websites }
        # 跨设备共享：每条共享格子各自拥有一个池子。手机端可以按格子分别绑定，
        # 因此这里允许多条规则同时带 shared 标记。
        if ($r.ContainsKey('shared') -and [bool]$r.shared) {
            $rule.shared = $true
        }
        $rules += $rule
    }
    if ($rules.Count -gt 100) { throw '最多选择 100 个应用' }
    if ($Config.enabled -and $rules.Count -eq 0) { throw '请至少选择一个应用' }
    if ($ids.ContainsKey('games') -and ($ids.ContainsKey('steam') -or $ids.ContainsKey('valorant'))) { throw '共享格子与独立格子不能同时包含相同应用，请先合并或拆分' }
    $targetSeen = @{}
    foreach ($rule in @($rules)) {
        foreach ($targetId in @(Get-AfsQuotaTargetIds $rule)) {
            if ($targetSeen.ContainsKey($targetId)) { throw "格子成员重复：$targetId" }
            $targetSeen[$targetId] = $true
        }
    }
    return @{version=5; enabled=$Config.enabled; rules=$rules; mode='foreground'; reset='local-midnight'}
}

function Get-AfsQuotaEditWindow {
    param(
        [datetime]$Now = (Get-Date),
        [string]$OverridePath = (Join-Path $PSScriptRoot 'quota-edit-until.json'),
        [bool]$MasterEnabled = $true,
        [bool]$QuotaEnabled = $true
    )
    $adjustment = Get-AfsAdjustmentWindow -Now $Now
    $start = [TimeSpan]::Parse($adjustment.start)
    $end = [TimeSpan]::Parse($adjustment.end)
    $allowed = [bool]$adjustment.allowed
    $next = $Now.Date.Add($start)
    if ($Now.TimeOfDay -ge $start) { $next = $next.AddDays(1) }
    $temporary = $false
    $until = $null
    $unlocked = $null
    $label = '每天 ' + $adjustment.start + '–' + $adjustment.end
    if (-not $MasterEnabled) {
        $allowed = $true; $unlocked = 'master-off'; $label = '总开关已关闭'
    } elseif (-not $QuotaEnabled) {
        $allowed = $true; $unlocked = 'quota-off'; $label = '时间限额已关闭'
    } elseif ($allowed) {
        $until = $Now.Date.Add($end).ToString('o')
    }
    if ($null -eq $unlocked -and (Test-Path -LiteralPath $OverridePath)) {
        try {
            $grant = Read-AfsJson $OverridePath
            $expires = [DateTimeOffset]::Parse([string]$grant.expiresAt)
            if ($expires -gt [DateTimeOffset]$Now) {
                $allowed = $true; $temporary = $true; $until = $expires.ToString('o')
            }
        } catch { } # Malformed or expired grants never open the settings.
    }
    return @{
        allowed = $allowed; temporary = $temporary; until = $until; next = $next.ToString('o')
        start = $adjustment.start; end = $adjustment.end; label = $label; unlocked = $unlocked; serverTime = $Now.ToString('o')
    }
}

# 调整时段以外, 共享格子/应用/进程「只进不出」:
#   允许 —— 新增应用(额度不超过默认 120 分钟)、往共享格子加进程、关闭时间限额
#   拒绝 —— 删应用 / 删共享格子成员 / 改任何已有格子的每日时长
# 两个入参都必须是 ConvertTo-AfsAppQuotaConfig 归一化后的配置。
# 返回 $null 表示允许, 否则返回拒绝原因。
function Test-AfsQuotaAppendOnly {
    param($Current, $Incoming, [string]$WindowLabel = '调整时段')
    if ($null -eq $Current) { return $null }
    $curRules = @{}
    foreach ($r in @($Current.rules)) { $curRules[[string]$r.id] = $r }
    $newRules = @{}
    foreach ($r in @($Incoming.rules)) { $newRules[[string]$r.id] = $r }

    foreach ($id in @($curRules.Keys)) {
        $a = $curRules[$id]
        if (-not $newRules.ContainsKey($id)) {
            return ('规定时间以外, 应用和进程「只进不出」—— 不能移除: ' + $a.name + '。想删请等' + $WindowLabel + '。')
        }
        $b = $newRules[$id]
        if ([int]$b.dailyMinutes -ne [int]$a.dailyMinutes) {
            return ('规定时间以外不能改每日时长: ' + $a.name + ' (' + [int]$a.dailyMinutes + ' → ' + [int]$b.dailyMinutes + ' 分钟)。想改请等' + $WindowLabel + '。')
        }
        $oldDays = @($a.days | ForEach-Object { [int]$_ } | Sort-Object)
        $newDays = @($b.days | ForEach-Object { [int]$_ } | Sort-Object)
        if (($oldDays -join ',') -ne ($newDays -join ',')) {
            return ('规定时间以外不能修改生效星期: ' + $a.name + '。想改请等' + $WindowLabel + '。')
        }
        # 关掉共享 = 把手机那半边已经用掉的时间从账上放走, 和调大额度是同一类事。
        if ($a.ContainsKey('shared') -and [bool]$a.shared -and -not ($b.ContainsKey('shared') -and [bool]$b.shared)) {
            return ('规定时间以外不能关掉跨设备共享: ' + $a.name + '。关掉等于把手机那边的用量放走, 想改请等' + $WindowLabel + '。')
        }
        $oldProcs = @($a.processes | Where-Object { $_ })
        $newProcs = @($b.processes | Where-Object { $_ })
        foreach ($p in $oldProcs) {
            if ($p -notin $newProcs) {
                return ('规定时间以外, 共享格子里的进程「只进不出」—— 不能移除: ' + $p + '。想删请等' + $WindowLabel + '。')
            }
        }
        foreach ($website in @($a.websites | Where-Object { $_ })) {
            if ($website -notin @($b.websites)) {
                return ('规定时间以外不能移除格子网站：' + $website + '。请等' + $WindowLabel + '。')
            }
        }
    }
    foreach ($id in @($newRules.Keys)) {
        if ($curRules.ContainsKey($id)) { continue }
        if ([int]$newRules[$id].dailyMinutes -gt 120) {
            return ('规定时间以外新增应用只能用默认 120 分钟额度: ' + $newRules[$id].name + '。想设更长请等' + $WindowLabel + '。')
        }
    }
    $null
}

function ConvertTo-AfsQuotaWebsiteHost {
    param([string]$Value)
    $Value = $Value.Trim()
    if ($Value -notmatch '^[a-z][a-z0-9+.-]*://') { $Value = 'https://' + $Value }
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http','https') -or $uri.UserInfo -or
        $uri.HostNameType -ne [UriHostNameType]::Dns -or $uri.Host -notmatch '\.') { return }
    return $uri.IdnHost.TrimEnd('.').ToLowerInvariant()
}

function Get-AfsQuotaWebsiteDomains {
    param($Rule)
    if ($Rule.type -eq 'website') { $Rule.name }
    $Rule.websites | Where-Object { $_ }
}

function Get-AfsQuotaWebsiteMatches {
    param([string]$HostName, [object[]]$Rules)
    if (-not $HostName) { return }
    foreach ($rule in $Rules) {
        $domains = @(Get-AfsQuotaWebsiteDomains $rule | Sort-Object -Property Length -Descending)
        foreach ($domain in $domains) {
            if ($HostName -eq $domain -or
                $HostName.EndsWith('.' + $domain, [StringComparison]::OrdinalIgnoreCase) -or
                ($domain.StartsWith('www.', [StringComparison]::OrdinalIgnoreCase) -and $HostName -eq $domain.Substring(4))) {
                'website:' + $domain
                break
            }
        }
    }
}

function Get-AfsQuotaMatches {
    param([string]$Name, [string]$Path, [object[]]$Rules)
    foreach ($r in $Rules) {
        $c = @{includeSteam=($r.type -in @('steam','games')); includeValorant=($r.type -in @('valorant','games')); processes=@($r.processes | Where-Object { $_ })}
        if ($r.type -eq 'process') { $c.processes += $r.name }
        if (Test-AfsGameProcess $Name $Path $c) { $r.id }
    }
}

function Get-AfsQuotaTargetIds {
    param($Rule)
    if ($Rule.type -eq 'games') { 'valorant'; 'steam' }
    elseif ($Rule.type -ne 'shared') { $Rule.id }
    foreach ($processName in @($Rule.processes | Where-Object { $_ })) { 'process:' + $processName }
    foreach ($website in @($Rule.websites | Where-Object { $_ })) { 'website:' + $website }
}

function Get-AfsForegroundQuotaTarget {
    param([string]$Name, [string]$Path, [object[]]$Rules)
    # Count one foreground interval once, even when a game matches a broad
    # Steam path and a more specific application rule.
    foreach ($r in @($Rules | Where-Object { $_.type -eq 'process' })) {
        if (($Name -replace '(?i)\.exe$', '') -eq $r.name) { return $r.id }
    }
    # 共享格子的附加进程: 单独判断, 返回它自己的 target id (与 valorant/steam 共用同一份额度)
    foreach ($r in $Rules) {
        foreach ($p in @($r.processes | Where-Object { $_ })) {
            if (@(Get-AfsQuotaMatches $Name $Path @(@{type='process'; name=$p; id=('process:' + $p)})).Count) { return ('process:' + $p) }
        }
    }
    $ids=@($Rules | ForEach-Object { Get-AfsQuotaTargetIds $_ })
    if ('valorant' -in $ids -and (Test-AfsGameProcess $Name $Path @{includeSteam=$false;includeValorant=$true;processes=@()})) { return 'valorant' }
    if ('steam' -in $ids -and (Test-AfsGameProcess $Name $Path @{includeSteam=$true;includeValorant=$false;processes=@()})) { return 'steam' }
}

function Update-AfsAppQuotaState {
    param([hashtable]$State, [hashtable]$Config, [datetime]$Now, [double]$Elapsed=0, [string[]]$ForegroundIds=@(),
          [double]$SharedUsedSeconds=0, [int]$PoolMinutes=0, [hashtable]$SharedPools=$null)
    $today=Get-AfsQuotaDayKey $Now
    if ($State.date -ne $today) {
        $State=@{version=4;date=$today;targets=@{}}
        # 只把额度日重置之后的那一段算进新的一天（重置在早上 8 点，不是零点）
        $Elapsed=[Math]::Min($Elapsed,(Get-AfsQuotaDaySeconds $Now))
    }
    if (-not $State.ContainsKey('targets')) {
        $State.targets=@{}
        if ($State.ContainsKey('apps')) {
            foreach ($id in $State.apps.Keys) { $State.targets[$id]=[double]$State.apps[$id].usedSeconds }
        } else {
            foreach ($r in $Config.rules) {
                foreach ($id in @(Get-AfsQuotaTargetIds $r)) { $State.targets[$id]=[double]$State.usedSeconds }
            }
        }
        $State.Remove('usedSeconds'); $State.Remove('remainingSeconds'); $State.Remove('exhausted'); $State.Remove('limitSeconds')
    }
    $activeRules = @($Config.rules | Where-Object { Test-AfsQuotaRuleActive $_ $Now })
    foreach ($r in $Config.rules) {
        foreach ($id in @(Get-AfsQuotaTargetIds $r)) {
            if (-not $State.targets.ContainsKey($id)) { $State.targets[$id]=0.0 }
            if ($State.error) { $State.targets[$id]=[Math]::Max([double]$State.targets[$id], [double]$r.dailyMinutes*60) }
        }
    }
    if ($Config.enabled -and $Elapsed -gt 0 -and $Elapsed -le 5) {
        foreach ($id in @($ForegroundIds | Select-Object -Unique)) {
            $matching=@($activeRules | Where-Object { $id -in @(Get-AfsQuotaTargetIds $_) })
            if (-not $matching.Count) { continue }
            $add=$Elapsed
            foreach ($r in $matching) {
                $used=0.0
                foreach ($target in @(Get-AfsQuotaTargetIds $r)) { $used += [double]$State.targets[$target] }
                $phoneUsed=0.0
                $limitMinutes=[int]$r.dailyMinutes
                if ($r.ContainsKey('shared') -and [bool]$r.shared) {
                    if ($null -ne $SharedPools -and $SharedPools.ContainsKey([string]$r.id)) {
                        $pool=$SharedPools[[string]$r.id]
                        $phoneUsed=[double]$pool.usedSeconds
                        if ([int]$pool.minutes -gt 0) { $limitMinutes=[int]$pool.minutes }
                    } else {
                        $phoneUsed=[double]$SharedUsedSeconds
                        if ($PoolMinutes -gt 0) { $limitMinutes=[int]$PoolMinutes }
                    }
                }
                $room=[double]$limitMinutes*60-$used-$phoneUsed
                # 共享池：本地能再记多少，取决于池子里还剩多少，不只是本地还剩多少。
                $add=[Math]::Min($add,[Math]::Max(0.0,$room))
            }
            $State.targets[$id]=[double]$State.targets[$id]+$add
        }
    }
    $State.apps=@{}
    foreach ($r in $Config.rules) {
        $activeToday = Test-AfsQuotaRuleActive $r $Now
        $used=0.0
        foreach ($target in @(Get-AfsQuotaTargetIds $r)) { $used += [double]$State.targets[$target] }
        $phoneUsed=0.0
        $limitMinutes=[int]$r.dailyMinutes
        if ($r.ContainsKey('shared') -and [bool]$r.shared) {
            if ($null -ne $SharedPools -and $SharedPools.ContainsKey([string]$r.id)) {
                $pool=$SharedPools[[string]$r.id]
                $phoneUsed=[double]$pool.usedSeconds
                if ([int]$pool.minutes -gt 0) { $limitMinutes=[int]$pool.minutes }
            } else {
                $phoneUsed=[double]$SharedUsedSeconds
                if ($PoolMinutes -gt 0) { $limitMinutes=[int]$PoolMinutes }
            }
        }
        $limit=[int]$limitMinutes*60
        $charged=$used
        if ($r.ContainsKey('shared') -and [bool]$r.shared) {
            $charged=$used+$phoneUsed
        }
        $remaining=[Math]::Max(0.0,$limit-$charged)
        $State.apps[$r.id]=@{
            usedSeconds=$used
            limitSeconds=$limit
            remainingSeconds=$remaining
            exhausted=($activeToday -and $remaining -le 0)
            chargedSeconds=$charged
            shared=($r.ContainsKey('shared') -and [bool]$r.shared)
            activeToday=$activeToday
            days=@($r.days)
        }
    }
    $State.version=5; $State.updatedAt=$Now.ToString('o')
    return $State
}

function Read-AfsAppQuotaState {
    param([string]$Path, [datetime]$Now)
    if (-not (Test-Path -LiteralPath $Path)) { return @{version=4;date=(Get-AfsQuotaDayKey $Now);targets=@{}} }
    try {
        $state=Read-AfsJson $Path
        if ($state.date -notmatch '^\d{4}-\d{2}-\d{2}$') { throw 'Invalid date' }
        $values=@($state.usedSeconds)
        if ($state.ContainsKey('targets')) {
            if ($state.targets -isnot [hashtable]) { throw 'Invalid target state' }
            $values=@($state.targets.Values)
        } elseif ($state.ContainsKey('apps')) {
            if ($state.apps -isnot [hashtable]) { throw 'Invalid app state' }
            $values=@($state.apps.Values | ForEach-Object { $_.usedSeconds })
        }
        foreach ($value in $values) {
            if ($null -eq $value -or [double]$value -lt 0 -or [double]::IsNaN([double]$value) -or [double]::IsInfinity([double]$value)) { throw 'Invalid usage' }
        }
        return $state
    } catch { return @{version=4;date=(Get-AfsQuotaDayKey $Now);targets=@{};error='Quota state unreadable'} }
}
