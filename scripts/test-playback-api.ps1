$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\src\game-quota.ps1" -LibraryOnly

function Assert($Condition, $Message) {
    if (-not $Condition) { throw $Message }
}

$root = Split-Path $PSScriptRoot -Parent
$tmp = Join-Path $env:TEMP ('afs-playback-api-' + [guid]::NewGuid().ToString('N'))
$proc = $null
try {
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    Copy-Item (Join-Path $root 'src') $tmp -Recurse -Force
    $webuiPath = Join-Path $tmp 'src\webui.ps1'
    $text = [IO.File]::ReadAllText($webuiPath, [Text.Encoding]::UTF8)
    $needle = '$isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)'
    Assert ($text.Contains($needle)) 'Test copy elevation marker missing'
    $text = $text.Replace($needle, '$isAdmin = $true')
    [IO.File]::WriteAllText($webuiPath, $text, [Text.UTF8Encoding]::new($true))

    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $port = ([Net.IPEndPoint]$probe.LocalEndpoint).Port
    $probe.Stop()
    $stdout = Join-Path $tmp 'webui.stdout.log'
    $stderr = Join-Path $tmp 'webui.stderr.log'
    $proc = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $webuiPath + '"'), '-Port', [string]$port
    )
    $base = 'http://127.0.0.1:' + $port
    $ready = $false
    for ($i = 0; $i -lt 50; $i++) {
        try {
            $null = Invoke-RestMethod -Uri ($base + '/api/contract') -TimeoutSec 1
            $ready = $true
            break
        } catch { Start-Sleep -Milliseconds 200 }
    }
    if (-not $ready) {
        $detail = ''
        if (Test-Path $stdout) { $detail += "`nSTDOUT:`n" + (Get-Content $stdout -Raw -ErrorAction SilentlyContinue) }
        if (Test-Path $stderr) { $detail += "`nSTDERR:`n" + (Get-Content $stderr -Raw -ErrorAction SilentlyContinue) }
        throw ('Temporary WebUI did not start' + $detail)
    }

    $savedMonitor = Invoke-RestMethod -Uri ($base + '/api/playback/monitor') -Method Post -ContentType 'application/json' -Body (@{
        enabled = $true
        url = 'https://www.youtube.com/watch?v=test'
        open = $true
    } | ConvertTo-Json -Compress)
    Assert ($savedMonitor.ok -and $savedMonitor.monitor.enabled) 'WebUI must save the single-site monitor switch'
    Assert ($savedMonitor.monitor.host -eq 'www.youtube.com') 'WebUI must normalize the monitor host'
    Assert ($savedMonitor.monitor.tokenSet -and $savedMonitor.monitor.openAt) 'WebUI must generate a token and open request'
    $monitorToken = [string](Read-AfsJson (Join-Path $tmp 'src\playback-monitor.json')).token
    Assert ($monitorToken.Length -ge 16) 'Saved monitor token must be usable by the desktop shell'
    $clientId = 'em-api-test-client1'
    $body = @{
        clientId = $clientId
        token = $monitorToken
        tabs = @(@{tabId=77; host='www.youtube.com'; title='Background'; playing=$true; background=$true})
    } | ConvertTo-Json -Depth 5 -Compress
    $headers = @{ Origin = 'https://www.youtube.com' }
    $heartbeat = Invoke-RestMethod -Uri ($base + '/api/playback/embedded') -Method Post -ContentType 'text/plain; charset=utf-8' -Headers $headers -Body $body
    Assert ($heartbeat.ok -and @($heartbeat.closeTabs).Count -eq 0) 'Heartbeat must be accepted without exhausted rules'

    $quota = Invoke-RestMethod -Uri ($base + '/api/game-quota')
    Assert ($quota.playback.connected) 'WebUI must expose a connected embedded monitor'
    Assert ($quota.config.playback.enabled) 'Background playback must count toward website quotas by default'
    Assert (@($quota.playback.backgroundHosts) -contains 'www.youtube.com') 'WebUI must expose the background host'
    Assert (@($quota.playback.days).Count -eq 7) 'WebUI must expose the 7-day series'
    Assert ($quota.playback.monitor.enabled -and $quota.playback.monitor.host -eq 'www.youtube.com') 'WebUI must expose the single-site monitor config'

    $now = Get-Date
    $cfg = ConvertTo-AfsAppQuotaConfig @{enabled=$true; rules=@(
        @{type='website';name='youtube.com';dailyMinutes=10;days=@(1..7)}
    )}
    $state = Update-AfsAppQuotaState $null $cfg $now
    $state.targets['website:youtube.com'] = 600
    $state = Update-AfsAppQuotaState $state $cfg $now
    Write-AfsJson (Join-Path $tmp 'src\game-quota-config.json') $cfg
    Write-AfsJson (Join-Path $tmp 'src\game-quota-state.json') $state
    $heartbeat2 = Invoke-RestMethod -Uri ($base + '/api/playback/embedded') -Method Post -ContentType 'text/plain; charset=utf-8' -Headers $headers -Body $body
    Assert (@($heartbeat2.closeTabs).Count -eq 1 -and $heartbeat2.closeTabs[0] -eq 77) 'Exhausted rule must return the background tab for closing'

    $cfgOff = ConvertTo-AfsAppQuotaConfig @{enabled=$true; playback=@{enabled=$false}; rules=@(
        @{type='website';name='youtube.com';dailyMinutes=10;days=@(1..7)}
    )}
    Write-AfsJson (Join-Path $tmp 'src\game-quota-config.json') $cfgOff
    $heartbeat3 = Invoke-RestMethod -Uri ($base + '/api/playback/embedded') -Method Post -ContentType 'text/plain; charset=utf-8' -Headers $headers -Body $body
    Assert (@($heartbeat3.closeTabs).Count -eq 0) 'Switch off must stop closing background playback tabs'

    $badToken = $false
    $badTokenBody = @{
        clientId = $clientId
        token = 'wrong-token'
        tabs = @(@{tabId=78; host='www.youtube.com'; playing=$true; background=$true})
    } | ConvertTo-Json -Depth 5 -Compress
    try {
        $null = Invoke-WebRequest -Uri ($base + '/api/playback/embedded') -Method Post -ContentType 'text/plain; charset=utf-8' `
            -Headers $headers -Body $badTokenBody -UseBasicParsing
    } catch {
        $badToken = [int]$_.Exception.Response.StatusCode -eq 400
    }
    Assert $badToken 'A monitor request with the wrong token must be rejected'

    $badHost = $false
    $badHostBody = @{
        clientId = $clientId
        token = $monitorToken
        tabs = @(@{tabId=79; host='example.com'; playing=$true; background=$true})
    } | ConvertTo-Json -Depth 5 -Compress
    try {
        $null = Invoke-WebRequest -Uri ($base + '/api/playback/embedded') -Method Post -ContentType 'text/plain; charset=utf-8' `
            -Headers $headers -Body $badHostBody -UseBasicParsing
    } catch {
        $badHost = [int]$_.Exception.Response.StatusCode -eq 400
    }
    Assert $badHost 'A monitor request for a different host must be rejected'

    'PASS: embedded monitor heartbeat API, WebUI statistics and tab closing'
} finally {
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    if ($proc) { $proc.Dispose() }
    if (Test-Path -LiteralPath $tmp) {
        $resolved = [IO.Path]::GetFullPath($tmp)
        $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
        if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
