# Shared validation/matching for the quota worker and settings API.
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
        if ($old.includeValorant) { $rules += @{type='valorant'; name='无畏契约'; dailyMinutes=$old.dailyMinutes} }
        if ($old.includeSteam) { $rules += @{type='steam'; name='Steam（含 Steam 游戏）'; dailyMinutes=$old.dailyMinutes} }
        foreach ($name in $old.processes) { $rules += @{type='process'; name=$name; dailyMinutes=$old.dailyMinutes} }
        $Config = @{enabled=$old.enabled; rules=$rules}
    }
    if ($Config.enabled -isnot [bool]) { throw '启用状态格式不正确' }
    $rules = @(); $ids = @{}; $sharedSeen = $false
    foreach ($r in @($Config.rules)) {
        if ($null -eq $r) { throw '应用规则不能为空' }
        $check = @{enabled=$false; dailyMinutes=$r.dailyMinutes; includeSteam=$false; includeValorant=$false; processes=@()}
        $type = [string]$r.type
        $extraProcs = @()
        switch ($type) {
            'games' {
                # 共享格子 = 无畏契约 + Steam + 可选附加进程(同一个 id 'games', 共用一份额度)
                $id='games'
                foreach ($p in @($r.processes)) {
                    if ($null -eq $p -or $p -isnot [string]) { continue }
                    $probe = ConvertTo-AfsQuotaConfig @{ enabled=$false; dailyMinutes=1; includeSteam=$false; includeValorant=$false; processes=@($p) }
                    foreach ($n in @($probe.processes)) { $extraProcs += $n }
                }
                $extraProcs = @($extraProcs | Sort-Object -Unique)
                foreach ($n in $extraProcs) {
                    if ($n -in @('steam','steamwebhelper','valorant','valorant-win64-shipping')) { throw "无畏契约 / Steam 已经在共享格子里，不用重复添加：$n" }
                }
                $name = if ($extraProcs.Count -gt 0) { '无畏契约 + Steam + ' + ($extraProcs -join ' + ') + '（共享）' } else { '无畏契约 + Steam（共享）' }
            }
            'steam' { $id='steam'; $name='Steam（含 Steam 游戏）' }
            'valorant' { $id='valorant'; $name='无畏契约' }
            'process' {
                $check.processes = @($r.name)
                $valid = ConvertTo-AfsQuotaConfig $check
                if ($valid.processes.Count -ne 1) { throw '请输入应用进程名' }
                $name = $valid.processes[0]; $id = 'process:' + $name
                if ($name -in @('steam','steamwebhelper')) { $id='steam'; $type='steam'; $name='Steam（含 Steam 游戏）' }
                if ($name -in @('valorant','valorant-win64-shipping','无畏契约登录器')) { $id='valorant'; $type='valorant'; $name='无畏契约' }
            }
            default { throw '应用规则类型不正确' }
        }
        $valid = ConvertTo-AfsQuotaConfig $check
        if ($ids.ContainsKey($id)) { throw "应用重复：$name" }
        $ids[$id]=$true
        $rule = @{id=$id; type=$type; name=$name; dailyMinutes=$valid.dailyMinutes}
        if ($type -eq 'games' -and @($extraProcs).Count -gt 0) { $rule.processes = @($extraProcs) }
        # 跨设备共享：这条规则的用量和手机端上报的用量合并成一个池子。
        # 只允许一条 —— 两条共享规则的池上限会互相打架，没法说清谁说了算。
        if ($r.ContainsKey('shared') -and [bool]$r.shared) {
            if ($sharedSeen) { throw '只能有一条规则参与跨设备共享' }
            $sharedSeen = $true
            $rule.shared = $true
        }
        $rules += $rule
    }
    if ($rules.Count -gt 100) { throw '最多选择 100 个应用' }
    if ($Config.enabled -and $rules.Count -eq 0) { throw '请至少选择一个应用' }
    if ($ids.ContainsKey('games') -and ($ids.ContainsKey('steam') -or $ids.ContainsKey('valorant'))) { throw '共享格子与独立格子不能同时包含相同应用，请先合并或拆分' }
    return @{version=4; enabled=$Config.enabled; rules=$rules; mode='foreground'; reset='local-midnight'}
}

