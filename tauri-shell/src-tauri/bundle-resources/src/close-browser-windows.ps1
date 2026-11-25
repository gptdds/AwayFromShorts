# close-browser-windows.ps1
# 由 AwayFromShorts-BrowserClose 计划任务在"用户交互会话"中调用
# (S4U 计划任务不能操作桌面窗口, 必须经由 /IT 交互任务执行)。
#
# 只做两件事:
#   1) 快速通道: 冻结期间结束 blockedProcesses 里的 chrome/msedge
#   2) URLBlocklist 策略变更后重启目标浏览器, 让新策略生效
# 不再按窗口标题 / Edge 工作区名关闭任何窗口。
param()
$ErrorActionPreference = 'Continue'

$dir  = Split-Path $MyInvocation.MyCommand.Path
$payloadPath = Join-Path $dir 'browser-close.json'
$logPath     = Join-Path $dir 'browser-close.log'
. (Join-Path $dir 'core.ps1')

# 直接读取当前配置和生效状态, 不依赖每分钟刷新的 payload。
# 因而临时解除、时段结束、进程白名单改动均在下一轮生效。
function Invoke-AfsBrowserProcessBlock {
    $cfg = Get-AfsConfig
    $state = Get-AfsActiveState -Config $cfg
    $active = [bool]$state.active
    $names = @(Get-AfsProcessKillList -Config $cfg -State $state | Where-Object { $_ -in @('chrome','msedge') })
    $monitorNames = @(Get-AfsWindowProcessUnion -Config $cfg | Where-Object { $_ -in @('chrome','msedge') })
    $killed = @()
    $errors = @()
    if ($active) {
        foreach ($name in $names) {
            foreach ($proc in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
                try {
                    Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                    $killed += "$name($($proc.Id))"
                } catch {
                    # Chromium 子进程可能随主进程退出; 已退出不算拦截失败。
                    if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) { $errors += $_.Exception.Message }
                }
            }
        }
    }
    @{ active = $active; monitoring = ($monitorNames.Count -gt 0); killed = $killed; errors = $errors }
}

