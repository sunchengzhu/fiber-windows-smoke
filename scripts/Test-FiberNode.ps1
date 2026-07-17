[CmdletBinding()]
param(
    [string]$SettingsPath,
    [switch]$AllowPending,
    [switch]$Compact,
    [string]$Label
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

if ($Compact) {
    if ([string]::IsNullOrWhiteSpace($Label)) {
        $Label = [string]$settings.peer.name
    }
    $healthStatus = if ($readyChannels.Count -gt 0) {
        "OK"
    }
    elseif ($AllowPending) {
        "PENDING"
    }
    else {
        "FAIL"
    }
    Write-Host "[$Label] $healthStatus  service=$($service.Status)  fnn=$($nodeInfo.version)  peers=$(@($peers.peers).Count)"

    if ($channels.Count -gt 0) {
        $channel = if ($readyChannels.Count -gt 0) { $readyChannels[0] } else { $channels[0] }
        $localBalance = ConvertFrom-HexQuantity -Value ([string]$channel.local_balance)
        $remoteBalance = ConvertFrom-HexQuantity -Value ([string]$channel.remote_balance)
        Write-Host "  $(Get-ChannelStateName -Channel $channel)  local=$(Format-CkbBalance -Shannons $localBalance)  remote=$(Format-CkbBalance -Shannons $remoteBalance) CKB"
        Write-Host "  $(Format-FiberLiquidityBar -LocalBalance $localBalance -RemoteBalance $remoteBalance -Width 16)"
    }
    else {
        Write-Host "  channel=None"
    }
}
else {
    Write-Host "Fiber node health"
    [pscustomobject]@{
        Service        = $service.Status
        Binary         = $binaryVersion
        RpcVersion     = $nodeInfo.version
        Commit         = $nodeInfo.commit_hash
        Pubkey         = $nodeInfo.pubkey
        CkbAddress     = $ckbAddress
        ConnectedPeers = @($peers.peers).Count
        PeerChannels   = $channels.Count
        ReadyChannels  = $readyChannels.Count
    } | Format-List

    if ($channels.Count -gt 0) {
        $channelNumber = 0
        $channels | ForEach-Object {
            $channelNumber += 1
            $localBalance = ConvertFrom-HexQuantity -Value ([string]$_.local_balance)
            $remoteBalance = ConvertFrom-HexQuantity -Value ([string]$_.remote_balance)
            Write-Host "Channel liquidity #$channelNumber"
            [pscustomobject]@{
                State            = Get-ChannelStateName -Channel $_
                LocalBalanceCkb  = (Format-CkbBalance -Shannons $localBalance) + " CKB"
                RemoteBalanceCkb = (Format-CkbBalance -Shannons $remoteBalance) + " CKB"
                ChannelId        = $_.channel_id
                ChannelOutpoint  = $_.channel_outpoint
            } | Format-List
            Write-Host (Format-FiberLiquidityBar -LocalBalance $localBalance -RemoteBalance $remoteBalance)
            Write-Host ""
        }
    }
}

if ($readyChannels.Count -eq 0 -and -not $AllowPending) {
    throw "No ChannelReady channel exists for peer $($settings.peer.pubkey)"
}
if ($readyChannels.Count -eq 0) {
    if (-not $Compact) {
        Write-Warning "No ready channel yet, but -AllowPending was specified"
    }
}
elseif (-not $Compact) {
    Write-Host "Health check passed"
}
