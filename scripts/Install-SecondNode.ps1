#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$PrimarySettingsPath,
    [string]$SecondarySettingsPath,
    [decimal]$FundingAmountCkb = 5000,
    [string]$PrimaryP2pAddress = "/ip4/127.0.0.1/tcp/8228",
    [string]$SecondaryRpcAddress = "127.0.0.1:8327",
    [string]$SecondaryP2pAddress = "/ip4/127.0.0.1/tcp/8328"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "FiberWindows.psm1") -Force
$PrimarySettingsPath = Resolve-FiberSettingsPath `
    -SettingsPath $PrimarySettingsPath -ScriptRoot $PSScriptRoot
$primarySettings = Import-FiberSettings -SettingsPath $PrimarySettingsPath
$primaryInfo = Wait-FiberRpc -Settings $primarySettings -TimeoutSeconds 60

if (-not $PSBoundParameters.ContainsKey("PrimaryP2pAddress")) {
    $PrimaryP2pAddress = [string](Get-ObjectPropertyValue `
        -Object $primarySettings -Name "p2pListeningAddress" -Default $PrimaryP2pAddress)
}
if ([string]::IsNullOrWhiteSpace($SecondarySettingsPath)) {
    $SecondarySettingsPath = Join-Path (Split-Path -Parent $PSScriptRoot) "config\node-b-settings.json"
}
elseif (-not [System.IO.Path]::IsPathRooted($SecondarySettingsPath)) {
    $SecondarySettingsPath = [System.IO.Path]::GetFullPath(
        (Join-Path (Get-Location).ProviderPath $SecondarySettingsPath)
    )
}

$fundingAmount = Convert-CkbToShannons -AmountCkb $FundingAmountCkb
$secondaryRpcUrl = "http://$SecondaryRpcAddress"
$secondarySettings = [ordered]@{
    installRoot         = "C:\fiber-node-b"
    repository          = [string]$primarySettings.repository
    releaseChannel      = [string]$primarySettings.releaseChannel
    releaseTag          = [string](Get-ObjectPropertyValue -Object $primarySettings -Name "releaseTag" -Default "")
    serviceName         = "FiberNodeB"
    rpcUrl              = $secondaryRpcUrl
    rpcListeningAddress = $SecondaryRpcAddress
    p2pListeningAddress = $SecondaryP2pAddress
    authTokenFile       = ""
    peer                = [ordered]@{
        name                       = "local-node-a"
        pubkey                     = [string]$primaryInfo.pubkey
        address                    = $PrimaryP2pAddress
        asset                      = "CKB"
        fundingAmountShannons      = $fundingAmount.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        fundingFeeRate             = [string]$primarySettings.peer.fundingFeeRate
        public                     = $false
        oneWay                     = $true
        connectTimeoutSeconds      = 600
        channelReadyTimeoutSeconds = 1800
    }
    dailyPayment        = [ordered]@{
        enabled                      = $true
        mode                         = "Invoice"
        amountCkb                    = "0.02"
        maxFeeCkb                    = "0.001"
        timeoutSeconds               = 120
        invoiceReceiverRpcUrl        = [string]$primarySettings.rpcUrl
        invoiceReceiverAuthTokenFile = [string](Get-ObjectPropertyValue `
            -Object $primarySettings -Name "authTokenFile" -Default "")
    }
}

$secondaryDirectory = Split-Path -Parent $SecondarySettingsPath
New-Item -ItemType Directory -Path $secondaryDirectory -Force | Out-Null
$secondarySettings | ConvertTo-Json -Depth 20 | Set-Content `
    -LiteralPath $SecondarySettingsPath -Encoding UTF8

Write-Host "Installing node B with an independent key, data directory, service, and ports"
Write-Host "Node A pubkey: $($primaryInfo.pubkey)"
Write-Host "Node B settings: $SecondarySettingsPath"
& (Join-Path $PSScriptRoot "Install-FiberService.ps1") -SettingsPath $SecondarySettingsPath

Write-Host "Node B is installed. Fund the CKB address printed above with about 5500 testnet CKB."
Write-Host "After the funding transaction is confirmed, run:"
Write-Host "  .\scripts\Ensure-SecondNodeChannel.ps1"
