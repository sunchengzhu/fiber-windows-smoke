#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet("Inspect", "Rehearse", "Upgrade")]
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

function Copy-VerifiedTree {
    param([string]$Source, [string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    & robocopy.exe $Source $Destination /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /XJ /NP /NFL /NDL /NJH /NJS | Out-Null
    $copyCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($copyCode -ge 8) { throw "Backup copy failed ($copyCode): $Source" }
    $sourceFiles = @(Get-ChildItem -LiteralPath $Source -Recurse -File -Force)
    $targetFiles = @(Get-ChildItem -LiteralPath $Destination -Recurse -File -Force)
    if ($sourceFiles.Count -ne $targetFiles.Count) { throw "Backup file count mismatch: $Source" }
    $manifest = foreach ($file in $sourceFiles) {
        $relative = $file.FullName.Substring($Source.TrimEnd('\').Length).TrimStart('\')
        $target = Join-Path $Destination $relative
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Backup missing file: $relative" }
        if ((Get-Item -LiteralPath $target).Length -ne $file.Length) { throw "Backup size mismatch: $relative" }
        $sourceHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ($sourceHash -ne $targetHash) { throw "Backup hash mismatch: $relative" }
        [pscustomobject]@{ Path = $relative; Bytes = $file.Length; Sha256 = $sourceHash }
    }
    return @($manifest)
}

function Invoke-OfflineFnn {
    param([string]$DataDirectory, [string]$ConfigFile, [string]$LogPrefix, [switch]$Validate)
    $start = New-Object System.Diagnostics.ProcessStartInfo
    # .NET Framework's redirected stdin writer emits a BOM when the process
    # starts, even before a raw BaseStream write. Let cmd redirect an ASCII
    # file directly so Rust receives exactly y + CRLF, with no managed writer.
    $inputFile = "$LogPrefix.input.txt"
    [System.IO.File]::WriteAllBytes($inputFile, [System.Text.Encoding]::ASCII.GetBytes("y`r`n"))
    $fnnArguments = '--config "' + $ConfigFile + '" --dir "' + $DataDirectory + '"'
    if ($Validate) { $fnnArguments += ' --check-validate' }
    $start.FileName = $env:ComSpec
    $start.Arguments = '/d /s /c ""' + $newFnn + '" ' + $fnnArguments + ' < "' + $inputFile + '""'
    $start.WorkingDirectory = $stage
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    # This process has no network-enabled service or credential. The minimal
    # fiber-only config exits at the missing-CKB guard after store migration,
    # before key loading or starting any network/watchtower actor (v0.10.1 main.rs).
    foreach ($key in @($start.EnvironmentVariables.Keys)) {
        if ($key -match '^(FIBER_|FNN_|RUST_LOG$|GITHUB_TOKEN$)') {
            $start.EnvironmentVariables.Remove($key)
        }
    }
    $start.EnvironmentVariables['RUST_LOG'] = 'info'
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(300000)) {
            & taskkill.exe /PID $process.Id /T /F | Out-Null
            $process.WaitForExit()
            throw "Offline FNN exceeded five minutes; inspect $LogPrefix before continuing."
        }
        $outText = $stdout.GetAwaiter().GetResult()
        $errText = $stderr.GetAwaiter().GetResult()
        [System.IO.File]::WriteAllText("$LogPrefix.stdout.log", $outText)
        [System.IO.File]::WriteAllText("$LogPrefix.stderr.log", $errText)
        $combined = $outText + "`n" + $errText
        foreach ($line in ($combined -split "`r?`n")) {
            if ($line -match '(?i)migrat|database version|db validate|service fiber requires service ckb|\[[0-9]+/[0-9]+\]') {
                Write-Host $line
            }
        }
        if ($Validate) {
            if ($process.ExitCode -ne 0 -or $combined -notmatch 'db validate success') {
                throw "Offline validation failed (exit $($process.ExitCode)); logs: $LogPrefix"
            }
        }
        elseif ($process.ExitCode -eq 0 -or $combined -notmatch 'service fiber requires service ckb which is not enabled in the config file') {
            throw "Offline migration did not reach its expected pre-network exit (exit $($process.ExitCode)); logs: $LogPrefix"
        }
    }
    finally {
        if ($process.Id -and -not $process.HasExited) {
            & taskkill.exe /PID $process.Id /T /F | Out-Null
            $process.WaitForExit()
        }
        $process.Dispose()
    }
}

if ($Operation -eq 'Rehearse') {
    $savedBackups = @(Get-ChildItem -LiteralPath 'C:\fiber-maintenance\backups' -Directory |
        Where-Object { $_.Name -like "*-$ReleaseTag-*" -and (Test-Path -LiteralPath (Join-Path $_.FullName 'BACKUP_COMPLETE')) } |
        Sort-Object Name -Descending)
    if ($savedBackups.Count -eq 0) { throw 'A complete backup is required for isolated rehearsal' }
    $savedBackup = $savedBackups[0].FullName
    $probe = Join-Path $savedBackup ("rehearsal-" + [Guid]::NewGuid().ToString('N'))
    try {
        foreach ($node in $nodes) {
            $copyData = Join-Path $probe "node-$($node.Name)"
            $null = Copy-VerifiedTree -Source (Join-Path $savedBackup "node-$($node.Name)\data\fiber\store") -Destination (Join-Path $copyData 'fiber\store')
            $prefix = Join-Path $savedBackup "node-$($node.Name)-probe-$($env:GITHUB_RUN_ID)"
            Invoke-OfflineFnn -DataDirectory $copyData -ConfigFile (Join-Path $savedBackup 'offline-migration.yml') -LogPrefix "$prefix-migrate"
            Invoke-OfflineFnn -DataDirectory $copyData -ConfigFile (Join-Path $savedBackup 'offline-migration.yml') -LogPrefix "$prefix-validate" -Validate
            Write-Host "Node $($node.Name): isolated backup migration and full validation passed"
        }
    }
    finally {
        if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Recurse -Force }
    }
    $global:LASTEXITCODE = 0
    return
}

$targetVersion = $ReleaseTag.Substring(1)
if ((Get-ExecutableVersion -Path $newFnn) -notlike "fnn Fiber $ReleaseTag *") { throw "Target FNN version differs from requested release" }
if ((Get-ExecutableVersion -Path $newCli) -ne "fnn-cli $targetVersion") { throw "Target CLI version differs from requested release" }
foreach ($node in $nodes) {
    if ([string](Get-Service -Name $node.Settings.serviceName).Status -ne 'Running') { throw "Both services must initially be running" }
    if ([version]$node.BeforeInfo.version -ge [version]$targetVersion) { throw "Manual upgrade requires an older installed version; refusing a downgrade or repeated migration" }
    foreach ($channel in $node.BeforeChannels) {
        if (-not (Test-ChannelReady -Channel $channel)) { throw "All channels must be ready before backup" }
        foreach ($name in @('offered_tlc_balance', 'received_tlc_balance')) {
            if ((ConvertFrom-HexQuantity -Value ([string]$channel.$name)) -ne 0) { throw "Node $($node.Name) has a pending TLC; wait for settlement" }
        }
    }
    foreach ($path in @($node.Paths.CkbKey, (Join-Path $node.Paths.Data 'fiber\sk'))) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required node key file missing" }
    }
}
$requiredBytes = [long](($nodes | Measure-Object -Property DataBytes -Sum).Sum * 3 + 1073741824)
if ((Get-PSDrive -Name C).Free -lt $requiredBytes) { throw "Insufficient disk space for verified backup and rehearsal" }
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$backupRoot = Join-Path 'C:\fiber-maintenance\backups' "$stamp-$ReleaseTag-$($env:GITHUB_RUN_ID)"
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
& icacls.exe $backupRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Unable to protect backup directory ACL" }
$offlineConfig = Join-Path $backupRoot 'offline-migration.yml'
@"
services:
  - fiber
