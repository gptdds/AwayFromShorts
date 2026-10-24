# Pure aggregation shared by the Gist publisher and offline regression checks.
function Get-AfsPcPairs {
    param($Value)
    if ($null -eq $Value) { return }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) { [pscustomobject]@{ Name = [string]$key; Value = $Value[$key] } }
    } else {
        foreach ($p in $Value.PSObject.Properties) { [pscustomobject]@{ Name = $p.Name; Value = $p.Value } }
    }
}

function Get-AfsPcActivitySummary {
    param($Activity, $History, [datetime]$Now = (Get-Date))
    $allDays = @{}
    # Daily counters are cumulative. Repeated or older snapshots must never add them twice.
    foreach ($source in @($History.days, $Activity.days)) {
        foreach ($day in @(Get-AfsPcPairs $source)) {
            if ($day.Name -notmatch '^\d{4}-\d{2}-\d{2}$') { continue }
            if (-not $allDays.ContainsKey($day.Name)) { $allDays[$day.Name] = @{ apps = @{} } }
            $apps = $allDays[$day.Name].apps
            foreach ($p in @(Get-AfsPcPairs $day.Value.apps)) {
                $min = 0L
                if (-not [long]::TryParse([string]$p.Value, [ref]$min) -or $min -le 0) { continue }
                if (-not $apps.ContainsKey($p.Name) -or $min -gt $apps[$p.Name]) { $apps[$p.Name] = $min }
            }
        }
    }
    $keys = @($allDays.Keys | Sort-Object)
    $month = $Now.ToString('yyyy-MM')
    $monthApps = @{}
    $totalApps = @{}
    foreach ($date in $keys) {
        foreach ($p in @(Get-AfsPcPairs $allDays[$date].apps)) {
            $totalApps[$p.Name] = [long]$totalApps[$p.Name] + [long]$p.Value
            if ($date.StartsWith($month)) { $monthApps[$p.Name] = [long]$monthApps[$p.Name] + [long]$p.Value }
        }
    }
    $slice = [ordered]@{}
    foreach ($date in @($keys | Select-Object -Last 14)) {
        $apps = [ordered]@{}
        foreach ($p in @(Get-AfsPcPairs $allDays[$date].apps | Sort-Object { [long]$_.Value } -Descending | Select-Object -First 12)) {
            $apps[$p.Name] = $p.Value
        }
        if ($apps.Count -gt 0) { $slice[$date] = @{ apps = $apps } }
    }
    @{
        history = @{ version = 1; days = $allDays }
        payload = [ordered]@{
            updated = $Now.ToString('yyyy-MM-dd HH:mm')
            month = $month
            date = $Now.ToString('yyyy-MM-dd')
            since = if ($keys.Count) { $keys[0] } else { '' }
            todayApps = if ($allDays.ContainsKey($Now.ToString('yyyy-MM-dd'))) { $allDays[$Now.ToString('yyyy-MM-dd')].apps } else { @{} }
            monthApps = $monthApps
            totalApps = $totalApps
            days = $slice
        }
    }
}
