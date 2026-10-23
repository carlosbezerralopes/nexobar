using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using NexoBar.Core;
using Application = System.Windows.Application;
using Button = System.Windows.Controls.Button;
using ContextMenu = System.Windows.Controls.ContextMenu;
using Orientation = System.Windows.Controls.Orientation;
using MenuItem = System.Windows.Controls.MenuItem;
using ToolTip = System.Windows.Controls.ToolTip;

namespace NexoBar.Windows;

internal sealed class BarWindow : Window, IDisposable
{
    private readonly string preferencesPath;
    private readonly HardwareReader hardware = new();
    private readonly AIReader ai;
    private readonly CancellationTokenSource lifetime = new();
    private readonly DispatcherTimer refresh;
    private readonly System.Windows.Forms.NotifyIcon tray;
    private readonly IndicatorTray indicatorTray;
    private readonly DisplayBridgeServer displayBridge;
    private DisplaySnapshot displaySnapshot;
    private readonly ResetWatcher resets = new();
    private readonly Dictionary<string, Reading> readings = [];
    private readonly HashSet<string> pending = [];
    private readonly Dictionary<string, DateTimeOffset> nextPoll = [];
    private readonly History history = new();
    private readonly Preferences preferences;
    private bool sensorsPending, exiting, disposed;
    private string? saveError;
    private DetailWindow? detail;
    private SettingsWindow? settings;
    private AppBarDock? docking;
    private int openMenus;
    internal BarWindow(string directory, bool isolated = false)
    {
        preferencesPath = Path.Combine(directory, "indicators.json");
        preferences = Preferences.Load(preferencesPath);
        ai = new(preferences);
        Title = "NexoBar"; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false; ShowActivated = false; Topmost = true;
        AllowsTransparency = true; SizeToContent = SizeToContent.Manual;
        SourceInitialized += (_, _) => { DesktopIntegration.NonActivating(this); docking = new AppBarDock(this, () => Render()); };
        Loaded += (_, _) => { Tick(); };
        Closing += OnClosing;
        tray = new System.Windows.Forms.NotifyIcon { Icon = System.Drawing.SystemIcons.Application, Text = "NexoBar · configurações e sair (sempre disponível)", Visible = true };
        var trayMenu = new System.Windows.Forms.ContextMenuStrip();
        trayMenu.Items.Add("Mostrar faixa", null, (_, _) => Dispatcher.Invoke(Recover));
        var barToggle = trayMenu.Items.Add("Faixa fixa", null, (_, _) => Dispatcher.Invoke(() => ToggleDisplay("bar"))) as System.Windows.Forms.ToolStripMenuItem;
        var trayToggle = trayMenu.Items.Add("Indicadores na bandeja", null, (_, _) => Dispatcher.Invoke(() => ToggleDisplay("tray"))) as System.Windows.Forms.ToolStripMenuItem;
        var widgetToggle = trayMenu.Items.Add("Widget WidBar", null, (_, _) => Dispatcher.Invoke(() => ToggleDisplay("widget"))) as System.Windows.Forms.ToolStripMenuItem;
        trayMenu.Opening += (_, _) => { barToggle!.Checked = preferences.Displays.BarEnabled; trayToggle!.Checked = preferences.Displays.TrayEnabled; widgetToggle!.Checked = preferences.Displays.WidgetEnabled; };
        trayMenu.Items.Add("Personalizar barra…", null, (_, _) => Dispatcher.Invoke(OpenSettings));
        trayMenu.Items.Add("Atualizar Claude", null, (_, _) => Dispatcher.Invoke(RefreshClaude));
        trayMenu.Items.Add("Reler cotas", null, (_, _) => Dispatcher.Invoke(Reread));
        trayMenu.Items.Add("Sair", null, (_, _) => Dispatcher.Invoke(Quit));
        tray.ContextMenuStrip = trayMenu;
        tray.MouseClick += (_, e) => { if (e.Button == System.Windows.Forms.MouseButtons.Left) Dispatcher.Invoke(OpenSettings); };
        indicatorTray = new IndicatorTray(OpenDetail, OpenSettings, Reread, Quit);
        displaySnapshot = Snapshot();
        displayBridge = new DisplayBridgeServer(() => Volatile.Read(ref displaySnapshot), isolated ? Path.GetFullPath(directory) : null);
        refresh = new DispatcherTimer(TimeSpan.FromSeconds(3), DispatcherPriority.Background, (_, _) => Tick(), Dispatcher);
        refresh.Start();
    }
    internal void Start()
    {
        // Create the message hooks without briefly showing a disabled bar.
        new System.Windows.Interop.WindowInteropHelper(this).EnsureHandle();
        if (preferences.Displays.BarEnabled) Show(); else Tick();
    }
    private void Tick()
    {
        if (disposed) return;
        history.Prune(DateTimeOffset.UtcNow);
        if (!sensorsPending)
        {
            sensorsPending = true;
            _ = ReadSensors();
        }
        foreach (var pref in preferences.Indicators.Where(p => p.Enabled && Preferences.Providers.Contains(p.Id)).ToArray())
        {
            if (pending.Contains(pref.Id) || nextPoll.GetValueOrDefault(pref.Id) > DateTimeOffset.UtcNow) continue;
            pending.Add(pref.Id);
            nextPoll[pref.Id] = DateTimeOffset.UtcNow.AddMinutes(pref.Id == "claude" ? 5 : 1);
            _ = ReadAI(pref.Id);
        }
        UpdateDisplays();
        Render();
        detail?.Refresh();
    }
    private async Task ReadSensors()
    {
        try
        {
            var values = await Task.Run(hardware.Read, lifetime.Token);
            if (disposed) return;
            var oldGpu = readings.Keys.Where(k => k.StartsWith("gpu:", StringComparison.Ordinal)).ToArray();
            foreach (string id in oldGpu) if (!values.Any(r => r.Id == id)) readings.Remove(id);
            foreach (var reading in values) { readings[reading.Id] = reading; history.Add(reading, DateTimeOffset.UtcNow); }
            if (preferences.Discover(values)) Save();
        }
        catch (OperationCanceledException) { }
        catch (Exception) { readings["cpu"] = new("cpu", "CPU", DateTimeOffset.UtcNow, Unavailable: "Falha ao ler sensores"); }
        finally { sensorsPending = false; if (!disposed) { Render(); detail?.Refresh(); } }
    }
    private async Task ReadAI(string id)
    {
        string? folder = id == "claude" ? preferences.ClaudeWorkingDirectory : id == "codex" ? preferences.CodexWorkingDirectory : null;
        // Process/pipe operations start on a worker; CLI activity never blocks the WPF dispatcher.
        var value = await Task.Run(() => ai.Read(id, lifetime.Token), lifetime.Token).ContinueWith(t =>
            t.Status == TaskStatus.RanToCompletion ? t.Result : AIReader.Unavailable(id, DateTimeOffset.UtcNow, "Consulta cancelada"), TaskScheduler.Default);
        if (disposed) return;
        pending.Remove(id);
        string? currentFolder = id == "claude" ? preferences.ClaudeWorkingDirectory : id == "codex" ? preferences.CodexWorkingDirectory : null;
        if (folder != currentFolder) { readings.Remove(id); nextPoll.Remove(id); Tick(); return; }
        readings[id] = value;
        var renewed = resets.Observe(value);
        if (preferences.ResetAlerts && renewed.Count > 0)
            tray.ShowBalloonTip(5000, "NexoBar · renovação confirmada", value.Name + ": " + string.Join(", ", renewed), System.Windows.Forms.ToolTipIcon.Info);
        Render(); detail?.Refresh();
    }
    private Reading Current(string id)
    {
        if (readings.TryGetValue(id, out var reading))
        {
            var now = DateTimeOffset.UtcNow;
            if (!Preferences.Providers.Contains(id) && now - reading.CapturedAt > TimeSpan.FromSeconds(15))
                return new(id, reading.Name, now, Source: reading.Source, Unavailable: "A leitura do sensor não responde há mais de 15s", Vendor: reading.Vendor);
            if (id != "claude" && Preferences.Providers.Contains(id) && now - reading.CapturedAt >= TimeSpan.FromMinutes(2))
                return AIReader.Unavailable(id, now, "A consulta da CLI não entregou uma leitura recente");
            if (reading.Id == "claude" && now - reading.CapturedAt >= TimeSpan.FromMinutes(6)) return AIReader.Unavailable(id, now, "A consulta Claude não entregou cotas recentes");
            if (reading.Id == "claude" && reading.Windows is { Count: > 0 } windows)
            {
                var fresh = windows.Where(w => w.ResetsAt is null || w.ResetsAt > now).ToArray();
                var headline = fresh.FirstOrDefault(w => w.AccountWindow);
                if (headline is null) return AIReader.Unavailable(id, now, "As janelas Claude venceram; aguardando nova consulta");
                reading = reading with { Windows = fresh, Percent = headline.UsedPercent };
            }
            return reading;
        }
        return new(id, preferences.Indicators.FirstOrDefault(p => p.Id == id)?.Label ?? id, DateTimeOffset.UtcNow,
            Unavailable: pending.Contains(id) || sensorsPending ? "Aguardando leitura" : id.StartsWith("gpu:", StringComparison.Ordinal) ? "GPU não encontrada nesta leitura" : "Fonte indisponível");
    }
    private void Render()
    {
        if (disposed) return;
        if (!preferences.Displays.BarEnabled)
        {
            docking?.Release();
            if (IsVisible) Hide();
            return;
        }
        if (!IsVisible) Show();
        if (!IsLoaded || openMenus > 0) return;
        DesktopIntegration.Theme(this);
        var solid = (SolidColorBrush)Background;
        var color = solid.Color;
        var backdrop = new SolidColorBrush(Color.FromArgb((byte)Math.Round(preferences.Displays.BarOpacity * 255), color.R, color.G, color.B));
        Background = Brushes.Transparent;
        var screen = DesktopIntegration.Selected(preferences.MonitorId);
        double maximum = Math.Max(200, screen.Bounds.Width / DesktopIntegration.Scale(screen) - 16);
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(3) };
        var missing = new List<IndicatorPreference>();
        double used = 6;
        foreach (var pref in preferences.Indicators.Where(p => p.Enabled && (!p.Id.StartsWith("gpu:", StringComparison.Ordinal) || readings.ContainsKey(p.Id))))
        {
            var reading = Current(pref.Id);
            var button = IndicatorButton(pref, reading);
            button.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            double width = button.DesiredSize.Width;
            if (used + width + 56 > maximum) { missing.Add(pref); continue; }
            used += width; panel.Children.Add(button);
        }
        if (missing.Count > 0)
        {
            var more = SmallButton("+" + missing.Count, () => { });
            more.Click += (_, _) =>
            {
                var menu = new ContextMenu { PlacementTarget = more };
                Track(menu);
                foreach (var pref in missing) { var item = new MenuItem { Header = pref.Label }; string id = pref.Id; item.Click += (_, _) => OpenDetail(id); menu.Items.Add(item); }
                menu.IsOpen = true;
            };
            panel.Children.Add(more);
        }
        if (panel.Children.Count == 0) panel.Children.Add(SmallButton("NexoBar", OpenSettings));
        panel.Measure(new Size(maximum, double.PositiveInfinity));
        double height = Math.Clamp(panel.DesiredSize.Height, 34, 82);
        var container = new DockPanel();
        panel.HorizontalAlignment = HorizontalAlignment.Right;
        container.Children.Add(panel);
        Content = new Border { BorderBrush = Foreground, BorderThickness = new Thickness(0.5), Background = backdrop, Child = container };
        ContextMenu = RightMenu();
        Width = maximum + 16; Height = height + 1;
        docking?.Position(screen, Height, preferences.Displays.BarEnabled, preferences.Displays.BarReserveSpace);
    }
    private Button IndicatorButton(IndicatorPreference pref, Reading reading)
    {
        var lines = new StackPanel { Orientation = Orientation.Vertical };
        var strings = Preferences.Providers.Contains(pref.Id) ? Presentation.QuotaLines(reading, preferences, DateTimeOffset.UtcNow) : [Presentation.Metric(reading, pref, preferences)];
        foreach (string text in strings) lines.Children.Add(new TextBlock { Text = text, FontSize = 11, TextTrimming = TextTrimming.None });
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        if (reading.Id.StartsWith("gpu:", StringComparison.Ordinal)) row.Children.Add(GpuBrandMark.Create(reading, Foreground, compact: true));
        row.Children.Add(new TextBlock { Text = pref.Label, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 7, 0), VerticalAlignment = VerticalAlignment.Center });
        row.Children.Add(lines);
        var button = new Button { Content = row, Padding = new Thickness(9, 5, 9, 5), Margin = new Thickness(1, 0, 1, 0), Background = Background,
            Foreground = Foreground, BorderThickness = new Thickness(0), Focusable = false, Cursor = System.Windows.Input.Cursors.Hand,
            ToolTip = new ToolTip { Content = pref.Label + " · " + (reading.Unavailable ?? reading.Source) } };
        button.Click += (_, _) => OpenDetail(pref.Id);
        System.Windows.Automation.AutomationProperties.SetName(button, pref.Label + " · abrir detalhes");
        return button;
    }
    private Button SmallButton(string text, Action action)
    {
        var button = new Button { Content = text, Foreground = Foreground, Background = Background, Padding = new Thickness(10, 5, 10, 5), Focusable = false };
        button.Click += (_, _) => action(); return button;
    }
    private ContextMenu RightMenu()
    {
        var menu = new ContextMenu();
        Track(menu);
        Add("Personalizar barra…", OpenSettings);
        Add("Atualizar Claude", RefreshClaude);
        Add("Reler cotas", Reread);
        AddToggle("Faixa fixa", preferences.Displays.BarEnabled, () => ToggleDisplay("bar"));
        AddToggle("Indicadores na bandeja", preferences.Displays.TrayEnabled, () => ToggleDisplay("tray"));
        AddToggle("Widget WidBar", preferences.Displays.WidgetEnabled, () => ToggleDisplay("widget"));
        menu.Items.Add(new Separator());
        Add("Sair", Quit);
        return menu;
        void AddToggle(string title, bool selected, Action action) { var item = new MenuItem { Header = title, IsChecked = selected }; item.Click += (_, _) => action(); menu.Items.Add(item); }
        void Add(string title, Action action) { var item = new MenuItem { Header = title }; item.Click += (_, _) => action(); menu.Items.Add(item); }
    }
    private void Track(ContextMenu menu)
    {
        menu.Opened += (_, _) => openMenus++;
        menu.Closed += (_, _) => { openMenus = Math.Max(0, openMenus - 1); Render(); };
    }
    internal void OpenSettings()
    {
        if (settings is { IsVisible: true }) { settings.Activate(); return; }
        string? claudeFolder = preferences.ClaudeWorkingDirectory;
        string? codexFolder = preferences.CodexWorkingDirectory;
        settings = new SettingsWindow(preferences, () =>
        {
            Save();
            if (claudeFolder != preferences.ClaudeWorkingDirectory)
            {
                readings.Remove("claude"); nextPoll.Remove("claude");
                claudeFolder = preferences.ClaudeWorkingDirectory;
            }
            if (codexFolder != preferences.CodexWorkingDirectory)
            {
                readings.Remove("codex"); nextPoll.Remove("codex");
                codexFolder = preferences.CodexWorkingDirectory;
            }
            Tick();
            return saveError;
        }, () => displayBridge.HasClient);
        settings.Show();
    }
    private void OpenDetail(string id)
    {
        detail?.Close();
        detail = new DetailWindow(() => Current(id), () => preferences.Indicators.First(p => p.Id == id).Label,
            () => history.Get(id, DateTimeOffset.UtcNow), OpenSettings, () => { nextPoll.Remove(id); Tick(); });
        detail.Show();
    }
    private void Save()
    {
        try { preferences.Save(preferencesPath); saveError = null; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { saveError = "Não foi possível salvar as preferências nesta pasta."; }
    }
    private void RefreshClaude() { nextPoll.Remove("claude"); Tick(); }
    private void Reread() { nextPoll.Clear(); hardware.Rediscover(); Tick(); }
    private void Recover() { preferences.Displays.BarEnabled = true; Save(); Tick(); }
    private void ToggleDisplay(string mode)
    {
        if (mode == "bar") preferences.Displays.BarEnabled = !preferences.Displays.BarEnabled;
        else if (mode == "tray") preferences.Displays.TrayEnabled = !preferences.Displays.TrayEnabled;
        else preferences.Displays.WidgetEnabled = !preferences.Displays.WidgetEnabled;
        Save(); Tick();
    }
    private void UpdateDisplays()
    {
        var values = preferences.Indicators.Where(p => !p.Id.StartsWith("gpu:", StringComparison.Ordinal) || readings.ContainsKey(p.Id))
            .Select(p => Current(p.Id)).ToArray();
        indicatorTray.Update(preferences, values);
        Volatile.Write(ref displaySnapshot, Snapshot());
    }
    private DisplaySnapshot Snapshot()
    {
        var options = preferences.Displays;
        var indicators = options.WidgetEnabled ? preferences.Indicators.Where(p => p.Enabled &&
            (!p.Id.StartsWith("gpu:", StringComparison.Ordinal) || readings.ContainsKey(p.Id))).Select(p =>
        {
            var reading = Current(p.Id);
            return new DisplayIndicator(p.Id, p.Label, reading with { Source = "", Activity = "Atividade não informada pela fonte",
                Unavailable = reading.Unavailable is null ? null : "Fonte indisponível" }, p.ShowTemperature);
        }).ToArray() : [];
        return new DisplaySnapshot(1, DateTimeOffset.UtcNow, options.WidgetEnabled,
            new DisplayWidgetOptions(options.WidgetItemsPerPage, options.WidgetLayout, options.WidgetRotationSeconds,
                options.WidgetRotate, options.WidgetWidth, options.WidgetPauseOnHover,
                WidgetPaging.NormalizePlacements(options.WidgetPlacements), options.WidgetRowGap), Array.AsReadOnly(indicators),
            preferences.MemoryNominal, preferences.StackedQuotas, preferences.DetailedCountdown, preferences.ShowQuotaReset);
    }
    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (!exiting) { e.Cancel = true; preferences.Displays.BarEnabled = false; Save(); docking?.Release(); Hide(); }
    }
    private void Quit() { exiting = true; Dispose(); Close(); Application.Current.Shutdown(); }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true; refresh.Stop(); lifetime.Cancel(); ai.Dispose(); docking?.Dispose(); displayBridge.Dispose(); indicatorTray.Dispose(); tray.Visible = false; tray.ContextMenuStrip?.Dispose(); tray.Dispose();
        // Sensor update owns the hardware lock; disposal runs off-dispatcher and cannot freeze shutdown.
        _ = Task.Run(hardware.Dispose);
        detail?.Close(); settings?.Close();
    }
}
