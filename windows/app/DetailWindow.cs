using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using NexoBar.Core;
using Button = System.Windows.Controls.Button;
using Orientation = System.Windows.Controls.Orientation;

namespace NexoBar.Windows;

internal sealed class DetailWindow : Window
{
    private readonly Func<Reading> getReading;
    private readonly Func<string> getLabel;
    private readonly Func<IReadOnlyList<(DateTimeOffset At, double Value)>> getHistory;
    private readonly Action settings, reread;
    internal DetailWindow(Func<Reading> reading, Func<string> label, Func<IReadOnlyList<(DateTimeOffset At, double Value)>> history, Action settings, Action reread)
    {
        getReading = reading; getLabel = label; getHistory = history; this.settings = settings; this.reread = reread;
        Width = 440; Height = 560; MinHeight = 360; MinWidth = 360;
        ShowInTaskbar = false; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Refresh();
    }
    internal void Refresh()
    {
        DesktopIntegration.Theme(this);
        var reading = getReading();
        Title = "NexoBar · " + getLabel();
        var panel = new StackPanel { Margin = new Thickness(20) };
        var heading = new StackPanel { Orientation = Orientation.Horizontal };
        if (reading.Id.StartsWith("gpu:", StringComparison.Ordinal)) heading.Children.Add(GpuBrandMark.Create(reading, Foreground, compact: false));
        heading.Children.Add(Text(getLabel(), 22, true));
        panel.Children.Add(heading);
        if (reading.Unavailable is not null) panel.Children.Add(Text("Indisponível · " + reading.Unavailable, 13));
        else if (reading.Windows is { Count: > 0 } windows)
            foreach (var window in windows)
            {
                panel.Children.Add(Text(window.Label + " · " + Presentation.QuotaValue(window), 15, true));
                if (window.Used is { } used) panel.Children.Add(Text(window.Limit is { } limit ? $"{used:0.##} de {limit:0.##} {window.Unit} utilizados" : $"{used:0.##} {window.Unit} utilizados"));
                if (window.Remaining is { } remaining) panel.Children.Add(Text($"{remaining:0.##} {window.Unit} restantes"));
                if (window.UsedPercent is { } percent)
                    panel.Children.Add(new ProgressBar { Minimum = 0, Maximum = 100, Value = Math.Clamp(percent, 0, 100), Height = 5, Margin = new Thickness(0, 6, 0, 5) });
                panel.Children.Add(Text(window.ResetsAt is { } reset ? "Renovação informada: " + reset.ToLocalTime().ToString("g", CultureInfo.CurrentCulture) +
                    " · " + Presentation.Countdown(reset, DateTimeOffset.UtcNow, true) : "Renovação não informada"));
                if (!window.AccountWindow) panel.Children.Add(Text("Janela por modelo · aparece apenas no detalhe"));
            }
        else
        {
            panel.Children.Add(Text(Presentation.Percent(reading.Percent) + " em uso", 24, true));
            if (reading.UsedBytes is not null || reading.TotalBytes is not null)
                panel.Children.Add(Text(Presentation.Bytes(reading.UsedBytes) + " em uso / " + Presentation.Bytes(reading.TotalBytes) + " total", 14));
            if (reading.Id != "memory") panel.Children.Add(Text(reading.Temperature is { } t ? $"Temperatura: {t:0.#} °C" : "Temperatura indisponível"));
            var samples = getHistory();
            panel.Children.Add(new HistoryChart(samples, Foreground) { Height = 140, Margin = new Thickness(0, 12, 0, 0) });
            panel.Children.Add(Text("Últimos 5 minutos · somente RAM · escala 0–100%"));
        }
        panel.Children.Add(Text("Fonte: " + reading.Source));
        panel.Children.Add(Text("Observação: " + reading.CapturedAt.ToLocalTime().ToString("G", CultureInfo.CurrentCulture)));
        if (Preferences.Providers.Contains(reading.Id)) panel.Children.Add(Text(reading.Activity));
        if (reading.Id == "claude") panel.Children.Add(Text("Reler consulta o arquivo local. O Claude Code precisa entregar uma status line recente."));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 15, 0, 0) };
        var customize = new Button { Content = "Personalizar barra…", Padding = new Thickness(9, 5, 9, 5) };
        customize.Click += (_, _) => settings(); buttons.Children.Add(customize);
        if (Preferences.Providers.Contains(reading.Id))
        {
            var reload = new Button { Content = reading.Id == "claude" ? "Reler status line" : "Reler cota", Padding = new Thickness(9, 5, 9, 5), Margin = new Thickness(8, 0, 0, 0) };
            reload.Click += (_, _) => reread(); buttons.Children.Add(reload);
        }
        panel.Children.Add(buttons);
        Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }
    private TextBlock Text(string text, double size = 12, bool bold = false) => new()
    {
        Text = text, FontSize = size, FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
        Foreground = Foreground, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 4)
    };
}

internal sealed class HistoryChart(IReadOnlyList<(DateTimeOffset At, double Value)> samples, Brush brush) : FrameworkElement
{
    protected override void OnRender(DrawingContext drawing)
    {
        base.OnRender(drawing);
        var pen = new Pen(brush, 1);
        drawing.DrawLine(new Pen(brush, 0.3), new Point(0, ActualHeight - 1), new Point(ActualWidth, ActualHeight - 1));
        drawing.DrawLine(new Pen(brush, 0.3), new Point(0, 1), new Point(ActualWidth, 1));
        DateTimeOffset start = DateTimeOffset.UtcNow.AddMinutes(-5);
        Point? previous = null; DateTimeOffset? previousTime = null;
        foreach (var sample in samples)
        {
            double x = Math.Clamp((sample.At - start).TotalSeconds / 300, 0, 1) * ActualWidth;
            double y = (1 - Math.Clamp(sample.Value / 100, 0, 1)) * (ActualHeight - 2) + 1;
            var point = new Point(x, y);
            if (previous is { } last && previousTime is { } time && sample.At - time <= TimeSpan.FromSeconds(9)) drawing.DrawLine(pen, last, point);
            else drawing.DrawEllipse(brush, null, point, 1.5, 1.5);
            previous = point; previousTime = sample.At;
        }
    }
}
