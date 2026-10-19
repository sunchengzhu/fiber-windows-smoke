[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "FiberWindows.psm1") -Force

foreach ($path in @($env:FIBER_WINDOWS_SETTINGS, $env:FIBER_WINDOWS_SECONDARY_SETTINGS)) {
    if ([string]::IsNullOrWhiteSpace($path)) { throw "Both node settings paths are required" }
    $settings = Import-FiberSettings -SettingsPath $path
    Wait-FiberPeerConnected -Settings $settings
    Write-Host "Configured peer connected: $($settings.peer.pubkey)"
}
