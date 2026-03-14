param(
    [Parameter(Position = 0)]
    [ValidateSet("list", "get", "set", "inc", "dec")]
    [string]$Command = "get",

    [Parameter(Position = 1)]
    [int]$Value,

    [string]$Serial
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

$nativeCode = @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using System.Text;

public class StudioDisplayDevice
{
    public string Path { get; set; }
    public string Serial { get; set; }
    public ushort ProductId { get; set; }
    public int InterfaceNumber { get; set; }
    public uint? BrightnessRaw { get; set; }
}

public static class StudioDisplayHid
{
    private const int ERROR_NO_MORE_ITEMS = 259;
    private const uint DIGCF_PRESENT = 0x2;
    private const uint DIGCF_DEVICEINTERFACE = 0x10;
    private const uint GENERIC_READ = 0x80000000;
    private const uint GENERIC_WRITE = 0x40000000;
    private const uint FILE_SHARE_READ = 0x1;
    private const uint FILE_SHARE_WRITE = 0x2;
    private const uint OPEN_EXISTING = 3;

    private const byte REPORT_ID = 1;
    private const int REPORT_LENGTH = 7;

    [StructLayout(LayoutKind.Sequential)]
    private struct SP_DEVICE_INTERFACE_DATA
    {
        public uint cbSize;
        public Guid InterfaceClassGuid;
        public uint Flags;
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SP_DEVICE_INTERFACE_DETAIL_DATA
    {
        public uint cbSize;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 1024)]
        public string DevicePath;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HIDD_ATTRIBUTES
    {
        public int Size;
        public ushort VendorID;
        public ushort ProductID;
        public ushort VersionNumber;
    }

    [DllImport("hid.dll")]
    private static extern void HidD_GetHidGuid(out Guid HidGuid);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_GetAttributes(SafeFileHandle HidDeviceObject, ref HIDD_ATTRIBUTES Attributes);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_GetSerialNumberString(SafeFileHandle HidDeviceObject, byte[] Buffer, int BufferLength);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_GetManufacturerString(SafeFileHandle HidDeviceObject, byte[] Buffer, int BufferLength);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_GetProductString(SafeFileHandle HidDeviceObject, byte[] Buffer, int BufferLength);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_GetFeature(SafeFileHandle HidDeviceObject, byte[] ReportBuffer, int ReportBufferLength);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_SetFeature(SafeFileHandle HidDeviceObject, byte[] ReportBuffer, int ReportBufferLength);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern IntPtr SetupDiGetClassDevs(
        ref Guid ClassGuid,
        IntPtr Enumerator,
        IntPtr hwndParent,
        uint Flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiEnumDeviceInterfaces(
        IntPtr DeviceInfoSet,
        IntPtr DeviceInfoData,
        ref Guid InterfaceClassGuid,
        uint MemberIndex,
        ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData);

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool SetupDiGetDeviceInterfaceDetail(
        IntPtr DeviceInfoSet,
        ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData,
        IntPtr DeviceInterfaceDetailData,
        uint DeviceInterfaceDetailDataSize,
        out uint RequiredSize,
        IntPtr DeviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool SetupDiGetDeviceInterfaceDetail(
        IntPtr DeviceInfoSet,
        ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData,
        ref SP_DEVICE_INTERFACE_DETAIL_DATA DeviceInterfaceDetailData,
        uint DeviceInterfaceDetailDataSize,
        out uint RequiredSize,
        IntPtr DeviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafeFileHandle CreateFile(
        string lpFileName,
        uint dwDesiredAccess,
        uint dwShareMode,
        IntPtr lpSecurityAttributes,
        uint dwCreationDisposition,
        uint dwFlagsAndAttributes,
        IntPtr hTemplateFile);

    public static List<StudioDisplayDevice> Enumerate(ushort vendorId)
    {
        var devices = new List<StudioDisplayDevice>();

        Guid hidGuid;
        HidD_GetHidGuid(out hidGuid);

        IntPtr deviceInfoSet = SetupDiGetClassDevs(ref hidGuid, IntPtr.Zero, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (deviceInfoSet == IntPtr.Zero || deviceInfoSet.ToInt64() == -1)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiGetClassDevs failed");
        }

        try
        {
            uint index = 0;
            while (true)
            {
                var interfaceData = new SP_DEVICE_INTERFACE_DATA();
                interfaceData.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));

                bool enumOk = SetupDiEnumDeviceInterfaces(deviceInfoSet, IntPtr.Zero, ref hidGuid, index, ref interfaceData);
                if (!enumOk)
                {
                    int err = Marshal.GetLastWin32Error();
                    if (err == ERROR_NO_MORE_ITEMS)
                    {
                        break;
                    }

                    index++;
                    continue;
                }

                uint requiredSize = 0;
                SetupDiGetDeviceInterfaceDetail(deviceInfoSet, ref interfaceData, IntPtr.Zero, 0, out requiredSize, IntPtr.Zero);

                var detailData = new SP_DEVICE_INTERFACE_DETAIL_DATA();
                detailData.cbSize = (uint)(IntPtr.Size == 8 ? 8 : 6);

                bool detailOk = SetupDiGetDeviceInterfaceDetail(deviceInfoSet, ref interfaceData, ref detailData, requiredSize, out requiredSize, IntPtr.Zero);
                if (!detailOk)
                {
                    index++;
                    continue;
                }

                string path = detailData.DevicePath;
                if (String.IsNullOrWhiteSpace(path))
                {
                    index++;
                    continue;
                }

                using (SafeFileHandle handle = OpenBestEffort(path))
                {
                    if (handle.IsInvalid)
                    {
                        index++;
                        continue;
                    }

                    ushort deviceVendorId;
                    ushort deviceProductId;
                    if (!TryGetDeviceIds(handle, path, out deviceVendorId, out deviceProductId))
                    {
                        index++;
                        continue;
                    }

                    if (deviceVendorId != vendorId)
                    {
                        index++;
                        continue;
                    }

                    string serial = ReadSerial(handle);
                    int interfaceNumber = ExtractInterfaceNumber(path);
                    uint? brightnessRaw = ProbeBrightness(path);

                    devices.Add(new StudioDisplayDevice
                    {
                        Path = path,
                        Serial = serial,
                        ProductId = deviceProductId,
                        InterfaceNumber = interfaceNumber,
                        BrightnessRaw = brightnessRaw
                    });
                }

                index++;
            }
        }
        finally
        {
            SetupDiDestroyDeviceInfoList(deviceInfoSet);
        }

        return devices;
    }

    public static uint ReadBrightnessRaw(string path)
    {
        uint value;

        using (SafeFileHandle handle = OpenPath(path, true))
        {
            if (!handle.IsInvalid && TryReadBrightness(handle, out value))
            {
                return value;
            }
        }

        using (SafeFileHandle handle = OpenPath(path, false))
        {
            if (!handle.IsInvalid && TryReadBrightness(handle, out value))
            {
                return value;
            }
        }

        throw new InvalidOperationException("Could not read brightness feature report.");
    }

    public static void WriteBrightnessRaw(string path, uint rawBrightness)
    {
        int lastError = 0;

        using (SafeFileHandle handle = OpenPath(path, true))
        {
            if (!handle.IsInvalid && TryWriteBrightness(handle, rawBrightness, out lastError))
            {
                return;
            }
        }

        using (SafeFileHandle handle = OpenPath(path, false))
        {
            if (!handle.IsInvalid && TryWriteBrightness(handle, rawBrightness, out lastError))
            {
                return;
            }
        }

        if (lastError != 0)
        {
            throw new Win32Exception(lastError, "HidD_SetFeature failed");
        }

        throw new InvalidOperationException("Could not write brightness feature report.");
    }

    private static bool TryWriteBrightness(SafeFileHandle handle, uint rawBrightness, out int lastError)
    {
        var report = new byte[REPORT_LENGTH];
        report[0] = REPORT_ID;
        var rawBytes = BitConverter.GetBytes(rawBrightness);
        Buffer.BlockCopy(rawBytes, 0, report, 1, 4);

        if (HidD_SetFeature(handle, report, report.Length))
        {
            lastError = 0;
            return true;
        }

        lastError = Marshal.GetLastWin32Error();
        return false;
    }

    private static uint? ProbeBrightness(string path)
    {
        uint value;

        using (SafeFileHandle handle = OpenPath(path, true))
        {
            if (!handle.IsInvalid && TryReadBrightness(handle, out value))
            {
                return value;
            }
        }

        using (SafeFileHandle handle = OpenPath(path, false))
        {
            if (!handle.IsInvalid && TryReadBrightness(handle, out value))
            {
                return value;
            }
        }

        return null;
    }

    private static bool TryGetDeviceIds(SafeFileHandle handle, string path, out ushort vendorId, out ushort productId)
    {
        var attributes = new HIDD_ATTRIBUTES();
        attributes.Size = Marshal.SizeOf(typeof(HIDD_ATTRIBUTES));

        if (HidD_GetAttributes(handle, ref attributes))
        {
            vendorId = attributes.VendorID;
            productId = attributes.ProductID;
            return true;
        }

        return TryExtractVidPidFromPath(path, out vendorId, out productId);
    }

    private static bool TryExtractVidPidFromPath(string path, out ushort vendorId, out ushort productId)
    {
        vendorId = 0;
        productId = 0;

        if (String.IsNullOrWhiteSpace(path))
        {
            return false;
        }

        string lower = path.ToLowerInvariant();
        ushort vid;
        ushort pid;
        if (!TryExtractHexToken(lower, "vid_", out vid))
        {
            return false;
        }

        if (!TryExtractHexToken(lower, "pid_", out pid))
        {
            return false;
        }

        vendorId = vid;
        productId = pid;
        return true;
    }

    private static bool TryExtractHexToken(string lower, string marker, out ushort value)
    {
        value = 0;
        int index = lower.IndexOf(marker, StringComparison.Ordinal);
        if (index < 0 || index + marker.Length + 4 > lower.Length)
        {
            return false;
        }

        string hex = lower.Substring(index + marker.Length, 4);
        ushort parsed;
        if (!UInt16.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out parsed))
        {
            return false;
        }

        value = parsed;
        return true;
    }

    private static SafeFileHandle OpenBestEffort(string path)
    {
        var readWriteHandle = OpenPath(path, true);
        if (!readWriteHandle.IsInvalid)
        {
            return readWriteHandle;
        }

        readWriteHandle.Dispose();

        return OpenPath(path, false);
    }

    private static string DecodeRawString(byte[] raw)
    {
        if (raw == null || raw.Length == 0)
        {
            return null;
        }

        string value = Encoding.Unicode.GetString(raw);
        int nullTerminator = value.IndexOf('\0');
        if (nullTerminator >= 0)
        {
            value = value.Substring(0, nullTerminator);
        }

        value = value.Trim();
        if (value.Length == 0)
        {
            return null;
        }

        return value;
    }

    private static string ReadManufacturerString(SafeFileHandle handle)
    {
        var buffer = new byte[256];
        if (!HidD_GetManufacturerString(handle, buffer, buffer.Length))
        {
            return null;
        }

        return DecodeRawString(buffer);
    }

    private static string ReadProductString(SafeFileHandle handle)
    {
        var buffer = new byte[256];
        if (!HidD_GetProductString(handle, buffer, buffer.Length))
        {
            return null;
        }

        return DecodeRawString(buffer);
    }

    private static SafeFileHandle OpenPath(string path, bool readWrite)
    {
        uint access = readWrite ? (GENERIC_READ | GENERIC_WRITE) : 0;
        return CreateFile(path, access, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
    }

    private static string ReadSerial(SafeFileHandle handle)
    {
        var serialBuffer = new byte[256];
        if (!HidD_GetSerialNumberString(handle, serialBuffer, serialBuffer.Length))
        {
            string manufacturer = ReadManufacturerString(handle);
            string product = ReadProductString(handle);
            if (manufacturer == null && product == null)
            {
                return null;
            }

            if (manufacturer != null && product != null)
            {
                return manufacturer + " " + product;
            }

            return manufacturer ?? product;
        }

        return DecodeRawString(serialBuffer);
    }

    private static bool TryReadBrightness(SafeFileHandle handle, out uint brightness)
    {
        var report = new byte[REPORT_LENGTH];
        report[0] = REPORT_ID;

        if (!HidD_GetFeature(handle, report, report.Length))
        {
            brightness = 0;
            return false;
        }

        brightness = BitConverter.ToUInt32(report, 1);
        return true;
    }

    private static int ExtractInterfaceNumber(string path)
    {
        if (String.IsNullOrWhiteSpace(path))
        {
            return -1;
        }

        string lower = path.ToLowerInvariant();
        int marker = lower.IndexOf("&mi_", StringComparison.Ordinal);
        if (marker < 0 || marker + 6 > lower.Length)
        {
            return -1;
        }

        string hexPart = lower.Substring(marker + 4, 2);
        int parsed;
        if (!Int32.TryParse(hexPart, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out parsed))
        {
            return -1;
        }

        return parsed;
    }
}
"@

if (-not ("StudioDisplayDevice" -as [type]) -or -not ("StudioDisplayHid" -as [type])) {
    Add-Type -TypeDefinition $nativeCode -Language CSharp
}

$VendorId = 0x05AC
$PreferredProductIds = @(0x1114, 0x1115, 0x1116, 0x1117)
$PreferredInterfaceNumbers = @(0x07, 0x0C)
$MinBrightnessRaw = 400
$MaxBrightnessRaw = 60000

function Convert-ToPercent {
    param([uint32]$Raw)

    if ($Raw -lt $MinBrightnessRaw) { $Raw = $MinBrightnessRaw }
    if ($Raw -gt $MaxBrightnessRaw) { $Raw = $MaxBrightnessRaw }

    $span = $MaxBrightnessRaw - $MinBrightnessRaw
    if ($span -le 0) {
        return 0
    }

    return [int][Math]::Round((($Raw - $MinBrightnessRaw) * 100.0) / $span)
}

function Convert-ToRaw {
    param([int]$Percent)

    $clamped = [Math]::Max(0, [Math]::Min(100, $Percent))
    $span = $MaxBrightnessRaw - $MinBrightnessRaw
    return [uint32][Math]::Round($MinBrightnessRaw + (($clamped / 100.0) * $span))
}

function Get-StudioDisplays {
    $allAppleHidDevices = [StudioDisplayHid]::Enumerate([uint16]$VendorId)
    if (-not $allAppleHidDevices -or $allAppleHidDevices.Count -eq 0) {
        throw "No Apple HID devices found (VID_05AC)."
    }

    $brightnessDevices = @($allAppleHidDevices | Where-Object { $null -ne $_.BrightnessRaw })
    if ($brightnessDevices.Count -eq 0) {
        $discovered = $allAppleHidDevices | ForEach-Object {
            $serialText = if ([string]::IsNullOrWhiteSpace($_.Serial)) { "unknown" } else { $_.Serial }
            $miText = if ($_.InterfaceNumber -lt 0) { "unknown" } else { ("0x{0:X2}" -f [int]$_.InterfaceNumber) }
            "PID=0x{0:X4}, MI={1}, serial={2}" -f [int]$_.ProductId, $miText, $serialText
        }
        $joined = ($discovered -join "; ")
        throw "Found Apple HID devices but none accepted brightness report id 1. Devices: $joined"
    }

    $preferredDevices = @($brightnessDevices | Where-Object {
        ($PreferredProductIds -contains [int]$_.ProductId) -or
        ($PreferredInterfaceNumbers -contains [int]$_.InterfaceNumber)
    })
    $devices = if ($preferredDevices.Count -gt 0) { $preferredDevices } else { $brightnessDevices }

    if ([string]::IsNullOrWhiteSpace($Serial)) {
        return $devices
    }

    $matched = $devices | Where-Object { $_.Serial -and $_.Serial -eq $Serial }
    if (-not $matched -or $matched.Count -eq 0) {
        throw "No Studio Display matched serial '$Serial'."
    }

    return $matched
}

$targets = Get-StudioDisplays

if ($Command -eq "list") {
    $index = 0
    foreach ($device in $targets) {
        $serialText = if ([string]::IsNullOrWhiteSpace($device.Serial)) { "unknown" } else { $device.Serial }
        $pidText = "0x{0:X4}" -f [int]$device.ProductId
        $miText = if ($device.InterfaceNumber -lt 0) { "unknown" } else { "0x{0:X2}" -f [int]$device.InterfaceNumber }
        $brightnessText = if ($null -eq $device.BrightnessRaw) { "unknown" } else { "$(Convert-ToPercent -Raw $device.BrightnessRaw)%" }
        Write-Output ("#{0} serial={1} pid={2} mi={3} brightness={4}" -f $index, $serialText, $pidText, $miText, $brightnessText)
        $index++
    }
    return
}

foreach ($device in $targets) {
    $serialText = if ([string]::IsNullOrWhiteSpace($device.Serial)) { "unknown" } else { $device.Serial }
    $currentRaw = [StudioDisplayHid]::ReadBrightnessRaw($device.Path)
    $currentPercent = Convert-ToPercent -Raw $currentRaw

    switch ($Command) {
        "get" {
            Write-Output ("serial={0} brightness={1}%" -f $serialText, $currentPercent)
        }
        "set" {
            $targetPercent = $Value
            $targetRaw = Convert-ToRaw -Percent $targetPercent
            [StudioDisplayHid]::WriteBrightnessRaw($device.Path, $targetRaw)
            $newPercent = Convert-ToPercent -Raw ([StudioDisplayHid]::ReadBrightnessRaw($device.Path))
            Write-Output ("serial={0} brightness={1}% -> {2}%" -f $serialText, $currentPercent, $newPercent)
        }
        "inc" {
            $targetPercent = [Math]::Min(100, $currentPercent + $Value)
            $targetRaw = Convert-ToRaw -Percent $targetPercent
            [StudioDisplayHid]::WriteBrightnessRaw($device.Path, $targetRaw)
            $newPercent = Convert-ToPercent -Raw ([StudioDisplayHid]::ReadBrightnessRaw($device.Path))
            Write-Output ("serial={0} brightness={1}% -> {2}%" -f $serialText, $currentPercent, $newPercent)
        }
        "dec" {
            $targetPercent = [Math]::Max(0, $currentPercent - $Value)
            $targetRaw = Convert-ToRaw -Percent $targetPercent
            [StudioDisplayHid]::WriteBrightnessRaw($device.Path, $targetRaw)
            $newPercent = Convert-ToPercent -Raw ([StudioDisplayHid]::ReadBrightnessRaw($device.Path))
            Write-Output ("serial={0} brightness={1}% -> {2}%" -f $serialText, $currentPercent, $newPercent)
        }
        default {
            throw "Unsupported command '$Command'."
        }
    }
}