# 读取 browser-close.json: { targets, restartAll }
# 旧版载荷里的 patterns 一律忽略, 不复现"按标题关窗口"的行为。
function Invoke-AfsBrowserReloadRound {
    $log = @{
        time     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        targets  = @()
        closed   = @()
        reopened = 0
        error    = ''
    }
    $restartAll = $false
    try {
        if (-not (Test-Path -LiteralPath $payloadPath)) {
            return @{ closed = 0; reopened = 0; restartAll = $false; empty = $true }
        }
        $p = ConvertFrom-Json ([System.IO.File]::ReadAllText($payloadPath, [System.Text.Encoding]::UTF8))
        $restartAll = [bool]$p.restartAll
        if (-not $restartAll) {
            # 旧版窗口屏蔽载荷: 直接丢弃, 不关闭任何窗口。
            Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
            return @{ closed = 0; reopened = 0; restartAll = $false; empty = $true }
        }

        $targets = @($p.targets | ForEach-Object { ([string]$_).Trim().ToLower() } |
            Where-Object { $_ -in @('edge','chrome') } | Select-Object -Unique)
        if ($targets.Count -eq 0) { $targets = @('edge', 'chrome') }
        $names = @($targets | ForEach-Object { if ($_ -eq 'edge') { 'msedge' } else { 'chrome' } } | Select-Object -Unique)
        $log.targets = @($names)

        # 记录重启前各浏览器有多少个可见窗口, 重启后按数量恢复。
        $windowCounts = @{}
        foreach ($n in $names) {
            $count = @(Get-Process -Name $n -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowTitle }).Count
            if ($count -gt 0) { $windowCounts[$n] = $count }
        }

        # 先删 payload: 计划任务每分钟都会拉新实例, 留着它会被重复执行。
        try { if (Test-Path -LiteralPath $payloadPath) { Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue } } catch { }
        try {
            $pending = Join-Path $dir 'browser-restart.pending.json'
            if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue }
        } catch { }

        try {
            $rs = @{ lastRestart = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
            [System.IO.File]::WriteAllText((Join-Path $dir 'browser-restart.json'),
                (ConvertTo-Json $rs), (New-Object System.Text.UTF8Encoding($false)))
        } catch { }

        # ★ 全进程清场: URLBlocklist 只在浏览器启动时读一次。
        #   Edge 的「启动增强 / 关闭后继续运行后台扩展」会让无窗口进程常驻,
        #   必须把目标浏览器的所有进程都结束, 否则新策略不会生效。
        $fullKilled = New-Object System.Collections.Generic.List[string]
        foreach ($n in $names) {
            foreach ($pr in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
                try {
                    Stop-Process -Id $pr.Id -Force -ErrorAction Stop
                    $fullKilled.Add("$n($($pr.Id))")
                } catch { }
            }
        }
        $log.closed = @($fullKilled | Select-Object -Unique)
        # 等进程退出 + 端口/单实例锁释放; 启动增强若自我复活, 下面的差额会把它算进去。
        Start-Sleep -Seconds 3
        $opened = 0
        foreach ($nm in @($windowCounts.Keys)) {
            $now = @(Get-Process -Name $nm -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowTitle }).Count
            $need = [int]$windowCounts[$nm] - $now
            if ($need -gt 8) { $need = 8 }
            for ($i = 0; $i -lt $need; $i++) {
                try { Start-Process -FilePath $nm -ArgumentList '--new-window'; $opened++ } catch { }
            }
        }
        $log.reopened = $opened
    } catch {
        $log.error = $_.Exception.Message
    }
    try {
        [System.IO.File]::WriteAllText($logPath, (ConvertTo-Json $log), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    return @{ closed = @($log.closed).Count; reopened = [int]$log.reopened; restartAll = [bool]$restartAll }
}

# 进程黑名单走 500ms 快速通道; 重启请求是一次性动作。
# 任务 MultipleInstancesPolicy=IgnoreNew: 引擎每分钟触发, 常驻实例不被重复拉起。
$heartbeatPath = Join-Path $dir 'browser-close.heartbeat'
$emptyRounds = 0
while ($true) {
    $processRound = $null
    $reloadRound = $null
    try {
        $processRound = Invoke-AfsBrowserProcessBlock
        if (@($processRound.killed).Count -gt 0 -or @($processRound.errors).Count -gt 0) {
            $event = @{ time = (Get-Date).ToString('o'); killed = @($processRound.killed); errors = @($processRound.errors) }
            [System.IO.File]::WriteAllText((Join-Path $dir 'browser-process.log'), (ConvertTo-Json $event), (New-Object System.Text.UTF8Encoding($false)))
        }
        $reloadRound = Invoke-AfsBrowserReloadRound
    } catch {
        try {
            $hb = @{ time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); error = $_.Exception.Message }
            [System.IO.File]::WriteAllText($heartbeatPath, (ConvertTo-Json $hb), (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
    }
    # 重启已完成: 这一轮结束, 绝不再循环一轮把它关掉。
    if ($reloadRound -and $reloadRound.restartAll) { break }
    # 有进程黑名单时跨解锁时段常驻, 下次屏蔽开始无需等分钟任务拉起。
    if (-not (Test-Path -LiteralPath $payloadPath) -and $processRound -and -not $processRound.monitoring) { break }
    # 心跳: 每次正常循环刷新时间戳, 便于诊断"进程是否存活"
    if ($emptyRounds % 10 -eq 0) {
        try {
            $hb = @{ time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); alive = $true }
            [System.IO.File]::WriteAllText($heartbeatPath, (ConvertTo-Json $hb), (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
    }
    $emptyRounds++
    Start-Sleep -Milliseconds 500
}
