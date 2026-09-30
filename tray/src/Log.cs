using System;
using System.Globalization;
using System.IO;

namespace StudioDisplayBrightness
{
    internal static class Log
    {
        private const long MaxBytes = 512 * 1024;
        private static readonly object sync = new object();

        public static readonly string Directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StudioDisplayBrightness");

        public static readonly string FilePath = Path.Combine(Directory, "tray.log");

        public static void Write(string format, params object[] args)
        {
            try
            {
                string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture) + "  " +
                    String.Format(CultureInfo.InvariantCulture, format, args) + Environment.NewLine;
                lock (sync)
                {
                    System.IO.Directory.CreateDirectory(Directory);
                    var info = new FileInfo(FilePath);
                    if (info.Exists && info.Length > MaxBytes)
                    {
                        File.Copy(FilePath, FilePath + ".old", true);
                        File.Delete(FilePath);
                    }

                    File.AppendAllText(FilePath, line);
                }
            }
            catch (Exception)
            {
                // Logging must never take the app down.
            }
        }
    }
}
