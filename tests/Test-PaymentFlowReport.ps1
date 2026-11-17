[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Run BOTH production payment scripts. The fixture module contains production
# arithmetic/channel helpers, but no HTTP implementation or reachable node.
$projectRoot = Split-Path -Parent $PSScriptRoot
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("fiber-report-test-" + [Guid]::NewGuid().ToString("N"))
$environmentNames = @("GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY", "FIBER_REPORT_TEST_CASE", "FIBER_REPORT_TEST_TRACE", "FIBER_REPORT_TEST_STATE")
$originalEnvironment = @{}
foreach ($name in $environmentNames) { $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process") }

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ([string]$Actual -cne [string]$Expected) { throw "$Label expected '$Expected', got '$Actual'" }
}
function Assert-Contains {
    param([string]$Text, [string]$Expected, [string]$Label)
    if (-not $Text.Contains($Expected)) { throw "$Label is missing '$Expected'; actual: $Text" }
}

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    foreach ($script in @("Send-PaymentFlow.ps1", "Send-DailyPayment.ps1")) {
        Copy-Item -LiteralPath (Join-Path $projectRoot "scripts/$script") -Destination $tempRoot
    }
    $tokens = $null
    $parseErrors = $null
    $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $projectRoot "scripts/FiberWindows.psm1"), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "Cannot parse production module for offline fixture" }
    $pureFunctions = @(
        "Get-ObjectPropertyValue", "Convert-CkbToShannons", "ConvertTo-HexQuantity",
        "ConvertFrom-HexQuantity", "Format-CkbBalance", "Format-FiberLiquidityBar", "Get-FiberForwardingFee",
        "Assert-FiberDirectPaymentBalance", "Assert-FiberRoutedPaymentBalance", "Get-ChannelStateName", "Test-ChannelReady",
        "New-FiberPaymentSnapshot", "Get-FiberPaymentSnapshot", "Assert-FiberPaymentLiquidity",
        "Assert-FiberPaymentSnapshotStable", "Get-FiberForwardedChannel"
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
function Assert-ReportNotWritten {
    if ((Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw) -match '(?m)^report=') { throw "Report written before flow ended" }
}
function Resolve-FiberSettingsPath { param($SettingsPath, $ScriptRoot) return $SettingsPath }
function Import-FiberSettings {
    param([string]$SettingsPath)
    if ($SettingsPath -notin @("fixture-primary", "fixture-secondary")) { throw "Unexpected settings path" }
    return [pscustomobject]@{
        id = $SettingsPath
        peer = [pscustomobject]@{ pubkey = $(if ($SettingsPath -eq "fixture-primary") { "02" + ("b" * 64) } else { "03" + ("a" * 64) }) }
        paymentFlow = [pscustomobject]@{
            enabled = ($env:FIBER_REPORT_TEST_CASE -ne "disabled")
            invoiceAmountCkb = "0.02000001"; keysendAmountCkb = "0.01000002"
            routedKeysendAmountCkb = "0.03000003"; routedMaxFeeCkb = "0.001"
        }
    }
}
function Wait-FiberRpc {
    param($Settings, [int]$TimeoutSeconds)
    Assert-ReportNotWritten
    Add-Content -LiteralPath $env:FIBER_REPORT_TEST_TRACE -Value "rpc:$($Settings.id)"
    return [pscustomobject]@{ pubkey = $(if ($Settings.id -eq "fixture-primary") { "03" + ("a" * 64) } else { "02" + ("c" * 64) }) }
}
function Get-PeerChannels {
    param($Settings, [switch]$IncludeClosed)
    Assert-ReportNotWritten
    if (-not $IncludeClosed) { throw "Payment inventory must include closed channels" }
    $state = Get-Content -LiteralPath $env:FIBER_REPORT_TEST_STATE -Raw | ConvertFrom-Json
    $phase = $state.phase
    if ($Settings.id -eq "fixture-primary") {
        if ($phase -eq 1 -and $env:FIBER_REPORT_TEST_CASE -eq "channel-rpc-failed") { throw "Fixture list_channels failed before send" }
        if ($phase -eq 2 -and $env:FIBER_REPORT_TEST_CASE -eq "post-payment-rpc-failed") { throw "Fixture list_channels failed after settlement" }
    }
    $local = [System.Numerics.BigInteger]::Parse("190097000000")
    $remote = [System.Numerics.BigInteger]::Parse("15103000000")
    if ($Settings.id -eq "fixture-primary") {
        if ($phase -ge 2) { $local -= 1000002; $remote += 1000002 }
        if ($phase -ge 3) {
            $local -= 3000003; $remote += 3000003
            if ($env:FIBER_REPORT_TEST_CASE -eq "second-hop-failed") { $local += [System.Numerics.BigInteger]::One }
            Add-Content -LiteralPath $env:FIBER_REPORT_TEST_TRACE -Value "second-hop-snapshot"
        }
        if ($env:FIBER_REPORT_TEST_CASE -eq "preflight-no-liquidity") { $local = [System.Numerics.BigInteger]::Zero }
        if ($phase -eq 1 -and $env:FIBER_REPORT_TEST_CASE -eq "keysend-liquidity-lost") { $local = [System.Numerics.BigInteger]::Zero }
        if ($env:FIBER_REPORT_TEST_CASE -eq "preflight-whole-budget") { $local = [System.Numerics.BigInteger]::Parse("3500000") }
    }
    else {
        $local = [System.Numerics.BigInteger]::Parse("490096000000")
        $remote = [System.Numerics.BigInteger]::Parse("4000000")
        if ($phase -ge 1) { $local -= 2000001; $remote += 2000001 }
        if ($phase -ge 3) { $local -= (3000003 + $state.routedFee); $remote += (3000003 + $state.routedFee) }
        if ($phase -eq 1 -and $env:FIBER_REPORT_TEST_CASE -eq "direct-assertion-failed") { $local += [System.Numerics.BigInteger]::One }
        if ($phase -eq 3 -and $env:FIBER_REPORT_TEST_CASE -eq "first-hop-failed") { $local += [System.Numerics.BigInteger]::One }
    }
    $channelState = if ($env:FIBER_REPORT_TEST_CASE -eq "preflight-no-liquidity" -and $Settings.id -eq "fixture-primary") { "Closed" } else { "ChannelReady" }
    $funded = [pscustomobject]@{
        channel_id = "funded"; state = [pscustomobject]@{ state_name = $channelState }
        local_balance = ConvertTo-HexQuantity $local; remote_balance = ConvertTo-HexQuantity $remote
        enabled = $true; is_one_way = $false; is_acceptor = $false
        offered_tlc_balance = "0x0"; funding_udt_type_script = $null; tlc_fee_proportional_millionths = "0x3e8"
    }
    $empty = [pscustomobject]@{
        channel_id = "new-empty"; state = [pscustomobject]@{ state_name = "ChannelReady" }
        local_balance = "0x0"; remote_balance = "0x0"; enabled = $true
        is_one_way = $false; is_acceptor = $true; offered_tlc_balance = "0x0"
        funding_udt_type_script = $null; tlc_fee_proportional_millionths = "0x0"
    }
    if ($channelState -eq "Closed") {
        $funded.local_balance = ConvertTo-HexQuantity ([System.Numerics.BigInteger]::Parse("189830000000"))
        $empty.remote_balance = ConvertTo-HexQuantity ([System.Numerics.BigInteger]::Parse("90000000000"))
    }
    if ($phase -ge 2 -and $env:FIBER_REPORT_TEST_CASE -eq "channel-set-changed" -and $Settings.id -eq "fixture-primary") { $empty.channel_id = "replacement" }
    # Deliberately put a zero-balance Ready channel first and change order later.
    if ($phase -ge 2) { return @($funded, $empty) }
    return @($empty, $funded)
}
function Start-Sleep { param([int]$Seconds) } # No wall-clock waits in offline polling cases.
function Invoke-FiberRpc {
    param($Settings, [string]$Method, $Params, [int]$TimeoutSeconds)
    Assert-ReportNotWritten
    if ($Method -eq "new_invoice" -and $Settings.id -eq "fixture-primary") {
        if ($Params[0].amount -ne "0x1e8481") { throw "Wrong invoice amount" }
        Add-Content -LiteralPath $env:FIBER_REPORT_TEST_TRACE -Value "new-invoice"
        return [pscustomobject]@{ invoice_address = "offline-fixture-invoice" }
    }
    if ($Method -eq "parse_invoice" -and $Settings.id -eq "fixture-secondary") {
        Add-Content -LiteralPath $env:FIBER_REPORT_TEST_TRACE -Value "parse-invoice"
        return [pscustomobject]@{ invoice = [pscustomobject]@{ currency = "Fibt"; amount = "0x1e8481" } }
    }
    if ($Method -eq "get_payment") {
        Add-Content -LiteralPath $env:FIBER_REPORT_TEST_TRACE -Value "get:invoice"
        if ($env:FIBER_REPORT_TEST_CASE -eq "poll-timeout") { throw "Fixture get_payment timed out" }
        return [pscustomobject]@{
            status = $(if ($env:FIBER_REPORT_TEST_CASE -eq "poll-failed") { "Failed" } else { "Success" })
            payment_hash = "0x" + ("1" * 64); fee = "0x0"; failed_error = "Fixture polled payment failed"
        }
    }
    if ($Method -ne "send_payment") { throw "Unexpected RPC call: $Method" }
    $params = $Params[0]
    # Preserve automatic routing; fixture forbids route pinning and retries.
    foreach ($key in @("router", "hop_hints", "channel_id")) { if ($params.ContainsKey($key)) { throw "Route was pinned" } }
    if ($params.dry_run) { throw "Smoke flow should exercise actual payment code against this offline fake" }
    $state = Get-Content -LiteralPath $env:FIBER_REPORT_TEST_STATE -Raw | ConvertFrom-Json
    $key = if (-not $params.keysend) { "invoice" } elseif ($Settings.id -eq "fixture-primary") { "keysend" } else { "routed" }
    $phase = @{ invoice = 1; keysend = 2; routed = 3 }[$key]
    if ($phase -ne ($state.phase + 1)) { throw "Payment retried or sent out of order" }
    if ($key -eq "routed") {
        if ($params.amount -ne "0x2dc6c3" -or $params.max_fee_amount -ne "0x186a0") { throw "Wrong routed amount or fee cap" }
    }
    elseif ($params.max_fee_amount -ne "0x0") { throw "Exact direct payment did not request zero fee" }
    Add-Content -LiteralPath $env:FIBER_REPORT_TEST_TRACE -Value "send:$key"
    $status = "Success"
    if (($key -eq "invoice" -and $env:FIBER_REPORT_TEST_CASE -eq "payment-failed") -or
        ($key -eq "keysend" -and $env:FIBER_REPORT_TEST_CASE -eq "keysend-failed")) { $status = "Failed" }
    if ($status -eq "Success") { $state.phase = $phase }
    $state | ConvertTo-Json -Compress | Set-Content -LiteralPath $env:FIBER_REPORT_TEST_STATE -Encoding UTF8
    if ($key -eq "keysend" -and $env:FIBER_REPORT_TEST_CASE -eq "rpc-timeout") { throw "Fixture RPC response timed out" }
    if ($key -eq "invoice" -and $env:FIBER_REPORT_TEST_CASE -like "poll-*") { $status = "InFlight" }
    return [pscustomobject]@{
        status = $status; payment_hash = "0x" + ([string]$phase * 64)
        fee = $(if ($key -eq "routed") { ConvertTo-HexQuantity ([System.Numerics.BigInteger]$state.routedFee) } else { "0x0" })
        failed_error = "Fixture payment failed"
    }
}
'@
    $fixtureModule -join "`n" | Set-Content -LiteralPath (Join-Path $tempRoot "FiberWindows.psm1") -Encoding UTF8
    $cases = @(
        @{ Name = "success"; Failure = "" },
        @{ Name = "disabled"; Failure = "" },
        @{ Name = "poll-success"; Failure = "" },
        @{ Name = "poll-failed"; Failure = "Fixture polled payment failed" },
        @{ Name = "poll-timeout"; Failure = "Fixture get_payment timed out" },
        @{ Name = "preflight-no-liquidity"; Failure = "insufficient outbound CKB liquidity" },
        @{ Name = "preflight-whole-budget"; Failure = "insufficient outbound CKB liquidity" },
        @{ Name = "payment-failed"; Failure = "Fixture payment failed" },
        @{ Name = "keysend-failed"; Failure = "Fixture payment failed" },
        @{ Name = "keysend-liquidity-lost"; Failure = "insufficient outbound CKB liquidity" },
        @{ Name = "channel-rpc-failed"; Failure = "Fixture list_channels failed before send" },
        @{ Name = "post-payment-rpc-failed"; Failure = "Fixture list_channels failed after settlement" },
        @{ Name = "direct-assertion-failed"; Failure = "Invoice local balance assertion failed" },
        @{ Name = "first-hop-failed"; Failure = "first-hop local balance assertion failed" },
        @{ Name = "second-hop-failed"; Failure = "Routed second hop local balance assertion failed" },
        @{ Name = "fee-mismatch"; Failure = "routing fee assertion failed" },
        @{ Name = "rpc-timeout"; Failure = "Fixture RPC response timed out" },
        @{ Name = "channel-set-changed"; Failure = "channel set changed" }
    )
    foreach ($case in $cases) {
        $env:FIBER_REPORT_TEST_CASE = $case.Name
        $env:GITHUB_OUTPUT = Join-Path $tempRoot ($case.Name + ".output")
        $env:GITHUB_STEP_SUMMARY = Join-Path $tempRoot ($case.Name + ".summary")
        $env:FIBER_REPORT_TEST_TRACE = Join-Path $tempRoot ($case.Name + ".trace")
        $env:FIBER_REPORT_TEST_STATE = Join-Path $tempRoot ($case.Name + ".state")
        @{ phase = 0; routedFee = $(if ($case.Name -eq "fee-mismatch") { 3002 } else { 3001 }) } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $env:FIBER_REPORT_TEST_STATE -Encoding UTF8
        "existing_output=preserved" | Set-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding UTF8
        $failure = ""
        try {
            & (Join-Path $tempRoot "Send-PaymentFlow.ps1") -PrimarySettingsPath "fixture-primary" -SecondarySettingsPath "fixture-secondary" -Scheduled 6>$null
        }
        catch { $failure = $_.Exception.Message }
        if ([string]::IsNullOrEmpty($case.Failure)) { Assert-Equal $failure "" "$($case.Name) execution" }
        else { Assert-Contains $failure $case.Failure "$($case.Name) failure" }
        $lines = @(Get-Content -LiteralPath $env:GITHUB_OUTPUT)
        Assert-Equal $lines[0] "existing_output=preserved" "Existing Actions output"
        $reports = @($lines | Where-Object { $_.StartsWith("report=") })
        Assert-Equal $reports.Count 1 "$($case.Name) report count"
        Assert-Equal $lines.Count 2 "Compact JSON must occupy one Actions output line"
        $report = $reports[0].Substring("report=".Length) | ConvertFrom-Json
        if ($case.Name -eq "disabled") {
            Assert-Equal $report.status "disabled" "Disabled report status"
            Assert-Equal $report.reason "Payment flow is disabled in settings; nothing sent" "Disabled reason"
            Assert-Equal $report.scenarios.Count 0 "Disabled scenarios"
            if (Test-Path -LiteralPath $env:FIBER_REPORT_TEST_TRACE) { throw "Disabled flow performed RPC work" }
            continue
        }
        $summary = Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw
        $trace = @(Get-Content -LiteralPath $env:FIBER_REPORT_TEST_TRACE)
        if (-not [string]::IsNullOrEmpty($case.Failure)) {
            Assert-Equal $report.status "failure" "Failed report status"
            Assert-Contains $report.failure.reason $case.Failure "Structured failure reason"
            Assert-Contains $summary $case.Failure "Summary failure reason"
            if ($case.Name -like "preflight-*") {
                Assert-Equal $report.failure.stage "preflight" "Preflight failure stage"
                Assert-Equal $report.failure.source "liquidity" "Preflight failure source"
                Assert-Equal $report.liquidity_status "failed" "Liquidity result"
                Assert-Equal (($report.scenarios | ForEach-Object status) -join ",") "not_started,not_started,not_started" "Nothing sent"
                Assert-Equal ($trace -join ",") "rpc:fixture-primary,rpc:fixture-secondary" "No invoice or send before budget checked"
                Assert-Contains $summary "Closed" "Closed inventory evidence"
            }
            else {
                $index = if ($case.Name -in @("payment-failed", "direct-assertion-failed", "poll-failed", "poll-timeout")) { 0 } elseif ($case.Name -in @("keysend-failed", "rpc-timeout", "channel-set-changed", "keysend-liquidity-lost", "channel-rpc-failed", "post-payment-rpc-failed")) { 1 } else { 2 }
                $active = $report.scenarios[$index]
                $expectedStatus = if ($case.Name -in @("rpc-timeout", "poll-timeout")) { "unknown" } elseif ($case.Name -in @("payment-failed", "keysend-failed", "poll-failed", "channel-rpc-failed")) { "failed" } elseif ($case.Name -eq "keysend-liquidity-lost") { "blocked" } else { "unverified" }
                Assert-Equal $active.status $expectedStatus "Active payment state"
                $expectedSubmitted = $case.Name -notin @("keysend-liquidity-lost", "channel-rpc-failed")
                Assert-Equal $active.submitted $expectedSubmitted "Active payment submitted"
                if ($case.Name -eq "poll-timeout") {
                    Assert-Equal $active.payment_hash ("0x" + ("1" * 64)) "Known hash retained after polling timeout"
                    Assert-Equal $report.failure.source "fiber_rpc" "Polling failure source"
                }
                if ($expectedStatus -eq "unverified") {
                    Assert-Equal $active.payment_status "Success" "Settled payment remains recorded"
                    $expectedSource = if ($case.Name -eq "post-payment-rpc-failed") { "fiber_rpc" } else { "balance_verification" }
                    Assert-Equal $report.failure.source $expectedSource "Verification failure source"
                }
                if ($case.Name -eq "channel-rpc-failed") { Assert-Equal $report.failure.source "fiber_rpc" "RPC error is not a liquidity error" }
                if ($case.Name -eq "keysend-liquidity-lost") {
                    Assert-Equal $report.failure.source "liquidity" "Per-send liquidity recheck"
                    if (($trace -join ",").Contains("send:keysend")) { throw "Sent despite exhausted outbound liquidity" }
                }
                for ($i = 0; $i -lt $index; $i++) {
                    Assert-Equal $report.scenarios[$i].status "success" "Verified prefix retained"
                    Assert-Contains $summary $report.scenarios[$i].payment_hash "Prefix payment hash retained"
                    if ($report.scenarios[$i].balances.Count -eq 0) { throw "Verified balances missing from failed report" }
                }
                for ($i = $index + 1; $i -lt 3; $i++) { Assert-Equal $report.scenarios[$i].status "not_started" "Unsent suffix" }
            }
            continue
        }
        Assert-Equal $report.status "success" "Verified report status"
        Assert-Equal $report.scenarios.Count 3 "Verified scenario count"
        $expectedTrace = "rpc:fixture-primary,rpc:fixture-secondary,new-invoice,parse-invoice,send:invoice,send:keysend,send:routed,second-hop-snapshot"
        if ($case.Name -eq "poll-success") { $expectedTrace = $expectedTrace.Replace("send:invoice,send:keysend", "send:invoice,get:invoice,send:keysend") }
        Assert-Equal ($trace -join ",") $expectedTrace "Flow order; no retry or pinning"
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
                    @("Node B / B-to-A", "4900.93999999", "4900.90996995", "Node B / B-to-A"),
                    @("Node A incoming / B-to-A", "0.06000001", "0.09003005", "Node A incoming / B-to-A"),
                    @("Node A outgoing / A-to-CkbaNode-1", "1900.95999998", "1900.92999995", "Node A outgoing / A-to-CkbaNode-1"),
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
                Assert-Contains $section "- **Forwarding fee rate:** $($scenario.fee_rate_millionths) millionths" "Summary routing fee rate"
            }
            else { Assert-Contains $section "- **Routing fee:** $($scenario.fee_ckb) CKB" "Summary direct fee" }
        }
    }
    Write-Host "Payment flow report checks passed (18 offline cases using both production payment scripts)"
}
finally {
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], "Process") }
    Get-Module -Name FiberWindows | Where-Object { $_.Path -eq (Join-Path $tempRoot "FiberWindows.psm1") } | Remove-Module -Force
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
