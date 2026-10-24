$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../src/activity-summary.ps1')
function Assert-Equal($Actual, $Expected, $Name) {
    if ($Actual -ne $Expected) { throw "$Name : got $Actual, expected $Expected" }
}
$a = @{ days = @{
    '2026-09-30' = @{ apps = @{ editor = 20 } }
    '2026-10-01' = @{ apps = @{ editor = 30; browser = 10 } }
} }
$now = [datetime]'2026-10-24T12:00:00'
$first = Get-AfsPcActivitySummary $a $null $now
Assert-Equal $first.payload.monthApps.editor 30 'month excludes previous month'
Assert-Equal $first.payload.totalApps.editor 50 'total includes previous month'
$again = Get-AfsPcActivitySummary $a $first.history $now
Assert-Equal $again.payload.totalApps.editor 50 'same snapshot is not counted twice'
$new = @{ days = @{ '2026-10-01' = @{ apps = @{ editor = 35 } }; '2026-10-24' = @{ apps = @{ editor = 5 } } } }
$next = Get-AfsPcActivitySummary $new $again.history $now
Assert-Equal $next.payload.totalApps.editor 60 'new counters replace rather than add'
Assert-Equal $next.payload.monthApps.browser 10 'missing entries in a partial snapshot survive'
Assert-Equal $next.payload.since '2026-09-30' 'old history survives source pruning'
$many = @{}
1..15 | ForEach-Object { $many["app$_"] = 1 }
$rank = Get-AfsPcActivitySummary @{ days = @{ '2026-10-24' = @{ apps = $many } } } $null $now
Assert-Equal $rank.payload.days['2026-10-24'].apps.Count 12 'daily ranking is bounded'
Assert-Equal $rank.payload.totalApps.Count 15 'total retains apps outside ranking'
Write-Output '8 PC activity summary checks passed'
