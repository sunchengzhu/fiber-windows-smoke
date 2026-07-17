[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) "scripts\FiberWindows.psm1") -Force

$originalProcessWorkingDirectory = [Environment]::CurrentDirectory
try {
    [Environment]::CurrentDirectory = [System.IO.Path]::GetTempPath()
    $expectedSettingsPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath "config\node-settings.json"))
    $resolvedSettingsPath = Resolve-FiberSettingsPath -SettingsPath ".\config\node-settings.json" -ScriptRoot $PSScriptRoot
    if (-not [string]::Equals($resolvedSettingsPath, $expectedSettingsPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Resolve-FiberSettingsPath used the process working directory instead of the PowerShell location: $resolvedSettingsPath"
    }
}
finally {
    [Environment]::CurrentDirectory = $originalProcessWorkingDirectory
}

if ((Convert-CkbToShannons -AmountCkb 2000) -ne [System.Numerics.BigInteger]::Parse("200000000000")) {
    throw "Convert-CkbToShannons produced an unexpected amount for 2000 CKB"
}
if ((Convert-CkbToShannons -AmountCkb 0.01) -ne [System.Numerics.BigInteger]::Parse("1000000")) {
    throw "Convert-CkbToShannons produced an unexpected amount for 0.01 CKB"
}
if ((Convert-CkbToShannons -AmountCkb 0.02) -ne [System.Numerics.BigInteger]::Parse("2000000")) {
    throw "Convert-CkbToShannons produced an unexpected amount for 0.02 CKB"
}
if ((Convert-CkbToShannons -AmountCkb 5000) -ne [System.Numerics.BigInteger]::Parse("500000000000")) {
    throw "Convert-CkbToShannons produced an unexpected amount for 5000 CKB"
}
if ((Convert-CkbToShannons -AmountCkb 1.00000001) -ne [System.Numerics.BigInteger]::Parse("100000001")) {
    throw "Convert-CkbToShannons did not preserve 8 decimal places"
}
if (-not (Test-FiberPeerInitPendingError -Message "Peer Pubkey(02ab)'s feature not found, waiting for peer to send Init message")) {
    throw "Test-FiberPeerInitPendingError rejected the transient Fiber Init error"
}
if (Test-FiberPeerInitPendingError -Message "Insufficient CKB balance") {
    throw "Test-FiberPeerInitPendingError accepted an unrelated error"
}

if ((ConvertTo-HexQuantity -Value ([System.Numerics.BigInteger]::Parse("49900000000"))) -ne "0xb9e459300") {
    throw "ConvertTo-HexQuantity produced an unexpected funding amount"
}
if ((ConvertTo-HexQuantity -Value ([System.Numerics.BigInteger]::Zero)) -ne "0x0") {
    throw "ConvertTo-HexQuantity produced an unexpected zero"
}
if ((ConvertFrom-HexQuantity -Value "0x2c42d7cd00") -ne [System.Numerics.BigInteger]::Parse("190100000000")) {
    throw "ConvertFrom-HexQuantity produced an unexpected local balance"
}
if ((Format-CkbBalance -Shannons ([System.Numerics.BigInteger]::Parse("190100000000"))) -ne "1901.00000000") {
    throw "Format-CkbBalance produced an unexpected CKB amount"
}

function Assert-ActionFails {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedMessage
    )

    $failed = $false
    try {
        & $Action | Out-Null
    }
    catch {
        $failed = $true
        if ($_.Exception.Message -notlike "*$ExpectedMessage*") {
            throw "Expected failure containing '$ExpectedMessage', got: $($_.Exception.Message)"
        }
    }
    if (-not $failed) {
        throw "Expected action to fail with '$ExpectedMessage'"
    }
}

