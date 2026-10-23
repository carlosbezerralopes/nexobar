using System.Windows;
using System.Windows.Controls;
using NexoBar.Core;
using Button = System.Windows.Controls.Button;
using CheckBox = System.Windows.Controls.CheckBox;
using ComboBox = System.Windows.Controls.ComboBox;
using MessageBox = System.Windows.MessageBox;
using Orientation = System.Windows.Controls.Orientation;
using TextBox = System.Windows.Controls.TextBox;
using Screen = System.Windows.Forms.Screen;

namespace NexoBar.Windows;

internal sealed class SettingsWindow : Window
{
    private readonly Preferences preferences;
    private readonly Func<string?> apply;
    private readonly Func<bool> widgetConnected;
    private readonly Border widgetPreview = new() { Margin = new Thickness(0, 8, 0, 8), BorderThickness = new Thickness(1), Padding = new Thickness(6) };
    private int previewPage;
    private TextBlock? widgetStatus;
    private readonly System.Windows.Threading.DispatcherTimer statusRefresh;
    internal SettingsWindow(Preferences preferences, Func<string?> apply, Func<bool>? widgetConnected = null)
    {
        this.preferences = preferences; this.apply = apply; this.widgetConnected = widgetConnected ?? (() => false);
        Title = "NexoBar · Personalizar"; Width = 750; Height = 650; MinWidth = 620; MinHeight = 400;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        statusRefresh = new System.Windows.Threading.DispatcherTimer(TimeSpan.FromSeconds(3), System.Windows.Threading.DispatcherPriority.Background,
            (_, _) => RefreshWidgetStatus(), Dispatcher);
        Loaded += (_, _) => statusRefresh.Start();
        Closed += (_, _) => statusRefresh.Stop();
        Render();
    }
    private void Render()
    {
        DesktopIntegration.Theme(this);
        var root = new DockPanel { Margin = new Thickness(18) };
        var footer = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        var save = new Button { Content = "Aplicar", Padding = new Thickness(18, 6, 18, 6) };
        save.Click += (_, _) =>
        {
            Focus();
            string? error = ValidateFolders() ?? apply();
            if (error is not null) MessageBox.Show(error, "NexoBar");
        };
        var close = new Button { Content = "Fechar", Margin = new Thickness(10, 0, 0, 0), Padding = new Thickness(18, 6, 18, 6) };
        close.Click += (_, _) => { Focus(); string? error = ValidateFolders() ?? apply(); if (error is null) Close(); else MessageBox.Show(error, "NexoBar"); };
        footer.Children.Add(save); footer.Children.Add(close);
        DockPanel.SetDock(footer, Dock.Bottom); root.Children.Add(footer);
        var panel = new StackPanel();
        panel.Children.Add(Label("Apresentação", 20));
        panel.Children.Add(Label("Os três modos podem coexistir. O ícone NexoBar de recuperação permanece na bandeja para personalizar ou sair, inclusive com os três modos desligados."));
        panel.Children.Add(Toggle("Faixa fixa junto à taskbar", preferences.Displays.BarEnabled, v => preferences.Displays.BarEnabled = v));
        panel.Children.Add(Toggle("Indicadores dinâmicos na bandeja", preferences.Displays.TrayEnabled, v => preferences.Displays.TrayEnabled = v));
        panel.Children.Add(Toggle("Widget WidBar", preferences.Displays.WidgetEnabled, v => preferences.Displays.WidgetEnabled = v));
        panel.Children.Add(Toggle("Faixa: reservar área útil (janelas maximizadas param acima dela)", preferences.Displays.BarReserveSpace, v => preferences.Displays.BarReserveSpace = v));
        panel.Children.Add(Label("Sem reserva, as janelas podem maximizar atrás da faixa. A translucidez afeta somente o fundo; o texto conserva o contraste."));
        Number(panel, "Opacidade do fundo da faixa (%)", (int)Math.Round(preferences.Displays.BarOpacity * 100), 10, 100,
            v => preferences.Displays.BarOpacity = v / 100d);
        AddWidgetOptions(panel);
        var monitors = new ComboBox { Margin = new Thickness(0, 8, 0, 8), MinWidth = 300, HorizontalAlignment = HorizontalAlignment.Left };
        monitors.Items.Add(new ComboBoxItem { Content = "Monitor principal (acompanhar o Windows)", Tag = (string?)null });
        foreach (var screen in Screen.AllScreens)
            monitors.Items.Add(new ComboBoxItem { Content = $"{screen.DeviceName} · {screen.Bounds.Width}×{screen.Bounds.Height}" + (screen.Primary ? " · principal" : ""), Tag = screen.DeviceName });
        monitors.SelectedIndex = 0;
        for (int i = 1; i < monitors.Items.Count; i++) if (((ComboBoxItem)monitors.Items[i]).Tag as string == preferences.MonitorId) monitors.SelectedIndex = i;
        monitors.SelectionChanged += (_, _) => preferences.MonitorId = ((ComboBoxItem)monitors.SelectedItem).Tag as string;
        panel.Children.Add(monitors);
        panel.Children.Add(Toggle("Memória: em uso / total (GiB)", preferences.MemoryNominal, v => preferences.MemoryNominal = v));
        panel.Children.Add(Toggle("Cotas em duas linhas (horizontal por padrão)", preferences.StackedQuotas, v => preferences.StackedQuotas = v));
        panel.Children.Add(Toggle("Detalhar tempo restante (2h13m, 3d4h)", preferences.DetailedCountdown, v => preferences.DetailedCountdown = v));
        panel.Children.Add(Toggle("Avisar renovação confirmada pela fonte", preferences.ResetAlerts, v => preferences.ResetAlerts = v));
        panel.Children.Add(Label("Tema acompanha o sistema; GPU usa a identidade física informada pelo monitor de hardware."));
        panel.Children.Add(Label("Pastas das CLIs", 17));
        panel.Children.Add(Label("Claude exige uma pasta já confiável no cliente. Escolher aqui não concede confiança; login, trust e setup interrompem a consulta. Nenhuma pasta pessoal é escolhida automaticamente."));
        AddFolder(panel, "Claude (obrigatória quando habilitado)", preferences.ClaudeWorkingDirectory, value => preferences.ClaudeWorkingDirectory = value);
        AddFolder(panel, "Codex (opcional)", preferences.CodexWorkingDirectory, value => preferences.CodexWorkingDirectory = value);
        panel.Children.Add(Label("Claude: consulta temporária a cada 5min ou por Atualizar Claude; sem terminal aberto entre consultas."));
        panel.Children.Add(Label("Indicadores · mostrar, nome, temperatura e ordem", 17));
        foreach (var pref in preferences.Indicators.ToArray())
        {
            var row = new Grid { Margin = new Thickness(0, 4, 0, 4) };
            foreach (var width in new[] { new GridLength(30), new GridLength(1, GridUnitType.Star), new GridLength(155), new GridLength(36), new GridLength(36) }) row.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
            var enabled = new CheckBox { IsChecked = pref.Enabled, VerticalAlignment = VerticalAlignment.Center };
            System.Windows.Automation.AutomationProperties.SetName(enabled, "Mostrar " + pref.Label);
            enabled.Checked += (_, _) => Replace(pref.Id, p => p with { Enabled = true });
            enabled.Unchecked += (_, _) => Replace(pref.Id, p => p with { Enabled = false });
            row.Children.Add(enabled);
            var name = new TextBox { Text = pref.Label, MaxLength = 64, Margin = new Thickness(0, 0, 12, 0), ToolTip = pref.Id };
            name.TextChanged += (_, _) => Replace(pref.Id, p => p with { Label = Preferences.SafeLabel(name.Text, pref.Id) });
            Grid.SetColumn(name, 1); row.Children.Add(name);
            if (pref.Id == "cpu" || pref.Id.StartsWith("gpu:", StringComparison.Ordinal))
            {
                var temperature = Toggle("Temperatura", pref.ShowTemperature, v => Replace(pref.Id, p => p with { ShowTemperature = v }));
                Grid.SetColumn(temperature, 2); row.Children.Add(temperature);
            }
            for (int direction = -1; direction <= 1; direction += 2)
            {
                int move = direction;
                var button = new Button { Content = move < 0 ? "↑" : "↓", Margin = new Thickness(2, 0, 2, 0), Padding = new Thickness(6, 3, 6, 3) };
                button.Click += (_, _) => { preferences.Move(pref.Id, move); Render(); };
                Grid.SetColumn(button, move < 0 ? 3 : 4); row.Children.Add(button);
            }
            panel.Children.Add(row);
        }
        panel.Children.Add(Label("GPUs desconectadas mantêm nome e ordem salvos. Elas voltam à barra quando forem detectadas novamente."));
        panel.Children.Add(Label("Sem inicialização automática ou elevação. Sensores inacessíveis e cotas ausentes aparecem como indisponíveis."));
        panel.Children.Add(Label("Claude exige o executável nativo claude.exe e uma sessão já autenticada; shims .cmd não são executados. Cursor, Grok, OpenCode Go, GLM e Antigravity não têm uma fonte segura validada no Windows."));
        root.Children.Add(new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        Content = root;
    }
    private void AddWidgetOptions(StackPanel panel)
    {
        panel.Children.Add(Label("Widget WidBar · opções independentes", 17));
        widgetStatus = Label("");
        RefreshWidgetStatus(); panel.Children.Add(widgetStatus);
        panel.Children.Add(Label("O widget lê as mesmas medições do aplicativo. Não executa sensores ou consultas de IA."));
        var layout = new ComboBox { HorizontalAlignment = HorizontalAlignment.Left, MinWidth = 220, Margin = new Thickness(0, 4, 0, 6) };
        layout.Items.Add(new ComboBoxItem { Content = "Horizontal", Tag = "horizontal" });
        layout.Items.Add(new ComboBoxItem { Content = "Duas linhas", Tag = "twoRows" });
        layout.SelectedIndex = preferences.Displays.WidgetLayout == "twoRows" ? 1 : 0;
        layout.SelectionChanged += (_, _) => { preferences.Displays.WidgetLayout = (string)((ComboBoxItem)layout.SelectedItem).Tag; PreviewWidget(); };
        panel.Children.Add(layout);
        Number(panel, "Indicadores por página", preferences.Displays.WidgetItemsPerPage, 1, 4, v => { preferences.Displays.WidgetItemsPerPage = v; previewPage = 0; PreviewWidget(); });
        Number(panel, "Largura do widget (px)", preferences.Displays.WidgetWidth, 120, 600, v => { preferences.Displays.WidgetWidth = v; PreviewWidget(); });
        panel.Children.Add(Toggle("Alternar páginas automaticamente", preferences.Displays.WidgetRotate, v => preferences.Displays.WidgetRotate = v));
        Number(panel, "Intervalo de rotação (segundos)", preferences.Displays.WidgetRotationSeconds, 2, 60, v => preferences.Displays.WidgetRotationSeconds = v);
        panel.Children.Add(Toggle("Pausar rotação com o ponteiro sobre o widget", preferences.Displays.WidgetPauseOnHover, v => preferences.Displays.WidgetPauseOnHover = v));
        panel.Children.Add(Label("Prévia com valores demonstrativos · não são medições atuais"));
        if (widgetPreview.Parent is Panel previous) previous.Children.Remove(widgetPreview);
        panel.Children.Add(widgetPreview);
        var next = new Button { Content = "Próxima página da prévia →", HorizontalAlignment = HorizontalAlignment.Left, Padding = new Thickness(10, 4, 10, 4) };
        next.Click += (_, _) => { previewPage++; PreviewWidget(); };
        panel.Children.Add(next);
        PreviewWidget();
    }
    private void RefreshWidgetStatus()
    {
        if (widgetStatus is not null) widgetStatus.Text = widgetConnected() ? "Cliente do widget ativo no canal de dados desta instância." :
            "Integração aguardando host WidBar. Ativar a opção prepara os dados; o host e o pacote do widget precisam estar instalados e ativos.";
    }
    private void PreviewWidget()
    {
        var options = preferences.Displays;
        string[] demo = ["CPU · 24%", "RAM · 12/32 GiB", "GPU · 41%", "Claude · 38%", "Codex · 12%"];
        var page = WidgetPaging.Page(demo, previewPage, options.WidgetItemsPerPage);
        var grid = new Grid();
        for (int i = 0; i < (options.WidgetLayout == "twoRows" ? 2 : 1); i++) grid.RowDefinitions.Add(new RowDefinition());
        int columns = options.WidgetLayout == "twoRows" ? (page.Count + 1) / 2 : page.Count;
        for (int i = 0; i < columns; i++) grid.ColumnDefinitions.Add(new ColumnDefinition());
        for (int i = 0; i < page.Count; i++)
        {
            var cell = WidgetPaging.Cell(i, page.Count, options.WidgetLayout);
            var label = new TextBlock { Text = page[i], TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(5), Foreground = Foreground, FontSize = 11 };
            Grid.SetRow(label, cell.Row); Grid.SetColumn(label, cell.Column); grid.Children.Add(label);
        }
        widgetPreview.Width = options.WidgetWidth; widgetPreview.HorizontalAlignment = HorizontalAlignment.Left;
        widgetPreview.BorderBrush = Foreground; widgetPreview.Child = grid;
        widgetPreview.ToolTip = $"Página {previewPage % WidgetPaging.PageCount(demo.Length, options.WidgetItemsPerPage) + 1} de {WidgetPaging.PageCount(demo.Length, options.WidgetItemsPerPage)} · valores demonstrativos";
    }
    private void Number(StackPanel panel, string title, int value, int minimum, int maximum, Action<int> changed)
    {
        var caption = Label($"{title}: {value}");
        panel.Children.Add(caption);
        var slider = new Slider { Minimum = minimum, Maximum = maximum, Value = value, TickFrequency = 1, IsSnapToTickEnabled = true,
            HorizontalAlignment = HorizontalAlignment.Left, Width = 280, Margin = new Thickness(0, 0, 0, 6) };
        System.Windows.Automation.AutomationProperties.SetName(slider, title);
        slider.ValueChanged += (_, _) => { int current = (int)Math.Round(slider.Value); caption.Text = $"{title}: {current}"; changed(current); };
        panel.Children.Add(slider);
    }
    private string? ValidateFolders() => CLIWorkingDirectories.Validate(preferences.ClaudeWorkingDirectory,
        preferences.Indicators.Any(p => p.Id == "claude" && p.Enabled), "Claude") ?? CLIWorkingDirectories.Validate(preferences.CodexWorkingDirectory, false, "Codex");
    private void AddFolder(StackPanel panel, string label, string? value, Action<string?> set)
    {
        panel.Children.Add(Label(label));
        var row = new DockPanel { Margin = new Thickness(0, 2, 0, 6) };
        var choose = new Button { Content = "Escolher…", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 4, 10, 4) };
        DockPanel.SetDock(choose, Dock.Right); row.Children.Add(choose);
        var folder = new TextBox { Text = value ?? "", MinWidth = 250, MaxLength = 4096 };
        folder.TextChanged += (_, _) => set(string.IsNullOrWhiteSpace(folder.Text) ? null : folder.Text.Trim());
        choose.Click += (_, _) =>
        {
            var dialog = new Microsoft.Win32.OpenFolderDialog { Title = "Escolha uma pasta já confiável no cliente", Multiselect = false };
            if (dialog.ShowDialog(this) == true) { folder.Text = dialog.FolderName; }
        };
        row.Children.Add(folder); panel.Children.Add(row);
    }
    private void Replace(string id, Func<IndicatorPreference, IndicatorPreference> change)
    {
        int index = preferences.Indicators.FindIndex(p => p.Id == id);
        if (index >= 0) preferences.Indicators[index] = change(preferences.Indicators[index]);
    }
    private CheckBox Toggle(string title, bool value, Action<bool> changed)
    {
        var control = new CheckBox { Content = title, IsChecked = value, Margin = new Thickness(0, 5, 0, 5), Foreground = Foreground };
        control.Checked += (_, _) => changed(true); control.Unchecked += (_, _) => changed(false); return control;
    }
    private TextBlock Label(string text, double size = 12) => new() { Text = text, TextWrapping = TextWrapping.Wrap, Foreground = Foreground, FontSize = size, Margin = new Thickness(0, 6, 0, 6) };
}
