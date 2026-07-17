Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) {
        return $Object.$Name
    }
    return $Default
}

function Resolve-FiberSettingsPath {
    param(
        [string]$SettingsPath,
        [Parameter(Mandatory = $true)]
        [string]$ScriptRoot
    )

    if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
        if (-not [string]::IsNullOrWhiteSpace($env:FIBER_WINDOWS_SETTINGS)) {
            $SettingsPath = $env:FIBER_WINDOWS_SETTINGS
        }
        else {
            $SettingsPath = Join-Path (Split-Path -Parent $ScriptRoot) "config\node-settings.json"
        }
    }
    if ([System.IO.Path]::IsPathRooted($SettingsPath)) {
        return [System.IO.Path]::GetFullPath($SettingsPath)
    }

    # PowerShell's current location can differ from the process working directory.
    # This commonly happens in an elevated shell, where .NET still reports
    # C:\Windows\System32 even after Set-Location changes the PowerShell location.
    $powerShellWorkingDirectory = (Get-Location).ProviderPath
    return [System.IO.Path]::GetFullPath((Join-Path $powerShellWorkingDirectory $SettingsPath))
}

function Import-FiberSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath
    )

    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        throw "Settings file not found: $SettingsPath. Copy config\node-settings.example.json first."
    }

    $settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
    foreach ($requiredName in @("installRoot", "repository", "releaseChannel", "serviceName", "rpcUrl", "peer")) {
        if ($settings.PSObject.Properties.Name -notcontains $requiredName) {
            throw "Missing required setting '$requiredName' in $SettingsPath"
        }
    }

    $installRoot = [System.IO.Path]::GetFullPath([string]$settings.installRoot)
    if ($installRoot -eq [System.IO.Path]::GetPathRoot($installRoot)) {
        throw "installRoot must not be a drive root: $installRoot"
    }
    $settings.installRoot = $installRoot

    if ([string]$settings.releaseChannel -notin @("stable", "prerelease")) {
        throw "releaseChannel must be 'stable' or 'prerelease'"
    }
    if ([string]$settings.serviceName -notmatch "^[A-Za-z0-9]+$") {
        throw "serviceName must contain only ASCII letters and digits because WinSW uses it as the service id"
    }
    if ([string]::IsNullOrWhiteSpace([string]$settings.peer.pubkey)) {
        throw "peer.pubkey is required"
    }
    if ([string]$settings.peer.pubkey -notmatch "^(02|03)[0-9a-fA-F]{64}$") {
        throw "peer.pubkey must be a compressed secp256k1 public key"
    }
    if ([string]$settings.peer.asset -ne "CKB") {
        throw "This first version supports CKB channels only; peer.asset must be 'CKB'"
    }

    $fundingAmount = [System.Numerics.BigInteger]::Parse([string]$settings.peer.fundingAmountShannons)
    if ($fundingAmount -le [System.Numerics.BigInteger]::Zero) {
        throw "peer.fundingAmountShannons must be positive"
    }
    $fundingFeeRate = [System.Numerics.BigInteger]::Parse([string]$settings.peer.fundingFeeRate)
    if ($fundingFeeRate -le [System.Numerics.BigInteger]::Zero) {
        throw "peer.fundingFeeRate must be positive"
    }

    return $settings
}

function Get-FiberPaths {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Settings
    )

    $root = [string]$Settings.installRoot
    return [pscustomobject]@{
        Root          = $root
        Bin           = Join-Path $root "bin"
        Data          = Join-Path $root "data"
        Config        = Join-Path $root "data\config.yml"
        Fnn           = Join-Path $root "bin\fnn.exe"
        Cli           = Join-Path $root "bin\fnn-cli.exe"
        Store         = Join-Path $root "data\fiber\store"
        CkbKey        = Join-Path $root "data\ckb\key"
        Service       = Join-Path $root "service"
        Logs          = Join-Path $root "logs"
        Backups       = Join-Path $root "backups"
        Automation    = Join-Path $root "automation"
        RuntimeConfig = Join-Path $root "automation\settings.json"
    }
}

