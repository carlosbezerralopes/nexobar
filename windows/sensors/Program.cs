using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using LibreHardwareMonitor.Hardware;
using NexoBar.Core;

namespace NexoBar.Sensors;

// Read-only sensor host. Runs as a LocalSystem service installed under Program Files; it accepts no input:
// each pipe connection receives one JSON snapshot and is closed.
public static class Program
{
    static readonly CancellationTokenSource stop = new();
    static volatile string snapshot = SensorProtocol.Serialize(new(1, DateTimeOffset.UtcNow, null, [], "aguardando primeira leitura"));
    public static int Main(string[] args)
    {
        // Diagnostic mode: one reading with the caller's own privileges, printed to the console.
        if (args.SequenceEqual(new[] { "--once" })) { using var reader = new SensorReader(); Console.WriteLine(SensorProtocol.Serialize(reader.Read())); return 0; }
        if (args.Length != 0) return 2;
        return ServiceHost.Run(SensorProtocol.ServiceName, Start, () => stop.Cancel()) ? 0 : 1;
    }
    static void Start()
    {
        new Thread(() =>
        {
            using var reader = new SensorReader();
            while (!stop.IsCancellationRequested)
            {
                try { snapshot = SensorProtocol.Serialize(reader.Read()); } catch (Exception) { /* Next cycle retries. */ }
                stop.Token.WaitHandle.WaitOne(TimeSpan.FromSeconds(2));
            }
        }) { IsBackground = true }.Start();
        new Thread(Serve) { IsBackground = true }.Start();
    }
    static void Serve()
    {
        var security = new PipeSecurity();
        security.AddAccessRule(new(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new(new SecurityIdentifier(WellKnownSidType.AuthenticatedUserSid, null), PipeAccessRights.Read, AccessControlType.Allow));
        while (!stop.IsCancellationRequested)
        {
            try
            {
                using var pipe = NamedPipeServerStreamAcl.Create(SensorProtocol.PipeName, PipeDirection.Out, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 0, 0, security);
                pipe.WaitForConnectionAsync(stop.Token).GetAwaiter().GetResult();
                byte[] bytes = Encoding.UTF8.GetBytes(snapshot + "\n");
                pipe.Write(bytes); pipe.Flush(); pipe.WaitForPipeDrain();
            }
            catch (OperationCanceledException) { return; }
            catch (Exception) { stop.Token.WaitHandle.WaitOne(250); }
        }
    }
}

internal sealed class SensorReader : IDisposable
{
    private readonly Computer computer = new() { IsCpuEnabled = true, IsStorageEnabled = true };
    private bool opened;
    public SensorSnapshot Read()
    {
        if (!opened) { computer.Open(); opened = true; }
        double? cpu = null; List<SensorDisk> disks = [];
        foreach (var hardware in computer.Hardware)
        {
            try { hardware.Update(); } catch (Exception) { continue; }
            var temperatures = hardware.Sensors.Where(s => s.SensorType == SensorType.Temperature && s.Value is { } v && float.IsFinite(v)).ToArray();
            if (hardware.HardwareType == HardwareType.Cpu)
            {
                // Package is the CPU's own summary; core maximum is the fallback.
                var package = temperatures.FirstOrDefault(s => s.Name.Equals("CPU Package", StringComparison.OrdinalIgnoreCase));
                var cores = temperatures.Where(s => s.Name.Contains("Core", StringComparison.OrdinalIgnoreCase) && !s.Name.Contains("Distance", StringComparison.OrdinalIgnoreCase));
                cpu ??= SensorProtocol.Temperature(package?.Value ?? (cores.Any() ? cores.Max(s => s.Value) : null));
            }
            else if (hardware.HardwareType == HardwareType.Storage && int.TryParse(hardware.Identifier.ToString().Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault(), out int disk))
            {
                var main = temperatures.FirstOrDefault(s => s.Name is "Temperature" or "Composite Temperature") ?? temperatures.FirstOrDefault();
                disks.Add(new(disk, hardware.Name, SensorProtocol.Temperature(main?.Value)));
            }
        }
        string? status = cpu is not null ? null : IsElevated() ? "indisponível: driver PawnIO ausente ou sem suporte" : "indisponível: leitor sem elevação";
        return new(1, DateTimeOffset.UtcNow, cpu, disks, status);
    }
    private static bool IsElevated() { using var identity = WindowsIdentity.GetCurrent(); return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator) || identity.IsSystem; }
    public void Dispose() { if (opened) computer.Close(); }
}

// Minimal SCM integration (StartServiceCtrlDispatcher / SetServiceStatus) without an extra package.
internal static class ServiceHost
{
    private delegate void ServiceMain(int argc, IntPtr argv);
    private delegate int Handler(int control, int type, IntPtr data, IntPtr context);
    private static ServiceMain? main; private static Handler? handler; private static IntPtr status;
    private static Action? onStart, onStop;
    public static bool Run(string name, Action start, Action stop)
    {
        onStart = start; onStop = stop; main = ServiceEntry; handler = Control;
        var table = new[] { new TableEntry { Name = name, Proc = Marshal.GetFunctionPointerForDelegate(main) }, default };
        return StartServiceCtrlDispatcher(table);
    }
    private static void ServiceEntry(int argc, IntPtr argv)
    {
        status = RegisterServiceCtrlHandlerEx(SensorProtocol.ServiceName, handler!, IntPtr.Zero);
        Report(4); // SERVICE_RUNNING
        onStart!();
    }
    private static int Control(int control, int type, IntPtr data, IntPtr context)
    {
        if (control is 1 or 5) { Report(3); onStop!(); Report(1); } // STOP/SHUTDOWN → STOP_PENDING → STOPPED
        return 0;
    }
    private static void Report(int state)
    {
        var value = new Status { Type = 0x10, State = state, Accepted = state == 4 ? 0x1 | 0x4 : 0 };
        SetServiceStatus(status, ref value);
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct TableEntry { public string? Name; public IntPtr Proc; }
    [StructLayout(LayoutKind.Sequential)] private struct Status { public int Type, State, Accepted, ExitCode, SpecificExitCode, CheckPoint, WaitHint; }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "StartServiceCtrlDispatcherW", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool StartServiceCtrlDispatcher(TableEntry[] table);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, EntryPoint = "RegisterServiceCtrlHandlerExW", SetLastError = true)]
    private static extern IntPtr RegisterServiceCtrlHandlerEx(string name, Handler handler, IntPtr context);
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetServiceStatus(IntPtr handle, ref Status status);
}
