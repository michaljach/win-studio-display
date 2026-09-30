using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace StudioDisplayBrightness
{
    internal sealed class DisplayView
    {
        public string Key;
        public string Name;
        public int Percent;
    }

    // Popup opened from the tray icon, styled after the Windows 11 Quick Settings panel.
    // Layout and drawing are done by hand at the DPI of the monitor it opens on.
    internal sealed class Flyout : Form
    {
        private const int BaseWidth = 340;
        private const int Pad = 20;
        private const int NameHeight = 20;
        private const int NameGap = 4;
        private const int RowHeight = 32;
        private const int RowGap = 14;
        private const int IconSize = 20;
        private const int ValueWidth = 40;
        private const int EdgeGap = 12;

        private sealed class Row
        {
            public string Key;
            public string Name;
            public BrightnessSlider Slider;
            public Rectangle NameBounds;
            public Rectangle IconBounds;
            public Rectangle ValueBounds;
        }

        private readonly List<Row> rows = new List<Row>();
        private Theme theme;
        private float scale = 1f;
        private Font nameFont;
        private Font valueFont;
        private Bitmap sun;
        private Point anchor;
        private DateTime shownAt;
        private readonly Timer inactiveTimer = new Timer();

        public DateTime LastHidden = DateTime.MinValue;

        public event Action<string, int> BrightnessChanged;

        public Flyout(Theme theme)
        {
            this.theme = theme;
            Text = "Studio Display Brightness";
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            TopMost = true;
            AutoScaleMode = AutoScaleMode.None;
            KeyPreview = true;
            DoubleBuffered = true;
            BackColor = theme.Background;
            ApplyScale(1f);

            // Windows can refuse to activate the flyout (e.g. a fullscreen game has the
            // foreground); then no Deactivate ever comes, so close once the cursor leaves it.
            inactiveTimer.Interval = 250;
            inactiveTimer.Tick += delegate
            {
                if (Visible && Form.ActiveForm != this && !Bounds.Contains(Cursor.Position) &&
                    DateTime.UtcNow - shownAt > TimeSpan.FromSeconds(1.5))
                {
                    Hide();
                }
            };
        }

        // Draws the flyout into a bitmap without showing it (build/README previews).
        public Bitmap RenderPreview(float previewScale)
        {
            ApplyScale(previewScale);
            anchor = Screen.PrimaryScreen.WorkingArea.Location;
            Relayout();
            var bitmap = new Bitmap(Width, Height);
            DrawToBitmap(bitmap, new Rectangle(Point.Empty, Size));
            // Child controls of a never-shown form aren't printed; draw them explicitly.
            foreach (Row row in rows)
            {
                row.Slider.DrawToBitmap(bitmap, row.Slider.Bounds);
            }

            return bitmap;
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= Native.WS_EX_TOOLWINDOW;
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

            ApplyScale(scale);
            Invalidate();
        }

        public void SetDisplays(IList<DisplayView> displays)
        {
            bool sameSet = displays.Count == rows.Count;
            for (int i = 0; sameSet && i < displays.Count; i++)
            {
                sameSet = displays[i].Key == rows[i].Key && displays[i].Name == rows[i].Name;
            }

            if (!sameSet)
            {
                SuspendLayout();
                foreach (Row row in rows)
                {
                    Controls.Remove(row.Slider);
                    row.Slider.Dispose();
                }

                rows.Clear();
                foreach (DisplayView display in displays)
                {
                    var row = new Row();
                    row.Key = display.Key;
                    row.Name = display.Name;
                    row.Slider = new BrightnessSlider();
                    row.Slider.Apply(theme, scale);
                    string key = display.Key;
                    BrightnessSlider slider = row.Slider;
                    slider.ValueChanged += delegate
                    {
                        Invalidate();
                        var handler = BrightnessChanged;
                        if (handler != null)
                        {
                            handler(key, slider.Value);
                        }
                    };
                    rows.Add(row);
                    Controls.Add(row.Slider);
                }

                ResumeLayout(false);
                if (Visible)
                {
                    Relayout();
                    FocusFirstSlider();
                }
            }

            for (int i = 0; i < displays.Count; i++)
            {
                if (!rows[i].Slider.IsDragging && displays[i].Percent >= 0)
                {
                    rows[i].Slider.Value = displays[i].Percent;
                }
            }

            Invalidate();
        }

        public void ShowNear(Point cursor)
        {
            anchor = cursor;
            ApplyScale(Native.ScaleForPoint(cursor));
            Relayout();
            Show();
            Activate();
            Native.SetForegroundWindow(Handle);
            FocusFirstSlider();
        }

        private void FocusFirstSlider()
        {
            if (rows.Count > 0)
            {
                rows[0].Slider.Focus();
            }
        }

        private int S(int value)
        {
            return (int)Math.Round(value * scale);
        }

        private void ApplyScale(float newScale)
        {
            scale = newScale;
            if (nameFont != null)
            {
                nameFont.Dispose();
                valueFont.Dispose();
                sun.Dispose();
            }

            nameFont = new Font("Segoe UI", 14f * scale, FontStyle.Regular, GraphicsUnit.Pixel);
            valueFont = new Font("Segoe UI", 14f * scale, FontStyle.Regular, GraphicsUnit.Pixel);
            sun = IconArt.RenderSun(S(IconSize), theme.Text);
            foreach (Row row in rows)
            {
                row.Slider.Apply(theme, scale);
            }
        }

        private void Relayout()
        {
            int width = S(BaseWidth);
            int y = S(Pad);
            if (rows.Count == 0)
            {
                y += S(NameHeight) + S(NameGap) + S(RowHeight);
            }

            for (int i = 0; i < rows.Count; i++)
            {
                Row row = rows[i];
                if (i > 0)
                {
                    y += S(RowGap);
                }

                row.NameBounds = new Rectangle(S(Pad), y, width - 2 * S(Pad), S(NameHeight));
                y += S(NameHeight) + S(NameGap);

                int iconSize = S(IconSize);
                row.IconBounds = new Rectangle(S(Pad), y + (S(RowHeight) - iconSize) / 2, iconSize, iconSize);
                row.ValueBounds = new Rectangle(width - S(Pad) - S(ValueWidth), y, S(ValueWidth), S(RowHeight));
                int sliderLeft = row.IconBounds.Right + S(8);
                row.Slider.SetBounds(sliderLeft, y, row.ValueBounds.Left - S(6) - sliderLeft, S(RowHeight));
                y += S(RowHeight);
            }

            int height = y + S(Pad);
            Bounds = Place(anchor, new Size(width, height));
            Invalidate();
        }

        // Next to the tray icon: above/below/beside the cursor depending on which
        // edge the taskbar is on, kept inside the working area.
        private Rectangle Place(Point cursor, Size size)
        {
            Rectangle area = Screen.FromPoint(cursor).WorkingArea;
            int margin = S(EdgeGap);
            int x = cursor.X - size.Width / 2;
            int y = cursor.Y - size.Height - margin;

            if (cursor.Y >= area.Bottom)
            {
                y = area.Bottom - size.Height - margin;
            }
            else if (cursor.Y < area.Top)
            {
                y = area.Top + margin;
            }
            else if (cursor.X < area.Left)
            {
                x = area.Left + margin;
                y = cursor.Y - size.Height / 2;
            }
            else if (cursor.X >= area.Right)
            {
                x = area.Right - size.Width - margin;
                y = cursor.Y - size.Height / 2;
            }

            x = Math.Max(area.Left + margin, Math.Min(area.Right - size.Width - margin, x));
            y = Math.Max(area.Top + margin, Math.Min(area.Bottom - size.Height - margin, y));
            return new Rectangle(new Point(x, y), size);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.Clear(theme.Background);
            const TextFormatFlags Line = TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis;

            if (rows.Count == 0)
            {
                var title = new Rectangle(S(Pad), S(Pad), ClientSize.Width - 2 * S(Pad), S(NameHeight));
                TextRenderer.DrawText(g, "No Studio Display found", nameFont, title, theme.Text, Line);
                var detail = new Rectangle(title.Left, title.Bottom + S(NameGap), title.Width, S(RowHeight));
                TextRenderer.DrawText(g, "Connect it with USB-C or Thunderbolt.", valueFont, detail, theme.SubtleText, Line);
                return;
            }

            foreach (Row row in rows)
            {
                TextRenderer.DrawText(g, row.Name, nameFont, row.NameBounds, theme.SubtleText, Line);
                g.DrawImage(sun, row.IconBounds);
                TextRenderer.DrawText(g, row.Slider.Value + "%", valueFont, row.ValueBounds, theme.Text, Line | TextFormatFlags.Right);
            }
        }

        protected override void OnDeactivate(EventArgs e)
        {
            base.OnDeactivate(e);
            Hide();
        }

        protected override void OnVisibleChanged(EventArgs e)
        {
            base.OnVisibleChanged(e);
            if (Visible)
            {
                shownAt = DateTime.UtcNow;
                inactiveTimer.Start();
            }
            else
            {
                LastHidden = DateTime.UtcNow;
                inactiveTimer.Stop();
            }
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            if (e.KeyCode == Keys.Escape)
            {
                Hide();
                e.Handled = true;
            }
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Native.WM_DPICHANGED)
            {
                // Lay out again at the new DPI ourselves instead of letting WinForms rescale.
                ApplyScale((m.WParam.ToInt64() & 0xFFFF) / 96f);
                Relayout();
                m.Result = IntPtr.Zero;
                return;
            }

            base.WndProc(ref m);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                inactiveTimer.Dispose();
            }

            if (disposing && nameFont != null)
            {
                nameFont.Dispose();
                valueFont.Dispose();
                sun.Dispose();
            }

            base.Dispose(disposing);
        }
    }
}
