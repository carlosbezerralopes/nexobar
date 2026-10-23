using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;
using NexoBar.Core;

namespace NexoBar.Windows;

// No credential access, shell, general prompt, or auto-accept input belongs in this transport.
internal sealed class ClaudeConPty : IDisposable
{
    internal const int MaximumOutput = 512 * 1024;
    internal static readonly string[] Arguments = ["--safe-mode", "--strict-mcp-config", "--tools", "", "--ax-screen-reader", "--settings", "{\"disableRemoteControl\":true,\"remoteControlAtStartup\":false}"];
    private readonly CancellationTokenSource shutdown = new();
    private readonly object gate = new();
    private readonly HashSet<SafeFileHandle> jobs = [];
    internal int ActiveJobs { get { lock (gate) return jobs.Count; } }
    internal Task<Reading> Read(string? directory, CancellationToken cancellation)
    {
        string folder = CLIWorkingDirectories.Require(directory, "Claude");
        string binary = OwnedCommand.Locate("claude") ?? throw new IOException("Claude Code não instalado");
        // Native Claude installer is required. A cmd shim would add shell parsing to the fixed JSON arguments.
        if (!binary.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) throw new IOException("Instale o executável nativo Claude Code");
        return Run(binary, Arguments, folder, cancellation, TimeSpan.FromSeconds(45));
    }
    // Internal synthetic harness entry only; never exposed through preferences or CLI arguments.
    internal async Task<Reading> Run(string binary, string[] arguments, string folder, CancellationToken cancellation, TimeSpan timeout)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("ConPTY exige Windows nativo");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation, shutdown.Token);
        deadline.CancelAfter(timeout <= TimeSpan.FromSeconds(45) ? timeout : TimeSpan.FromSeconds(45));
        using var job = Native.CreateJobObject(IntPtr.Zero, null);
        if (job.IsInvalid) throw new Win32Exception();
        var limits = new Native.JobLimits { Basic = new Native.JobBasicLimits { LimitFlags = 0x2000 } };
        if (!Native.SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<Native.JobLimits>())) throw new Win32Exception();
        IntPtr console = IntPtr.Zero, attributes = IntPtr.Zero, environment = IntPtr.Zero;
        SafeFileHandle? process = null, thread = null;
        Task? drain = null;
        using var input = Pipe.Create(); using var output = Pipe.Create();
        lock (gate) { shutdown.Token.ThrowIfCancellationRequested(); jobs.Add(job); }
        bool attributesInitialized = false;
        var screen = new ClaudeTerminalScreen(); var screenGate = new object(); Exception? readFailure = null;
        try
        {
            int hr = Native.CreatePseudoConsole(new Native.Coord(160, 80), input.Read, output.Write, 0, out console);
            if (hr != 0) throw new IOException("ConPTY indisponível neste Windows", Marshal.GetExceptionForHR(hr));
            IntPtr size = IntPtr.Zero;
            Native.InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
            attributes = Marshal.AllocHGlobal(size);
            if (!Native.InitializeProcThreadAttributeList(attributes, 1, 0, ref size)) throw new Win32Exception();
            attributesInitialized = true;
            if (!Native.UpdateProcThreadAttribute(attributes, 0, (IntPtr)0x00020016, console, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero)) throw new Win32Exception();
            // STARTF_USESTDHANDLES with null handles suppresses redirected parent streams in the ConPTY client.
            // https://github.com/microsoft/terminal/discussions/15814
            var startup = new Native.StartupInfoEx { Startup = new Native.StartupInfo { Cb = Marshal.SizeOf<Native.StartupInfoEx>(), Flags = 0x100 }, Attributes = attributes };
            environment = EnvironmentBlock();
            if (!Native.CreateProcess(binary, new StringBuilder(string.Join(' ', new[] { binary }.Concat(arguments).Select(Quote))), IntPtr.Zero, IntPtr.Zero, false,
                0x00080000 | 0x00000004 | 0x00000400, environment, folder, ref startup, out var created)) throw new Win32Exception();
            // ConPTY's communication endpoints must stay open through CreateProcess.
            input.Read.Dispose(); output.Write.Dispose();
            process = new SafeFileHandle(created.Process, true); thread = new SafeFileHandle(created.Thread, true);
            if (!Native.AssignProcessToJobObject(job, process)) { Native.TerminateProcess(process, 1); throw new Win32Exception(); }
            using var canceled = deadline.Token.Register(() => { lock (gate) { if (!job.IsClosed) Native.TerminateJobObject(job, 1); } });
            // Always continue draining after a protocol/output failure until ClosePseudoConsole returns.
            // This prevents the pre-24H2 ClosePseudoConsole synchronous-output deadlock.
            drain = Task.Factory.StartNew(() =>
            {
                byte[] bytes = new byte[16384]; long total = 0;
                try
                {
                    using var stream = new FileStream(output.Read, FileAccess.Read, 16384, false);
                    int count;
                    while ((count = stream.Read(bytes, 0, bytes.Length)) > 0)
                    {
                        total += count;
                        lock (screenGate)
                        {
                            if (total > MaximumOutput) { readFailure ??= new IOException("Saída Claude excedeu 512KiB"); continue; }
                            screen.Feed(bytes.AsSpan(0, count));
                            try { ClaudeNativeUsage.RejectBlocked(screen.Text); }
                            catch (FormatException e) { readFailure ??= e; }
                        }
                    }
                }
                catch (IOException e) { lock (screenGate) readFailure ??= e; }
            }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
            deadline.Token.ThrowIfCancellationRequested();
            if (Native.ResumeThread(thread) == uint.MaxValue) throw new Win32Exception();
            var clock = Stopwatch.StartNew(); var protocol = new ClaudeUsageProtocol();
            while (true)
            {
                deadline.Token.ThrowIfCancellationRequested();
                string frame;
                lock (screenGate) { if (readFailure is not null) throw readFailure; frame = screen.Text; }
                if (protocol.Observe(frame, clock.Elapsed))
                {
                    lock (screenGate) screen.EraseContents(); // Pre-request status-line/frame quotas cannot be reused.
                    byte[] command = Encoding.UTF8.GetBytes("/usage\r");
                    if (!Native.WriteFile(input.Write, command, (uint)command.Length, out uint written, IntPtr.Zero) || written != command.Length) throw new IOException("Entrada Claude fechada");
                }
                else if (protocol.Ready(clock.Elapsed))
                {
                    try { return ClaudeNativeUsage.Parse(frame, DateTimeOffset.UtcNow); }
                    catch (FormatException) { /* A stable but incomplete composition can still be replaced. */ }
                }
                if (Native.WaitForSingleObject(process, 0) == 0) throw new IOException("Claude encerrou antes de informar cotas");
                await Task.Delay(20, deadline.Token).ConfigureAwait(false);
            }
        }
        finally
        {
            // Kill the owned tree before console teardown, including children left after the root exits.
            lock (gate) { if (!job.IsClosed) Native.TerminateJobObject(job, 0); }
            if (process is not null) Native.WaitForSingleObject(process, 2000);
            input.Write.Dispose();
            try
            {
                // Before the reader starts, close the output channel so ConPTY cannot block on its flush.
                if (drain is null) output.Read.Dispose();
                if (console != IntPtr.Zero) Native.ClosePseudoConsole(console);
                if (drain is not null) await drain.ConfigureAwait(false);
            }
            finally
            {
                process?.Dispose(); thread?.Dispose();
                if (attributes != IntPtr.Zero) { if (attributesInitialized) Native.DeleteProcThreadAttributeList(attributes); Marshal.FreeHGlobal(attributes); }
                if (environment != IntPtr.Zero) Marshal.FreeHGlobal(environment);
                lock (gate) jobs.Remove(job);
            }
        }
    }
    private static string Quote(string value)
    {
        var result = new StringBuilder("\""); int slashes = 0;
        foreach (char c in value) { if (c == '\\') { slashes++; continue; } if (c == '"') result.Append('\\', slashes * 2 + 1); else result.Append('\\', slashes); result.Append(c); slashes = 0; }
        return result.Append('\\', slashes * 2).Append('"').ToString();
    }
    private static IntPtr EnvironmentBlock()
    {
        var environment = Environment.GetEnvironmentVariables().Cast<DictionaryEntry>().Where(e => e.Key is string && e.Value is string)
            .ToDictionary(e => (string)e.Key, e => (string)e.Value!, StringComparer.OrdinalIgnoreCase);
        environment.Remove("CI"); environment.Remove("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC");
        environment["TERM"] = "xterm-256color"; environment["DISABLE_AUTOUPDATER"] = "1";
        // The session may never launch a browser. cmd /d /c exit is a fixed no-op browser command.
        environment["BROWSER"] = "cmd.exe /d /c exit 1";
        return Marshal.StringToHGlobalUni(string.Join('\0', environment.OrderBy(e => e.Key, StringComparer.OrdinalIgnoreCase).Select(e => e.Key + "=" + e.Value)) + "\0\0");
    }
    public void Dispose()
    {
        shutdown.Cancel();
        lock (gate) foreach (var job in jobs) if (!job.IsClosed) Native.TerminateJobObject(job, 1);
    }
    private sealed class Pipe : IDisposable
    {
        public required SafeFileHandle Read { get; init; } public required SafeFileHandle Write { get; init; }
        public static Pipe Create() { if (!Native.CreatePipe(out var read, out var write, IntPtr.Zero, 0)) throw new Win32Exception(); return new() { Read = read, Write = write }; }
        public void Dispose() { Read.Dispose(); Write.Dispose(); }
    }
    private static class Native
    {
        [StructLayout(LayoutKind.Sequential)] internal readonly struct Coord(short x, short y) { public readonly short X = x, Y = y; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct StartupInfo { public int Cb; public IntPtr Reserved, Desktop, Title; public uint X, Y, XSize, YSize, XChars, YChars, FillAttribute, Flags; public ushort Show, Reserved2; public IntPtr ReservedPtr, Input, Output, Error; }
        [StructLayout(LayoutKind.Sequential)] internal struct StartupInfoEx { public StartupInfo Startup; public IntPtr Attributes; }
        [StructLayout(LayoutKind.Sequential)] internal struct ProcessInformation { public IntPtr Process, Thread; public uint ProcessId, ThreadId; }
        [StructLayout(LayoutKind.Sequential)] internal struct JobBasicLimits { public long ProcessTime, JobTime; public uint LimitFlags; public UIntPtr MinWorkingSet, MaxWorkingSet; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint Priority, Scheduling; }
        [StructLayout(LayoutKind.Sequential)] internal struct IoCounters { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
        [StructLayout(LayoutKind.Sequential)] internal struct JobLimits { public JobBasicLimits Basic; public IoCounters Io; public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory; }
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern int CreatePseudoConsole(Coord size, SafeFileHandle input, SafeFileHandle output, uint flags, out IntPtr console);
        [DllImport("kernel32.dll")] internal static extern void ClosePseudoConsole(IntPtr console);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, IntPtr attributes, uint size);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, uint flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
        [DllImport("kernel32.dll")] internal static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "CreateProcessW", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool CreateProcess(string application, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory, ref StartupInfoEx startup, out ProcessInformation information);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern SafeFileHandle CreateJobObject(IntPtr attributes, string? name);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetInformationJobObject(SafeFileHandle job, int infoClass, ref JobLimits info, uint length);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool AssignProcessToJobObject(SafeFileHandle job, SafeFileHandle process);
        [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool TerminateJobObject(SafeFileHandle job, uint exit);
        [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool TerminateProcess(SafeFileHandle process, uint exit);
        [DllImport("kernel32.dll", SetLastError = true)] internal static extern uint ResumeThread(SafeFileHandle thread);
        [DllImport("kernel32.dll")] internal static extern uint WaitForSingleObject(SafeFileHandle handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool WriteFile(SafeFileHandle handle, byte[] buffer, uint size, out uint written, IntPtr overlapped);
    }
}
