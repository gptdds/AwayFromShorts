# hub-config.json —— Gist 中心仓库的配置分节同步（PC 侧）
#
# 中心仓库格局（用户决策 2026-10-23）：
#   - 配置以 hub 为唯一权威、双向同步；但 PC 和手机各占一个分节，互不套用
#       hub-config.json = { rev, updated,
#                           pc:    { updated, writtenBy, hash, config:{...} },
#                           phone: { updated, writtenBy, hash, config:{...} } }
#   - 每端只写自己的分节（读-改-写保留对方节），方向靠 hash 对比：
#       hubHash == localHash            -> 两边一致
#       hubHash == last && local != last -> 本地新 -> 推
#       localHash == last && hub != last -> hub 新 -> 拉(应用)
#       都变了                            -> 本地赢（用户刚改的是最新意图）
#   - 应用使用统计: pc-activity.json(PC写) / phone-activity.json(手机写)，hub 只聚合
#   - 打卡统计: checkin-ledger.json（PC 从云台账快照），两端只读
#
# 调用：push_gist.ps1 每 15 分钟带一次；webui 改配置后由 Set-AfsConfigSafe
# 的钩子以 -PushOnly 立即推（内部 120 秒节流）。失败只写日志不影响屏蔽。
#
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File hub_config.ps1 [-PushOnly]

param([switch]$PushOnly, [switch]$LibraryOnly)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $here 'hub-config.log'
$statePath = Join-Path $here 'hub-state.json'
$cachePhoneAct = Join-Path $here 'phone-activity.cache.json'

# This script also runs as an independent hidden process. Read the version
# cheaply and load the shared contract without assuming webui.ps1 is the caller.
$corePath = Join-Path $here 'core.ps1'
if (Test-Path -LiteralPath $corePath) {
    $versionMatch = [regex]::Match(
        [System.IO.File]::ReadAllText($corePath, [System.Text.Encoding]::UTF8),
        "\`$script:AFS_VERSION\s*=\s*'([^']+)'")
    if ($versionMatch.Success) { $script:AFS_VERSION = $versionMatch.Groups[1].Value }
}
. (Join-Path $here 'cross-contract.ps1')

function Write-Log {
    param([string]$Level, [string]$Msg)
    try {
        $line = '{0}  {1,-4} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Msg
        Add-Content -Path $log -Value $line -Encoding UTF8
        $lines = [System.IO.File]::ReadAllLines($log)
        if ($lines.Count -gt 200) {
            [System.IO.File]::WriteAllLines($log, $lines[-200..-1])
        }
    } catch { }
}

function Read-State {
    try {
        if (Test-Path $statePath) {
            $o = ConvertFrom-Json ([System.IO.File]::ReadAllText($statePath, [System.Text.Encoding]::UTF8))
            return @{
                lastHash = [string]$o.lastHash
                lastPush = [string]$o.lastPush
                lastContractHash = [string]$o.lastContractHash
            }
        }
    } catch { }
    return @{ lastHash = ''; lastPush = ''; lastContractHash = '' }
}

function Write-State {
    param([string]$lastHash, [string]$lastPush, [string]$lastContractHash = '')
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($statePath,
            (ConvertTo-Json @{
                lastHash = $lastHash
                lastPush = $lastPush
                lastContractHash = $lastContractHash
            } -Compress), $utf8)
    } catch { }
}

# 语义 hash：走"解析->再序列化"的同一条路，同数据必同 hash（直接 hash 文件字节
# 会被 Set-AfsConfigSafe 的格式化抖动骗出假差异）
function Get-CfgHash {
    param($Obj)
    $m = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Obj | ConvertTo-Json -Compress -Depth 12))
        ([System.BitConverter]::ToString($m.ComputeHash($bytes))).Replace('-', '').ToLower()
    } finally { $m.Dispose() }
}

