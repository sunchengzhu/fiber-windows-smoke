[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Dispatch-DailyRun.ps1')

function Assert-DispatchTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-DispatchFails {
    param([scriptblock]$Action, [string]$Message)
    $failed = $false
    try { & $Action | Out-Null }
    catch {
        $failed = $true
        if ($_.Exception.Message -notlike "*$Message*") { throw }
    }
    Assert-DispatchTest $failed "Expected failure containing '$Message'"
}

function Read-DailyDispatchToken {
    param([string]$Path)
    $script:tokenReads++
    return 'offline-fixture-token'
}

function Invoke-DailyDispatchApi {
    param([string]$Method, [string]$Uri, [string]$Token, [object]$Body)
    Assert-DispatchTest ($Token -ceq 'offline-fixture-token') 'Unexpected token passed to HTTP helper'
    $script:requests.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $Body })
    if ($Method -eq 'GET') {
        if ($script:badRunsResponse) { return [pscustomobject]@{ message = 'invalid fixture' } }
        if ($Uri -match '[?&]page=2(?:&|$)') { return [pscustomobject]@{ workflow_runs = @($script:secondPage) } }
        return [pscustomobject]@{ workflow_runs = @($script:firstPage) }
    }
    $statePath = Join-Path $script:caseDirectory '2026-10-19.json'
    $pending = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-DispatchTest ($pending.status -ceq 'pending') 'POST happened before pending state was saved'
    if ($script:postFailure) { throw 'Simulated transport timeout' }
    return $script:postResponse
}

function Reset-DispatchFixture {
    param([string]$Name)
    $script:caseDirectory = Join-Path $script:testRoot $Name
    $script:requests = New-Object 'System.Collections.Generic.List[object]'
    $script:tokenReads = 0
    $script:firstPage = @()
    $script:secondPage = @()
    $script:postResponse = $null
    $script:postFailure = $false
    $script:badRunsResponse = $false
}

function New-DispatchRun {
    param([long]$Id = 1234, [string]$Branch = 'main', [string]$Event = 'workflow_dispatch',
        [string]$Title = "Fiber Windows smoke $([char]0x00b7) 2026-10-19")
    return [pscustomobject]@{ id = $Id; head_branch = $Branch; event = $Event; display_title = $Title }
}

