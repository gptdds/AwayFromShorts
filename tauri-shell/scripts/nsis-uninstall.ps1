# ============================================================
#  nsis-uninstall.ps1 - pre-uninstall orchestration for NSIS bundle
#
#  Called by NSIS_HOOK_PREUNINSTALL (runs BEFORE NSIS removes files and
#  shortcuts, so this file still exists on disk at that point).
#
#  Mode A: -CheckOnly  -> read-only. Returns 1 if Force Mode currently
#          blocks uninstall (anti-cheat guard), 0 otherwise.
#          NSIS maps exit 1 to MessageBox + Abort.
#  Mode B: -Cleanup    -> delete scheduled tasks, restore hosts, clear
#          browser policies, stop webui, delete hosts.backup, remove
#          legacy startup VBS and the shell autostart task.
#          Does NOT delete the install directory: NSIS does that itself.
#
#  -DryRun : skip every globally-visible side effect.
#  -NoElevate : internal, set by the self-elevation relaunch.
#
#  NOTE: keep this file pure ASCII (PS 5.1 reads BOM-less .ps1 as ANSI).
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$AppDir,
    [switch]$CheckOnly,
    [switch]$Cleanup,
    [switch]$DryRun,
    [switch]$NoElevate
)

$ErrorActionPreference = 'Continue'
$src  = Join-Path $AppDir 'src'
$core = Join-Path $src 'core.ps1'

function Write-Step([string]$n, [string]$s) { Write-Host "[$n] $s" }
function Write-Skip([string]$s)            { Write-Host "  DRYRUN-SKIP: $s" }

# ---- 0. self-elevation -------------------------------------------------
# RequestExecutionLevel admin normally covers the uninstaller too, but if
# it is launched from a non-elevated shell (or via "Run as different user")
# the cleanup would silently fail. Re-exec elevated and pass the exit code
# back to NSIS so Abort / success stays observable.
function Test-AfsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not $CheckOnly -and -not $NoElevate -and -not $DryRun -and -not (Test-AfsAdmin)) {
    Write-Host 'Not elevated. Requesting administrator rights for cleanup...'
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', "`"$($MyInvocation.MyCommand.Path)`"",
        '-AppDir', "`"$AppDir`"", '-Cleanup', '-NoElevate'
    )
    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList `
                -Verb RunAs -PassThru -Wait
        $code = if ($p) { $p.ExitCode } else { 5 }
        Write-Host "Elevated cleanup exit: $code"
        exit $code
    } catch {
        Write-Host "ELEVATION-DENIED: $($_.Exception.Message)"
        exit 5
    }
}

# ---- 1. anti-cheat guard (read-only, always runs) ----------------------
# Reuse core.ps1's Get-AfsUninstallBlock so the NSIS path obeys exactly the
# same Force Mode protection as the original uninstall.bat / panel button.
$guardBlocked = $false
if (Test-Path $core) {
    try {
        . $core
        $guard = Get-AfsUninstallBlock
        if ($guard -and $guard.blocked) {
            $guardBlocked = $true
            Write-Host ''
            Write-Host '===== UNINSTALL BLOCKED (Force Mode) ====='
            Write-Host $guard.msg
            Write-Host ''
        } else {
            Write-Host 'Force Mode guard: not blocking'
        }
    } catch {
        Write-Host "WARN: guard check failed ($($_.Exception.Message)); allowing uninstall"
    }
} else {
    Write-Host 'WARN: core.ps1 not found; guard check skipped (fresh/partial install)'
}

if ($CheckOnly) {
    if ($guardBlocked) { Write-Host 'CHECK-EXIT: 1 (blocked)'; exit 1 }
    Write-Host 'CHECK-EXIT: 0 (allowed)'; exit 0
}

if ($guardBlocked) { Write-Host 'Refusing cleanup.'; exit 1 }
if (-not $Cleanup) { Write-Host 'Nothing to do (pass -CheckOnly or -Cleanup).'; exit 0 }

Write-Host '===== AwayFromShorts NSIS pre-uninstall cleanup ====='
Write-Host "AppDir : $AppDir"
Write-Host "DryRun : $DryRun"
Write-Host "Admin  : $(Test-AfsAdmin)"

# ---- 2. delete all scheduled tasks -------------------------------------
Write-Step '1/6' 'Delete scheduled tasks'
$taskNames = @(
    'AwayFromShorts', 'AwayFromShorts-WebUI',
    'AwayFromShorts-BrowserClose', 'AwayFromShorts-GameQuota',
    'AwayFromShorts-Shell'
)
foreach ($t in $taskNames) {
    if ($DryRun) { Write-Skip "schtasks /Delete /TN $t /F" }
    else {
        & schtasks.exe /Delete /TN $t /F 2>&1 | Out-Null
    }
}

# ---- 3. restore hosts (remove only our marker block) -------------------
Write-Step '2/6' 'Restore hosts file'
if ($DryRun) { Write-Skip 'Remove-AfsHostsBlock (would modify system hosts)' }
else {
    if (Test-Path $core) {
        try {
            Remove-AfsHostsBlock -Path (Get-AfsDefaultHostsPath)
            Write-Host '  hosts marker block removed'
        } catch { Write-Host "  WARN: hosts restore failed: $($_.Exception.Message)" }
    } else { Write-Host '  WARN: core.ps1 missing, hosts restore skipped' }
}

# ---- 4. clear browser URLBlocklist / URLAllowlist policies -------------
Write-Step '3/6' 'Clear browser blocking policies'
if ($DryRun) { Write-Skip 'Remove-Item HKLM policies URLBlocklist / URLAllowlist' }
else {
    foreach ($root in @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'HKLM:\SOFTWARE\Policies\Google\Chrome')) {
        Remove-Item (Join-Path $root 'URLBlocklist') -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $root 'URLAllowlist') -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host '  policies cleared'
}

# ---- 5. stop webui HTTP server + tray shell ----------------------------
Write-Step '4/6' 'Stop webui / shell processes'
if ($DryRun) { Write-Skip 'Stop-Process webui.ps1 + awayfromshorts-shell.exe' }
else {
    $me = $PID
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*webui.ps1*' -and $_.ProcessId -ne $me } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-Process -Name 'awayfromshorts-shell' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host '  processes stopped'
}

# ---- 6. remove hosts.backup + legacy startup VBS -----------------------
Write-Step '5/6' 'Remove backup file and legacy startup VBS'
if ($DryRun) { Write-Skip 'delete hosts.backup + Startup folder VBS' }
else {
    $bak = Join-Path $AppDir 'hosts.backup'
    if (Test-Path $bak) { Remove-Item $bak -Force -ErrorAction SilentlyContinue }
    $vbs = Join-Path ([Environment]::GetFolderPath('Startup')) 'AwayFromShorts-WebUI.vbs'
    if (Test-Path $vbs) { Remove-Item $vbs -Force -ErrorAction SilentlyContinue }
    Write-Host '  cleaned'
}

# ---- 7. explicit note: directory removal is NSIS's job -----------------
Write-Step '6/6' 'Install directory left for NSIS to remove'
Write-Host "  NSIS will delete $AppDir and its shortcuts/registry"

Write-Host '===== NSIS pre-uninstall cleanup done ====='
exit 0
