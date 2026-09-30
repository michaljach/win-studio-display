<#
.SYNOPSIS
    Builds the Studio Display Brightness tray app (dist\StudioDisplayBrightness.exe).

.DESCRIPTION
    Compiles tray\src with the C# compiler that ships with .NET Framework 4.x
    (part of Windows 10/11), so no Visual Studio or .NET SDK is needed. The
    output is AnyCPU and runs natively on x64 and ARM64.
#>
param(
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "dist\StudioDisplayBrightness.exe")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$csc = @(
    (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
    (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) {
    throw "csc.exe from .NET Framework 4.x was not found."
}

$sourceDir = Join-Path $PSScriptRoot "src"
$objDir = Join-Path $PSScriptRoot "obj"
New-Item -ItemType Directory -Force -Path $objDir, (Split-Path -Parent $OutputPath) | Out-Null

# Render the EXE icon with the same drawing code the app uses at runtime.
$iconPath = Join-Path $objDir "app.ico"
if (-not ("StudioDisplayBrightness.IconArt" -as [type])) {
    Add-Type -Path (Join-Path $sourceDir "IconArt.cs") -ReferencedAssemblies System.Drawing
}
[StudioDisplayBrightness.IconArt]::WriteIco($iconPath, [System.Drawing.Color]::FromArgb(0xF5, 0xB0, 0x0B), [int[]](16, 20, 24, 32, 40, 48, 64, 256))

$sources = Get-ChildItem -LiteralPath $sourceDir -Filter *.cs | ForEach-Object { $_.FullName }
$arguments = @(
    "/nologo",
    "/target:winexe",
    "/platform:anycpu",
    "/optimize+",
    "/warnaserror+",
    "/out:$OutputPath",
    "/win32icon:$iconPath",
    "/win32manifest:$(Join-Path $PSScriptRoot 'app.manifest')",
    "/reference:System.dll",
    "/reference:System.Drawing.dll",
    "/reference:System.Windows.Forms.dll"
) + $sources

& $csc @arguments
if ($LASTEXITCODE -ne 0) {
    throw "csc.exe failed with exit code $LASTEXITCODE."
}

Write-Output "Built $OutputPath"
