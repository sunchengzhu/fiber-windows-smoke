#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$SettingsPath,
    [decimal]$FundingAmountCkb = 5000,
    [int]$TimeoutSeconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    if (-not [string]::IsNullOrWhiteSpace($env:FIBER_WINDOWS_SECONDARY_SETTINGS)) {
        $SettingsPath = $env:FIBER_WINDOWS_SECONDARY_SETTINGS
    }
    else {
        $SettingsPath = "C:\fiber-node-b\automation\settings.json"
    }
}

& (Join-Path $PSScriptRoot "Ensure-Channel.ps1") `
    -SettingsPath $SettingsPath `
    -FundingAmountCkb $FundingAmountCkb `
    -TimeoutSeconds $TimeoutSeconds
