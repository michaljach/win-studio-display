param(
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "dist/StudioDisplayBrightnessUI.exe")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT") {
    throw "This build script must run on Windows."
}

$uiScript = Join-Path $PSScriptRoot "studio-display-brightness-ui.ps1"
$backendScript = Join-Path $PSScriptRoot "studio-display-brightness.ps1"

foreach ($p in @($uiScript, $backendScript)) {
    if (-not (Test-Path -LiteralPath $p)) {
        throw "Required script not found: $p"
    }
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}

if (-not (Get-Command -Name ps12exe -ErrorAction SilentlyContinue)) {
    if (-not (Get-Module -ListAvailable -Name ps12exe)) {
        Install-Module -Name ps12exe -Scope CurrentUser -Force
    }
    Import-Module ps12exe -ErrorAction Stop
}

if (-not (Get-Command -Name ps12exe -ErrorAction SilentlyContinue)) {
    throw "ps12exe is not available after Install-Module ps12exe."
}

ps12exe -inputFile $uiScript -outputFile $OutputPath

if ($global:LastExitCode -ne 0) {
    throw "ps12exe failed with exit code $($global:LastExitCode)."
}

Write-Output "Built UI executable: $OutputPath"
