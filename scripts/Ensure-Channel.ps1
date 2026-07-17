[CmdletBinding()]
param(
    [string]$SettingsPath,
    [int]$TimeoutSeconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "FiberWindows.psm1") -Force
$SettingsPath = Resolve-FiberSettingsPath -SettingsPath $SettingsPath -ScriptRoot $PSScriptRoot
$settings = Import-FiberSettings -SettingsPath $SettingsPath

$nodeInfo = Wait-FiberRpc -Settings $settings -TimeoutSeconds 60
$ckbAddress = ConvertTo-CkbAddress -Script $nodeInfo.default_funding_lock_script -Network testnet
Write-Host "Local node: version=$($nodeInfo.version) pubkey=$($nodeInfo.pubkey)"
Write-Host "CKB address to fund: $ckbAddress"

$channels = @(Get-PeerChannels -Settings $settings)
$readyChannels = @($channels | Where-Object { Test-ChannelReady -Channel $_ })
if ($readyChannels.Count -gt 0) {
    $channel = $readyChannels[0]
    Write-Host "Channel already ready; no transaction submitted"
    $channel | Select-Object channel_id, channel_outpoint, pubkey, local_balance, remote_balance, state | Format-List
    return
}

if ($channels.Count -gt 0) {
    $states = @($channels | ForEach-Object { Get-ChannelStateName -Channel $_ })
    Write-Host "An existing channel is still opening; no duplicate open_channel call will be made. States: $($states -join ', ')"
    $channel = Wait-PeerChannelReady -Settings $settings -TimeoutSeconds $TimeoutSeconds
    $channel | Select-Object channel_id, channel_outpoint, pubkey, local_balance, remote_balance, state | Format-List
    return
}

$peerAddress = [string](Get-ObjectPropertyValue -Object $settings.peer -Name "address" -Default "")
$connectParams = @{
    save = $true
}
if ([string]::IsNullOrWhiteSpace($peerAddress)) {
    $connectParams["pubkey"] = [string]$settings.peer.pubkey
    $connectParams["addr_type"] = "tcp"
}
else {
    $connectParams["address"] = $peerAddress
}

$connectTimeout = [int](Get-ObjectPropertyValue -Object $settings.peer -Name "connectTimeoutSeconds" -Default 600)
$connectDeadline = [DateTime]::UtcNow.AddSeconds($connectTimeout)
$connected = $false
$lastConnectError = $null
while (-not $connected -and [DateTime]::UtcNow -lt $connectDeadline) {
    try {
        Invoke-FiberRpc -Settings $settings -Method "connect_peer" -Params @($connectParams) | Out-Null
        $connected = $true
    }
    catch {
        $lastConnectError = $_.Exception.Message
        Write-Host "Waiting to resolve/connect peer from gossip: $lastConnectError"
        Start-Sleep -Seconds 10
    }
}
if (-not $connected) {
    throw "Unable to connect peer within $connectTimeout seconds. Set peer.address explicitly if gossip has not learned the address. Last error: $lastConnectError"
}

$fundingAmount = [System.Numerics.BigInteger]::Parse([string]$settings.peer.fundingAmountShannons)
$fundingFeeRate = [System.Numerics.BigInteger]::Parse([string]$settings.peer.fundingFeeRate)
$openParams = @{
    pubkey          = [string]$settings.peer.pubkey
    funding_amount  = ConvertTo-HexQuantity -Value $fundingAmount
    funding_fee_rate = ConvertTo-HexQuantity -Value $fundingFeeRate
    public          = [bool]$settings.peer.public
}

Write-Warning "Opening a channel locks $($settings.peer.fundingAmountShannons) shannons on-chain. This call is intentionally never part of the scheduled workflow."
$openResult = Invoke-FiberRpc -Settings $settings -Method "open_channel" -Params @($openParams) -TimeoutSeconds 60
Write-Host "open_channel accepted: temporary_channel_id=$($openResult.temporary_channel_id)"

$channel = Wait-PeerChannelReady -Settings $settings -TimeoutSeconds $TimeoutSeconds
Write-Host "Channel is ready"
$channel | Select-Object channel_id, channel_outpoint, pubkey, local_balance, remote_balance, state | Format-List