function Get-AfsHubSectionProperty {
    param($Hub, [string]$Name)
    if ($null -eq $Hub) { return $null }
    $p = $Hub.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-AfsHubContractHash {
    param($Hub, [string]$SectionName)
    $section = Get-AfsHubSectionProperty -Hub $Hub -Name $SectionName
    if ($null -eq $section -or $null -eq $section.contract) { return '' }
    return [string]$section.contract.contractHash
}

# Replace only this device's known envelope fields. Unknown fields in the hub
# and section are copied first, so an older device cannot delete metadata added
# by a newer peer during a read-modify-write.
function Merge-AfsHubDeviceSection {
    param(
        $Hub,
        [ValidateSet('pc','phone')][string]$SectionName,
        $Config,
        $Contract,
        [string]$ConfigHash
    )
    if ($null -eq $Hub) { $Hub = [pscustomobject]@{} }
    $section = [ordered]@{}
    $current = Get-AfsHubSectionProperty -Hub $Hub -Name $SectionName
    if ($null -ne $current) {
        foreach ($p in @($current.PSObject.Properties)) {
            $section[[string]$p.Name] = $p.Value
        }
    }
    $section.updated = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $section.writtenBy = $SectionName
    $section.hash = $ConfigHash
    if ($null -ne $Config) { $section.config = $Config }
    if ($null -ne $Contract) { $section.contract = $Contract }
    $Hub | Add-Member -NotePropertyName $SectionName `
        -NotePropertyValue ([pscustomobject]$section) -Force
    return $Hub
}

if ($LibraryOnly) { return }

try {
    $cfgPath = Join-Path $here 'config.json'
    $tokPath = Join-Path $here 'github-token.enc'
    $syncPath = Join-Path $here 'sync-state.json'
    if (-not (Test-Path $cfgPath))  { throw 'config.json 不存在' }
    if (-not (Test-Path $syncPath)) { throw 'sync-state.json 不存在（未登录同步）' }

    $sync = ConvertFrom-Json ([System.IO.File]::ReadAllText($syncPath, [System.Text.Encoding]::UTF8))
    if (-not $sync.gistId) { throw 'sync-state.json 里没有 gistId' }

    # ---------- token（DPAPI，与 push_gist.ps1 同一份） ----------
    if (-not (Test-Path $tokPath)) { throw 'github-token.enc 不存在（未登录）' }
    . (Join-Path $here 'token.ps1')
    $token = Get-AfsGithubTokenText -Path $tokPath
    if (-not $token) { throw 'token 解密为空' }

    try {
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    } catch { }

    $headers = @{
        'Authorization' = ('token ' + $token)
        'User-Agent'    = 'AwayFromShorts-PC'
        'Accept'        = 'application/vnd.github+json'
    }

    # ---------- 1. GET 整个 hub-config.json ----------
    $gist = Invoke-RestMethod -Method Get -Uri ('https://api.github.com/gists/' + $sync.gistId) `
        -Headers $headers -TimeoutSec 25
    $hubRaw = $null
    $f = $gist.files.'hub-config.json'
    if ($f) {
        $hubRaw = $f.content
        if (-not $hubRaw -and $f.truncated -and $f.raw_url) {
            $hubRaw = [System.Text.Encoding]::UTF8.GetString(
                (Invoke-WebRequest -UseBasicParsing -Uri $f.raw_url -TimeoutSec 25).Content)
        }
    }
    $hub = if ($hubRaw) {
        ConvertFrom-Json $hubRaw
    } else {
        [pscustomobject]@{ rev = 0; updated = ''; pc = $null; phone = $null }
    }

    # 顺路缓存 phone-activity.json 给面板显示（中心仓库的"拿取"侧）
    try {
        $pa = $gist.files.'phone-activity.json'
        if ($pa -and $pa.content) {
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($cachePhoneAct, $pa.content, $utf8)
        }
    } catch { }

    $localCfg = ConvertFrom-Json ([System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8))
    $localHash = Get-CfgHash $localCfg
    $localContract = Get-AfsCrossContractInfo -Platform pc
    $localContractHash = [string]$localContract.contractHash
    $st = Read-State

    $hubPcHash = ''
    if ($hub.pc -and $hub.pc.hash) { $hubPcHash = [string]$hub.pc.hash }
    $hubPcContractHash = Get-AfsHubContractHash -Hub $hub -SectionName pc
    $contractOutdated = $hubPcContractHash -ne $localContractHash

    $action = 'none'
    if ($hubPcHash -eq $localHash) {
        $action = 'none'
    } elseif ($hubPcHash -eq $st.lastHash) {
        $action = 'push'      # 只有本地变了
    } elseif ($localHash -eq $st.lastHash) {
        $action = 'pull'      # 只有 hub 变了
    } else {
        $action = 'push'      # 两边都变 -> 本地赢
    }

    if ($action -eq 'pull' -and -not $PushOnly) {
        # hub 是权威：把 hub 的 PC 分节应用回本地（走 Set-AfsConfigSafe 补默认值）
        Set-AfsConfigSafe -InputConfig $hub.pc.config | Out-Null
        $localCfg = ConvertFrom-Json ([System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8))
        $localHash = Get-CfgHash $localCfg
        Write-Log 'ok' ('PULL_APPLIED rev=' + $hub.rev + ' hash=' + $localHash.Substring(0, 12))
        Write-State -lastHash $localHash -lastPush $st.lastPush -lastContractHash $st.lastContractHash
        Write-Output ('HUB_CONFIG_PULL_APPLIED rev=' + $hub.rev)
        if (-not $contractOutdated) { exit 0 }
        # A pull is config-only. If this version also needs to publish a newer
        # capability declaration, continue with a section-only contract update.
        $action = 'none'
    }

    if ($action -eq 'none' -and -not $contractOutdated) {
        if ($st.lastHash -ne $localHash -or $st.lastContractHash -ne $localContractHash) {
            Write-State -lastHash $localHash -lastPush $st.lastPush `
                -lastContractHash $localContractHash
        }
        Write-Output 'HUB_CONFIG_SYNC_NONE'
        exit 0
    }

    # 读-改-写：只换 pc 分节的已知字段，phone 分节和未知字段原样保留。
    $configForPush = if ($action -eq 'push') { $localCfg } else { $null }
    $hub = Merge-AfsHubDeviceSection -Hub $hub -SectionName pc `
        -Config $configForPush -Contract $localContract -ConfigHash $localHash
    if ($action -eq 'push' -or $contractOutdated) {
        $hub.rev = [int]$hub.rev + 1
        $hub.updated = Get-Date -Format 'yyyy-MM-dd HH:mm'
        $json = $hub | ConvertTo-Json -Compress -Depth 12
        $body = '{"files":{"hub-config.json":{"content":' + ($json | ConvertTo-Json) + '}}}'
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        Invoke-RestMethod -Method Patch -Uri ('https://api.github.com/gists/' + $sync.gistId) `
            -Headers $headers -Body $bodyBytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 25 | Out-Null
        Write-Log 'ok' ('PUSH_OK rev=' + $hub.rev + ' hash=' + $localHash.Substring(0, 12) +
            ' contract=' + $localContractHash.Substring(0, 12))
        Write-State -lastHash $localHash -lastPush (Get-Date -Format 'yyyy-MM-dd HH:mm') `
            -lastContractHash $localContractHash
        Write-Output ('HUB_CONFIG_PUSH_OK rev=' + $hub.rev)
        exit 0
    }

    Write-Output 'HUB_CONFIG_SYNC_NONE'
    exit 0
}
catch {
    Write-Log 'FAIL' ([string]$_.Exception.Message)
    Write-Output ('HUB_CONFIG_FAIL ' + $_.Exception.Message)
    exit 1
}