$directPaymentAssertion = Assert-FiberDirectPaymentBalance `
    -Label "Invoice" `
    -ExpectedAmount ([System.Numerics.BigInteger]::Parse("2000000")) `
    -Fee ([System.Numerics.BigInteger]::Zero) `
    -LocalBefore ([System.Numerics.BigInteger]::Parse("490096000000")) `
    -LocalAfter ([System.Numerics.BigInteger]::Parse("490094000000")) `
    -RemoteBefore ([System.Numerics.BigInteger]::Parse("4000000")) `
    -RemoteAfter ([System.Numerics.BigInteger]::Parse("6000000"))
if ($directPaymentAssertion.Status -ne "Passed") {
    throw "Exact direct payment balance assertion did not pass"
}

Assert-ActionFails -ExpectedMessage "local balance assertion failed" -Action {
    Assert-FiberDirectPaymentBalance `
        -Label "Invoice" `
        -ExpectedAmount ([System.Numerics.BigInteger]::Parse("2000000")) `
        -Fee ([System.Numerics.BigInteger]::Zero) `
        -LocalBefore ([System.Numerics.BigInteger]::Parse("490096000000")) `
        -LocalAfter ([System.Numerics.BigInteger]::Parse("490094000001")) `
        -RemoteBefore ([System.Numerics.BigInteger]::Parse("4000000")) `
        -RemoteAfter ([System.Numerics.BigInteger]::Parse("6000000"))
}
Assert-ActionFails -ExpectedMessage "remote balance assertion failed" -Action {
    Assert-FiberDirectPaymentBalance `
        -Label "Keysend" `
        -ExpectedAmount ([System.Numerics.BigInteger]::Parse("1000000")) `
        -Fee ([System.Numerics.BigInteger]::Zero) `
        -LocalBefore ([System.Numerics.BigInteger]::Parse("190097000000")) `
        -LocalAfter ([System.Numerics.BigInteger]::Parse("190096000000")) `
        -RemoteBefore ([System.Numerics.BigInteger]::Parse("15103000000")) `
        -RemoteAfter ([System.Numerics.BigInteger]::Parse("15103999999"))
}
Assert-ActionFails -ExpectedMessage "fee assertion failed" -Action {
    Assert-FiberDirectPaymentBalance `
        -Label "Keysend" `
        -ExpectedAmount ([System.Numerics.BigInteger]::Parse("1000000")) `
        -Fee ([System.Numerics.BigInteger]::One) `
        -LocalBefore ([System.Numerics.BigInteger]::Parse("190097000000")) `
        -LocalAfter ([System.Numerics.BigInteger]::Parse("190096000000")) `
        -RemoteBefore ([System.Numerics.BigInteger]::Parse("15103000000")) `
        -RemoteAfter ([System.Numerics.BigInteger]::Parse("15104000000"))
}

$liquidityBar = Format-FiberLiquidityBar `
    -LocalBalance ([System.Numerics.BigInteger]::Parse("190100000000")) `
    -RemoteBalance ([System.Numerics.BigInteger]::Parse("15100000000")) `
    -Width 20
if ($liquidityBar -ne "LOCAL 92.6413% [###################-] 7.3587% REMOTE") {
    throw "Format-FiberLiquidityBar produced an unexpected visualization: $liquidityBar"
}
$tinyRemoteLiquidityBar = Format-FiberLiquidityBar `
    -LocalBalance ([System.Numerics.BigInteger]::Parse("490098000000")) `
    -RemoteBalance ([System.Numerics.BigInteger]::Parse("2000000")) `
    -Width 24
if ($tinyRemoteLiquidityBar -ne "LOCAL 99.9996% [########################] 0.0004% REMOTE") {
    throw "Format-FiberLiquidityBar rounded a small non-zero balance to zero: $tinyRemoteLiquidityBar"
}

$modernChannel = [pscustomobject]@{
    state = [pscustomobject]@{ state_name = "ChannelReady" }
}
if ((Get-ChannelStateName -Channel $modernChannel) -ne "ChannelReady") {
    throw "Get-ChannelStateName did not parse the modern state shape"
}
if (-not (Test-ChannelReady -Channel $modernChannel)) {
    throw "Test-ChannelReady rejected ChannelReady"
}

$legacyChannel = [pscustomobject]@{ state = "CHANNEL_READY" }
if (-not (Test-ChannelReady -Channel $legacyChannel)) {
    throw "Test-ChannelReady rejected legacy CHANNEL_READY"
}

$rfcScript = [pscustomobject]@{
    code_hash = "0x9bd7e06f3ecf4be0f2fcd2188b23f1b9fcc88e5d4b65a8637b17723bbda3cce8"
    hash_type = "type"
    args      = "0xb39bbc0b3673c7d36450bc14cfcdad2d559c6c64"
}
$rfcAddress = ConvertTo-CkbAddress -Script $rfcScript -Network mainnet
if ($rfcAddress -ne "ckb1qzda0cr08m85hc8jlnfp3zer7xulejywt49kt2rr0vthywaa50xwsqdnnw7qkdnnclfkg59uzn8umtfd2kwxceqxwquc4") {
    throw "ConvertTo-CkbAddress does not match the RFC 0021 full address example: $rfcAddress"
}

Write-Host "Module unit checks passed"
