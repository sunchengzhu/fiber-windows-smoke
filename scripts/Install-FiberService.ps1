#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$SettingsPath,
    [SecureString]$SecretKeyPassword,
    [switch]$ForceReinstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Import-Module (Join-Path $PSScriptRoot "FiberWindows.psm1") -Force
$SettingsPath = Resolve-FiberSettingsPath -SettingsPath $SettingsPath -ScriptRoot $PSScriptRoot
$settings = Import-FiberSettings -SettingsPath $SettingsPath
$paths = Get-FiberPaths -Settings $settings
New-FiberDirectories -Paths $paths

$existingServiceBeforeInstall = Get-Service -Name ([string]$settings.serviceName) -ErrorAction SilentlyContinue
if ($null -ne $existingServiceBeforeInstall -and -not $ForceReinstall) {
    throw "Service '$($settings.serviceName)' already exists. Use Update-FiberBinary.ps1 for normal updates, or pass -ForceReinstall with the original key password to repair the service registration."
}
if ($null -eq $existingServiceBeforeInstall) {
    & (Join-Path $PSScriptRoot "Update-FiberBinary.ps1") -SettingsPath $SettingsPath -NoServiceControl
}
else {
    & (Join-Path $PSScriptRoot "Update-FiberBinary.ps1") -SettingsPath $SettingsPath
}

if ([System.IO.Path]::GetFullPath($SettingsPath) -ne [System.IO.Path]::GetFullPath($paths.RuntimeConfig)) {
    Copy-Item -LiteralPath $SettingsPath -Destination $paths.RuntimeConfig -Force
}
Write-Host "Saved machine-local automation settings: $($paths.RuntimeConfig)"

if (-not (Test-Path -LiteralPath $paths.CkbKey -PathType Leaf)) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $paths.CkbKey) -Force | Out-Null
    $keyBytes = New-Object byte[] 32
    $random = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $random.GetBytes($keyBytes)
    }
    finally {
        $random.Dispose()
    }
    $plainKey = ([System.BitConverter]::ToString($keyBytes)).Replace("-", "").ToLowerInvariant()
    Set-Content -LiteralPath $paths.CkbKey -Value $plainKey -Encoding ASCII -NoNewline
    Write-Host "Generated a new CKB private key. FNN will encrypt it on first start."
}

$passwordConfirmation = $null
if ($null -eq $SecretKeyPassword) {
    $SecretKeyPassword = Read-Host "Password used by FNN to encrypt/decrypt the CKB key" -AsSecureString
    $passwordConfirmation = Read-Host "Confirm the FNN CKB key password" -AsSecureString
}
$passwordPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecretKeyPassword)
$confirmationPtr = [IntPtr]::Zero
$plainPasswordConfirmation = $null
try {
    $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPtr)
    if ($null -ne $passwordConfirmation) {
        $confirmationPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($passwordConfirmation)
        $plainPasswordConfirmation = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($confirmationPtr)
        if (-not [string]::Equals($plainPassword, $plainPasswordConfirmation, [System.StringComparison]::Ordinal)) {
            $plainPassword = $null
            throw "Secret key passwords do not match; run the installer again"
        }
    }
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPtr)
    if ($confirmationPtr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($confirmationPtr)
    }
    $plainPasswordConfirmation = $null
}
if ([string]::IsNullOrWhiteSpace($plainPassword) -or $plainPassword.Length -lt 12) {
    throw "Secret key password must be at least 12 characters"
}

$wrapperPath = Join-Path $paths.Service "FiberNodeService.exe"
$wrapperConfigPath = Join-Path $paths.Service "FiberNodeService.xml"
$winswUrl = "https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe"
$winswSha256 = "05b82d46ad331cc16bdc00de5c6332c1ef818df8ceefcd49c726553209b3a0da"

if (-not (Test-Path -LiteralPath $wrapperPath -PathType Leaf)) {
    Write-Host "Downloading WinSW v2.12.0"
    Invoke-WebRequest -Uri $winswUrl -OutFile $wrapperPath -UseBasicParsing
}
$actualWinswSha256 = (Get-FileHash -LiteralPath $wrapperPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualWinswSha256 -ne $winswSha256) {
    throw "WinSW SHA-256 mismatch: expected $winswSha256, got $actualWinswSha256"
}

$escapedPassword = [System.Security.SecurityElement]::Escape($plainPassword)
$escapedFnn = [System.Security.SecurityElement]::Escape($paths.Fnn)
$escapedConfig = [System.Security.SecurityElement]::Escape($paths.Config)
$escapedData = [System.Security.SecurityElement]::Escape($paths.Data)
$escapedLogs = [System.Security.SecurityElement]::Escape($paths.Logs)
$serviceName = [string]$settings.serviceName
$serviceXml = @"
<service>
  <id>$serviceName</id>
  <name>Fiber Network Node</name>
  <description>Long-running Fiber Network Node managed by fiber-windows-smoke.</description>
  <executable>$escapedFnn</executable>
  <arguments>--config &quot;$escapedConfig&quot; --dir &quot;$escapedData&quot;</arguments>
  <workingdirectory>$escapedData</workingdirectory>
  <env name="FIBER_SECRET_KEY_PASSWORD" value="$escapedPassword" />
  <startmode>Automatic</startmode>
  <delayedAutoStart>true</delayedAutoStart>
  <stoptimeout>30 sec</stoptimeout>
  <onfailure action="restart" delay="10 sec" />
  <onfailure action="restart" delay="30 sec" />
  <resetfailure>1 hour</resetfailure>
  <logpath>$escapedLogs</logpath>
  <log mode="roll" />
</service>
"@
Set-Content -LiteralPath $wrapperConfigPath -Value $serviceXml -Encoding UTF8
$plainPassword = $null

# The service XML contains the FNN key password, so only SYSTEM and Administrators may read it.
& icacls.exe $wrapperConfigPath /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to restrict ACL on $wrapperConfigPath"
}
& icacls.exe $paths.Data /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to restrict ACL on $($paths.Data)"
}

$existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($null -eq $existingService) {
    & $wrapperPath install
    if ($LASTEXITCODE -ne 0) {
        throw "WinSW failed to install service $serviceName"
    }
}
else {
    Stop-FiberService -ServiceName $serviceName
    & $wrapperPath uninstall
    if ($LASTEXITCODE -ne 0) {
        throw "WinSW failed to uninstall the previous registration for service $serviceName"
    }
    & $wrapperPath install
    if ($LASTEXITCODE -ne 0) {
        throw "WinSW failed to reinstall service $serviceName"
    }
}

Start-FiberService -ServiceName $serviceName
$nodeInfo = Wait-FiberRpc -Settings $settings -TimeoutSeconds 180
$ckbAddress = ConvertTo-CkbAddress -Script $nodeInfo.default_funding_lock_script -Network testnet
Write-Host "Fiber service installed and healthy"
[pscustomobject]@{
    version     = $nodeInfo.version
    commit_hash = $nodeInfo.commit_hash
    pubkey      = $nodeInfo.pubkey
    addresses   = $nodeInfo.addresses
    ckb_address = $ckbAddress
} | Format-List
Write-Warning "Back up $($paths.Data) now. In particular, losing data\fiber\sk or data\ckb\key can make channel funds unrecoverable."
