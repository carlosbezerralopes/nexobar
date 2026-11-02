using System.Text.Json;

namespace NexoBar.Core;

public sealed record SensorDisk(int DiskNumber, string Name, double? Temperature);
public sealed record SensorSnapshot(int SchemaVersion, DateTimeOffset CapturedAt, double? CpuTemperature, IReadOnlyList<SensorDisk> Disks, string? CpuStatus = null);
public sealed record DiskVolume(int DiskNumber, ulong Total, ulong Free);
public sealed record DiskActivity(double ActivePercent, double ReadRate, double WriteRate);
// Cumulative IOCTL_DISK_PERFORMANCE counters; times in 100 ns units, as Resource Monitor uses them.
public sealed record DiskCounters(long BytesRead, long BytesWritten, long IdleTime, long QueryTime)
{
    public static DiskActivity? Delta(DiskCounters before, DiskCounters after)
    {
        long elapsed = after.QueryTime - before.QueryTime, idle = after.IdleTime - before.IdleTime;
        long read = after.BytesRead - before.BytesRead, written = after.BytesWritten - before.BytesWritten;
        if (elapsed <= 0 || idle < 0 || read < 0 || written < 0) return null;
        double seconds = elapsed / 1e7;
        return new(Math.Clamp(100 * (1 - (double)idle / elapsed), 0, 100), read / seconds, written / seconds);
    }
}

// Contract between the elevated, read-only sensor service and the unelevated app.
public static class SensorProtocol
{
    public const string PipeName = "NexoBar.Sensors.v1", ServiceName = "NexoBarSensors", ServiceDisplayName = "NexoBar Sensores";
    public const int MaxBytes = 64 * 1024;
    public static string ExecutablePath(string programFiles) => Path.Combine(programFiles, "NexoBar", "Sensores", "NexoBar.Sensors.exe");
    public static double? Temperature(double? value) => value is { } v && double.IsFinite(v) && v is > -20 and < 150 ? v : null;
    public static string Serialize(SensorSnapshot snapshot) => JsonSerializer.Serialize(snapshot);
    public static SensorSnapshot? Parse(string json, DateTimeOffset now)
    {
        if (json.Length > MaxBytes) return null;
        try
        {
            var value = JsonSerializer.Deserialize<SensorSnapshot>(json);
            // Stale or future samples are dropped rather than shown as current.
            if (value is null || value.SchemaVersion != 1 || value.Disks is null || value.Disks.Count > 32 ||
                (now - value.CapturedAt).Duration() > TimeSpan.FromSeconds(15)) return null;
            return value with
            {
                CpuTemperature = Temperature(value.CpuTemperature),
                Disks = value.Disks.Where(d => d is not null && d.DiskNumber is >= 0 and < 256).DistinctBy(d => d.DiskNumber)
                    .Select(d => d with { Name = Preferences.SafeLabel(d.Name, "Disco " + d.DiskNumber), Temperature = Temperature(d.Temperature) }).ToArray(),
                CpuStatus = value.CpuStatus is { } status ? Preferences.SafeLabel(status, "") : null
            };
        }
        catch (JsonException) { return null; }
    }
}

public static class DiskReadings
{
    // One reading per physical disk: percent is active time (Resource Monitor), capacity sums its lettered volumes;
    // temperature comes only from the sensor service.
    public static IReadOnlyList<Reading> Build(IEnumerable<DiskVolume> volumes, IReadOnlyDictionary<int, bool?> solidState,
        SensorSnapshot? sensors, DateTimeOffset now, IReadOnlyDictionary<int, DiskActivity>? activity = null)
    {
        var disks = volumes.Where(v => v.Total > 0 && v.Free <= v.Total).GroupBy(v => v.DiskNumber).OrderBy(g => g.Key).ToArray();
        return disks.Select(group =>
        {
            ulong total = 0, used = 0;
            foreach (var v in group) { total += v.Total; used += v.Total - v.Free; }
            var sensor = sensors?.Disks.FirstOrDefault(d => d.DiskNumber == group.Key);
            string kind = solidState.TryGetValue(group.Key, out var ssd) && ssd is { } value ? value ? "SSD" : "HD" : "Disco";
            string name = disks.Length == 1 ? kind : kind + " " + group.Key;
            DiskActivity? io = activity is not null && activity.TryGetValue(group.Key, out var a) ? a : null;
            return new Reading("disk:" + group.Key, name, now, io?.ActivePercent, sensor?.Temperature, used, total,
                Source: "Tempo ativo e leitura/escrita do disco " + group.Key + " · capacidade dos volumes" +
                    (sensor is null ? " · temperatura exige o serviço NexoBar Sensores" : " · temperatura: " + sensor.Name),
                ReadRate: io?.ReadRate, WriteRate: io?.WriteRate, HardwareName: sensor?.Name);
        }).ToArray();
    }
}
