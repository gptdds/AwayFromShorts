$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/core.ps1')
. (Join-Path $root 'src/cross-contract.ps1')
. (Join-Path $root 'src/hub_config.ps1') -LibraryOnly

$checks = 0
function Check([bool]$Condition, [string]$Name) {
    $script:checks++
    if (-not $Condition) { throw "FAIL: $Name" }
}

$pc = Get-AfsCrossContractInfo -Platform pc
$phone = Get-AfsCrossContractInfo -Platform phone
Check ($pc.platform -eq 'pc') 'PC platform label'
Check ($phone.platform -eq 'phone') 'phone platform label'
Check ($pc.contractVersion -eq 1) 'contract version'
Check ($pc.scopeMask.all -eq 31) 'scope bits'
Check ($pc.supportedFeatures -contains 'freeze.schedule') 'PC freeze schedule'
Check ($pc.supportedFeatures -contains 'quota.app') 'PC app quota'
Check ($pc.supportedFeatures -notcontains 'freeze.weekday-pause') `
    'PC does not overclaim weekday pause'
Check ($pc.supportedFeatures -notcontains 'quota.or-set') `
    'PC does not overclaim OR-set'
Check ($pc.supportedFeatures -notcontains 'memo.markdown') `
    'PC does not overclaim memo markdown'
Check ($phone.supportedFeatures -contains 'freeze.weekday-pause') `
    'phone weekday pause'
Check ($phone.supportedFeatures -contains 'quota.or-set') 'phone OR-set'
Check ($phone.supportedFeatures -contains 'memo.markdown') 'phone markdown'
Check ($pc.contractHash -eq $phone.contractHash) 'platforms share byte-identical contract'

$compare = Compare-AfsCrossContractInfo -Local $pc -Remote $phone
Check ($compare.status -eq 'different') 'real support difference is reported'
Check ($compare.compatible) 'different capabilities remain protocol compatible'
Check ($compare.missingOnLocal -contains 'quota.or-set') `
    'phone-only OR-set is explicit'
Check ($compare.missingOnLocal -contains 'memo.markdown') `
    'phone-only markdown is explicit'

$future = ConvertTo-Json $phone -Depth 12 | ConvertFrom-Json
$future.contractVersion = 2
$incompatible = Compare-AfsCrossContractInfo -Local $pc -Remote $future
Check ($incompatible.status -eq 'incompatible') 'future contract is incompatible'

$unknown = ConvertTo-Json $phone -Depth 12 | ConvertFrom-Json
$unknown.supportedFeatures = @($unknown.supportedFeatures) + @('future.feature')
$unknown.featureVersions | Add-Member -NotePropertyName 'future.feature' `
    -NotePropertyValue 1 -Force
$unknownResult = Compare-AfsCrossContractInfo -Local $pc -Remote $unknown
Check ($unknownResult.missingOnLocal -contains 'future.feature') `
    'unknown peer feature is reported'
Check (($unknownResult.warnings -join ' ') -match 'warn') `
    'unknown peer feature warning policy'

$hub = @'
{
  "rev": 7,
  "updated": "2026-01-01 00:00",
  "futureTop": { "keep": true },
  "pc": {
    "hash": "old",
    "futurePc": "keep-pc",
    "config": { "version": 1 }
  },
  "phone": {
    "hash": "phone-hash",
    "futurePhone": "keep-phone",
    "contract": { "contractHash": "old-phone" }
  }
}
'@ | ConvertFrom-Json
$merged = Merge-AfsHubDeviceSection -Hub $hub -SectionName pc `
    -Config @{ version = 1; enabled = $true } -Contract $pc -ConfigHash 'new-hash'
Check ($merged.futureTop.keep) 'unknown top-level hub field preserved'
Check ($merged.phone.futurePhone -eq 'keep-phone') 'phone section preserved'
Check ($merged.pc.futurePc -eq 'keep-pc') 'unknown PC section field preserved'
Check ($merged.pc.contract.contractHash -eq $pc.contractHash) 'contract is written'

$contract = Get-AfsCrossContract
$temp = Join-Path $env:TEMP ('afs-contract-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    $contract.features[0].requires = @('timezone', 'timezone')
    [IO.File]::WriteAllText($temp, (ConvertTo-Json $contract -Depth 12),
        (New-Object Text.UTF8Encoding($false)))
    $rejected = $false
    try { Get-AfsCrossContract -Path $temp | Out-Null }
    catch { $rejected = $true }
    Check $rejected 'duplicate requires rejected'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
}

$androidContract = 'D:\afs-source-style\dpc\assets\contracts\awayfromshorts-cross-platform-v1.json'
if (Test-Path -LiteralPath $androidContract) {
    $pcHash = (Get-FileHash (Get-AfsCrossContractPath) -Algorithm SHA256).Hash
    $phoneHash = (Get-FileHash $androidContract -Algorithm SHA256).Hash
    Check ($pcHash -eq $phoneHash) 'checked-in PC and Android contracts match'
}

Write-Output "Cross contract: $checks checks passed"
