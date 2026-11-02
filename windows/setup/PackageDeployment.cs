using System.Diagnostics;
using Windows.ApplicationModel;
using Windows.Management.Deployment;
using NexoBar.Setup.Core;

namespace NexoBar.Setup;

public sealed class PackageDeployment : IWidgetPlatform
{
    public const string HostName = "30113AndreaDelBello.WidBar-WidgetTaskbarsystem";
    public const string HostPublisher = "CN=D93DC56B-45A4-4446-A06F-C51D5859D18B";
    public const string StoreId = "9PKLDNM83TP9";
    public const string StoreUrl = "https://apps.microsoft.com/detail/9PKLDNM83TP9";
    readonly PackageManager manager = new();
    public Package? Find(string name, string publisher) => manager.FindPackagesForUser("")
        .Where(p => p.Id.Name == name && p.Id.Publisher == publisher).OrderByDescending(p => VersionOf(p)).FirstOrDefault();
    public static Version VersionOf(Package package) { var v = package.Id.Version; return new(v.Major, v.Minor, v.Build, v.Revision); }
    public bool HostPresent() => Find(HostName, HostPublisher) is { } host && VersionOf(host) >= new Version(1, 2, 8, 0);
    public Version? HostVersion() => Find(HostName, HostPublisher) is { } host ? VersionOf(host) : null;
    public Version? CompanionVersion() => Find("NexoBar.Widget", "CN=NexoBar") is { } companion ? VersionOf(companion) : null;
    public static void OpenStore() => Process.Start(new ProcessStartInfo("ms-windows-store://pdp/?ProductId=" + StoreId) { UseShellExecute = true });
    public async Task<ComponentResult> EnsureHost(CancellationToken token, IProgress<string>? progress)
    {
        if (HostPresent()) return new(true, "WidBar oficial já está instalado.");
        string? winget = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
            .Select(dir => Path.Combine(dir.Trim('"'), "winget.exe")).FirstOrDefault(File.Exists);
        if (winget is null) { OpenStore(); return new(false, "Instale o WidBar pela Microsoft Store e clique Verificar novamente. Nenhum login é iniciado pelo instalador."); }
        progress?.Report("Solicitando WidBar oficial à Microsoft Store…");
        var start = new ProcessStartInfo(winget) { UseShellExecute = false, CreateNoWindow = true };
        foreach (string arg in new[] { "install", "--id", StoreId, "--source", "msstore", "--exact", "--no-upgrade", "--disable-interactivity" }) start.ArgumentList.Add(arg);
        using var process = Process.Start(start) ?? throw new IOException("Não foi possível executar winget.");
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(10));
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, timeout.Token);
        try { await process.WaitForExitAsync(linked.Token); }
        catch (OperationCanceledException)
        {
            // Only the exact helper created by this attempt is stopped; installed packages are preserved.
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync();
            return new(false, "Solicitação ao winget cancelada/tempo excedido. Confira o WidBar na Store e verifique novamente.");
        }
        return HostPresent() ? new(true, "WidBar oficial confirmado após instalação.") :
            new(false, $"WidBar ainda ausente/incompatível (winget {process.ExitCode}). Abra a Store, conclua a instalação e verifique novamente.");
    }
    public async Task<ComponentResult> EnsureCompanion(string package, CancellationToken token, IProgress<string>? progress)
    {
        var target = NexoBar.Setup.Core.InstallManifest.CompanionTarget; var installed = Find("NexoBar.Widget", "CN=NexoBar");
        if (installed is not null && VersionOf(installed) >= target)
            return new(true, "Companion compatível já instalado; sem reinstalação/downgrade.");
        progress?.Report("Instalando companion NexoBar…");
        // The running companion is closed by the deployment itself; if the WidBar host still holds the package,
        // the host is closed, the update retried once and the host reopened.
        string? error = await Add(package, token, progress);
        bool hostClosed = false;
        if (error is not null && !token.IsCancellationRequested)
        {
            progress?.Report("WidBar mantém o companion em uso; fechando o WidBar para atualizar…");
            hostClosed = CloseHost();
            error = await Add(package, token, progress);
        }
        installed = Find("NexoBar.Widget", "CN=NexoBar");
        bool ok = installed is not null && VersionOf(installed) >= target;
        if (hostClosed || ok) { try { await OpenHost(); } catch (Exception) { /* Reopening is a convenience; the update result stands. */ } }
        return ok ? new(true, "Companion confirmado" + (hostClosed ? "; WidBar foi fechado e reaberto." : ".") + " Se o NexoBar não aparecer, adicione-o pelo catálogo do WidBar.") :
            new(false, "Companion pendente: " + error);
    }
    async Task<string?> Add(string package, CancellationToken token, IProgress<string>? progress)
    {
        var operation = manager.AddPackageAsync(new Uri(package), null, DeploymentOptions.ForceTargetApplicationShutdown | DeploymentOptions.ForceApplicationShutdown);
        using var cancel = token.Register(operation.Cancel);
        operation.Progress = (_, p) => progress?.Report($"Companion: {p.percentage}%");
        try { var result = await operation; return result.IsRegistered ? null : result.ErrorText; }
        catch (Exception e) { return e.Message; }
    }
    // Only processes running from the official WidBar package folder or the NexoBar companion are closed.
    bool CloseHost()
    {
        bool closed = false;
        string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WindowsApps");
        foreach (var process in Process.GetProcesses())
            using (process)
            {
                try
                {
                    string? path = process.MainModule?.FileName;
                    if (path is null || !path.StartsWith(root, StringComparison.OrdinalIgnoreCase)) continue;
                    string folder = Path.GetFileName(Path.GetDirectoryName(path)!) ?? "";
                    if (!folder.StartsWith(HostName + "_", StringComparison.OrdinalIgnoreCase) && !folder.StartsWith("NexoBar.Widget_", StringComparison.OrdinalIgnoreCase)) continue;
                    process.Kill(entireProcessTree: true); process.WaitForExit(5000); closed = true;
                }
                catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException) { }
            }
        return closed;
    }
    public async Task OpenHost()
    {
        var host = Find(HostName, HostPublisher) ?? throw new IOException("WidBar não instalado.");
        var entries = await host.GetAppListEntriesAsync();
        if (entries.Count == 0 || !await entries[0].LaunchAsync()) throw new IOException("Não foi possível abrir WidBar.");
    }
}
