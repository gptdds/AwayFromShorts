# ============================================================
#  nsis-install.ps1 - post-install orchestration for the NSIS bundle
#
#  Called by NSIS_HOOK_POSTINSTALL after all files are copied.
#  Reuses the project's existing scripts (register-task.ps1,
#  register-webui-task.ps1, awayfromshorts.ps1, webui.ps1) instead of
#  reimplementing their logic.
#
#  -DryRun : skip every globally-visible side effect (scheduled tasks,
#            engine run, process launch, cleanup of legacy startup VBS).
#            AppDir-local files (config.json, hosts.backup) are still
#            created so the staged layout can be verified.
#
#  NOTE: keep this file pure ASCII. Windows PowerShell 5.1 reads BOM-less
#  .ps1 as ANSI, which mangles non-ASCII text.
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$AppDir,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$src    = Join-Path $AppDir 'src'
$engine = Join-Path $src 'awayfromshorts.ps1'
$webui  = Join-Path $src 'webui.ps1'
$shell  = Join-Path $AppDir 'awayfromshorts-shell.exe'

function Write-Step([string]$n, [string]$s) { Write-Host "[$n] $s" }
function Write-Skip([string]$s)            { Write-Host "  DRYRUN-SKIP: $s" }

Write-Host '===== AwayFromShorts NSIS post-install ====='
Write-Host "AppDir : $AppDir"
Write-Host "DryRun : $DryRun"
if (-not (Test-Path $src)) { Write-Host "FATAL: src dir missing: $src"; exit 2 }

# ---- 1. init config.json (never overwrite an existing user config) ----
Write-Step '1/9' 'Init config.json (preserve existing)'
$cfg    = Join-Path $src 'config.json'
$cfgEx  = Join-Path $src 'config.example.json'
if (-not (Test-Path $cfg)) {
    if (Test-Path $cfgEx) {
        Copy-Item $cfgEx $cfg -Force
        Write-Host '  created config.json from config.example.json'
    } else {
        Write-Host '  WARN: config.example.json missing, engine will use defaults'
    }
} else {
    Write-Host '  kept existing config.json (migration-safe)'
}

# ---- 2. backup hosts (never overwrite an existing backup) ----
Write-Step '2/9' 'Backup hosts file (preserve existing backup)'
$bak   = Join-Path $AppDir 'hosts.backup'
$hosts = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
if (-not (Test-Path $bak)) {
    if (Test-Path $hosts) {
        Copy-Item $hosts $bak -Force
        Write-Host "  backed up hosts -> $bak"
    } else {
        Write-Host '  WARN: hosts file not found'
    }
} else {
    Write-Host '  kept existing hosts.backup (migration-safe)'
}

# ---- 3. main engine task: every minute, S4U, highest ----
Write-Step '3/9' 'Register AwayFromShorts engine task (per minute)'
if ($DryRun) {
    Write-Skip 'schtasks /Create via register-task.ps1 -TaskFile awayfromshorts.ps1'
} else {
    $reg = Join-Path $src 'register-task.ps1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $reg -TaskFile $engine
    if ($LASTEXITCODE -ne 0) { Write-Host "FATAL: register-task.ps1 failed (exit $LASTEXITCODE)"; exit 3 }
}

# ---- 4. webui autostart task: AtLogOn, elevated, no UAC prompt ----
Write-Step '4/9' 'Register AwayFromShorts-WebUI task (AtLogOn)'
if ($DryRun) {
    Write-Skip 'schtasks /Create via register-webui-task.ps1'
} else {
    $regWeb = Join-Path $src 'register-webui-task.ps1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $regWeb
    if ($LASTEXITCODE -ne 0) { Write-Host "WARN: register-webui-task.ps1 failed (exit $LASTEXITCODE)" }
}

# ---- 5. shell tray autostart task: AtLogOn, hidden window ----
Write-Step '5/9' 'Register AwayFromShorts-Shell task (AtLogOn, --autostart)'
if ($DryRun) {
    Write-Skip 'schtasks /Create for AwayFromShorts-Shell (tray-only autostart)'
} else {
    $sid  = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $now  = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    $esc  = { param($s) ([string]$s).Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;') }
    $shEsc = & $esc $shell
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Date>$now</Date><URI>\AwayFromShorts-Shell</URI></RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <UserId>$sid</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
  </Settings>
  <Triggers><LogonTrigger><Enabled>true</Enabled><UserId>$sid</UserId></LogonTrigger></Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>$shEsc</Command>
      <Arguments>--autostart</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    $xmlPath = Join-Path $env:TEMP ("afs-shell-task-" + [guid]::NewGuid().ToString('N') + '.xml')
    try {
        [System.IO.File]::WriteAllText($xmlPath, $xml, [System.Text.Encoding]::Unicode)
        & schtasks.exe /Create /F /TN 'AwayFromShorts-Shell' /XML $xmlPath 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "WARN: AwayFromShorts-Shell task failed (exit $LASTEXITCODE)" }
        else { Write-Host '  registered AwayFromShorts-Shell' }
    } finally {
        Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue
    }
}

# ---- 6. remove legacy startup-folder VBS (old auto-start) ----
Write-Step '6/9' 'Clean legacy startup VBS'
if ($DryRun) {
    Write-Skip 'delete legacy AwayFromShorts-WebUI.vbs from Startup folder'
} else {
    $vbs = Join-Path ([Environment]::GetFolderPath('Startup')) 'AwayFromShorts-WebUI.vbs'
    if (Test-Path $vbs) { Remove-Item $vbs -Force -ErrorAction SilentlyContinue; Write-Host "  removed $vbs" }
    else { Write-Host '  no legacy VBS' }
}

# ---- 7. optional game-quota task (only if config file exists) ----
Write-Step '7/9' 'Optional game-quota task'
if (Test-Path (Join-Path $src 'game-quota-config.json')) {
    if ($DryRun) { Write-Skip 'register-game-quota-task.ps1' }
    else {
        $q = Join-Path $src 'register-game-quota-task.ps1'
        if (Test-Path $q) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $q }
    }
} else { Write-Host '  skipped (no game-quota-config.json)' }

# ---- 8. apply blocking rules once, immediately ----
Write-Step '8/9' 'Run engine once (apply current schedule)'
if ($DryRun) { Write-Skip 'awayfromshorts.ps1 (would modify hosts)' }
else {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $engine
    Write-Host "  engine exit: $LASTEXITCODE"
}

# ---- 9. start webui HTTP server, wait for port 8737 ----
# The Tauri shell main.exe is launched by the installer's Finish page
# (MUI_FINISHPAGE_RUN) or /R in silent mode; we only ensure the backend.
Write-Step '9/9' 'Start webui server and wait for 8737'
if ($DryRun) {
    Write-Skip 'Start-Process webui.ps1 + wait for port 8737'
} else {
    $up = $false
    try {
        $c = New-Object Net.Sockets.TcpClient
        $c.Connect('127.0.0.1', 8737); $c.Close(); $up = $true
    } catch { }
    if ($up) {
        Write-Host '  port 8737 already listening (existing instance preserved)'
    } else {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$webui`"" `
            -WindowStyle Hidden
        for ($i = 0; $i -lt 60; $i++) {
            try {
                $c = New-Object Net.Sockets.TcpClient
                $c.Connect('127.0.0.1', 8737); $c.Close(); $up = $true; break
            } catch { Start-Sleep -Milliseconds 250 }
        }
        Write-Host "  port 8737 ready: $up"
    }
}

Write-Host '===== NSIS post-install done ====='
exit 0
