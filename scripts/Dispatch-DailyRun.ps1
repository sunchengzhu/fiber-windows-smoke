[CmdletBinding()]
param(
    [string]$StateDirectory = 'C:\fiber-node\automation\daily-dispatch',
    [string]$TokenPath = 'C:\fiber-node\automation\daily-dispatch\github-token.dpapi',
    [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DailyDispatchProperty {
    param([object]$Object, [string]$Name)
    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) {
        # Preserve empty and single-item API arrays across the function boundary.
        return ,($Object.$Name)
    }
    return $null
}

function Test-DailyDispatchRunId {
    param([object]$Value)
    return ($Value -is [int] -or $Value -is [long] -or $Value -is [uint32] -or $Value -is [uint64]) -and
        $Value -gt 0 -and $Value -le [long]::MaxValue
}

function Read-DailyDispatchToken {
    param([Parameter(Mandatory = $true)][string]$Path)
    $plaintext = $null
    try {
        Add-Type -AssemblyName System.Security
        $encrypted = [System.IO.File]::ReadAllBytes($Path)
        $plaintext = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $encrypted, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        $token = [System.Text.Encoding]::UTF8.GetString($plaintext).Trim()
        if ([string]::IsNullOrWhiteSpace($token)) { throw 'Empty token' }
        return $token
    }
    catch {
        throw 'Cannot read or decrypt the dispatcher token. Run the dispatcher installer again with a valid token.'
    }
    finally {
        if ($null -ne $plaintext) { [Array]::Clear($plaintext, 0, $plaintext.Length) }
    }
}

function Invoke-DailyDispatchApi {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Token,
        [object]$Body
    )
    $headers = @{
        Accept = 'application/vnd.github+json'
        Authorization = "Bearer $Token"
        'User-Agent' = 'fiber-windows-smoke-daily-dispatch'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $request = @{
        Method = $Method
        Uri = $Uri
        Headers = $headers
        UseBasicParsing = $true
        TimeoutSec = 60
        ErrorAction = 'Stop'
    }
    if ($Method -eq 'POST') {
        $request.ContentType = 'application/json'
        $request.Body = $Body | ConvertTo-Json -Depth 5 -Compress
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        return Invoke-RestMethod @request
    }
    catch {
        # Do not print response bodies, headers, or exception details: a token
        # must never appear in task history or the scheduled task's output.
        $response = Get-DailyDispatchProperty -Object $_.Exception -Name 'Response'
        $status = Get-DailyDispatchProperty -Object $response -Name 'StatusCode'
        $detail = if ($null -ne $status) { " (HTTP $([int]$status))" } else { '' }
        throw "GitHub API $Method failed$detail. Check connectivity and the configured token; an uncertain dispatch is never retried automatically."
    }
}

function Save-DailyDispatchState {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$State)
    $temporary = Join-Path (Split-Path -Parent $Path) ('.dispatch-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $previous = "$temporary.previous"
    $stream = $null
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($State | ConvertTo-Json -Depth 5 -Compress))
        $stream = [System.IO.File]::Open($temporary, [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        if ([System.IO.File]::Exists($Path)) {
            [System.IO.File]::Replace($temporary, $Path, $previous)
        }
        else {
            [System.IO.File]::Move($temporary, $Path)
        }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
        if ([System.IO.File]::Exists($previous)) { [System.IO.File]::Delete($previous) }
    }
}

function Find-DailyDispatchRun {
    param([Parameter(Mandatory = $true)][string]$Date, [Parameter(Mandatory = $true)][string]$Token)
    $since = [DateTimeOffset]::ParseExact("${Date}T10:30:00+08:00", "yyyy-MM-dd'T'HH:mm:sszzz",
        [System.Globalization.CultureInfo]::InvariantCulture)
    $created = [Uri]::EscapeDataString('>=' + $since.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))
    $expectedTitle = "Fiber Windows smoke $([char]0x00b7) $Date"
    $page = 1
    while ($true) {
        $uri = "https://api.github.com/repos/sunchengzhu/fiber-windows-smoke/actions/workflows/fiber-node-maintenance.yml/runs?branch=main&event=workflow_dispatch&per_page=100&created=$created&page=$page"
        $response = Invoke-DailyDispatchApi -Method GET -Uri $uri -Token $Token
        $runs = Get-DailyDispatchProperty -Object $response -Name 'workflow_runs'
        if ($null -eq $runs -or $runs -isnot [Array]) {
            throw 'Unexpected workflow-runs API response; refusing to dispatch.'
        }
        foreach ($run in $runs) {
            if ($null -eq $run -or $run -isnot [pscustomobject]) {
                throw 'Invalid workflow run in API response; refusing to dispatch.'
            }
            if ((Get-DailyDispatchProperty $run 'head_branch') -ceq 'main' -and
                (Get-DailyDispatchProperty $run 'event') -ceq 'workflow_dispatch' -and
                (Get-DailyDispatchProperty $run 'display_title') -ceq $expectedTitle) {
                $id = Get-DailyDispatchProperty $run 'id'
                if (-not (Test-DailyDispatchRunId $id)) { throw 'Matched daily run has no valid ID; refusing to dispatch.' }
                return [long]$id
            }
        }
        if ($runs.Count -lt 100) { return $null }
        $page++
    }
}