fiber:
  chain: testnet
"@ | Set-Content -LiteralPath $offlineConfig -Encoding ASCII
$backupComplete = $false
$liveMigrationStarted = $false
$networkMayHaveAdvanced = $false
$stoppingStarted = $false
$rehearsal = Join-Path $backupRoot 'rehearsal'
try {
    Write-Host "Stopping both services for a consistent backup: $backupRoot"
    $stoppingStarted = $true
    foreach ($node in $nodes) { Stop-FiberService -ServiceName $node.Settings.serviceName }
    $liveProcesses = @(Get-CimInstance Win32_Process -Filter "name = 'fnn.exe'" | Where-Object {
        $_.ExecutablePath -in @($nodes[0].Paths.Fnn, $nodes[1].Paths.Fnn)
    })
    if ($liveProcesses.Count -gt 0) { throw "A managed FNN process is still running after stopping services" }
    foreach ($node in $nodes) {
        $destination = Join-Path $backupRoot "node-$($node.Name)"
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        $node | Add-Member NoteProperty Backup $destination
        foreach ($folder in @('data', 'bin', 'service')) {
            $source = Join-Path $node.Paths.Root $folder
            $manifest = @(Copy-VerifiedTree -Source $source -Destination (Join-Path $destination $folder))
            $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $destination "$folder-sha256.json") -Encoding UTF8
            Write-Host "Node $($node.Name) $folder backup verified: $($manifest.Count) files, $(($manifest | Measure-Object Bytes -Sum).Sum) bytes"
        }
        Copy-Item -LiteralPath $node.SettingsFile -Destination (Join-Path $destination 'settings.json')
        if ((Get-FileHash -LiteralPath $node.SettingsFile).Hash -ne (Get-FileHash -LiteralPath (Join-Path $destination 'settings.json')).Hash) { throw "Settings backup mismatch" }
        $node.BeforeInfo | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $destination 'node-info-before.json') -Encoding UTF8
        $node.BeforeChannels | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $destination 'channels-before.json') -Encoding UTF8
    }
    Set-Content -LiteralPath (Join-Path $backupRoot 'BACKUP_COMPLETE') -Value $stamp -Encoding ASCII
    $backupComplete = $true
    Write-Host "Both complete node backups verified; beginning offline rehearsal"
    foreach ($node in $nodes) {
        $copyData = Join-Path $rehearsal "node-$($node.Name)"
        $null = Copy-VerifiedTree -Source (Join-Path $node.Backup 'data\fiber\store') -Destination (Join-Path $copyData 'fiber\store')
        Write-Host "Node $($node.Name): rehearsing database migration"
        Invoke-OfflineFnn -DataDirectory $copyData -ConfigFile $offlineConfig -LogPrefix (Join-Path $backupRoot "node-$($node.Name)-rehearsal-migrate")
        Invoke-OfflineFnn -DataDirectory $copyData -ConfigFile $offlineConfig -LogPrefix (Join-Path $backupRoot "node-$($node.Name)-rehearsal-validate") -Validate
    }
    Write-Host "Both rehearsal databases passed; migrating live stores while services remain stopped"
    $liveMigrationStarted = $true
    foreach ($node in $nodes) {
        Write-Host "Node $($node.Name): migrating live database"
        Invoke-OfflineFnn -DataDirectory $node.Paths.Data -ConfigFile $offlineConfig -LogPrefix (Join-Path $backupRoot "node-$($node.Name)-live-migrate")
        Invoke-OfflineFnn -DataDirectory $node.Paths.Data -ConfigFile $offlineConfig -LogPrefix (Join-Path $backupRoot "node-$($node.Name)-live-validate") -Validate
        foreach ($relative in @('ckb\key', 'fiber\sk', 'config.yml')) {
            $original = Join-Path $node.Paths.Data $relative
            $saved = Join-Path (Join-Path $node.Backup 'data') $relative
            if ((Get-FileHash -LiteralPath $original).Hash -ne (Get-FileHash -LiteralPath $saved).Hash) { throw "Node key or configuration changed during offline migration" }
        }
    }
    foreach ($node in $nodes) {
        Copy-Item -LiteralPath $newFnn -Destination $node.Paths.Fnn -Force
        Copy-Item -LiteralPath $newCli -Destination $node.Paths.Cli -Force
        if ((Get-FileHash -LiteralPath $node.Paths.Fnn).Hash -ne (Get-FileHash -LiteralPath $newFnn).Hash) { throw "Installed FNN hash mismatch" }
        if ((Get-FileHash -LiteralPath $node.Paths.Cli).Hash -ne (Get-FileHash -LiteralPath $newCli).Hash) { throw "Installed CLI hash mismatch" }
    }
    Write-Host "Both migrated stores validated and both binary pairs installed; starting services"
    # Never restore this snapshot after a node has rejoined the network: its
    # channel state could have advanced. Post-start failures retain migrated data.
    $networkMayHaveAdvanced = $true
    foreach ($node in $nodes) { Start-FiberService -ServiceName $node.Settings.serviceName }
    foreach ($node in $nodes) {
        $info = Wait-FiberRpc -Settings $node.Settings -TimeoutSeconds 180
        if ($info.version -ne $targetVersion) { throw "RPC version differs from the requested release" }
        if ($info.pubkey -ne $node.BeforeInfo.pubkey) { throw "Node identity changed" }
        Write-Host "Node $($node.Name) healthy: version=$($info.version), commit=$($info.commit_hash), pubkey unchanged"
    }
    & (Join-Path $PSScriptRoot 'Connect-PaymentPeers.ps1')
    foreach ($node in $nodes) {
        $after = @((Invoke-FiberRpc -Settings $node.Settings -Method 'list_channels' -Params @(@{})).channels)
        if ($after.Count -ne $node.BeforeChannels.Count) { throw "Channel count changed after migration" }
        foreach ($before in $node.BeforeChannels) {
            $matched = @($after | Where-Object { $_.channel_id -eq $before.channel_id })
            if ($matched.Count -ne 1) { throw "Original channel missing after migration" }
            foreach ($field in @('local_balance', 'remote_balance')) {
                if ($matched[0].$field -ne $before.$field) { throw "Channel balance changed across offline migration" }
            }
        }
        Write-Host "Node $($node.Name): all original channel IDs and balances preserved"
    }
    & (Join-Path $PSScriptRoot 'Test-PaymentTopology.ps1')
    Set-Content -LiteralPath (Join-Path $backupRoot 'UPGRADE_COMPLETE') -Value $ReleaseTag -Encoding ASCII
    Write-Host "MANUAL UPGRADE COMPLETE: $ReleaseTag; backup=$backupRoot"
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        @"
Manual upgrade to $ReleaseTag completed for both Windows nodes.

