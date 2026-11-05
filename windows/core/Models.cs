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
    string Activity = "Atividade não informada pela fonte", GpuVendor Vendor = GpuVendor.Unknown, string? Plan = null,
    double? ReadRate = null, double? WriteRate = null, string? HardwareName = null);
public sealed record IndicatorPreference(string Id, string Label, bool Enabled = true, bool ShowTemperature = true, bool ShowFreeSpace = true, bool ShowRates = false);
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
    public bool ShowQuotaReset { get; set; } = true;
    public bool ResetAlerts { get; set; }
    public List<IndicatorPreference> Indicators { get; set; } = Defaults();
    public static readonly string[] Providers = ["claude", "codex", "kiro", "copilot", "antigravity", "cursor", "grok", "opencode", "glm"];
    public static List<IndicatorPreference> Defaults() => [new("cpu", "CPU"), new("memory", "RAM"),
        new("claude", "Claude"), new("codex", "Codex"), new("kiro", "Kiro"), new("copilot", "Copilot"),
        new("antigravity", "Antigravity", false), new("cursor", "Cursor", false), new("grok", "Grok", false),
        new("opencode", "OpenCode Go", false), new("glm", "GLM", false)];
    // Missing GPUs stay in preferences, so rediscovery never loses label/order/visibility.
    // GPUs and disks are discovered devices: shown only while present in the latest reading.
    public static bool IsDevice(string id) => id.StartsWith("gpu:", StringComparison.Ordinal) || id.StartsWith("disk:", StringComparison.Ordinal);
    public bool Discover(IEnumerable<Reading> readings)
    {
        bool changed = false;
        var all = readings.ToArray();
        foreach (var reading in all.Where(r => IsDevice(r.Id)))
            if (!Indicators.Any(p => p.Id == reading.Id))
            {
                // Short default names (GPU, SSD) in the order CPU · GPU · SSD · RAM; the hardware name stays restorable.
                bool gpu = reading.Id.StartsWith("gpu:", StringComparison.Ordinal), integrated = gpu && IsIntegrated(reading.Id);
                string label = gpu ? integrated ? "GPU integrada" : "GPU" : reading.Name;
                for (int n = 2; Indicators.Any(p => p.Label == label); n++) label = (gpu ? integrated ? "GPU integrada" : "GPU" : reading.Name) + " " + n;
                bool enabled = !(integrated && all.Any(r => r.Id.StartsWith("gpu:", StringComparison.Ordinal) && !IsIntegrated(r.Id)));
                int index = Indicators.FindLastIndex(p => p.Id == "cpu" || p.Id.StartsWith("gpu:", StringComparison.Ordinal) || (!gpu && IsDevice(p.Id))) + 1;
                Indicators.Insert(index, new(reading.Id, label, enabled));
                changed = true;
            }
        return changed;
    }
    static bool IsIntegrated(string id) => id.Contains("integrated", StringComparison.OrdinalIgnoreCase);
    public static string DefaultLabel(string id) => Defaults().FirstOrDefault(p => p.Id == id)?.Label ?? id;
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
    // The plan is shown only as the client reported it in the same reading; a failed reading drops it.
    public static string Name(string label, Reading reading) => string.IsNullOrWhiteSpace(reading.Plan) ? label : label + " " + reading.Plan;
    public static string? PlanName(string? raw)
    {
        string text = (raw ?? "").Trim();
        return text.Length is 0 or > 40 || text.Any(char.IsControl) ? null : CultureInfo.InvariantCulture.TextInfo.ToTitleCase(text.ToLowerInvariant());
    }
    // Thin spaces (U+2009) keep the top row narrow: CPU · GPU · SSD · RAM must fit the default width.
    public const string Separator = "\u2009·\u2009";
    public static string Percent(double? value) => value is not { } v || !double.IsFinite(v) || v < 0 ? "—" :
        v is > 0 and < 1 ? "<1%" : v is > 99 and < 100 ? "99%" : $"{v:0}%";
    public static string Bytes(ulong? value) => value is { } v ? (v / 1073741824d).ToString("0.#", CultureInfo.CurrentCulture) + " GB" : "—";
    // Whole unit names (MB/GB/TB): a bare "G" was ambiguous on the bar.
    public static string Size(ulong bytes) => bytes switch
    {
        >= 1UL << 40 => (bytes / 1099511627776d).ToString("0.#", CultureInfo.CurrentCulture) + " TB",
        >= 1UL << 30 => $"{bytes / 1073741824d:0} GB",
        _ => $"{bytes / 1048576d:0} MB",
    };
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
        => QuotaDisplayLines(r, now, p.StackedQuotas, includeWindowLabels: true,
            showQuotaReset: p.ShowQuotaReset, detailedCountdown: p.DetailedCountdown);
    public static IReadOnlyList<string> QuotaDisplayLines(Reading reading, DateTimeOffset now,
        bool stacked, bool includeWindowLabels, bool showQuotaReset, bool detailedCountdown)
    {
        if (reading.Unavailable is not null) return ["—"];
        var strings = (reading.Windows ?? []).Where(window => window.AccountWindow).Select(window =>
            (includeWindowLabels ? window.Label + " " : "") + QuotaValue(window) +
            (showQuotaReset && window.ResetsAt is not null ? Separator + Countdown(window.ResetsAt, now, detailedCountdown) : "")).ToArray();
        if (strings.Length == 0) return ["—"];
        return stacked && strings.Length > 1 ? strings : [string.Join("  |  ", strings)];
    }
    public static string QuotaValue(QuotaWindow w) => w.UsedPercent is not null ? Percent(w.UsedPercent) :
        w.Remaining is { } remaining ? $"{remaining:0.#} restantes" : w.Used is { } used ? $"{used:0.#} utilizados" : "—";
    public static string Metric(Reading r, IndicatorPreference pref, Preferences p)
    {
        string value = r.Id == "memory" && p.MemoryNominal ? r.UsedBytes is { } used && r.TotalBytes is { } total ?
            $"{used / 1073741824d:0.#}/{total / 1073741824d:0} GB" : "—" : Percent(r.Percent);
        bool disk = r.Id.StartsWith("disk:", StringComparison.Ordinal);
        // Disks: active time, read/write rates (Resource Monitor), temperature, then free space when enabled.
        if (disk && pref.ShowRates && r.ReadRate is { } read && r.WriteRate is { } write) value += Separator + Rates(read, write);
        value += pref.ShowTemperature && r.Id != "memory" && r.Temperature is { } temperature ? $"{Separator}{temperature:0}°C" : "";
        if (disk && pref.ShowFreeSpace && r.UsedBytes is { } diskUsed && r.TotalBytes is { } diskTotal && diskTotal >= diskUsed)
            value += $"{Separator}{Size(diskTotal - diskUsed)} livre";
        return value;
    }
    public static IReadOnlyList<string> MetricLines(Reading r, IndicatorPreference pref, Preferences p) => [Metric(r, pref, p)];
    // One shared unit keeps the pair short: "L 1,2 E 0,4 MB/s".
    public static string Rates(double read, double write)
    {
        bool mega = Math.Max(read, write) >= 1048576; double unit = mega ? 1048576 : 1024;
        string Format(double v) => (v / unit).ToString(mega && v / unit < 10 ? "0.0" : "0", CultureInfo.CurrentCulture);
        return $"L {Format(read)} E {Format(write)} {(mega ? "MB/s" : "KB/s")}";
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
