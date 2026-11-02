# 学习闸门 -> Gist 推送
# 把 study.flag + config.studyHold 打包成 study-gate.json, 更新到账号的同步 Gist。
# 手机端(AwayFromShorts-Phone dpc)用 secret gist 的 raw URL 免鉴权拉取。
#
# 由 study_sync.py 每 15 分钟调一次(面板空闲循环); 失败只写日志, 不影响屏蔽。
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File push_gist.ps1

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $here 'study-gist.log'
$stPath = Join-Path $here 'study-gist-state.json'

# quota-ledger 需要 core.ps1 里的 Read-AfsJson / Write-AfsJson。core.ps1 只定义函数,
# 加载它没有副作用（game-quota.ps1 也是这么用的）。
. (Join-Path $here 'core.ps1')
. (Join-Path $here 'quota-ledger.ps1')

# 连续失败计数: 面板读这个文件亮角标。成功一次就清零。
function Read-GateState {
    try {
        if (Test-Path $stPath) {
            $o = ConvertFrom-Json ([System.IO.File]::ReadAllText($stPath, [System.Text.Encoding]::UTF8))
            return @{ fails = [int]$o.fails; lastOk = [string]$o.lastOk
                      lastFail = [string]$o.lastFail; error = [string]$o.error }
        }
    } catch { }
    @{ fails = 0; lastOk = ''; lastFail = ''; error = '' }
}

function Write-GateState {
    param($s)
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($stPath, (ConvertTo-Json $s -Compress), $utf8)
    } catch { }
}

function Write-Log {
    param([string]$Level, [string]$Msg)
    $line = '{0}  {1,-4} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Msg
    Add-Content -Path $log -Value $line -Encoding UTF8
    # 日志只留最后 200 行
    try {
        $lines = [System.IO.File]::ReadAllLines($log)
        if ($lines.Count -gt 200) {
            [System.IO.File]::WriteAllLines($log, $lines[-200..-1])
        }
    } catch { }
}

