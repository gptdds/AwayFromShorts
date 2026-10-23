# ============================================================
#  AwayFromShorts - webui.ps1 (可视化配置面板)
#  启动本地 Web 服务: http://127.0.0.1:8737
#  用法: powershell -ExecutionPolicy Bypass -File webui.ps1
#  (由 start-web.bat / install.bat 调用, 无需管理员权限)
# ============================================================
param([int]$Port = 0)

$ErrorActionPreference = 'Stop'

# ---------------- 管理员权限(自我提权) ----------------
# 面板需要管理员权限才能直接写 hosts / 管理浏览器策略 / 操作网卡等。
# 非管理员启动时自动弹 UAC 提权重启; 用户取消则继续以当前权限运行(不退出)。
$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $MyInvocation.MyCommand.Path + '"'
    $psi.Verb = 'runas'
    $psi.UseShellExecute = $true
    try {
        [System.Diagnostics.Process]::Start($psi) | Out-Null
        exit
    } catch { }
    # UAC 被取消或失败 -> 继续以当前权限运行
}

. "$PSScriptRoot\core.ps1"

$cfg = Get-AfsConfig
if ($Port -eq 0) { $Port = $cfg.web.port }
if ($Port -lt 1 -or $Port -gt 65535) { $Port = 8737 }

$indexPath = Join-Path $PSScriptRoot 'web\index.html'
if (-not (Test-Path $indexPath)) { throw "缺少前端页面: $indexPath" }
$indexBytes = [System.IO.File]::ReadAllBytes($indexPath)

# 学习台(本地库): 页面是原版 final.html, 数据落本机, 不再依赖资料库在线表
$studyPagePath = Join-Path $PSScriptRoot 'web\study.html'
$script:StudyDbPath = Join-Path $PSScriptRoot 'study-db.json'

# ---------------- 基础 HTTP ---------------

function Send-AfsResponse {
    param($Stream, [int]$Status, [string]$Type, $Body)
    $bytes = if ($Body -is [byte[]]) { $Body } else { [System.Text.Encoding]::UTF8.GetBytes([string]$Body) }
    $head = "HTTP/1.1 $Status`r`nContent-Type: $Type`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($hb, 0, $hb.Length)
    if ($bytes.Length -gt 0) { $Stream.Write($bytes, 0, $bytes.Length) }
    $Stream.Flush()
}

function Send-AfsJson {
    param($Stream, [int]$Status, $Obj)
    $json = ConvertTo-Json $Obj -Depth 12 -Compress
    Send-AfsResponse -Stream $Stream -Status $Status -Type 'application/json; charset=utf-8' -Body $json

}
# ---------------- 学习台: 本地库 ----------------
# web/study.html 是从 WorkBuddy 资料库搬来的原版页面, 靠 window.__SMART_PAGE__ 垫片工作。
# 垫片把 SDK 的 query/addRecord/updateRecord/deleteRecord 翻译成 /api/study/db/*,
# 数据落在本机 study-db.json —— 不需要登录态, 也不再依赖云端在线表。
$script:AFS_STUDY_TABLES = @('goals', 'logs', 'notes', 'focus')

function Read-AfsStudyStore {
    if (-not (Test-Path $script:StudyDbPath)) {
        return @{ goals = @(); logs = @(); notes = @(); focus = @() }
    }
    $store = ConvertTo-AfsHashtable (ConvertFrom-Json (Read-AfsTextRetry -Path $script:StudyDbPath))
    foreach ($k in $script:AFS_STUDY_TABLES) {
        if (-not $store.ContainsKey($k) -or $null -eq $store[$k]) { $store[$k] = @() }
        else { $store[$k] = @($store[$k]) }
    }
    $store
}

function Save-AfsStudyStore {
    param($Store)
    Write-AfsTextAtomic -Path $script:StudyDbPath -Text (ConvertTo-Json $Store -Depth 12)
}

