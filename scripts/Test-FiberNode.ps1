[CmdletBinding()]
param(
    [string]$SettingsPath,
    [switch]$AllowPending
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "FiberWindows.psm1") -Force
$SettingsPath = Resolve-FiberSettingsPath -SettingsPath $SettingsPath -ScriptRoot $PSScriptRoot
$settings = Import-FiberSettings -SettingsPath $SettingsPath
$paths = Get-FiberPaths -Settings $settings

$service = Get-Service -Name ([string]$settings.serviceName) -ErrorAction SilentlyContinue
if ($null -eq $service) {
    throw "Windows service '$($settings.serviceName)' is not installed"
}
if ($service.Status -ne "Running") {
    throw "Windows service '$($settings.serviceName)' is $($service.Status), expected Running"
}

$nodeInfo = Wait-FiberRpc -Settings $settings -TimeoutSeconds 60
$ckbAddress = ConvertTo-CkbAddress -Script $nodeInfo.default_funding_lock_script -Network testnet
$binaryVersion = Get-ExecutableVersion -Path $paths.Fnn
$peers = Invoke-FiberRpc -Settings $settings -Method "list_peers"
$channels = @(Get-PeerChannels -Settings $settings)
$readyChannels = @($channels | Where-Object { Test-ChannelReady -Channel $_ })

Write-Host "Fiber node health"
[pscustomobject]@{
    Service       = $service.Status
    Binary        = $binaryVersion
    RpcVersion    = $nodeInfo.version
    Commit        = $nodeInfo.commit_hash
    Pubkey        = $nodeInfo.pubkey
    CkbAddress    = $ckbAddress
    ConnectedPeers = @($peers.peers).Count
    PeerChannels  = $channels.Count
    ReadyChannels = $readyChannels.Count
} | Format-List

if ($channels.Count -gt 0) {
    $channelNumber = 0
    $channels | ForEach-Object {
        $channelNumber += 1
        $localBalance = ConvertFrom-HexQuantity -Value ([string]$_.local_balance)
        $remoteBalance = ConvertFrom-HexQuantity -Value ([string]$_.remote_balance)
        Write-Host "Channel liquidity #$channelNumber"
        [pscustomobject]@{
            State           = Get-ChannelStateName -Channel $_
            LocalBalanceCkb = (Format-CkbBalance -Shannons $localBalance) + " CKB"
            RemoteBalanceCkb = (Format-CkbBalance -Shannons $remoteBalance) + " CKB"
            ChannelId       = $_.channel_id
            ChannelOutpoint = $_.channel_outpoint
        } | Format-List
        Write-Host (Format-FiberLiquidityBar -LocalBalance $localBalance -RemoteBalance $remoteBalance)
        Write-Host ""
    }
}

if ($readyChannels.Count -eq 0 -and -not $AllowPending) {
    throw "No ChannelReady channel exists for peer $($settings.peer.pubkey)"
}
if ($readyChannels.Count -eq 0) {
    Write-Warning "No ready channel yet, but -AllowPending was specified"
}
else {
    Write-Host "Health check passed"
}