function New-FiberDirectories {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Paths
    )

    foreach ($path in @($Paths.Root, $Paths.Bin, $Paths.Data, $Paths.Service, $Paths.Logs, $Paths.Backups, $Paths.Automation)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

function ConvertTo-HexQuantity {
    param(
        [Parameter(Mandatory = $true)]
        [System.Numerics.BigInteger]$Value
    )

    if ($Value -lt [System.Numerics.BigInteger]::Zero) {
        throw "Hex quantity cannot be negative"
    }
    $hex = $Value.ToString("x").TrimStart("0")
    if ([string]::IsNullOrEmpty($hex)) {
        $hex = "0"
    }
    return "0x$hex"
}

function Get-FiberAuthHeaders {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Settings
    )

    $headers = @{ "Content-Type" = "application/json" }
    $token = $env:FNN_AUTH_TOKEN
    $tokenFile = [string](Get-ObjectPropertyValue -Object $Settings -Name "authTokenFile" -Default "")
    if ([string]::IsNullOrWhiteSpace($token) -and -not [string]::IsNullOrWhiteSpace($tokenFile)) {
        if (-not (Test-Path -LiteralPath $tokenFile -PathType Leaf)) {
            throw "authTokenFile not found: $tokenFile"
        }
        $token = (Get-Content -LiteralPath $tokenFile -Raw).Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        $headers["Authorization"] = "Bearer $token"
    }
    return $headers
}

function Invoke-FiberRpc {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Settings,
        [Parameter(Mandatory = $true)]
        [string]$Method,
        [object[]]$Params = @(),
        [int]$TimeoutSeconds = 30
    )

    $body = @{
        id      = 1
        jsonrpc = "2.0"
        method  = $Method
        params  = @($Params)
    } | ConvertTo-Json -Depth 20 -Compress

    $response = Invoke-RestMethod `
        -Uri ([string]$Settings.rpcUrl) `
        -Method Post `
        -Headers (Get-FiberAuthHeaders -Settings $Settings) `
        -Body $body `
        -TimeoutSec $TimeoutSeconds `
        -UseBasicParsing

    $rpcError = Get-ObjectPropertyValue -Object $response -Name "error"
    if ($null -ne $rpcError) {
        $errorMessage = [string](Get-ObjectPropertyValue -Object $rpcError -Name "message" -Default "Unknown JSON-RPC error")
        throw "Fiber RPC '$Method' failed: $errorMessage"
    }
    return $response.result
}

function ConvertFrom-HexBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Hex
    )

    $normalized = $Hex
    if ($normalized.StartsWith("0x", [StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(2)
    }
    if ($normalized.Length % 2 -ne 0 -or $normalized -notmatch "^[0-9a-fA-F]*$") {
        throw "Invalid hex byte string"
    }
    $bytes = New-Object byte[] ($normalized.Length / 2)
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        $bytes[$index] = [Convert]::ToByte($normalized.Substring($index * 2, 2), 16)
    }
    return $bytes
}

function ConvertTo-FiveBitGroups {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    $result = New-Object 'System.Collections.Generic.List[int]'
    [uint32]$accumulator = 0
    $bits = 0
    foreach ($value in $Bytes) {
        $accumulator = [uint32]((($accumulator -shl 8) -bor [uint32]$value) -band 4095)
        $bits += 8
        while ($bits -ge 5) {
            $bits -= 5
            $result.Add([int](($accumulator -shr $bits) -band 31))
        }
    }
    if ($bits -gt 0) {
        $result.Add([int](($accumulator -shl (5 - $bits)) -band 31))
    }
    return $result.ToArray()
}

function Get-Bech32Polymod {
    param(
        [Parameter(Mandatory = $true)]
        [int[]]$Values
    )

    [uint32[]]$generators = @(
        [uint32]0x3b6a57b2,
        [uint32]0x26508e6d,
        [uint32]0x1ea119fa,
        [uint32]0x3d4233dd,
        [uint32]0x2a1462b3
    )
    [uint32]$checksum = 1
    foreach ($value in $Values) {
        [uint32]$top = $checksum -shr 25
        $checksum = [uint32]((($checksum -band [uint32]0x1ffffff) -shl 5) -bxor [uint32]$value)
        for ($index = 0; $index -lt 5; $index++) {
            if ((($top -shr $index) -band 1) -ne 0) {
                $checksum = [uint32]($checksum -bxor $generators[$index])
            }
        }
    }
    return $checksum
}

