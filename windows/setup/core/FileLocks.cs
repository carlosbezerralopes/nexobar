using System.Diagnostics;
using System.Runtime.InteropServices;

namespace NexoBar.Setup.Core;

public sealed record FileHolder(int ProcessId, string Name);

// Restart Manager tells exactly which processes hold a file. Only NexoBar's own processes and the WidBar host
// are closed; third parties (Explorer, Defender, OneDrive, indexer) are only named, never killed.
public static class FileLocks
{
    const string WidBarFolder = "30113AndreaDelBello.WidBar-WidgetTaskbarsystem_";
    public static IReadOnlyList<FileHolder> Holders(IEnumerable<string> paths)
    {
        string[] files = paths.SelectMany(p => Directory.Exists(p) ? Directory.EnumerateFiles(p, "*", SearchOption.AllDirectories) : File.Exists(p) ? [p] : [])
            .Take(4000).ToArray();
        if (files.Length == 0 || !OperatingSystem.IsWindows()) return [];
        if (RmStartSession(out uint session, 0, new char[64]) != 0) return [];
        try
        {
            if (RmRegisterResources(session, (uint)files.Length, files, 0, null, 0, null) != 0) return [];
            uint count = 0;
            int result = RmGetList(session, out uint needed, ref count, null, out _);
            if (result == 0 || needed == 0) return [];
            var info = new ProcessInfo[needed]; count = needed;
            if (RmGetList(session, out _, ref count, info, out _) != 0) return [];
            return info.Take((int)count).Select(i => new FileHolder(i.Process.ProcessId, string.IsNullOrWhiteSpace(i.AppName) ? "PID " + i.Process.ProcessId : i.AppName))
                .DistinctBy(h => h.ProcessId).ToArray();
        }
        finally { RmEndSession(session); }
    }
    public static bool IsOwned(Process process)
    {
        try
        {
            string path = process.MainModule?.FileName ?? "", name = Path.GetFileName(path), folder = Path.GetFileName(Path.GetDirectoryName(path) ?? "") ?? "";
            if (process.Id == Environment.ProcessId || name.StartsWith("NexoBar-Setup", StringComparison.OrdinalIgnoreCase)) return false;
            return name.Equals("NexoBar.exe", StringComparison.OrdinalIgnoreCase) || name.Equals("NexoBar.Widget.exe", StringComparison.OrdinalIgnoreCase) ||
                folder.StartsWith(WidBarFolder, StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException) { return false; }
    }
    // Closes owned holders; returns the names of the others so the error can say who holds the file.
    public static (bool Closed, IReadOnlyList<string> Others) Release(IEnumerable<string> paths)
    {
        bool closed = false; var others = new List<string>();
        foreach (var holder in Holders(paths))
        {
            try
            {
                using var process = Process.GetProcessById(holder.ProcessId);
                if (IsOwned(process)) { process.Kill(entireProcessTree: true); process.WaitForExit(5000); closed = true; }
                else others.Add(holder.Name + " (PID " + holder.ProcessId + ")");
            }
            catch (Exception e) when (e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { }
        }
        return (closed, others);
    }
    [StructLayout(LayoutKind.Sequential)] struct UniqueProcess { public int ProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME StartTime; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct ProcessInfo
    {
        public UniqueProcess Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string AppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string ServiceShortName;
        public int ApplicationType; public uint AppStatus, TSSessionId; [MarshalAs(UnmanagedType.Bool)] public bool Restartable;
    }
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmStartSession(out uint session, int flags, char[] key);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmRegisterResources(uint session, uint files, string[] names, uint processes, UniqueProcess[]? applications, uint services, string[]? serviceNames);
    [DllImport("rstrtmgr.dll")] static extern int RmGetList(uint session, out uint needed, ref uint count, [In, Out] ProcessInfo[]? info, out uint reasons);
    [DllImport("rstrtmgr.dll")] static extern int RmEndSession(uint session);
}
