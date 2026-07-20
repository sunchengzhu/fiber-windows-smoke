[CmdletBinding()]
param(
    [string]$PrimarySettingsPath,
    [string]$SecondarySettingsPath,
    [decimal]$InvoiceAmountCkb,
    [decimal]$KeysendAmountCkb,
    [decimal]$RoutedKeysendAmountCkb,
    [decimal]$RoutedMaxFeeCkb,
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
if (-not $PSBoundParameters.ContainsKey("RoutedKeysendAmountCkb")) {
    $configuredRoutedAmount = if ($null -eq $paymentFlow) {
        "0.03"
    }
    else {
        [string](Get-ObjectPropertyValue -Object $paymentFlow -Name "routedKeysendAmountCkb" -Default "0.03")
    }
    $RoutedKeysendAmountCkb = [decimal]::Parse(
        $configuredRoutedAmount, [System.Globalization.CultureInfo]::InvariantCulture)
}
if (-not $PSBoundParameters.ContainsKey("RoutedMaxFeeCkb")) {
    $configuredRoutedMaxFee = if ($null -eq $paymentFlow) {
        "0.001"
    }
    else {
        [string](Get-ObjectPropertyValue -Object $paymentFlow -Name "routedMaxFeeCkb" -Default "0.001")
    }
    $RoutedMaxFeeCkb = [decimal]::Parse(
        $configuredRoutedMaxFee, [System.Globalization.CultureInfo]::InvariantCulture)
}

$invoiceAmount = Convert-CkbToShannons -AmountCkb $InvoiceAmountCkb
$keysendAmount = Convert-CkbToShannons -AmountCkb $KeysendAmountCkb
$routedKeysendAmount = Convert-CkbToShannons -AmountCkb $RoutedKeysendAmountCkb
$routedMaxFee = Convert-CkbToShannons -AmountCkb $RoutedMaxFeeCkb
$primaryInfo = Wait-FiberRpc -Settings $primarySettings -TimeoutSeconds 60
$secondaryInfo = Wait-FiberRpc -Settings $secondarySettings -TimeoutSeconds 60
if (-not [string]::Equals(
    [string]$secondarySettings.peer.pubkey,
    [string]$primaryInfo.pubkey,
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    throw "Node B is configured for $($secondarySettings.peer.pubkey), not node A $($primaryInfo.pubkey)"
}

$publicNodeName = "CkbaNode-1"

function Get-ReadyFlowChannel {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Settings,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $channels = @(Get-PeerChannels -Settings $Settings | Where-Object { Test-ChannelReady -Channel $_ })
    if ($channels.Count -eq 0) {
        throw "$Description has no ChannelReady channel"
    }
    return $channels[0]
}

$null = Get-ReadyFlowChannel -Settings $primarySettings -Description "Node A -> $publicNodeName"
$null = Get-ReadyFlowChannel -Settings $secondarySettings -Description "Node B -> Node A"

function Format-FlowCkb {
    param(
        [Parameter(Mandatory = $true)]
        [System.Numerics.BigInteger]$Shannons
    )

    return (Format-CkbBalance -Shannons $Shannons).TrimEnd("0").TrimEnd(".")
}

$invoiceAmountDisplay = Format-FlowCkb -Shannons $invoiceAmount
$keysendAmountDisplay = Format-FlowCkb -Shannons $keysendAmount
$routedKeysendAmountDisplay = Format-FlowCkb -Shannons $routedKeysendAmount

Write-Host ("=" * 60)
Write-Host "PAYMENT FLOW"
Write-Host ("=" * 60)
Write-Host "Node B -- $invoiceAmountDisplay CKB Invoice --> Node A"
Write-Host "Node A -- $keysendAmountDisplay CKB Keysend --> $publicNodeName"
Write-Host "Node B -- $routedKeysendAmountDisplay CKB Routed Keysend --> Node A --> $publicNodeName (routing fee)"
Write-Host "Node A: $($primaryInfo.pubkey)"
Write-Host "Node B: $($secondaryInfo.pubkey)"
Write-Host ""

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

$routedSecondHopBefore = Get-ReadyFlowChannel -Settings $primarySettings -Description "Node A -> $publicNodeName"
$routedFeeRate = ConvertFrom-HexQuantity -Value ([string]$routedSecondHopBefore.tlc_fee_proportional_millionths)
$expectedRoutingFee = Get-FiberForwardingFee `
    -Amount $routedKeysendAmount `
    -FeeRateMillionths $routedFeeRate
if ($expectedRoutingFee -le [System.Numerics.BigInteger]::Zero) {
    throw "Node A forwarding fee rate produced a zero fee; this routed-fee smoke test requires a positive fee"
}
if ($expectedRoutingFee -gt $routedMaxFee) {
    throw "Expected routing fee exceeds the configured routed payment fee limit"
}

$routedPayment = & (Join-Path $PSScriptRoot "Send-DailyPayment.ps1") `
    -SettingsPath $SecondarySettingsPath `
    -Mode Keysend `
    -AmountCkb $RoutedKeysendAmountCkb `
    -TargetPubkey ([string]$primarySettings.peer.pubkey) `
    -PaymentLabel "Routed keysend B -> A -> $publicNodeName" `
    -MaximumFeeCkb ($RoutedMaxFeeCkb.ToString([System.Globalization.CultureInfo]::InvariantCulture)) `
    -ExpectedRoutingFee $expectedRoutingFee `
    -PassThru `
    -AssertExactRoutedBalance

$routedSecondHopAfter = Get-ReadyFlowChannel -Settings $primarySettings -Description "Node A -> $publicNodeName"
$routedSecondHopAssertion = Assert-FiberDirectPaymentBalance `
    -Label "Routed keysend A -> $publicNodeName hop" `
    -ExpectedAmount $routedKeysendAmount `
    -Fee ([System.Numerics.BigInteger]::Zero) `
    -LocalBefore (ConvertFrom-HexQuantity -Value ([string]$routedSecondHopBefore.local_balance)) `
    -LocalAfter (ConvertFrom-HexQuantity -Value ([string]$routedSecondHopAfter.local_balance)) `
    -RemoteBefore (ConvertFrom-HexQuantity -Value ([string]$routedSecondHopBefore.remote_balance)) `
    -RemoteAfter (ConvertFrom-HexQuantity -Value ([string]$routedSecondHopAfter.remote_balance))

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
$routedLocalBefore = Format-FlowCkb -Shannons $routedPayment.LocalBefore
$routedLocalAfter = Format-FlowCkb -Shannons $routedPayment.LocalAfter
$routedRemoteBefore = Format-FlowCkb -Shannons $routedPayment.RemoteBefore
$routedRemoteAfter = Format-FlowCkb -Shannons $routedPayment.RemoteAfter
$routedPublicNodeLocalBefore = Format-FlowCkb -Shannons (ConvertFrom-HexQuantity -Value ([string]$routedSecondHopBefore.local_balance))
$routedPublicNodeLocalAfter = Format-FlowCkb -Shannons (ConvertFrom-HexQuantity -Value ([string]$routedSecondHopAfter.local_balance))
$routedPublicNodeRemoteBefore = Format-FlowCkb -Shannons (ConvertFrom-HexQuantity -Value ([string]$routedSecondHopBefore.remote_balance))
$routedPublicNodeRemoteAfter = Format-FlowCkb -Shannons (ConvertFrom-HexQuantity -Value ([string]$routedSecondHopAfter.remote_balance))
$routingFee = Format-FlowCkb -Shannons $routedPayment.Fee

Write-Host ("=" * 60)
Write-Host "PAYMENT FLOW RESULT - SUCCESS"
Write-Host ("=" * 60)
Write-Host ""
Write-Host "1. Node B -> Node A | Invoice $invoiceAmountDisplay CKB"
Write-Host "   Node B : $invoiceLocalBefore -> $invoiceLocalAfter CKB"
Write-Host "   Node A : $invoiceRemoteBefore -> $invoiceRemoteAfter CKB"
Write-Host "   Routing fee : $invoiceFee CKB"
Write-Host "   Assert : PASSED (exact $invoiceAmountDisplay CKB transfer)"
Write-Host ""
Write-Host "2. Node A -> $publicNodeName | Keysend $keysendAmountDisplay CKB"
Write-Host "   Node A : $keysendLocalBefore -> $keysendLocalAfter CKB"
Write-Host "   $publicNodeName : $keysendRemoteBefore -> $keysendRemoteAfter CKB"
Write-Host "   Routing fee : $keysendFee CKB"
Write-Host "   Assert : PASSED (exact $keysendAmountDisplay CKB transfer)"
Write-Host ""
Write-Host "3. Node B -> Node A -> $publicNodeName | Routed Keysend $routedKeysendAmountDisplay CKB"
Write-Host "   B -> A local  : $routedLocalBefore -> $routedLocalAfter CKB"
Write-Host "   B -> A remote : $routedRemoteBefore -> $routedRemoteAfter CKB"
Write-Host "   A -> $publicNodeName : $routedPublicNodeLocalBefore -> $routedPublicNodeLocalAfter CKB"
Write-Host "   $publicNodeName      : $routedPublicNodeRemoteBefore -> $routedPublicNodeRemoteAfter CKB"
Write-Host "   Routing fee   : $routingFee CKB ($($routedPayment.Fee) shannons at $routedFeeRate millionths)"
Write-Host "   Assert        : PASSED (positive fee, both hops, and balance conservation)"
Write-Host ""
Write-Host "FEE PATH: Node B -- $routedKeysendAmountDisplay CKB + $routingFee CKB fee --> Node A -- $routedKeysendAmountDisplay CKB --> $publicNodeName"
Write-Host ""

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
    $summary = @"
## Actual payment result

> **1. Invoice:** **Node B** -- **$invoiceAmountDisplay CKB** &rarr; **Node A**

> **2. Keysend:** **Node A** -- **$keysendAmountDisplay CKB** &rarr; **$publicNodeName** *(Fiber testnet public node)*

> **3. Routed Keysend:** **Node B** -- **$routedKeysendAmountDisplay CKB + $routingFee CKB fee** &rarr; **Node A** &rarr; **$publicNodeName**

### 1. Invoice: Node B &rarr; Node A ($invoiceAmountDisplay CKB)

- **Node B:** $invoiceLocalBefore &rarr; $invoiceLocalAfter CKB
- **Node A:** $invoiceRemoteBefore &rarr; $invoiceRemoteAfter CKB
- **Routing fee:** $invoiceFee CKB
- **Assertions:** &#x2705; Exact amount, zero fee, and balance conservation passed
- **Status:** &#x2705; **Success**
- **Payment hash:** $($invoicePayment.PaymentHash)

### 2. Keysend: Node A &rarr; $publicNodeName ($keysendAmountDisplay CKB)

- **Node A:** $keysendLocalBefore &rarr; $keysendLocalAfter CKB
- **${publicNodeName}:** $keysendRemoteBefore &rarr; $keysendRemoteAfter CKB
- **Routing fee:** $keysendFee CKB
- **Assertions:** &#x2705; Exact amount, zero fee, and balance conservation passed
- **Status:** &#x2705; **Success**
- **Payment hash:** $($keysendPayment.PaymentHash)

### 3. Routed Keysend: Node B &rarr; Node A &rarr; $publicNodeName ($routedKeysendAmountDisplay CKB)

- **Node B / B-to-A channel:** $routedLocalBefore &rarr; $routedLocalAfter CKB
- **Node A incoming / B-to-A channel:** $routedRemoteBefore &rarr; $routedRemoteAfter CKB
- **Node A outgoing / A-to-$publicNodeName channel:** $routedPublicNodeLocalBefore &rarr; $routedPublicNodeLocalAfter CKB
- **${publicNodeName}:** $routedPublicNodeRemoteBefore &rarr; $routedPublicNodeRemoteAfter CKB
- **Routing fee earned by Node A:** **$routingFee CKB** ($($routedPayment.Fee) shannons, rate $routedFeeRate millionths)
- **Assertions:** &#x2705; Positive fee, exact first-hop amount plus fee, exact second-hop amount, and balance conservation passed
- **Status:** &#x2705; **Success**
- **Payment hash:** $($routedPayment.PaymentHash)
"@
    $summary | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
    Write-Host "GitHub Job Summary updated"
}

Write-Host "Payment flow succeeded: invoice $InvoiceAmountCkb CKB, direct keysend $KeysendAmountCkb CKB, routed keysend $RoutedKeysendAmountCkb CKB with $routingFee CKB fee"