function ConvertTo-CkbAddress {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Script,
        [ValidateSet("mainnet", "testnet")]
        [string]$Network = "testnet"
    )

    $codeHash = ConvertFrom-HexBytes -Hex ([string]$Script.code_hash)
    if ($codeHash.Length -ne 32) {
        throw "CKB script code_hash must be 32 bytes"
    }
    $scriptArgs = ConvertFrom-HexBytes -Hex ([string]$Script.args)
    $hashTypeName = ([string]$Script.hash_type).ToLowerInvariant()
    $hashType = switch ($hashTypeName) {
        "data" { 0 }
        "type" { 1 }
        "data1" { 2 }
        default { throw "Unsupported CKB script hash_type: $hashTypeName" }
    }

    $payload = New-Object byte[] (1 + $codeHash.Length + 1 + $scriptArgs.Length)
    $payload[0] = 0 # Full payload format.
    [Array]::Copy($codeHash, 0, $payload, 1, $codeHash.Length)
    $payload[1 + $codeHash.Length] = [byte]$hashType
    [Array]::Copy($scriptArgs, 0, $payload, 2 + $codeHash.Length, $scriptArgs.Length)

    $hrp = if ($Network -eq "mainnet") { "ckb" } else { "ckt" }
    $data = @(ConvertTo-FiveBitGroups -Bytes $payload)
    $expandedHrp = New-Object 'System.Collections.Generic.List[int]'
    foreach ($character in $hrp.ToCharArray()) {
        $expandedHrp.Add(([int][char]$character) -shr 5)
    }
    $expandedHrp.Add(0)
    foreach ($character in $hrp.ToCharArray()) {
        $expandedHrp.Add(([int][char]$character) -band 31)
    }

    $polymodInput = @($expandedHrp.ToArray()) + $data + @(0, 0, 0, 0, 0, 0)
    [uint32]$polymod = (Get-Bech32Polymod -Values $polymodInput) -bxor [uint32]0x2bc830a3
    $checksum = New-Object int[] 6
    for ($index = 0; $index -lt 6; $index++) {
        $checksum[$index] = [int](($polymod -shr (5 * (5 - $index))) -band 31)
    }

    $alphabet = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append($hrp)
    [void]$builder.Append("1")
    foreach ($value in ($data + $checksum)) {
        [void]$builder.Append($alphabet[$value])
    }
    return $builder.ToString()
}

function Wait-FiberRpc {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Settings,
        [int]$TimeoutSeconds = 180
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastError = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            return Invoke-FiberRpc -Settings $Settings -Method "node_info" -TimeoutSeconds 10
        }
        catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Seconds 2
        }
    }
    throw "Fiber RPC did not become healthy within $TimeoutSeconds seconds. Last error: $lastError"
}

function Get-ChannelStateName {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Channel
    )

    if ($Channel.state -is [string]) {
        return [string]$Channel.state
    }
    if ($null -ne $Channel.state -and $Channel.state.PSObject.Properties.Name -contains "state_name") {
        return [string]$Channel.state.state_name
    }
    return "Unknown"
}

function Get-PeerChannels {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Settings,
        [switch]$IncludeClosed
    )

    $query = @{
        pubkey        = [string]$Settings.peer.pubkey
        include_closed = [bool]$IncludeClosed
    }
    $result = Invoke-FiberRpc -Settings $Settings -Method "list_channels" -Params @($query)
    return @($result.channels)
}

function Test-ChannelReady {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Channel
    )

    return (Get-ChannelStateName -Channel $Channel) -in @("ChannelReady", "CHANNEL_READY")
}

function Wait-PeerChannelReady {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Settings,
        [int]$TimeoutSeconds
    )

    if ($TimeoutSeconds -le 0) {
        $TimeoutSeconds = [int](Get-ObjectPropertyValue -Object $Settings.peer -Name "channelReadyTimeoutSeconds" -Default 1800)
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastStates = @()
    while ([DateTime]::UtcNow -lt $deadline) {
        $channels = @(Get-PeerChannels -Settings $Settings)
        $lastStates = @($channels | ForEach-Object { Get-ChannelStateName -Channel $_ })
        $ready = @($channels | Where-Object { Test-ChannelReady -Channel $_ })
        if ($ready.Count -gt 0) {
            return $ready[0]
        }
        Write-Host "Waiting for ChannelReady; current states: $($lastStates -join ', ')"
        Start-Sleep -Seconds 5
    }
    throw "No channel to $($Settings.peer.pubkey) became ready within $TimeoutSeconds seconds. Last states: $($lastStates -join ', ')"
}

