# ============================================================
#  prepare-bundle.ps1 - stage clean runtime files for the NSIS bundle
#
#  Copies the project's src/ tree + root launcher scripts into
#  src-tauri/bundle-resources/, excluding user data / runtime state
#  (same exclusion list as scripts/build-release.ps1).
#
#  The Tauri config references this folder via bundle.resources, so run
#  this BEFORE `cargo tauri build`.
#
#  Usage: powershell -ExecutionPolicy Bypass -File prepare-bundle.ps1
# ============================================================
$ErrorActionPreference = 'Stop'

$root       = Split-Path $PSScriptRoot          # tauri-shell/
$project    = Split-Path $root                  # project root
$stage      = Join-Path (Join-Path $root 'src-tauri') 'bundle-resources'
$stageSrc   = Join-Path $stage 'src'

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stageSrc -Force | Out-Null

# ---- 1. copy the whole src tree, then strip runtime/user data ----
Copy-Item (Join-Path $project 'src') $stage -Recurse -Force

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
    '.webui-restart.timestamp', 'game-quota-config.json', 'game-quota-state.json',
    'game-quota-state.json.tmp', 'quota-edit-until.json', 'quota-edit-until.json.tmp',
    'hosts.backup', 'study-db.json.bak'
)
Get-ChildItem $stageSrc -Recurse -File |
    Where-Object { ($runtimeFiles -contains $_.Name) -or ($_.Name -like '*.bak-*') -or ($_.Name -like '*.log') } |
    Remove-Item -Force

# stray VCS / editor files
Get-ChildItem $stageSrc -Recurse -File |
    Where-Object { $_.Name -in @('.gitignore', '.DS_Store', 'Thumbs.db') } |
    Remove-Item -Force

# Python bytecode caches are not needed at runtime
Get-ChildItem $stageSrc -Recurse -Directory |
    Where-Object { $_.Name -eq '__pycache__' } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# ---- 2. root launcher scripts + docs (install.bat intentionally kept) ----
foreach ($f in @('install.bat', 'uninstall.bat', 'start-web.bat', 'startup-webui.vbs', 'README.md', 'LICENSE')) {
    $p = Join-Path $project $f
    if (Test-Path $p) { Copy-Item $p $stage -Force }
}

# ---- 3. NSIS helper scripts (install / uninstall orchestration) ----
Copy-Item (Join-Path $root 'scripts\nsis-install.ps1')   $stage -Force
Copy-Item (Join-Path $root 'scripts\nsis-uninstall.ps1') $stage -Force

# ---- 4. summary ----
$count = (Get-ChildItem $stage -Recurse -File | Measure-Object).Count
$size  = [math]::Round((Get-ChildItem $stage -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1KB, 1)
Write-Host "Staged $count files ($size KB) into: $stage"
Write-Host "  src/ files: $((Get-ChildItem $stageSrc -Recurse -File | Measure-Object).Count)"
