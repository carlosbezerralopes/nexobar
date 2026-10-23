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
    private readonly WidgetPreviewRenderer renderer = new();
    private PreviewLayoutMeasurement? measurement;
    private bool measurementDirty, measurementCurrent;
    private int generation, layoutRevision;
    private string? layoutShape;
    private event Action? PreviewChanged;
    private StackPanel? detail;
    private readonly List<(TextBlock Text, DateTimeOffset Reset)> detailCountdowns = [];
    private DisplaySnapshot? snapshot;
    private DisplaySnapshot? settingsVisualOptions;
    private WidgetInstanceSettings instanceSettings = WidgetInstanceSettings.Parse(null);
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
    public override string Version => "0.6.0";
    public override int PreviewLogicalWidth => instanceSettings.EffectiveWidth(snapshot?.WidgetOptions.Width ?? settingsVisualOptions?.WidgetOptions.Width);
    public override int FlyoutWidth => 390;
    public override int FlyoutHeight => 420;
    // Offline is visible with an explanation. Explicitly disabled releases the slot.
    public override bool IsPreviewVisible => availability.IsPreviewVisible;

    public override async Task InitializeAsync(IWidgetContext context)
    {
        instanceSettings = WidgetInstanceSettings.Parse(context.SettingsJson);
        await base.InitializeAsync(context);
        context.PreviewVisibilityChanged += VisibilityChanged;
        renderTimer.Tick += RenderTick;
        SetActive(context.IsPreviewVisible);
    }
    public override UIElement? CreatePreviewContent()
    {
        DisconnectPreview();
        generation++;
        preview = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        preview.Loaded += PreviewLoaded; preview.Unloaded += PreviewUnloaded;
        preview.SizeChanged += PreviewSizeChanged; preview.LayoutUpdated += PreviewLayoutUpdated;
        hover = false;
        preview.PointerEntered += PreviewPointerEntered;
        preview.PointerExited += PreviewPointerExited;
        Render();
        return preview;
    }
    public override UIElement? CreateFlyoutContent()
    {
        detail = new StackPanel { Padding = new Thickness(20), Spacing = 10 };
        RenderDetail();
        return new ScrollViewer { Content = detail, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    }
    public UIElement? CreateSettingsContent(IWidgetSettingsContext context) => new WidgetSettingsView(context,
        WidgetInstanceSettings.Parse(context.SettingsJson), () => settingsVisualOptions, ReadMeasurement,
        listener => { PreviewChanged += listener; return () => PreviewChanged -= listener; });
    public override void OnSettingsDraftChanged(string settingsJson)
    {
        // WidBar also calls this with the original JSON on Cancel. Never persist from this callback.
        instanceSettings = WidgetInstanceSettings.Parse(settingsJson);
        Render(); Context?.RequestPreviewRefresh();
    }
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
    private void VisibilityChanged(object? sender, bool visible)
    {
        if (!visible) InvalidateMeasurement(); else measurementDirty = true;
        SetActive(visible || flyoutOpen);
    }
    private string ReadMeasurement() => measurement?.Caption(measurementCurrent &&
        measurement.Generation == generation && measurement.LayoutRevision == layoutRevision) ??
        "Altura do preview ainda não medida. Exiba o widget para conferir o espaço.";
    private void InvalidateMeasurement()
    {
        measurementCurrent = false;
        measurement = measurement?.Invalidate();
        PreviewChanged?.Invoke();
    }
    private void PreviewLoaded(object sender, RoutedEventArgs e) => measurementDirty = true;
    private void PreviewUnloaded(object sender, RoutedEventArgs e) => InvalidateMeasurement();
    private void PreviewSizeChanged(object sender, SizeChangedEventArgs e) => measurementDirty = true;
    private void PreviewPointerEntered(object sender, PointerRoutedEventArgs e) => hover = true;
    private void PreviewPointerExited(object sender, PointerRoutedEventArgs e)
    { hover = false; lastRotation = DateTimeOffset.UtcNow; }
    private void PreviewLayoutUpdated(object? sender, object e)
    {
        if (!measurementDirty || preview is null) return;
        measurementDirty = false;
        bool visible = Context?.IsPreviewVisible == true && snapshot?.WidgetEnabled == true &&
            DisplayBridge.IsFresh(snapshot, DateTimeOffset.UtcNow) && renderer.LineCounts.Count > 0;
        if (!preview.IsLoaded || !visible) { InvalidateMeasurement(); return; }
        var bounds = renderer.Bounds(preview);
        var next = PreviewLayoutMeasurement.Measure(generation, layoutRevision, layoutRevision,
            preview.IsLoaded, visible, preview.ActualWidth, preview.ActualHeight, preview.DesiredSize.Height,
            renderer.RequiredHeight, renderer.LineCounts.Count, renderer.LineCounts.SelectMany(row => row).DefaultIfEmpty(0).Max(),
            renderer.RowGap, bounds.Top, bounds.Bottom, bounds.Compressed);
        if (next.State == PreviewLayoutState.NotMeasured) { InvalidateMeasurement(); return; }
        bool changed = !measurementCurrent || measurement is null ||
            measurement with { MeasuredAt = next.MeasuredAt } != next;
        measurement = next; measurementCurrent = true;
        if (changed) PreviewChanged?.Invoke();
    }
    private void DisconnectPreview()
    {
        if (preview is null) return;
        preview.Loaded -= PreviewLoaded; preview.Unloaded -= PreviewUnloaded;
        preview.SizeChanged -= PreviewSizeChanged; preview.LayoutUpdated -= PreviewLayoutUpdated;
        preview.PointerEntered -= PreviewPointerEntered; preview.PointerExited -= PreviewPointerExited;
        renderer.Clear();
        InvalidateMeasurement();
    }
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
            InvalidateMeasurement();
            renderer.Clear();
            preview?.Children.Clear();
            detail?.Children.Clear();
            detailCountdowns.Clear();
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
                    if (snapshot?.WidgetOptions.Layout != next?.WidgetOptions.Layout ||
                        snapshot?.WidgetOptions.ItemsPerPage != next?.WidgetOptions.ItemsPerPage)
                    { page = 0; lastRotation = DateTimeOffset.UtcNow; }
                    snapshot = next;
                    if (next is not null) settingsVisualOptions = next with { Indicators = next.Indicators.Select(item =>
                        item with { Reading = PresentationDemo.Reading(item.Id, item.Label) }).ToArray() };
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
        if (changed) Render();
        else
        {
            if (snapshot is { WidgetEnabled: true } current) renderer.UpdateText(instanceSettings, current, now);
            foreach (var entry in detailCountdowns)
            {
                string text = ResetDetail(entry.Reset, now);
                if (entry.Text.Text != text) entry.Text.Text = text;
            }
        }
    }
    private IReadOnlyList<WidgetCell<DisplayIndicator>> VisibleCells() => snapshot is { WidgetEnabled: true } value &&
        DisplayBridge.IsFresh(value, DateTimeOffset.UtcNow) ?
        WidgetPaging.LayoutPage(value.Indicators, x => x.Id, page, value.WidgetOptions.ItemsPerPage,
            value.WidgetOptions.Layout, value.WidgetOptions.Placements) : [];
    private IReadOnlyList<DisplayIndicator> VisibleItems() => VisibleCells().Select(x => x.Item).ToArray();
    private static TextBlock Text(string value, double fontSize = 12) => new() {
        Text = value, FontSize = fontSize, TextTrimming = TextTrimming.CharacterEllipsis,
        VerticalAlignment = VerticalAlignment.Center
    };
    private void Render()
    {
        if (preview is not null)
        {
            var cells = VisibleCells();
            string shape = System.Text.Json.JsonSerializer.Serialize(new {
                Options = snapshot?.WidgetOptions, snapshot?.MemoryNominal, snapshot?.StackedQuotas,
                snapshot?.DetailedCountdown, snapshot?.ShowQuotaReset, instanceSettings.ShowNames,
                Width = PreviewLogicalWidth, Page = page,
                Cells = cells.Select(cell => new { cell.Row, cell.Column, cell.Item.Id, cell.Item.ShowTemperature,
                    Lines = cell.Item.Reading.Windows?.Count(window => window.AccountWindow) ?? 1 }) });
            if (layoutShape != shape) { layoutRevision++; layoutShape = shape; InvalidateMeasurement(); }
            measurementCurrent = false;
            if (IsPreviewVisible && snapshot is { WidgetEnabled: true } value && cells.Count > 0)
                renderer.Build(preview, cells, instanceSettings, value, DateTimeOffset.UtcNow,
                    id => { selectedId = id; RenderDetail(); Context?.RequestOpenFlyout(); });
            else
            {
                renderer.Clear();
                preview.Children.Clear(); preview.RowDefinitions.Clear(); preview.ColumnDefinitions.Clear();
                if (IsPreviewVisible) preview.Children.Add(Text("NexoBar · indisponível"));
                InvalidateMeasurement();
            }
            measurementDirty = true;
        }
        PreviewChanged?.Invoke();
        RenderDetail();
    }
    private Preferences PresentationOptions() => new() { MemoryNominal = snapshot?.MemoryNominal ?? true,
        StackedQuotas = snapshot?.StackedQuotas ?? false, DetailedCountdown = snapshot?.DetailedCountdown ?? false,
        ShowQuotaReset = snapshot?.ShowQuotaReset ?? true };
    private void RenderDetail()
    {
        if (detail is null) return;
        detailCountdowns.Clear();
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
                {
                    var countdown = Text(ResetDetail(reset, DateTimeOffset.UtcNow));
                    detail.Children.Add(countdown); detailCountdowns.Add((countdown, reset));
                }
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
    private static string ResetDetail(DateTimeOffset reset, DateTimeOffset now) =>
        "Renovação: " + reset.ToLocalTime().ToString("g") + " · " + Presentation.Countdown(reset, now, true);
    public override async ValueTask DisposeAsync()
    {
        disposed = true;
        if (Context is not null) Context.PreviewVisibilityChanged -= VisibilityChanged;
        renderTimer.Stop(); renderTimer.Tick -= RenderTick;
        polling?.Cancel();
        if (pollTask is not null) await pollTask.ConfigureAwait(false);
        polling?.Dispose(); polling = null;
        DisconnectPreview(); PreviewChanged = null;
        detailCountdowns.Clear();
        snapshot = null; settingsVisualOptions = null; preview = null; detail = null;
    }
}
