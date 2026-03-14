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

if (-not (Test-Path -LiteralPath $uiScript)) {
    throw "UI script not found: $uiScript"
}

if (-not (Test-Path -LiteralPath $backendScript)) {
    throw "Backend script not found: $backendScript"
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}

$ps2exeCommand = Get-Command -Name Invoke-PS2EXE -ErrorAction SilentlyContinue
if (-not $ps2exeCommand) {
    $ps2exeCommand = Get-Command -Name Invoke-ps2exe -ErrorAction SilentlyContinue
}

if (-not $ps2exeCommand) {
    if (-not (Get-Module -ListAvailable -Name ps2exe)) {
        Install-Module -Name ps2exe -Scope CurrentUser -Force
    }

    Import-Module ps2exe -ErrorAction Stop

    $ps2exeCommand = Get-Command -Name Invoke-PS2EXE -ErrorAction SilentlyContinue
    if (-not $ps2exeCommand) {
        $ps2exeCommand = Get-Command -Name Invoke-ps2exe -ErrorAction SilentlyContinue
    }
}

if (-not $ps2exeCommand) {
    throw "Could not find ps2exe command after installing/importing module."
}

$buildArgs = @{
    InputFile = $uiScript
    OutputFile = $OutputPath
    NoConsole = $true
    Title = "Studio Display Brightness"
    Product = "Studio Display Brightness"
    Company = "win-studio-display"
}

& $ps2exeCommand.Name @buildArgs

Copy-Item -LiteralPath $backendScript -Destination (Join-Path $outputDirectory "studio-display-brightness.ps1") -Force

Write-Output "Built UI executable: $OutputPath"
Write-Output "Copied backend script next to EXE."