function Get-GitHubHeaders {
    $headers = @{
        "Accept"               = "application/vnd.github+json"
        "User-Agent"           = "fiber-windows-smoke"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        $headers["Authorization"] = "Bearer $($env:GITHUB_TOKEN)"
    }
    return $headers
}

function Get-FiberRelease {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Settings
    )

    $repository = [string]$Settings.repository
    $releaseTag = [string](Get-ObjectPropertyValue -Object $Settings -Name "releaseTag" -Default "")
    $headers = Get-GitHubHeaders

    if (-not [string]::IsNullOrWhiteSpace($releaseTag)) {
        $uri = "https://api.github.com/repos/$repository/releases/tags/$releaseTag"
        return Invoke-RestMethod -Uri $uri -Headers $headers -UseBasicParsing
    }

    $uri = "https://api.github.com/repos/$repository/releases?per_page=30"
    # Invoke-RestMethod returns a JSON array as one pipeline object in newer
    # PowerShell versions. Assign first so @() expands the array elements.
    $releaseResponse = Invoke-RestMethod -Uri $uri -Headers $headers -UseBasicParsing
    $releases = @($releaseResponse)
    $candidates = @($releases | Where-Object {
        -not [bool]$_.draft -and (
            [string]$Settings.releaseChannel -eq "prerelease" -or -not [bool]$_.prerelease
        )
    })
    $release = $candidates | Sort-Object { [DateTimeOffset]$_.published_at } -Descending | Select-Object -First 1
    if ($null -eq $release) {
        throw "No matching Fiber release found for channel '$($Settings.releaseChannel)'"
    }
    return $release
}

function Get-WindowsReleaseAsset {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Release
    )

    $assets = @($Release.assets | Where-Object { [string]$_.name -like "*-x86_64-windows.tar.gz" })
    if ($assets.Count -ne 1) {
        throw "Release $($Release.tag_name) must contain exactly one *-x86_64-windows.tar.gz asset; found $($assets.Count)"
    }
    $asset = $assets[0]
    $digest = [string](Get-ObjectPropertyValue -Object $asset -Name "digest" -Default "")
    if ($digest -notmatch "^sha256:[0-9a-fA-F]{64}$") {
        throw "Release asset $($asset.name) has no GitHub SHA-256 digest; refusing an unverified update"
    }
    return $asset
}

function Get-ExecutableVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return "missing"
    }
    $output = @(& $Path --version 2>&1)
    if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) {
        throw "Unable to read executable version: $Path"
    }
    return [string]$output[0]
}

function Stop-FiberService {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceName
    )

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -ne $service -and $service.Status -ne "Stopped") {
        Stop-Service -Name $ServiceName -Force
        (Get-Service -Name $ServiceName).WaitForStatus("Stopped", [TimeSpan]::FromMinutes(2))
    }
}

function Start-FiberService {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceName
    )

    Start-Service -Name $ServiceName
    (Get-Service -Name $ServiceName).WaitForStatus("Running", [TimeSpan]::FromMinutes(2))
}

Export-ModuleMember -Function @(
    "ConvertTo-HexQuantity",
    "ConvertTo-CkbAddress",
    "Get-ChannelStateName",
    "Get-ExecutableVersion",
    "Get-FiberPaths",
    "Get-FiberRelease",
    "Get-ObjectPropertyValue",
    "Get-PeerChannels",
    "Get-WindowsReleaseAsset",
    "Import-FiberSettings",
    "Invoke-FiberRpc",
    "New-FiberDirectories",
    "Resolve-FiberSettingsPath",
    "Start-FiberService",
    "Stop-FiberService",
    "Test-ChannelReady",
    "Wait-FiberRpc",
    "Wait-PeerChannelReady"
)
