<#
.SYNOPSIS
    Removes the Studio Display Brightness driver package.

.PARAMETER RemoveTestCertificate
    Also remove the developer test certificate from the machine's trusted stores.

.PARAMETER DisableTestSigning
    Also turn Windows test-signing mode off (takes effect after a reboot).
#>
[CmdletBinding()]
param(
    [switch]$RemoveTestCertificate,
    [switch]$DisableTestSigning,
    [switch]$PauseAtEnd
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DriverName = "StudioDisplayBrightness"
$ExtensionId = "{2db501d7-e092-43b6-b7a4-926f235929df}"
$MonitorClassKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96e-e325-11ce-bfc1-08002be10318}"
$TestCertSubject = "CN=StudioDisplayBrightness Test Signing"

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-PauseAtEnd")
    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        if ($entry.Value) { $arguments += "-$($entry.Key)" }
    }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -Wait
    return
}

$exitCode = 0
try {
    $packages = @(Get-ChildItem (Join-Path $env:windir "INF\oem*.inf") -ErrorAction SilentlyContinue |
        Where-Object { Select-String -Path $_.FullName -Pattern $ExtensionId -SimpleMatch -Quiet })

    foreach ($package in $packages) {
        Write-Host "Removing driver package $($package.Name)..."
        & pnputil.exe /delete-driver $package.Name /uninstall /force
    }

    # Clean up the class-wide registration used by early development builds.
    $filters = @((Get-Item $MonitorClassKey).GetValue("UpperFilters") | Where-Object { $_ })
    if ($filters -contains $DriverName) {
        $remaining = @($filters | Where-Object { $_ -ne $DriverName })
        if ($remaining.Count -gt 0) {
            Set-ItemProperty $MonitorClassKey -Name UpperFilters -Value ([string[]]$remaining) -Type MultiString
        } else {
            Remove-ItemProperty $MonitorClassKey -Name UpperFilters
        }
        foreach ($monitor in Get-PnpDevice -Class Monitor -PresentOnly) {
            & pnputil.exe /restart-device "$($monitor.InstanceId)" | Out-Null
        }
        $legacyBinary = Join-Path $env:SystemRoot "System32\drivers\$DriverName.sys"
        if (Test-Path $legacyBinary) {
            Remove-Item $legacyBinary -Force -ErrorAction SilentlyContinue
        }
    }

    if ($packages.Count -eq 0 -and (Get-Service $DriverName -ErrorAction SilentlyContinue)) {
        & sc.exe delete $DriverName | Out-Null
    }

    if ($RemoveTestCertificate) {
        foreach ($store in "Root", "TrustedPublisher") {
            Get-ChildItem "Cert:\LocalMachine\$store" | Where-Object Subject -eq $TestCertSubject | Remove-Item
        }
    }

    if ($DisableTestSigning) {
        & bcdedit.exe /set testsigning off | Out-Null
        Write-Host "Test signing disabled; reboot to apply."
    }

    Write-Host "Studio Display Brightness removed."
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}

if ($PauseAtEnd) {
    Read-Host "Press Enter to close" | Out-Null
}
exit $exitCode
