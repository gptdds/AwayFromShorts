# close-browser-windows.ps1
# 由 AwayFromShorts-BrowserClose 计划任务在"用户交互会话"中调用
# (S4U 计划任务不能操作桌面窗口, 必须经由 /IT 交互任务执行)。
#
# 读取 browser-close.json 载荷:
#   patterns   - 窗口标题匹配(支持 * 通配符), 匹配的窗口被强制关闭(工作区屏蔽)
#   targets    - 生效浏览器: edge -> msedge, chrome -> chrome
#   restartAll - 关闭所有浏览器窗口后重新打开(URLBlocklist 策略变更后重启使策略生效)
#               ★ 策略只在浏览器启动时读一次, 所以 restartAll 走"全进程重启":
#                 结束该浏览器所有进程(含 Edge 启动增强/后台常驻的无窗口进程)再拉起,
#                 否则进程没死 = 策略永远不生效。
# 注意: 只按 patterns 关闭(用户配置的工作区窗口), 不做"标题含站点名"兜底, 避免误关工作窗口。
# 强制结束进程(不等待优雅关闭): 页面 onbeforeunload 弹"确认离开?"会卡住 CloseMainWindow;
# Chromium 多个窗口可能共享主进程, 按 PID 强杀可能连带关闭同进程的其他窗口。
# 显式浏览器进程黑名单每 500ms 检查; 窗口标题规则每 3 秒检查。
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
    $active = [bool](Get-AfsActiveState -Config $cfg).active
    $names = @(Get-AfsProcessKillList -Config $cfg | Where-Object { $_ -in @('chrome','msedge') })
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
    @{ active = $active; monitoring = ($names.Count -gt 0); killed = $killed; errors = $errors }
}

# Win32 顶层窗口枚举 (不依赖 Get-Process.MainWindowTitle —— 它对 Chromium 多进程窗口经常返回空)
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class AfsWin {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder s, int nMax);
    [DllImport("user32.dll")] public static extern int GetWindowTextLengthW(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
}
'@

# 枚举当前交互会话所有可见顶层窗口, 返回 (PID, Title) 列表
function Get-AfsVisibleWindows {
    $list = New-Object System.Collections.ArrayList
    $cb = [AfsWin+EnumProc]{
        param($h, $l)
        try {
            if ([AfsWin]::IsWindowVisible($h)) {
                $len = [AfsWin]::GetWindowTextLengthW($h)
                if ($len -gt 0) {
                    $sb = New-Object System.Text.StringBuilder ($len + 1)
                    [void][AfsWin]::GetWindowTextW($h, $sb, $sb.Capacity)
                    [uint32]$windowProcessId = 0
                    [void][AfsWin]::GetWindowThreadProcessId($h, [ref]$windowProcessId)
                    [void]$list.Add(@{ Pid = [int]$windowProcessId; Title = $sb.ToString() })
                }
            }
        } catch { }
        return $true
    }
    [void][AfsWin]::EnumWindows($cb, [IntPtr]::Zero)
    return $list
}

