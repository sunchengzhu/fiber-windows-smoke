[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) "scripts\DailySchedule.psm1") -Force

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "fiber-daily-claim-$([Guid]::NewGuid().ToString('N'))"
$script:assertions = 0
$due = [DateTimeOffset]::Parse("2026-10-19T02:30:00Z")

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    $script:assertions++
    if ($Actual -cne $Expected) { throw "$Message; expected '$Expected', got '$Actual'." }
}

function Assert-Fails {
    param([scriptblock]$Action, [string]$ExpectedMessage = "")
    $script:assertions++
    try {
        & $Action | Out-Null
    }
    catch {
        if ($ExpectedMessage -and $_.Exception.Message -notlike "*$ExpectedMessage*") {
            throw "Expected error '$ExpectedMessage', got '$($_.Exception.Message)'."
        }
        return
    }
    throw "Expected the action to fail: $ExpectedMessage"
}

function Get-TestClaim {
    param([string]$Case, [hashtable]$Override = @{})
    $arguments = @{
        EventName = "workflow_dispatch"
        ScheduledDate = "2026-10-19"
        Ref = "refs/heads/main"
        RunId = "100"
        StateDirectory = (Join-Path $testRoot $Case)
        Now = $due
    }
    foreach ($key in $Override.Keys) { $arguments[$key] = $Override[$key] }
    return Get-FiberDailyClaim @arguments
}

