[CmdletBinding()]
param(
    [string]$SettingsPath,
    [switch]$NoServiceControl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Import-Module (Join-Path $PSScriptRoot "FiberWindows.psm1") -Force
$SettingsPath = Resolve-FiberSettingsPath -SettingsPath $SettingsPath -ScriptRoot $PSScriptRoot
$settings = Import-FiberSettings -SettingsPath $SettingsPath
$paths = Get-FiberPaths -Settings $settings
New-FiberDirectories -Paths $paths

$release = Get-FiberRelease -Settings $settings
$asset = Get-WindowsReleaseAsset -Release $release
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("fiber-update-" + [Guid]::NewGuid().ToString("N"))
$archivePath = Join-Path $tempRoot ([string]$asset.name)
$extractPath = Join-Path $tempRoot "extract"
$backupPath = $null
$service = Get-Service -Name ([string]$settings.serviceName) -ErrorAction SilentlyContinue
$serviceWasRunning = $null -ne $service -and $service.Status -eq "Running"
$binariesReplaced = $false

try {
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
    Write-Host "Downloading Fiber $($release.tag_name): $($asset.name)"
    Invoke-WebRequest -Uri ([string]$asset.browser_download_url) -OutFile $archivePath -UseBasicParsing

    $expectedSha256 = ([string]$asset.digest).Substring("sha256:".Length).ToLowerInvariant()
    $actualSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $expectedSha256) {
        throw "SHA-256 mismatch for $($asset.name): expected $expectedSha256, got $actualSha256"
    }
    Write-Host "SHA-256 verified: $actualSha256"

    & tar.exe -xzf $archivePath -C $extractPath
    if ($LASTEXITCODE -ne 0) {
        throw "tar.exe failed to extract $archivePath"
    }

    $newFnn = Get-ChildItem -Path $extractPath -Filter "fnn.exe" -File -Recurse | Select-Object -First 1
    $newCli = Get-ChildItem -Path $extractPath -Filter "fnn-cli.exe" -File -Recurse | Select-Object -First 1
    if ($null -eq $newFnn -or $null -eq $newCli) {
        throw "The release archive does not contain fnn.exe and fnn-cli.exe"
    }

    $targetFnnVersion = Get-ExecutableVersion -Path $newFnn.FullName
    $targetCliVersion = Get-ExecutableVersion -Path $newCli.FullName
    $currentFnnVersion = Get-ExecutableVersion -Path $paths.Fnn
    $currentCliVersion = Get-ExecutableVersion -Path $paths.Cli

    Write-Host "Target release : $($release.tag_name)"
    Write-Host "Target fnn     : $targetFnnVersion"
    Write-Host "Current fnn    : $currentFnnVersion"
    Write-Host "Target fnn-cli : $targetCliVersion"
    Write-Host "Current fnn-cli: $currentCliVersion"

    if (-not (Test-Path -LiteralPath $paths.Config -PathType Leaf)) {
        $packagedConfig = Join-Path $extractPath "config\testnet\config.yml"
        if (-not (Test-Path -LiteralPath $packagedConfig -PathType Leaf)) {
            throw "Release archive has no config\testnet\config.yml"
        }
        Copy-Item -LiteralPath $packagedConfig -Destination $paths.Config

        # Default to an outbound-only client node. RPC and P2P are not exposed publicly.
        $configText = Get-Content -LiteralPath $paths.Config -Raw
        $configText = $configText.Replace(
            'listening_addr: "/ip4/0.0.0.0/tcp/8228"',
            'listening_addr: "/ip4/127.0.0.1/tcp/8228"'
        )
        $configText = $configText.Replace("announce_listening_addr: true", "announce_listening_addr: false")
        Set-Content -LiteralPath $paths.Config -Value $configText -Encoding UTF8
        Write-Host "Created outbound-only testnet config: $($paths.Config)"
    }

    $fnnNeedsUpdate = $currentFnnVersion -ne $targetFnnVersion
    $cliNeedsUpdate = $currentCliVersion -ne $targetCliVersion
    if (-not $fnnNeedsUpdate -and -not $cliNeedsUpdate) {
        Write-Host "Fiber binaries are already current; no restart needed"
        if ($serviceWasRunning -and -not $NoServiceControl) {
            $nodeInfo = Wait-FiberRpc -Settings $settings -TimeoutSeconds 60
            Write-Host "Node healthy: version=$($nodeInfo.version) pubkey=$($nodeInfo.pubkey)"
        }
        return
    }

    if ($fnnNeedsUpdate -and $serviceWasRunning -and -not $NoServiceControl) {
        Write-Host "Stopping service $($settings.serviceName)"
        Stop-FiberService -ServiceName ([string]$settings.serviceName)
    }
    elseif ($fnnNeedsUpdate -and $serviceWasRunning -and $NoServiceControl) {
        throw "Cannot replace a running fnn.exe with -NoServiceControl. Stop service $($settings.serviceName) first."
    }

    if ($fnnNeedsUpdate -and (Test-Path -LiteralPath $paths.Store -PathType Container)) {
        Write-Host "Validating existing database with $targetFnnVersion"
        & $newFnn.FullName --config $paths.Config --dir $paths.Data --check-validate
        if ($LASTEXITCODE -ne 0) {
            throw "Database validation failed. The new release may require a manual migration; no binary was replaced."
        }
    }

    $timestamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    $backupPath = Join-Path $paths.Backups "$timestamp-$($release.tag_name)"
    New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
    if (Test-Path -LiteralPath $paths.Fnn) {
        Copy-Item -LiteralPath $paths.Fnn -Destination (Join-Path $backupPath "fnn.exe")
    }
    if (Test-Path -LiteralPath $paths.Cli) {
        Copy-Item -LiteralPath $paths.Cli -Destination (Join-Path $backupPath "fnn-cli.exe")
    }

    if ($fnnNeedsUpdate) {
        Copy-Item -LiteralPath $newFnn.FullName -Destination $paths.Fnn -Force
    }
    if ($cliNeedsUpdate) {
        Copy-Item -LiteralPath $newCli.FullName -Destination $paths.Cli -Force
    }
    $binariesReplaced = $true
    Write-Host "Installed $($release.tag_name); previous binaries saved in $backupPath"

    if ($serviceWasRunning -and -not $NoServiceControl) {
        Start-FiberService -ServiceName ([string]$settings.serviceName)
        $nodeInfo = Wait-FiberRpc -Settings $settings -TimeoutSeconds 180
        Write-Host "Node healthy after update: version=$($nodeInfo.version) pubkey=$($nodeInfo.pubkey)"
    }
}
catch {
    $failure = $_
    if ($binariesReplaced -and -not [string]::IsNullOrWhiteSpace([string]$backupPath)) {
        Write-Warning "Update failed; restoring previous binaries from $backupPath"
        if ($null -ne (Get-Service -Name ([string]$settings.serviceName) -ErrorAction SilentlyContinue)) {
            Stop-FiberService -ServiceName ([string]$settings.serviceName)
        }
        $oldFnn = Join-Path $backupPath "fnn.exe"
        $oldCli = Join-Path $backupPath "fnn-cli.exe"
        if (Test-Path -LiteralPath $oldFnn) {
            Copy-Item -LiteralPath $oldFnn -Destination $paths.Fnn -Force
        }
        if (Test-Path -LiteralPath $oldCli) {
            Copy-Item -LiteralPath $oldCli -Destination $paths.Cli -Force
        }
    }
    if ($serviceWasRunning -and -not $NoServiceControl) {
        $currentService = Get-Service -Name ([string]$settings.serviceName) -ErrorAction SilentlyContinue
        if ($null -ne $currentService -and $currentService.Status -ne "Running") {
            Start-FiberService -ServiceName ([string]$settings.serviceName)
        }
    }
    throw $failure
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
