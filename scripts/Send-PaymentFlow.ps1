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

function Format-FlowCkb {
    param([Parameter(Mandatory = $true)][System.Numerics.BigInteger]$Shannons)
    return (Format-CkbBalance -Shannons $Shannons).TrimEnd("0").TrimEnd(".")
}

function Complete-FlowScenario {
    param([hashtable]$Scenario, [object]$Payment, [string]$LocalLabel, [string]$RemoteLabel)
    if ($Payment.Status -ne "Success" -or $Payment.Assertions -ne "Passed") {
        throw "Payment did not return a verified success result"
    }
    $Scenario.status = "success"
    $Scenario.payment_status = "Success"
    $Scenario.submitted = $true
    $Scenario.payment_hash = [string]$Payment.PaymentHash
    $Scenario.fee_ckb = Format-FlowCkb $Payment.Fee
    $Scenario.fee_shannons = [string]$Payment.Fee
    $Scenario.assertions = "Exact amount, zero fee, and balance conservation passed"
    $Scenario.balances = @(
        @{ label = $LocalLabel; before_ckb = Format-FlowCkb $Payment.LocalBefore; after_ckb = Format-FlowCkb $Payment.LocalAfter }
        @{ label = $RemoteLabel; before_ckb = Format-FlowCkb $Payment.RemoteBefore; after_ckb = Format-FlowCkb $Payment.RemoteAfter }
    )
}

function Add-FlowChannelInventory {
    param([object]$Snapshot, [string]$Node)
    foreach ($channel in $Snapshot.Channels) {
        $entry = [ordered]@{
            node = $Node; channel_id = $channel.Id; state = $channel.State; asset = $channel.Asset
            state_flags = $channel.StateFlags; shutdown_transaction_hash = $channel.ShutdownTransaction
            enabled = $channel.Enabled; outbound = $channel.Outbound
            local_ckb = $(if ($channel.Asset -eq "CKB") { Format-FlowCkb $channel.Local } else { $null })
            remote_ckb = $(if ($channel.Asset -eq "CKB") { Format-FlowCkb $channel.Remote } else { $null })
            available_ckb = Format-FlowCkb $channel.Available
        }
        $paymentReport.channels += $entry
        Write-Host "$Node channel=$($channel.Id) state=$($channel.State) asset=$($channel.Asset) outbound=$($channel.Outbound) available=$($entry.available_ckb) CKB"
    }
}

function Write-FlowReport {
    # A failed step still exports its verified prefix and the active payment's
    # last known state. Report once, then preserve the original terminating error.
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
        $json = $paymentReport | ConvertTo-Json -Depth 12 -Compress
        "report=$json" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
    }
    $lines = @("## Actual payment result", "", "**Payment flow:** $($paymentReport.status)", "")
    if ($null -ne $paymentReport.failure) {
        $failure = $paymentReport.failure
        $lines += "**Failure:** [$($failure.source)] $($failure.stage): $($failure.reason)", ""
    }
    if ($paymentReport.status -eq "disabled") { $lines += $paymentReport.reason }
    else {
        $headings = @("1. Invoice: Node B &rarr; Node A", "2. Keysend: Node A &rarr; CkbaNode-1", "3. Routed Keysend: Node B &rarr; Node A &rarr; CkbaNode-1")
        for ($i = 0; $i -lt $paymentReport.scenarios.Count; $i++) {
            $scenario = $paymentReport.scenarios[$i]
            $lines += "### $($headings[$i]) ($($scenario.amount_ckb) CKB)", ""
            $lines += "- **Status:** $($scenario.status) (Fiber: $($scenario.payment_status))"
            foreach ($balance in @($scenario.balances)) {
                $lines += "- **$($balance.label):** $($balance.before_ckb) &rarr; $($balance.after_ckb) CKB"
            }
            if ($scenario.ContainsKey("fee_ckb")) {
                $lines += "- **Routing fee:** $($scenario.fee_ckb) CKB ($($scenario.fee_shannons) shannons)"
            }
            if ($scenario.ContainsKey("fee_rate_millionths")) {
                $lines += "- **Forwarding fee rate:** $($scenario.fee_rate_millionths) millionths"
            }
            if ($scenario.status -eq "success") { $lines += "- **Assertions:** &#x2705; $($scenario.assertions)" }
            if ($scenario.ContainsKey("reason")) { $lines += "- **Reason:** $($scenario.reason)" }
            if ($scenario.ContainsKey("payment_hash")) { $lines += "- **Payment hash:** $($scenario.payment_hash)" }
            $lines += ""
        }
        if ($paymentReport.channels.Count -gt 0) {
            $lines += "### Channel inventory before payments", "", "| Node | Channel ID | State | Asset | Outbound | Local | Remote | Available CKB |", "| --- | --- | --- | --- | --- | --- | --- | --- |"
            foreach ($channel in $paymentReport.channels) {
                $lines += "| $($channel.node) | $($channel.channel_id) | $($channel.state) $($channel.state_flags) | $($channel.asset) | $($channel.outbound) | $($channel.local_ckb) | $($channel.remote_ckb) | $($channel.available_ckb) |"
            }
            foreach ($channel in @($paymentReport.channels | Where-Object { -not [string]::IsNullOrEmpty($_.shutdown_transaction_hash) })) {
                $lines += "", "Shutdown transaction ($($channel.channel_id)): $($channel.shutdown_transaction_hash)"
            }
            $lines += "", "Available CKB excludes offered TLCs, closed/disabled channels, UDT channels, and receive-only channels. Balance assertions cover the same set of Ready CKB channels to the configured peer; product routing is automatic."
        }
    }
    $summary = $lines -join "`n"
    Write-Host $summary
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        $summary | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
    }
}