try {
    # ---------- 1. 读数据 ----------
    $cfgPath  = Join-Path $here 'config.json'
    $flagPath = Join-Path $here 'study.flag'
    $syncPath = Join-Path $here 'sync-state.json'
    $tokPath  = Join-Path $here 'github-token.enc'

    $cfg = ConvertFrom-Json ([System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8))
    $sh  = $cfg.studyHold
    if (-not $sh) { throw 'config.json 里没有 studyHold' }

    # study.flag 可能刚被 check_study.py 重写; 读失败按 fail-open 处理
    $flag = $null
    try {
        $flag = ConvertFrom-Json ([System.IO.File]::ReadAllText($flagPath, [System.Text.Encoding]::UTF8))
    } catch { }

    $sync = ConvertFrom-Json ([System.IO.File]::ReadAllText($syncPath, [System.Text.Encoding]::UTF8))
    if (-not $sync.gistId) { throw 'sync-state.json 里没有 gistId (先在面板里登录一次账号/同步)' }

    # ---------- 2. 解 DPAPI token ----------
    if (-not (Test-Path $tokPath)) { throw 'github-token.enc 不存在 (未登录)' }
    . (Join-Path $here 'token.ps1')
    $token = Get-AfsGithubTokenText -Path $tokPath
    if (-not $token) { throw 'token 解密为空' }

    # ---------- 3. 组 study-gate.json (手机端解析; 全 ASCII, 不存在编码坑) ----------
    # 手机打卡 App 要"选一个目标打"，光有 pending 数字没法选，所以把目标明细也推上去。
    # 注意 -Depth：ConvertTo-Json 默认只展开 2 层，goals 里每个对象的字段会被压成字符串。
    $goalList = @()
    if ($flag -and $flag.goals) {
        foreach ($g in $flag.goals) {
            $goalList += [ordered]@{
                id       = [string]$g.id
                name     = [string]$g.name
                unit     = [string]$g.unit
                total    = [double]$g.total
                done     = [double]$g.done
                todayHit = [bool]$g.todayHit
                suggest  = [double]$g.suggest
            }
        }
    }

    # 队列里还有多少条没被 PC 记账（手机写完还没回补）。
    # 手机上显示"待记账 N 条"，也用来提示同步是否卡住。
    $queueN = 0
    $qPath = Join-Path $here 'checkin-queue.local.json'
    if (Test-Path $qPath) {
        try {
            $q = ConvertFrom-Json ([System.IO.File]::ReadAllText($qPath, [System.Text.Encoding]::UTF8))
            if ($q.items) { $queueN = @($q.items).Count }
        } catch { }
    }

    $gate = [ordered]@{
        date      = if ($flag) { [string]$flag.date } else { (Get-Date -Format 'yyyy-MM-dd') }
        enabled   = [bool]$sh.enabled
        allDone   = if ($flag) { [bool]$flag.allDone } else { $true }
        pending   = if ($flag) { [int]$flag.pending } else { 0 }
        checkedAt = if ($flag) { [string]$flag.checkedAt } else { '' }
        goals     = $goalList
        queue     = $queueN
    }
    $json = $gate | ConvertTo-Json -Compress -Depth 6

    # ---------- 3.5 组 pc-activity.json（手机统计页用的电脑端应用时长） ----------
    # activity.json 是面板每 60 秒采样聚合的（core.ps1 唯一写入方）。
    # 日排行保留近 14 天前 12 个；本月与累计从完整应用记录汇总，避免排行截断漏算。
    $files = @{ 'study-gate.json' = @{ content = $json } }
    try {
        $actPath = Join-Path $here 'activity.json'
        if (Test-Path $actPath) {
            $act = ConvertFrom-Json ([System.IO.File]::ReadAllText($actPath, [System.Text.Encoding]::UTF8))
            . (Join-Path $here 'activity-summary.ps1')
            $historyPath = Join-Path $here 'pc-activity-history.json'
            $history = $null
            if (Test-Path $historyPath) {
                $history = ConvertFrom-Json ([System.IO.File]::ReadAllText($historyPath, [System.Text.Encoding]::UTF8))
            }
            $summary = Get-AfsPcActivitySummary -Activity $act -History $history
            if ($summary.payload.days.Count -gt 0) {
                $historyTemp = $historyPath + '.tmp'
                [System.IO.File]::WriteAllText($historyTemp, ($summary.history | ConvertTo-Json -Compress -Depth 8),
                    (New-Object System.Text.UTF8Encoding($false)))
                Move-Item -LiteralPath $historyTemp -Destination $historyPath -Force
                $pcj = $summary.payload
                $files['pc-activity.json'] = @{
                    content = ($pcj | ConvertTo-Json -Compress -Depth 6)
                }
            }
        }
    } catch {
        Write-Log 'WARN' ('ACTIVITY_SLICE_FAIL ' + $_.Exception.Message)
    }

    # ---------- 3.6 组 quota-pool.json（局域网连不上时手机端的兜底） ----------
    # 局域网是主通道（3 秒）；Gist 只是手机不在家、或电脑那边服务没起来时的退路。
    # 延迟最大 15 分钟，所以手机端拿它判超是偏乐观的 —— 但比「完全各自记账」强,
    # 至少能看到电脑那边已经用掉多少。
    try {
        $lanCfg = Get-AfsQuotaLanConfig $here
        if ($lanCfg.enabled) {
            $view = Get-AfsQuotaPoolView -DataDir $here -Now (Get-Date)
            $pool = [ordered]@{
                date      = [string]$view.date
                minutes   = [int]$view.poolMinutes
                pcUsed    = [Math]::Round([double]$view.pcUsed, 1)
                phoneUsed = [Math]::Round([double]$view.phoneUsed, 1)
                total     = [Math]::Round([double]$view.total, 1)
                remaining = [Math]::Round([double]$view.remaining, 1)
                exhausted = [bool]$view.exhausted
                updated   = (Get-Date -Format 'o')
            }
            $files['quota-pool.json'] = @{ content = ($pool | ConvertTo-Json -Compress -Depth 4) }
        }
    } catch {
        Write-Log 'WARN' ('QUOTA_SLICE_FAIL ' + $_.Exception.Message)
    }

    # ---------- 4. PATCH Gist ----------
    try {
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    } catch { }

    $filesJson = ($files.GetEnumerator() | ForEach-Object {
        '"' + $_.Key + '":{"content":' + ($_.Value.content | ConvertTo-Json) + '}'
    }) -join ','
    $body = '{"files":{' + $filesJson + '}}'
    # ★ 必须发 byte[]：PowerShell 5.1 的 Invoke-RestMethod 把 string body 按 Latin-1
    #   编码发出去，中文会全变成 "?"（目标的 name/unit 就是这么丢过一次）。
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $headers = @{
        'Authorization' = ('token ' + $token)
        'User-Agent'    = 'AwayFromShorts-PC'
        'Accept'        = 'application/vnd.github+json'
    }
    $resp = Invoke-RestMethod -Method Patch -Uri ('https://api.github.com/gists/' + $sync.gistId) `
        -Headers $headers -Body $bodyBytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 25

    Write-Log 'ok' ('PUSH_GIST_OK ' + $json)
    # 成功就清零: 面板上的失败角标随之消失
    $okState = Read-GateState
    $okState.fails = 0
    $okState.lastOk = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    $okState.error = ''
    Write-GateState -s $okState
    # study_sync.py 以 stdout 判成败: 成功也必须回一行, 否则被当 "no output" 记 FAIL
    Write-Output ('PUSH_GIST_OK ' + $json)
    exit 0
}
catch {
    # 连续失败计数 +1: 面板读这个文件, 连续 2 次(约 30 分钟推不上去)就亮角标
    $st = Read-GateState
    $st.fails = [int]$st.fails + 1
    $st.lastFail = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $st.error = [string]$_.Exception.Message
    Write-GateState -s $st
    Write-Log 'FAIL' ('PUSH_GIST_FAIL x' + $st.fails + ' ' + $_.Exception.Message)
    Write-Output ('PUSH_GIST_FAIL ' + $_.Exception.Message)
    exit 1
}
