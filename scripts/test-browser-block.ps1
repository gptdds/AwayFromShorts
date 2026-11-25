# Windows PowerShell 5.1 regression tests; no real browser is closed.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. (Join-Path $root 'src\core.ps1')
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src\close-browser-windows.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-AfsBrowserProcessBlock' }, $true)
Invoke-Expression $fn.Extent.Text
$script:testConfig = Get-AfsDefaultConfig
$script:testConfig.enabled = $true
$script:testConfig.force.enabled = $false
$script:testConfig.schedule.days = @(1,2,3,4,5,6,7)
$script:testConfig.schedule.windows = @(
    @{start='00:00';end='12:00';blockedSites=@();blockedProcesses=@('chrome.exe','powershell','msedge')},
    @{start='12:00';end='00:00';blockedSites=@();blockedProcesses=@('chrome.exe','powershell','msedge')}
)
$script:testConfig.whitelist.processes = @('msedge')
$script:stopped = @()
function Get-AfsConfig { $script:testConfig }
function Get-Process { param($Name, $Id, $ErrorAction) @{Id=123;ProcessName=$Name} }
function Stop-Process { param($Id, [switch]$Force, $ErrorAction) $script:stopped += $Id }
function Assert-Test { param($Pass, $Message) if (-not $Pass) { throw $Message }; Write-Output "PASS: $Message" }
$r = Invoke-AfsBrowserProcessBlock
Assert-Test ($r.active -and $r.killed.Count -eq 1 -and $r.killed[0] -eq 'chrome(123)') 'Chrome process blacklist is enforced; Edge whitelist is respected'
$script:testConfig.whitelist.processes += 'chr*'
$r = Invoke-AfsBrowserProcessBlock
Assert-Test ($r.killed.Count -eq 0 -and $r.monitoring) 'Wildcard process whitelist takes effect'
$script:testConfig.whitelist.processes = @('msedge')
$script:testConfig.override = @{mode='off';until=(Get-Date).AddMinutes(5).ToString('o')}
$r = Invoke-AfsBrowserProcessBlock
Assert-Test (-not $r.active -and $r.killed.Count -eq 0 -and $r.monitoring) 'Temporary unlock stops killing and retains monitoring for relock'
$script:testConfig.override.mode = 'none'
$script:testConfig.freeze.enabled = $false
$r = Invoke-AfsBrowserProcessBlock
Assert-Test (-not $r.active -and $r.killed.Count -eq 0) 'Pausing the freeze schedule leaves blacklisted browsers running'
$script:testConfig.freeze.enabled = $true
$script:testConfig.enabled = $false
$r = Invoke-AfsBrowserProcessBlock
Assert-Test (-not $r.active -and $r.killed.Count -eq 0) 'Disabled blocking leaves browsers running'
$script:testConfig.enabled = $true
$script:testConfig.schedule.days = @()
$r = Invoke-AfsBrowserProcessBlock
Assert-Test (-not $r.active -and $r.killed.Count -eq 0) 'Outside schedule leaves browsers running'
$script:testConfig.schedule.days = @(1,2,3,4,5,6,7)
function Stop-Process { param($Id, [switch]$Force, $ErrorAction) throw 'test access denied' }
$r = Invoke-AfsBrowserProcessBlock
Assert-Test ($r.errors.Count -eq 1 -and $r.killed.Count -eq 0) 'Kill failure is reported without claiming success'

# Exercise the actual minute-engine function with external effects stubbed.
function Stop-Process { param($Id, [switch]$Force, $ErrorAction) $script:stopped += $Id }
function Invoke-AfsBrowserPendingRestart { $false }
function Invoke-AfsBrowserReload { $true }
function Initialize-AfsBrowserTask { $true }
function Read-AfsBrowserState { @{applied=$false} }
function Update-AfsUnlockStats { }
$script:testConfig.blockWebsites = $false
$script:testConfig.browser.urlBlock = $false
$r = Invoke-AfsEnforce -Config $script:testConfig
Assert-Test ($r.killed -contains 'chrome(123)' -and $r.killed.Count -eq 1) 'Minute engine also honors Chrome blacklist without killing whitelisted Edge'