function Get-AfsQuotaEditWindow {
    param([datetime]$Now = (Get-Date), [string]$OverridePath = (Join-Path $PSScriptRoot 'quota-edit-until.json'))
    $allowed = ($Now.Hour -eq 21)
    $next = $Now.Date.AddHours(21)
    if ($Now -ge $next.AddHours(1)) { $next = $next.AddDays(1) }
    $temporary = $false
    $until = $null
    if ($allowed) { $until = $Now.Date.AddHours(22).ToString('o') }
    if (Test-Path -LiteralPath $OverridePath) {
        try {
            $grant = Read-AfsJson $OverridePath
            $expires = [DateTimeOffset]::Parse([string]$grant.expiresAt)
            if ($expires -gt [DateTimeOffset]$Now) {
                $allowed = $true; $temporary = $true; $until = $expires.ToString('o')
            }
        } catch { } # Malformed or expired grants never open the settings.
    }
    return @{allowed=$allowed; temporary=$temporary; until=$until; next=$next.ToString('o'); label='每天 21:00–21:59'; serverTime=$Now.ToString('o')}
}

# 规定时间(每天 21:00–21:59)以外, 共享格子/应用/进程「只进不出」:
#   允许 —— 新增应用(额度不超过默认 120 分钟)、往共享格子加进程
#   拒绝 —— 删应用 / 删共享格子成员 / 改任何已有格子的每日时长 / 关掉限额开关
# 两个入参都必须是 ConvertTo-AfsAppQuotaConfig 归一化后的配置。
# 返回 $null 表示允许, 否则返回拒绝原因。
function Test-AfsQuotaAppendOnly {
    param($Current, $Incoming)
    if ($null -eq $Current) { return $null }
    if ([bool]$Incoming.enabled -ne [bool]$Current.enabled) {
        return '规定时间以外, 每日限额的总开关不能改(关掉就等于放行)。请等每天 21:00–21:59 再操作。'
    }
    $curRules = @{}
    foreach ($r in @($Current.rules)) { $curRules[[string]$r.id] = $r }
    $newRules = @{}
    foreach ($r in @($Incoming.rules)) { $newRules[[string]$r.id] = $r }

    foreach ($id in @($curRules.Keys)) {
        $a = $curRules[$id]
        if (-not $newRules.ContainsKey($id)) {
            return ('规定时间以外, 应用和进程「只进不出」—— 不能移除: ' + $a.name + '。想删请等每天 21:00–21:59。')
        }
        $b = $newRules[$id]
        if ([int]$b.dailyMinutes -ne [int]$a.dailyMinutes) {
            return ('规定时间以外不能改每日时长: ' + $a.name + ' (' + [int]$a.dailyMinutes + ' → ' + [int]$b.dailyMinutes + ' 分钟)。想改请等每天 21:00–21:59。')
        }
        # 关掉共享 = 把手机那半边已经用掉的时间从账上放走, 和调大额度是同一类事。
        if ($a.ContainsKey('shared') -and [bool]$a.shared -and -not ($b.ContainsKey('shared') -and [bool]$b.shared)) {
            return ('规定时间以外不能关掉跨设备共享: ' + $a.name + '。关掉等于把手机那边的用量放走, 想改请等每天 21:00–21:59。')
        }
        $oldProcs = @($a.processes | Where-Object { $_ })
        $newProcs = @($b.processes | Where-Object { $_ })
        foreach ($p in $oldProcs) {
            if ($p -notin $newProcs) {
                return ('规定时间以外, 共享格子里的进程「只进不出」—— 不能移除: ' + $p + '。想删请等每天 21:00–21:59。')
            }
        }
    }
    foreach ($id in @($newRules.Keys)) {
        if ($curRules.ContainsKey($id)) { continue }
        if ([int]$newRules[$id].dailyMinutes -gt 120) {
            return ('规定时间以外新增应用只能用默认 120 分钟额度: ' + $newRules[$id].name + '。想设更长请等每天 21:00–21:59。')
        }
    }
    $null
}

function Get-AfsQuotaMatches {
    param([string]$Name, [string]$Path, [object[]]$Rules)
    foreach ($r in $Rules) {
        $c = @{includeSteam=($r.type -in @('steam','games')); includeValorant=($r.type -in @('valorant','games')); processes=@()}
        if ($r.type -eq 'process') { $c.processes=@($r.name) }
        if ($r.type -eq 'games') { $c.processes=@($r.processes | Where-Object { $_ }) }
        if (Test-AfsGameProcess $Name $Path $c) { $r.id }
    }
}

