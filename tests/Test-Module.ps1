[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) "scripts\FiberWindows.psm1") -Force

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
