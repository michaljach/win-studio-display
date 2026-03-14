param(
    [Parameter(Position = 0)]
    [ValidateSet("get", "set", "inc", "dec", "list")]
    [string]$Command = "get",

    [Parameter(Position = 1)]
    [int]$Value,

    [string]$MonitorName = "Studio Display",
    [int]$MonitorIndex,
    [switch]$All
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT") {
    throw "This tool only works on Windows."
}

if (("set", "inc", "dec") -contains $Command -and -not $PSBoundParameters.ContainsKey("Value")) {
    throw "The '$Command' command requires a numeric value."
}

if ($PSBoundParameters.ContainsKey("Value")) {
    switch ($Command) {
        "set" {
            if ($Value -lt 0 -or $Value -gt 100) {
                throw "For 'set', value must be between 0 and 100."
            }
        }
        "inc" {
            if ($Value -lt 1 -or $Value -gt 100) {
                throw "For 'inc', value must be between 1 and 100."
            }
        }
        "dec" {
            if ($Value -lt 1 -or $Value -gt 100) {
                throw "For 'dec', value must be between 1 and 100."
            }
        }
        default { }
    }
}

if ($PSBoundParameters.ContainsKey("MonitorIndex") -and $MonitorIndex -lt 0) {
    throw "MonitorIndex must be 0 or higher."
}

$nativeCode = @"
using System;
using System.Runtime.InteropServices;

public static class NativeMethods
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int left;
        public int top;
        public int right;
        public int bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR
    {
        public IntPtr hPhysicalMonitor;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }

    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData);

    [DllImport("user32.dll")]
    public static extern bool EnumDisplayMonitors(
        IntPtr hdc,
        IntPtr lprcClip,
        MonitorEnumProc lpfnEnum,
        IntPtr dwData);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(
        IntPtr hMonitor,
        out uint pdwNumberOfPhysicalMonitors);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetPhysicalMonitorsFromHMONITOR(
        IntPtr hMonitor,
        uint dwPhysicalMonitorArraySize,
        [Out] PHYSICAL_MONITOR[] pPhysicalMonitorArray);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool DestroyPhysicalMonitors(
        uint dwPhysicalMonitorArraySize,
        PHYSICAL_MONITOR[] pPhysicalMonitorArray);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetMonitorCapabilities(
        IntPtr hMonitor,
        out uint pdwMonitorCapabilities,
        out uint pdwSupportedColorTemperatures);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetMonitorBrightness(
        IntPtr hMonitor,
        out uint pdwMinimumBrightness,
        out uint pdwCurrentBrightness,
        out uint pdwMaximumBrightness);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool SetMonitorBrightness(
        IntPtr hMonitor,
        uint dwNewBrightness);
}
"@

Add-Type -TypeDefinition $nativeCode -Language CSharp

function Convert-ToPercent {
    param(
        [uint32]$RawValue,
        [uint32]$MinValue,
        [uint32]$MaxValue
    )

    if ($MaxValue -le $MinValue) {
        return 0
    }

    return [int][Math]::Round((($RawValue - $MinValue) * 100.0) / ($MaxValue - $MinValue))
}

function Convert-ToRawBrightness {
    param(
        [int]$Percent,
        [uint32]$MinValue,
        [uint32]$MaxValue
    )

    if ($MaxValue -le $MinValue) {
        return $MinValue
    }

    $clampedPercent = [Math]::Max(0, [Math]::Min(100, $Percent))
    return [uint32][Math]::Round($MinValue + (($MaxValue - $MinValue) * ($clampedPercent / 100.0)))
}

function Convert-UInt16ArrayToText {
    param([uint16[]]$Data)

    if (-not $Data) {
        return ""
    }

    $characters = foreach ($value in $Data) {
        if ($value -ne 0) {
            [char]$value
        }
    }

    return (-join $characters).Trim()
}

