using System.Globalization;
using System.Text.Json;

namespace NexoBar.Core;

public enum GpuVendor { Unknown, Nvidia, Amd, Intel }
public static class GpuBrand
{
    // Manufacturer identity comes from the hardware backend, never from an editable display label.
    public static string? Wordmark(GpuVendor vendor) => vendor switch
    {
        GpuVendor.Nvidia => "NVIDIA", GpuVendor.Amd => "AMD", GpuVendor.Intel => "intel", _ => null
    };
}
public sealed record QuotaWindow(string Id, string Label, double? UsedPercent, DateTimeOffset? ResetsAt,
    double? Used = null, double? Limit = null, string? Unit = null, double? Remaining = null, bool AccountWindow = true);
public sealed record Reading(string Id, string Name, DateTimeOffset CapturedAt, double? Percent = null,
    double? Temperature = null, ulong? UsedBytes = null, ulong? TotalBytes = null,
    IReadOnlyList<QuotaWindow>? Windows = null, string Source = "", string? Unavailable = null,
    string Activity = "Atividade não informada pela fonte", GpuVendor Vendor = GpuVendor.Unknown);
public sealed record IndicatorPreference(string Id, string Label, bool Enabled = true, bool ShowTemperature = true);
public sealed class Preferences
{
    public int SchemaVersion { get; set; } = 1;
    public string? MonitorId { get; set; }
    public string? ClaudeWorkingDirectory { get; set; }
    public string? CodexWorkingDirectory { get; set; }
    public DisplayOptions Displays { get; set; } = new();
    public bool MemoryNominal { get; set; } = true;
    public bool StackedQuotas { get; set; }
    public bool DetailedCountdown { get; set; }
    public bool ResetAlerts { get; set; }
    public List<IndicatorPreference> Indicators { get; set; } = Defaults();
    public static readonly string[] Providers = ["claude", "codex", "kiro", "copilot", "antigravity", "cursor", "grok", "opencode", "glm"];
    public static List<IndicatorPreference> Defaults() => [new("cpu", "CPU"), new("memory", "Memória"),
        new("claude", "Claude"), new("codex", "Codex"), new("kiro", "Kiro"), new("copilot", "Copilot"),
        new("antigravity", "Antigravity", false), new("cursor", "Cursor", false), new("grok", "Grok", false),
        new("opencode", "OpenCode Go", false), new("glm", "GLM", false)];
    // Missing GPUs stay in preferences, so rediscovery never loses label/order/visibility.
    public bool Discover(IEnumerable<Reading> readings)
    {
        bool changed = false;
        foreach (var reading in readings.Where(r => r.Id.StartsWith("gpu:", StringComparison.Ordinal)))
            if (!Indicators.Any(p => p.Id == reading.Id))
            {
                Indicators.Insert(Indicators.FindLastIndex(p => p.Id == "memory" || p.Id.StartsWith("gpu:", StringComparison.Ordinal)) + 1,
                    new(reading.Id, reading.Name));
                changed = true;
            }
        return changed;
    }
    public void Move(string id, int direction)
    {
        int from = Indicators.FindIndex(x => x.Id == id), to = from + Math.Sign(direction);
        if (from >= 0 && to >= 0 && to < Indicators.Count) (Indicators[from], Indicators[to]) = (Indicators[to], Indicators[from]);
    }
    public static Preferences Load(string path)
    {
        try
        {
            if (!File.Exists(path) || new FileInfo(path).Length > 128 * 1024) return new();
            var result = JsonSerializer.Deserialize<Preferences>(File.ReadAllText(path));
            if (result is null || result.SchemaVersion != 1 || result.Indicators is null) return new();
            result.Indicators = result.Indicators.Where(x => x is not null && !string.IsNullOrWhiteSpace(x.Id))
                .DistinctBy(x => x.Id).Select(x => x with { Label = SafeLabel(x.Label, x.Id) }).Take(128).ToList();
            foreach (var item in Defaults()) if (!result.Indicators.Any(p => p.Id == item.Id)) result.Indicators.Add(item);
            result.Displays ??= new();
            result.Displays.Normalize();
            return result;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { return new(); }
    }
    public void Save(string path)
    {
        Displays ??= new();
        Displays.Normalize();
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string temporary = path + ".new";
        File.WriteAllText(temporary, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temporary, path, true);
    }
    public static string SafeLabel(string? label, string fallback) => string.IsNullOrWhiteSpace(label) ? fallback :
        new string(label.Where(c => !char.IsControl(c)).Take(64).ToArray()).Trim();
}

public static class Presentation
{
    public static string Percent(double? value) => value is not { } v || !double.IsFinite(v) || v < 0 ? "—" :
        v is > 0 and < 1 ? "<1%" : v is > 99 and < 100 ? "99%" : $"{v:0}%";
    public static string Bytes(ulong? value) => value is { } v ? (v / 1073741824d).ToString("0.#", CultureInfo.CurrentCulture) + " GiB" : "—";
    public static string Countdown(DateTimeOffset? reset, DateTimeOffset now, bool detailed)
    {
        if (reset is null) return "";
        var span = reset.Value - now;
        if (span <= TimeSpan.Zero) return "aguardando confirmação";
        int days = (int)span.TotalDays, hours = (int)span.TotalHours, minutes = (int)span.TotalMinutes;
        return days > 0 ? $"{days}d" + (detailed ? $"{span.Hours}h" : "") :
            hours > 0 ? $"{hours}h" + (detailed ? $"{span.Minutes}m" : "") : minutes > 0 ? $"{minutes}m" : "<1m";
    }
    public static IReadOnlyList<string> QuotaLines(Reading r, Preferences p, DateTimeOffset now)
    {
        if (r.Unavailable is not null) return ["—"];
        var windows = r.Windows?.Where(w => w.AccountWindow).ToArray() ?? [];
        var strings = windows.Select(w => $"{w.Label} {QuotaValue(w)}" + (w.ResetsAt is null ? "" : " · " + Countdown(w.ResetsAt, now, p.DetailedCountdown))).ToArray();
        if (strings.Length == 0) return ["—"];
        return p.StackedQuotas && strings.Length > 1 ? strings : [string.Join("  |  ", strings)];
    }
    public static string QuotaValue(QuotaWindow w) => w.UsedPercent is not null ? Percent(w.UsedPercent) :
        w.Remaining is { } remaining ? $"{remaining:0.#} restantes" : w.Used is { } used ? $"{used:0.#} utilizados" : "—";
    public static string Metric(Reading r, IndicatorPreference pref, Preferences p)
    {
        string value = r.Id == "memory" && p.MemoryNominal ? r.UsedBytes is { } used && r.TotalBytes is { } total ?
            $"{used / 1073741824d:0.#}/{total / 1073741824d:0.#} GiB" : "—" : Percent(r.Percent);
        return value + (pref.ShowTemperature && r.Id != "memory" && r.Temperature is { } temperature ? $" · {temperature:0}°C" : "");
    }
}

public sealed class History
{
    private readonly Dictionary<string, Queue<(DateTimeOffset At, double Value)>> samples = [];
    public void Add(Reading reading, DateTimeOffset now)
    {
        Prune(now);
        if (reading.Unavailable is not null || reading.Percent is not { } value || !double.IsFinite(value)) return;
        if (!samples.TryGetValue(reading.Id, out var queue)) samples[reading.Id] = queue = new();
        queue.Enqueue((now, value));
    }
    public void Prune(DateTimeOffset now)
    {
        foreach (var queue in samples.Values) while (queue.TryPeek(out var first) && now - first.At >= TimeSpan.FromMinutes(5)) queue.Dequeue();
    }
    public IReadOnlyList<(DateTimeOffset At, double Value)> Get(string id, DateTimeOffset now)
    {
        Prune(now); return samples.TryGetValue(id, out var queue) ? queue.ToArray() : [];
    }
}

public sealed class ResetWatcher
{
    private readonly Dictionary<string, QuotaWindow> previous = [];
    public IReadOnlyList<string> Observe(Reading reading)
    {
        if (reading.Unavailable is not null) return [];
        List<string> resets = [];
        foreach (var window in reading.Windows ?? [])
        {
            string key = reading.Id + ":" + window.Id;
            // A clock reaching zero alone is never evidence; require a new reset AND reduced usage.
            if (previous.TryGetValue(key, out var old) && old.ResetsAt is { } oldReset && window.ResetsAt is { } newReset &&
                newReset > oldReset && old.UsedPercent is { } oldUsed && window.UsedPercent is { } newUsed && newUsed < oldUsed)
                resets.Add(window.Label);
            previous[key] = window;
        }
        return resets;
    }
}
