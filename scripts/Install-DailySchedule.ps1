#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet("Check", "Install", "Pause")]
    [string]$Operation = "Check",
    [string]$AutomationRoot = "C:\fiber-node\automation"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (-not [System.IO.Path]::IsPathRooted($AutomationRoot)) {
    throw "AutomationRoot must be an absolute path outside the Actions checkout"
}
$AutomationRoot = [System.IO.Path]::GetFullPath($AutomationRoot)
$taskName = "FiberWindowsSmokeDispatch"
$schedulerRoot = Join-Path $AutomationRoot "scheduler"
$stateDirectory = Join-Path $AutomationRoot "daily-dispatch"
$tokenPath = Join-Path $stateDirectory "github-token.dpapi"
$dispatcherPath = Join-Path $schedulerRoot "Dispatch-DailyRun.ps1"

function Invoke-DailySchedulePreflight {
    param([string]$DispatcherPath, [string]$StateDirectory, [string]$TokenPath)
    $global:LASTEXITCODE = 0
    & $DispatcherPath -StateDirectory $StateDirectory -TokenPath $TokenPath -Check
    if ($global:LASTEXITCODE -ne 0) {
        throw "Dispatcher preflight failed; the scheduled task was not installed or updated"
    }
}

function Set-DailyScheduleAccess {
    param([string]$Path, [switch]$Directory)
    $acl = if ($Directory) {
        New-Object System.Security.AccessControl.DirectorySecurity
    }
    else {
        New-Object System.Security.AccessControl.FileSecurity
    }
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sidValue in @("S-1-5-18", "S-1-5-32-544")) {
        $sid = [Security.Principal.SecurityIdentifier]::new($sidValue)
        if ($Directory) {
            $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
            $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, "FullControl", $inheritance, "None", "Allow")
        }
        else {
            $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, "FullControl", "Allow")
        }
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Show-ScheduleStatus {
    Write-Host "UTC now: $([DateTimeOffset]::UtcNow.ToString('o'))"
    Write-Host "Target: 10:30 Asia/Shanghai (02:30 UTC), independent of the Windows time zone"
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        Write-Host "$taskName is not installed"
        return
    }
    $task | Select-Object TaskName, State | Format-Table
    Get-ScheduledTaskInfo -TaskName $taskName | Select-Object LastRunTime, LastTaskResult, NextRunTime | Format-List
    $logPath = Join-Path $stateDirectory "dispatcher.log"
    if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Tail 15 }
}

if ($Operation -eq "Pause") {
    Disable-ScheduledTask -TaskName $taskName | Out-Null
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Show-ScheduleStatus
    return
}
if ($Operation -eq "Check") {
    Get-Command Register-ScheduledTask | Out-Null
    Show-ScheduleStatus
    if ((Test-Path -LiteralPath $dispatcherPath) -and (Test-Path -LiteralPath $tokenPath)) {
        Invoke-DailySchedulePreflight -DispatcherPath $dispatcherPath -StateDirectory $stateDirectory -TokenPath $tokenPath
    }
    return
}

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_WORKSPACE)) {
    $workspace = [System.IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd('\', '/')
    if ($AutomationRoot -eq $workspace -or $AutomationRoot.StartsWith($workspace + "\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "AutomationRoot must be outside the Actions checkout"
    }
}
foreach ($directory in @($schedulerRoot, $stateDirectory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Set-DailyScheduleAccess -Path $directory -Directory
}

if (-not [string]::IsNullOrWhiteSpace($env:FIBER_SMOKE_DISPATCH_TOKEN)) {
    Add-Type -AssemblyName System.Security
    $tokenBytes = [Text.Encoding]::UTF8.GetBytes($env:FIBER_SMOKE_DISPATCH_TOKEN.Trim())
    try {
        $encrypted = [Security.Cryptography.ProtectedData]::Protect(
            $tokenBytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        [System.IO.File]::WriteAllBytes($tokenPath, $encrypted)
    }
    finally {
        [Array]::Clear($tokenBytes, 0, $tokenBytes.Length)
        Remove-Item Env:FIBER_SMOKE_DISPATCH_TOKEN -ErrorAction SilentlyContinue
    }
}
if (-not (Test-Path -LiteralPath $tokenPath -PathType Leaf)) {
    throw "Configure repository secret FIBER_SMOKE_DISPATCH_TOKEN with Actions read/write access first"
}
Set-DailyScheduleAccess -Path $tokenPath

Copy-Item -LiteralPath (Join-Path $PSScriptRoot "Dispatch-DailyRun.ps1") -Destination $dispatcherPath -Force
Set-DailyScheduleAccess -Path $dispatcherPath
# This verifies read access only. Installation never dispatches a payment run.
Invoke-DailySchedulePreflight -DispatcherPath $dispatcherPath -StateDirectory $stateDirectory -TokenPath $tokenPath

$beijingNow = [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(8))
$nextStart = [DateTimeOffset]::new($beijingNow.Year, $beijingNow.Month, $beijingNow.Day, 10, 30, 0, [TimeSpan]::FromHours(8))
if ($nextStart -le $beijingNow) { $nextStart = $nextStart.AddDays(1) }
$templatePath = Join-Path (Split-Path -Parent $PSScriptRoot) "deploy/fiber-windows-smoke-dispatch.xml"
# The template omits an encoding declaration because -Xml receives a Unicode
# string, not the UTF-8 bytes stored in the repository.
$taskXml = Get-Content -LiteralPath $templatePath -Raw
$replacements = @{
    "__START_BOUNDARY__" = $nextStart.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
    "__POWERSHELL__" = (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe")
    "__DISPATCHER_PATH__" = $dispatcherPath
    "__STATE_DIRECTORY__" = $stateDirectory
    "__TOKEN_PATH__" = $tokenPath
}
foreach ($key in $replacements.Keys) {
    $taskXml = $taskXml.Replace($key, [Security.SecurityElement]::Escape([string]$replacements[$key]))
}
Register-ScheduledTask -TaskName $taskName -Xml $taskXml -Force | Out-Null
Write-Host "Installed $taskName; first scheduled dispatch: $($nextStart.ToString('yyyy-MM-dd HH:mm zzz'))"
Show-ScheduleStatus
