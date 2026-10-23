using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace NexoBar.Windows;

// A suspended process is assigned to a kill-on-close Job before it can create children.
// No general-purpose command API is exposed to preferences or quota payloads.
internal sealed class OwnedCommand : IDisposable
{
    private readonly CancellationTokenSource shutdown = new();
    private readonly HashSet<SafeFileHandle> jobs = [];
    private readonly object gate = new();
    private static readonly object spawnGate = new();
    internal static string? Locate(string binary)
    {
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string[] directories = [Path.Combine(home, ".local", "bin"), Path.Combine(home, ".cargo", "bin"),
            .. (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)];
        foreach (string extension in new[] { ".exe", ".cmd" })
            foreach (string directory in directories)
            {
                string path;
                try { path = Path.GetFullPath(Path.Combine(directory.Trim('"'), binary + extension)); }
                catch (Exception e) when (e is ArgumentException or NotSupportedException) { continue; }
                if (File.Exists(path)) return path;
            }
        return null;
    }
    internal async Task<string> Run(string binary, string[] args, bool rpc, CancellationToken cancellation, string? workingDirectory = null)
    {
        string path = Locate(binary) ?? throw new IOException("CLI não instalada no PATH");
        string commandLine;
        string executable;
        if (path.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase))
        {
            // npm installs Codex as a .cmd shim. Only fixed allowlisted arguments reach cmd.
            if (path.IndexOfAny(['"', '%', '!', '\r', '\n']) >= 0) throw new IOException("Caminho de CLI incompatível");
            executable = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe");
            commandLine = $"\"{executable}\" /d /s /c \"\"{path}\" {string.Join(' ', args.Select(Quote))}\"";
        }
        else { executable = path; commandLine = Quote(path) + " " + string.Join(' ', args.Select(Quote)); }
        using var job = CreateJobObject(IntPtr.Zero, null);
        if (job.IsInvalid) throw new Win32Exception();
        var limits = new JobLimits { Basic = new JobBasicLimits { LimitFlags = 0x2000 } };
        if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<JobLimits>())) throw new Win32Exception();
        lock (gate) { if (shutdown.IsCancellationRequested) throw new OperationCanceledException(); jobs.Add(job); }
        try
        {
            string scratch = string.IsNullOrWhiteSpace(workingDirectory) ? Path.Combine(Path.GetTempPath(), "NexoBar", "quota-clients") : NexoBar.Core.CLIWorkingDirectories.Require(workingDirectory, "Codex");
            Directory.CreateDirectory(scratch);
            Pipe input, output, error;
            ProcessInformation process;
            lock (spawnGate)
            {
                input = Pipe.Create(parentReads: false);
                try { output = Pipe.Create(parentReads: true); }
                catch { input.Dispose(); throw; }
                try { error = Pipe.Create(parentReads: true); }
                catch { input.Dispose(); output.Dispose(); throw; }
                try
                {
                    var startup = new StartupInfo { Cb = Marshal.SizeOf<StartupInfo>(), Flags = 0x100, Input = input.Child.DangerousGetHandle(), Output = output.Child.DangerousGetHandle(), Error = error.Child.DangerousGetHandle() };
                    IntPtr environment = EnvironmentBlock();
                    try
                    {
                        if (!CreateProcess(executable, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, true,
                            0x08000000 | 0x00000004 | 0x00000400, environment, scratch, ref startup, out process)) throw new Win32Exception();
                    }
                    finally { Marshal.FreeHGlobal(environment); }
                }
                catch { input.Dispose(); output.Dispose(); error.Dispose(); throw; }
                // The only inheritable pipe handles are closed before another owned spawn can start.
                input.Child.Dispose(); output.Child.Dispose(); error.Child.Dispose();
            }
            using var ownedInput = input;
            using var ownedOutput = output;
            using var ownedError = error;
            using var processHandle = new SafeFileHandle(process.Process, true);
            using var threadHandle = new SafeFileHandle(process.Thread, true);
            if (!AssignProcessToJobObject(job, processHandle)) { TerminateProcess(processHandle, 1); throw new Win32Exception(); }
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation, shutdown.Token);
            timeout.CancelAfter(TimeSpan.FromSeconds(20));
            using var onCancel = timeout.Token.Register(() => TerminateJobObject(job, 1));
            using var reader = new StreamReader(new FileStream(output.Parent, FileAccess.Read, 4096, false), Encoding.UTF8, true);
            using var errors = new StreamReader(new FileStream(error.Parent, FileAccess.Read, 4096, false), Encoding.UTF8, true);
            using var writer = new StreamWriter(new FileStream(input.Parent, FileAccess.Write, 4096, false), new UTF8Encoding(false)) { AutoFlush = true };
            if (ResumeThread(threadHandle) == uint.MaxValue) throw new Win32Exception();
            var stderrTask = Drain(errors, timeout.Token);
            if (!rpc) writer.Close();
            string result;
            if (rpc)
            {
                await writer.WriteLineAsync("{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"nexobar\",\"version\":\"0.3.1\"},\"capabilities\":{\"experimentalApi\":true}}}");
                _ = await Response(reader, 1, timeout.Token);
                await writer.WriteLineAsync("{\"method\":\"initialized\",\"params\":{}}");
                await writer.WriteLineAsync("{\"id\":2,\"method\":\"account/rateLimits/read\",\"params\":{}}");
                result = await Response(reader, 2, timeout.Token);
                writer.Close();
                TerminateJobObject(job, 0); // An app-server may stay alive after stdin closes.
            }
            else
            {
                result = await Drain(reader, timeout.Token);
                await Task.Run(() => WaitForSingleObject(processHandle, 21000), timeout.Token);
                timeout.Token.ThrowIfCancellationRequested();
                if (!GetExitCodeProcess(processHandle, out uint exit) || exit != 0) throw new IOException("Consulta da CLI falhou");
            }
            _ = await stderrTask;
            timeout.Token.ThrowIfCancellationRequested();
            return result;
        }
        finally { TerminateJobObject(job, 0); lock (gate) jobs.Remove(job); }
    }
    private static async Task<string> Drain(StreamReader reader, CancellationToken cancellation)
    {
        StringBuilder result = new();
        char[] buffer = new char[4096];
        while (true)
        {
            int count = await reader.ReadAsync(buffer.AsMemory(), cancellation);
            if (count == 0) return result.ToString();
            if (result.Length + count > 512 * 1024) throw new IOException("Saída da CLI excedeu o limite");
            result.Append(buffer, 0, count);
        }
    }
    private static async Task<string> Response(StreamReader reader, int id, CancellationToken cancellation)
    {
        int count = 0;
        while (true)
        {
            string line = await BoundedLine(reader, cancellation) ?? throw new IOException("RPC fechado");
            count += line.Length;
            if (count > 512 * 1024) throw new IOException("RPC excedeu limite");
            try
            {
                using var doc = System.Text.Json.JsonDocument.Parse(line);
                if (doc.RootElement.TryGetProperty("id", out var node) && node.TryGetInt32(out int actual) && actual == id)
                {
                    if (doc.RootElement.TryGetProperty("error", out _)) throw new IOException("Consulta RPC recusada");
                    return line;
                }
            }
            catch (System.Text.Json.JsonException) { }
        }
    }
    private static async Task<string?> BoundedLine(StreamReader reader, CancellationToken cancellation)
    {
        StringBuilder line = new();
        char[] one = new char[1];
        while (true)
        {
            if (await reader.ReadAsync(one.AsMemory(), cancellation) == 0) return line.Length > 0 ? line.ToString() : null;
            if (one[0] == '\n') return line.ToString();
            if (line.Length >= 512 * 1024) throw new IOException("Linha RPC excedeu limite");
            line.Append(one[0]);
        }
    }
    private static string Quote(string value) => "\"" + value.Replace("\"", "\\\"") + "\"";
    private static IntPtr EnvironmentBlock()
    {
        var environment = Environment.GetEnvironmentVariables().Cast<System.Collections.DictionaryEntry>()
            .Where(e => e.Key is string && e.Value is string).ToDictionary(e => (string)e.Key, e => (string)e.Value!, StringComparer.OrdinalIgnoreCase);
        foreach (var pair in new Dictionary<string, string> { ["GH_PROMPT_DISABLED"] = "1", ["GIT_TERMINAL_PROMPT"] = "0", ["CI"] = "1", ["BROWSER"] = "false", ["NO_COLOR"] = "1" }) environment[pair.Key] = pair.Value;
        return Marshal.StringToHGlobalUni(string.Join('\0', environment.OrderBy(e => e.Key, StringComparer.OrdinalIgnoreCase).Select(e => e.Key + "=" + e.Value)) + "\0\0");
    }
    public void Dispose()
    {
        shutdown.Cancel();
        lock (gate) foreach (var job in jobs) if (!job.IsClosed) TerminateJobObject(job, 1);
    }
    private sealed class Pipe : IDisposable
    {
        public required SafeFileHandle Parent { get; init; }
        public required SafeFileHandle Child { get; init; }
        public static Pipe Create(bool parentReads)
        {
            var attributes = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), Inherit = true };
            if (!CreatePipe(out var read, out var write, ref attributes, 0)) throw new Win32Exception();
            var parent = parentReads ? read : write; var child = parentReads ? write : read;
            if (!SetHandleInformation(parent, 1, 0)) { read.Dispose(); write.Dispose(); throw new Win32Exception(); }
            return new() { Parent = parent, Child = child };
        }
        public void Dispose() { Parent.Dispose(); Child.Dispose(); }
    }
    [StructLayout(LayoutKind.Sequential)] private struct SecurityAttributes { public int Length; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool Inherit; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct StartupInfo { public int Cb; public string? Reserved, Desktop, Title; public uint X, Y, XSize, YSize, XChars, YChars, FillAttribute, Flags; public ushort Show, Reserved2; public IntPtr ReservedPtr, Input, Output, Error; }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessInformation { public IntPtr Process, Thread; public uint ProcessId, ThreadId; }
    [StructLayout(LayoutKind.Sequential)] private struct JobBasicLimits { public long ProcessTime, JobTime; public uint LimitFlags; public UIntPtr MinWorkingSet, MaxWorkingSet; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint Priority, Scheduling; }
    [StructLayout(LayoutKind.Sequential)] private struct IoCounters { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
    [StructLayout(LayoutKind.Sequential)] private struct JobLimits { public JobBasicLimits Basic; public IoCounters Io; public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateJobObject(IntPtr attributes, string? name);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetInformationJobObject(SafeFileHandle job, int infoClass, ref JobLimits info, uint length);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AssignProcessToJobObject(SafeFileHandle job, SafeFileHandle process);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool TerminateJobObject(SafeFileHandle job, uint exit);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool TerminateProcess(SafeFileHandle process, uint exit);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, ref SecurityAttributes attributes, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetHandleInformation(SafeFileHandle handle, uint mask, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "CreateProcessW", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CreateProcess(string application, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcessInformation information);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint ResumeThread(SafeFileHandle thread);
    [DllImport("kernel32.dll")] private static extern uint WaitForSingleObject(SafeFileHandle handle, uint milliseconds);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetExitCodeProcess(SafeFileHandle process, out uint code);
}