try {
    # Ordinary manual runs neither require main nor consume a daily slot.
    $manual = Get-TestClaim "manual" @{ ScheduledDate = ""; Ref = "refs/heads/test"; RunId = "" }
    Assert-Equal $manual.should_run "true" "Manual run should execute"
    Assert-Equal $manual.is_daily "false" "Manual run should retain manual payment semantics"
    Assert-Equal $manual.scheduled_date "" "Manual run should have no daily date"
    Assert-Equal (Test-Path (Join-Path $testRoot "manual")) $false "Manual run should not write state"
    Assert-Equal (Get-TestClaim "manual").should_run "true" "A manual run should not suppress the daily run"

    $early = Get-TestClaim "boundary" @{ Now = $due.AddTicks(-1) }
    Assert-Equal $early.should_run "false" "Daily run must wait until exactly 10:30 Beijing"
    Assert-Equal $early.is_daily "true" "Skipped daily run should retain daily classification"
    Assert-Equal (Test-Path (Join-Path $testRoot "boundary")) $false "Early trigger should not consume a slot"
    $onTime = Get-TestClaim "boundary"
    Assert-Equal $onTime.should_run "true" "Daily run should start at exactly 10:30 Beijing"
    Assert-Equal $onTime.scheduled_date "2026-10-19" "Daily date should use Beijing time"
    $claimPath = Join-Path (Join-Path $testRoot "boundary") "2026-10-19.json"
    $originalClaim = [System.IO.File]::ReadAllText($claimPath)
    Assert-Equal (Get-TestClaim "boundary" @{ RunId = "101" }).should_run "false" "Another run must not repeat payments"
    Assert-Equal (Get-TestClaim "boundary").should_run "true" "Explicit same-run rerun should execute"
    Assert-Equal ([System.IO.File]::ReadAllText($claimPath)) $originalClaim "Rerun should preserve original claim"
    Assert-Equal (Get-TestClaim "boundary" @{ ScheduledDate = "2026-10-20"; Now = $due.AddDays(1); RunId = "102" }).should_run "true" "The next day should have an independent slot"

    Assert-Equal (Get-TestClaim "offset" @{ Now = [DateTimeOffset]::Parse("2026-10-18T22:30:00-04:00") }).should_run "true" "Now should be converted to Beijing independently of its input offset"
    foreach ($day in @("2026-10-18", "2026-10-20")) {
        $case = "date-$day"
        Assert-Equal (Get-TestClaim $case @{ ScheduledDate = $day }).should_run "false" "Stale or future dated dispatch should skip"
        Assert-Equal (Test-Path (Join-Path $testRoot $case)) $false "Skipped dated dispatch should not write state"
    }
    foreach ($day in @("20261019", "2026-1-19", "2026-10-9", "2026-02-30", "../bad", " ", "2026-10-19 ")) {
        Assert-Fails { Get-TestClaim "invalid-date" @{ ScheduledDate = $day } } "yyyy-MM-dd"
    }
    Assert-Fails { Get-TestClaim "bad-ref" @{ Ref = "refs/heads/develop" } } "refs/heads/main"
    Assert-Fails { Get-TestClaim "bad-ref-case" @{ Ref = "refs/heads/Main" } } "refs/heads/main"
    foreach ($id in @("", "0", "-1", "1.0", "../bad")) {
        Assert-Fails { Get-TestClaim "bad-id" @{ RunId = $id } } "GitHub run ID"
    }
    Assert-Fails { Get-TestClaim "bad-event" @{ EventName = "push" } } "Unsupported"

    # GitHub's fallback must share the dispatch claim and retain its own
    # creation date across runner queues, reruns, and local timezone changes.
    $schedule = @{ EventName = "schedule"; ScheduledDate = ""; RunCreatedAt = "2026-10-19T02:47:00Z"; Now = $due.AddMinutes(17) }
    Assert-Equal (Get-TestClaim "schedule" $schedule).should_run "true" "Same-day GitHub fallback should execute"
    $schedule.RunId = "200"
    Assert-Equal (Get-TestClaim "schedule" $schedule).should_run "false" "Duplicate fallback should skip"
    Assert-Equal (Get-TestClaim "schedule" @{ RunId = "201"; Now = $due.AddMinutes(18) }).should_run "false" "Server dispatch must share the fallback claim"
    $schedule.RunId = "100"
    Assert-Equal (Get-TestClaim "schedule" $schedule).should_run "true" "Same-day fallback rerun should execute"
    $schedule.Now = $due.AddDays(1).AddMinutes(17)
    Assert-Equal (Get-TestClaim "schedule" $schedule).should_run "false" "Old fallback rerun must not claim the following day"
    Assert-Equal (Get-TestClaim "schedule-queued" $schedule).should_run "false" "Cross-day queued fallback must skip even without prior state"
    Assert-Equal (Test-Path (Join-Path $testRoot "schedule-queued")) $false "Cross-day fallback must not write state"
    $schedule.Now = $due.AddMinutes(17)
    $schedule.RunCreatedAt = "2026-10-20T02:47:00Z"
    Assert-Equal (Get-TestClaim "schedule-future" $schedule).should_run "false" "Future fallback creation date should skip"
    $schedule.RunCreatedAt = "2026-10-19T02:29:59Z"
    Assert-Equal (Get-TestClaim "schedule-early-created" $schedule).should_run "false" "A pre-10:30 created fallback must not claim later"
    $schedule.RunCreatedAt = "2026-10-19T02:30:00Z"
    $schedule.Now = $due
    Assert-Equal (Get-TestClaim "schedule-boundary" $schedule).should_run "true" "A fallback created exactly at 10:30 should execute"
    $schedule.RunCreatedAt = "2026-10-18T22:47:00-04:00"
    $schedule.Now = $due.AddMinutes(17)
    Assert-Equal (Get-TestClaim "schedule-offset" $schedule).scheduled_date "2026-10-19" "Schedule date must use the creation timestamp's Beijing date"
    foreach ($timestamp in @("", "bad", "2026-10-19T02:47:00", "2026-02-30T02:47:00Z")) {
        $schedule.RunCreatedAt = $timestamp
        Assert-Fails { Get-TestClaim "schedule-invalid-created" $schedule } "creation timestamp"
    }
    $schedule.RunCreatedAt = "2026-10-19T02:47:00Z"
    $schedule.RunId = "200"
    Assert-Equal (Get-TestClaim "boundary" $schedule).should_run "false" "Fallback must skip after server dispatch claimed the date"

    # Never replace a malformed or inconsistent prior record to force retries.
    $badRecords = @(
        "broken-json",
        "null",
        "[]",
        "{}",
        '{"scheduled_date":"2026-10-19","run_id":100,"claimed_at":"2026-10-19T10:30:00+08:00"}',
        '{"scheduled_date":"2026-10-18","run_id":"100","claimed_at":"2026-10-19T10:30:00+08:00"}',
        '{"scheduled_date":"2026-10-19","run_id":"100","claimed_at":"bad"}',
        '{"scheduled_date":"2026-10-19","run_id":"100","claimed_at":"2026-10-19T10:30:00"}',
        '{"scheduled_date":"2026-10-19","run_id":"100","claimed_at":"2026-10-18T10:30:00+08:00"}',
        '{"scheduled_date":"2026-10-19","run_id":"100","claimed_at":"2026-10-19T10:29:59+08:00"}'
    )
    for ($index = 0; $index -lt $badRecords.Count; $index++) {
        $case = "bad-state-$index"
        $directory = Join-Path $testRoot $case
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
        $path = Join-Path $directory "2026-10-19.json"
        [System.IO.File]::WriteAllText($path, $badRecords[$index])
        Assert-Fails { Get-TestClaim $case } "Invalid daily execution state"
        Assert-Equal ([System.IO.File]::ReadAllText($path)) $badRecords[$index] "Bad state should remain available for review"
    }

    $lockedDirectory = Join-Path $testRoot "locked"
    [System.IO.Directory]::CreateDirectory($lockedDirectory) | Out-Null
    $heldLock = [System.IO.File]::Open((Join-Path $lockedDirectory "claim.lock"),
        [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        Assert-Fails { Get-TestClaim "locked" }
        Assert-Equal (Test-Path (Join-Path $lockedDirectory "2026-10-19.json")) $false "A locked state directory should not produce a claim"
    }
    finally { $heldLock.Dispose() }
    Assert-Equal (Get-TestClaim "locked").should_run "true" "The claim should work after the exclusive lock is released"

    # Exercise the workflow wrapper without network access or Python.
    $environmentNames = @("GITHUB_EVENT_NAME", "SCHEDULED_DATE", "GITHUB_REF", "GITHUB_RUN_ID",
        "GITHUB_WORKSPACE", "GITHUB_OUTPUT", "GITHUB_TOKEN", "GITHUB_REPOSITORY")
    $originalEnvironment = @{}
    foreach ($name in $environmentNames) { $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process") }
    $wrapper = Join-Path (Split-Path -Parent $PSScriptRoot) "scripts\Claim-DailyRun.ps1"
    $mockState = [pscustomobject]@{ RequestCount = 0; RequestFails = $false; CreatedAt = [DateTimeOffset]::UtcNow.AddDays(-1) }
    function Invoke-RestMethod {
        param($Method, $Uri, $Headers, $UserAgent, $TimeoutSec)
        $mockState.RequestCount++
        if ($Method -cne "Get" -or $Uri -cne "https://api.github.com/repos/offline/example/actions/runs/300" -or
                $Headers.Authorization -cne "Bearer offline-test-token") {
            throw "Unexpected GitHub API request."
        }
        if ($mockState.RequestFails) { throw "offline API failure" }
        return [pscustomobject]@{ created_at = $mockState.CreatedAt }
    }
    try {
        $env:GITHUB_EVENT_NAME = "workflow_dispatch"
        $env:SCHEDULED_DATE = ""
        $env:GITHUB_REF = "refs/heads/test"
        $env:GITHUB_RUN_ID = "300"
        $env:GITHUB_WORKSPACE = Join-Path $testRoot "checkout"
        $env:GITHUB_OUTPUT = Join-Path $testRoot "wrapper-output.txt"
        $env:GITHUB_TOKEN = "offline-test-token"
        $env:GITHUB_REPOSITORY = "offline/example"
        $wrapperState = Join-Path $testRoot "wrapper-state"
        & $wrapper -StateDirectory $wrapperState
        Assert-Equal $mockState.RequestCount 0 "Manual runs should never call the GitHub API"
        $wrapperOutput = [System.IO.File]::ReadAllText($env:GITHUB_OUTPUT)
        Assert-Equal ($wrapperOutput -match '(?m)^should_run=true\r?$') $true "Wrapper should publish the manual decision"
        Assert-Equal ($wrapperOutput -match '(?m)^is_daily=false\r?$') $true "Wrapper should publish manual classification"
        Assert-Equal ($wrapperOutput.Contains($env:GITHUB_TOKEN)) $false "Wrapper outputs must not contain credentials"
        Assert-Fails { & $wrapper -StateDirectory (Join-Path $env:GITHUB_WORKSPACE "state") } "outside GITHUB_WORKSPACE"

        $env:GITHUB_EVENT_NAME = "schedule"
        $env:GITHUB_REF = "refs/heads/main"
        # A stale timestamp is deterministic at any execution time, and a
        # DateTimeOffset response covers PowerShell's JSON date coercion.
        [System.IO.File]::WriteAllText($env:GITHUB_OUTPUT, "")
        & $wrapper -StateDirectory $wrapperState
        Assert-Equal $mockState.RequestCount 1 "Scheduled wrapper should fetch the run creation time once"
        $wrapperOutput = [System.IO.File]::ReadAllText($env:GITHUB_OUTPUT)
        Assert-Equal ($wrapperOutput -match '(?m)^should_run=false\r?$') $true "Stale wrapper run should skip"
        Assert-Equal ($wrapperOutput -match '(?m)^is_daily=true\r?$') $true "Scheduled wrapper should retain daily classification"
        Assert-Equal (Test-Path $wrapperState) $false "Stale wrapper run should not consume state"
        $mockState.RequestFails = $true
        Assert-Fails { & $wrapper -StateDirectory $wrapperState } "Cannot read the GitHub run creation time"
        Assert-Equal (Test-Path $wrapperState) $false "API failure must not claim execution"
    }
    finally {
        foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], "Process") }
    }

    Write-Host "Daily schedule checks passed ($script:assertions assertions)"
}
finally {
    if (Test-Path $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
