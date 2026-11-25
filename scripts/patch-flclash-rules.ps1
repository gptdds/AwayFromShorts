# patch-flclash-rules.ps1
# 给 FlClash 的**当前订阅**(profiles\<id>.yaml) 幂等补上"B站直播/空间/动态"的 REJECT 规则。
#
# 为什么需要它:
#   AwayFromShorts 的 hosts 屏蔽只对"不走代理"的流量有效。FlClash 开着系统代理时,
#   浏览器请求全交给 FlClash 解析, Windows hosts 直接被绕过 —— 直播/空间照样能开。
#   代理层拦一下最省事: 规则写在 Clash 配置里, 与 DNS/hosts 无关, 也绕不过去。
#
# 为什么不能一次了事:
#   订阅每天自动更新(FlClash 默认 24h), 更新会把 profile 文件整个覆盖掉, 规则也就没了。
#   订阅更新后重跑一次本脚本即可(或干脆在 FlClash 设置里把 *bilibili.com 加进
#   「系统代理绕过域名」, 让 B站 走直连、hosts 重新生效 —— 那个不会随订阅更新丢失)。
#
# 用法: powershell -ExecutionPolicy Bypass -File patch-flclash-rules.ps1 [-WhatIf]
param(
    [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'

$domains = @('live.bilibili.com', 'space.bilibili.com', 't.bilibili.com')
$root = Join-Path $env:APPDATA 'com.follow\clash'
if (-not (Test-Path $root)) { throw "找不到 FlClash 数据目录: $root (没装 FlClash?)" }

# 当前订阅 id 存在 shared_preferences.json 的 flutter.config.currentProfileId
$prefsPath = Join-Path $root 'shared_preferences.json'
if (-not (Test-Path $prefsPath)) { throw "找不到 $prefsPath" }
$prefs = Get-Content $prefsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$cfg = $prefs.'flutter.config' | ConvertFrom-Json
$profileId = [string]$cfg.currentProfileId
if (-not $profileId) { throw '读不到 currentProfileId, 请先在 FlClash 里选好订阅' }

$profilePath = Join-Path $root "profiles\$profileId.yaml"
if (-not (Test-Path $profilePath)) { throw "找不到当前订阅文件: $profilePath" }

$lines = Get-Content $profilePath -Encoding UTF8
$existing = @($lines | Where-Object { $_ -match 'DOMAIN,(live|space|t)\.bilibili\.com,REJECT' })
if ($existing.Count -ge $domains.Count) {
    Write-Output "已经是补好的状态: $profilePath"
    exit 0
}

$missing = @($domains | Where-Object { $d = $_; -not ($lines | Where-Object { $_ -match [regex]::Escape("DOMAIN,$d,REJECT") }) })
if ($missing.Count -eq 0) { Write-Output '无需改动'; exit 0 }

# 插到 rules: 的第一条之前(REJECT 必须排在 GEOIP/China-Site 之类的前面才不会被抢走)
$out = New-Object System.Collections.Generic.List[string]
$inserted = $false
foreach ($ln in $lines) {
    if (-not $inserted -and $ln -match '^rules:\s*$') {
        $out.Add($ln)
        foreach ($d in $missing) { $out.Add("    - 'DOMAIN,$d,REJECT'") }
        $inserted = $true
    } else {
        $out.Add($ln)
    }
}
if (-not $inserted) { throw "在 $profilePath 里找不到 rules: 行, 订阅格式可能变了, 请手动处理" }

Write-Output ("将补入 " + ($missing -join ', '))
if ($WhatIf) { Write-Output '[-WhatIf] 没有写盘'; exit 0 }

$bak = "$profilePath.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
Copy-Item $profilePath $bak -Force
# 保持原文件的 LF 行尾, 避免整文件 diff
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($profilePath, (($out -join "`n") + "`n"), $utf8)
Write-Output "已写入: $profilePath"
Write-Output "备份:   $bak"
Write-Output '下一步: 打开 FlClash -> 订阅页点「重新加载」(或退出重开 FlClash), 规则才会生效。'
