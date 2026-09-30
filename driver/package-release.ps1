<#
.SYNOPSIS
    Turns the Microsoft-signed package downloaded from Partner Center into the
    end-user release zip.

.DESCRIPTION
    Verifies that the catalog and every driver binary carry a valid Microsoft
    signature, then bundles them with install.cmd / uninstall.cmd and the
    scripts they run. Users unzip it and double-click install.cmd; no test
    signing or Secure Boot changes are involved.

.EXAMPLE
    .\package-release.ps1 -SignedPackage "$env:USERPROFILE\Downloads\Signed_1152921505123456789.zip"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SignedPackage,

    [string]$OutDir = (Join-Path $PSScriptRoot "dist\release")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DriverName = "StudioDisplayBrightness"

function Test-MicrosoftSignature {
    param([string]$Path)
    $signature = Get-AuthenticodeSignature $Path
    if ($signature.Status -ne "Valid" -or $signature.SignerCertificate.Subject -notmatch "O=Microsoft Corporation") {
        throw "$Path is not validly signed by Microsoft (status: $($signature.Status), signer: $($signature.SignerCertificate.Subject))."
    }
}

$work = Join-Path ([IO.Path]::GetTempPath()) "sdb-release-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $work | Out-Null

try {
    if ((Get-Item $SignedPackage).PSIsContainer) {
        $source = $SignedPackage
    } else {
        Expand-Archive $SignedPackage (Join-Path $work "download")
        $source = Join-Path $work "download"
    }

    $inf = Get-ChildItem $source -Recurse -Filter "$DriverName.inf" | Select-Object -First 1
    if (-not $inf) {
        throw "No $DriverName.inf found in '$SignedPackage'."
    }
    $package = $inf.DirectoryName

    $catalog = Get-ChildItem $package -Filter *.cat | Select-Object -First 1
    if (-not $catalog) {
        throw "The signed package has no catalog."
    }
    Test-MicrosoftSignature $catalog.FullName
    $binaries = @(Get-ChildItem $package -Recurse -Filter *.sys)
    foreach ($sys in $binaries) {
        Test-MicrosoftSignature $sys.FullName
    }

    $version = [regex]::Match((Get-Content $inf.FullName -Raw), '(?m)^DriverVer\s*=\s*[^,]+,\s*(\S+)').Groups[1].Value
    $name = "$DriverName-$version"
    $staging = Join-Path $work $name
    New-Item -ItemType Directory -Force $staging | Out-Null

    # Driver package (symbols stay out of the end-user download).
    Copy-Item $inf.FullName $staging
    Copy-Item $catalog.FullName (Join-Path $staging "$DriverName.cat")
    foreach ($sys in $binaries) {
        $relative = $sys.DirectoryName.Substring($package.Length).TrimStart('\')
        $target = Join-Path $staging $relative
        New-Item -ItemType Directory -Force $target | Out-Null
        Copy-Item $sys.FullName $target
    }

    foreach ($file in "install.cmd", "install.ps1", "uninstall.cmd", "uninstall.ps1") {
        Copy-Item (Join-Path $PSScriptRoot $file) $staging
    }
    @"
Studio Display Brightness $version

Native Windows brightness control for the Apple Studio Display and other
USB Monitor Control Class displays.

Install:    double-click install.cmd   (asks for administrator rights)
Uninstall:  double-click uninstall.cmd

Afterwards use the brightness slider in Settings > System > Display or in
Quick Settings (Win+A). The display's USB-C/Thunderbolt cable must be
connected. Requires Windows 10 version 2004 or later (x64 or ARM64).
"@ | Set-Content (Join-Path $staging "README.txt") -Encoding UTF8

    New-Item -ItemType Directory -Force $OutDir | Out-Null
    $zip = Join-Path $OutDir "$name.zip"
    if (Test-Path $zip) {
        Remove-Item $zip
    }
    Compress-Archive -Path $staging -DestinationPath $zip

    Write-Host "Verified Microsoft signatures on $($binaries.Count + 1) files."
    Write-Host "Release: $zip"
} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