function Get-AfsQuotaTargetIds {
    param($Rule)
    if ($Rule.type -eq 'games') {
        $ids = @('valorant','steam')
        foreach ($p in @($Rule.processes | Where-Object { $_ })) { $ids += ('process:' + $p) }
        return $ids
    }
    $Rule.id
}

function Get-AfsForegroundQuotaTarget {
    param([string]$Name, [string]$Path, [object[]]$Rules)
    # Count one foreground interval once, even when a game matches a broad
    # Steam path and a more specific application rule.
    foreach ($r in @($Rules | Where-Object { $_.type -eq 'process' })) {
        if (@(Get-AfsQuotaMatches $Name $Path @($r)).Count) { return $r.id }
    }
    # 共享格子的附加进程: 单独判断, 返回它自己的 target id (与 valorant/steam 共用同一份额度)
    foreach ($r in @($Rules | Where-Object { $_.type -eq 'games' })) {
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
          [double]$SharedUsedSeconds=0, [int]$PoolMinutes=0)
    $today=$Now.ToString('yyyy-MM-dd')
    if ($State.date -ne $today) {
        $State=@{version=4;date=$today;targets=@{}}
        $Elapsed=[Math]::Min($Elapsed,$Now.TimeOfDay.TotalSeconds)
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
    foreach ($r in $Config.rules) {
        foreach ($id in @(Get-AfsQuotaTargetIds $r)) {
            if (-not $State.targets.ContainsKey($id)) { $State.targets[$id]=0.0 }
            if ($State.error) { $State.targets[$id]=[Math]::Max([double]$State.targets[$id], [double]$r.dailyMinutes*60) }
        }
    }
    if ($Config.enabled -and $Elapsed -gt 0 -and $Elapsed -le 5) {
        foreach ($id in @($ForegroundIds | Select-Object -Unique)) {
            $matching=@($Config.rules | Where-Object { $id -in @(Get-AfsQuotaTargetIds $_) })
            if (-not $matching.Count) { continue }
            $add=$Elapsed
            foreach ($r in $matching) {
                $used=0.0
                foreach ($target in @(Get-AfsQuotaTargetIds $r)) { $used += [double]$State.targets[$target] }
                $room=[double]$r.dailyMinutes*60-$used
                # 共享池：本地能再记多少，取决于池子里还剩多少，不只是本地还剩多少。
                if ($r.ContainsKey('shared') -and [bool]$r.shared) {
                    $poolLimit = if ($PoolMinutes -gt 0) { [double]$PoolMinutes*60 } else { [double]$r.dailyMinutes*60 }
                    $room = $poolLimit-$used-[double]$SharedUsedSeconds
                }
                $add=[Math]::Min($add,[Math]::Max(0.0,$room))
            }
            $State.targets[$id]=[double]$State.targets[$id]+$add
        }
    }
    $State.apps=@{}
    foreach ($r in $Config.rules) {
        $used=0.0
        foreach ($target in @(Get-AfsQuotaTargetIds $r)) { $used += [double]$State.targets[$target] }
        $limit=[int]$r.dailyMinutes*60
        $charged=$used
        if ($r.ContainsKey('shared') -and [bool]$r.shared) {
            if ($PoolMinutes -gt 0) { $limit=[int]$PoolMinutes*60 }
            $charged=$used+[double]$SharedUsedSeconds
        }
        $remaining=[Math]::Max(0.0,$limit-$charged)
        $State.apps[$r.id]=@{usedSeconds=$used;limitSeconds=$limit;remainingSeconds=$remaining;exhausted=($remaining -le 0);chargedSeconds=$charged;shared=($r.ContainsKey('shared') -and [bool]$r.shared)}
    }
    $State.version=4; $State.updatedAt=$Now.ToString('o')
    return $State
}

function Read-AfsAppQuotaState {
    param([string]$Path, [datetime]$Now)
    if (-not (Test-Path -LiteralPath $Path)) { return @{version=4;date=$Now.ToString('yyyy-MM-dd');targets=@{}} }
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
    } catch { return @{version=4;date=$Now.ToString('yyyy-MM-dd');targets=@{};error='Quota state unreadable'} }
}