function Invoke-AfsCloseRound {
    $log = @{
        time     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        seen     = @()
        matched  = @()
        closed   = @()
        reopened = 0
        error    = ''
    }
    $restartAll = $false
    try {
        if (-not (Test-Path $payloadPath)) {
            return @{ closed = 0; reopened = 0; restartAll = $false; empty = $true }
        }
        $p = ConvertFrom-Json ([System.IO.File]::ReadAllText($payloadPath, [System.Text.Encoding]::UTF8))
        $patterns   = @($p.patterns)
        $targets    = @($p.targets)
        $restartAll = [bool]$p.restartAll
        $names = @($targets | ForEach-Object { if ($_ -eq 'edge') { 'msedge' } else { 'chrome' } } | Select-Object -Unique)
        if ($names.Count -eq 0) { $names = @('msedge', 'chrome') }

        # PID -> 进程名 映射 (一次查询, 供窗口反查)
        $pidName = @{}
        foreach ($n in $names) {
            foreach ($pr in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
                $pidName[[int]$pr.Id] = $n
            }
        }

        $hadWindow = @()
        foreach ($n in $names) {
            if ($pidName.ContainsValue($n)) { $hadWindow += $n }
        }

        # 双数据源取并集: 两种窗口标题读取方式各有失效场景, 互相兜底
        #   1) EnumWindows: 覆盖 Chromium 多进程(主进程 MainWindowTitle 常空) —— 但计划任务窗口站隔离时枚举不到
        #   2) Get-Process.MainWindowTitle: 读进程对象不依赖窗口站 —— 但 Chromium 主进程标题可能为空
        # 用 PID 去重, 保证同一窗口只处理一次。
        $candidates = @{}   # PID -> 标题

        # 数据源 1: EnumWindows 枚举可见顶层窗口
        foreach ($w in @(Get-AfsVisibleWindows)) {
            if ($pidName.ContainsKey($w.Pid)) {
                $key = [string]$w.Pid
                if (-not $candidates.ContainsKey($key) -or $candidates[$key] -eq '') {
                    $candidates[$key] = [string]$w.Title
                }
            }
        }
        # 数据源 2: Get-Process.MainWindowTitle (跨窗口站, 读进程对象)
        foreach ($n in $names) {
            foreach ($pr in @(Get-Process -Name $n -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle })) {
                $key = [string]$pr.Id
                if (-not $candidates.ContainsKey($key) -or $candidates[$key] -eq '') {
                    $candidates[$key] = [string]$pr.MainWindowTitle
                }
            }
        }

        $closedBy = @{}    # 浏览器名 -> 关掉的窗口数(重开时按这个数恢复)
        foreach ($pidKey in $candidates.Keys) {
            $title = [string]$candidates[$pidKey]
            $wn = $pidName[[int]$pidKey]
            if (-not $wn) { continue }
            $log.seen += "$wn($pidKey) [$title]"
            $match = $restartAll
            if (-not $match) {
                foreach ($pat in $patterns) { if ($title -like $pat) { $match = $true; break } }
            }
            if ($match) {
                $log.matched += "$wn($pidKey) [$title]"
                try {
                    Stop-Process -Id ([int]$pidKey) -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 400
                    if (-not (Get-Process -Id ([int]$pidKey) -ErrorAction SilentlyContinue)) {
                        $log.closed += "$wn($pidKey) [$title] (强制)"
                        $closedBy[$wn] = [int]$closedBy[$wn] + 1
                    }
                } catch { }
            }
        }

        if ($restartAll) {
            # ★ 这里是「一次性重启」：串行做四件事，顺序不能换。
            #   1) 先删 payload —— 计划任务每分钟都会拉新实例，留着它下一个实例会再杀一遍，
            #      外面看到的就是"浏览器被开关好几次"。
            #   2) 记时间戳 —— core.ps1 读它做去抖，8 分钟内不再重启第二次。
            #   3) 全进程清场 —— 让新进程重新读取注册表里的 URLBlocklist 策略(见下)。
            #   4) 按被关掉的窗口数恢复 —— 原来固定只开一个空白窗口，三个窗口的用户回来只剩一个。
            $want = @($log.closed).Count
            try { if (Test-Path $payloadPath) { Remove-Item $payloadPath -Force -ErrorAction SilentlyContinue } } catch { }
            try { if (Test-Path (Join-Path $dir 'browser-restart.pending.json')) { Remove-Item (Join-Path $dir 'browser-restart.pending.json') -Force -ErrorAction SilentlyContinue } } catch { }
            try {
                $rs = @{ lastRestart = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); closed = $want }
                [System.IO.File]::WriteAllText((Join-Path $dir 'browser-restart.json'),
                    (ConvertTo-Json $rs), (New-Object System.Text.UTF8Encoding($false)))
            } catch { }
            # ★ 全进程清场 (2026-10-25 修): URLBlocklist 只在浏览器**启动**时读一次。
            #   上面那一轮只 Stop-Process 了"有窗口"的进程, 而 Edge 的「启动增强 / 关闭后继续运行后台扩展」
            #   会让一批无窗口进程常驻 —— 它们活着, 浏览器就没有真正重启, 新写的策略永远不生效。
            #   实测: 策略 10-24 23:00 就写进注册表了, 10-25 早上照样能打开 live.bilibili.com / search.bilibili.com。
            #   所以这里把目标浏览器的**所有**进程(含后台/常驻)全部结束, 再由下面的窗口恢复逻辑重新拉起。
            $fullKilled = New-Object System.Collections.Generic.List[string]
            foreach ($n in $names) {
                foreach ($pr in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
                    try {
                        Stop-Process -Id $pr.Id -Force -ErrorAction Stop
                        $fullKilled.Add("$n($($pr.Id))")
                    } catch { }
                }
            }
            $log.fullKilled = @($fullKilled | Select-Object -Unique)
            # 等进程退出 + 端口/单实例锁释放; 启动增强若自我复活, 下面的 need 差额会把它算进去
            Start-Sleep -Seconds 3
            $opened = 0
            foreach ($nm in @($closedBy.Keys)) {
                # 等这 2 秒的意义：浏览器可能已经自己把上次会话恢复了，那就只补差额，
                # 否则「恢复会话」+「按数补窗」= 两倍窗口。
                $now = @(Get-Process -Name $nm -ErrorAction SilentlyContinue |
                    Where-Object { $_.MainWindowTitle }).Count
                $need = [int]$closedBy[$nm] - $now
                if ($need -gt 8) { $need = 8 }     # 上限：一次开二十个窗口等于把桌面炸了
                for ($i = 0; $i -lt $need; $i++) {
                    try { Start-Process -FilePath $nm -ArgumentList '--new-window'; $opened++ } catch { }
                }
            }
            $log.reopened = $opened
        }
    } catch {
        $log.error = $_.Exception.Message
    }
    try {
        [System.IO.File]::WriteAllText($logPath, (ConvertTo-Json $log), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    return @{ closed = @($log.closed).Count; reopened = [int]$log.reopened; restartAll = [bool]$restartAll }
}

# 进程黑名单走 500ms 快速通道, 窗口标题扫描保持 3 秒。
# 任务 MultipleInstancesPolicy=IgnoreNew: 引擎每分钟触发, 常驻实例不被重复拉起。
# 未配置浏览器进程黑名单且无窗口载荷时退出。
$heartbeatPath = Join-Path $dir 'browser-close.heartbeat'
$emptyRounds = 0
$windowClock = [System.Diagnostics.Stopwatch]::StartNew()
$nextWindowScan = 0
while ($true) {
    # 全局兜底: 单轮任何未捕获异常都不中断常驻循环, 避免"进程静默死亡导致屏蔽失效"
    $round = $null
    $processRound = $null
    try {
        $processRound = Invoke-AfsBrowserProcessBlock
        if (@($processRound.killed).Count -gt 0 -or @($processRound.errors).Count -gt 0) {
            $event = @{ time = (Get-Date).ToString('o'); killed = @($processRound.killed); errors = @($processRound.errors) }
            [System.IO.File]::WriteAllText((Join-Path $dir 'browser-process.log'), (ConvertTo-Json $event), (New-Object System.Text.UTF8Encoding($false)))
        }
        if ($processRound.active -and $windowClock.ElapsedMilliseconds -ge $nextWindowScan) {
            $round = Invoke-AfsCloseRound
            $nextWindowScan = $windowClock.ElapsedMilliseconds + 3000
        }
    } catch {
        try {
            $hb = @{ time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); error = $_.Exception.Message }
            [System.IO.File]::WriteAllText($heartbeatPath, (ConvertTo-Json $hb), (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
    }
    # restartAll 是一次性动作：这一轮开完窗口就结束，绝不再循环一轮把它关掉。
    if ($round -and $round.restartAll) { break }
    $stillActive = $false
    if (Test-Path $payloadPath) {
        try {
            $pp = ConvertFrom-Json ([System.IO.File]::ReadAllText($payloadPath, [System.Text.Encoding]::UTF8))
            if (@($pp.patterns).Count -gt 0 -or [bool]$pp.restartAll) { $stillActive = $true }
        } catch { }
    }
    # 有进程黑名单时跨解锁时段常驻, 下次屏蔽开始无需等分钟任务拉起。
    if (-not $stillActive -and $processRound -and -not $processRound.monitoring) { break }
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
