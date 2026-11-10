# ============================================================
#  check-template-drift.ps1
#
#  Verifies that nsis/installer.nsi is still EXACTLY the upstream
#  tauri-bundler v2.10.4 template plus our single approved patch:
#    - 4 comment lines (beginning with "; AFS:")
#    - currentUser branch: RequestExecutionLevel user -> admin
#
#  Run this after upgrading tauri / tauri-bundler. If it reports drift,
#  re-copy the upstream template and re-apply the one-line patch.
#
#  Usage: powershell -ExecutionPolicy Bypass -File check-template-drift.ps1
#         (optional) -Upstream <path-to-new-installer.nsi>
# ============================================================
param([string]$Upstream = '')

$ErrorActionPreference = 'Stop'
$here     = $PSScriptRoot
$patched  = Join-Path $here 'installer.nsi'

if (-not $Upstream) {
    $cargoSrc = Join-Path $env:USERPROFILE '.cargo\registry\src'
    $cand = Get-ChildItem -Path $cargoSrc -Directory -Filter 'tauri-bundler-2.10.4' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
    if ($cand) {
        $Upstream = Join-Path $cand.FullName 'src\bundle\windows\nsis\installer.nsi'
    }
}
if (-not $Upstream -or -not (Test-Path $Upstream)) {
    Write-Host "ERROR: upstream template not found. Pass -Upstream <path>."
    exit 2
}

$uLines = [System.IO.File]::ReadAllLines($Upstream)
$pLines = [System.IO.File]::ReadAllLines($patched)

# Rebuild "expected upstream" from our patched file by undoing the patch.
$expected = New-Object System.Collections.Generic.List[string]
$inCurrentUser = $false
$removedComments = 0
foreach ($l in $pLines) {
    if ($l -match '^\s*;\s*AFS:') { $removedComments++; continue }
    if ($l -match '^\s*;\s*stays \$LOCALAPPDATA') { $removedComments++; continue }
    if ($l -match '^\s*;\s*but need admin for hosts') { $removedComments++; continue }
    if ($l -match '^\s*;\s*Copy of tauri-bundler') { $removedComments++; continue }
    if ($l -match '!if "\$\{INSTALLMODE\}" == "currentUser"') { $inCurrentUser = $true }
    if ($inCurrentUser -and $l -match '^\s*RequestExecutionLevel admin') {
        $expected.Add('  RequestExecutionLevel user')
        $inCurrentUser = $false
        continue
    }
    if ($l -match '!endif') { $inCurrentUser = $false }
    $expected.Add($l)
}

$differ = 0
$max = [Math]::Max($uLines.Count, $expected.Count)
for ($i = 0; $i -lt $max; $i++) {
    $a = if ($i -lt $uLines.Count)   { $uLines[$i] }   else { '<missing>' }
    $b = if ($i -lt $expected.Count) { $expected[$i] } else { '<missing>' }
    if ($a -ne $b) {
        $differ++
        if ($differ -le 12) {
            Write-Host "  L$($i+1) upstream : $a"
            Write-Host "  L$($i+1) expected : $b"
        }
    }
}

Write-Host ''
Write-Host "Upstream       : $Upstream"
Write-Host "Patched        : $patched"
Write-Host "Upstream lines : $($uLines.Count)"
Write-Host "Patched  lines : $($pLines.Count)"
Write-Host "Comment lines removed by reverse-patch: $removedComments"
Write-Host "Upstream SHA256: $((Get-FileHash $Upstream -Algorithm SHA256).Hash)"
Write-Host "Patched  SHA256: $((Get-FileHash $patched  -Algorithm SHA256).Hash)"
Write-Host "Differing lines after undo: $differ"

if ($differ -eq 0 -and $removedComments -eq 4) {
    Write-Host ''
    Write-Host 'OK: template matches upstream + the single approved patch. No drift.'
    exit 0
} else {
    Write-Host ''
    Write-Host 'DRIFT DETECTED: re-sync installer.nsi from the new upstream template,'
    Write-Host 'then re-apply only the currentUser RequestExecutionLevel admin change.'
    exit 1
}
