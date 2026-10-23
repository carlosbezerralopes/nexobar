using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using NexoBar.Core;
using WidBar.SDK;

namespace NexoBar.Widget;

public sealed class MainPlugin : WidgetPluginBase, IConfigurableWidgetPlugin, IWidgetFlyoutLifecycle
{
    private Grid? preview;
    private StackPanel? detail;
    private DisplaySnapshot? snapshot;
    private readonly WidgetAvailabilityPolicy availability = new();
    private readonly DispatcherQueue dispatcher = DispatcherQueue.GetForCurrentThread();
    private readonly DispatcherTimer renderTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private CancellationTokenSource? polling;
    private Task? pollTask;
    private bool hover, flyoutOpen, disposed;
    private int page;
    private string? selectedId;
    private DateTimeOffset lastRotation = DateTimeOffset.UtcNow;
    public override string Id => "com.nexobar.indicators";
    public override string Name => "NexoBar";
    public override string Version => "0.4.0";
    public override int PreviewLogicalWidth => snapshot?.WidgetOptions.Width ?? 320;
    public override int FlyoutWidth => 390;
    public override int FlyoutHeight => 420;
    // Offline is visible with an explanation. Explicitly disabled releases the slot.
    public override bool IsPreviewVisible => availability.IsPreviewVisible;

