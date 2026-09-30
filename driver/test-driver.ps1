<#
.SYNOPSIS
    Talks to the StudioDisplayBrightness driver the same way Windows'
    Display Enhancement Service does (run as Administrator).

.EXAMPLE
    .\test-driver.ps1              # list brightness interfaces and current level
.EXAMPLE
    .\test-driver.ps1 -Nits 200    # set 200 nits
.EXAMPLE
    .\test-driver.ps1 -Percent 40  # set 40 % (power-policy style request)
#>
[CmdletBinding(DefaultParameterSetName = "Get")]
param(
    [Parameter(ParameterSetName = "Nits")]
    [ValidateRange(1, 10000)]
    [int]$Nits,

    [Parameter(ParameterSetName = "Nits")]
    [ValidateRange(0, 20000)]
    [int]$TransitionMs = 0,

    [Parameter(ParameterSetName = "Percent")]
    [ValidateRange(0, 100)]
    [int]$Percent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class SdbTest
{
    public static readonly Guid Interface = new Guid("db524086-ba90-4e1e-be42-894e94ecf289");
    const uint IOCTL_SET = 0x234004, IOCTL_GET = 0x234008, IOCTL_POLICY = 0x234010;

    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVICE_INTERFACE_DATA { public uint cbSize; public Guid g; public uint Flags; public IntPtr Reserved; }

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr e, IntPtr w, uint f);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiEnumDeviceInterfaces(IntPtr s, IntPtr d, ref Guid g, uint i, ref SP_DEVICE_INTERFACE_DATA di);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr s, ref SP_DEVICE_INTERFACE_DATA di, IntPtr dd, uint size, out uint required, IntPtr d);
    [DllImport("setupapi.dll")]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr s);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] inBuf, int inLen, byte[] outBuf, int outLen, out int returned, IntPtr overlapped);

    public static List<string> List()
    {
        var paths = new List<string>();
        Guid g = Interface;
        IntPtr set = SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, 0x12);
        try {
            for (uint i = 0; ; i++) {
                var di = new SP_DEVICE_INTERFACE_DATA();
                di.cbSize = (uint)Marshal.SizeOf(di);
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, i, ref di)) break;
                uint required;
                SetupDiGetDeviceInterfaceDetail(set, ref di, IntPtr.Zero, 0, out required, IntPtr.Zero);
                IntPtr buffer = Marshal.AllocHGlobal((int)required);
                try {
                    Marshal.WriteInt32(buffer, 8);
                    if (SetupDiGetDeviceInterfaceDetail(set, ref di, buffer, required, out required, IntPtr.Zero))
                        paths.Add(Marshal.PtrToStringUni(buffer + 4));
                } finally { Marshal.FreeHGlobal(buffer); }
            }
        } finally { SetupDiDestroyDeviceInfoList(set); }
        return paths;
    }

    static SafeFileHandle Open(string path)
    {
        var h = CreateFile(path, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "open " + path);
        return h;
    }

    static void Ioctl(SafeFileHandle h, uint code, byte[] input, byte[] output)
    {
        int returned;
        if (!DeviceIoControl(h, code, input, input == null ? 0 : input.Length, output, output == null ? 0 : output.Length, out returned, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error(), String.Format("IOCTL 0x{0:X}", code));
    }

    // Returns { version, current, target }.
    public static uint[] Get(string path)
    {
        using (var h = Open(path)) {
            var output = new byte[16];
            Ioctl(h, IOCTL_GET, null, output);
            return new uint[] { BitConverter.ToUInt32(output, 0), BitConverter.ToUInt32(output, 4), BitConverter.ToUInt32(output, 8) };
        }
    }

    public static void SetMillinits(string path, uint millinits, uint transitionMs)
    {
        using (var h = Open(path)) {
            var input = new byte[0x24];
            BitConverter.GetBytes(3u).CopyTo(input, 0);
            BitConverter.GetBytes(millinits).CopyTo(input, 4);
            BitConverter.GetBytes(transitionMs).CopyTo(input, 8);
            Ioctl(h, IOCTL_SET, input, null);
        }
    }

    public static void SetPercent(string path, byte percent)
    {
        using (var h = Open(path)) {
            Ioctl(h, IOCTL_POLICY, new byte[] { percent, percent }, null);
        }
    }
}
"@

$paths = [SdbTest]::List()
if ($paths.Count -eq 0) {
    Write-Host "No enabled brightness interface found."
    Write-Host "Check that the driver is installed and the display's USB connection is attached."
    return
}

foreach ($path in $paths) {
    Write-Host $path
    switch ($PSCmdlet.ParameterSetName) {
        "Nits" { [SdbTest]::SetMillinits($path, [uint32]($Nits * 1000), [uint32]$TransitionMs) }
        "Percent" { [SdbTest]::SetPercent($path, [byte]$Percent) }
    }
    if ($PSCmdlet.ParameterSetName -ne "Get" -and $TransitionMs -gt 0) {
        Start-Sleep -Milliseconds $TransitionMs
    }
    $state = [SdbTest]::Get($path)
    Write-Host ("  version={0} current={1:N1} nits target={2:N1} nits" -f $state[0], ($state[1] / 1000.0), ($state[2] / 1000.0))
}
