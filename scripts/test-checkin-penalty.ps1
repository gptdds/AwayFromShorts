# ============================================================
#  AwayFromShorts - test-checkin-penalty.ps1
#  20:00 打卡罚时(对齐手机端 CheckinPenalty)的离线回归。
#  纯时间推演: 用 -Now 造假时刻, 不碰真实配置 / 真实 hosts。
#  用法: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-checkin-penalty.ps1
# ============================================================
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\src\core.ps1')

$pass = 0; $fail = 0
function Check([bool]$cond, [string]$name) {
    if ($cond) { $script:pass++; Write-Output ("PASS  " + $name) }
    else { $script:fail++; Write-Output ("FAIL  " + $name) }
}

$today = (Get-Date).ToString('yyyy-MM-dd')
function At([string]$hm) { [datetime]::Parse((Get-Date).ToString('yyyy-MM-dd') + ' ' + $hm) }

$root = Join-Path $env:TEMP ('afs-penalty-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
    $cfgPath = Join-Path $root 'config.json'
    Set-AfsConfigPath -Path $cfgPath

    function Write-Cfg([object[]]$windows, [bool]$holdEnabled) {
        $cfg = @{
            version = 1; enabled = $true
            schedule = @{ days = @(1,2,3,4,5,6,7); windows = @($windows) }
            blockWebsites = $true; blockedSites = @(); blockedProcesses = @()
            whitelist = @{ sites = @(); processes = @() }
            override = @{ mode = 'none'; until = $null }
            force = @{ enabled = $false; until = $null; weekdays = @() }
            web = @{ port = 8737 }
            studyHold = @{ enabled = $holdEnabled }
            browser = @{ urlBlock = $false; targets = @('edge','chrome') }
        }
        $json = $cfg | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($cfgPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    }
    function Write-Flag([string]$allDone, [int]$pending, [string]$lastHitAt, [datetime]$mtime) {
        $flag = @{
            date = $today; allDone = [bool]$allDone; active = 2; pending = $pending
            pendingNames = @('A','B'); goals = @(); lastHitAt = $lastHitAt
            checkedAt = $today + ' 20:00'
        }
        $fp = Join-Path $root 'study.flag'
        [System.IO.File]::WriteAllText($fp, ($flag | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
        (Get-Item $fp).LastWriteTime = $mtime
        $fp
    }
    function Clear-Penalty { $pp = Join-Path $root 'checkin-penalty.json'; if (Test-Path $pp) { Remove-Item $pp -Force } }

    # 常规排法: 00:00-21:00 + 23:00-00:00 (放行点 21:00)
    $winA = @(@{ start = '00:00'; end = '21:00' }, @{ start = '23:00'; end = '00:00' })
    Write-Cfg $winA $true

    # --- 1. 20:00 前不入账 ---
    Clear-Penalty
    Write-Flag $false 2 '' (At '19:59') | Out-Null
    $cfg = Get-AfsConfig
    Check (-not (Invoke-AfsCheckinPenaltyTick -Config $cfg -Now (At '19:59'))) '19:59 不入账'
    Check (-not (Test-Path (Join-Path $root 'checkin-penalty.json'))) '19:59 没有状态文件'

    # --- 2. 20:00 有 pending -> 入账, until = 21:30 ---
    Write-Flag $false 2 '' (At '20:00') | Out-Null
    Check (Invoke-AfsCheckinPenaltyTick -Config $cfg -Now (At '20:00')) '20:00 有未完成 -> 入账'
    $pen = Read-AfsCheckinPenalty
    Check ($null -ne $pen -and $pen.until -eq ($today + ' 21:30')) ('入账 until=21:30 (实际 ' + $(if($pen){$pen.until}else{'null'}) + ')')
    Check ($pen.release -eq ($today + ' 21:00')) '入账 release=21:00'

    # --- 3. 幂等 + 入账后不撤销 (20:05 补打完也不撤) ---
    Write-Flag $true 0 '' (At '20:05') | Out-Null
    Check (-not (Invoke-AfsCheckinPenaltyTick -Config $cfg -Now (At '20:05'))) '20:05 已入账 -> 不再入账'
    $pen2 = Read-AfsCheckinPenalty
    Check ($pen2.until -eq ($today + ' 21:30')) '20:05 补打卡后 until 不变(不撤销)'

    # --- 4. 罚时段判定: [21:00,21:30) ---
    Check ((Get-AfsCheckinPenaltyActive -Config $cfg -Now (At '20:59')).active -eq $false) '20:59 罚时未生效'
    Check ((Get-AfsCheckinPenaltyActive -Config $cfg -Now (At '21:00')).active) '21:00 罚时生效'
    Check ((Get-AfsCheckinPenaltyActive -Config $cfg -Now (At '21:29')).active) '21:29 罚时生效'
    Check ((Get-AfsCheckinPenaltyActive -Config $cfg -Now (At '21:30')).active -eq $false) '21:30 罚时结束'

    # --- 5. Get-AfsActiveState 在罚时段优先返回 study-penalty ---
    $st = Get-AfsActiveState -Config $cfg -Now (At '21:10')
    Check ($st.active -and $st.reason -eq 'study-penalty') '21:10 Get-AfsActiveState -> study-penalty'

    # --- 6. 反绕过: allDone 但最后一笔在 20:00 之后 -> 仍入账 ---
    Clear-Penalty
    Write-Flag $true 0 ($today + ' 20:10') (At '20:15') | Out-Null
    Check (Invoke-AfsCheckinPenaltyTick -Config $cfg -Now (At '20:15')) '20:10 才补打卡 -> 仍入账(反绕过)'

    # --- 7. 按时完成: allDone 且最后一笔 20:00 前 -> 不入账 ---
    Clear-Penalty
    Write-Flag $true 0 ($today + ' 19:00') (At '20:15') | Out-Null
    Check (-not (Invoke-AfsCheckinPenaltyTick -Config $cfg -Now (At '20:15'))) '19:00 就打完 -> 不入账'

    # --- 8. fail-open: 没有 flag -> 不入账 ---
    Clear-Penalty
    $fp = Join-Path $root 'study.flag'; if (Test-Path $fp) { Remove-Item $fp -Force }
    Check (-not (Invoke-AfsCheckinPenaltyTick -Config $cfg -Now (At '20:15'))) '读不到进度 -> 不入账(fail-open)'

    # --- 9. 开关关闭 -> 不入账、不生效 ---
    Clear-Penalty
    Write-Cfg $winA $false
    $cfgOff = Get-AfsConfig
    Write-Flag $false 2 '' (At '20:15') | Out-Null
    Check (-not (Invoke-AfsCheckinPenaltyTick -Config $cfgOff -Now (At '20:15'))) '开关关闭 -> 不入账'
    Check ((Get-AfsCheckinPenaltyActive -Config $cfgOff -Now (At '21:10')).active -eq $false) '开关关闭 -> 罚时不生效'

    # --- 10. 只有跨午夜窗口(23:00-00:00) -> 今天没有放行点 -> 不延 ---
    Clear-Penalty
    Write-Cfg @(@{ start = '23:00'; end = '00:00' }) $true
    $cfgMid = Get-AfsConfig
    Write-Flag $false 2 '' (At '20:15') | Out-Null
    Check (-not (Invoke-AfsCheckinPenaltyTick -Config $cfgMid -Now (At '20:15'))) '跨午夜无今日放行点 -> 不延'

    # --- 11. 多窗口取最晚的今日结束点 ---
    Clear-Penalty
    Write-Cfg @(@{ start = '00:00'; end = '19:00' }, @{ start = '20:00'; end = '21:00' }) $true
    $cfgMulti = Get-AfsConfig
    Write-Flag $false 2 '' (At '20:15') | Out-Null
    Check (Invoke-AfsCheckinPenaltyTick -Config $cfgMulti -Now (At '20:15')) '多窗口 -> 入账'
    $penM = Read-AfsCheckinPenalty
    Check ($penM.until -eq ($today + ' 21:30')) '多窗口取最晚结束点 21:00 -> until 21:30'

    # --- 12. lastHitAt 透传 ---
    Write-Flag $true 0 ($today + ' 20:10') (At '20:15') | Out-Null
    $info = Get-AfsStudyInfo -Now (At '20:15')
    Check ($info.ok -and $info.lastHitAt -eq ($today + ' 20:10')) 'Get-AfsStudyInfo 透传 lastHitAt'
}
finally {
    try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

Write-Output ''
Write-Output ("RESULT: {0} PASS / {1} FAIL" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
exit 0