function Get-WmiFriendlyMonitorNames {
    $names = New-Object "System.Collections.Generic.List[string]"

    try {
        $entries = Get-CimInstance -Namespace "root/wmi" -ClassName "WmiMonitorID" -ErrorAction Stop |
            Where-Object { $_.Active -eq $true }

        foreach ($entry in $entries) {
            $friendly = Convert-UInt16ArrayToText -Data $entry.UserFriendlyName
            if ([string]::IsNullOrWhiteSpace($friendly)) {
                $manufacturer = Convert-UInt16ArrayToText -Data $entry.ManufacturerName
                $productCode = Convert-UInt16ArrayToText -Data $entry.ProductCodeID
                $friendly = ("{0} {1}" -f $manufacturer, $productCode).Trim()
            }

            if (-not [string]::IsNullOrWhiteSpace($friendly)) {
                $names.Add($friendly) | Out-Null
            }
        }
    }
    catch {
        # Best-effort enrichment only; keep raw DXVA names when WMI is unavailable.
    }

    return $names
}

$physicalMonitors = New-Object "System.Collections.Generic.List[NativeMethods+PHYSICAL_MONITOR]"
$monitorInfo = New-Object "System.Collections.Generic.List[object]"

$enumCallback = [NativeMethods+MonitorEnumProc]{
    param(
        [IntPtr]$hMonitor,
        [IntPtr]$hdcMonitor,
        [ref][NativeMethods+RECT]$lprcMonitor,
        [IntPtr]$dwData
    )

    [uint32]$count = 0
    if (-not [NativeMethods]::GetNumberOfPhysicalMonitorsFromHMONITOR($hMonitor, [ref]$count)) {
        return $true
    }

    if ($count -eq 0) {
        return $true
    }

    $buffer = New-Object "NativeMethods+PHYSICAL_MONITOR[]" $count
    if (-not [NativeMethods]::GetPhysicalMonitorsFromHMONITOR($hMonitor, $count, $buffer)) {
        return $true
    }

    foreach ($physical in $buffer) {
        $physicalMonitors.Add($physical) | Out-Null

        [uint32]$caps = 0
        [uint32]$temps = 0
        $hasCaps = [NativeMethods]::GetMonitorCapabilities($physical.hPhysicalMonitor, [ref]$caps, [ref]$temps)
        $supportsBrightnessFlag = $hasCaps -and (($caps -band 0x2) -ne 0)

        [uint32]$min = 0
        [uint32]$current = 0
        [uint32]$max = 0
        $canReadBrightness = [NativeMethods]::GetMonitorBrightness($physical.hPhysicalMonitor, [ref]$min, [ref]$current, [ref]$max)

        $percent = $null
        if ($canReadBrightness) {
            $percent = Convert-ToPercent -RawValue $current -MinValue $min -MaxValue $max
        }

        $monitorInfo.Add([pscustomobject]@{
            Index = -1
            Name = $physical.szPhysicalMonitorDescription.Trim()
            RawName = $physical.szPhysicalMonitorDescription.Trim()
            FriendlyName = $null
            Handle = $physical.hPhysicalMonitor
            SupportsBrightness = ($supportsBrightnessFlag -or $canReadBrightness)
            Min = $min
            Max = $max
            Current = $current
            BrightnessPercent = $percent
        }) | Out-Null
    }

    return $true
}

$null = [NativeMethods]::EnumDisplayMonitors([IntPtr]::Zero, [IntPtr]::Zero, $enumCallback, [IntPtr]::Zero)

