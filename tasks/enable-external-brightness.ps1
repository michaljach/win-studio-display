<#
.SYNOPSIS
    Experiment: turn on Windows' own external-monitor brightness path.

.DESCRIPTION
    Enables the WIL feature "ExternalBrightness" (ID 12759424), which Windows
    ships disabled at priority 9, with a priority-10 runtime override, then
    restarts the Display Enhancement Service so it picks the change up.
    Runtime overrides don't survive a reboot; run this again after every boot.

    Also needs HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers
    ExternalBrightnessEnabled = 1 (DWORD), which dxgkrnl reads at boot.

    -Revert removes the registry value; the runtime override then ends at the
    next reboot.
#>
param([switch]$Revert)

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-NoExit", "-File", "`"$PSCommandPath`"")
    if ($Revert) { $arguments += "-Revert" }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments
    return
}

$graphicsKey = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
if ($Revert) {
    Remove-ItemProperty $graphicsKey -Name ExternalBrightnessEnabled -ErrorAction SilentlyContinue
    Write-Host "ExternalBrightnessEnabled removed. Reboot to return to the defaults."
    return
}

Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class ExtBrightness {
  [StructLayout(LayoutKind.Sequential)] public struct CFG { public uint FeatureId; public uint Flags; public uint Payload; }
  [StructLayout(LayoutKind.Sequential)] public struct UPDATE {
    public uint FeatureId; public uint Priority; public uint EnabledState; public uint EnabledStateOptions;
    public uint Variant; public uint VariantPayloadKind; public uint VariantPayload; public uint Operation; }
  [DllImport("ntdll.dll")] public static extern int RtlQueryFeatureConfiguration(uint id, int type, ref ulong stamp, out CFG cfg);
  [DllImport("ntdll.dll")] public static extern ulong RtlQueryFeatureConfigurationChangeStamp();
  [DllImport("ntdll.dll")] public static extern int RtlSetFeatureConfigurations(ref ulong stamp, int type, UPDATE[] updates, int count);
}
'@

$featureId = 12759424
$update = New-Object ExtBrightness+UPDATE
$update.FeatureId = $featureId
$update.Priority = 10       # above the shipped priority-9 "disabled"
$update.EnabledState = 2    # enabled
$update.Operation = 1       # feature state
$stamp = [ExtBrightness]::RtlQueryFeatureConfigurationChangeStamp()
$status = [ExtBrightness]::RtlSetFeatureConfigurations([ref]$stamp, 1, @($update), 1)

$s = [uint64]0; $cfg = New-Object ExtBrightness+CFG
[void][ExtBrightness]::RtlQueryFeatureConfiguration($featureId, 1, [ref]$s, [ref]$cfg)
Write-Host ("ExternalBrightness: set status 0x{0:X8}, now priority {1}, state {2} (2 = enabled)" -f $status, ($cfg.Flags -band 0xF), (($cfg.Flags -shr 4) -band 3))
Write-Host ("ExternalBrightnessEnabled registry value: {0}" -f (Get-Item $graphicsKey).GetValue("ExternalBrightnessEnabled"))

Restart-Service DisplayEnhancementService -Force
Write-Host "Display Enhancement Service restarted. Reopen Settings > System > Display and check for a brightness slider."
