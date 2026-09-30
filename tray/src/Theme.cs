using System;
using System.Drawing;
using Microsoft.Win32;

namespace StudioDisplayBrightness
{
    // Colors approximating Windows 11 flyouts; follows the taskbar (system) theme and accent.
    internal sealed class Theme
    {
        public bool Dark;
        public Color Background;
        public Color Text;
        public Color SubtleText;
        public Color Rail;
        public Color Accent;
        public Color ThumbOuter;
        public Color ThumbBorder;

        public static Theme Current()
        {
            return Create(ReadDword(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "SystemUsesLightTheme", 0) == 0);
        }

        public static Theme Create(bool dark)
        {
            var theme = new Theme();
            theme.Dark = dark;
            if (dark)
            {
                theme.Background = Color.FromArgb(0x2C, 0x2C, 0x2C);
                theme.Text = Color.FromArgb(0xFF, 0xFF, 0xFF);
                theme.SubtleText = Color.FromArgb(0xC5, 0xC5, 0xC5);
                theme.Rail = Color.FromArgb(0x9A, 0x9A, 0x9A);
                theme.ThumbOuter = Color.FromArgb(0x45, 0x45, 0x45);
                theme.ThumbBorder = Color.FromArgb(0x50, 0x50, 0x50);
            }
            else
            {
                theme.Background = Color.FromArgb(0xF3, 0xF3, 0xF3);
                theme.Text = Color.FromArgb(0x1A, 0x1A, 0x1A);
                theme.SubtleText = Color.FromArgb(0x5D, 0x5D, 0x5D);
                theme.Rail = Color.FromArgb(0x86, 0x86, 0x86);
                theme.ThumbOuter = Color.FromArgb(0xFF, 0xFF, 0xFF);
                theme.ThumbBorder = Color.FromArgb(0xD6, 0xD6, 0xD6);
            }

            theme.Accent = ReadAccent(dark);
            return theme;
        }

        private static Color ReadAccent(bool dark)
        {
            // AccentPalette: 8 RGBA entries from lightest to darkest. Windows uses a lighter
            // shade for controls on dark surfaces and a darker one on light surfaces.
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Explorer\Accent"))
                {
                    var palette = key == null ? null : key.GetValue("AccentPalette") as byte[];
                    if (palette != null && palette.Length >= 32)
                    {
                        int i = (dark ? 1 : 4) * 4;
                        return Color.FromArgb(palette[i], palette[i + 1], palette[i + 2]);
                    }
                }
            }
            catch (Exception)
            {
            }

            return dark ? Color.FromArgb(0x4C, 0xC2, 0xFF) : Color.FromArgb(0x00, 0x67, 0xC0);
        }

        private static int ReadDword(string path, string name, int fallback)
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(path))
                {
                    object value = key == null ? null : key.GetValue(name);
                    return value is int ? (int)value : fallback;
                }
            }
            catch (Exception)
            {
                return fallback;
            }
        }
    }
}
