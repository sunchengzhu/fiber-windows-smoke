Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-FiberDailyClaim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$EventName,
        [AllowEmptyString()]
        [string]$ScheduledDate = "",
        [AllowEmptyString()]
        [string]$Ref = "",
        [AllowEmptyString()]
        [string]$RunId = "",
        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,
        [AllowEmptyString()]
        [string]$RunCreatedAt = ""
    )

    if ($EventName -ceq "workflow_dispatch" -and $ScheduledDate -ceq "") {
        return [pscustomobject]@{
            should_run = "true"
            is_daily = "false"
            scheduled_date = ""
            reason = "Manual run; daily execution claim not used."
        }
    }
    if ($EventName -cnotin @("schedule", "workflow_dispatch")) {
        throw "Unsupported daily execution trigger: $EventName"
    }
    if ($Ref -cne "refs/heads/main") {
        throw "Daily runs must use refs/heads/main."
    }

    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $beijingOffset = [TimeSpan]::FromHours(8)
    $localNow = $Now.ToOffset($beijingOffset)
    $createdTooEarly = $false
    if ($EventName -ceq "schedule") {
        # A queued GitHub fallback belongs to its creation day, even if the
        # Windows runner does not become available until a later date.
        if ($RunCreatedAt -notmatch '^\d{4}-\d{2}-\d{2}T.+(?:Z|[+-]\d{2}:\d{2})$') {
            throw "Scheduled runs require a valid GitHub run creation timestamp with a timezone."
        }
        try {
            $created = [DateTimeOffset]::Parse($RunCreatedAt, $culture).ToOffset($beijingOffset)
        }
        catch {
            throw "Scheduled runs require a valid GitHub run creation timestamp with a timezone."
        }
        $day = $created.ToString("yyyy-MM-dd", $culture)
        $createdTooEarly = $created.TimeOfDay -lt [TimeSpan]::FromMinutes(630)
    }
    else {
        $parsedDay = [DateTime]::MinValue
        if (-not [DateTime]::TryParseExact($ScheduledDate, "yyyy-MM-dd", $culture,
                [System.Globalization.DateTimeStyles]::None, [ref]$parsedDay)) {
            throw "scheduled_date must use yyyy-MM-dd."
        }
        $day = $parsedDay.ToString("yyyy-MM-dd", $culture)
    }

    $result = [pscustomobject]@{
        should_run = "false"
        is_daily = "true"
        scheduled_date = $day
        reason = ""
    }
    if ($day -cne $localNow.ToString("yyyy-MM-dd", $culture) -or
            $localNow.TimeOfDay -lt [TimeSpan]::FromMinutes(630) -or $createdTooEarly) {
        $result.reason = "Not due today; skip a stale, future, or pre-10:30 Asia/Shanghai trigger."
        return $result
    }
    if ($RunId -notmatch '^[1-9][0-9]*$') {
        throw "Daily runs require a valid GitHub run ID."
    }

    [System.IO.Directory]::CreateDirectory($StateDirectory) | Out-Null
    $lockPath = Join-Path $StateDirectory "claim.lock"
    $recordPath = Join-Path $StateDirectory "$day.json"
    $lock = $null
    $temporaryPath = $null
    try {
        # The lock is shared across runner processes and survives checkout
        # cleanup. Contention or corrupt state fails closed before payments.
        $lock = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        if ([System.IO.File]::Exists($recordPath)) {
            try {
                $json = [System.IO.File]::ReadAllText($recordPath)
                # PowerShell 7.5+ otherwise coerces ISO strings to DateTime;
                # Windows PowerShell 5.1 retains the original JSON strings.
                if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey("DateKind")) {
                    $prior = $json | ConvertFrom-Json -DateKind String
                }
                else {
                    $prior = $json | ConvertFrom-Json
                }
                if ($null -eq $prior -or $prior -is [array] -or
                        $prior.PSObject.Properties.Name -notcontains "scheduled_date" -or
                        $prior.PSObject.Properties.Name -notcontains "run_id" -or
                        $prior.PSObject.Properties.Name -notcontains "claimed_at" -or
                        $prior.scheduled_date -isnot [string] -or $prior.scheduled_date -cne $day -or
                        $prior.run_id -isnot [string] -or $prior.run_id -notmatch '^[1-9][0-9]*$' -or
                        $prior.claimed_at -isnot [string] -or
                        $prior.claimed_at -notmatch '^\d{4}-\d{2}-\d{2}T.+(?:Z|[+-]\d{2}:\d{2})$') {
                    throw "Invalid claim fields."
                }
                $priorTime = [DateTimeOffset]::Parse($prior.claimed_at, $culture).ToOffset($beijingOffset)
                if ($priorTime.ToString("yyyy-MM-dd", $culture) -cne $day -or
                        $priorTime.TimeOfDay -lt [TimeSpan]::FromMinutes(630)) {
                    throw "Invalid claim timestamp."
                }
            }
            catch {
                throw "Invalid daily execution state in '$recordPath'; review the matching GitHub run before retrying."
            }
            if ($prior.run_id -cne $RunId) {
                $result.reason = "Already claimed by run $($prior.run_id); no maintenance or payments repeated."
                return $result
            }
        }
        else {
            $temporaryPath = Join-Path $StateDirectory "$day.$([Guid]::NewGuid().ToString('N')).tmp"
            $record = @{
                scheduled_date = $day
                run_id = $RunId
                claimed_at = $localNow.ToString("o", $culture)
            } | ConvertTo-Json -Compress
            $stream = $null
            try {
                $stream = [System.IO.File]::Open($temporaryPath, [System.IO.FileMode]::CreateNew,
                    [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($record)
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush($true)
            }
            finally {
                if ($null -ne $stream) { $stream.Dispose() }
            }
            # Rename within the same directory publishes a complete claim;
            # the two-argument Move deliberately never overwrites a claim.
            [System.IO.File]::Move($temporaryPath, $recordPath)
        }
        $result.should_run = "true"
        $result.reason = "Daily execution claimed by run $RunId."
        return $result
    }
    finally {
        if ($null -ne $temporaryPath -and [System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
        if ($null -ne $lock) { $lock.Dispose() }
    }
}

Export-ModuleMember -Function Get-FiberDailyClaim
