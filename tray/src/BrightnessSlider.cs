using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace StudioDisplayBrightness
{
    // Windows 11-style slider: thin rail, accent fill, round thumb with an accent dot.
    internal sealed class BrightnessSlider : Control
    {
        private int value;
        private bool hover;
        private bool dragging;
        private Theme theme;
        private float scale = 1f;

        // Raised only for changes made by the user.
        public event EventHandler ValueChanged;

        public BrightnessSlider()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
            TabStop = true;
            Cursor = Cursors.Default;
        }

        public bool IsDragging
        {
            get { return dragging; }
        }

        public int Value
        {
            get { return value; }
            set
            {
                int clamped = Math.Max(0, Math.Min(100, value));
                if (clamped != this.value)
                {
                    this.value = clamped;
                    Invalidate();
                }
            }
        }

        public void Apply(Theme newTheme, float newScale)
        {
            theme = newTheme;
            scale = newScale;
            BackColor = theme.Background;
            Invalidate();
        }

        private float ThumbRadius
        {
            get { return 10f * scale; }
        }

        private void SetFromUser(int newValue)
        {
            newValue = Math.Max(0, Math.Min(100, newValue));
            if (newValue == value)
            {
                return;
            }

            value = newValue;
            Invalidate();
            var handler = ValueChanged;
            if (handler != null)
            {
                handler(this, EventArgs.Empty);
            }
        }

        private int ValueFromX(int x)
        {
            float left = ThumbRadius;
            float width = Math.Max(1f, Width - 2 * ThumbRadius);
            return (int)Math.Round((x - left) / width * 100f);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            if (theme == null)
            {
                return;
            }

            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;

            float radius = ThumbRadius;
            float left = radius;
            float right = Width - radius;
            float centerY = Height / 2f;
            float thumbX = left + (right - left) * value / 100f;
            float railHeight = Math.Max(2f, 4f * scale);

            using (var railPen = new Pen(theme.Rail, railHeight))
            using (var accentPen = new Pen(theme.Accent, railHeight))
            {
                railPen.StartCap = railPen.EndCap = LineCap.Round;
                accentPen.StartCap = accentPen.EndCap = LineCap.Round;
                if (thumbX < right)
                {
                    g.DrawLine(railPen, thumbX, centerY, right, centerY);
                }

                if (thumbX > left)
                {
                    g.DrawLine(accentPen, left, centerY, thumbX, centerY);
                }
            }

            using (var outer = new SolidBrush(theme.ThumbOuter))
            using (var border = new Pen(theme.ThumbBorder, Math.Max(1f, scale)))
            using (var inner = new SolidBrush(theme.Accent))
            {
                g.FillEllipse(outer, thumbX - radius, centerY - radius, radius * 2, radius * 2);
                g.DrawEllipse(border, thumbX - radius, centerY - radius, radius * 2, radius * 2);
                float dot = (dragging ? 5f : hover ? 7f : 6f) * scale;
                g.FillEllipse(inner, thumbX - dot, centerY - dot, dot * 2, dot * 2);
            }

            if (Focused && ShowFocusCues)
            {
                using (var focus = new Pen(theme.Text, Math.Max(1f, scale)))
                {
                    float pad = 2f * scale;
                    g.DrawEllipse(focus, thumbX - radius - pad, centerY - radius - pad, (radius + pad) * 2, (radius + pad) * 2);
                }
            }
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button != MouseButtons.Left)
            {
                return;
            }

            Focus();
            dragging = true;
            Capture = true;
            SetFromUser(ValueFromX(e.X));
            Invalidate();
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (dragging)
            {
                SetFromUser(ValueFromX(e.X));
            }
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (dragging)
            {
                dragging = false;
                Capture = false;
                Invalidate();
            }
        }

        protected override void OnMouseEnter(EventArgs e)
        {
            base.OnMouseEnter(e);
            hover = true;
            Invalidate();
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            base.OnMouseLeave(e);
            hover = false;
            Invalidate();
        }

        protected override void OnMouseWheel(MouseEventArgs e)
        {
            base.OnMouseWheel(e);
            SetFromUser(value + Math.Sign(e.Delta) * 2);
        }

        protected override void OnGotFocus(EventArgs e)
        {
            base.OnGotFocus(e);
            Invalidate();
        }

        protected override void OnLostFocus(EventArgs e)
        {
            base.OnLostFocus(e);
            dragging = false;
            Invalidate();
        }

        protected override bool IsInputKey(Keys keyData)
        {
            switch (keyData & Keys.KeyCode)
            {
                case Keys.Left:
                case Keys.Right:
                case Keys.Up:
                case Keys.Down:
                    return true;
            }

            return base.IsInputKey(keyData);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            switch (e.KeyCode)
            {
                case Keys.Left:
                case Keys.Down:
                    SetFromUser(value - 1);
                    break;
                case Keys.Right:
                case Keys.Up:
                    SetFromUser(value + 1);
                    break;
                case Keys.PageDown:
                    SetFromUser(value - 10);
                    break;
                case Keys.PageUp:
                    SetFromUser(value + 10);
                    break;
                case Keys.Home:
                    SetFromUser(0);
                    break;
                case Keys.End:
                    SetFromUser(100);
                    break;
                default:
                    return;
            }

            e.Handled = true;
        }
    }
}
