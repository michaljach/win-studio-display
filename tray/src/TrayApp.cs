using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace StudioDisplayBrightness
{
    internal sealed class TrayApp : ApplicationContext
    {
        public static readonly uint ShowFlyoutMessage = Native.RegisterWindowMessage("StudioDisplayBrightness.ShowFlyout");

        private const int HotkeyUpId = 1;
        private const int HotkeyDownId = 2;
        private static readonly TimeSpan UserChangeGrace = TimeSpan.FromMilliseconds(1500);

        private readonly SynchronizationContext ui;
        private readonly MessageWindow messages;
        private readonly NotifyIcon tray;
        private readonly ToolStripMenuItem startWithWindowsItem;
        private readonly ToolStripMenuItem restoreItem;
        private readonly DisplayService service;
        private readonly Flyout flyout;
        private readonly Osd osd;
        private readonly FileSystemWatcher settingsWatcher;
        private readonly System.Windows.Forms.Timer rescanTimer = new System.Windows.Forms.Timer();
        private readonly System.Windows.Forms.Timer saveTimer = new System.Windows.Forms.Timer();
        private readonly System.Windows.Forms.Timer settingsTimer = new System.Windows.Forms.Timer();

        private Settings settings;
        private Theme theme;
        private IntPtr trayIconHandle;
        private DisplayState[] displays = new DisplayState[0];
        private readonly Dictionary<string, int> current = new Dictionary<string, int>();
        private readonly Dictionary<string, DateTime> lastUserChange = new Dictionary<string, DateTime>();
        private readonly Dictionary<string, int> unsaved = new Dictionary<string, int>();
        private HashSet<string> connected = new HashSet<string>();
        private string hotkeyWarning;

        public TrayApp()
        {
            ui = new WindowsFormsSynchronizationContext();
            SynchronizationContext.SetSynchronizationContext(ui);

            settings = LoadSettings();
            theme = Theme.Current();

            flyout = new Flyout(theme);
            flyout.BrightnessChanged += (key, percent) => SetBrightness(key, percent, false);
            osd = new Osd(theme);

            startWithWindowsItem = new ToolStripMenuItem("Start with Windows", null, delegate
            {
                UserState.StartsWithWindows = !UserState.StartsWithWindows;
            });
            restoreItem = new ToolStripMenuItem("Restore brightness when the display connects", null, delegate
            {
                settings.RestoreOnConnect = !settings.RestoreOnConnect;
                SaveSettings();
            });

            var menu = new ContextMenuStrip();
            menu.Items.Add(new ToolStripMenuItem("Brightness...", null, delegate { ShowFlyout(); }));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(startWithWindowsItem);
            menu.Items.Add(restoreItem);
            menu.Items.Add(new ToolStripMenuItem("Edit settings (step, hotkeys)...", null, delegate { OpenSettingsFile(); }));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("Exit", null, delegate { ExitThread(); }));
            menu.Opening += delegate
            {
                startWithWindowsItem.Checked = UserState.StartsWithWindows;
                restoreItem.Checked = settings.RestoreOnConnect;
            };

            tray = new NotifyIcon();
            tray.ContextMenuStrip = menu;
            tray.MouseClick += (sender, e) =>
            {
                if (e.Button == MouseButtons.Left)
                {
                    ToggleFlyout();
                }
            };
            UpdateTrayIcon();
            UpdateTooltip();
            tray.Visible = true;

            messages = new MessageWindow(this);
            RegisterHotkeys();

            rescanTimer.Interval = 1500;
            rescanTimer.Tick += delegate
            {
                rescanTimer.Stop();
                service.RequestRescan();
            };

            saveTimer.Interval = 1000;
            saveTimer.Tick += delegate
            {
                saveTimer.Stop();
                SaveBrightness();
            };

            settingsTimer.Interval = 300;
            settingsTimer.Tick += delegate
            {
                settingsTimer.Stop();
                ReloadSettings();
            };

            Directory.CreateDirectory(Path.GetDirectoryName(Settings.FilePath));
            settingsWatcher = new FileSystemWatcher(Path.GetDirectoryName(Settings.FilePath), Path.GetFileName(Settings.FilePath));
            settingsWatcher.NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size;
            FileSystemEventHandler onSettingsChanged = (sender, e) => ui.Post(delegate { settingsTimer.Stop(); settingsTimer.Start(); }, null);
            settingsWatcher.Changed += onSettingsChanged;
            settingsWatcher.Created += onSettingsChanged;
            settingsWatcher.Renamed += (sender, e) => onSettingsChanged(sender, e);
            settingsWatcher.EnableRaisingEvents = true;

            SystemEvents.PowerModeChanged += OnPowerModeChanged;

            service = new DisplayService();
            service.Changed += (states, rescanned) => ui.Post(delegate { OnDisplaysChanged(states, rescanned); }, null);
            service.RequestRescan();

            Log.Write("Started {0}", Application.ProductVersion);
        }

        private static Settings LoadSettings()
        {
            try
            {
                return Settings.Load();
            }
            catch (Exception ex)
            {
                Log.Write("Could not read settings: {0}", ex.Message);
                return new Settings();
            }
        }

        private void SaveSettings()
        {
            try
            {
                settings.Save();
            }
            catch (Exception ex)
            {
                Log.Write("Could not save settings: {0}", ex.Message);
            }
        }

        private void ReloadSettings()
        {
            settings = LoadSettings();
            RegisterHotkeys();
            Log.Write("Settings reloaded");
        }

        private void OpenSettingsFile()
        {
            if (!File.Exists(Settings.FilePath))
            {
                SaveSettings();
            }

            try
            {
                Process.Start("notepad.exe", "\"" + Settings.FilePath + "\"");
            }
            catch (Exception ex)
            {
                Log.Write("Could not open settings: {0}", ex.Message);
            }
        }

        private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
        {
            if (e.Mode == PowerModes.Resume)
            {
                ui.Post(delegate { ScheduleRescan(); }, null);
            }
        }

        private void ScheduleRescan()
        {
            rescanTimer.Stop();
            rescanTimer.Start();
        }

        private void OnDisplaysChanged(DisplayState[] states, bool rescanned)
        {
            displays = states;
            DateTime now = DateTime.UtcNow;
            foreach (DisplayState state in states)
            {
                DateTime changed;
                bool recentUserChange = lastUserChange.TryGetValue(state.Key, out changed) && now - changed < UserChangeGrace;
                if (state.Percent >= 0 && !recentUserChange)
                {
                    current[state.Key] = state.Percent;
                }
            }

            if (rescanned)
            {
                var nowConnected = new HashSet<string>();
                foreach (DisplayState state in states)
                {
                    nowConnected.Add(state.Key);
                    if (!connected.Contains(state.Key))
                    {
                        OnDisplayConnected(state);
                    }
                }

                connected = nowConnected;
            }

            UpdateFlyout();
            UpdateTooltip();
        }

        private void OnDisplayConnected(DisplayState state)
        {
            Log.Write("Connected: {0}, brightness {1}%", state.Key, state.Percent);
            if (!settings.RestoreOnConnect)
            {
                return;
            }

            int? saved = null;
            try
            {
                saved = UserState.GetBrightness(state.Key);
            }
            catch (Exception ex)
            {
                Log.Write("Could not read saved brightness: {0}", ex.Message);
            }

            if (saved.HasValue && saved.Value != state.Percent)
            {
                Log.Write("Restoring {0}% on {1}", saved.Value, state.Key);
                current[state.Key] = saved.Value;
                service.SetBrightness(state.Key, saved.Value);
            }
        }

        private void SetBrightness(string key, int percent, bool fromHotkey)
        {
            percent = Math.Max(0, Math.Min(100, percent));
            current[key] = percent;
            lastUserChange[key] = DateTime.UtcNow;
            unsaved[key] = percent;
            service.SetBrightness(key, percent);
            saveTimer.Stop();
            saveTimer.Start();
            if (fromHotkey)
            {
                UpdateFlyout();
            }

            UpdateTooltip();
        }

        private void SaveBrightness()
        {
            foreach (var entry in unsaved)
            {
                try
                {
                    UserState.SetBrightness(entry.Key, entry.Value);
                }
                catch (Exception ex)
                {
                    Log.Write("Could not save brightness: {0}", ex.Message);
                }
            }

            unsaved.Clear();
        }

        private void Step(int direction)
        {
            if (displays.Length == 0)
            {
                osd.ShowMessage("No Studio Display found");
                service.RequestRescan();
                return;
            }

            int shown = -1;
            foreach (DisplayState display in displays)
            {
                int value;
                if (!current.TryGetValue(display.Key, out value))
                {
                    continue;
                }

                value = Math.Max(0, Math.Min(100, value + direction * settings.Step));
                SetBrightness(display.Key, value, true);
                if (shown < 0)
                {
                    shown = value;
                }
            }

            if (shown >= 0)
            {
                osd.ShowLevel(shown);
            }
        }

        private List<DisplayView> BuildViews()
        {

            var views = new List<DisplayView>();
            foreach (DisplayState display in displays)
            {
                var view = new DisplayView();
                view.Key = display.Key;
                // The HID product string is "HID Relay", so name the display ourselves.
                view.Name = "Studio Display";
                if (displays.Length > 1 && !String.IsNullOrEmpty(display.Serial))
                {
                    view.Name += " (" + (display.Serial.Length > 4 ? display.Serial.Substring(display.Serial.Length - 4) : display.Serial) + ")";
                }

                int value;
                view.Percent = current.TryGetValue(display.Key, out value) ? value : -1;
                views.Add(view);
            }

            return views;
        }

        private void UpdateFlyout()
        {
            flyout.SetDisplays(BuildViews());
        }

        private void UpdateTooltip()
        {
            string text;
            if (displays.Length == 0)
            {
                text = "Studio Display: not connected";
            }
            else
            {
                var parts = new List<string>();
                foreach (DisplayView view in BuildViews())
                {
                    parts.Add(view.Percent >= 0 ? view.Percent + "%" : "?");
                }

                text = "Studio Display brightness: " + String.Join(", ", parts.ToArray());
            }

            if (hotkeyWarning != null)
            {
                text += "\n" + hotkeyWarning;
            }

            tray.Text = text.Length > 63 ? text.Substring(0, 63) : text;
        }

        private void UpdateTrayIcon()
        {
            int size = (int)Math.Round(16 * Native.PrimaryScale());
            IntPtr oldHandle = trayIconHandle;
            using (Bitmap bitmap = IconArt.RenderSun(size, theme.Dark ? Color.White : Color.Black))
            {
                trayIconHandle = bitmap.GetHicon();
            }

            tray.Icon = Icon.FromHandle(trayIconHandle);
            if (oldHandle != IntPtr.Zero)
            {
                Native.DestroyIcon(oldHandle);
            }
        }

        private void OnThemeChanged()
        {
            theme = Theme.Current();
            flyout.SetTheme(theme);
            osd.SetTheme(theme);
            UpdateTrayIcon();
        }

        private void ToggleFlyout()
        {
            // A click on the icon while the flyout is open deactivates (hides) it first;
            // don't reopen it on that same click.
            if (flyout.Visible || DateTime.UtcNow - flyout.LastHidden < TimeSpan.FromMilliseconds(300))
            {
                flyout.Hide();
                return;
            }

            ShowFlyout();
        }

        private void ShowFlyout()
        {
            ShowFlyout(Cursor.Position);
        }

        private void ShowFlyout(Point anchor)
        {
            UpdateFlyout();
            flyout.ShowNear(anchor);
            if (displays.Length == 0)
            {
                service.RequestRescan();
            }
            else
            {
                service.RequestRefresh();
            }
        }

        private void RegisterHotkeys()
        {
            Native.UnregisterHotKey(messages.Handle, HotkeyUpId);
            Native.UnregisterHotKey(messages.Handle, HotkeyDownId);

            var problems = new List<string>();
            RegisterHotkey(HotkeyUpId, settings.HotkeyUp, problems);
            RegisterHotkey(HotkeyDownId, settings.HotkeyDown, problems);

            string warning = problems.Count == 0 ? null : String.Join("; ", problems.ToArray());
            if (warning != null && warning != hotkeyWarning)
            {
                tray.ShowBalloonTip(5000, "Studio Display Brightness", warning, ToolTipIcon.Warning);
            }

            hotkeyWarning = warning;
            UpdateTooltip();
        }

        private void RegisterHotkey(int id, string text, List<string> problems)
        {
            Hotkey hotkey;
            if (!Hotkey.TryParse(text, out hotkey))
            {
                problems.Add("Invalid hotkey \"" + text + "\"");
                Log.Write("Invalid hotkey '{0}'", text);
                return;
            }

            if (hotkey == null)
            {
                return;
            }

            if (!Native.RegisterHotKey(messages.Handle, id, hotkey.Modifiers, (uint)hotkey.Key))
            {
                problems.Add(hotkey.Text + " is used by another app");
                Log.Write("RegisterHotKey '{0}' failed: {1}", hotkey.Text, System.Runtime.InteropServices.Marshal.GetLastWin32Error());
            }
        }

        protected override void ExitThreadCore()
        {
            SaveBrightness();
            tray.Visible = false;
            base.ExitThreadCore();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                SystemEvents.PowerModeChanged -= OnPowerModeChanged;
                settingsWatcher.Dispose();
                service.Dispose();
                messages.DestroyHandle();
                tray.Dispose();
                flyout.Dispose();
                osd.Dispose();
                rescanTimer.Dispose();
                saveTimer.Dispose();
                settingsTimer.Dispose();
                if (trayIconHandle != IntPtr.Zero)
                {
                    Native.DestroyIcon(trayIconHandle);
                    trayIconHandle = IntPtr.Zero;
                }
            }

            base.Dispose(disposing);
        }

        // Hidden top-level window: receives hotkeys and the broadcasts (device, theme,
        // display changes, second-instance activation) that message-only windows miss.
        private sealed class MessageWindow : NativeWindow
        {
            private readonly TrayApp app;

            public MessageWindow(TrayApp app)
            {
                this.app = app;
                var cp = new CreateParams();
                cp.Caption = "StudioDisplayBrightness.Messages";
                CreateHandle(cp);
            }

            protected override void WndProc(ref Message m)
            {
                switch (m.Msg)
                {
                    case Native.WM_HOTKEY:
                        app.Step(m.WParam.ToInt32() == HotkeyUpId ? 1 : -1);
                        break;
                    case Native.WM_DEVICECHANGE:
                        if (m.WParam.ToInt32() == Native.DBT_DEVNODES_CHANGED)
                        {
                            app.ScheduleRescan();
                        }

                        break;
                    case Native.WM_SETTINGCHANGE:
                        if (m.LParam != IntPtr.Zero && System.Runtime.InteropServices.Marshal.PtrToStringUni(m.LParam) == "ImmersiveColorSet")
                        {
                            app.OnThemeChanged();
                        }

                        break;
                    case Native.WM_DISPLAYCHANGE:
                        app.UpdateTrayIcon();
                        break;
                    default:
                        if (m.Msg == (int)ShowFlyoutMessage && ShowFlyoutMessage != 0)
                        {
                            // Launched again (e.g. from Start): open in the tray corner of the primary screen.
                            Rectangle bounds = Screen.PrimaryScreen.Bounds;
                            app.ShowFlyout(new Point(bounds.Right - 1, bounds.Bottom - 1));
                        }

                        break;
                }

                base.WndProc(ref m);
            }
        }
    }
}
