$script:AFS_CROSS_CONTRACT_ID = 'awayfromshorts.cross-platform'
$script:AFS_CROSS_CONTRACT_VERSION = 1
$script:AFS_CROSS_CONTRACT_FILE = 'awayfromshorts-cross-platform-v1.json'

function Get-AfsCrossContractPath {
    Join-Path (Join-Path $PSScriptRoot 'contracts') $script:AFS_CROSS_CONTRACT_FILE
}

function Get-AfsCrossContract {
    param([string]$Path = '')
    if (-not $Path) { $Path = Get-AfsCrossContractPath }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "缺少跨端功能契约: $Path"
    }
    $contract = ConvertFrom-Json ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8))
    if ([string]$contract.id -ne $script:AFS_CROSS_CONTRACT_ID) {
        throw '跨端功能契约 id 不匹配'
    }
    if ([int]$contract.contractVersion -ne $script:AFS_CROSS_CONTRACT_VERSION -or
        [int]$contract.minimumReaderVersion -gt $script:AFS_CROSS_CONTRACT_VERSION) {
        throw '跨端功能契约版本不兼容'
    }
    if (@('reject','preserve') -notcontains [string]$contract.unknownFieldPolicy) {
        throw '跨端功能契约 unknownFieldPolicy 无效'
    }
    if (@('reject','warn') -notcontains [string]$contract.unknownFeaturePolicy) {
        throw '跨端功能契约 unknownFeaturePolicy 无效'
    }

    $scope = $contract.scopeMask
    $combined = ([int]$scope.schedule -bor [int]$scope.quota -bor [int]$scope.orSet -bor
        [int]$scope.study -bor [int]$scope.penalty)
    if ([int]$scope.schedule -ne 1 -or [int]$scope.quota -ne 2 -or
        [int]$scope.orSet -ne 4 -or [int]$scope.study -ne 8 -or
        [int]$scope.penalty -ne 16 -or [int]$scope.all -ne 31 -or $combined -ne 31) {
        throw '跨端功能契约 scopeMask 无效'
    }

    $seen = @{}
    foreach ($feature in @($contract.features)) {
        $id = [string]$feature.id
        if ($id -notmatch '^[a-z][a-z0-9-]*(\.[a-z0-9-]+)+$') {
            throw "跨端功能契约 feature id 无效: $id"
        }
        if ($seen.ContainsKey($id)) {
            throw "跨端功能契约 feature id 重复: $id"
        }
        $seen[$id] = $true
        if ([int]$feature.version -lt 1) {
            throw "跨端功能契约 feature version 无效: $id"
        }
        if ($null -eq $feature.support -or
            $feature.support.pc -isnot [bool] -or $feature.support.phone -isnot [bool]) {
            throw "跨端功能契约 support 无效: $id"
        }

        $required = @($feature.requires)
        if ($required.Count -eq 0) {
            throw "跨端功能契约 requires 不能为空: $id"
        }
        $requiredSeen = @{}
        foreach ($requirement in $required) {
            $name = [string]$requirement
            if (-not $name.Trim()) {
                throw "跨端功能契约 requires 含空值: $id"
            }
            if ($requiredSeen.ContainsKey($name)) {
                throw "跨端功能契约 requires 重复: $id/$name"
            }
            $requiredSeen[$name] = $true
        }
    }

    if (-not $contract.platformBindings -or
        -not $contract.platformBindings.pc -or
        -not $contract.platformBindings.phone) {
        throw '跨端功能契约 platformBindings 无效'
    }
    if (-not $contract.sync -or [string]$contract.sync.hub -ne 'hub-config.json' -or
        [string]$contract.sync.capabilityField -ne 'contract' -or
        [string]$contract.sync.unknownFields -ne 'preserve' -or
        [string]$contract.sync.unsupportedFeature -ne 'warn-and-skip') {
        throw '跨端功能契约 sync 配置无效'
    }
    $sections = @($contract.sync.deviceSections)
    if ($sections -notcontains 'pc' -or $sections -notcontains 'phone') {
        throw '跨端功能契约 sync.deviceSections 无效'
    }
    return $contract
}

