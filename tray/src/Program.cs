using System;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("Studio Display Brightness")]
[assembly: AssemblyProduct("Studio Display Brightness")]
[assembly: AssemblyDescription("Tray brightness control for the Apple Studio Display on Windows")]
[assembly: AssemblyCompany("win-studio-display")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace StudioDisplayBrightness
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length == 2 && args[0] == "--render-preview")
            {
                RenderPreviews(args[1]);
                return 0;
            }

            bool createdNew;
            using (var mutex = new Mutex(true, @"Local\StudioDisplayBrightness.Tray", out createdNew))
            {
                if (!createdNew)
                {
                    // Already running: ask that instance to open its flyout.
                    Native.AllowSetForegroundWindow(Native.ASFW_ANY);
                    Native.PostMessage(Native.HWND_BROADCAST, TrayApp.ShowFlyoutMessage, IntPtr.Zero, IntPtr.Zero);
                    return 0;
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.ThreadException += (sender, e) => Log.Write("Unhandled UI exception: {0}", e.Exception);
                AppDomain.CurrentDomain.UnhandledException += (sender, e) => Log.Write("Unhandled exception: {0}", e.ExceptionObject);

                using (var app = new TrayApp())
                {
                    Application.Run(app);
                }

                return 0;
            }
        }

        // Writes flyout/OSD images in both themes at 150% for visual checks and docs.
        private static void RenderPreviews(string directory)
        {
            System.IO.Directory.CreateDirectory(directory);
            var one = new[] { View("a", "Studio Display", 55) };
            var two = new[] { View("a", "Studio Display (401C)", 55), View("b", "Studio Display (7A2F)", 80) };
            foreach (bool dark in new[] { true, false })
            {
                string suffix = dark ? "dark" : "light";
                Theme theme = Theme.Create(dark);
                Save(directory, "flyout-empty-" + suffix, new Flyout(theme), new DisplayView[0]);
                Save(directory, "flyout-one-" + suffix, new Flyout(theme), one);
                Save(directory, "flyout-two-" + suffix, new Flyout(theme), two);
                using (var osd = new Osd(theme))
                using (var bitmap = osd.RenderPreview(1.5f, 55))
                {
                    bitmap.Save(System.IO.Path.Combine(directory, "osd-" + suffix + ".png"));
                }
            }
        }

        private static DisplayView View(string key, string name, int percent)
        {
            var view = new DisplayView();
            view.Key = key;
            view.Name = name;
            view.Percent = percent;
            return view;
        }

        private static void Save(string directory, string name, Flyout flyout, DisplayView[] views)
        {
            using (flyout)
            {
                flyout.SetDisplays(views);
                using (var bitmap = flyout.RenderPreview(1.5f))
                {
                    bitmap.Save(System.IO.Path.Combine(directory, name + ".png"));
                }
            }
        }
    }
}
