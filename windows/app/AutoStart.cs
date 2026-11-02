using System.IO;
using System.Runtime.InteropServices;

namespace NexoBar.Windows;

// Same per-user Startup shortcut the installer writes and recognizes; no registry Run key or elevation.
internal static class AutoStart
{
    internal const string Description = "NexoBar — indicadores de hardware e cotas";
    private static string ShortcutPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "NexoBar.lnk");
    internal static bool Enabled => File.Exists(ShortcutPath);
    internal static void Set(bool enabled)
    {
        string path = ShortcutPath;
        if (!enabled)
        {
            if (!File.Exists(path)) return;
            // An unrelated shortcut that reuses the name is preserved.
            if (!WithShortcut(path, link => Path.GetFileName((string)link.TargetPath).Equals("NexoBar.exe", StringComparison.OrdinalIgnoreCase)))
                throw new IOException("Atalho de inicialização desconhecido foi preservado.");
            File.Delete(path); return;
        }
        string executable = Environment.ProcessPath ?? throw new IOException("Executável do NexoBar indisponível.");
        WithShortcut(path, link => {
            link.TargetPath = executable; link.WorkingDirectory = Path.GetDirectoryName(executable); link.Arguments = "";
            link.Description = Description; link.IconLocation = executable + ",0"; link.Save(); return true;
        });
    }
    private static T WithShortcut<T>(string path, Func<dynamic, T> action)
    {
        object? shell = null, link = null;
        try
        {
            shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell") ?? throw new IOException("Shell COM indisponível."));
            link = ((dynamic)shell!).CreateShortcut(path); return action(link);
        }
        finally { if (link is not null) Marshal.FinalReleaseComObject(link); if (shell is not null) Marshal.FinalReleaseComObject(shell); }
    }
}
