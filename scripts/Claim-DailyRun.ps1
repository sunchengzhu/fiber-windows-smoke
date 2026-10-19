[CmdletBinding()]
param(
    [string]$StateDirectory = "C:\fiber-node\automation\daily-executions"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "DailySchedule.psm1") -Force

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_WORKSPACE)) {
    $workspacePath = [System.IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd([char[]]"\/")
    $statePath = [System.IO.Path]::GetFullPath($StateDirectory).TrimEnd([char[]]"\/")
    if ([string]::Equals($statePath, $workspacePath, [System.StringComparison]::OrdinalIgnoreCase) -or
            $statePath.StartsWith($workspacePath + [System.IO.Path]::DirectorySeparatorChar,
                [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Daily execution state must be stored outside GITHUB_WORKSPACE."
    }
}
if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    throw "GITHUB_OUTPUT is required to publish the daily execution decision."
}

$createdAt = ""
if ($env:GITHUB_EVENT_NAME -ceq "schedule") {
    if ($env:GITHUB_REPOSITORY -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
            $env:GITHUB_RUN_ID -notmatch '^[1-9][0-9]*$' -or
            [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        throw "Scheduled runs require GITHUB_REPOSITORY, GITHUB_RUN_ID, and a read-only GITHUB_TOKEN lookup."
    }
    $headers = @{
        Accept = "application/vnd.github+json"
        Authorization = "Bearer $env:GITHUB_TOKEN"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $uri = "https://api.github.com/repos/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
        $run = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -UserAgent "fiber-windows-smoke-daily-gate" -TimeoutSec 60
        if ($run.created_at -is [DateTimeOffset]) {
            $createdAt = $run.created_at.ToString("o", [System.Globalization.CultureInfo]::InvariantCulture)
        }
        elseif ($run.created_at -is [DateTime]) {
            $createdAt = $run.created_at.ToUniversalTime().ToString("o", [System.Globalization.CultureInfo]::InvariantCulture)
        }
        else {
            $createdAt = [string]$run.created_at
        }
    }
    catch {
        throw "Cannot read the GitHub run creation time; daily execution was not claimed."
    }
    finally {
        $headers.Clear()
    }
}

$result = Get-FiberDailyClaim -EventName $env:GITHUB_EVENT_NAME -ScheduledDate ([string]$env:SCHEDULED_DATE) `
    -Ref ([string]$env:GITHUB_REF) -RunId ([string]$env:GITHUB_RUN_ID) `
    -StateDirectory $StateDirectory -RunCreatedAt $createdAt
foreach ($name in @("should_run", "is_daily", "scheduled_date", "reason")) {
    "$name=$($result.$name)" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
}
Write-Host $result.reason
