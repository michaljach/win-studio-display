using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

namespace StudioDisplayBrightness
{
    internal sealed class Hotkey
    {
        public readonly uint Modifiers;
        public readonly Keys Key;
        public readonly string Text;

        private Hotkey(uint modifiers, Keys key, string text)
        {
            Modifiers = modifiers;
            Key = key;
            Text = text;
        }

        // "Ctrl+Alt+PageUp", "Win+Shift+F2", ... Empty means no hotkey.
        public static bool TryParse(string text, out Hotkey hotkey)
        {
            hotkey = null;
            if (String.IsNullOrWhiteSpace(text))
            {
                return true;
            }

            uint modifiers = 0;
            Keys key = Keys.None;
            foreach (string rawPart in text.Split('+'))
            {
                string part = rawPart.Trim();
                switch (part.ToLowerInvariant())
                {
                    case "ctrl":
                    case "control":
                        modifiers |= Native.MOD_CONTROL;
                        break;
                    case "alt":
                        modifiers |= Native.MOD_ALT;
                        break;
                    case "shift":
                        modifiers |= Native.MOD_SHIFT;
                        break;
                    case "win":
                        modifiers |= Native.MOD_WIN;
                        break;
                    default:
                        Keys parsed;
                        if (key != Keys.None || !Enum.TryParse(part, true, out parsed) || (parsed & Keys.Modifiers) != 0)
                        {
                            return false;
                        }

                        key = parsed;
                        break;
                }
            }

            if (key == Keys.None)
            {
                return false;
            }

            hotkey = new Hotkey(modifiers, key, text.Trim());
            return true;
        }
    }

    // User-editable options in %APPDATA%\StudioDisplayBrightness\settings.ini.
    internal sealed class Settings
    {
        public static readonly string FilePath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "StudioDisplayBrightness", "settings.ini");

        private const string DefaultHotkeyUp = "Ctrl+Alt+PageUp";
        private const string DefaultHotkeyDown = "Ctrl+Alt+PageDown";

        public int Step = 5;
        public string HotkeyUp = DefaultHotkeyUp;
        public string HotkeyDown = DefaultHotkeyDown;
        public bool RestoreOnConnect = true;

        public static Settings Load()
        {
            var settings = new Settings();
            if (!File.Exists(FilePath))
            {
                settings.Save();
                return settings;
            }

            var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (string rawLine in File.ReadAllLines(FilePath))
            {
                string line = rawLine.Trim();
                int equals = line.IndexOf('=');
                if (line.Length == 0 || line[0] == '#' || line[0] == ';' || equals <= 0)
                {
                    continue;
                }

                values[line.Substring(0, equals).Trim()] = line.Substring(equals + 1).Trim();
            }

            string value;
            int step;
            if (values.TryGetValue("Step", out value) && Int32.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out step))
            {
                settings.Step = Math.Max(1, Math.Min(50, step));
            }

            if (values.TryGetValue("HotkeyUp", out value))
            {
                settings.HotkeyUp = value;
            }

            if (values.TryGetValue("HotkeyDown", out value))
            {
                settings.HotkeyDown = value;
            }

            bool restore;
            if (values.TryGetValue("RestoreOnConnect", out value) && Boolean.TryParse(value, out restore))
            {
                settings.RestoreOnConnect = restore;
            }

            return settings;
        }

        public void Save()
        {
            var text = new StringBuilder();
            text.AppendLine("# Studio Display Brightness settings. Changes apply as soon as the file is saved.");
            text.AppendLine();
            text.AppendLine("# Brightness change per hotkey press, in percent (1-50).");
            text.AppendLine("Step=" + Step.ToString(CultureInfo.InvariantCulture));
            text.AppendLine();
            text.AppendLine("# Global hotkeys: modifiers Ctrl, Alt, Shift, Win plus a key name such as PageUp, Up, F2, Oemplus.");
            text.AppendLine("# Leave empty to disable. Defaults: " + DefaultHotkeyUp + " / " + DefaultHotkeyDown);
            text.AppendLine("HotkeyUp=" + HotkeyUp);
            text.AppendLine("HotkeyDown=" + HotkeyDown);
            text.AppendLine();
            text.AppendLine("# Re-apply the last brightness when a display connects or the app starts (true/false).");
            text.AppendLine("RestoreOnConnect=" + (RestoreOnConnect ? "true" : "false"));

            Directory.CreateDirectory(Path.GetDirectoryName(FilePath));
            string temp = FilePath + ".tmp";
            File.WriteAllText(temp, text.ToString(), new UTF8Encoding(false));
            if (File.Exists(FilePath))
            {
                File.Replace(temp, FilePath, null);
            }
            else
            {
                File.Move(temp, FilePath);
            }
        }
    }

    // Last brightness per display (keyed by serial) and the autostart entry, in HKCU.
    internal static class UserState
    {
        private const string BrightnessKey = @"Software\StudioDisplayBrightness\Brightness";
        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string RunValue = "StudioDisplayBrightness";

        public static int? GetBrightness(string displayKey)
        {
            using (RegistryKey key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(BrightnessKey))
            {
                object value = key == null ? null : key.GetValue(displayKey);
                if (value is int)
                {
                    return Math.Max(0, Math.Min(100, (int)value));
                }

                return null;
            }
        }

        public static void SetBrightness(string displayKey, int percent)
        {
            using (RegistryKey key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(BrightnessKey))
            {
                key.SetValue(displayKey, percent, RegistryValueKind.DWord);
            }
        }

        public static bool StartsWithWindows
        {
            get
            {
                using (RegistryKey key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey))
                {
                    string value = key == null ? null : key.GetValue(RunValue) as string;
                    return value != null && value.Trim('"').Equals(Application.ExecutablePath, StringComparison.OrdinalIgnoreCase);
                }
            }

            set
            {
                using (RegistryKey key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(RunKey))
                {
                    if (value)
                    {
                        key.SetValue(RunValue, "\"" + Application.ExecutablePath + "\"");
                    }
                    else
                    {
                        key.DeleteValue(RunValue, false);
                    }
                }
            }
        }
    }
}
