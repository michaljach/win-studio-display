<#
.SYNOPSIS
    Installs the Studio Display Brightness driver package.

.DESCRIPTION
    Adds the driver package to the Windows driver store with pnputil, which
    attaches the filter to the monitor devices. Microsoft-signed packages
    install on any Windows 10 2004+/Windows 11 PC with Secure Boot on.

    Test-signed developer builds (build.ps1 -Sign Test) additionally need
    Windows test-signing mode; this script handles that with
    -EnableTestSigning and trusts the test certificate.

    If a monitor fails to start with the driver attached, the package is
    removed again automatically.

.PARAMETER PackagePath
    Folder containing StudioDisplayBrightness.inf. Defaults to this script's
    folder (release zip) or dist\package\StudioDisplayBrightness (dev build).
#>
[CmdletBinding()]
param(
    [string]$PackagePath,
    [string]$TestCertificatePath,
    [switch]$EnableTestSigning,
    [switch]$EnableDebugLog,
    [switch]$PauseAtEnd
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DriverName = "StudioDisplayBrightness"
$ExtensionId = "{2db501d7-e092-43b6-b7a4-926f235929df}"
$MonitorClassKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96e-e325-11ce-bfc1-08002be10318}"

# Relaunch elevated when started by a normal user (e.g. install.cmd).
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-PauseAtEnd")
    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        if ($entry.Value -is [switch]) {
            if ($entry.Value) { $arguments += "-$($entry.Key)" }
        } else {
            $arguments += "-$($entry.Key)", "`"$($entry.Value)`""
        }
    }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -Wait
    return
}

function Exit-Script {
    param([int]$Code)
    if ($PauseAtEnd) {
        Read-Host "Press Enter to close" | Out-Null
    }
    exit $Code
}

function Get-InstalledPackages {
    # pnputil output is localized; the driver store copy of our INF is found by its ExtensionId.
    Get-ChildItem (Join-Path $env:windir "INF\oem*.inf") -ErrorAction SilentlyContinue |
        Where-Object { Select-String -Path $_.FullName -Pattern $ExtensionId -SimpleMatch -Quiet }
}

function Remove-LegacyInstall {
    # Early development builds registered a class-wide filter; with the
    # package filter as well, the driver would attach twice.
    $filters = @((Get-Item $MonitorClassKey).GetValue("UpperFilters") | Where-Object { $_ })
    if ($filters -contains $DriverName) {
        Write-Host "Removing the legacy class filter registration..."
        $remaining = @($filters | Where-Object { $_ -ne $DriverName })
        if ($remaining.Count -gt 0) {
            Set-ItemProperty $MonitorClassKey -Name UpperFilters -Value ([string[]]$remaining) -Type MultiString
        } else {
            Remove-ItemProperty $MonitorClassKey -Name UpperFilters
        }
    }
}

function Get-UnsignedDriverMode {
    $options = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control").SystemStartOptions
    if ($options -match "TESTSIGNING") {
        return "TestSigning"
    }
    # Set for one boot by Startup Settings > "Disable driver signature enforcement".
    if ($options -match "DISABLE_INTEGRITY_CHECKS") {
        return "EnforcementDisabled"
    }
    return $null
}

function Test-MicrosoftSigned {
    param([string]$Path)
    $signature = Get-AuthenticodeSignature $Path
    return $signature.Status -eq "Valid" -and $signature.SignerCertificate.Subject -match "O=Microsoft Corporation"
}

try {
    if (-not $PackagePath) {
        $PackagePath = if (Test-Path (Join-Path $PSScriptRoot "$DriverName.inf")) { $PSScriptRoot } else { Join-Path $PSScriptRoot "dist\package\$DriverName" }
    }
    if (-not $TestCertificatePath) {
        $TestCertificatePath = Join-Path $PSScriptRoot "dist\$DriverName-test.cer"
    }

    $inf = Join-Path $PackagePath "$DriverName.inf"
    $cat = Join-Path $PackagePath "$DriverName.cat"
    if (-not (Test-Path $inf) -or -not (Test-Path $cat)) {
        throw "No driver package found in '$PackagePath'. Build one with build.ps1 or use a release zip."
    }

    if (Test-MicrosoftSigned $cat) {
        Write-Host "Package is Microsoft-signed."
    } else {
        Write-Host "Package is not Microsoft-signed; installing as a test-signed developer build."

        $mode = Get-UnsignedDriverMode
        if ($mode -eq "EnforcementDisabled") {
            Write-Warning @"
Driver signature enforcement is off for this boot only. After the next normal
restart Windows will refuse to load this driver and the monitor devices will
report an error, so run uninstall.cmd before restarting.
"@
        }

        if (-not $mode) {
            if (-not $EnableTestSigning) {
                throw @"
Test-signed builds need one of these (release builds signed by Microsoft need neither):

  A. One restart, no BIOS change (lasts until the next restart):
     Settings > System > Recovery > Advanced startup > Restart now, then
     Troubleshoot > Advanced options > Startup Settings > Restart, press 7
     ("Disable driver signature enforcement"), then run this script again.

  B. Persistent test-signing mode:
     disable Secure Boot in the UEFI/BIOS, run .\install.ps1 -EnableTestSigning,
     restart, then run this script again.
"@
            }

            $secureBoot = $false
            try { $secureBoot = [bool](Confirm-SecureBootUEFI) } catch { }
            if ($secureBoot) {
                throw "Secure Boot is enabled; Windows ignores test signing while it's on. Disable it in the UEFI/BIOS settings first."
            }

            $bitlocker = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue
            if ($bitlocker -and $bitlocker.ProtectionStatus -eq "On") {
                Write-Host "Suspending BitLocker for one reboot so the boot configuration change doesn't trigger recovery..."
                Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 1 | Out-Null
            }

            & bcdedit.exe /set testsigning on
            if ($LASTEXITCODE -ne 0) {
                throw "bcdedit failed to enable test signing."
            }
            Write-Host "Test signing enabled. Reboot, then run this script again."
            Exit-Script 0
        }

        if (-not (Test-Path $TestCertificatePath)) {
            throw "Test certificate not found at '$TestCertificatePath'."
        }
        Import-Certificate -FilePath $TestCertificatePath -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
        Import-Certificate -FilePath $TestCertificatePath -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
    }

    Remove-LegacyInstall

    if ($EnableDebugLog) {
        $filterKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Debug Print Filter"
        New-Item $filterKey -Force | Out-Null
        Set-ItemProperty $filterKey -Name IHVVIDEO -Value 0xF -Type DWord
        Write-Host "Kernel debug output enabled (Sysinternals DebugView, 'Capture Kernel'); effective after a reboot."
    }

    Write-Host "Installing the driver package..."
    & pnputil.exe /add-driver "$inf" /install
    $exitCode = $LASTEXITCODE
    $rebootRequired = $exitCode -eq 3010
    if ($exitCode -ne 0 -and -not $rebootRequired) {
        throw "pnputil failed with exit code $exitCode."
    }

    if ($rebootRequired) {
        Write-Host ""
        Write-Host "Installed. Restart Windows to finish."
        Exit-Script 0
    }

    Start-Sleep -Seconds 2
    $failed = @(Get-PnpDevice -Class Monitor -PresentOnly | Where-Object { $_.Status -eq "Error" })
    if ($failed.Count -gt 0) {
        Write-Warning "A monitor device failed to start with the driver attached. Rolling back."
        foreach ($package in Get-InstalledPackages) {
            & pnputil.exe /delete-driver $package.Name /uninstall /force | Out-Null
        }
        throw "Installation rolled back. Please report this with your Windows build number."
    }

    $state = (Get-CimInstance Win32_SystemDriver -Filter "Name='$DriverName'" -ErrorAction SilentlyContinue).State
    $interfaces = @(Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\{db524086-ba90-4e1e-be42-894e94ecf289}" -ErrorAction SilentlyContinue)
    Write-Host ""
    Write-Host "Installed. Driver state: $state; brightness interfaces: $($interfaces.Count)."
    Write-Host "Use the brightness slider in Settings > System > Display or Quick Settings (Win+A)."
    Exit-Script 0
} catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Exit-Script 1
}