try {
    if ($monitorInfo.Count -eq 0) {
        throw "No external monitors were discovered."
    }

    $friendlyNames = Get-WmiFriendlyMonitorNames
    for ($i = 0; $i -lt $monitorInfo.Count; $i++) {
        $monitor = $monitorInfo[$i]
        $monitor.Index = $i

        $friendly = $null
        if ($i -lt $friendlyNames.Count) {
            $friendly = $friendlyNames[$i]
        }

        $rawName = $monitor.RawName
        $displayName = $rawName
        if (-not [string]::IsNullOrWhiteSpace($friendly)) {
            $monitor.FriendlyName = $friendly
            if ($rawName -match "(?i)generic|pnp|p2p" -or $rawName -eq $friendly) {
                $displayName = $friendly
            }
            else {
                $displayName = "{0} ({1})" -f $friendly, $rawName
            }
        }

        $monitor.Name = $displayName
    }

    if ($Command -eq "list") {
        foreach ($monitor in $monitorInfo) {
            $status = if ($monitor.SupportsBrightness) { "brightness-control" } else { "no-brightness-control" }
            $valueText = if ($null -eq $monitor.BrightnessPercent) { "n/a" } else { "$($monitor.BrightnessPercent)%" }
            Write-Output ("#{0} {1} [{2}] current={3}" -f $monitor.Index, $monitor.Name, $status, $valueText)
        }
        return
    }

    $targets = $monitorInfo | Where-Object { $_.SupportsBrightness }
    if ($PSBoundParameters.ContainsKey("MonitorIndex")) {
        $targets = $targets | Where-Object { $_.Index -eq $MonitorIndex }
    }
    elseif (-not $All) {
        $escapedMonitorName = [System.Management.Automation.WildcardPattern]::Escape($MonitorName)
        $namePattern = "*{0}*" -f $escapedMonitorName
        $targets = $targets | Where-Object {
            $_.Name -like $namePattern -or
            $_.RawName -like $namePattern -or
            ($_.FriendlyName -and $_.FriendlyName -like $namePattern)
        }
    }

    if (-not $targets -or $targets.Count -eq 0) {
        $nameMessage = if ($PSBoundParameters.ContainsKey("MonitorIndex")) {
            "monitor index $MonitorIndex"
        }
        elseif ($All) {
            "any detected monitor"
        }
        else {
            "monitor name containing '$MonitorName'"
        }
        throw "No brightness-capable monitor matched $nameMessage. Run 'list' to inspect monitor names and indexes."
    }

    foreach ($target in $targets) {
        [uint32]$min = 0
        [uint32]$current = 0
        [uint32]$max = 0
        if (-not [NativeMethods]::GetMonitorBrightness($target.Handle, [ref]$min, [ref]$current, [ref]$max)) {
            Write-Warning "Could not read brightness for '$($target.Name)'."
            continue
        }

        $currentPercent = Convert-ToPercent -RawValue $current -MinValue $min -MaxValue $max

        switch ($Command) {
            "get" {
                Write-Output ("#{0} {1}: {2}%" -f $target.Index, $target.Name, $currentPercent)
            }
            "set" {
                $newRaw = Convert-ToRawBrightness -Percent $Value -MinValue $min -MaxValue $max
                if ([NativeMethods]::SetMonitorBrightness($target.Handle, $newRaw)) {
                    Write-Output ("#{0} {1}: {2}% -> {3}%" -f $target.Index, $target.Name, $currentPercent, $Value)
                } else {
                    Write-Warning "Failed to set brightness on '$($target.Name)'."
                }
            }
            "inc" {
                $newPercent = [Math]::Min(100, $currentPercent + $Value)
                $newRaw = Convert-ToRawBrightness -Percent $newPercent -MinValue $min -MaxValue $max
                if ([NativeMethods]::SetMonitorBrightness($target.Handle, $newRaw)) {
                    Write-Output ("#{0} {1}: {2}% -> {3}%" -f $target.Index, $target.Name, $currentPercent, $newPercent)
                } else {
                    Write-Warning "Failed to increase brightness on '$($target.Name)'."
                }
            }
            "dec" {
                $newPercent = [Math]::Max(0, $currentPercent - $Value)
                $newRaw = Convert-ToRawBrightness -Percent $newPercent -MinValue $min -MaxValue $max
                if ([NativeMethods]::SetMonitorBrightness($target.Handle, $newRaw)) {
                    Write-Output ("#{0} {1}: {2}% -> {3}%" -f $target.Index, $target.Name, $currentPercent, $newPercent)
                } else {
                    Write-Warning "Failed to decrease brightness on '$($target.Name)'."
                }
            }
            default {
                throw "Unsupported command '$Command'."
            }
        }
    }
}
finally {
    if ($physicalMonitors.Count -gt 0) {
        $allPhysical = $physicalMonitors.ToArray()
        [void][NativeMethods]::DestroyPhysicalMonitors([uint32]$allPhysical.Length, $allPhysical)
    }
}
