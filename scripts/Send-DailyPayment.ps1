[CmdletBinding()]
param(
    [string]$SettingsPath,
    [ValidateSet("Keysend", "Invoice", "Both")]
    [string]$Mode,
    [decimal]$AmountCkb,
    [string]$Invoice,
    [string]$InvoiceReceiverRpcUrl,
    [string]$InvoiceReceiverAuthTokenFile,
    [int]$TimeoutSeconds = 0,
    [switch]$Scheduled
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "FiberWindows.psm1") -Force
$SettingsPath = Resolve-FiberSettingsPath -SettingsPath $SettingsPath -ScriptRoot $PSScriptRoot
$settings = Import-FiberSettings -SettingsPath $SettingsPath
$dailyPayment = Get-ObjectPropertyValue -Object $settings -Name "dailyPayment" -Default $null

if ($Scheduled -and $null -ne $dailyPayment) {
    $enabled = [bool](Get-ObjectPropertyValue -Object $dailyPayment -Name "enabled" -Default $true)
    if (-not $enabled) {
        Write-Host "Daily payment is disabled in settings; nothing sent"
        return
    }
}
if (-not $PSBoundParameters.ContainsKey("Mode")) {
    $Mode = "Keysend"
    if ($null -ne $dailyPayment) {
        $Mode = [string](Get-ObjectPropertyValue -Object $dailyPayment -Name "mode" -Default "Keysend")
    }
}
if ($Mode -notin @("Keysend", "Invoice", "Both")) {
    throw "Payment mode must be Keysend, Invoice, or Both"
}
if (-not $PSBoundParameters.ContainsKey("AmountCkb")) {
    $configuredAmount = "0.01"
    if ($null -ne $dailyPayment) {
        $configuredAmount = [string](Get-ObjectPropertyValue -Object $dailyPayment -Name "amountCkb" -Default "0.01")
    }
    $AmountCkb = [decimal]::Parse($configuredAmount, [System.Globalization.CultureInfo]::InvariantCulture)
}
if ($TimeoutSeconds -le 0) {
    $TimeoutSeconds = 120
    if ($null -ne $dailyPayment) {
        $TimeoutSeconds = [int](Get-ObjectPropertyValue -Object $dailyPayment -Name "timeoutSeconds" -Default 120)
    }
}
if ($TimeoutSeconds -le 0) {
    throw "Payment timeout must be positive"
}
if ([string]::IsNullOrWhiteSpace($InvoiceReceiverRpcUrl) -and $null -ne $dailyPayment) {
    $InvoiceReceiverRpcUrl = [string](Get-ObjectPropertyValue -Object $dailyPayment -Name "invoiceReceiverRpcUrl" -Default "")
}
if ([string]::IsNullOrWhiteSpace($InvoiceReceiverAuthTokenFile) -and $null -ne $dailyPayment) {
    $InvoiceReceiverAuthTokenFile = [string](Get-ObjectPropertyValue -Object $dailyPayment -Name "invoiceReceiverAuthTokenFile" -Default "")
}

$amountShannons = Convert-CkbToShannons -AmountCkb $AmountCkb
$maxFeeCkb = "0.001"
if ($null -ne $dailyPayment) {
    $maxFeeCkb = [string](Get-ObjectPropertyValue -Object $dailyPayment -Name "maxFeeCkb" -Default "0.001")
}
$maxFeeShannons = Convert-CkbToShannons -AmountCkb (
    [decimal]::Parse($maxFeeCkb, [System.Globalization.CultureInfo]::InvariantCulture)
)

function Get-ReadyPaymentChannel {
    $channels = @(Get-PeerChannels -Settings $settings | Where-Object { Test-ChannelReady -Channel $_ })
    if ($channels.Count -eq 0) {
        throw "No ChannelReady channel exists for payment peer $($settings.peer.pubkey)"
    }
    return $channels[0]
}

function Wait-PaymentSuccess {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InitialPayment
    )

    $payment = $InitialPayment
    $paymentHash = [string]$payment.payment_hash
    if ([string]::IsNullOrWhiteSpace($paymentHash)) {
        throw "send_payment returned no payment_hash"
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds + 15)
    while ([string]$payment.status -notin @("Success", "Failed")) {
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Payment $paymentHash did not finish within $TimeoutSeconds seconds; last status: $($payment.status)"
        }
        Write-Host "Waiting for payment $paymentHash; status=$($payment.status)"
        Start-Sleep -Seconds 2
        $payment = Invoke-FiberRpc -Settings $settings -Method "get_payment" -Params @(@{
            payment_hash = $paymentHash
        })
    }
    if ([string]$payment.status -eq "Failed") {
        throw "Payment $paymentHash failed: $($payment.failed_error)"
    }
    return $payment
}