$script:testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('fiber-dispatch-test-' + [Guid]::NewGuid().ToString('N'))
$due = [DateTimeOffset]'2026-10-19T02:30:00Z'
try {
    Reset-DispatchFixture 'early'
    Invoke-DailyDispatch -StateDirectory $script:caseDirectory -Now ([DateTimeOffset]'2026-10-19T02:29:59Z') | Out-Null
    Assert-DispatchTest ($script:requests.Count -eq 0 -and $script:tokenReads -eq 0) 'Early run read a token or called GitHub'
    Assert-DispatchTest (-not (Test-Path -LiteralPath $script:caseDirectory)) 'Early run created state'

    Reset-DispatchFixture 'check'
    $message = Invoke-DailyDispatch -StateDirectory $script:caseDirectory -Now ([DateTimeOffset]'2026-10-19T00:00:00Z') -Check
    Assert-DispatchTest ($script:requests.Count -eq 1 -and $script:requests[0].Method -ceq 'GET') 'Check must make one read-only request'
    Assert-DispatchTest ($script:requests[0].Uri -ceq 'https://api.github.com/repos/sunchengzhu/fiber-windows-smoke/actions/workflows/fiber-node-maintenance.yml/runs?per_page=1') 'Check used an unexpected endpoint'
    Assert-DispatchTest ($message -like '*Write permission is not proven*') 'Check overstated token permission'
    Assert-DispatchTest (-not (Test-Path -LiteralPath $script:caseDirectory)) 'Check created dispatcher state'

    Reset-DispatchFixture 'accepted204'
    Invoke-DailyDispatch -StateDirectory $script:caseDirectory -Now $due | Out-Null
    Assert-DispatchTest ($script:requests.Count -eq 2 -and $script:requests[1].Method -ceq 'POST') 'Due run did not dispatch exactly once'
    $request = $script:requests[1]
    Assert-DispatchTest ($request.Uri -ceq 'https://api.github.com/repos/sunchengzhu/fiber-windows-smoke/actions/workflows/fiber-node-maintenance.yml/dispatches') 'Unexpected dispatch endpoint'
    Assert-DispatchTest ($request.Body.ref -ceq 'main' -and $request.Body.inputs.scheduled_date -ceq '2026-10-19') 'Unexpected dispatch ref or Beijing date'
    Assert-DispatchTest ($request.Body.inputs.send_discord_report -eq $true -and $request.Body.inputs.Count -eq 2) 'Dispatch inputs must contain date/report only'
    Assert-DispatchTest ($script:requests[0].Uri -like '*branch=main&event=workflow_dispatch*') 'Reconciliation must filter main dispatches'
    Assert-DispatchTest ($script:requests[0].Uri -like '*created=%3E%3D2026-10-19T02%3A30%3A00Z*') 'Created filter did not start at 10:30 Beijing time'
    $state = Get-Content -LiteralPath (Join-Path $script:caseDirectory '2026-10-19.json') -Raw | ConvertFrom-Json
    Assert-DispatchTest ($state.status -ceq 'accepted' -and $null -eq $state.run_id) 'HTTP 204 was not recorded as accepted'
    Invoke-DailyDispatch -StateDirectory $script:caseDirectory -Now $due.AddHours(3) | Out-Null
    Assert-DispatchTest ($script:requests.Count -eq 2 -and $script:tokenReads -eq 1) 'Accepted state did not avoid token/API access'
    Assert-DispatchTest (-not ([System.IO.File]::ReadAllText((Join-Path $script:caseDirectory '2026-10-19.json')).Contains('offline-fixture-token'))) 'Token leaked into state'

    Reset-DispatchFixture 'acceptedRunId'
    $script:postResponse = [pscustomobject]@{ workflow_run_id = [long]39182315640 }
    Invoke-DailyDispatch -StateDirectory $script:caseDirectory -Now $due | Out-Null
    $state = Get-Content -LiteralPath (Join-Path $script:caseDirectory '2026-10-19.json') -Raw | ConvertFrom-Json
    Assert-DispatchTest ($state.run_id -eq [long]39182315640 -and $state.status -ceq 'accepted') 'Dispatch run ID was not saved'

    Reset-DispatchFixture 'acceptedEmptyBody'
    $script:postResponse = ''
    Invoke-DailyDispatch -StateDirectory $script:caseDirectory -Now $due | Out-Null
    $state = Get-Content -LiteralPath (Join-Path $script:caseDirectory '2026-10-19.json') -Raw | ConvertFrom-Json
    Assert-DispatchTest ($state.status -ceq 'accepted' -and $null -eq $state.run_id) 'Empty HTTP 204 response was not accepted'

    Reset-DispatchFixture 'existing'
    $script:firstPage = @(
        (New-DispatchRun -Id 1 -Branch 'other'),
        (New-DispatchRun -Id 2 -Event 'schedule'),
        (New-DispatchRun -Id 3 -Title 'Fiber Windows smoke'),
        (New-DispatchRun -Id 4 -Title "Fiber Windows smoke $([char]0x00b7) 2026-10-18"),
        (New-DispatchRun -Id 5678)
    )
    Invoke-DailyDispatch -StateDirectory $script:caseDirectory -Now $due | Out-Null
    Assert-DispatchTest ($script:requests.Count -eq 1) 'Existing matching run caused another dispatch'
    $state = Get-Content -LiteralPath (Join-Path $script:caseDirectory '2026-10-19.json') -Raw | ConvertFrom-Json
    Assert-DispatchTest ($state.run_id -eq 5678) 'Wrong existing run was accepted'

    Reset-DispatchFixture 'wrongRunIdentity'
    $script:firstPage = @(
        (New-DispatchRun -Id 1 -Branch 'other'),
        (New-DispatchRun -Id 2 -Event 'schedule'),
        (New-DispatchRun -Id 3 -Title 'Fiber Windows smoke'),
        (New-DispatchRun -Id 4 -Title "Fiber Windows smoke $([char]0x00b7) 2026-10-18")
    )
    Invoke-DailyDispatch -StateDirectory $script:caseDirectory -Now $due | Out-Null
    Assert-DispatchTest ($script:requests.Count -eq 2 -and $script:requests[1].Method -ceq 'POST') 'Unrelated run suppressed the scheduled dispatch'

    Reset-DispatchFixture 'pagination'
    $script:firstPage = @(1..100 | ForEach-Object { New-DispatchRun -Id $_ -Title 'Other manual run' })
    $script:secondPage = @(New-DispatchRun -Id 9876)
    Invoke-DailyDispatch -StateDirectory $script:caseDirectory -Now $due | Out-Null
    Assert-DispatchTest ($script:requests.Count -eq 2 -and $script:requests[1].Uri -like '*&page=2') 'Reconciliation did not paginate'
    Assert-DispatchTest (@($script:requests | Where-Object { $_.Method -eq 'POST' }).Count -eq 0) 'Matching page two run caused a dispatch'

    Reset-DispatchFixture 'timeout'
    $script:postFailure = $true
    Assert-DispatchFails { Invoke-DailyDispatch -StateDirectory $script:caseDirectory -Now $due } 'Simulated transport timeout'
    $state = Get-Content -LiteralPath (Join-Path $script:caseDirectory '2026-10-19.json') -Raw | ConvertFrom-Json
    Assert-DispatchTest ($state.status -ceq 'pending') 'Transport failure did not retain pending state'
    $script:postFailure = $false
    Assert-DispatchFails { Invoke-DailyDispatch -StateDirectory $script:caseDirectory -Now $due.AddMinutes(5) } 'Pending state retained'
    Assert-DispatchTest (@($script:requests | Where-Object { $_.Method -eq 'POST' }).Count -eq 1) 'Pending dispatch was blindly retried'
    $script:firstPage = @(New-DispatchRun -Id 4567)
    Invoke-DailyDispatch -StateDirectory $script:caseDirectory -Now $due.AddMinutes(10) | Out-Null
    $state = Get-Content -LiteralPath (Join-Path $script:caseDirectory '2026-10-19.json') -Raw | ConvertFrom-Json
    Assert-DispatchTest ($state.status -ceq 'accepted' -and $state.run_id -eq 4567) 'Pending dispatch did not reconcile'

    Reset-DispatchFixture 'unexpectedResponse'
    $script:postResponse = [pscustomobject]@{ message = 'unexpected' }
    Assert-DispatchFails { Invoke-DailyDispatch -StateDirectory $script:caseDirectory -Now $due } 'Unexpected dispatch response'
    $script:postResponse = $null
    Assert-DispatchFails { Invoke-DailyDispatch -StateDirectory $script:caseDirectory -Now $due } 'Pending state retained'
    Assert-DispatchTest (@($script:requests | Where-Object { $_.Method -eq 'POST' }).Count -eq 1) 'Unexpected POST response led to a repeated dispatch'

    Reset-DispatchFixture 'badRuns'
    $script:badRunsResponse = $true
    Assert-DispatchFails { Invoke-DailyDispatch -StateDirectory $script:caseDirectory -Now $due } 'Unexpected workflow-runs API response'
    Assert-DispatchTest (@($script:requests | Where-Object { $_.Method -eq 'POST' }).Count -eq 0) 'Malformed run response allowed a dispatch'

    Reset-DispatchFixture 'badRunId'
    $script:firstPage = @(New-DispatchRun -Id 0)
    Assert-DispatchFails { Invoke-DailyDispatch -StateDirectory $script:caseDirectory -Now $due } 'Matched daily run has no valid ID'
    Assert-DispatchTest (@($script:requests | Where-Object { $_.Method -eq 'POST' }).Count -eq 0) 'Malformed matching run ID allowed a dispatch'

    Reset-DispatchFixture 'invalidState'
    [System.IO.Directory]::CreateDirectory($script:caseDirectory) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $script:caseDirectory '2026-10-19.json'), '{"date":"2026-10-18","status":"accepted"}')
    Assert-DispatchFails { Invoke-DailyDispatch -StateDirectory $script:caseDirectory -Now $due } 'Invalid daily state'
    Assert-DispatchTest ($script:requests.Count -eq 0 -and $script:tokenReads -eq 0) 'Invalid state allowed token/API access'

    Reset-DispatchFixture 'locked'
    [System.IO.Directory]::CreateDirectory($script:caseDirectory) | Out-Null
    $heldLock = [System.IO.File]::Open((Join-Path $script:caseDirectory 'dispatch.lock'),
        [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $message = Invoke-DailyDispatch -StateDirectory $script:caseDirectory -Now $due
        Assert-DispatchTest ($message -like '*holds the state lock*') 'Concurrent dispatcher did not respect the lock'
        Assert-DispatchTest ($script:requests.Count -eq 0 -and $script:tokenReads -eq 0) 'Concurrent dispatcher read a token or called GitHub'
    }
    finally { $heldLock.Dispose() }

    Reset-DispatchFixture 'beijingDate'
    Invoke-DailyDispatch -StateDirectory $script:caseDirectory -Now ([DateTimeOffset]'2026-10-19T16:30:00Z') | Out-Null
    Assert-DispatchTest ($script:requests.Count -eq 0 -and $script:tokenReads -eq 0) 'UTC evening was not treated as the next Beijing morning'

    $logDirectory = Join-Path $script:testRoot 'logging'
    Write-DailyDispatchLog -Directory $logDirectory -Message "First line`ncontinued"
    $logPath = Join-Path $logDirectory 'dispatcher.log'
    $logText = [System.IO.File]::ReadAllText($logPath)
    Assert-DispatchTest ($logText -match '^\d{4}-\d{2}-\d{2}T.*\+00:00 First line continued') 'Log must contain a UTC timestamp and one-line result'
    [System.IO.File]::WriteAllText($logPath, ('x' * 1MB))
    Write-DailyDispatchLog -Directory $logDirectory -Message 'After rotation'
    Assert-DispatchTest ([System.IO.File]::Exists("$logPath.1") -and (Get-Item -LiteralPath $logPath).Length -lt 1MB) 'Log rotation did not bound the active log'

    # A nested PowerShell script's exit 1 sets LASTEXITCODE without throwing.
    # Exercise the actual installer preflight so it cannot enable the task
    # after that failure. Extract only this helper to avoid Windows task/ACL APIs.
    $installerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Install-DailySchedule.ps1'
    $tokens = $null
    $parseErrors = $null
    $installerAst = [System.Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw 'Cannot parse scheduler installer' }
    $preflight = $installerAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DailySchedulePreflight'
    }, $true)
    . ([scriptblock]::Create($preflight.Extent.Text))
    $fixtureDispatcher = Join-Path $script:testRoot 'preflight.ps1'
    [System.IO.File]::WriteAllText($fixtureDispatcher, 'param($StateDirectory, $TokenPath, [switch]$Check); exit 1')
    Assert-DispatchFails {
        Invoke-DailySchedulePreflight -DispatcherPath $fixtureDispatcher -StateDirectory $script:testRoot -TokenPath 'offline-token'
    } 'Dispatcher preflight failed'
    [System.IO.File]::WriteAllText($fixtureDispatcher, 'param($StateDirectory, $TokenPath, [switch]$Check); return')
    Invoke-DailySchedulePreflight -DispatcherPath $fixtureDispatcher -StateDirectory $script:testRoot -TokenPath 'offline-token'
    $global:LASTEXITCODE = 0

    Write-Host 'Daily dispatch offline checks passed'
}
finally {
    if (Test-Path -LiteralPath $script:testRoot) { Remove-Item -LiteralPath $script:testRoot -Recurse -Force }
}