# 页面写记录时字段带类型({ 总量: { number: 20 } }), 本地库只存裸值
function Get-AfsStudyValue {
    param($Prop)
    if ($null -eq $Prop) { return $null }
    if ($Prop -is [string] -or $Prop -is [int] -or $Prop -is [long] -or $Prop -is [double] -or $Prop -is [bool]) { return $Prop }
    foreach ($k in @('text', 'number', 'date', 'checkbox', 'select', 'multiSelect')) {
        $p = $Prop.PSObject.Properties[$k]
        if ($null -ne $p) { return $p.Value }
    }
    $Prop
}

function Get-AfsStudyTable {
    param([string]$Name)
    if ($script:AFS_STUDY_TABLES -notcontains $Name) { throw "未知数据表: $Name" }
    $Name
}

# ---------------- 状态 ----------------

function Get-AfsStatusObj {
    $cfg = Get-AfsConfig
    $state = Get-AfsActiveState -Config $cfg
    $lastRun = $null
    $lastPath = Join-Path (Split-Path (Get-AfsConfigPath)) 'last-run.json'
    if (Test-Path $lastPath) {
        try {
            $lastRun = ConvertTo-AfsHashtable (ConvertFrom-Json ([System.IO.File]::ReadAllText($lastPath, [System.Text.Encoding]::UTF8)))
        } catch { }
    }
    $ub = Get-AfsUninstallBlock
    @{
        ok          = $true
        version     = $script:AFS_VERSION
        isAdmin     = Get-AfsIsAdmin
        active      = $state.active
        activeReason = $state.reason
        enabled     = $cfg.enabled
        hosts       = Get-AfsHostsState -Path (Get-AfsDefaultHostsPath)
        task        = Get-AfsTaskInfo
        nextActive  = Get-AfsNextActiveTime -Config $cfg
        lastRun     = $lastRun
        config      = $cfg
        forceActive = ((Test-AfsForceActive -Config $cfg).active)
        pending     = (Read-AfsPendingQueue)
        # 强制模式期间禁止卸载: 面板据此禁用按钮(仅提示用, 真拦在 /api/uninstall 与 uninstall.ps1)
        uninstallBlocked = $ub.blocked
        uninstallMsg     = $ub.msg
        uninstallReason  = $ub.reason
    }
}

# ---------------- 路由 ----------------
# 注意: Windows PowerShell 5.1 不能在 .NET Thread 上执行 scriptblock(会直接崩溃进程),
#       所以这里顺序处理每个连接(本地单用户面板, 响应毫秒级, 足够用)。

