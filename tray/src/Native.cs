using System;
using System.Runtime.InteropServices;

namespace StudioDisplayBrightness
{
    internal static class Native
    {
        public const int WM_SETTINGCHANGE = 0x001A;
        public const int WM_DISPLAYCHANGE = 0x007E;
        public const int WM_DEVICECHANGE = 0x0219;
        public const int WM_HOTKEY = 0x0312;
        public const int WM_DPICHANGED = 0x02E0;
        public const int DBT_DEVNODES_CHANGED = 0x0007;

        public const uint MOD_ALT = 0x1;
        public const uint MOD_CONTROL = 0x2;
        public const uint MOD_SHIFT = 0x4;
        public const uint MOD_WIN = 0x8;

        public const int WS_EX_TOPMOST = 0x00000008;
        public const int WS_EX_TRANSPARENT = 0x00000020;
        public const int WS_EX_TOOLWINDOW = 0x00000080;
        public const int WS_EX_NOACTIVATE = 0x08000000;
        public const int CS_DROPSHADOW = 0x00020000;

        public const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
        public const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
        public const int DWMWCP_ROUND = 2;
        public const int DWMWCP_ROUNDSMALL = 3;

        public const uint MONITOR_DEFAULTTONEAREST = 2;
        public const uint MONITOR_DEFAULTTOPRIMARY = 1;
        public const int MDT_EFFECTIVE_DPI = 0;

        public static readonly IntPtr HWND_BROADCAST = new IntPtr(0xFFFF);
        public const int ASFW_ANY = -1;

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT
        {
            public int X;
            public int Y;

            public POINT(int x, int y)
            {
                X = x;
                Y = y;
            }
        }

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

        [DllImport("user32.dll")]
        public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern uint RegisterWindowMessage(string lpString);

        [DllImport("user32.dll")]
        public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool AllowSetForegroundWindow(int dwProcessId);

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool DestroyIcon(IntPtr hIcon);

        [DllImport("user32.dll")]
        public static extern IntPtr MonitorFromPoint(POINT pt, uint dwFlags);

        [DllImport("shcore.dll")]
        public static extern int GetDpiForMonitor(IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY);

        [DllImport("dwmapi.dll")]
        public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

        public static float ScaleForPoint(System.Drawing.Point point)
        {
            return ScaleForMonitor(MonitorFromPoint(new POINT(point.X, point.Y), MONITOR_DEFAULTTONEAREST));
        }

        public static float PrimaryScale()
        {
            return ScaleForMonitor(MonitorFromPoint(new POINT(0, 0), MONITOR_DEFAULTTOPRIMARY));
        }

        private static float ScaleForMonitor(IntPtr monitor)
        {
            uint dpiX;
            uint dpiY;
            try
            {
                if (monitor != IntPtr.Zero && GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, out dpiX, out dpiY) == 0 && dpiX > 0)
                {
                    return dpiX / 96f;
                }
            }
            catch (DllNotFoundException)
            {
            }
            catch (EntryPointNotFoundException)
            {
            }

            return 1f;
        }

        public static void ApplyWindowFrame(IntPtr hwnd, bool dark, bool smallCorners)
        {
            // Both attributes are ignored (non-zero HRESULT) on Windows 10; that's fine.
            int corner = smallCorners ? DWMWCP_ROUNDSMALL : DWMWCP_ROUND;
            DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref corner, sizeof(int));
            int darkValue = dark ? 1 : 0;
            DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref darkValue, sizeof(int));
        }
    }
}
