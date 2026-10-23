using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using NexoBar.Core;
using Forms = System.Windows.Forms;

namespace NexoBar.Windows;

// Every indicator has its own identity, click target and owned icon. No sensor/CLI work occurs here.
internal sealed class IndicatorTray(Action<string> detail, Action settings, Action reread, Action quit) : IDisposable
{
    private sealed class Entry : IDisposable
    {
        internal readonly Forms.NotifyIcon Notify = new();
        internal Icon? Image;
        internal string Key = "";
        public void Dispose() { Notify.Visible = false; Notify.ContextMenuStrip?.Dispose(); Notify.Dispose(); Image?.Dispose(); }
    }
    private readonly Dictionary<string, Entry> entries = [];
    internal void Update(Preferences preferences, IReadOnlyList<Reading> readings)
    {
        var enabled = preferences.Displays.TrayEnabled ? preferences.Indicators.Where(p => p.Enabled &&
            (!p.Id.StartsWith("gpu:", StringComparison.Ordinal) || readings.Any(r => r.Id == p.Id))).ToArray() : [];
        var ids = enabled.Select(p => p.Id).ToHashSet(StringComparer.Ordinal);
        foreach (string id in entries.Keys.Where(id => !ids.Contains(id)).ToArray()) { entries[id].Dispose(); entries.Remove(id); }
        bool light = DesktopIntegration.LightTheme();
        int size = Math.Clamp((int)Math.Round(16 * DesktopIntegration.Scale(DesktopIntegration.Selected(null))), 16, 64);
        foreach (var pref in enabled)
        {
            var reading = readings.First(r => r.Id == pref.Id);
            string value = reading.Unavailable is null ? Presentation.Percent(reading.Percent).Replace("%", "", StringComparison.Ordinal) : "—";
            string glyph = Glyph(pref.Id, reading.Vendor);
            string tooltip = Tooltip(pref, reading, preferences);
            string key = $"{light}|{size}|{glyph}|{value}|{tooltip}";
            if (!entries.TryGetValue(pref.Id, out var entry))
            {
                string id = pref.Id;
                entry = new();
                var menu = new Forms.ContextMenuStrip();
                menu.Items.Add("Abrir " + pref.Label, null, (_, _) => detail(id));
                menu.Items.Add("Personalizar…", null, (_, _) => settings());
                menu.Items.Add("Reler cotas", null, (_, _) => reread());
                menu.Items.Add("Sair", null, (_, _) => quit());
                entry.Notify.ContextMenuStrip = menu;
                entry.Notify.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) detail(id); };
                entries[id] = entry;
            }
            if (entry.Key == key) continue;
            var image = Render(glyph, value, size, light);
            var old = entry.Image;
            entry.Notify.Icon = image; entry.Image = image;
            entry.Notify.Text = tooltip;
            entry.Notify.ContextMenuStrip!.Items[0].Text = "Abrir " + pref.Label;
            entry.Notify.Visible = true; entry.Key = key;
            old?.Dispose();
        }
    }
    private static string Glyph(string id, GpuVendor vendor) => id switch
    {
        "cpu" => "C", "memory" => "M", "claude" => "Cl", "codex" => "Cx", "kiro" => "K",
        "copilot" => "Co", "antigravity" => "An", "cursor" => "Cu", "grok" => "Gr", "opencode" => "Op", "glm" => "Gl",
        _ when id.StartsWith("gpu:", StringComparison.Ordinal) => vendor switch { GpuVendor.Nvidia => "N", GpuVendor.Amd => "A", GpuVendor.Intel => "I", _ => "G" },
        _ => "N"
    };
    private static string Tooltip(IndicatorPreference pref, Reading reading, Preferences preferences)
    {
        string value = reading.Unavailable ?? (Preferences.Providers.Contains(pref.Id) ?
            string.Join(" | ", Presentation.QuotaLines(reading, preferences, DateTimeOffset.UtcNow)) : Presentation.Metric(reading, pref, preferences));
        string text = new((pref.Label + " · " + value).Where(c => !char.IsControl(c)).ToArray());
        if (text.Length <= 127) return text;
        int length = char.IsHighSurrogate(text[126]) ? 126 : 127;
        return text[..length];
    }
    private static Icon Render(string glyph, string value, int size, bool light)
    {
        // Render at taskbar DPI, with an opaque foreground and transparent background.
        using var bitmap = new Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.Transparent); graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        using var brush = new SolidBrush(light ? Color.FromArgb(20, 20, 20) : Color.FromArgb(248, 248, 248));
        using var small = new Font("Segoe UI", size * .34f, FontStyle.Bold, GraphicsUnit.Pixel);
        using var large = new Font("Segoe UI", size * .49f, FontStyle.Bold, GraphicsUnit.Pixel);
        using var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center, FormatFlags = StringFormatFlags.NoWrap };
        graphics.DrawString(glyph, small, brush, new RectangleF(0, -size * .04f, size, size * .45f), format);
        float measured = graphics.MeasureString(value, large).Width;
        using var fitted = new Font("Segoe UI", large.Size * Math.Min(1, size / measured), FontStyle.Bold, GraphicsUnit.Pixel);
        graphics.DrawString(value, fitted, brush, new RectangleF(0, size * .35f, size, size * .7f), format);
        IntPtr handle = bitmap.GetHicon();
        try { using var borrowed = Icon.FromHandle(handle); return (Icon)borrowed.Clone(); }
        finally { DestroyIcon(handle); }
    }
    public void Dispose() { foreach (var entry in entries.Values) entry.Dispose(); entries.Clear(); }
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyIcon(IntPtr icon);
}