function Invoke-DailyDispatch {
    [CmdletBinding()]
    param(
        [string]$StateDirectory = 'C:\fiber-node\automation\daily-dispatch',
        [string]$TokenPath = 'C:\fiber-node\automation\daily-dispatch\github-token.dpapi',
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow,
        [switch]$Check
    )
    $token = $null
    $lock = $null
    try {
        if ($Check) {
            $token = Read-DailyDispatchToken -Path $TokenPath
            $response = Invoke-DailyDispatchApi -Method GET -Token $token -Uri 'https://api.github.com/repos/sunchengzhu/fiber-windows-smoke/actions/workflows/fiber-node-maintenance.yml/runs?per_page=1'
            $runs = Get-DailyDispatchProperty $response 'workflow_runs'
            if ($null -eq $runs -or $runs -isnot [Array]) { throw 'Unexpected workflow-runs API response.' }
            return 'Preflight passed: the token can read workflow runs; no dispatch sent. Write permission is not proven.'
        }

        $beijingNow = $Now.ToOffset([TimeSpan]::FromHours(8))
        $date = $beijingNow.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        if ($beijingNow.Hour * 60 + $beijingNow.Minute -lt 630) {
            return 'Not due: daily smoke starts at 10:30 Asia/Shanghai.'
        }
        [System.IO.Directory]::CreateDirectory($StateDirectory) | Out-Null
        try {
            $lock = [System.IO.File]::Open((Join-Path $StateDirectory 'dispatch.lock'),
                [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        }
        catch [System.IO.IOException] {
            return 'Another dispatcher holds the state lock; no request sent.'
        }
        $path = Join-Path $StateDirectory "$date.json"
        $state = $null
        if ([System.IO.File]::Exists($path)) {
            try { $state = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json }
            catch { throw 'Invalid daily state; review it before dispatching.' }
            if ($null -eq $state -or $state -isnot [pscustomobject] -or
                (Get-DailyDispatchProperty $state 'date') -cne $date -or
                (Get-DailyDispatchProperty $state 'status') -cnotin @('pending', 'accepted')) {
                throw 'Invalid daily state; review it before dispatching.'
            }
            if ($state.status -ceq 'accepted') { return "Already accepted for ${date}; no request sent." }
        }

        $token = Read-DailyDispatchToken -Path $TokenPath
        $runId = Find-DailyDispatchRun -Date $date -Token $token
        if ($null -ne $runId) {
            Save-DailyDispatchState -Path $path -State @{ date = $date; status = 'accepted'; run_id = $runId }
            return "Existing daily run ${runId}; no request sent."
        }
        if ($null -ne $state) {
            throw "Uncertain dispatch for ${date}; no matching run found. Pending state retained; manual review required."
        }

        Save-DailyDispatchState -Path $path -State @{ date = $date; status = 'pending'; requested_at = $Now.ToString('o') }
        $body = @{ ref = 'main'; inputs = @{ scheduled_date = $date; send_discord_report = $true } }
        $response = Invoke-DailyDispatchApi -Method POST -Token $token -Body $body -Uri 'https://api.github.com/repos/sunchengzhu/fiber-windows-smoke/actions/workflows/fiber-node-maintenance.yml/dispatches'
        $runId = $null
        if ($null -ne $response -and -not ($response -is [string] -and [string]::IsNullOrWhiteSpace($response))) {
            $runId = Get-DailyDispatchProperty $response 'workflow_run_id'
            if (-not (Test-DailyDispatchRunId $runId)) {
                throw 'Unexpected dispatch response. Pending state retained; manual review required.'
            }
        }
        Save-DailyDispatchState -Path $path -State @{ date = $date; status = 'accepted'; run_id = $runId }
        if ($null -eq $runId) { return "Accepted daily smoke for ${date}; run ID unavailable (HTTP 204)." }
        return "Accepted daily smoke for ${date}: run $runId."
    }
    finally {
        $token = $null
        if ($null -ne $lock) { $lock.Dispose() }
    }
}

function Write-DailyDispatchLog {
    param([string]$Directory, [string]$Message)
    [System.IO.Directory]::CreateDirectory($Directory) | Out-Null
    $path = Join-Path $Directory 'dispatcher.log'
    if ([System.IO.File]::Exists($path) -and (Get-Item -LiteralPath $path).Length -ge 1MB) {
        $previous = "$path.1"
        if ([System.IO.File]::Exists($previous)) { [System.IO.File]::Delete($previous) }
        [System.IO.File]::Move($path, $previous)
    }
    $line = [DateTimeOffset]::UtcNow.ToString('o') + ' ' + ($Message -replace '[\r\n]+', ' ') + [Environment]::NewLine
    [System.IO.File]::AppendAllText($path, $line, (New-Object System.Text.UTF8Encoding($false)))
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Invoke-DailyDispatch -StateDirectory $StateDirectory -TokenPath $TokenPath -Now $Now -Check:$Check
        Write-DailyDispatchLog -Directory $StateDirectory -Message $result
        Write-Output $result
    }
    catch {
        # Only our fixed, token-free errors may be persisted. Other exception
        # messages may originate from .NET or a provider, so use a safe summary.
        $message = $_.Exception.Message
        if ($message -notmatch '^(Cannot read or decrypt the dispatcher token\.|GitHub API (GET|POST) failed|Unexpected (workflow-runs API|dispatch) response|Invalid (daily state|workflow run)|Matched daily run has no valid ID|Uncertain dispatch for \d{4}-\d{2}-\d{2};)') {
            $message = 'Dispatcher failed. Check token configuration, connectivity, file permissions, and daily state. An uncertain dispatch is never retried automatically.'
        }
        try { Write-DailyDispatchLog -Directory $StateDirectory -Message ("ERROR: $message") }
        catch { Write-Warning 'Could not write dispatcher.log; check the state directory permissions.' }
        Write-Error -Message $message -ErrorAction Continue
        exit 1
    }
}