$handler = {
    param($client)
    $stream = $null
    $ErrorActionPreference = 'Continue'   # 路由里用显式 throw, 不依赖全局 Stop
    try {
        $stream = $client.GetStream()
        $stream.ReadTimeout = 8000
        $buf  = [byte[]]::new(16384)
        $raw  = [System.Collections.Generic.List[byte]]::new()
        $head = $null
        $contentLength = 0
        $headBytesLen = 0

        # 读请求头 (字节累积, 之后按字节切 body —— 字符数 vs Content-Length 字节数混用会导致中文 body 误判未读完)
        while ($true) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            for ($k = 0; $k -lt $n; $k++) { $raw.Add($buf[$k]) }
            $all = [System.Text.Encoding]::UTF8.GetString($raw.ToArray())
            $idx = $all.IndexOf("`r`n`r`n")
            if ($idx -ge 0) {
                $headStr = $all.Substring(0, $idx)
                $head = $headStr
                $headBytesLen = [System.Text.Encoding]::UTF8.GetByteCount($headStr) + 4
                foreach ($line in ($headStr -split "`r`n")) {
                    if ($line -match '^Content-Length:\s*(\d+)') { $contentLength = [int]$Matches[1] }
                }
                break
            }
        }
        if ($null -eq $head) { throw 'bad request' }

        # 读满 body (按字节补齐)
        while ($raw.Count -lt ($headBytesLen + $contentLength)) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            for ($k = 0; $k -lt $n; $k++) { $raw.Add($buf[$k]) }
        }
        $bodyBytes = if ($contentLength -gt 0 -and $raw.Count -ge ($headBytesLen + $contentLength)) {
            $raw.GetRange($headBytesLen, $contentLength).ToArray()
        } else { $raw.ToArray() }
        $body = [System.Text.Encoding]::UTF8.GetString($bodyBytes)

        $parts = $head -split '\s+'
        $method = if ($parts.Count -gt 0) { $parts[0].ToUpper() } else { '' }
        $path   = if ($parts.Count -gt 1) { $parts[1] } else { '/' }
        if ($path -match '\?') { $path = $path.Substring(0, $path.IndexOf('?')) }

        $appDir = Split-Path (Get-AfsConfigPath)
        $logPath = Join-Path $appDir 'last-run.json'

        # ---------- 路由表 ----------
        if ($method -eq 'GET' -and $path -eq '/') {
            Send-AfsResponse -Stream $stream -Status 200 -Type 'text/html; charset=utf-8' -Body $indexBytes
            return
        }
        if ($path -eq '/api/ping') { Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; pong = $true }; return }
        if ($method -eq 'GET' -and $path -eq '/api/config') {
            # 顺手尝试把排队内容落地: 只有"非强制生效时段"才会真的合并进 config, 无队列时几乎零成本
            try { Invoke-AfsPendingApply | Out-Null } catch { }
            $cfgNow = Get-AfsConfig
            Send-AfsJson -Stream $stream -Status 200 -Obj @{
                ok          = $true
                config      = $cfgNow
                forceActive = (Test-AfsForceActive -Config $cfgNow).active
                pending     = (Read-AfsPendingQueue)
            }
            return
        }
        if ($method -eq 'GET' -and $path -eq '/api/status') {
            Send-AfsJson -Stream $stream -Status 200 -Obj (Get-AfsStatusObj)
            return
        }
        if ($method -eq 'GET' -and $path -eq '/api/browser/windows') {
            $w = @(Get-Process msedge,chrome -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowTitle } |
                ForEach-Object { [string]$_.MainWindowTitle } | Select-Object -Unique)
            Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; windows = $w }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/config') {
            try {
                $o = $body | ConvertFrom-Json -ErrorAction Stop
                $inCfg = ConvertTo-AfsHashtable $o
                # 先把已有排队内容落地 (如果此刻已经不在强制生效时段)
                try { Invoke-AfsPendingApply | Out-Null } catch { }
                $curCfg = Get-AfsConfig
                $forceNow = Test-AfsForceActive -Config $curCfg
                if ($forceNow.active -and -not [bool]$inCfg.enabled) {
                    throw "强制模式生效中 (可先关闭强制模式, 再关闭屏蔽)"
                }
                # 强制模式开启期间:
                #   「屏蔽星期 / 屏蔽时段」-> 硬拒 (它们正是"何时算非屏蔽时段"的定义, 改了就绕开强制)
                #   「放宽」类(删屏蔽项 / 关屏蔽开关 / 往白名单加项) -> 生效时段内硬拒 (只能增不能删, 删了就是放行)
                #   「收紧」类(加屏蔽项 / 开屏蔽开关 / 从白名单删项) -> 立即落地生效 (只收紧, 无放行风险),
                #     合并进 config 后马上踢一次屏蔽引擎, 不再等本次时段结束。
                #   判据集中在 core.ps1 的 Get-AfsConfigLockDiff (可离线回归测试)。
                if ([bool]$curCfg.force.enabled) {
                    $diff = Get-AfsConfigLockDiff -Current $curCfg -Incoming $inCfg
                    if ($diff.hardMsg) { throw $diff.hardMsg }
                    if ($forceNow.active -and $diff.widenMsg) { throw $diff.widenMsg }
                    if (@($diff.queueKeys).Count -gt 0 -and $forceNow.active) {
                        # 老版本排下的队列先一并落地, 再叠本次改动 (都只收紧, 无放行风险)
                        try {
                            Invoke-AfsPendingApply -Config $curCfg -IgnoreWindow | Out-Null
                            $curCfg = Get-AfsConfig
                        } catch { }
                        $np = New-AfsPendingPatch -Current $curCfg -Incoming $inCfg
                        if ([int]$np.total -gt 0) {
                            $merged = Merge-AfsPendingTighten -Base $curCfg -Patch $np.patch
                            $null = Set-AfsConfigSafe -InputConfig $merged
                            Remove-AfsPendingQueue
                        }
                        # 不自动踢引擎(避免额外进程开销): 引擎常规 tick 自然带上新配置;
                        # 急用走面板「⚡ 立即应用」人工触发 (/api/apply)。
                        Send-AfsJson -Stream $stream -Status 200 -Obj @{
                            ok          = $true
                            queued      = $false
                            note        = '已保存: 收紧改动已写入配置, 引擎下一轮自动应用; 急用点「立即应用」'
                            config      = (Get-AfsConfig)
                            forceActive = $true
                            pending     = $null
                        }
                        return
                    }
                }
                $newCfg = Set-AfsConfigSafe -InputConfig $inCfg
                # 期望状态已整份写入 config, 排队内容不再需要
                Remove-AfsPendingQueue
                Send-AfsJson -Stream $stream -Status 200 -Obj @{
                    ok          = $true
                    queued      = $false
                    note        = '已保存, 屏蔽引擎将在 1 分钟内应用'
                    config      = $newCfg
                    forceActive = (Test-AfsForceActive -Config $newCfg).active
                    pending     = $null
                }
            } catch {
                Send-AfsJson -Stream $stream -Status 400 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/pending/clear') {
            try {
                Remove-AfsPendingQueue
                Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; queued = $false; pending = $null; note = '已撤销排队中的改动' }
            } catch {
                Send-AfsJson -Stream $stream -Status 400 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/force') {
            try {
                $o = $body | ConvertFrom-Json -ErrorAction Stop
                $enable = [bool]$o.enabled
                $c = Get-AfsConfig
                if ($enable) {
                    # 可选"强制星期" (1=周一..7=周日, 空=跟随屏蔽计划星期)
                    $c.force.weekdays = $null
                    if ($o.PSObject.Properties.Name -contains 'weekdays' -and $o.weekdays) {
                        $wd = @($o.weekdays | ForEach-Object { [int]$_ } | Where-Object { $_ -ge 1 -and $_ -le 7 } | Select-Object -Unique)
                        if ($wd.Count -gt 0) { $c.force.weekdays = $wd }
                    }
                    # 长期模式(星期循环, 无到期日): 所选星期的屏蔽窗口内持续强制, 直到手动关闭
                    $c.force.enabled = $true
                    $c.force.until  = $null
                    Set-AfsConfigSafe -InputConfig $c | Out-Null
                    Save-AfsForceState -Until $null
                    Send-AfsJson -Stream $stream -Status 200 -Obj @{
                        ok = $true
                        until = $null
                        note = '强制模式已开启: 所选星期的屏蔽时段内长期强制(无到期日); 强制中无法关闭, 窗口外 / 非所选星期可手动关闭'
                    }
                } else {
                    # 开启后当天内不可关闭(防破戒): 生效中(屏蔽窗口内且未到期)一律拒绝
                    $ft = Test-AfsForceActive -Config $c
                    if ($ft.active) {
                        Send-AfsJson -Stream $stream -Status 403 -Obj @{ ok = $false; error = '强制模式正在生效中, 无法关闭(防破戒): 等当前屏蔽时段结束, 或在非所选星期 / 屏蔽窗口外再关闭。' }
                        return
                    }
                    # 未生效(已到期 / 窗口外残留): 允许清理
                    $c.force.enabled = $false
                    $c.force.until  = $null
                    $c.force.weekdays = $null
                    Set-AfsConfigSafe -InputConfig $c | Out-Null
                    Remove-AfsForceState
                    Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; note = '强制模式已关闭(未生效状态已清理)' }
                }
            } catch {
                Send-AfsJson -Stream $stream -Status 400 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/apply') {
            try {
                # 先把历史遗留的排队内容落地(补丁只收紧, 任何时刻落地都无放行风险),
                # 再跑本次强制 —— 保证「立即应用」点下去, 面板上能看到的所有收紧改动全部生效。
                $flushErr = $null
                try { Invoke-AfsPendingApply -IgnoreWindow | Out-Null } catch { $flushErr = $_.Exception.Message }
                $cfgNow = Get-AfsConfig
                if (Get-AfsIsAdmin) {
                    $res = Invoke-AfsLocked -Action {
                        Invoke-AfsEnforce -Config $cfgNow -HostsPath (Get-AfsDefaultHostsPath) -LogPath $logPath
                    }
                    Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; applied = $true; result = $res; flushError = $flushErr }
                } else {
                    Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; applied = $false; note = '面板非管理员权限, 已交由计划任务执行(1 分钟内)' }
                }
            } catch {
                Send-AfsJson -Stream $stream -Status 500 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/override') {
            try {
                $o = $body | ConvertFrom-Json -ErrorAction Stop
                $mode = [string]$o.mode
                $minutes = try { [int]$o.minutes } catch { 30 }
                if ($mode -notin @('none','block','off')) { throw 'mode 必须为 none/block/off' }
                $c = Get-AfsConfig
                $forceNow = Test-AfsForceActive -Config $c
                if ($forceNow.active -and $mode -in @('off','none')) {
                    throw "强制模式生效中 (可先关闭强制模式, 再解除屏蔽)"
                }
                if ($mode -eq 'none') {
                    $c.override.mode = 'none'; $c.override.until = $null
                } else {
                    $c.override.mode = $mode
                    $c.override.until = (Get-Date).AddMinutes($minutes).ToString('o')
                }
                Set-AfsConfigSafe -InputConfig $c | Out-Null   # 返回值必须吞掉, 否则会泄漏到 stdout
                # 立即记录统计状态(解除起点/结算), 不依赖下方 enforce 是否成功 —— 面板繁忙/僵死时起点也不会丢
                try { Invoke-AfsLocked -Action { $c2 = Get-AfsConfig; $s2 = Get-AfsActiveState -Config $c2; Update-AfsUnlockStats -Config $c2 -Reason $s2.reason } } catch { }
                # 立即生效: 管理员面板直接同步执行 enforcer, 不等计划任务 (任务可能失败/错过触发, 避免"点了没用")
                $applied = $false
                if (Get-AfsIsAdmin) {
                    try {
                        Invoke-AfsLocked -Action {
                            Invoke-AfsEnforce -Config (Get-AfsConfig) -HostsPath (Get-AfsDefaultHostsPath) -LogPath $logPath
                        } | Out-Null
                        $applied = $true
                    } catch { $applied = $false }
                }
                if ($applied) { $note = '已设置并立即生效' } else { $note = '已设置, 1 分钟内生效(自动)' }
                Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; until = $c.override.until; applied = $applied; note = $note }
            } catch {
                Send-AfsJson -Stream $stream -Status 400 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'GET' -and $path -eq '/api/study') {
            # 学习联动状态: 开关/区间 + 今天目标进度 + 当前是否因学习被继续屏蔽
            try {
                $cfgS  = Get-AfsConfig
                $infoS = Get-AfsStudyInfo
                $stS   = Get-AfsActiveState -Config $cfgS
                $pend  = @()
                if ($infoS.ok) { $pend = @($infoS.pendingNames) }
                # 手机端的数据靠 push_gist.ps1 推; 连续推不上去时面板要亮角标,
                # 否则"手机上还锁着/已经不锁了"这类问题只能翻日志才发现。
                $gistS = @{ fails = 0; lastOk = ''; lastFail = ''; error = '' }
                try {
                    $gp = Join-Path (Split-Path (Get-AfsConfigPath)) 'study-gist-state.json'
                    if (Test-Path $gp) {
                        $gj = ConvertFrom-Json ([System.IO.File]::ReadAllText($gp, [System.Text.Encoding]::UTF8))
                        $gistS = @{ fails    = [int]$gj.fails
                                    lastOk   = [string]$gj.lastOk
                                    lastFail = [string]$gj.lastFail
                                    error    = [string]$gj.error }
                    }
                } catch { }
                Send-AfsJson -Stream $stream -Status 200 -Obj @{
                    ok        = $true
                    studyHold = $cfgS.studyHold
                    flag      = $infoS
                    active    = $stS.active
                    reason    = $stS.reason
                    pending   = $pend
                    gist      = $gistS
                }
            } catch {
                Send-AfsJson -Stream $stream -Status 500 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/study/hold') {
            try {
                $b = $body | ConvertFrom-Json -ErrorAction Stop
                # 只有开关, 没有时间窗(老的 start/end 字段来了也直接忽略)
                $c = Get-AfsConfig
                # 防绕过: PC 正在屏蔽中就不许关学习联动 —— 目标没打完时打开面板
                # 把开关一关, 延长屏蔽立刻失效。
                # force 长期开着的话这一条等于把开关焊死, 关它得先过 force 这关。
                if (-not [bool]$b.enabled) {
                    $stH = Get-AfsActiveState -Config $c
                    if ($stH.active) {
                        throw ("PC 正在屏蔽时间内（" + $stH.reason + "），学习联动开关不能关闭")
                    }
                }
                $c.studyHold = @{ enabled = [bool]$b.enabled }
                Set-AfsConfigSafe -InputConfig $c | Out-Null
                Send-AfsJson -Stream $stream -Status 200 -Obj @{
                    ok = $true; studyHold = (Get-AfsConfig).studyHold
                    note = '已保存, 1 分钟内生效'
                }
            } catch {
                Send-AfsJson -Stream $stream -Status 400 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/study/check') {
            try {
                $run = Invoke-AfsStudySync -Wait
                $infoS = Get-AfsStudyInfo
                Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; flag = $infoS; run = $run }
            } catch {
                Send-AfsJson -Stream $stream -Status 500 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'GET' -and $path -eq '/api/stats') {
            Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; stats = (Read-AfsStats) }
            return
        }
        if ($method -eq 'GET' -and $path -eq '/api/activity') {
            Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; activity = (Read-AfsActivity) }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/stats/clear') {
            try {
                Clear-AfsStats
                Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; note = '统计已清空' }
            } catch {
                Send-AfsJson -Stream $stream -Status 500 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/uninstall') {
            # 强制模式期间禁止卸载(防破戒): 这里是 UI 入口的硬拦, uninstall.ps1 里还有一道,
            # 两道判据同源(Get-AfsUninstallBlock), 所以即使绕过前端也拦得住。
            $ub = Get-AfsUninstallBlock
            if ($ub.blocked) {
                Send-AfsJson -Stream $stream -Status 403 -Obj @{ ok = $false; error = $ub.msg; blocked = $true; reason = $ub.reason }
                return
            }
            try {
                $uninstallPs1 = Join-Path $PSScriptRoot 'uninstall.ps1'
                if (-not (Test-Path $uninstallPs1)) { throw "找不到 $uninstallPs1" }
                $argStr = "-NoProfile -ExecutionPolicy Bypass -File `"$uninstallPs1`""
                Start-Process -FilePath 'powershell.exe' -ArgumentList $argStr -Verb RunAs
                Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; note = '卸载程序已启动, 请在弹窗中确认' }
            } catch {
                Send-AfsJson -Stream $stream -Status 500 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        # ---------- 账号 / 云同步 (GitHub Gist) ----------
        if ($method -eq 'GET' -and $path -eq '/api/account') {
            Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; account = (Get-AfsAccountInfo) }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/account/login') {
            try {
                $o = $body | ConvertFrom-Json -ErrorAction Stop
                $token = [string]$o.token
                if (-not $token) { throw '请输入 GitHub Personal Access Token' }
                $u = Get-AfsGitHubUser -Token $token   # 验证失败会抛 401
                Save-AfsGitHubToken -Token $token
                Save-AfsAccountCache $u                # 缓存用户信息, 面板后续离线读取
                $state = Get-AfsSyncState
                Send-AfsJson -Stream $stream -Status 200 -Obj @{
                    ok = $true
                    account = @{
                        loggedIn = $true; login = $u.login; name = $u.name; email = $u.email
                        gistId = $state.gistId; lastSync = $state.lastSync; autoPush = [bool]$state.autoPush
                    }
                    note = "登录成功: $($u.login)"
                }
            } catch {
                Send-AfsJson -Stream $stream -Status 401 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/account/logout') {
            Clear-AfsGitHubToken
            try {
                $s = Get-AfsSyncState
                $s.login = $null; $s.name = $null; $s.email = $null
                Save-AfsSyncState $s
            } catch { }
            Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; note = '已退出登录, 本机 Token 已删除' }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/account/push') {
            try {
                $token = Get-AfsGitHubToken
                if (-not $token) { throw '未登录, 请先输入 GitHub Token' }
                $state = Push-AfsSyncConfig -Token $token
                Send-AfsJson -Stream $stream -Status 200 -Obj @{
                    ok = $true
                    note = "已推送到云端 Gist ($($state.lastSync))"
                    account = (Get-AfsAccountInfo)
                }
            } catch {
                Send-AfsJson -Stream $stream -Status 500 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/account/pull') {
            try {
                $token = Get-AfsGitHubToken
                if (-not $token) { throw '未登录, 请先输入 GitHub Token' }
                $r = Pull-AfsSyncConfig -Token $token
                Send-AfsJson -Stream $stream -Status 200 -Obj @{
                    ok = $true
                    note = "已从云端拉取(本地已备份: $($r.backup))"
                    config = $r.config
                    account = (Get-AfsAccountInfo)
                }
            } catch {
                Send-AfsJson -Stream $stream -Status 500 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/account/autopush') {
            try {
                $o = $body | ConvertFrom-Json -ErrorAction Stop
                $state = Get-AfsSyncState
                $state.autoPush = [bool]$o.autoPush
                Save-AfsSyncState $state
                Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; autoPush = [bool]$state.autoPush }
            } catch {
                Send-AfsJson -Stream $stream -Status 400 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/stop') {
            Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true }
            $script:AFS_STOP = $true
            return
        }
        # ---------- 学习台: 本地库 ----------
        if ($method -eq 'GET' -and ($path -eq '/study' -or $path -eq '/study.html')) {
            if (-not (Test-Path $studyPagePath)) {
                Send-AfsResponse -Stream $stream -Status 404 -Type 'text/plain; charset=utf-8' -Body 'study page missing'
                return
            }
            Send-AfsResponse -Stream $stream -Status 200 -Type 'text/html; charset=utf-8' -Body ([System.IO.File]::ReadAllBytes($studyPagePath))
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/study/db/query') {
            try {
                $q = $body | ConvertFrom-Json -ErrorAction Stop
                $table = Get-AfsStudyTable ([string]$q.table)
                $store = Read-AfsStudyStore
                $rows = @($store[$table])
                if ($table -eq 'focus') {
                    # 专注记录由 sync_activity.py 每 15 分钟从 activity.json 生成，本地优先
                    $fp = Join-Path ([System.IO.Path]::GetDirectoryName($script:StudyDbPath)) 'focus-local.json'
                    if (Test-Path $fp) {
                        try {
                            # ConvertTo-AfsHashtable 用 `,$arr` 返回防展开, 必须先赋值再 @()
                            $tmpRows = ConvertTo-AfsHashtable (ConvertFrom-Json (Read-AfsTextRetry -Path $fp))
                            $rows = @($tmpRows)
                        } catch { }
                    }
                }
                $sorts = @($q.sorts)
                if ($sorts.Count -gt 0 -and $sorts[0] -and $sorts[0].property) {
                    $prop = [string]$sorts[0].property
                    $desc = ([string]$sorts[0].direction) -ne 'ascending'
                    $rows = @($rows | Sort-Object -Property @{ Expression = { [string]$_[$prop] } } -Descending:$desc)
                }
                Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; table = $table; results = $rows; hasMore = $false; nextCursor = '' }
            } catch {
                Send-AfsJson -Stream $stream -Status 400 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/study/db/add') {
            try {
                $o = $body | ConvertFrom-Json -ErrorAction Stop
                $table = Get-AfsStudyTable ([string]$o.table)
                $store = Read-AfsStudyStore
                $rec = @{ id = ('L' + [guid]::NewGuid().ToString('N').Substring(0, 18)) }
                foreach ($p in $o.properties.PSObject.Properties) { $rec[$p.Name] = Get-AfsStudyValue $p.Value }
                $store[$table] = @(@($store[$table]) + @($rec))
                Save-AfsStudyStore $store
                Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; record = $rec }
            } catch {
                Send-AfsJson -Stream $stream -Status 400 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/study/db/update') {
            try {
                $o = $body | ConvertFrom-Json -ErrorAction Stop
                $table = Get-AfsStudyTable ([string]$o.table)
                $store = Read-AfsStudyStore
                $rows = @($store[$table])
                $hit = -1
                for ($i = 0; $i -lt $rows.Count; $i++) {
                    if ([string]$rows[$i]['id'] -eq [string]$o.recordId) { $hit = $i; break }
                }
                if ($hit -lt 0) { throw "记录不存在: $($o.recordId)" }
                $rec = $rows[$hit]
                foreach ($p in $o.properties.PSObject.Properties) { $rec[$p.Name] = Get-AfsStudyValue $p.Value }
                $rows[$hit] = $rec
                $store[$table] = $rows
                Save-AfsStudyStore $store
                Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; record = $rec }
            } catch {
                Send-AfsJson -Stream $stream -Status 400 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        if ($method -eq 'POST' -and $path -eq '/api/study/db/delete') {
            try {
                $o = $body | ConvertFrom-Json -ErrorAction Stop
                $table = Get-AfsStudyTable ([string]$o.table)
                $store = Read-AfsStudyStore
                $before = @($store[$table]).Count
                $store[$table] = @($store[$table] | Where-Object { [string]$_['id'] -ne [string]$o.recordId })
                Save-AfsStudyStore $store
                Send-AfsJson -Stream $stream -Status 200 -Obj @{ ok = $true; removed = ($before - @($store[$table]).Count) }
            } catch {
                Send-AfsJson -Stream $stream -Status 400 -Obj @{ ok = $false; error = $_.Exception.Message }
            }
            return
        }
        Send-AfsResponse -Stream $stream -Status 404 -Type 'text/plain; charset=utf-8' -Body '404 not found'
    } catch {
        try { Send-AfsResponse -Stream $stream -Status 500 -Type 'text/plain; charset=utf-8' -Body ("server error: " + $_.Exception.Message) } catch { }
    } finally {
        if ($client) { try { $client.Close() } catch { } }
    }
}

# ---------------- 主循环 ----------------

# 幂等启动: 端口被占用说明面板已在运行(如开机自启重复触发),直接退出,不绑定其它端口
$listener = $null
try {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()
} catch {
    Write-Output "AwayFromShorts 配置面板已在运行(端口 $Port 被占用),无需重复启动"
    exit 0
}

Write-Output "AwayFromShorts 配置面板已启动: http://127.0.0.1:$Port/  (Ctrl+C 停止)"

$script:AFS_LAST_SAMPLE = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$script:AFS_LAST_STUDY  = 0    # 0 = 启动后第一轮空闲就同步一次
while (-not $script:AFS_STOP) {
    $pending = $false
    try { $pending = $listener.Pending() } catch { }
    if ($pending) {
        try {
            $client = $listener.AcceptTcpClient()
            & $handler $client
        } catch {
            if ($script:AFS_STOP) { break }
        }
    } else {
        # 空闲轮询间隔: 越短请求延迟越低( worst case = 间隔时长 ), 150ms 下 CPU 占用仍可忽略
        Start-Sleep -Milliseconds 150
        # 活动时间采样: 每 60 秒记录一次前台窗口 (面板在交互会话, 可访问桌面)
        $nowSec = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if (($nowSec - $script:AFS_LAST_SAMPLE) -ge 60) {
            $script:AFS_LAST_SAMPLE = $nowSec
            try { Invoke-AfsActivitySample } catch { }
        }
        # 学习联动: 每 15 分钟把使用统计同步到云端 + 刷新今日打卡进度(study.flag)。
        # 独立进程跑, 不阻塞面板响应; 失败只影响数据新鲜度, 不影响屏蔽。
        if (($nowSec - $script:AFS_LAST_STUDY) -ge 900) {
            $script:AFS_LAST_STUDY = $nowSec
            try { Invoke-AfsStudySync | Out-Null } catch { }
        }
    }
}
$listener.Stop()
Write-Output "配置面板已停止"