    public override async Task InitializeAsync(IWidgetContext context)
    {
        await base.InitializeAsync(context);
        context.PreviewVisibilityChanged += VisibilityChanged;
        renderTimer.Tick += RenderTick;
        SetActive(context.IsPreviewVisible);
    }
    public override UIElement? CreatePreviewContent()
    {
        preview = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        preview.PointerEntered += (_, _) => hover = true;
        preview.PointerExited += (_, _) => { hover = false; lastRotation = DateTimeOffset.UtcNow; };
        Render();
        return preview;
    }
    public override UIElement? CreateFlyoutContent()
    {
        detail = new StackPanel { Padding = new Thickness(20), Spacing = 10 };
        RenderDetail();
        return new ScrollViewer { Content = detail, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    }
    public UIElement? CreateSettingsContent(IWidgetSettingsContext context) => new TextBlock {
        Text = "Configure indicadores, ordem, páginas, rotação e largura em NexoBar → Personalizar barra → WidBar. O aplicativo principal precisa estar aberto. Este widget só lê as métricas publicadas por ele.",
        TextWrapping = TextWrapping.Wrap, Margin = new Thickness(20)
    };
    public void OnFlyoutShown()
    {
        flyoutOpen = true;
        selectedId ??= VisibleItems().FirstOrDefault()?.Id;
        SetActive(true);
        RenderDetail();
    }
    public void OnFlyoutHidden()
    {
        flyoutOpen = false;
        selectedId = null;
        lastRotation = DateTimeOffset.UtcNow;
        SetActive(Context?.IsPreviewVisible ?? false);
    }
    private void VisibilityChanged(object? sender, bool visible) => SetActive(visible || flyoutOpen);
    private void SetActive(bool active)
    {
        if (disposed) return;
        // A host may hide the disabled slot (including while a flyout closes).
        // Preserve the availability probe so the main application's next enable can restore it.
        active |= availability.KeepAvailabilityProbe;
        if (active)
        {
            if (polling is not null) return;
            polling = new CancellationTokenSource();
            pollTask = PollAsync(polling.Token);
        }
        else
        {
            polling?.Cancel();
            polling?.Dispose();
            polling = null;
            renderTimer.Stop();
            snapshot = null;
            preview?.Children.Clear();
            detail?.Children.Clear();
        }
    }
    private async Task PollAsync(CancellationToken token)
    {
        try
        {
            while (!token.IsCancellationRequested)
            {
                // Ephemeral, read-only connection. Never launches the main app or an AI client.
                var next = await DisplayBridge.ReadAsync(token).ConfigureAwait(false);
                if (token.IsCancellationRequested) break;
                dispatcher.TryEnqueue(() => {
                    if (disposed || token.IsCancellationRequested) return;
                    int previousWidth = PreviewLogicalWidth;
                    bool previousVisibility = IsPreviewVisible;
                    snapshot = next;
                    availability.Observe(next?.WidgetEnabled);
                    if (next?.WidgetEnabled == true) renderTimer.Start(); else renderTimer.Stop();
                    Render();
                    if (previousWidth != PreviewLogicalWidth || previousVisibility != IsPreviewVisible)
                        Context?.RequestPreviewRefresh();
                });
                // Remains only a low-cost availability probe when disabled; no pipe remains open.
                await Task.Delay(TimeSpan.FromSeconds(3), token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) { }
    }
    private void RenderTick(object? sender, object e)
    {
        var now = DateTimeOffset.UtcNow;
        bool changed = false;
        if (snapshot is not null && !DisplayBridge.IsFresh(snapshot, now))
        {
            int width = PreviewLogicalWidth;
            snapshot = null;
            changed = true;
            if (width != PreviewLogicalWidth) Context?.RequestPreviewRefresh();
        }
        if (snapshot is { WidgetEnabled: true } value && value.WidgetOptions.Rotate && !flyoutOpen &&
            !(hover && value.WidgetOptions.PauseOnHover) && now - lastRotation >= TimeSpan.FromSeconds(value.WidgetOptions.RotationSeconds))
        {
            page++;
            changed = true;
            lastRotation = now;
        }
        if (changed) Render(); else RenderDetail();
    }
    private IReadOnlyList<DisplayIndicator> VisibleItems() => snapshot is { WidgetEnabled: true } value &&
        DisplayBridge.IsFresh(value, DateTimeOffset.UtcNow) ?
        WidgetPaging.Page(value.Indicators, page, value.WidgetOptions.ItemsPerPage) : [];
    private static TextBlock Text(string value, double fontSize = 12) => new() {
        Text = value, FontSize = fontSize, TextTrimming = TextTrimming.CharacterEllipsis,
        VerticalAlignment = VerticalAlignment.Center
    };
    private void Render()
    {
        if (preview is not null)
        {
            preview.Children.Clear(); preview.RowDefinitions.Clear(); preview.ColumnDefinitions.Clear();
            if (IsPreviewVisible)
            {
                var items = VisibleItems();
                if (items.Count == 0) preview.Children.Add(Text("NexoBar · indisponível"));
                else for (int i = 0; i < items.Count; i++)
                {
                    var item = items[i];
                    string label = item.Label;
                    if (item.Id.StartsWith("gpu:", StringComparison.Ordinal) && GpuBrand.Wordmark(item.Reading.Vendor) is { } brand)
                        label = brand + " · " + label;
                    var (row, column) = WidgetPaging.Cell(i, items.Count, snapshot!.WidgetOptions.Layout);
                    while (preview.RowDefinitions.Count <= row) preview.RowDefinitions.Add(new RowDefinition());
                    while (preview.ColumnDefinitions.Count <= column) preview.ColumnDefinitions.Add(new ColumnDefinition());
                    var lines = Summary(item);
                    var panel = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 4, 0) };
                    if (snapshot.WidgetOptions.Layout == "twoRows")
                        panel.Children.Add(Text(label + " · " + string.Join(" | ", lines), 11));
                    else
                    {
                        panel.Children.Add(Text(label, 10));
                        foreach (string line in lines) panel.Children.Add(Text(line, lines.Count > 1 ? 10 : 12));
                    }
                    // Tapped runs before WidBar opens its flyout; capture identity, never a rotating index.
                    panel.Tapped += (_, _) => { selectedId = item.Id; RenderDetail(); Context?.RequestOpenFlyout(); };
                    var tooltipLines = item.Reading.Windows is not null ?
                        Presentation.QuotaLines(item.Reading, PresentationOptions(), DateTimeOffset.UtcNow) : lines;
                    ToolTipService.SetToolTip(panel, label + " · " + string.Join(" | ", tooltipLines));
                    Grid.SetRow(panel, row); Grid.SetColumn(panel, column); preview.Children.Add(panel);
                }
            }
        }
        RenderDetail();
    }
    private Preferences PresentationOptions() => new() { MemoryNominal = snapshot?.MemoryNominal ?? true,
        StackedQuotas = snapshot?.StackedQuotas ?? false, DetailedCountdown = snapshot?.DetailedCountdown ?? false };
    private IReadOnlyList<string> Summary(DisplayIndicator item)
    {
        if (item.Reading is null || item.Reading.Unavailable is not null) return ["indisponível"];
        var reading = item.Reading;
        var prefs = PresentationOptions();
        if (reading.Windows is { } windows)
        {
            var values = windows.Where(w => w.AccountWindow).Select(w => Presentation.QuotaValue(w) +
                (w.ResetsAt is null ? "" : " · " + Presentation.Countdown(w.ResetsAt, DateTimeOffset.UtcNow, prefs.DetailedCountdown))).ToArray();
            if (values.Length == 0) return ["—"];
            return prefs.StackedQuotas && snapshot?.WidgetOptions.Layout != "twoRows" ? values : [string.Join(" | ", values)];
        }
        return [Presentation.Metric(reading, new(item.Id, item.Label, true, item.ShowTemperature), prefs)];
    }
    private void RenderDetail()
    {
        if (detail is null) return;
        detail.Children.Clear();
        var item = DisplayBridge.IsFresh(snapshot, DateTimeOffset.UtcNow) && snapshot!.WidgetEnabled ?
            snapshot.Indicators.FirstOrDefault(x => x.Id == selectedId) : null;
        detail.Children.Add(Text(item?.Label ?? "NexoBar", 20));
        if (item is null || item.Reading is null || item.Reading.Unavailable is not null)
        {
            detail.Children.Add(new TextBlock { Text = "Indisponível. Abra o NexoBar e habilite o modo WidBar. O indicador selecionado precisa estar habilitado.", TextWrapping = TextWrapping.Wrap });
            return;
        }
        var reading = item.Reading;
        if (reading.Windows is { } windows)
        {
            foreach (var window in windows)
            {
                detail.Children.Add(Text(window.Label + " · " + Presentation.QuotaValue(window), 16));
                if (window.ResetsAt is { } reset)
                    detail.Children.Add(Text("Renovação: " + reset.ToLocalTime().ToString("g") + " · " + Presentation.Countdown(reset, DateTimeOffset.UtcNow, true)));
            }
            detail.Children.Add(new TextBlock { Text = "Atividade não informada pela fonte", TextWrapping = TextWrapping.Wrap });
        }
        else
        {
            detail.Children.Add(Text(Presentation.Metric(reading, new(item.Id, item.Label, true, true), PresentationOptions()), 20));
            if (reading.UsedBytes is not null || reading.TotalBytes is not null)
                detail.Children.Add(Text(Presentation.Bytes(reading.UsedBytes) + " / " + Presentation.Bytes(reading.TotalBytes)));
        }
        detail.Children.Add(Text("Leitura: " + reading.CapturedAt.ToLocalTime().ToString("T"), 10));
    }
    public override async ValueTask DisposeAsync()
    {
        disposed = true;
        if (Context is not null) Context.PreviewVisibilityChanged -= VisibilityChanged;
        renderTimer.Stop(); renderTimer.Tick -= RenderTick;
        polling?.Cancel();
        if (pollTask is not null) await pollTask.ConfigureAwait(false);
        polling?.Dispose(); polling = null;
        snapshot = null; preview = null; detail = null;
    }
}
