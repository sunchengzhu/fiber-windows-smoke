[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Run the production flow with no reachable network or payment implementation.
# Keep the production arithmetic and balance assertions in the fixture module so
# an invalid balance must actually fail before the report can claim success.
$projectRoot = Split-Path -Parent $PSScriptRoot
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("fiber-report-test-" + [Guid]::NewGuid().ToString("N"))
$environmentNames = @("GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY", "FIBER_REPORT_TEST_CASE", "FIBER_REPORT_TEST_TRACE")
$originalEnvironment = @{}
foreach ($name in $environmentNames) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ([string]$Actual -cne [string]$Expected) {
        throw "$Label expected '$Expected', got '$Actual'"
    }
}

function Assert-Contains {
    param([string]$Text, [string]$Expected, [string]$Label)
    if (-not $Text.Contains($Expected)) {
        throw "$Label is missing '$Expected'; actual: $Text"
    }
}

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot "scripts/Send-PaymentFlow.ps1") -Destination $tempRoot
    $tokens = $null
    $parseErrors = $null
    $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $projectRoot "scripts/FiberWindows.psm1"), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "Cannot parse production module for offline fixture" }
    $pureFunctions = @(
        "Get-ObjectPropertyValue", "Convert-CkbToShannons", "ConvertTo-HexQuantity",
        "ConvertFrom-HexQuantity", "Format-CkbBalance", "Get-FiberForwardingFee",
        "Assert-FiberDirectPaymentBalance", "Assert-FiberRoutedPaymentBalance"
    )
    $fixtureModule = @("Set-StrictMode -Version Latest", '$ErrorActionPreference = "Stop"')
    foreach ($functionName in $pureFunctions) {
        $definitions = @($moduleAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $true))
        if ($definitions.Count -ne 1) { throw "Expected one production function named $functionName" }
        $fixtureModule += $definitions[0].Extent.Text
    }
    $fixtureModule += @'
$script:primaryChannelReads = 0

function Assert-ReportNotWritten {
    if ((Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw) -match '(?m)^report=') {
        throw "Report was written before payments and both hop assertions completed"
    }
}

function Import-FiberSettings {
    param([string]$SettingsPath)
    if ($SettingsPath -notin @("fixture-primary", "fixture-secondary")) { throw "Unexpected settings path" }
    return [pscustomobject]@{
        id = $SettingsPath
        peer = [pscustomobject]@{ pubkey = $(if ($SettingsPath -eq "fixture-primary") { "public-node" } else { "node-a" }) }
        paymentFlow = [pscustomobject]@{
            enabled = ($env:FIBER_REPORT_TEST_CASE -ne "disabled")
            invoiceAmountCkb = "0.02000001"
            keysendAmountCkb = "0.01000002"
            routedKeysendAmountCkb = "0.03000003"
            routedMaxFeeCkb = "0.001"
        }
    }
}

function Wait-FiberRpc {
    param($Settings, [int]$TimeoutSeconds)
    Assert-ReportNotWritten
    Add-Content -LiteralPath $env:FIBER_REPORT_TEST_TRACE -Value "rpc:$($Settings.id)"
    return [pscustomobject]@{ pubkey = $(if ($Settings.id -eq "fixture-primary") { "node-a" } else { "node-b" }) }
}

function Get-PeerChannels {
    param($Settings)
    Assert-ReportNotWritten
    $local = [System.Numerics.BigInteger]::Parse("190095999998")
    $remote = [System.Numerics.BigInteger]::Parse("15104000002")
    if ($Settings.id -eq "fixture-primary") {
        $script:primaryChannelReads++
        if ($script:primaryChannelReads -eq 3) {
            $local = [System.Numerics.BigInteger]::Parse("190092999995")
            $remote = [System.Numerics.BigInteger]::Parse("15107000005")
            if ($env:FIBER_REPORT_TEST_CASE -eq "second-hop-failed") { $local += [System.Numerics.BigInteger]::One }
            Add-Content -LiteralPath $env:FIBER_REPORT_TEST_TRACE -Value "second-hop-snapshot"
        }
    }
    return [pscustomobject]@{
        local_balance = ConvertTo-HexQuantity -Value $local
        remote_balance = ConvertTo-HexQuantity -Value $remote
        tlc_fee_proportional_millionths = "0x3e8"
    }
}