- Complete data, keys, configuration, service wrappers, binaries, and settings backed up with SHA-256 verification.
- Both database copies rehearsed and validated before migrating the live stores.
- Both live stores validated; node identities, channel IDs, and balances preserved.
- Both Windows services, RPC, and payment topology passed.
- Protected server-local backup: ``$backupRoot``
- Payment smoke is a separate explicitly requested run.
"@ | Out-File -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding UTF8 -Append
    }
}
catch {
    $failure = $_
    if ($networkMayHaveAdvanced) {
        Write-Warning "Post-start check failed. Retaining migrated stores and $ReleaseTag binaries; no stale channel snapshot will be restored."
        foreach ($node in $nodes) {
            if ([string](Get-Service -Name $node.Settings.serviceName).Status -ne 'Running') {
                Start-FiberService -ServiceName $node.Settings.serviceName
            }
        }
    }
    elseif ($stoppingStarted) {
        if ($liveMigrationStarted -and $backupComplete) {
            Write-Warning "Offline update failed before network startup; restoring verified old stores and binaries."
            foreach ($node in $nodes) {
                $failedStore = Join-Path $backupRoot "node-$($node.Name)-failed-store"
                Move-Item -LiteralPath $node.Paths.Store -Destination $failedStore
                $null = Copy-VerifiedTree -Source (Join-Path $node.Backup 'data\fiber\store') -Destination $node.Paths.Store
                Copy-Item -LiteralPath (Join-Path $node.Backup 'bin\fnn.exe') -Destination $node.Paths.Fnn -Force
                Copy-Item -LiteralPath (Join-Path $node.Backup 'bin\fnn-cli.exe') -Destination $node.Paths.Cli -Force
            }
        }
        foreach ($node in $nodes) {
            Start-FiberService -ServiceName $node.Settings.serviceName
            $null = Wait-FiberRpc -Settings $node.Settings -TimeoutSeconds 180
            Write-Host "Node $($node.Name): original service and RPC restored"
        }
    }
    throw $failure
}
finally {
    # Only disposable database copies are removed. The complete pre-upgrade
    # snapshot, manifests, and migration logs stay in the protected directory.
    if (Test-Path -LiteralPath $rehearsal) { Remove-Item -LiteralPath $rehearsal -Recurse -Force }
}
$global:LASTEXITCODE = 0
