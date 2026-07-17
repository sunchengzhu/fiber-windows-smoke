[CmdletBinding()]
param(
    [string]$PrimarySettingsPath,
    [string]$SecondarySettingsPath,
    [switch]$AllowPending,
    [switch]$Detailed
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

if ($Detailed) {
    Write-Host "=== Node A -> public Bottle ==="
}
else {
    Write-Host "Fiber topology health"
}
& (Join-Path $PSScriptRoot "Test-FiberNode.ps1") `
    -SettingsPath $PrimarySettingsPath `
    -AllowPending:$AllowPending `
    -Compact:(-not $Detailed) `
    -Label "A -> Bottle"

if ($Detailed) {
    Write-Host ""
    Write-Host "=== Node B -> node A ==="
}
& (Join-Path $PSScriptRoot "Test-FiberNode.ps1") `
    -SettingsPath $SecondarySettingsPath `
    -AllowPending:$AllowPending `
    -Compact:(-not $Detailed) `
    -Label "B -> A"

if (-not $Detailed) {
    if ($AllowPending) {
        Write-Host "Topology check completed (pending allowed)"
    }
    else {
        Write-Host "Topology health passed"
    }
}
