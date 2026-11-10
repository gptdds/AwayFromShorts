param([switch]$DryRun)
$ErrorActionPreference = 'Stop'
$taskName = 'AwayFromShorts-GameQuota'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$file = [Security.SecurityElement]::Escape((Join-Path $PSScriptRoot 'game-quota.ps1'))
$start = (Get-Date).AddMinutes(-1).ToString('yyyy-MM-ddTHH:mm:ss')
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
 <Principals><Principal id="Author"><UserId>$sid</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
 <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><RestartOnFailure><Interval>PT1M</Interval><Count>999</Count></RestartOnFailure></Settings>
 <Triggers><LogonTrigger><Enabled>true</Enabled><UserId>$sid</UserId></LogonTrigger><TimeTrigger><StartBoundary>$start</StartBoundary><Repetition><Interval>PT1M</Interval></Repetition></TimeTrigger></Triggers>
 <Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$file"</Arguments></Exec></Actions>
</Task>
"@
if ($DryRun) { return $xml }
Register-ScheduledTask -TaskName $taskName -Xml $xml -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
