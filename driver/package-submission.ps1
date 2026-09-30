<#
.SYNOPSIS
    Creates the EV-signed CAB to submit to the Windows Hardware Dev Center
    (Partner Center) for Microsoft signing.

.DESCRIPTION
    1. Build an unsigned package:   .\build.ps1 -Version 1.0.0.0 -Company "Your Company" -Sign None
    2. Create the submission:       .\package-submission.ps1 -CertificateThumbprint <EV cert thumbprint>
    3. Upload dist\submission\StudioDisplayBrightness.cab in Partner Center
       (Hardware > Submit new hardware), see README.md.

    The EV code-signing certificate usually lives on a hardware token or in a
    cloud HSM and shows up in the current user's certificate store; pass its
    thumbprint. Use -SkipSigning to only build the CAB (for example when your
    certificate provider signs through its own tool).
#>
[CmdletBinding(DefaultParameterSetName = "Sign")]
param(
    [Parameter(ParameterSetName = "Sign", Mandatory = $true)]
    [ValidatePattern('^[0-9A-Fa-f]{40}$')]
    [string]$CertificateThumbprint,

    [Parameter(ParameterSetName = "Sign")]
    [string]$TimestampUrl = "http://timestamp.digicert.com",

    [Parameter(ParameterSetName = "NoSign", Mandatory = $true)]
    [switch]$SkipSigning,

    [string]$PackagePath = (Join-Path $PSScriptRoot "dist\package\StudioDisplayBrightness"),
    [string]$OutDir = (Join-Path $PSScriptRoot "dist\submission"),
    [string]$Toolchain = (Join-Path $env:LOCALAPPDATA "wsd-toolchain")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DriverName = "StudioDisplayBrightness"
$KitDir = "10.0.28000.0"
$signtool = Join-Path $Toolchain "microsoft.windows.sdk.cpp\c\bin\$KitDir\x64\signtool.exe"
$infverif = Join-Path $Toolchain "microsoft.windows.wdk.x64\c\tools\$KitDir\x64\infverif.exe"

function Invoke-Tool {
    param([string]$Path, [string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Path @Arguments 2>&1 | ForEach-Object { Write-Host "$_" }
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($LASTEXITCODE -ne 0) {
        throw "$(Split-Path $Path -Leaf) failed with exit code $LASTEXITCODE."
    }
}

# --- Pre-flight checks -------------------------------------------------------

$inf = Join-Path $PackagePath "$DriverName.inf"
if (-not (Test-Path $inf)) {
    throw "No package at '$PackagePath'. Run: .\build.ps1 -Sign None"
}

$files = @(Get-ChildItem $PackagePath -Recurse -File)
$binaries = @($files | Where-Object Extension -eq ".sys")
if ($binaries.Count -eq 0) {
    throw "The package contains no driver binaries."
}
foreach ($sys in $binaries) {
    $pdb = [IO.Path]::ChangeExtension($sys.FullName, ".pdb")
    if (-not (Test-Path $pdb)) {
        throw "Missing symbols for $($sys.FullName); Partner Center requires the .pdb."
    }
    # Microsoft replaces embedded signatures, but a test certificate in the
    # submission is a sign the wrong build was picked up.
    $signature = Get-AuthenticodeSignature $sys.FullName
    if ($signature.SignerCertificate -and $signature.SignerCertificate.Subject -match "Test Signing") {
        throw "$($sys.FullName) is test-signed. Rebuild with: .\build.ps1 -Sign None"
    }
}

$version = [regex]::Match((Get-Content $inf -Raw), '(?m)^DriverVer\s*=\s*[^,]+,\s*(\S+)').Groups[1].Value
$provider = [regex]::Match((Get-Content $inf -Raw), '(?m)^ProviderName\s*=\s*"([^"]*)"').Groups[1].Value
Write-Host "Package $DriverName $version, provider '$provider'"

Invoke-Tool $infverif @("/h", $inf)

# --- CAB -----------------------------------------------------------------------

New-Item -ItemType Directory -Force $OutDir | Out-Null
$cab = Join-Path $OutDir "$DriverName.cab"
if (Test-Path $cab) {
    Remove-Item $cab
}

# Partner Center wants the package in a subfolder of the CAB (name < 40
# characters, no special characters), with its layout preserved.
$ddf = Join-Path $OutDir "$DriverName.ddf"
$lines = @(
    ".OPTION EXPLICIT",
    ".Set CabinetFileCountThreshold=0",
    ".Set FolderFileCountThreshold=0",
    ".Set FolderSizeThreshold=0",
    ".Set MaxCabinetSize=0",
    ".Set MaxDiskFileCount=0",
    ".Set MaxDiskSize=0",
    ".Set CompressionType=MSZIP",
    ".Set Cabinet=on",
    ".Set Compress=on",
    ".Set CabinetNameTemplate=$DriverName.cab",
    ".Set DiskDirectoryTemplate=`"$OutDir`""
)
foreach ($group in $files | Group-Object DirectoryName) {
    $relative = $group.Name.Substring($PackagePath.TrimEnd('\').Length).TrimStart('\')
    $destination = if ($relative) { "$DriverName\$relative" } else { $DriverName }
    $lines += ".Set DestinationDir=$destination"
    foreach ($file in $group.Group) {
        $lines += "`"$($file.FullName)`""
    }
}
$lines | Set-Content $ddf -Encoding ASCII

Push-Location $OutDir
try {
    $output = & (Join-Path $env:windir "System32\makecab.exe") /F $ddf 2>&1
    if ($LASTEXITCODE -ne 0) {
        $output | ForEach-Object { Write-Host "$_" }
        throw "makecab failed with exit code $LASTEXITCODE."
    }
    $output | Where-Object { "$_" -match "^Total files|^Bytes after" } | ForEach-Object { Write-Host "$_" }
} finally {
    Pop-Location
    Remove-Item (Join-Path $OutDir "setup.inf"), (Join-Path $OutDir "setup.rpt") -ErrorAction SilentlyContinue
}

if (-not $SkipSigning) {
    Write-Host "Signing $cab with EV certificate $CertificateThumbprint"
    Invoke-Tool $signtool @(
        "sign", "/sha1", $CertificateThumbprint, "/fd", "SHA256",
        "/tr", $TimestampUrl, "/td", "SHA256", "/v", $cab
    )
    Invoke-Tool $signtool @("verify", "/pa", $cab)
}

Write-Host ""
Write-Host "Submission CAB: $cab"
Write-Host "Upload it in Partner Center > Hardware > Submit new hardware (see driver\README.md)."