function Get-AfsCrossContractInfo {
    param([ValidateSet('pc','phone')][string]$Platform = 'pc')
    $path = Get-AfsCrossContractPath
    $contract = Get-AfsCrossContract -Path $path
    $supported = New-Object System.Collections.ArrayList
    $versions = [ordered]@{}
    foreach ($feature in @($contract.features)) {
        if (-not [bool]$feature.support.$Platform) { continue }
        [void]$supported.Add([string]$feature.id)
        $versions[[string]$feature.id] = [int]$feature.version
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = ($sha.ComputeHash([System.IO.File]::ReadAllBytes($path)) |
            ForEach-Object { $_.ToString('x2') }) -join ''
    } finally {
        $sha.Dispose()
    }
    $appVersion = if ($script:AFS_VERSION) { [string]$script:AFS_VERSION } else { 'unknown' }
    return [ordered]@{
        platform = $Platform
        appVersion = $appVersion
        contractVersion = [int]$contract.contractVersion
        contractHash = $digest
        scopeMask = [ordered]@{
            schedule = [int]$contract.scopeMask.schedule
            quota = [int]$contract.scopeMask.quota
            orSet = [int]$contract.scopeMask.orSet
            study = [int]$contract.scopeMask.study
            penalty = [int]$contract.scopeMask.penalty
            all = [int]$contract.scopeMask.all
        }
        featureVersions = $versions
        supportedFeatures = @($supported.ToArray())
    }
}

function Compare-AfsCrossContractInfo {
    param($Local, $Remote)
    $result = [ordered]@{
        status = 'missing'
        compatible = $false
        localContractVersion = $null
        remoteContractVersion = $null
        missingOnLocal = @()
        missingOnRemote = @()
        versionMismatches = @()
        warnings = @()
    }
    if ($null -eq $Local -or $null -eq $Remote) {
        $result.warnings = @('一端尚未上报跨端能力清单')
        return [pscustomobject]$result
    }

    $result.localContractVersion = [int]$Local.contractVersion
    $result.remoteContractVersion = [int]$Remote.contractVersion
    if ([int]$Local.contractVersion -ne [int]$Remote.contractVersion) {
        $result.status = 'incompatible'
        $result.warnings = @(
            "契约版本不一致: 本地 $($Local.contractVersion)，远端 $($Remote.contractVersion)"
        )
        return [pscustomobject]$result
    }

    $localVersions = @{}
    if ($Local.featureVersions -is [System.Collections.IDictionary]) {
        foreach ($key in @($Local.featureVersions.Keys)) {
            $localVersions[[string]$key] = [int]$Local.featureVersions[$key]
        }
    } else {
        foreach ($p in @($Local.featureVersions.PSObject.Properties)) {
            $localVersions[[string]$p.Name] = [int]$p.Value
        }
    }
    $remoteVersions = @{}
    if ($Remote.featureVersions -is [System.Collections.IDictionary]) {
        foreach ($key in @($Remote.featureVersions.Keys)) {
            $remoteVersions[[string]$key] = [int]$Remote.featureVersions[$key]
        }
    } else {
        foreach ($p in @($Remote.featureVersions.PSObject.Properties)) {
            $remoteVersions[[string]$p.Name] = [int]$p.Value
        }
    }
    $localFeatures = @($Local.supportedFeatures)
    $remoteFeatures = @($Remote.supportedFeatures)
    $all = @($localFeatures + $remoteFeatures | Sort-Object -Unique)
    $missingLocal = New-Object System.Collections.ArrayList
    $missingRemote = New-Object System.Collections.ArrayList
    $mismatches = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList

    foreach ($feature in $all) {
        $localHas = $localFeatures -contains $feature
        $remoteHas = $remoteFeatures -contains $feature
        if ($localHas -and -not $remoteHas) {
            [void]$missingRemote.Add([string]$feature)
            [void]$warnings.Add("远端不支持: $feature（将按 warn-and-skip 跳过）")
        } elseif ($remoteHas -and -not $localHas) {
            [void]$missingLocal.Add([string]$feature)
            [void]$warnings.Add("本地不支持: $feature（warn；未知能力将保留）")
        } elseif ($localHas -and $remoteHas -and $localVersions[$feature] -ne $remoteVersions[$feature]) {
            [void]$mismatches.Add([ordered]@{
                id = [string]$feature
                local = [int]$localVersions[$feature]
                remote = [int]$remoteVersions[$feature]
            })
        }
    }

    $result.compatible = $mismatches.Count -eq 0
    $result.missingOnLocal = @($missingLocal.ToArray())
    $result.missingOnRemote = @($missingRemote.ToArray())
    $result.versionMismatches = @($mismatches.ToArray())
    $result.warnings = @($warnings.ToArray())
    if (-not $result.compatible) {
        $result.status = 'incompatible'
    } elseif ($missingLocal.Count -gt 0 -or $missingRemote.Count -gt 0) {
        $result.status = 'different'
    } else {
        $result.status = 'same'
    }
    return [pscustomobject]$result
}
