using System.ComponentModel;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using NexoBar.Setup.Core;

namespace NexoBar.Setup;

public sealed class SetupWindow : Window
{
    readonly StackPanel body = new() { Margin = new Thickness(28) };
    readonly CheckBox bar = Choice("Faixa junto à barra de tarefas"), tray = Choice("Ícones por indicador na bandeja"), widget = Choice("Widget no WidBar");
    readonly CheckBox autostart = Choice("Iniciar NexoBar ao entrar no Windows (opcional)");
    readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 16, 0, 10) };
    readonly Button next = new() { Content = "Revisar instalação", Padding = new Thickness(16, 8, 16, 8), HorizontalAlignment = HorizontalAlignment.Left };
    readonly Button cancel = new() { Content = "Cancelar", Padding = new Thickness(16, 8, 16, 8), Margin = new Thickness(12, 0, 0, 0) };
    SetupPayload? payload; readonly PackageDeployment deployment = new(); WindowsInstallServices services = null!;
    InstallEnvironment environment = null!; InstallTransaction transaction = null!; byte[]? observed;
    bool autoChanged, running, reviewing, finished; CancellationTokenSource? cancellation; string? installedExe;
    static CheckBox Choice(string label) => new() { Content = label, Margin = new Thickness(0, 7, 0, 7) };
    public SetupWindow()
    {
        Title = "Instalar NexoBar 0.5.0"; Width = 700; Height = 650; MinWidth = 600; MinHeight = 480; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Content = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        body.Children.Add(new TextBlock { Text = "NexoBar", FontSize = 30, FontWeight = FontWeights.SemiBold });
        body.Children.Add(new TextBlock { Text = "Hardware e cotas à vista · Windows 11 x64", Margin = new Thickness(0, 4, 0, 18) });
        foreach (var control in new[] { bar, tray, widget, autostart }) body.Children.Add(control);
        var store = new Button { Content = "WidBar na Microsoft Store — informações e licença", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 8) };
        store.Click += (_, _) => OpenUrl(PackageDeployment.StoreUrl); body.Children.Add(store);
        body.Children.Add(new TextBlock { Text = "WidBar é um produto separado. Ao selecionar Widget e instalar, você solicita a instalação do host oficial pela Store/winget, conforme os termos exibidos na Store. O companion NexoBar será instalado para seu usuário. Nenhuma consulta de IA será feita pelo instalador.", TextWrapping = TextWrapping.Wrap });
        body.Children.Add(status); var buttons = new StackPanel { Orientation = Orientation.Horizontal }; buttons.Children.Add(next); buttons.Children.Add(cancel); body.Children.Add(buttons);
        autostart.Click += (_, _) => autoChanged = true;
        foreach (var choice in new[] { bar, tray, widget, autostart }) choice.Click += (_, _) => {
            if (reviewing) { reviewing = false; next.Content = "Revisar instalação"; status.Text = "Escolhas alteradas. Revise novamente antes de instalar."; }
        };
        next.Click += async (_, _) => { if (finished) { Close(); return; } if (!reviewing) Review(); else await Install(); };
        cancel.Click += (_, _) => { if (running) { cancellation?.Cancel(); status.Text = "Cancelamento solicitado. O aplicativo já confirmado é preservado; componentes pendentes podem ser retomados."; } else Close(); };
        next.IsEnabled = false;
        Closing += OnClosing; Loaded += async (_, _) => await Initialize();
    }
    async Task Initialize()
    {
        running = true; cancellation = new(); status.Text = "Conferindo o conteúdo incorporado do instalador…";
        try
        {
            payload = await Task.Run(() => new SetupPayload(cancellation.Token)); services = new(deployment); environment = WindowsInstallServices.EnvironmentForUser(services);
            transaction = new(environment, payload.Manifest, payload.ManifestHash);
            RefreshPreferences(); status.Text = "Escolha os modos. Os indicadores de IA começam desligados em uma instalação nova."; next.IsEnabled = true;
        }
        catch (Exception e) { status.Text = e.Message; next.IsEnabled = false; }
        finally { running = false; cancellation.Dispose(); cancellation = null; }
    }
    void RefreshPreferences()
    {
        SafePaths.NoReparseParents(environment.Preferences);
        observed = File.Exists(environment.Preferences) ? File.ReadAllBytes(environment.Preferences) : null;
        bar.IsChecked = true; tray.IsChecked = widget.IsChecked = false;
        try
        {
            var root = observed is null ? null : JsonNode.Parse(observed);
            if (root?["SchemaVersion"]?.GetValue<int>() == 1)
            {
                bar.IsChecked = root["Displays"]?["BarEnabled"]?.GetValue<bool>() ?? true;
                tray.IsChecked = root["Displays"]?["TrayEnabled"]?.GetValue<bool>() ?? false;
                widget.IsChecked = root["Displays"]?["WidgetEnabled"]?.GetValue<bool>() ?? false;
            }
        }
        catch (Exception e) when (e is System.Text.Json.JsonException or InvalidOperationException or FormatException) { }
        autostart.IsChecked = File.Exists(environment.StartupShortcut); autoChanged = false;
    }
    void Review()
    {
        try
        {
            if (services.IsAppRunning()) throw new IOException("NexoBar está em execução. Use Sair no menu do aplicativo; depois clique Verificar novamente. Nenhum processo será encerrado.");
            if (!PreferencesPatch.Matches(environment.Preferences, observed)) { RefreshPreferences(); throw new IOException("As preferências mudaram e foram relidas. Confira as escolhas e revise novamente."); }
            var plan = transaction.Plan();
            if (plan.Kind is InstallKind.RefuseDowngrade or InstallKind.UnknownCollision or InstallKind.Repair) throw new IOException(plan.Message);
            using var cert = payload!.PublicCertificate();
            var signature = SignatureVerifier.Verify(payload.Companion, payload.Manifest.CompanionName, payload.Manifest.CompanionPublisher, payload.Manifest.CompanionVersion, cert);
            if (!signature.Integrity) throw new IOException("Falha na integridade do companion: " + signature.Detail);
            status.Text = $"Destino: {plan.Target}\n{plan.Message}\nFaixa: {Yes(bar)} · Bandeja: {Yes(tray)} · Widget: {Yes(widget)}\nInicialização automática: {(autoChanged ? Yes(autostart) : "preservar opção atual")}\n{signature.Detail}\nO widget será adicionado manualmente pelo catálogo do WidBar.\nClique Instalar para confirmar as escolhas.";
            reviewing = true; next.Content = "Instalar";
        }
        catch (Exception e) { status.Text = e.Message; next.Content = "Verificar novamente"; reviewing = false; }
    }
    static string Yes(CheckBox c) => c.IsChecked == true ? "sim" : "não";
    async Task<bool> EnsureTrust()
    {
        using var cert = payload!.PublicCertificate();
        var signature = SignatureVerifier.Verify(payload.Companion, payload.Manifest.CompanionName, payload.Manifest.CompanionPublisher, payload.Manifest.CompanionVersion, cert);
        if (!signature.Integrity) throw new IOException(signature.Detail);
        if (signature.Trusted) return true;
        if (cert is null) { status.Text = "Certificado público não incluído. Instale apenas o aplicativo e retome após obter um pacote confiável."; return false; }
        string details = $"Autorizar somente este certificado público no repositório TrustedPeople da máquina? O Windows solicitará UAC.\n\nSubject: {cert.Subject}\nIssuer: {cert.Issuer}\nValidade: {cert.NotBefore:O} até {cert.NotAfter:O}\nSHA256 do certificado: {Convert.ToHexStringLower(SHA256.HashData(cert.RawData))}\nPacote: NexoBar.Widget {payload.Manifest.CompanionVersion}\nSHA256 do MSIX: {InstallManifest.HashFile(payload.Companion)}\n\nIsso confia neste publisher para instalação. Nenhuma chave privada é importada. Se recusar/cancelar, o aplicativo pode ser instalado e o widget ficará pendente.";
        if (MessageBox.Show(this, details, "Confiança específica no publisher NexoBar", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) != MessageBoxResult.Yes) return false;
        try
        {
            using var helper = Process.Start(new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = true, Verb = "runas", Arguments = "--trust-embedded-certificate" });
            if (helper is null) return false;
            await helper.WaitForExitAsync();
            if (helper.ExitCode != 0) { status.Text = "Importação do certificado não confirmada; widget pendente."; return false; }
            return SignatureVerifier.Verify(payload.Companion, payload.Manifest.CompanionName, payload.Manifest.CompanionPublisher, payload.Manifest.CompanionVersion, cert).Trusted;
        }
        catch (Win32Exception e) when (e.NativeErrorCode == 1223) { status.Text = "UAC cancelado; widget pendente."; return false; }
    }
    async Task Install()
    {
        if (running) return; running = true; cancellation = new(); next.IsEnabled = false;
        foreach (var c in new[] { bar, tray, widget, autostart }) c.IsEnabled = false;
        try
        {
            if (widget.IsChecked == true) services.CompanionTrusted = await EnsureTrust();
            var options = new InstallOptions(bar.IsChecked == true, tray.IsChecked == true, widget.IsChecked == true, autoChanged ? autostart.IsChecked == true : null);
            var progress = new Progress<string>(message => status.Text = message);
            var result = await RunSta(() => transaction.ExecuteAsync(SetupPayload.OpenArchive, options, observed, cancellation.Token, progress));
            installedExe = result.Executable;
            status.Text = (result.Complete ? "Instalação concluída." : "Aplicativo instalado; há etapas pendentes.") + "\n" + string.Join("\n", result.Messages);
            if (widget.IsChecked == true) status.Text += "\nNo WidBar, abra o catálogo de widgets e adicione/arraste NexoBar para a barra desejada.";
            AddLaunchButtons();
            if (result.Complete) { finished = true; next.Content = "Concluir"; }
            else { reviewing = false; next.Content = "Verificar novamente"; RefreshPreferences(); }
        }
        catch (OperationCanceledException) { status.Text = "Instalação cancelada antes de confirmar o aplicativo. Você pode verificar e retomar."; reviewing = false; next.Content = "Verificar novamente"; }
        catch (Exception e) { status.Text = e.Message; reviewing = false; next.Content = "Verificar novamente"; }
        finally { running = false; next.IsEnabled = true; foreach (var c in new[] { bar, tray, widget, autostart }) c.IsEnabled = !finished; cancellation.Dispose(); cancellation = null; }
    }
    bool launchAdded;
    static Task<T> RunSta<T>(Func<Task<T>> action)
    {
        var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(async () => { try { completion.SetResult(await action()); } catch (Exception e) { completion.SetException(e); } }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA); thread.Start(); return completion.Task;
    }
    void AddLaunchButtons()
    {
        if (launchAdded) return; launchAdded = true;
        var app = new Button { Content = "Abrir NexoBar", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 14, 0, 5) };
        app.Click += (_, _) => { if (installedExe is not null) Process.Start(new ProcessStartInfo(installedExe) { UseShellExecute = true }); }; body.Children.Add(app);
        var host = new Button { Content = "Abrir WidBar / adicionar NexoBar no catálogo", HorizontalAlignment = HorizontalAlignment.Left };
        host.Click += async (_, _) => { try { await deployment.OpenHost(); } catch (Exception e) { status.Text = e.Message; PackageDeployment.OpenStore(); } }; body.Children.Add(host);
    }
    static void OpenUrl(string url) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
    void OnClosing(object? sender, CancelEventArgs e)
    {
        if (running) { e.Cancel = true; cancellation?.Cancel(); status.Text = "Aguardando cancelamento seguro…"; return; }
        payload?.Dispose();
    }
}
