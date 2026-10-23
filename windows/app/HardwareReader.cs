using System.Runtime.InteropServices;
using LibreHardwareMonitor.Hardware;
using NexoBar.Core;

namespace NexoBar.Windows;

internal sealed class HardwareReader : IDisposable
{
    private readonly Computer computer = new() { IsCpuEnabled = true, IsGpuEnabled = true };
    private bool opened;
    private ulong previousIdle, previousKernel, previousUser;
    private bool hasCpuSample;
    private DateTimeOffset lastDiscovery;
    private int rediscover;
    private readonly object gate = new();
    public IReadOnlyList<Reading> Read()
    {
        lock (gate)
        {
            var now = DateTimeOffset.UtcNow;
            if (!opened)
            {
                try { computer.Open(); opened = true; lastDiscovery = now; }
                catch (Exception) { /* CPU/RAM remain readable without hardware sensor access. */ }
            }
            if (opened && (now - lastDiscovery >= TimeSpan.FromMinutes(1) || Interlocked.Exchange(ref rediscover, 0) != 0))
            {
                try { computer.Reset(); } catch (Exception) { }
                lastDiscovery = now;
            }
            var hardware = new List<IHardware>();
            if (opened)
                foreach (var item in computer.Hardware)
                {
                    try { Update(item, hardware); } catch (Exception) { /* Inaccessible sensors remain null. */ }
                }
            double? temperature = ValidTemperature(hardware.Where(h => h.HardwareType == HardwareType.Cpu).SelectMany(h => h.Sensors));
            double? cpu = ReadCpu();
            List<Reading> results = [new("cpu", "CPU", now, cpu, temperature, Source: "Windows GetSystemTimes · delta kernel+user sem idle", Unavailable: cpu is null ? "Aguardando amostra ou contador indisponível" : null)];
            var memory = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
            if (GlobalMemoryStatusEx(ref memory))
            {
                ulong used = memory.TotalPhysical - memory.AvailablePhysical;
                results.Add(new("memory", "Memória", now, memory.TotalPhysical > 0 ? used * 100d / memory.TotalPhysical : null,
                    UsedBytes: used, TotalBytes: memory.TotalPhysical, Source: "GlobalMemoryStatusEx · RAM física total menos disponível"));
            }
            else results.Add(new("memory", "Memória", now, Source: "GlobalMemoryStatusEx", Unavailable: "Contador indisponível"));
            foreach (var gpu in hardware.Where(h => h.HardwareType is HardwareType.GpuNvidia or HardwareType.GpuAmd or HardwareType.GpuIntel))
            {
                double? load = Value(gpu.Sensors.FirstOrDefault(s => s.SensorType == SensorType.Load && s.Name.Equals("GPU Core", StringComparison.OrdinalIgnoreCase)));
                load = load is >= 0 and <= 100 ? load : null;
                // Per-adapter sensor values, never a max across distinct GPUs.
                double? usedMb = Value(gpu.Sensors.FirstOrDefault(s => s.SensorType == SensorType.SmallData && s.Name.Equals("GPU Memory Used", StringComparison.OrdinalIgnoreCase)));
                double? totalMb = Value(gpu.Sensors.FirstOrDefault(s => s.SensorType == SensorType.SmallData && s.Name.Equals("GPU Memory Total", StringComparison.OrdinalIgnoreCase)));
                results.Add(new("gpu:" + gpu.Identifier, gpu.Name, now, load, ValidTemperature(gpu.Sensors),
                    MbBytes(usedMb), MbBytes(totalMb), Source: "LibreHardwareMonitor 0.9.6 · " + gpu.Identifier,
                    Unavailable: load is null && ValidTemperature(gpu.Sensors) is null && usedMb is null ? "GPU detectada; sensores inacessíveis ao usuário atual" : null,
                    Vendor: gpu.HardwareType switch
                    {
                        HardwareType.GpuNvidia => GpuVendor.Nvidia,
                        HardwareType.GpuAmd => GpuVendor.Amd,
                        HardwareType.GpuIntel => GpuVendor.Intel,
                        _ => GpuVendor.Unknown
                    }));
            }
            return results;
        }
    }
    private static void Update(IHardware item, List<IHardware> all)
    {
        item.Update();
        all.Add(item);
        foreach (var child in item.SubHardware) Update(child, all);
    }
    private static double? Value(ISensor? sensor) => sensor?.Value is { } value && float.IsFinite(value) ? value : null;
    private static ulong? MbBytes(double? mb) => mb is >= 0 and < 1048576 ? (ulong)(mb.Value * 1048576) : null;
    private static double? ValidTemperature(IEnumerable<ISensor> sensors)
    {
        var values = sensors.Where(s => s.SensorType == SensorType.Temperature).Select(Value).Where(v => v is > -20 and < 150).Select(v => v!.Value).ToArray();
        return values.Length == 0 ? null : values.Max();
    }
    private double? ReadCpu()
    {
        if (!GetSystemTimes(out var idle, out var kernel, out var user)) return null;
        double? result = null;
        if (hasCpuSample && kernel >= previousKernel && user >= previousUser && idle >= previousIdle)
        {
            ulong total = kernel - previousKernel + user - previousUser, idleDelta = idle - previousIdle;
            if (total > 0 && idleDelta <= total) result = (total - idleDelta) * 100d / total;
        }
        previousIdle = idle; previousKernel = kernel; previousUser = user; hasCpuSample = true;
        return result;
    }
    public void Dispose() { lock (gate) { if (opened) computer.Close(); } }
    internal void Rediscover() => Interlocked.Exchange(ref rediscover, 1);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetSystemTimes(out ulong idle, out ulong kernel, out ulong user);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryStatus
    {
        public uint Length, Load;
        public ulong TotalPhysical, AvailablePhysical, TotalPageFile, AvailablePageFile, TotalVirtual, AvailableVirtual, AvailableExtendedVirtual;
    }
}
