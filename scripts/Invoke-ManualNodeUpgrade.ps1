#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet("Inspect", "Upgrade")]
    [string]$Operation = "Inspect",
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+$')]
    [string]$ReleaseTag
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Import-Module (Join-Path $PSScriptRoot "FiberWindows.psm1") -Force

$nodes = @(
    [pscustomobject]@{ Name = "A"; SettingsFile = "C:\fiber-node\automation\settings.json" },
    [pscustomobject]@{ Name = "B"; SettingsFile = "C:\fiber-node-b\automation\settings.json" }
)
foreach ($node in $nodes) {
    $settings = Import-FiberSettings -SettingsPath $node.SettingsFile
    $paths = Get-FiberPaths -Settings $settings
    $node | Add-Member NoteProperty Settings $settings
    $node | Add-Member NoteProperty Paths $paths
    $info = Wait-FiberRpc -Settings $settings -TimeoutSeconds 30
    $channels = @(Invoke-FiberRpc -Settings $settings -Method "list_channels" -Params @{}).channels
    $files = @(Get-ChildItem -LiteralPath $paths.Data -File -Recurse -Force)
    $bytes = ($files | Measure-Object -Property Length -Sum).Sum
    $configText = Get-Content -LiteralPath $paths.Config -Raw
    if ($configText -match '(?m)^\s*(base_dir|store_path)\s*:') {
        throw "Node $($node.Name) has a custom data/store path; review before copying."
    }
    $node | Add-Member NoteProperty BeforeInfo $info
    $node | Add-Member NoteProperty BeforeChannels @($channels)
    $node | Add-Member NoteProperty DataBytes ([long]$bytes)
    [pscustomobject]@{
        Node = $node.Name
        Service = $settings.serviceName
        ServiceStatus = [string](Get-Service -Name $settings.serviceName).Status
        Fnn = Get-ExecutableVersion -Path $paths.Fnn
        Cli = Get-ExecutableVersion -Path $paths.Cli
        RpcVersion = $info.version
        Pubkey = $info.pubkey
        DataBytes = $bytes
        DataFiles = $files.Count
        Channels = @($channels | Select-Object channel_id, state, local_balance, remote_balance, offered_tlc_balance, received_tlc_balance)
    } | ConvertTo-Json -Depth 8 | Write-Host
}
Get-PSDrive -PSProvider FileSystem | Select-Object Name, Used, Free | Format-Table | Out-String | Write-Host

$targetSettings = $nodes[0].Settings.PSObject.Copy()
$targetSettings | Add-Member NoteProperty releaseTag $ReleaseTag -Force
$release = Get-FiberRelease -Settings $targetSettings
$asset = Get-WindowsReleaseAsset -Release $release
$stage = Join-Path "C:\fiber-maintenance" $ReleaseTag
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$archive = Join-Path $stage $asset.name
if (-not (Test-Path -LiteralPath $archive)) {
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $archive -UseBasicParsing
}
$expected = ([string]$asset.digest).Substring(7).ToLowerInvariant()
$actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw "Release archive SHA-256 mismatch" }
$extract = Join-Path $stage "release"
New-Item -ItemType Directory -Path $extract -Force | Out-Null
& tar.exe -xzf $archive -C $extract
if ($LASTEXITCODE -ne 0) { throw "Release extraction failed" }
$newFnn = @(Get-ChildItem -LiteralPath $extract -Filter fnn.exe -File -Recurse)[0].FullName
$newCli = @(Get-ChildItem -LiteralPath $extract -Filter fnn-cli.exe -File -Recurse)[0].FullName
Write-Host "Target: $(Get-ExecutableVersion -Path $newFnn)"
Write-Host "Target CLI: $(Get-ExecutableVersion -Path $newCli)"
Write-Host "SHA-256: $actual"
if ($Operation -eq "Inspect") {
    & $newFnn --help
    if ($LASTEXITCODE -ne 0) { throw "Target executable help failed" }
    return
}
throw "Upgrade operation is not yet enabled; inspection only."
