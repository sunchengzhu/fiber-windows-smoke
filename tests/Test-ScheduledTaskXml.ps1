#Requires -RunAsAdministrator
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$templatePath = Join-Path (Split-Path -Parent $PSScriptRoot) "deploy/fiber-windows-smoke-dispatch.xml"
$taskXml = Get-Content -LiteralPath $templatePath -Raw
$replacements = @{
    "__START_BOUNDARY__" = [DateTime]::UtcNow.AddDays(1).ToString("yyyy-MM-ddTHH:mm:ssZ")
    "__POWERSHELL__" = (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe")
    "__DISPATCHER_PATH__" = "C:\scheduler-validation\Dispatch-DailyRun.ps1"
    "__STATE_DIRECTORY__" = "C:\scheduler-validation\state"
    "__TOKEN_PATH__" = "C:\scheduler-validation\token.dpapi"
}
foreach ($key in $replacements.Keys) {
    $taskXml = $taskXml.Replace($key, [Security.SecurityElement]::Escape([string]$replacements[$key]))
}

# Exercise Windows' own XML parser with the same Unicode string used by the
# installer. A .NET XML parse alone misses the UTF-8 declaration regression.
# TASK_VALIDATE_ONLY (1) validates without registering or executing any task:
# https://learn.microsoft.com/en-us/windows/win32/taskschd/taskfolder-registertask
$scheduler = New-Object -ComObject "Schedule.Service"
$scheduler.Connect()
$folder = $scheduler.GetFolder("\")
$validationName = "FiberSmokeXmlValidation-$([Guid]::NewGuid().ToString('N'))"
$folder.RegisterTask($validationName, $taskXml, 1, "SYSTEM", $null, 5, $null) | Out-Null
Write-Host "Windows Task Scheduler accepted the task XML; no task registered or executed."
