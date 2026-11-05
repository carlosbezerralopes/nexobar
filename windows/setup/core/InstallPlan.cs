namespace NexoBar.Setup.Core;

public sealed record InstallOptions(bool? BarEnabled = null, bool? TrayEnabled = null, bool? WidgetEnabled = null, bool? AutoStart = null);
public enum InstallKind { New, Upgrade, Reuse, Repair, RefuseDowngrade, UnknownCollision, Replace }
public sealed record InstallState(string Product, string Version, string Executable, string ManifestHash);
public sealed record InstallPlan(InstallKind Kind, string Target, string Message)
{
    public static InstallPlan Create(InstallManifest manifest, string root, InstallState? current, string manifestHash)
    {
        manifest.Validate(); SafePaths.NoReparseParents(root);
        string target = SafePaths.Under(root, "versions/" + manifest.Version);
        if (current is not null)
        {
            if (current.Product != "NexoBar" || !Version.TryParse(current.Version, out var version))
                return new(InstallKind.UnknownCollision, target, "Recibo desconhecido. Nenhum arquivo será substituído.");
            if (version > Version.Parse(manifest.Version)) return new(InstallKind.RefuseDowngrade, target, "Uma versão mais nova já está instalada.");
        }
        // Only a byte-identical install of this exact payload is reused; any other folder for this version is replaced.
        if (Directory.Exists(target))
            return current is not null && current.Version == manifest.Version && current.ManifestHash == manifestHash &&
                string.Equals(Path.GetFullPath(current.Executable), Path.Combine(target, "NexoBar.exe"), StringComparison.OrdinalIgnoreCase) && manifest.VerifyInstalled(target) ?
                new(InstallKind.Reuse, target, "Versão íntegra: reutilizar arquivos existentes.") :
                new(InstallKind.Replace, target, "Substituir a pasta existente da versão " + manifest.Version + "; versões anteriores serão removidas.");
        return new(current is null ? InstallKind.New : InstallKind.Upgrade, target, "Instalar aplicativo por usuário; versões anteriores serão removidas.");
    }
}

public sealed record ComponentResult(bool Success, string Message);
public interface IInstallServices
{
    bool IsAppRunning();
    byte[] CreateShortcut(string executable);
    bool OwnsShortcut(byte[] content, string root);
    Task<ComponentResult> EnsureWidgetAsync(string package, CancellationToken cancellationToken, IProgress<string>? progress);
}
public sealed record InstallEnvironment(string Root, string Preferences, string StartMenuShortcut, string StartupShortcut, IInstallServices Services)
{
    public string StatePath => Path.Combine(Root, "install-state.json");
}
public sealed record InstallResult(bool AppInstalled, bool Complete, string Executable, IReadOnlyList<string> Messages);

public interface IWidgetPlatform
{
    Version? HostVersion();
    Version? CompanionVersion();
    Task<ComponentResult> EnsureHost(CancellationToken token, IProgress<string>? progress);
    Task<ComponentResult> EnsureCompanion(string package, CancellationToken token, IProgress<string>? progress);
}

public static class WidgetCoordinator
{
    public static async Task<ComponentResult> Ensure(IWidgetPlatform platform, string package, bool trusted,
        CancellationToken token, IProgress<string>? progress)
    {
        if (!trusted) return new(false, "Companion pendente: confiança no certificado não foi concedida.");
        if (platform.HostVersion() is not { } host || host < new Version(1, 2, 8, 0))
        {
            var request = await platform.EnsureHost(token, progress);
            if (!request.Success) return request;
            if (platform.HostVersion() is not { } verified || verified < new Version(1, 2, 8, 0))
                return new(false, "WidBar não confirmado após solicitação. Abra a Store e verifique novamente.");
        }
        if (platform.CompanionVersion() is { } installed && installed >= InstallManifest.CompanionTarget)
            return new(true, "Companion compatível já instalado; sem reinstalação/downgrade.");
        var result = await platform.EnsureCompanion(package, token, progress);
        if (!result.Success) return result;
        return platform.CompanionVersion() is { } version && version >= InstallManifest.CompanionTarget ?
            new(true, "Companion confirmado. Abra WidBar e adicione NexoBar pelo catálogo.") : new(false, "Companion não confirmado após solicitação; verifique novamente.");
    }
}
