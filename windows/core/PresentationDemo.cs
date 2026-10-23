namespace NexoBar.Core;

// Explicit demonstration data shared by both settings surfaces; never used by collectors.
public static class PresentationDemo
{
    public static readonly DateTimeOffset ReferenceTime = new(2026, 1, 1, 12, 0, 0, TimeSpan.Zero);
    public static Reading Reading(string id, string label)
    {
        var now = ReferenceTime;
        if (id == "cpu") return new(id, label, now, Percent: 24, Temperature: 60, Source: "demonstrativo");
        if (id.StartsWith("gpu:", StringComparison.Ordinal)) return new(id, label, now, Percent: 42, Temperature: 65, Source: "demonstrativo");
        if (id == "memory") return new(id, label, now, Percent: 37.5, UsedBytes: 12UL << 30, TotalBytes: 32UL << 30, Source: "demonstrativo");
        QuotaWindow[] windows = id switch {
            "claude" => [new("session", "Sessão", 12, now.AddHours(2)), new("weekly_all", "Semana", 38, now.AddDays(3))],
            "codex" => [new("weekly", "Semana", 38, now.AddDays(3))],
            "kiro" => [new("monthly", "Mês", 8, now.AddDays(7))],
            _ => []
        };
        return new(id, label, now, Windows: windows, Source: "demonstrativo");
    }
    public static IReadOnlyList<string> Lines(IndicatorPreference item, Preferences options)
    {
        var reading = Reading(item.Id, item.Label);
        return reading.Windows is not null ? Presentation.QuotaDisplayLines(reading, ReferenceTime,
            options.StackedQuotas, false, options.ShowQuotaReset, options.DetailedCountdown) :
            [Presentation.Metric(reading, item, options)];
    }
}
