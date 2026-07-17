[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$files = Get-ChildItem -Path $projectRoot -Recurse -File | Where-Object {
    $_.Extension -in @(".ps1", ".psm1")
}
$failed = $false

foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null

    if ($errors.Count -gt 0) {
        $failed = $true
        foreach ($parseError in $errors) {
            Write-Error "$($file.FullName):$($parseError.Extent.StartLineNumber): $($parseError.Message)" -ErrorAction Continue
        }
    }
}

if ($failed) {
    throw "PowerShell syntax validation failed"
}
Write-Host "Parsed $($files.Count) PowerShell files successfully"