$paymentReport = [ordered]@{
    schema_version = 2; status = "running"; stage = "setup"; liquidity_status = "not_checked"
    failure = $null; channels = @()
    scenarios = @("invoice", "keysend", "routed" | ForEach-Object {
        @{ key = $_; status = "not_started"; payment_status = "not_sent"; submitted = $false; amount_ckb = "unavailable"; balances = @() }
    })
}
$activeScenario = -1
$progress = @{}
$failureSource = "configuration"
try {
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
            $paymentReport.status = "disabled"
            $paymentReport.reason = "Payment flow is disabled in settings; nothing sent"
            $paymentReport.scenarios = @()
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

    $paymentReport.scenarios[0].amount_ckb = Format-FlowCkb $invoiceAmount
    $paymentReport.scenarios[1].amount_ckb = Format-FlowCkb $keysendAmount
    $paymentReport.scenarios[2].amount_ckb = Format-FlowCkb $routedKeysendAmount
    $failureSource = "fiber_rpc"
    $primaryInfo = Wait-FiberRpc -Settings $primarySettings -TimeoutSeconds 60
    $secondaryInfo = Wait-FiberRpc -Settings $secondarySettings -TimeoutSeconds 60
    if (-not [string]::Equals([string]$secondarySettings.peer.pubkey, [string]$primaryInfo.pubkey,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        $failureSource = "configuration"
        throw "Node B is configured for $($secondarySettings.peer.pubkey), not node A $($primaryInfo.pubkey)"
    }

    $paymentReport.stage = "preflight"
    $paymentReport.liquidity_status = "checking"
    $primaryBefore = Get-FiberPaymentSnapshot -Settings $primarySettings
    $secondaryBefore = Get-FiberPaymentSnapshot -Settings $secondarySettings
    Add-FlowChannelInventory -Snapshot $primaryBefore -Node "A -> CkbaNode-1"
    Add-FlowChannelInventory -Snapshot $secondaryBefore -Node "B -> A"
    $failureSource = "liquidity"
    # Check the whole round before creating an invoice or sending any payment.
    # Direct payments request zero fee; B reserves the routed maximum fee.
    $null = Assert-FiberPaymentLiquidity -Snapshot $primaryBefore `
        -Amounts @($keysendAmount, $routedKeysendAmount) -Description "Node A -> CkbaNode-1 (whole flow)"
    $null = Assert-FiberPaymentLiquidity -Snapshot $secondaryBefore `
        -Amounts @($invoiceAmount, ($routedKeysendAmount + $routedMaxFee)) -Description "Node B -> Node A (whole flow)"
    $feeCandidates = @($primaryBefore.ReadyChannels | Where-Object { $_.Outbound -and $_.Available -ge $routedKeysendAmount } |
        Where-Object {
            $fee = Get-FiberForwardingFee -Amount $routedKeysendAmount -FeeRateMillionths $_.FeeRate
            $fee -gt [System.Numerics.BigInteger]::Zero -and $fee -le $routedMaxFee
        })
    if ($feeCandidates.Count -eq 0) {
        $failureSource = "fee_policy"
        throw "No usable A -> CkbaNode-1 channel offers a positive forwarding fee within the routed fee limit"
    }
    $paymentReport.liquidity_status = "passed"

    $paymentReport.stage = "invoice"
    $activeScenario = 0
    $progress = @{ failure_source = "fiber_rpc"; status = "failed"; submitted = $false; payment_status = "not_sent" }
    $invoiceResult = Invoke-FiberRpc -Settings $primarySettings -Method "new_invoice" -Params @(@{
        amount = ConvertTo-HexQuantity $invoiceAmount; currency = "Fibt"
        description = "fiber-windows-smoke node B to node A"; expiry = "0xe10"
        hash_algorithm = "sha256"; allow_mpp = $false
    })
    $invoice = [string]$invoiceResult.invoice_address
    if ([string]::IsNullOrWhiteSpace($invoice)) { throw "Node A new_invoice returned no invoice_address" }
    $invoicePayment = & (Join-Path $PSScriptRoot "Send-DailyPayment.ps1") `
        -SettingsPath $SecondarySettingsPath -Mode Invoice -AmountCkb $InvoiceAmountCkb `
        -Invoice $invoice -PassThru -AssertExactDirectBalance -PaymentProgress $progress
    Complete-FlowScenario $paymentReport.scenarios[0] $invoicePayment "Node B" "Node A"

    $paymentReport.stage = "keysend"
    $activeScenario = 1
    $progress = @{}
    $keysendPayment = & (Join-Path $PSScriptRoot "Send-DailyPayment.ps1") `
        -SettingsPath $PrimarySettingsPath -Mode Keysend -AmountCkb $KeysendAmountCkb `
        -PassThru -AssertExactDirectBalance -PaymentProgress $progress
    Complete-FlowScenario $paymentReport.scenarios[1] $keysendPayment "Node A" "CkbaNode-1"

    $paymentReport.stage = "routed"
    $activeScenario = 2
    $progress = @{ failure_source = "fiber_rpc"; status = "failed"; submitted = $false; payment_status = "not_sent" }
    $routedSecondHopBefore = Get-FiberPaymentSnapshot -Settings $primarySettings
    $progress.failure_source = "liquidity"
    $progress.status = "blocked"
    $null = Assert-FiberPaymentLiquidity -Snapshot $routedSecondHopBefore -Amounts @($routedKeysendAmount) -Description "Routed A -> CkbaNode-1 hop"
    $routedPayment = & (Join-Path $PSScriptRoot "Send-DailyPayment.ps1") `
        -SettingsPath $SecondarySettingsPath -Mode Keysend -AmountCkb $RoutedKeysendAmountCkb `
        -TargetPubkey ([string]$primarySettings.peer.pubkey) -PaymentLabel "Routed keysend B -> A -> CkbaNode-1" `
        -MaximumFeeCkb ($RoutedMaxFeeCkb.ToString([System.Globalization.CultureInfo]::InvariantCulture)) `
        -DeferRoutingFeeValidation -PassThru -AssertExactRoutedBalance -PaymentProgress $progress
    # Fiber settled the payment; it is not fully verified until BOTH hops and the
    # fee rate on the actual outgoing channel have been checked.
    $progress.status = "unverified"
    $progress.failure_source = "fiber_rpc"
    $paymentReport.stage = "routed_verification"
    $routedSecondHopAfter = Get-FiberPaymentSnapshot -Settings $primarySettings
    $progress.failure_source = "balance_verification"
    $actualChannel = Get-FiberForwardedChannel -Before $routedSecondHopBefore -After $routedSecondHopAfter -Amount $routedKeysendAmount
    $expectedFee = Get-FiberForwardingFee -Amount $routedKeysendAmount -FeeRateMillionths $actualChannel.FeeRate
    $null = Assert-FiberRoutedPaymentBalance -Label "Routed keysend" -ExpectedAmount $routedKeysendAmount `
        -ExpectedFee $expectedFee -ActualFee $routedPayment.Fee `
        -LocalBefore $routedPayment.LocalBefore -LocalAfter $routedPayment.LocalAfter `
        -RemoteBefore $routedPayment.RemoteBefore -RemoteAfter $routedPayment.RemoteAfter
    Complete-FlowScenario $paymentReport.scenarios[2] $routedPayment "Node B / B-to-A" "Node A incoming / B-to-A"
    $routed = $paymentReport.scenarios[2]
    $routed.fee_rate_millionths = [string]$actualChannel.FeeRate
    $routed.channel_id = $actualChannel.Id
    $routed.assertions = "Positive fee, exact first-hop amount plus fee, exact second-hop amount, and balance conservation passed"
    $routed.balances += @(
        @{ label = "Node A outgoing / A-to-CkbaNode-1"; before_ckb = Format-FlowCkb $routedSecondHopBefore.Local; after_ckb = Format-FlowCkb $routedSecondHopAfter.Local }
        @{ label = "CkbaNode-1"; before_ckb = Format-FlowCkb $routedSecondHopBefore.Remote; after_ckb = Format-FlowCkb $routedSecondHopAfter.Remote }
    )
    $paymentReport.status = "success"
    $paymentReport.stage = "complete"
}
catch {
    $paymentReport.status = "failure"
    if ($paymentReport.liquidity_status -eq "checking") { $paymentReport.liquidity_status = "failed" }
    $reason = $_.Exception.Message
    if ($activeScenario -ge 0) {
        $scenario = $paymentReport.scenarios[$activeScenario]
        foreach ($key in @("status", "payment_status", "submitted", "payment_hash", "fee_ckb", "fee_shannons", "balances")) {
            if ($progress.ContainsKey($key)) { $scenario[$key] = $progress[$key] }
        }
        if ($scenario.status -notin @("blocked", "failed", "unverified", "unknown")) {
            $scenario.status = if ($scenario.payment_status -eq "Success") { "unverified" } else { "failed" }
        }
        $scenario.reason = $reason
        if ($progress.ContainsKey("failure_source")) { $failureSource = $progress.failure_source }
    }
    $paymentReport.failure = @{ stage = $paymentReport.stage; source = $failureSource; reason = $reason }
    throw
}
finally {
    Write-FlowReport
}
