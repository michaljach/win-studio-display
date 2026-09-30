using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace StudioDisplayBrightness
{
    // Small click-through level indicator shown above the taskbar for hotkey changes,
    // like the Windows 11 volume/brightness OSD.
    internal sealed class Osd : Form
    {
        private readonly Timer hideTimer = new Timer();
        private Theme theme;
        private float scale = 1f;
        private int percent;
        private string message;
        private Font font;
        private Bitmap sun;

        public Osd(Theme theme)
        {
            this.theme = theme;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            AutoScaleMode = AutoScaleMode.None;
            DoubleBuffered = true;
            BackColor = theme.Background;
            hideTimer.Interval = 1500;
            hideTimer.Tick += delegate
            {
                hideTimer.Stop();
                Hide();
            };
        }

        protected override bool ShowWithoutActivation
        {
            get { return true; }
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOPMOST | Native.WS_EX_TRANSPARENT;
                cp.ClassStyle |= Native.CS_DROPSHADOW;
                return cp;
            }
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            Native.ApplyWindowFrame(Handle, theme.Dark, false);
        }

        public void SetTheme(Theme newTheme)
        {
            theme = newTheme;
            BackColor = theme.Background;
            if (IsHandleCreated)
            {
                Native.ApplyWindowFrame(Handle, theme.Dark, false);
            }

            Rescale(scale, true);
        }

        public void ShowLevel(int value)
        {
            percent = value;
            message = null;
            Present();
        }

        public void ShowMessage(string text)
        {
            message = text;
            Present();
        }

        public Bitmap RenderPreview(float previewScale, int value)
        {
            percent = value;
            message = null;
            Rescale(previewScale, true);
            Size = new Size(S(220), S(48));
            var bitmap = new Bitmap(Width, Height);
            DrawToBitmap(bitmap, new Rectangle(Point.Empty, Size));
            return bitmap;
        }

        private int S(int value)
        {
            return (int)Math.Round(value * scale);
        }

        private void Rescale(float newScale, bool force)
        {
            if (!force && font != null && newScale == scale)
            {
                return;
            }

            scale = newScale;
            if (font != null)
            {
                font.Dispose();
                sun.Dispose();
            }

            font = new Font("Segoe UI", 14f * scale, FontStyle.Regular, GraphicsUnit.Pixel);
            sun = IconArt.RenderSun(S(20), theme.Text);
        }

        private void Present()
        {
            Point cursor = Cursor.Position;
            Rescale(Native.ScaleForPoint(cursor), false);
            Rectangle area = Screen.FromPoint(cursor).WorkingArea;
            var size = new Size(S(message == null ? 220 : 300), S(48));
            Bounds = new Rectangle(area.Left + (area.Width - size.Width) / 2, area.Bottom - size.Height - S(24), size.Width, size.Height);
            Invalidate();
            if (!Visible)
            {
                Show();
            }

            hideTimer.Stop();
            hideTimer.Start();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.Clear(theme.Background);
            int pad = S(16);
            var iconBounds = new Rectangle(pad, (ClientSize.Height - sun.Height) / 2, sun.Width, sun.Height);
            g.DrawImage(sun, iconBounds);

            const TextFormatFlags Line = TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis;
            if (message != null)
            {
                var textBounds = new Rectangle(iconBounds.Right + S(12), 0, ClientSize.Width - iconBounds.Right - S(12) - pad, ClientSize.Height);
                TextRenderer.DrawText(g, message, font, textBounds, theme.Text, Line);
                return;
            }

            var valueBounds = new Rectangle(ClientSize.Width - pad - S(40), 0, S(40), ClientSize.Height);
            TextRenderer.DrawText(g, percent + "%", font, valueBounds, theme.Text, Line | TextFormatFlags.Right);

            float left = iconBounds.Right + S(14);
            float right = valueBounds.Left - S(12);
            float y = ClientSize.Height / 2f;
            float fill = left + (right - left) * percent / 100f;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (var rail = new Pen(theme.Rail, Math.Max(2f, 4f * scale)))
            using (var accent = new Pen(theme.Accent, Math.Max(2f, 4f * scale)))
            {
                rail.StartCap = rail.EndCap = LineCap.Round;
                accent.StartCap = accent.EndCap = LineCap.Round;
                g.DrawLine(rail, left, y, right, y);
                if (percent > 0)
                {
                    g.DrawLine(accent, left, y, fill, y);
                }
            }
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Native.WM_DPICHANGED)
            {
                m.Result = IntPtr.Zero;
                return;
            }

            base.WndProc(ref m);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                hideTimer.Dispose();
                if (font != null)
                {
                    font.Dispose();
                    sun.Dispose();
                }
            }

            base.Dispose(disposing);
        }
    }
}
