using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

namespace StudioDisplayBrightness
{
    // Sun glyph used for the tray icon, the flyout and (via build.ps1) the EXE icon.
    public static class IconArt
    {
        public static Bitmap RenderSun(int size, Color color)
        {
            var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(bitmap))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.Clear(Color.Transparent);

                float center = size / 2f;
                float stroke = Math.Max(1.25f, size * 0.09f);
                float core = size * 0.2f;
                float rayStart = size * 0.33f;
                float rayEnd = size * 0.455f - stroke / 2f;

                using (var brush = new SolidBrush(color))
                using (var pen = new Pen(color, stroke))
                {
                    pen.StartCap = LineCap.Round;
                    pen.EndCap = LineCap.Round;
                    g.FillEllipse(brush, center - core, center - core, core * 2, core * 2);
                    for (int i = 0; i < 8; i++)
                    {
                        double angle = i * Math.PI / 4;
                        float cos = (float)Math.Cos(angle);
                        float sin = (float)Math.Sin(angle);
                        g.DrawLine(pen, center + cos * rayStart, center + sin * rayStart, center + cos * rayEnd, center + sin * rayEnd);
                    }
                }
            }

            return bitmap;
        }

        // Writes a multi-resolution .ico: 32-bit DIB entries, plus PNG for 256 px.
        public static void WriteIco(string path, Color color, int[] sizes)
        {
            var images = new List<byte[]>();
            foreach (int size in sizes)
            {
                using (Bitmap bitmap = RenderSun(size, color))
                {
                    images.Add(size >= 256 ? EncodePng(bitmap) : EncodeDib(bitmap));
                }
            }

            using (var stream = new FileStream(path, FileMode.Create, FileAccess.Write))
            using (var writer = new BinaryWriter(stream))
            {
                writer.Write((ushort)0);
                writer.Write((ushort)1);
                writer.Write((ushort)sizes.Length);

                int offset = 6 + 16 * sizes.Length;
                for (int i = 0; i < sizes.Length; i++)
                {
                    writer.Write((byte)(sizes[i] >= 256 ? 0 : sizes[i]));
                    writer.Write((byte)(sizes[i] >= 256 ? 0 : sizes[i]));
                    writer.Write((byte)0);
                    writer.Write((byte)0);
                    writer.Write((ushort)1);
                    writer.Write((ushort)32);
                    writer.Write(images[i].Length);
                    writer.Write(offset);
                    offset += images[i].Length;
                }

                foreach (byte[] image in images)
                {
                    writer.Write(image);
                }
            }
        }

        private static byte[] EncodePng(Bitmap bitmap)
        {
            using (var stream = new MemoryStream())
            {
                bitmap.Save(stream, ImageFormat.Png);
                return stream.ToArray();
            }
        }

        private static byte[] EncodeDib(Bitmap bitmap)
        {
            int size = bitmap.Width;
            int maskStride = ((size + 31) / 32) * 4;
            using (var stream = new MemoryStream())
            using (var writer = new BinaryWriter(stream))
            {
                writer.Write(40);
                writer.Write(size);
                writer.Write(size * 2);
                writer.Write((ushort)1);
                writer.Write((ushort)32);
                writer.Write(0);
                writer.Write(size * size * 4 + maskStride * size);
                writer.Write(0);
                writer.Write(0);
                writer.Write(0);
                writer.Write(0);

                BitmapData data = bitmap.LockBits(new Rectangle(0, 0, size, size), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                try
                {
                    var row = new byte[size * 4];
                    for (int y = size - 1; y >= 0; y--)
                    {
                        Marshal.Copy(new IntPtr(data.Scan0.ToInt64() + (long)y * data.Stride), row, 0, row.Length);
                        writer.Write(row);
                    }
                }
                finally
                {
                    bitmap.UnlockBits(data);
                }

                writer.Write(new byte[maskStride * size]);
                return stream.ToArray();
            }
        }
    }
}
