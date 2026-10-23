using System.Diagnostics;
using System.Runtime.InteropServices;
using NexoBar.Setup.Core;

namespace NexoBar.Setup;

public sealed class WindowsInstallServices(PackageDeployment deployment) : IInstallServices
{
    public bool CompanionTrusted { get; set; }
    public static InstallEnvironment EnvironmentForUser(WindowsInstallServices services)
    {
        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return new(Path.Combine(local, "Programs", "NexoBar"), Path.Combine(local, "NexoBar", "indicators.json"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "NexoBar.lnk"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "NexoBar.lnk"), services);
    }
    public bool IsAppRunning()
    {
        using var current = Process.GetCurrentProcess();
        foreach (var p in Process.GetProcessesByName("NexoBar")) using (p)
            try { if (p.SessionId == current.SessionId) return true; } catch (InvalidOperationException) { }
        return false;
    }
    public byte[] CreateShortcut(string executable) => WithShortcut(null, link => {
        link.TargetPath = executable; link.WorkingDirectory = Path.GetDirectoryName(executable); link.Arguments = "";
        link.Description = "NexoBar — indicadores de hardware e cotas"; link.IconLocation = executable + ",0";
        link.Save(); return File.ReadAllBytes((string)link.FullName);
    });
    public bool OwnsShortcut(byte[] content, string root) => WithShortcut(content, link => {
        string target = Path.GetFullPath((string)link.TargetPath);
        string versions = Path.GetFullPath(Path.Combine(root, "versions")) + Path.DirectorySeparatorChar;
        return target.StartsWith(versions, StringComparison.OrdinalIgnoreCase) && Path.GetFileName(target).Equals("NexoBar.exe", StringComparison.OrdinalIgnoreCase) &&
            string.IsNullOrWhiteSpace((string)link.Arguments) && (string)link.Description == "NexoBar — indicadores de hardware e cotas";
    });
    static T WithShortcut<T>(byte[]? content, Func<dynamic, T> action)
    {
        string dir = Path.Combine(Path.GetTempPath(), "NexoBar", "shortcut", Guid.NewGuid().ToString("N"));
        SafePaths.NoReparseParents(dir); Directory.CreateDirectory(dir);
        string path = Path.Combine(dir, "NexoBar.lnk"); object? shell = null, link = null;
        try
        {
            if (content is not null) File.WriteAllBytes(path, content);
            shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell") ?? throw new IOException("Shell COM indisponível."));
            link = ((dynamic)shell!).CreateShortcut(path); return action(link);
        }
        finally
        {
            if (link is not null) Marshal.FinalReleaseComObject(link); if (shell is not null) Marshal.FinalReleaseComObject(shell);
            if (File.Exists(path)) File.Delete(path); Directory.Delete(dir);
        }
    }
    public async Task<ComponentResult> EnsureWidgetAsync(string package, CancellationToken cancellationToken, IProgress<string>? progress)
    {
        return await WidgetCoordinator.Ensure(deployment, package, CompanionTrusted, cancellationToken, progress);
    }
}
