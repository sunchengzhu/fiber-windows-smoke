[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('fiber-version-test-' + [Guid]::NewGuid().ToString('N'))
$names = @('GITHUB_OUTPUT', 'GITHUB_STEP_SUMMARY', 'FIBER_VERSION_TEST_CASE', 'FIBER_VERSION_TEST_TRACE')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    # Keep the fixture in its own module namespace so later production-module
    # tests still see exactly one FiberWindows module in this PowerShell host.
    $production = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts/Test-InstalledFiber.ps1') -Raw
    $production.Replace("'FiberWindows.psm1'", "'FiberVersionFixture.psm1'") |
        Set-Content -LiteralPath (Join-Path $tempRoot 'Test-InstalledFiber.ps1') -Encoding UTF8
    @'
Set-StrictMode -Version Latest
function Import-FiberSettings {
    param([string]$SettingsPath)
    if ($SettingsPath -notin @('A', 'B')) { throw 'Unexpected settings path' }
    if ($SettingsPath -eq 'A' -and $env:FIBER_VERSION_TEST_CASE -eq 'missing-settings') { throw 'Offline missing settings' }
    return [pscustomobject]@{ name = $SettingsPath }
}
function Get-FiberPaths {
    param($Settings)
    return [pscustomobject]@{ Fnn = "$($Settings.name)-fnn"; Cli = "$($Settings.name)-cli" }
}
function Get-ExecutableVersion {
    param([string]$Path)
    Add-Content -LiteralPath $env:FIBER_VERSION_TEST_TRACE -Value $Path
    if ($Path -eq 'A-fnn' -and $env:FIBER_VERSION_TEST_CASE -eq 'missing-binary') { return 'missing' }
    if ($Path -eq 'A-cli' -and $env:FIBER_VERSION_TEST_CASE -eq 'cli-mismatch') { return 'fnn-cli 0.10.0-rc3' }
    if ($Path -eq 'A-fnn' -and $env:FIBER_VERSION_TEST_CASE -eq 'commit-mismatch') { return 'fnn Fiber v0.10.1 (d6868d1 2026-11-13)' }
    if ($Path -eq 'A-fnn' -and $env:FIBER_VERSION_TEST_CASE -eq 'fnn-mismatch') { return 'fnn Fiber v0.9.1 (9a561b3 2026-09-10)' }
    if ($Path -like '*-cli') { return 'fnn-cli 0.10.1' }
    return 'fnn Fiber v0.10.1 (d9b6bbd 2026-11-14)'
}
function Invoke-FiberRpc {
    param($Settings, [string]$Method, [int]$TimeoutSeconds)
    if ($Method -ne 'node_info') { throw 'Version inspection attempted a state-changing RPC' }
    Add-Content -LiteralPath $env:FIBER_VERSION_TEST_TRACE -Value "rpc:$($Settings.name)"
    if ($Settings.name -eq 'A' -and $env:FIBER_VERSION_TEST_CASE -eq 'rpc-down') { throw 'Offline unavailable RPC' }
    if ($Settings.name -eq 'A' -and $env:FIBER_VERSION_TEST_CASE -eq 'rpc-mismatch') { return [pscustomobject]@{ version = '0.9.1'; commit_hash = '9a561b3 2026-09-10' } }
    return [pscustomobject]@{ version = '0.10.1'; commit_hash = 'd9b6bbd 2026-11-14' }
}
function Get-LatestStableFiberRelease {
    param([string]$Repository)
    if ($Repository -ne 'nervosnetwork/fiber') { throw 'Unexpected release repository' }
    if ($env:FIBER_VERSION_TEST_CASE -eq 'lookup-failed') { throw 'Offline GitHub outage' }
    return [pscustomobject]@{ tag_name = $(if ($env:FIBER_VERSION_TEST_CASE -eq 'new-stable') { 'v0.11.0' } else { 'v0.10.1' }) }
}
'@ | Set-Content -LiteralPath (Join-Path $tempRoot 'FiberVersionFixture.psm1') -Encoding UTF8
    $manifest = Join-Path $tempRoot 'release.json'
    # Fixture versions are independent of the deployed baseline. Future manual
    # upgrades only need to change the real manifest, not these historical cases.
    @{ repository = 'nervosnetwork/fiber'; tag = 'v0.10.1'; commit = 'd9b6bbd74faf5b168244e3ddea5b6762a04e0a71' } |
        ConvertTo-Json | Set-Content -LiteralPath $manifest -Encoding UTF8
    $cases = @{
        'matching' = @('match', 'current')
        'cli-mismatch' = @('mismatch', 'current')
        'fnn-mismatch' = @('mismatch', 'current')
        'commit-mismatch' = @('mismatch', 'current')
        'rpc-mismatch' = @('mismatch', 'current')
        'missing-binary' = @('unavailable', 'current')
        'missing-settings' = @('unavailable', 'current')
        'rpc-down' = @('unavailable', 'current')
        'new-stable' = @('match', 'update_available')
        'lookup-failed' = @('match', 'unknown')
        'missing-manifest' = @('unavailable', 'unknown')
    }
    foreach ($case in $cases.Keys) {
        $env:FIBER_VERSION_TEST_CASE = $case
        $env:GITHUB_OUTPUT = Join-Path $tempRoot "$case-output.txt"
        $env:GITHUB_STEP_SUMMARY = Join-Path $tempRoot "$case-summary.md"
        $env:FIBER_VERSION_TEST_TRACE = Join-Path $tempRoot "$case-trace.txt"
        $failed = $false
        $manifestPath = if ($case -eq 'missing-manifest') { Join-Path $tempRoot 'absent.json' } else { $manifest }
        try {
            & (Join-Path $tempRoot 'Test-InstalledFiber.ps1') -PrimarySettingsPath A -SecondarySettingsPath B -ReleaseManifestPath $manifestPath
        }
        catch {
            if ($_.Exception.Message -notlike 'Fiber version check failed:*') { throw }
            $failed = $true
        }
        $expected = $cases[$case]
        if ($failed -ne ($expected[0] -ne 'match')) { throw "${case}: unexpected process result" }
        $output = Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw
        if ($output -notmatch '(?m)^report=(.+)$') { throw "${case}: version evidence was lost" }
        $report = $Matches[1] | ConvertFrom-Json
        if ($report.status -ne $expected[0] -or $report.freshness -ne $expected[1]) { throw "${case}: wrong version or freshness status" }
        if ($report.nodes.Count -ne 2) { throw "${case}: failed to inspect both nodes" }
        $nodeB = @($report.nodes | Where-Object { $_.name -eq 'B' })[0]
        if ($nodeB.fnn_version -notlike '*v0.10.1*' -or $nodeB.rpc_version -ne '0.10.1') { throw "${case}: first-node failure hid node B" }
        $summary = Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw
        if ($summary -notlike '*Latest stable:*' -or $summary -notlike '*Installed CLI*') { throw "${case}: summary lacks version context" }
        if ($case -eq 'cli-mismatch' -and $summary -notlike '*fnn-cli 0.10.0-rc3*') { throw 'Mismatch summary omitted the actual stale CLI version' }
        if ($case -eq 'new-stable' -and -not $summary.StartsWith('## FIBER UPDATE AVAILABLE')) { throw 'New stable release must be a summary headline' }
        if ($case -eq 'lookup-failed' -and -not $summary.StartsWith('## Latest stable version UNKNOWN')) { throw 'Unknown release freshness must be a summary headline' }
        $trace = Get-Content -LiteralPath $env:FIBER_VERSION_TEST_TRACE -Raw
        if ($trace -notlike '*rpc:B*') { throw "${case}: node B RPC was not checked" }
    }
    Write-Host "Installed Fiber version checks passed ($($cases.Count) offline full-script cases)"
}
finally {
    Remove-Module FiberVersionFixture -Force -ErrorAction SilentlyContinue
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
