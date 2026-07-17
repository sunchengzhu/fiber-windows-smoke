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
