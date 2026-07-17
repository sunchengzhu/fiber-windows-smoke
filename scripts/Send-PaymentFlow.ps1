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
$keysendAmount = Convert-CkbToShannons -AmountCkb $KeysendAmountCkb
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

function Format-FlowCkb {
    param(
        [Parameter(Mandatory = $true)]
        [System.Numerics.BigInteger]$Shannons
    )

    return (Format-CkbBalance -Shannons $Shannons).TrimEnd("0").TrimEnd(".")
}

$invoiceAmountDisplay = Format-FlowCkb -Shannons $invoiceAmount
$keysendAmountDisplay = Format-FlowCkb -Shannons $keysendAmount
$bottleName = [string]$primarySettings.peer.name

Write-Host ("=" * 60)
Write-Host "PAYMENT FLOW"
Write-Host ("=" * 60)
Write-Host "Node B -- $invoiceAmountDisplay CKB Invoice --> Node A"
Write-Host "Node A -- $keysendAmountDisplay CKB Keysend --> $bottleName"
Write-Host "Node A: $($primaryInfo.pubkey)"
Write-Host "Node B: $($secondaryInfo.pubkey)"

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

$invoicePayment = & (Join-Path $PSScriptRoot "Send-DailyPayment.ps1") `
    -SettingsPath $SecondarySettingsPath `
    -Mode Invoice `
    -AmountCkb $InvoiceAmountCkb `
    -Invoice $invoice `
    -PassThru `
    -AssertExactDirectBalance

$keysendPayment = & (Join-Path $PSScriptRoot "Send-DailyPayment.ps1") `
    -SettingsPath $PrimarySettingsPath `
    -Mode Keysend `
    -AmountCkb $KeysendAmountCkb `
    -PassThru `
    -AssertExactDirectBalance

$invoiceLocalBefore = Format-FlowCkb -Shannons $invoicePayment.LocalBefore
$invoiceLocalAfter = Format-FlowCkb -Shannons $invoicePayment.LocalAfter
$invoiceRemoteBefore = Format-FlowCkb -Shannons $invoicePayment.RemoteBefore
$invoiceRemoteAfter = Format-FlowCkb -Shannons $invoicePayment.RemoteAfter
$invoiceFee = Format-FlowCkb -Shannons $invoicePayment.Fee
$keysendLocalBefore = Format-FlowCkb -Shannons $keysendPayment.LocalBefore
$keysendLocalAfter = Format-FlowCkb -Shannons $keysendPayment.LocalAfter
$keysendRemoteBefore = Format-FlowCkb -Shannons $keysendPayment.RemoteBefore
$keysendRemoteAfter = Format-FlowCkb -Shannons $keysendPayment.RemoteAfter
$keysendFee = Format-FlowCkb -Shannons $keysendPayment.Fee

Write-Host ""
Write-Host ("=" * 60)
Write-Host "PAYMENT FLOW RESULT - SUCCESS"
Write-Host ("=" * 60)
Write-Host "1. Node B -> Node A | Invoice $invoiceAmountDisplay CKB"
Write-Host "   Node B : $invoiceLocalBefore -> $invoiceLocalAfter CKB"
Write-Host "   Node A : $invoiceRemoteBefore -> $invoiceRemoteAfter CKB"
Write-Host "   Fee    : $invoiceFee CKB"
Write-Host "   Assert : PASSED (exact $invoiceAmountDisplay CKB transfer)"
Write-Host ""
Write-Host "2. Node A -> $bottleName | Keysend $keysendAmountDisplay CKB"
Write-Host "   Node A : $keysendLocalBefore -> $keysendLocalAfter CKB"
Write-Host "   Bottle : $keysendRemoteBefore -> $keysendRemoteAfter CKB"
Write-Host "   Fee    : $keysendFee CKB"
Write-Host "   Assert : PASSED (exact $keysendAmountDisplay CKB transfer)"
Write-Host ""
Write-Host "FUNDS FLOW: Node B -- $invoiceAmountDisplay Invoice --> Node A -- $keysendAmountDisplay Keysend --> Bottle"

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
    $summary = @"
## Actual payment result

> **Node B** -- Invoice **$invoiceAmountDisplay CKB** &rarr; **Node A** -- Keysend **$keysendAmountDisplay CKB** &rarr; **Bottle**

### 1. Invoice: Node B &rarr; Node A ($invoiceAmountDisplay CKB)

- **Node B:** $invoiceLocalBefore &rarr; $invoiceLocalAfter CKB
- **Node A:** $invoiceRemoteBefore &rarr; $invoiceRemoteAfter CKB
- **Fee:** $invoiceFee CKB
- **Assertions:** &#x2705; Exact amount, zero fee, and balance conservation passed
- **Status:** &#x2705; **Success**
- **Payment hash:** $($invoicePayment.PaymentHash)

### 2. Keysend: Node A &rarr; Bottle ($keysendAmountDisplay CKB)

- **Node A:** $keysendLocalBefore &rarr; $keysendLocalAfter CKB
- **Bottle:** $keysendRemoteBefore &rarr; $keysendRemoteAfter CKB
- **Fee:** $keysendFee CKB
- **Assertions:** &#x2705; Exact amount, zero fee, and balance conservation passed
- **Status:** &#x2705; **Success**
- **Payment hash:** $($keysendPayment.PaymentHash)
"@
    $summary | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
    Write-Host "GitHub Job Summary updated"
}

Write-Host "Payment flow succeeded: invoice $InvoiceAmountCkb CKB, keysend $KeysendAmountCkb CKB"