function Send-SmokePayment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [hashtable]$PaymentParams,
        [Parameter(Mandatory = $true)]
        [System.Numerics.BigInteger]$ExpectedAmount,
        [Parameter(Mandatory = $true)]
        [System.Numerics.BigInteger]$MaximumFee
    )

    $channelBefore = Get-ReadyPaymentChannel
    $localBefore = ConvertFrom-HexQuantity -Value ([string]$channelBefore.local_balance)
    $remoteBefore = ConvertFrom-HexQuantity -Value ([string]$channelBefore.remote_balance)
    if ($localBefore -lt ($ExpectedAmount + $MaximumFee)) {
        throw "Insufficient local balance for $Label payment and fee allowance"
    }

    Write-Host "$Label payment"
    [pscustomobject]@{
        Amount       = (Format-CkbBalance -Shannons $ExpectedAmount) + " CKB"
        LocalBefore  = (Format-CkbBalance -Shannons $localBefore) + " CKB"
        RemoteBefore = (Format-CkbBalance -Shannons $remoteBefore) + " CKB"
    } | Format-List
    Write-Host (Format-FiberLiquidityBar -LocalBalance $localBefore -RemoteBalance $remoteBefore)

    $initialPayment = Invoke-FiberRpc -Settings $settings -Method "send_payment" -Params @($PaymentParams) -TimeoutSeconds 60
    $payment = Wait-PaymentSuccess -InitialPayment $initialPayment
    $channelAfter = Get-ReadyPaymentChannel
    $localAfter = ConvertFrom-HexQuantity -Value ([string]$channelAfter.local_balance)
    $remoteAfter = ConvertFrom-HexQuantity -Value ([string]$channelAfter.remote_balance)
    $fee = ConvertFrom-HexQuantity -Value ([string]$payment.fee)

    Write-Host "$Label payment succeeded"
    [pscustomobject]@{
        PaymentHash = [string]$payment.payment_hash
        Amount      = (Format-CkbBalance -Shannons $ExpectedAmount) + " CKB"
        Fee         = (Format-CkbBalance -Shannons $fee) + " CKB"
        LocalAfter  = (Format-CkbBalance -Shannons $localAfter) + " CKB"
        RemoteAfter = (Format-CkbBalance -Shannons $remoteAfter) + " CKB"
    } | Format-List
    Write-Host (Format-FiberLiquidityBar -LocalBalance $localAfter -RemoteBalance $remoteAfter)
}

if ($Mode -in @("Keysend", "Both")) {
    $keysendParams = @{
        target_pubkey  = [string]$settings.peer.pubkey
        amount         = ConvertTo-HexQuantity -Value $amountShannons
        timeout        = ConvertTo-HexQuantity -Value ([System.Numerics.BigInteger]$TimeoutSeconds)
        max_fee_amount = "0x0"
        keysend        = $true
        dry_run        = $false
    }
    Send-SmokePayment -Label "Keysend" -PaymentParams $keysendParams `
        -ExpectedAmount $amountShannons -MaximumFee ([System.Numerics.BigInteger]::Zero)
}

if ($Mode -in @("Invoice", "Both")) {
    if ([string]::IsNullOrWhiteSpace($Invoice)) {
        if ([string]::IsNullOrWhiteSpace($InvoiceReceiverRpcUrl)) {
            throw "Invoice mode needs -Invoice or dailyPayment.invoiceReceiverRpcUrl for a receiver you control"
        }
        $receiverSettings = [pscustomobject]@{
            rpcUrl        = $InvoiceReceiverRpcUrl
            authTokenFile = $InvoiceReceiverAuthTokenFile
        }
        $invoiceResult = Invoke-FiberRpc -Settings $receiverSettings -Method "new_invoice" -Params @(@{
            amount         = ConvertTo-HexQuantity -Value $amountShannons
            currency       = "Fibt"
            description    = "fiber-windows-smoke daily invoice"
            expiry         = ConvertTo-HexQuantity -Value ([System.Numerics.BigInteger]3600)
            hash_algorithm = "sha256"
            allow_mpp      = $false
        })
        $Invoice = [string]$invoiceResult.invoice_address
        if ([string]::IsNullOrWhiteSpace($Invoice)) {
            throw "Receiver new_invoice returned no invoice_address"
        }
        Write-Host "Created a fresh $(Format-CkbBalance -Shannons $amountShannons) CKB invoice through $InvoiceReceiverRpcUrl"
    }

    $parsedInvoice = Invoke-FiberRpc -Settings $settings -Method "parse_invoice" -Params @(@{
        invoice = $Invoice
    })
    if ([string]$parsedInvoice.invoice.currency -ne "Fibt") {
        throw "Invoice currency must be Fibt for CKB testnet"
    }
    $invoiceAmount = ConvertFrom-HexQuantity -Value ([string]$parsedInvoice.invoice.amount)
    if ($invoiceAmount -ne $amountShannons) {
        throw "Invoice amount is $(Format-CkbBalance -Shannons $invoiceAmount) CKB, expected $(Format-CkbBalance -Shannons $amountShannons) CKB"
    }
    $invoiceParams = @{
        invoice        = $Invoice
        timeout        = ConvertTo-HexQuantity -Value ([System.Numerics.BigInteger]$TimeoutSeconds)
        max_fee_amount = ConvertTo-HexQuantity -Value $maxFeeShannons
        keysend        = $false
        dry_run        = $false
    }
    Send-SmokePayment -Label "Invoice" -PaymentParams $invoiceParams `
        -ExpectedAmount $invoiceAmount -MaximumFee $maxFeeShannons
}
