# ============================================================
#  build-release.ps1 — 打包懒人包 ZIP (install.bat + src + 文档)
#  用法: powershell -File build-release.ps1 [-Version 1.1.4]
# ============================================================
param([string]$Version = '1.1.4')

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot          # 项目根
$dist = Join-Path $root 'dist'
$stage = Join-Path $env:TEMP 'afs-release-stage'

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage | Out-Null

# 只打包必要文件, 保持 zip 干净
Copy-Item (Join-Path $root 'install.bat')      $stage
Copy-Item (Join-Path $root 'uninstall.bat')    $stage
Copy-Item (Join-Path $root 'start-web.bat')    $stage
Copy-Item (Join-Path $root 'startup-webui.vbs') $stage
Copy-Item (Join-Path $root 'README.md')        $stage
Copy-Item (Join-Path $root 'LICENSE')          $stage
Copy-Item (Join-Path $root 'src')              $stage -Recurse

# 清除运行时/用户数据文件, 防止打包进懒人包 (隐私: 白名单/Token/状态等)
$runtimeFiles = @(
    'config.json', 'last-run.json', 'github-token.enc',
    'sync-state.json', 'force-state.json', 'clash-state.json',
    'browser-state.json', 'browser-close.json', 'browser-close.log',
    'stats.json', 'activity.json',
    'study-db.json', 'focus-local.json', 'study.flag',
    'ledger-sync-state.json', 'ledger-sync-status.json', 'study-db.json.before-sync.json',
    'study-db.json.lock', 'study-db.json.sync.lock',
    'study-run.lock',
    'browser-restart.json', 'browser-restart.pending.json', 'browser-close.heartbeat',
    'hub-state.json', 'study-gist-state.json', 'checkin-queue.local.json',
    'phone-activity.cache.json', 'study-gist.log', 'study-sync.log', 'hub-config.log',
    '.webui-restart.timestamp', 'game-quota-config.json', 'game-quota-state.json', 'game-quota-state.json.tmp',
    'quota-lan-config.json', 'quota-lan-state.json', 'quota-lan.log',
    'quota-edit-until.json', 'quota-edit-until.json.tmp',
    'playback-monitor.json', 'playback-monitor.json.tmp',
    'playback-heartbeat.json', 'playback-heartbeat.json.tmp',
    'playback-history.json', 'playback-history.json.tmp'
)
Get-ChildItem (Join-Path $stage 'src') -File |
    Where-Object { $runtimeFiles -contains $_.Name } |
    Remove-Item -Force

# 安装目录里翻出来的 *.bak-时间戳 同样不能进包（含 web 子目录）
Get-ChildItem (Join-Path $stage 'src') -Recurse -File |
    Where-Object { $_.Name -like '*.bak-*' } |
    Remove-Item -Force

if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist | Out-Null }
$out = Join-Path $dist "AwayFromShorts-v$Version-win64.zip"
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $out -Force
Remove-Item $stage -Recurse -Force

Write-Host "懒人包已生成: $out" -ForegroundColor Green
