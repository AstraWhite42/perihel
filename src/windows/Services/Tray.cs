using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using Forms = System.Windows.Forms;

namespace Perihel;

internal sealed class Tray : IDisposable
{
    private readonly Forms.NotifyIcon item = new();

    private Icon? icon;
    private (string? Value, bool Light) displayed;
    private (int, bool, DepletionDirection) appearance = (-2,false,default);
    public event Action<Bitmap>? ImageChanged;
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr icon);
    public Tray(Action toggle)
    {
        void Click(object? sender, Forms.MouseEventArgs e) { if (e.Button is Forms.MouseButtons.Left or Forms.MouseButtons.Right) toggle(); }
        item.MouseClick += Click;

        item.Visible = true;
    }
    public void InvalidateAppearance() => appearance = (-2,false,default);
    public void Update(double? remaining, string text, DepletionDirection direction, string value)
    {
        item.Text = text.Length <= 63 ? text : text[..62] + "…";
        int lit = (int)Math.Floor((remaining ?? 0) * 7 / 100 + .5000000001);
        bool light = Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "SystemUsesLightTheme", 0) is 1;
        bool ringChanged = appearance != (lit, light, direction);
        bool displayChanged = displayed != (value, light);
        if (ringChanged || (displayChanged && value.Length == 0))
        {
            using var ring = DrawRing(lit, light, direction);
            if (ringChanged) ImageChanged?.Invoke(ring);
            if (value.Length == 0) ReplaceIcon(ring);
            appearance = (lit, light, direction);
        }
        if (displayChanged && value.Length > 0) DrawNumber(value, light);
        displayed = (value, light);
    }
    private static Bitmap DrawRing(int lit, bool light, DepletionDirection direction)
    {
        var color = light ? Color.FromArgb(27,38,53) : Color.White;
        var bitmap = new Bitmap(48,48);
        using var g = Graphics.FromImage(bitmap);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.ScaleTransform(2.4f,2.4f);
        for (var i = 0; i < 7; i++)
        {
            bool on = direction == DepletionDirection.Counterclockwise ? i < lit : i >= 7 - lit;
            var shade = Color.FromArgb(on ? 255 : 51, color);
            using var pen = new Pen(shade,2);
            if (i < 6) g.DrawArc(pen,3,3,14,14,-90 + i*360f/7 + 4.5f,360f/7 - 9);
            else
            {
                using var b = new SolidBrush(shade);
                g.FillPolygon(b,[new PointF(4.9f,4.5f),new PointF(8.4f,2.6f),new PointF(8,6.4f)]);
            }
        }
        using var brush = new SolidBrush(color);
        g.FillPolygon(brush,[new PointF(10,5.8f),new PointF(11.2f,8.8f),new PointF(14.2f,10),new PointF(11.2f,11.2f),
            new PointF(10,14.2f),new PointF(8.8f,11.2f),new PointF(5.8f,10),new PointF(8.8f,8.8f)]);
        return bitmap;
    }
    private void DrawNumber(string value, bool light)
    {
        using var bitmap = new Bitmap(48,48);
        using var g = Graphics.FromImage(bitmap);
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        using var brush = new SolidBrush(light ? Color.FromArgb(27,38,53) : Color.White);
        using var format = new StringFormat(StringFormat.GenericTypographic) {
            Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center, FormatFlags = StringFormatFlags.NoWrap
        };
        // The shell grants one square per icon. Put signed budget decimals on a second line.
        string label = value.TrimEnd('!', ' ');
        var lines = label.Split('.');
        string top = lines[0];
        bool warning = value.EndsWith('!');
        using var font = new Font("Segoe UI", top.Length > 3 ? 18 : top.Length > 2 ? 22 : 29, FontStyle.Bold, GraphicsUnit.Pixel);
        g.DrawString(top, font, brush, new RectangleF(0,0,48,lines.Length > 1 ? 30 : 48), format);
        if (lines.Length > 1)
        {
            using var fraction = new Font("Segoe UI",17,FontStyle.Bold,GraphicsUnit.Pixel);
            g.DrawString("." + lines[1], fraction, brush, new RectangleF(0,27,48,20), format);
        }
        if (warning)
        {
            using var alert = new Font("Segoe UI",16,FontStyle.Bold,GraphicsUnit.Pixel);
            g.DrawString("!", alert, Brushes.DarkOrange, new RectangleF(37,0,11,18), format);
        }
        ReplaceIcon(bitmap);
    }
    private void ReplaceIcon(Bitmap bitmap)
    {
        var handle = bitmap.GetHicon();
        try
        {
            using var borrowed = Icon.FromHandle(handle);
            var next = (Icon)borrowed.Clone();
            item.Icon = next; icon?.Dispose(); icon = next;
        }
        finally { DestroyIcon(handle); }
    }
    public void Dispose()
    {
        item.Visible = false;
        item.Dispose(); icon?.Dispose();
    }
}
