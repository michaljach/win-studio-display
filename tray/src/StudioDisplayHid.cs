using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace StudioDisplayBrightness
{
    internal sealed class HidEndpoint
    {
        public string Path;
        public string Serial;
        public string Product;
        public ushort ProductId;
        public int InterfaceNumber;
    }

    // Studio Display brightness over USB HID: report 1, 7 bytes
    // (report id + UInt32 little-endian brightness in 0.01 nit + 2 padding bytes), 400..60000.
    // Same protocol and endpoint selection as tools/studio-display-brightness.ps1.
    internal static class StudioDisplayHid
    {
        public const uint RawMin = 400;
        public const uint RawMax = 60000;

        private const ushort AppleVendorId = 0x05AC;
        private static readonly ushort[] PreferredProductIds = { 0x1114, 0x1115, 0x1116, 0x1117 };
        private static readonly int[] PreferredInterfaceNumbers = { 0x07, 0x0C };

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
        private static extern void HidD_GetHidGuid(out Guid hidGuid);

        [DllImport("hid.dll", SetLastError = true)]
        private static extern bool HidD_GetAttributes(SafeFileHandle device, ref HIDD_ATTRIBUTES attributes);

        [DllImport("hid.dll", SetLastError = true)]
        private static extern bool HidD_GetSerialNumberString(SafeFileHandle device, byte[] buffer, int bufferLength);

        [DllImport("hid.dll", SetLastError = true)]
        private static extern bool HidD_GetProductString(SafeFileHandle device, byte[] buffer, int bufferLength);

        [DllImport("hid.dll", SetLastError = true)]
        private static extern bool HidD_GetFeature(SafeFileHandle device, byte[] reportBuffer, int reportBufferLength);

        [DllImport("hid.dll", SetLastError = true)]
        private static extern bool HidD_SetFeature(SafeFileHandle device, byte[] reportBuffer, int reportBufferLength);

        [DllImport("setupapi.dll", SetLastError = true)]
        private static extern IntPtr SetupDiGetClassDevs(ref Guid classGuid, IntPtr enumerator, IntPtr hwndParent, uint flags);

        [DllImport("setupapi.dll", SetLastError = true)]
        private static extern bool SetupDiEnumDeviceInterfaces(IntPtr deviceInfoSet, IntPtr deviceInfoData, ref Guid interfaceClassGuid, uint memberIndex, ref SP_DEVICE_INTERFACE_DATA deviceInterfaceData);

        [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr deviceInfoSet, ref SP_DEVICE_INTERFACE_DATA deviceInterfaceData, ref SP_DEVICE_INTERFACE_DETAIL_DATA deviceInterfaceDetailData, uint deviceInterfaceDetailDataSize, out uint requiredSize, IntPtr deviceInfoData);

        [DllImport("setupapi.dll", SetLastError = true)]
        private static extern bool SetupDiDestroyDeviceInfoList(IntPtr deviceInfoSet);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern SafeFileHandle CreateFile(string fileName, uint desiredAccess, uint shareMode, IntPtr securityAttributes, uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

        public static int ToPercent(uint raw)
        {
            raw = Math.Max(RawMin, Math.Min(RawMax, raw));
            return (int)Math.Round((raw - RawMin) * 100.0 / (RawMax - RawMin));
        }

        public static uint ToRaw(int percent)
        {
            percent = Math.Max(0, Math.Min(100, percent));
            return (uint)Math.Round(RawMin + percent / 100.0 * (RawMax - RawMin));
        }

        // Apple HID endpoints that answer the brightness feature report, narrowed to
        // known Studio Display product/interface combinations when any are present.
        public static List<HidEndpoint> Enumerate()
        {
            var all = new List<HidEndpoint>();

            Guid hidGuid;
            HidD_GetHidGuid(out hidGuid);

            IntPtr set = SetupDiGetClassDevs(ref hidGuid, IntPtr.Zero, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
            if (set == IntPtr.Zero || set.ToInt64() == -1)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiGetClassDevs failed");
            }

            try
            {
                for (uint index = 0; ; index++)
                {
                    var interfaceData = new SP_DEVICE_INTERFACE_DATA();
                    interfaceData.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));
                    if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref hidGuid, index, ref interfaceData))
                    {
                        if (Marshal.GetLastWin32Error() == ERROR_NO_MORE_ITEMS)
                        {
                            break;
                        }

                        continue;
                    }

                    var detail = new SP_DEVICE_INTERFACE_DETAIL_DATA();
                    detail.cbSize = (uint)(IntPtr.Size == 8 ? 8 : 6);
                    uint required;
                    if (!SetupDiGetDeviceInterfaceDetail(set, ref interfaceData, ref detail, (uint)Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DETAIL_DATA)), out required, IntPtr.Zero))
                    {
                        continue;
                    }

                    HidEndpoint endpoint = Probe(detail.DevicePath);
                    if (endpoint != null)
                    {
                        all.Add(endpoint);
                    }
                }
            }
            finally
            {
                SetupDiDestroyDeviceInfoList(set);
            }

            var preferred = all.FindAll(e =>
                Array.IndexOf(PreferredProductIds, e.ProductId) >= 0 ||
                Array.IndexOf(PreferredInterfaceNumbers, e.InterfaceNumber) >= 0);
            return preferred.Count > 0 ? preferred : all;
        }

        private static HidEndpoint Probe(string path)
        {
            if (String.IsNullOrEmpty(path))
            {
                return null;
            }

            // Skip other vendors' USB devices without opening them.
            string lower = path.ToLowerInvariant();
            if (lower.Contains("vid_") && !lower.Contains("vid_05ac"))
            {
                return null;
            }

            using (SafeFileHandle handle = OpenBestEffort(path))
            {
                if (handle.IsInvalid)
                {
                    return null;
                }

                ushort vendorId;
                ushort productId;
                if (!TryGetDeviceIds(handle, lower, out vendorId, out productId) || vendorId != AppleVendorId)
                {
                    return null;
                }

                uint raw;
                if (!TryReadRaw(path, out raw))
                {
                    return null;
                }

                var endpoint = new HidEndpoint();
                endpoint.Path = path;
                endpoint.ProductId = productId;
                endpoint.InterfaceNumber = ExtractInterfaceNumber(lower);
                endpoint.Serial = ReadString(handle, HidD_GetSerialNumberString);
                endpoint.Product = ReadString(handle, HidD_GetProductString);
                return endpoint;
            }
        }

        public static bool TryReadRaw(string path, out uint raw)
        {
            foreach (bool readWrite in new[] { true, false })
            {
                using (SafeFileHandle handle = OpenPath(path, readWrite))
                {
                    if (handle.IsInvalid)
                    {
                        continue;
                    }

                    var report = new byte[REPORT_LENGTH];
                    report[0] = REPORT_ID;
                    if (HidD_GetFeature(handle, report, report.Length))
                    {
                        raw = BitConverter.ToUInt32(report, 1);
                        return true;
                    }
                }
            }

            raw = 0;
            return false;
        }

        public static void WriteRaw(string path, uint raw)
        {
            int lastError = 0;
            foreach (bool readWrite in new[] { true, false })
            {
                using (SafeFileHandle handle = OpenPath(path, readWrite))
                {
                    if (handle.IsInvalid)
                    {
                        lastError = Marshal.GetLastWin32Error();
                        continue;
                    }

                    var report = new byte[REPORT_LENGTH];
                    report[0] = REPORT_ID;
                    Buffer.BlockCopy(BitConverter.GetBytes(raw), 0, report, 1, 4);
                    if (HidD_SetFeature(handle, report, report.Length))
                    {
                        return;
                    }

                    lastError = Marshal.GetLastWin32Error();
                }
            }

            throw new Win32Exception(lastError, "HidD_SetFeature failed");
        }

        private delegate bool HidStringReader(SafeFileHandle device, byte[] buffer, int bufferLength);

        private static string ReadString(SafeFileHandle handle, HidStringReader reader)
        {
            var buffer = new byte[256];
            if (!reader(handle, buffer, buffer.Length))
            {
                return null;
            }

            string value = Encoding.Unicode.GetString(buffer);
            int terminator = value.IndexOf('\0');
            if (terminator >= 0)
            {
                value = value.Substring(0, terminator);
            }

            value = value.Trim();
            return value.Length == 0 ? null : value;
        }

        private static bool TryGetDeviceIds(SafeFileHandle handle, string lowerPath, out ushort vendorId, out ushort productId)
        {
            var attributes = new HIDD_ATTRIBUTES();
            attributes.Size = Marshal.SizeOf(typeof(HIDD_ATTRIBUTES));
            if (HidD_GetAttributes(handle, ref attributes))
            {
                vendorId = attributes.VendorID;
                productId = attributes.ProductID;
                return true;
            }

            productId = 0;
            return TryParseHexToken(lowerPath, "vid_", out vendorId) && TryParseHexToken(lowerPath, "pid_", out productId);
        }

        private static bool TryParseHexToken(string lower, string marker, out ushort value)
        {
            value = 0;
            int index = lower.IndexOf(marker, StringComparison.Ordinal);
            if (index < 0 || index + marker.Length + 4 > lower.Length)
            {
                return false;
            }

            return UInt16.TryParse(lower.Substring(index + marker.Length, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out value);
        }

        private static int ExtractInterfaceNumber(string lower)
        {
            int marker = lower.IndexOf("&mi_", StringComparison.Ordinal);
            int parsed;
            if (marker < 0 || marker + 6 > lower.Length ||
                !Int32.TryParse(lower.Substring(marker + 4, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out parsed))
            {
                return -1;
            }

            return parsed;
        }

        private static SafeFileHandle OpenBestEffort(string path)
        {
            SafeFileHandle handle = OpenPath(path, true);
            if (!handle.IsInvalid)
            {
                return handle;
            }

            handle.Dispose();
            return OpenPath(path, false);
        }

        private static SafeFileHandle OpenPath(string path, bool readWrite)
        {
            uint access = readWrite ? (GENERIC_READ | GENERIC_WRITE) : 0;
            return CreateFile(path, access, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        }
    }
}
