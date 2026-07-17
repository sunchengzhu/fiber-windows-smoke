[CmdletBinding()]
param(
    [string]$PrimarySettingsPath,
    [string]$SecondarySettingsPath,
    [switch]$AllowPending
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($PrimarySettingsPath)) {
    if (-not [string]::IsNullOrWhiteSpace($env:FIBER_WINDOWS_SETTINGS)) {
        $PrimarySettingsPath = $env:FIBER_WINDOWS_SETTINGS
    }
    else {
        $PrimarySettingsPath = "C:\fiber-node\automation\settings.json"
    }
}
if ([string]::IsNullOrWhiteSpace($SecondarySettingsPath)) {
    if (-not [string]::IsNullOrWhiteSpace($env:FIBER_WINDOWS_SECONDARY_SETTINGS)) {
        $SecondarySettingsPath = $env:FIBER_WINDOWS_SECONDARY_SETTINGS
    }
    else {
        $SecondarySettingsPath = "C:\fiber-node-b\automation\settings.json"
    }
}

Write-Host "=== Node A -> public Bottle ==="
& (Join-Path $PSScriptRoot "Test-FiberNode.ps1") `
    -SettingsPath $PrimarySettingsPath -AllowPending:$AllowPending
Write-Host ""
Write-Host "=== Node B -> node A ==="
& (Join-Path $PSScriptRoot "Test-FiberNode.ps1") `
    -SettingsPath $SecondarySettingsPath -AllowPending:$AllowPending
