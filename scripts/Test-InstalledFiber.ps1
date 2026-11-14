[CmdletBinding()]
param(
    [string]$PrimarySettingsPath = $env:FIBER_WINDOWS_SETTINGS,
    [string]$SecondarySettingsPath = $env:FIBER_WINDOWS_SECONDARY_SETTINGS,
    [string]$ReleaseManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\tested-fiber-release.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module (Join-Path $PSScriptRoot 'FiberWindows.psm1') -Force
if ([string]::IsNullOrWhiteSpace($PrimarySettingsPath)) { $PrimarySettingsPath = 'C:\fiber-node\automation\settings.json' }
if ([string]::IsNullOrWhiteSpace($SecondarySettingsPath)) { $SecondarySettingsPath = 'C:\fiber-node-b\automation\settings.json' }

function Test-CommitMatches {
    param([string]$Actual, [string]$Expected)
    $match = [regex]::Match($Actual, '^([0-9a-fA-F]{7,40})(?:\s|$)')
    if (-not $match.Success) { return $false }
    $actualCommit = $match.Groups[1].Value.ToLowerInvariant()
    $expectedCommit = $Expected.ToLowerInvariant()
    return $expectedCommit.StartsWith($actualCommit) -or $actualCommit.StartsWith($expectedCommit)
}

function Format-VersionValue {
    param($Value)
    $text = ([string]$Value -replace '[\r\n|`]', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return 'unavailable' }
    return $text.Substring(0, [Math]::Min(180, $text.Length))
}

$report = [ordered]@{
    status = 'unavailable'
    expected = @{ repository = 'nervosnetwork/fiber'; tag = ''; commit = '' }
    latest = @{ status = 'unavailable'; tag = ''; url = '' }
    freshness = 'unknown'
    nodes = @()
    errors = @()
}
$manifestValid = $false
try {
    try {
        $expected = Get-Content -LiteralPath $ReleaseManifestPath -Raw | ConvertFrom-Json
        if ($expected.tag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$' -or
            $expected.commit -notmatch '^[0-9a-fA-F]{7,40}$' -or
            $expected.repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
            throw 'Invalid release manifest'
        }
        $report.expected = @{ repository = [string]$expected.repository; tag = [string]$expected.tag; commit = [string]$expected.commit }
        $manifestValid = $true
    }
    catch { $report.errors += 'CI release manifest is missing or invalid; review config/tested-fiber-release.json.' }

    # Always inspect both nodes, even when the first node is missing or mismatched.
    # No package download, service control, migration, or payment is performed.
    foreach ($spec in @(@{ name = 'A'; path = $PrimarySettingsPath }, @{ name = 'B'; path = $SecondarySettingsPath })) {
        $node = [ordered]@{ name = $spec.name; fnn_version = ''; cli_version = ''; rpc_version = ''; rpc_commit = ''; problems = @() }
        try {
            $settings = Import-FiberSettings -SettingsPath $spec.path
            $paths = Get-FiberPaths -Settings $settings
            foreach ($kind in @('fnn', 'cli')) {
                try {
                    $path = if ($kind -eq 'fnn') { $paths.Fnn } else { $paths.Cli }
                    $node["${kind}_version"] = Get-ExecutableVersion -Path $path
                    if ($node["${kind}_version"] -eq 'missing') { $node.problems += "${kind}_unavailable" }
                }
                catch { $node.problems += "${kind}_unavailable" }
            }
            try {
                $info = Invoke-FiberRpc -Settings $settings -Method 'node_info' -TimeoutSeconds 10
                $node.rpc_version = [string]$info.version
                $node.rpc_commit = [string]$info.commit_hash
            }
            catch { $node.problems += 'rpc_unavailable' }

            if ($manifestValid) {
                $binary = [regex]::Match($node.fnn_version, '^fnn Fiber (v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?) \(([0-9a-fA-F]{7,40})(?:\s[^)]*)?\)$')
                if ($node.problems -notcontains 'fnn_unavailable' -and
                    (-not $binary.Success -or $binary.Groups[1].Value -ne $report.expected.tag -or
                    -not (Test-CommitMatches -Actual $binary.Groups[2].Value -Expected $report.expected.commit))) {
                    $node.problems += 'fnn_mismatch'
                }
                if ($node.problems -notcontains 'cli_unavailable' -and $node.cli_version -ne "fnn-cli $($report.expected.tag.Substring(1))") {
                    $node.problems += 'cli_mismatch'
                }
                if ($node.problems -notcontains 'rpc_unavailable' -and
                    ($node.rpc_version -ne $report.expected.tag.Substring(1) -or
                    -not (Test-CommitMatches -Actual $node.rpc_commit -Expected $report.expected.commit))) {
                    $node.problems += 'rpc_mismatch'
                }
            }
        }
        catch { $node.problems += 'settings_unavailable' }
        $report.nodes += $node
        foreach ($problem in $node.problems) { $report.errors += "Node $($node.name): $problem" }
    }

    # Freshness is advisory. GitHub outages and new releases never prevent the
    # smoke for an explicitly recorded installed version from running.
    try {
        $latest = Get-LatestStableFiberRelease -Repository $report.expected.repository
        $report.latest = @{
            status = 'ok'; tag = [string]$latest.tag_name
            url = "https://github.com/$($report.expected.repository)/releases/tag/$($latest.tag_name)"
        }
        if ($manifestValid) {
            $latestVersion = [version]$report.latest.tag.Substring(1)
            $expectedVersion = [version]$report.expected.tag.Substring(1)
            $report.freshness = if ($latestVersion -gt $expectedVersion) { 'update_available' } elseif ($latestVersion -eq $expectedVersion) { 'current' } else { 'ahead' }
        }
    }
    catch { Write-Warning 'Latest stable Fiber release lookup failed; freshness is unknown. Installed-version checks still apply.' }

    $report.status = if (@($report.errors | Where-Object { $_ -like '*_mismatch' }).Count -gt 0) { 'mismatch' } elseif ($report.errors.Count -gt 0) { 'unavailable' } else { 'match' }
}
finally {
    # Export evidence before failing so Discord can show actual and expected
    # versions instead of replacing every field with "unavailable".
    $json = $report | ConvertTo-Json -Depth 10 -Compress
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
        "report=$json" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
    }
    $heading = switch ($report.status) { 'match' { 'Installed Fiber versions verified' }; 'mismatch' { 'FIBER VERSION MISMATCH - payments blocked' }; default { 'FIBER VERSION CHECK FAILED - payments blocked' } }
    $lines = @(
        "## $heading", '',
        "CI expected: $(Format-VersionValue $report.expected.tag) / $(Format-VersionValue $report.expected.commit)",
        "Latest stable: $(Format-VersionValue $report.latest.tag) (lookup: $($report.latest.status))", '',
        '| Node | Installed FNN | Installed CLI | Running RPC |', '| --- | --- | --- | --- |'
    )
    foreach ($node in $report.nodes) {
        $lines += "| $($node.name) | $(Format-VersionValue $node.fnn_version) | $(Format-VersionValue $node.cli_version) | $(Format-VersionValue $node.rpc_version) / $(Format-VersionValue $node.rpc_commit) |"
    }
    if ($report.status -ne 'match') {
        $lines += @('', 'Align both installed FNN/CLI binaries and running RPC with config/tested-fiber-release.json during a reviewed manual upgrade.', ($report.errors -join '; '))
    }
    if ($report.freshness -eq 'update_available') {
        $lines += @('', "UPDATE AVAILABLE: $($report.latest.tag). Request a manual upgrade; the recorded version remains the smoke baseline.")
    }
    elseif ($report.freshness -eq 'unknown') { $lines += @('', 'Latest stable release status is unknown; this does not indicate that the installed version is current.') }
    $lines | Write-Host
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        $lines | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
    }
}
if ($report.errors.Count -gt 0) { throw "Fiber version check failed: $($report.errors -join '; '). See the version table above; no payment was started." }
