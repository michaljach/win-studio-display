<#
.SYNOPSIS
    Builds the StudioDisplayBrightness driver package (x64 + ARM64).

.DESCRIPTION
    Uses the Windows Driver Kit / SDK NuGet packages and a portable LLVM
    (clang-cl, lld-link, llvm-rc), so no Visual Studio or admin rights are
    needed. The first run downloads the toolchain into
    %LOCALAPPDATA%\wsd-toolchain (about 2 GB).

    Output (dist\package\StudioDisplayBrightness):
        StudioDisplayBrightness.inf   stamped extension INF
        StudioDisplayBrightness.cat   catalog
        amd64\StudioDisplayBrightness.sys / .pdb
        arm64\StudioDisplayBrightness.sys / .pdb

    -Sign Test  (default) test-signs the binaries and catalog for local
                testing on machines in test-signing mode.
    -Sign None  leaves them unsigned, for a Partner Center submission
                (Microsoft re-signs everything; see package-submission.ps1).

.EXAMPLE
    .\build.ps1
.EXAMPLE
    .\build.ps1 -Version 1.2.0.0 -Company "Contoso Ltd" -Sign None
#>
[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
    [string]$Version = "1.0.0.0",

    [string]$Company = "win-studio-display",

    [ValidateSet("x64", "arm64")]
    [string[]]$Architecture = @("x64", "arm64"),

    [ValidateSet("Release", "Debug")]
    [string]$Configuration = "Release",

    [ValidateSet("Test", "None")]
    [string]$Sign = "Test",

    [string]$Toolchain = (Join-Path $env:LOCALAPPDATA "wsd-toolchain"),
    [string]$OutDir = (Join-Path $PSScriptRoot "dist")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$DriverName = "StudioDisplayBrightness"
$KitVersion = "10.0.28000.2526"
$KitDir = "10.0.28000.0"
$LlvmVersion = "23.1.2"
$KmdfVersion = "1.15"
$TestCertSubject = "CN=StudioDisplayBrightness Test Signing"
$CatalogOs = "10_VB_X64,10_VB_ARM64,10_CO_X64,10_CO_ARM64,10_NI_X64,10_NI_ARM64,10_GE_X64,10_GE_ARM64"

$Targets = @{
    x64   = @{ Wdk = "microsoft.windows.wdk.x64";   LibArch = "x64";   PackageDir = "amd64"; Triple = "x86_64-pc-windows-msvc";  Machine = "X64";   Defines = @("_AMD64_", "AMD64") }
    arm64 = @{ Wdk = "microsoft.windows.wdk.arm64"; LibArch = "ARM64"; PackageDir = "arm64"; Triple = "aarch64-pc-windows-msvc"; Machine = "ARM64"; Defines = @("_ARM64_", "ARM64") }
}

# ---------------------------------------------------------------------------
# Toolchain
# ---------------------------------------------------------------------------

function Get-NuGetPackage {
    param([string]$Id)

    $target = Join-Path $Toolchain $Id
    if (Test-Path $target) {
        return
    }

    Write-Host "Downloading $Id $KitVersion..."
    $zip = "$target.zip"
    Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/$Id/$KitVersion/$Id.$KitVersion.nupkg" -OutFile $zip -UseBasicParsing
    Expand-Archive $zip $target -Force
    Remove-Item $zip
}

function Get-Llvm {
    $target = Join-Path $Toolchain "llvm-msi"
    if (Test-Path (Join-Path $target "LLVM\bin\clang-cl.exe")) {
        return
    }

    Write-Host "Downloading LLVM $LlvmVersion..."
    $msi = Join-Path $Toolchain "llvm.msi"
    Invoke-WebRequest "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LlvmVersion/LLVM-$LlvmVersion-win64.msi" -OutFile $msi -UseBasicParsing

    # An administrative install only extracts the files; it needs no elevation.
    $process = Start-Process msiexec.exe -ArgumentList @("/a", "`"$msi`"", "/qn", "TARGETDIR=`"$target`"") -Wait -PassThru
    Remove-Item $msi
    if ($process.ExitCode -ne 0) {
        throw "LLVM extraction failed with exit code $($process.ExitCode)."
    }
}

function Invoke-Tool {
    param([string]$Path, [string[]]$Arguments)

    # Windows PowerShell turns native stderr into terminating errors under
    # "Stop"; let tool diagnostics through and judge by the exit code.
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

# ---------------------------------------------------------------------------
# Build steps
# ---------------------------------------------------------------------------

function Build-Driver {
    param([string]$Arch)

    $t = $Targets[$Arch]
    $wdk = Join-Path $Toolchain "$($t.Wdk)\c"
    $wdkHeaders = Join-Path $Toolchain "microsoft.windows.wdk.x64\c"
    $objDir = Join-Path $OutDir "obj\$Arch"
    $binDir = Join-Path $PackageRoot $t.PackageDir
    New-Item -ItemType Directory -Force $objDir, $binDir | Out-Null

    $includes = @(
        "$wdkHeaders\Include\$KitDir\km",
        "$wdkHeaders\Include\$KitDir\km\crt",
        "$wdkHeaders\Include\$KitDir\shared",
        "$sdk\Include\$KitDir\shared",
        "$wdkHeaders\Include\wdf\kmdf\$KmdfVersion"
    ) | ForEach-Object { "/imsvc$_" }

    $defines = @($t.Defines) + @(
        "_WIN64", "_KERNEL_MODE", "WINNT=1",
        "NTDDI_VERSION=0x0A00000C", "_WIN32_WINNT=0x0A00", "WINVER=0x0A00",
        "KMDF_VERSION_MAJOR=1", "KMDF_VERSION_MINOR=$($KmdfVersion.Split('.')[1])",
        "POOL_NX_OPTIN=1"
    ) | ForEach-Object { "/D$_" }
    if ($Configuration -eq "Debug") {
        $defines += "/DDBG=1"
    }

    $flags = @(
        "/nologo", "/c", "/kernel", "/Zi", "/W4", "/WX", "/GS", "/guard:cf", "/Gy", "/GR-",
        "/Zc:wchar_t", "/Brepro", "--target=$($t.Triple)",
        "-fms-extensions", "-fms-compatibility"
    )
    $flags += if ($Configuration -eq "Debug") { "/Od" } else { "/O2" }

    $objects = foreach ($source in Get-ChildItem (Join-Path $PSScriptRoot "src") -Filter *.c) {
        $obj = Join-Path $objDir ($source.BaseName + ".obj")
        Write-Host "  [$Arch] $($source.Name)"
        Invoke-Tool $clang ($flags + $defines + $includes + @("/Fo$obj", $source.FullName))
        $obj
    }

    $res = Join-Path $objDir "$DriverName.res"
    Invoke-Tool $rc @("/nologo", "/I", $GeneratedDir, "/FO", $res, (Join-Path $PSScriptRoot "src\$DriverName.rc"))

    $kmLib = "$wdk\Lib\$KitDir\km\$($t.LibArch)"
    $wdfLib = "$wdk\Lib\wdf\kmdf\$($t.LibArch)\$KmdfVersion"
    $sys = Join-Path $binDir "$DriverName.sys"

    Write-Host "  [$Arch] linking"
    Invoke-Tool $lld (@(
        "/nologo", "/DRIVER", "/SUBSYSTEM:NATIVE,10.00", "/MACHINE:$($t.Machine)",
        "/ENTRY:FxDriverEntry", "/NODEFAULTLIB", "/DEBUG", "/OPT:REF", "/OPT:ICF",
        # lld-link replaces a section's attributes with the /SECTION flags
        # (MSVC link adds to them), so INIT must keep "er" or it isn't executable.
        "/RELEASE", "/Brepro", "/guard:cf", "/SECTION:INIT,erd", "/MERGE:.CRT=.rdata",
        # lld-link marks images terminal-server aware by default; the kernel
        # loader rejects such drivers with STATUS_CONFLICTING_ADDRESSES.
        "/TSAWARE:NO",
        "/OUT:$sys", "/PDB:$(Join-Path $binDir "$DriverName.pdb")"
    ) + @($objects) + @($res) + @(
        "$kmLib\ntoskrnl.lib", "$kmLib\hal.lib", "$kmLib\hidparse.lib",
        "$kmLib\ntstrsafe.lib", "$kmLib\BufferOverflowFastFailK.lib", "$kmLib\cfg_support_v1.lib",
        "$wdfLib\WdfDriverEntry.lib", "$wdfLib\WdfLdr.lib"
    ))

    Test-HvciCompatible $sys
    return $sys
}

# Memory integrity (HVCI) refuses drivers with writable+executable sections
# or without NX; Windows 11 enables it by default on new installs.
function Test-HvciCompatible {
    param([string]$Sys)

    $headers = & $readobj --file-headers --sections --coff-load-config $Sys
    $text = $headers -join "`n"

    if ($text -notmatch "IMAGE_DLL_CHARACTERISTICS_NX_COMPAT") {
        throw "$Sys is not NX compatible."
    }
    if ($text -notmatch "SectionAlignment: 4096") {
        throw "$Sys does not use 4 KB section alignment."
    }
    if ($text -match "IMAGE_DLL_CHARACTERISTICS_TERMINAL_SERVER_AWARE") {
        throw "$Sys is marked terminal-server aware; Windows refuses to load it."
    }
    if ($text -notmatch "IMAGE_DLL_CHARACTERISTICS_GUARD_CF") {
        throw "$Sys was not built with Control Flow Guard."
    }
    if ($text -notmatch "SecurityCookie: 0x[1-9A-F]") {
        throw "$Sys has no /GS security cookie in its load config."
    }

    foreach ($section in ($text -split "Section \{") | Select-Object -Skip 1) {
        if ($section -match "IMAGE_SCN_MEM_EXECUTE" -and $section -match "IMAGE_SCN_MEM_WRITE") {
            $name = [regex]::Match($section, "Name: (\S+)").Groups[1].Value
            throw "$Sys has a writable and executable section ($name)."
        }
        # The kernel loader refuses code sections that aren't mapped executable.
        if ($section -match "IMAGE_SCN_CNT_CODE" -and $section -notmatch "IMAGE_SCN_MEM_EXECUTE") {
            $name = [regex]::Match($section, "Name: (\S+)").Groups[1].Value
            throw "$Sys has a code section that isn't executable ($name)."
        }
    }

    $names = [regex]::Matches($text, "Name: (\S+) \(") | ForEach-Object { $_.Groups[1].Value }
    $duplicates = @($names | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
    if ($duplicates.Count -gt 0) {
        throw "$Sys has duplicate sections ($($duplicates -join ', ')); check section attributes."
    }
}

function Write-VersionHeader {
    $parts = $Version.Split(".")
    $escapedCompany = $Company.Replace('\', '\\').Replace('"', '\"')
    @(
        "#define SDB_VER_MAJOR $($parts[0])",
        "#define SDB_VER_MINOR $($parts[1])",
        "#define SDB_VER_BUILD $($parts[2])",
        "#define SDB_VER_REVISION $($parts[3])",
        "#define SDB_VER_STRING `"$Version`"",
        "#define SDB_COMPANY `"$escapedCompany`""
    ) | Set-Content (Join-Path $GeneratedDir "sdb_version.h") -Encoding ASCII
}

function Write-Inf {
    $inf = Get-Content (Join-Path $PSScriptRoot "package\$DriverName.inf") -Raw
    $date = (Get-Date).ToUniversalTime().ToString("MM/dd/yyyy", [Globalization.CultureInfo]::InvariantCulture)
    $inf = [regex]::Replace($inf, '(?m)^DriverVer\s*=.*$', "DriverVer   = $date,$Version")
    $inf = [regex]::Replace($inf, '(?m)^ProviderName\s*=.*$', "ProviderName          = `"$($Company.Replace('"', '""'))`"")

    # Only list the architectures being built: drop every section, DestinationDirs
    # entry and Manufacturer decoration that names a skipped architecture.
    foreach ($arch in $Targets.Keys) {
        if ($Architecture -contains $arch) {
            continue
        }
        $token = $Targets[$arch].PackageDir
        $inf = [regex]::Replace($inf, "(?msi)^\[[^\]\r\n]*$token[^\]\r\n]*\].*?(?=^\[|\z)", "")
        $inf = [regex]::Replace($inf, "(?mi)^\S*_$token\s*=\s*13,.*\r?\n", "")
        $inf = [regex]::Replace($inf, "(?i),?\s*NT$token\.10\.0\.\.\.\d+", "")
        $inf = [regex]::Replace($inf, "(?m)(=\s*Monitors)\s*,\s*,", '$1,')
    }

    $path = Join-Path $PackageRoot "$DriverName.inf"
    # INF files are read as UTF-16 when they carry a BOM; plain ASCII is fine too.
    [IO.File]::WriteAllText($path, $inf, [Text.Encoding]::ASCII)
    return $path
}

function Get-TestCertificate {
    $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
        Where-Object { $_.Subject -eq $TestCertSubject -and $_.NotAfter -gt (Get-Date).AddDays(30) } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1

    if ($null -eq $cert) {
        Write-Host "Creating test signing certificate '$TestCertSubject'..."
        $cert = New-SelfSignedCertificate `
            -Type CodeSigningCert `
            -Subject $TestCertSubject `
            -CertStoreLocation Cert:\CurrentUser\My `
            -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 `
            -NotAfter (Get-Date).AddYears(5)
    }
    return $cert
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Dev builds get an ever-increasing version so install.ps1 (pnputil) swaps the
# running driver in place instead of treating it as already installed.
if ($Sign -eq "Test" -and -not $PSBoundParameters.ContainsKey("Version")) {
    $now = (Get-Date).ToUniversalTime()
    $Version = "1.0.{0}.{1}" -f [int]($now.Date - [datetime]"2026-01-01").TotalDays, [int]$now.TimeOfDay.TotalMinutes
}

New-Item -ItemType Directory -Force $Toolchain | Out-Null
Get-NuGetPackage "microsoft.windows.wdk.x64"
Get-NuGetPackage "microsoft.windows.sdk.cpp"
if ($Architecture -contains "arm64") {
    Get-NuGetPackage "microsoft.windows.wdk.arm64"
}
Get-Llvm

$sdk = Join-Path $Toolchain "microsoft.windows.sdk.cpp\c"
$wdkBin = Join-Path $Toolchain "microsoft.windows.wdk.x64\c"
$llvm = Join-Path $Toolchain "llvm-msi\LLVM\bin"
$clang = Join-Path $llvm "clang-cl.exe"
$lld = Join-Path $llvm "lld-link.exe"
$rc = Join-Path $llvm "llvm-rc.exe"
$readobj = Join-Path $llvm "llvm-readobj.exe"
$signtool = Join-Path $sdk "bin\$KitDir\x64\signtool.exe"
$inf2cat = Join-Path $wdkBin "bin\$KitDir\x86\Inf2Cat.exe"
$infverif = Join-Path $wdkBin "tools\$KitDir\x64\infverif.exe"

$PackageRoot = Join-Path $OutDir "package\$DriverName"
$GeneratedDir = Join-Path $OutDir "obj\generated"
if (Test-Path $PackageRoot) {
    Remove-Item $PackageRoot -Recurse -Force
}
New-Item -ItemType Directory -Force $PackageRoot, $GeneratedDir | Out-Null

Write-Host "Building $DriverName $Version ($Configuration; $($Architecture -join ', '))"
Write-VersionHeader
$binaries = foreach ($arch in $Architecture) { Build-Driver $arch }

Write-Host "Packaging"
$inf = Write-Inf
Invoke-Tool $infverif @("/h", "/v", $inf)

$testCert = $null
if ($Sign -eq "Test") {
    $testCert = Get-TestCertificate
    foreach ($sys in $binaries) {
        Invoke-Tool $signtool @("sign", "/q", "/fd", "SHA256", "/s", "My", "/sha1", $testCert.Thumbprint, $sys)
    }
}

$osList = ($CatalogOs.Split(",") | Where-Object {
    ($_ -like "*_X64" -and $Architecture -contains "x64") -or ($_ -like "*_ARM64" -and $Architecture -contains "arm64")
}) -join ","
Invoke-Tool $inf2cat @("/driver:$PackageRoot", "/os:$osList", "/uselocaltime")

if ($testCert) {
    Invoke-Tool $signtool @("sign", "/q", "/fd", "SHA256", "/s", "My", "/sha1", $testCert.Thumbprint, (Join-Path $PackageRoot "$DriverName.cat"))
    Export-Certificate -Cert $testCert -FilePath (Join-Path $OutDir "$DriverName-test.cer") -Type CERT | Out-Null
}

Write-Host ""
Write-Host "Package: $PackageRoot"
Get-ChildItem $PackageRoot -Recurse -File | ForEach-Object {
    Write-Host ("  {0,-45} {1,8:N0} bytes" -f $_.FullName.Substring($PackageRoot.Length + 1), $_.Length)
}
if ($Sign -eq "Test") {
    Write-Host "Test-signed. Install on a test-signing machine with install.ps1."
} else {
    Write-Host "Unsigned. Create the Partner Center submission with package-submission.ps1."
}
