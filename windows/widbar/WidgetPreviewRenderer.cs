using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using NexoBar.Core;
using Windows.Foundation;

namespace NexoBar.Widget;

// References point only into the tree created here, never into the host's visual tree.
internal sealed class WidgetPreviewRenderer
{
    internal const double IconHeight = 16, LineHeight = 12, FontSize = 11;
    private sealed record Block(DisplayIndicator Item, Grid Cell, StackPanel Values, TextBlock[] Texts);
    private readonly List<Block> blocks = [];
    private readonly List<Grid> rows = [];
    internal IReadOnlyList<IReadOnlyList<int>> LineCounts { get; private set; } = [];
    internal double RowGap { get; private set; }
    internal double RequiredHeight => PreviewLayoutMeasurement.Required(LineCounts, IconHeight, LineHeight, 0, 0, RowGap);
    internal void Clear()
    {
        blocks.Clear(); rows.Clear(); LineCounts = [];
    }
    internal void Build(Grid root, IReadOnlyList<WidgetCell<DisplayIndicator>> cells, WidgetInstanceSettings instance,
        DisplaySnapshot options, DateTimeOffset now, Action<string>? tapped = null, bool demonstration = false)
    {
        Clear();
        root.Children.Clear(); root.RowDefinitions.Clear(); root.ColumnDefinitions.Clear();
        RowGap = Math.Clamp(options.WidgetOptions.RowGap, 0, 12);
        List<IReadOnlyList<int>> counts = [];
        foreach (var group in cells.GroupBy(cell => cell.Row))
        {
            if (rows.Count > 0) root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(RowGap) });
            var row = new Grid { VerticalAlignment = VerticalAlignment.Center };
            List<int> rowCounts = [];
            foreach (var entry in group)
            {
                row.ColumnDefinitions.Add(new ColumnDefinition());
                var item = entry.Item;
                var lines = Lines(item, instance, options, now);
                var values = new StackPanel { Orientation = Orientation.Vertical, Spacing = 0,
                    Margin = new Thickness(4, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
                var texts = lines.Select((line, i) => new TextBlock { Text = Prefix(line, i, item, instance), FontSize = FontSize,
                    LineHeight = LineHeight, LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
                    TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center }).ToArray();
                foreach (var text in texts) values.Children.Add(text);
                var cell = new Grid { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(3, 0, 3, 0),
                    Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
                cell.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); cell.ColumnDefinitions.Add(new ColumnDefinition());
                var icon = IndicatorIcon.Create(item.Id, texts[0]);
                if (icon is FrameworkElement element) element.VerticalAlignment = VerticalAlignment.Center;
                cell.Children.Add(icon); Grid.SetColumn(values, 1); cell.Children.Add(values);
                if (tapped is not null) cell.Tapped += (_, _) => tapped(item.Id);
                SetDescription(cell, item, options, now, demonstration);
                Grid.SetColumn(cell, entry.Column); row.Children.Add(cell);
                blocks.Add(new(item, cell, values, texts)); rowCounts.Add(texts.Length);
            }
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetRow(row, root.RowDefinitions.Count - 1); root.Children.Add(row); rows.Add(row); counts.Add(rowCounts);
        }
        LineCounts = counts;
    }
    internal void UpdateText(WidgetInstanceSettings instance, DisplaySnapshot options, DateTimeOffset now)
    {
        foreach (var block in blocks)
        {
            var lines = Lines(block.Item, instance, options, now);
            for (int i = 0; i < block.Texts.Length && i < lines.Count; i++)
            {
                string value = Prefix(lines[i], i, block.Item, instance);
                if (block.Texts[i].Text != value) block.Texts[i].Text = value;
            }
            SetDescription(block.Cell, block.Item, options, now, false);
        }
    }
    internal (double Top, double Bottom, bool Compressed) Bounds(Grid root)
    {
        double top = double.PositiveInfinity, bottom = double.NegativeInfinity;
        bool compressed = false;
        foreach (var row in rows)
        {
            Rect bounds = row.TransformToVisual(root).TransformBounds(new Rect(0, 0, row.ActualWidth, row.ActualHeight));
            top = Math.Min(top, bounds.Top); bottom = Math.Max(bottom, bounds.Bottom);
        }
        foreach (var block in blocks)
        {
            Rect cellBounds = block.Cell.TransformToVisual(root).TransformBounds(new Rect(0, 0, block.Cell.ActualWidth, block.Cell.ActualHeight));
            top = Math.Min(top, cellBounds.Top); bottom = Math.Max(bottom, cellBounds.Bottom);
            Rect bounds = block.Values.TransformToVisual(root).TransformBounds(new Rect(0, 0, block.Values.ActualWidth, block.Values.ActualHeight));
            top = Math.Min(top, bounds.Top); bottom = Math.Max(bottom, bounds.Bottom);
            compressed |= block.Cell.ActualHeight + .5 < Math.Max(IconHeight, block.Texts.Length * LineHeight) ||
                block.Values.ActualHeight + .5 < block.Texts.Length * LineHeight ||
                block.Texts.Any(text => text.ActualHeight + .5 < LineHeight);
            foreach (var text in block.Texts)
            {
                Rect textBounds = text.TransformToVisual(root).TransformBounds(new Rect(0, 0, text.ActualWidth, text.ActualHeight));
                top = Math.Min(top, textBounds.Top); bottom = Math.Max(bottom, textBounds.Bottom);
            }
        }
        return (rows.Count == 0 ? 0 : top, rows.Count == 0 ? 0 : bottom, compressed);
    }
    private static string Prefix(string line, int index, DisplayIndicator item, WidgetInstanceSettings instance) =>
        (index == 0 && instance.ShowNames ? item.Label + " · " : "") + line;
    private static IReadOnlyList<string> Lines(DisplayIndicator item, WidgetInstanceSettings instance, DisplaySnapshot options, DateTimeOffset now)
    {
        if (item.Reading.Unavailable is not null) return ["indisponível"];
        return item.Reading.Windows is not null ? instance.PreviewQuotaLines(item.Reading, now,
            options.DetailedCountdown, options.StackedQuotas, options.ShowQuotaReset) :
            [Presentation.Metric(item.Reading, new(item.Id, item.Label, true, item.ShowTemperature),
                new() { MemoryNominal = options.MemoryNominal })];
    }
    private static void SetDescription(Grid cell, DisplayIndicator item, DisplaySnapshot options, DateTimeOffset now, bool demo)
    {
        var lines = item.Reading.Windows is not null ? Presentation.QuotaDisplayLines(item.Reading, now, true,
            true, options.ShowQuotaReset, options.DetailedCountdown) :
            [Presentation.Metric(item.Reading, new(item.Id, item.Label, true, item.ShowTemperature), new() { MemoryNominal = options.MemoryNominal })];
        string label = item.Label;
        if (item.Id.StartsWith("gpu:", StringComparison.Ordinal) && GpuBrand.Wordmark(item.Reading.Vendor) is { } brand) label += " · " + brand;
        string description = label + " · " + string.Join(" | ", lines) + (demo ? " · demonstrativo" : "");
        if (ToolTipService.GetToolTip(cell) as string != description) ToolTipService.SetToolTip(cell, description);
        if (Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(cell) != description)
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(cell, description);
    }
}