function Test-ChannelReady {
    param($Channel)
    return $true
}

function Invoke-FiberRpc {
    param($Settings, [string]$Method, $Params)
    Assert-ReportNotWritten
    if ($Method -ne "new_invoice" -or $Settings.id -ne "fixture-primary") { throw "Unexpected RPC call" }
    if ($Params[0].amount -ne "0x1e8481") { throw "Invoice RPC amount did not match configured amount" }
    Add-Content -LiteralPath $env:FIBER_REPORT_TEST_TRACE -Value "new-invoice"
    return [pscustomobject]@{ invoice_address = "offline-fixture-invoice" }
}
'@
    $fixtureModule -join "`n" | Set-Content -LiteralPath (Join-Path $tempRoot "FiberWindows.psm1") -Encoding UTF8

    @'
[CmdletBinding()]
param(
    [string]$SettingsPath, [string]$Mode, [decimal]$AmountCkb, [string]$Invoice,
    [string]$TargetPubkey, [string]$PaymentLabel, [string]$MaximumFeeCkb,
    [System.Numerics.BigInteger]$ExpectedRoutingFee, [switch]$PassThru,
    [switch]$AssertExactDirectBalance, [switch]$AssertExactRoutedBalance
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Assert-ReportNotWritten
if (-not $PassThru) { throw "Flow did not request payment result" }
if ($env:FIBER_REPORT_TEST_CASE -eq "payment-failed") { throw "Fixture payment failed" }
$amount = Convert-CkbToShannons -AmountCkb $AmountCkb
if ($Mode -eq "Invoice") {
    if ($SettingsPath -ne "fixture-secondary" -or $Invoice -ne "offline-fixture-invoice") { throw "Wrong invoice arguments" }
    $key = "invoice"
    $localBefore = [System.Numerics.BigInteger]::Parse("490096000000")
    $remoteBefore = [System.Numerics.BigInteger]::Parse("4000000")
    $fee = [System.Numerics.BigInteger]::Zero
    $hashDigit = "1"
}
elseif ([string]::IsNullOrWhiteSpace($TargetPubkey)) {
    if ($Mode -ne "Keysend" -or $SettingsPath -ne "fixture-primary") { throw "Wrong direct keysend arguments" }
    $key = "keysend"
    $localBefore = [System.Numerics.BigInteger]::Parse("190097000000")
    $remoteBefore = [System.Numerics.BigInteger]::Parse("15103000000")
    $fee = [System.Numerics.BigInteger]::Zero
    $hashDigit = "2"
}
else {
    if ($Mode -ne "Keysend" -or $SettingsPath -ne "fixture-secondary" -or $TargetPubkey -ne "public-node") { throw "Wrong routed arguments" }
    if ($MaximumFeeCkb -ne "0.001" -or $ExpectedRoutingFee -ne 3001) { throw "Wrong routed fee arguments" }
    $key = "routed"
    $localBefore = [System.Numerics.BigInteger]::Parse("490093999999")
    $remoteBefore = [System.Numerics.BigInteger]::Parse("6000001")
    $fee = [System.Numerics.BigInteger]::Parse("3001")
    $hashDigit = "3"
}
$localAfter = $localBefore - $amount - $fee
$remoteAfter = $remoteBefore + $amount + $fee
if ($key -eq "invoice" -and $env:FIBER_REPORT_TEST_CASE -eq "direct-assertion-failed") { $localAfter += [System.Numerics.BigInteger]::One }
if ($key -eq "routed" -and $env:FIBER_REPORT_TEST_CASE -eq "first-hop-failed") { $localAfter += [System.Numerics.BigInteger]::One }
$balanceArguments = @{
    Label = $key; ExpectedAmount = $amount
    LocalBefore = $localBefore; LocalAfter = $localAfter
    RemoteBefore = $remoteBefore; RemoteAfter = $remoteAfter
}
if ($key -eq "routed") {
    if (-not $AssertExactRoutedBalance -or $AssertExactDirectBalance) { throw "Routed balance assertion not requested" }
    $null = Assert-FiberRoutedPaymentBalance @balanceArguments -ExpectedFee $ExpectedRoutingFee -ActualFee $fee
}
else {
    if (-not $AssertExactDirectBalance -or $AssertExactRoutedBalance) { throw "Direct balance assertion not requested" }
    $null = Assert-FiberDirectPaymentBalance @balanceArguments -Fee $fee
}
Add-Content -LiteralPath $env:FIBER_REPORT_TEST_TRACE -Value "verified:$key"
return [pscustomobject]@{
    Status = "Success"; Assertions = "Passed"; Fee = $fee
    LocalBefore = $localBefore; LocalAfter = $localAfter
    RemoteBefore = $remoteBefore; RemoteAfter = $remoteAfter
    PaymentHash = "0x" + ($hashDigit * 64)
}
'@ | Set-Content -LiteralPath (Join-Path $tempRoot "Send-DailyPayment.ps1") -Encoding UTF8

    $cases = @(
        @{ Name = "success"; Failure = "" },
        @{ Name = "disabled"; Failure = "" },
        @{ Name = "payment-failed"; Failure = "Fixture payment failed" },
        @{ Name = "direct-assertion-failed"; Failure = "invoice local balance assertion failed" },
        @{ Name = "first-hop-failed"; Failure = "routed first-hop local balance assertion failed" },
        @{ Name = "second-hop-failed"; Failure = "Routed keysend A -> CkbaNode-1 hop local balance assertion failed" }
    )
    foreach ($case in $cases) {
        $env:FIBER_REPORT_TEST_CASE = $case.Name
        $env:GITHUB_OUTPUT = Join-Path $tempRoot ($case.Name + ".output")
        $env:GITHUB_STEP_SUMMARY = Join-Path $tempRoot ($case.Name + ".summary")
        $env:FIBER_REPORT_TEST_TRACE = Join-Path $tempRoot ($case.Name + ".trace")
        "existing_output=preserved" | Set-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding UTF8
        $failure = ""
        try {
            & (Join-Path $tempRoot "Send-PaymentFlow.ps1") `
                -PrimarySettingsPath "fixture-primary" -SecondarySettingsPath "fixture-secondary" -Scheduled 6>$null
        }
        catch { $failure = $_.Exception.Message }
        if ([string]::IsNullOrEmpty($case.Failure)) {
            Assert-Equal $failure "" "$($case.Name) execution"
        }
        else { Assert-Contains $failure $case.Failure "$($case.Name) failure" }
        $lines = @(Get-Content -LiteralPath $env:GITHUB_OUTPUT)
        Assert-Equal $lines[0] "existing_output=preserved" "Existing Actions output"
        $reports = @($lines | Where-Object { $_.StartsWith("report=") })
        if (-not [string]::IsNullOrEmpty($case.Failure)) {
            Assert-Equal $reports.Count 0 "$($case.Name) report count"
            if (Test-Path -LiteralPath $env:GITHUB_STEP_SUMMARY) { throw "Failed flow wrote a success summary" }
            continue
        }
        Assert-Equal $reports.Count 1 "$($case.Name) report count"
        Assert-Equal $lines.Count 2 "Compact JSON must occupy one Actions output line"
        $report = $reports[0].Substring("report=".Length) | ConvertFrom-Json
        if ($case.Name -eq "disabled") {
            Assert-Equal $report.status "disabled" "Disabled report status"
            Assert-Equal $report.reason "Payment flow is disabled in settings; nothing sent" "Disabled report reason"
            if ($report.PSObject.Properties.Name -contains "scenarios") { throw "Disabled flow reported payment scenarios" }
            if (Test-Path -LiteralPath $env:FIBER_REPORT_TEST_TRACE) { throw "Disabled scheduled flow performed RPC or payment work" }
            continue
        }
        Assert-Equal $report.status "success" "Verified report status"
        Assert-Equal $report.scenarios.Count 3 "Verified scenario count"
        $trace = @(Get-Content -LiteralPath $env:FIBER_REPORT_TEST_TRACE)
        Assert-Equal ($trace -join ",") "rpc:fixture-primary,rpc:fixture-secondary,new-invoice,verified:invoice,verified:keysend,verified:routed,second-hop-snapshot" "Verified flow order"
        $summary = Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw
        $expected = @(
            @{
                Key = "invoice"; Amount = "0.02000001"; Fee = "0"; Shannons = "0"; HashDigit = "1"
                Heading = "1. Invoice: Node B &rarr; Node A"
                Balances = @(
                    @("Node B", "4900.96", "4900.93999999", "Node B"),
                    @("Node A", "0.04", "0.06000001", "Node A")
                )
            },
            @{
                Key = "keysend"; Amount = "0.01000002"; Fee = "0"; Shannons = "0"; HashDigit = "2"
                Heading = "2. Keysend: Node A &rarr; CkbaNode-1"
                Balances = @(
                    @("Node A", "1900.97", "1900.95999998", "Node A"),
                    @("CkbaNode-1", "151.03", "151.04000002", "CkbaNode-1")
                )
            },
            @{
                Key = "routed"; Amount = "0.03000003"; Fee = "0.00003001"; Shannons = "3001"; HashDigit = "3"
                Heading = "3. Routed Keysend: Node B &rarr; Node A &rarr; CkbaNode-1"
                Balances = @(
                    @("Node B / B-to-A", "4900.93999999", "4900.90996995", "Node B / B-to-A channel"),
                    @("Node A incoming / B-to-A", "0.06000001", "0.09003005", "Node A incoming / B-to-A channel"),
                    @("Node A outgoing / A-to-CkbaNode-1", "1900.95999998", "1900.92999995", "Node A outgoing / A-to-CkbaNode-1 channel"),
                    @("CkbaNode-1", "151.04000002", "151.07000005", "CkbaNode-1")
                )
            }
        )
        for ($i = 0; $i -lt $expected.Count; $i++) {
            $fixture = $expected[$i]
            $scenario = $report.scenarios[$i]
            Assert-Equal $scenario.key $fixture.Key "Scenario order"
            Assert-Equal $scenario.amount_ckb $fixture.Amount "$($fixture.Key) amount"
            Assert-Equal $scenario.fee_ckb $fixture.Fee "$($fixture.Key) fee CKB"
            Assert-Equal $scenario.fee_shannons $fixture.Shannons "$($fixture.Key) fee shannons"
            Assert-Equal $scenario.payment_hash ("0x" + ($fixture.HashDigit * 64)) "$($fixture.Key) hash"
            $heading = "### $($fixture.Heading) ($($fixture.Amount) CKB)"
            Assert-Contains $summary $heading "Summary amount and route"
            $section = ($summary.Substring($summary.IndexOf($heading)) -split "`n### ")[0]
            Assert-Contains $section "- **Payment hash:** $($scenario.payment_hash)" "Summary hash"
            Assert-Contains $section "- **Assertions:** &#x2705; $($scenario.assertions)" "Summary assertions"
            Assert-Equal $scenario.balances.Count $fixture.Balances.Count "$($fixture.Key) balance count"
            for ($j = 0; $j -lt $fixture.Balances.Count; $j++) {
                $balance = $scenario.balances[$j]
                $expectedBalance = $fixture.Balances[$j]
                Assert-Equal $balance.label $expectedBalance[0] "Balance label"
                Assert-Equal $balance.before_ckb $expectedBalance[1] "Balance before"
                Assert-Equal $balance.after_ckb $expectedBalance[2] "Balance after"
                Assert-Contains $section "- **$($expectedBalance[3]):** $($balance.before_ckb) &rarr; $($balance.after_ckb) CKB" "Summary balance"
            }
            if ($fixture.Key -eq "routed") {
                Assert-Equal $scenario.fee_rate_millionths "1000" "Routed fee rate"
                Assert-Contains $section "**$($scenario.fee_ckb) CKB** ($($scenario.fee_shannons) shannons, rate $($scenario.fee_rate_millionths) millionths)" "Summary routing fee"
            }
            else { Assert-Contains $section "- **Routing fee:** $($scenario.fee_ckb) CKB" "Summary direct fee" }
        }
    }
    Write-Host "Payment flow report checks passed (6 offline full-script cases)"
}
finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], "Process")
    }
    Get-Module -Name FiberWindows | Where-Object { $_.Path -eq (Join-Path $tempRoot "FiberWindows.psm1") } | Remove-Module -Force
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
