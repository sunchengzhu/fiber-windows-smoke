[CmdletBinding()]
param(
    [string]$PrimarySettingsPath,
    [string]$SecondarySettingsPath,
    [decimal]$InvoiceAmountCkb,
    [decimal]$KeysendAmountCkb,
    [switch]$Scheduled
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "FiberWindows.psm1") -Force

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

$primarySettings = Import-FiberSettings -SettingsPath $PrimarySettingsPath
$secondarySettings = Import-FiberSettings -SettingsPath $SecondarySettingsPath
$paymentFlow = Get-ObjectPropertyValue -Object $primarySettings -Name "paymentFlow" -Default $null

if ($Scheduled -and $null -ne $paymentFlow) {
    $enabled = [bool](Get-ObjectPropertyValue -Object $paymentFlow -Name "enabled" -Default $true)
    if (-not $enabled) {
        Write-Host "Payment flow is disabled in settings; nothing sent"
        return
    }
}
if (-not $PSBoundParameters.ContainsKey("InvoiceAmountCkb")) {
    $configuredInvoiceAmount = if ($null -eq $paymentFlow) {
        "0.02"
    }
    else {
        [string](Get-ObjectPropertyValue -Object $paymentFlow -Name "invoiceAmountCkb" -Default "0.02")
    }
    $InvoiceAmountCkb = [decimal]::Parse(
        $configuredInvoiceAmount, [System.Globalization.CultureInfo]::InvariantCulture)
}
if (-not $PSBoundParameters.ContainsKey("KeysendAmountCkb")) {
    $configuredKeysendAmount = if ($null -eq $paymentFlow) {
        "0.01"
    }
    else {
        [string](Get-ObjectPropertyValue -Object $paymentFlow -Name "keysendAmountCkb" -Default "0.01")
    }
    $KeysendAmountCkb = [decimal]::Parse(
        $configuredKeysendAmount, [System.Globalization.CultureInfo]::InvariantCulture)
}

$invoiceAmount = Convert-CkbToShannons -AmountCkb $InvoiceAmountCkb
$primaryInfo = Wait-FiberRpc -Settings $primarySettings -TimeoutSeconds 60
$secondaryInfo = Wait-FiberRpc -Settings $secondarySettings -TimeoutSeconds 60
if (-not [string]::Equals(
    [string]$secondarySettings.peer.pubkey,
    [string]$primaryInfo.pubkey,
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    throw "Node B is configured for $($secondarySettings.peer.pubkey), not node A $($primaryInfo.pubkey)"
}

$primaryReadyChannels = @(Get-PeerChannels -Settings $primarySettings | Where-Object { Test-ChannelReady -Channel $_ })
$secondaryReadyChannels = @(Get-PeerChannels -Settings $secondarySettings | Where-Object { Test-ChannelReady -Channel $_ })
if ($primaryReadyChannels.Count -eq 0) {
    throw "Node A has no ready channel to the public payment peer"
}
if ($secondaryReadyChannels.Count -eq 0) {
    throw "Node B has no ready channel to node A; run Ensure-SecondNodeChannel.ps1 first"
}

Write-Host "Payment flow"
[pscustomobject]@{
    Invoice = "Node B -> node A: $InvoiceAmountCkb CKB"
    Keysend = "Node A -> $($primarySettings.peer.name): $KeysendAmountCkb CKB"
    NodeA   = [string]$primaryInfo.pubkey
    NodeB   = [string]$secondaryInfo.pubkey
} | Format-List

$invoiceResult = Invoke-FiberRpc -Settings $primarySettings -Method "new_invoice" -Params @(@{
    amount         = ConvertTo-HexQuantity -Value $invoiceAmount
    currency       = "Fibt"
    description    = "fiber-windows-smoke node B to node A"
    expiry         = ConvertTo-HexQuantity -Value ([System.Numerics.BigInteger]3600)
    hash_algorithm = "sha256"
    allow_mpp      = $false
})
$invoice = [string]$invoiceResult.invoice_address
if ([string]::IsNullOrWhiteSpace($invoice)) {
    throw "Node A new_invoice returned no invoice_address"
}

& (Join-Path $PSScriptRoot "Send-DailyPayment.ps1") `
    -SettingsPath $SecondarySettingsPath `
    -Mode Invoice `
    -AmountCkb $InvoiceAmountCkb `
    -Invoice $invoice

& (Join-Path $PSScriptRoot "Send-DailyPayment.ps1") `
    -SettingsPath $PrimarySettingsPath `
    -Mode Keysend `
    -AmountCkb $KeysendAmountCkb

Write-Host "Payment flow succeeded: invoice $InvoiceAmountCkb CKB, keysend $KeysendAmountCkb CKB"
