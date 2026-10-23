using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace NexoBar.Core;

public static partial class QuotaParsers
{
    public const int MaximumJsonBytes = 16 * 1024;
    public static Reading Claude(string json, DateTimeOffset now)
    {
        if (System.Text.Encoding.UTF8.GetByteCount(json) > MaximumJsonBytes) throw new FormatException("Cache muito grande");
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        if (!ExactFields(root, "schemaVersion", "provider", "capturedAt", "windows")) throw new FormatException("Campos Claude inválidos");
        if (Integer(root, "schemaVersion") != 1 || Text(root, "provider") != "claude") throw new FormatException("Schema Claude inválido");
        string? stamp = Text(root, "capturedAt");
        if (stamp is null || !IsoStamp().IsMatch(stamp) || !DateTimeOffset.TryParse(stamp, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var captured) ||
            captured > now || now - captured >= TimeSpan.FromMinutes(30)) throw new FormatException("Cache Claude ausente, futuro ou antigo");
        if (!root.TryGetProperty("windows", out var entries) || entries.ValueKind != JsonValueKind.Array || entries.GetArrayLength() > 2)
            throw new FormatException("Janelas Claude inválidas");
        List<QuotaWindow> windows = [];
        HashSet<string> seen = [];
        foreach (var row in entries.EnumerateArray())
        {
            if (!ExactFields(row, "id", "usedPercent", "resetsAt")) throw new FormatException("Campos de janela Claude inválidos");
            string? id = Text(row, "id");
            if (id is not ("session" or "weekly_all") || !seen.Add(id)) throw new FormatException("Identidade de janela Claude inválida");
            double? used = Percentage(row, "usedPercent");
            if (used is null) throw new FormatException("Percentual Claude ausente");
            if (!row.TryGetProperty("resetsAt", out var resetNode)) throw new FormatException("Reset ausente");
            DateTimeOffset? reset = resetNode.ValueKind == JsonValueKind.Null ? null : Unix(resetNode);
            if (resetNode.ValueKind != JsonValueKind.Null && reset is null) throw new FormatException("Reset inválido");
            if (reset <= now) continue;
            windows.Add(new(id, id == "session" ? "Sessão" : "Semanal", used, reset));
        }
        if (windows.Count == 0) throw new FormatException("Claude não informou janelas");
        windows = windows.OrderBy(x => x.Id == "session" ? 0 : 1).ToList();
        return new("claude", "Claude", captured, Windows: windows, Percent: windows[0].UsedPercent,
            Source: "Claude Code · status line local · data de entrega pela CLI, sem consulta remota");
    }
    public static Reading Codex(string json, DateTimeOffset now)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (root.TryGetProperty("error", out _)) throw new FormatException("Consulta Codex recusada");
        if (!root.TryGetProperty("result", out var result)) throw new FormatException("Resposta RPC inválida");
        JsonElement limits = default, map = default;
        if (result.TryGetProperty("rateLimitsByLimitId", out map) && map.ValueKind == JsonValueKind.Object) map.TryGetProperty("codex", out limits);
        if (limits.ValueKind != JsonValueKind.Object) result.TryGetProperty("rateLimits", out limits);
        if (limits.ValueKind != JsonValueKind.Object || (Text(limits, "limitId") is { } id && id != "codex")) throw new FormatException("Limites da conta ausentes");
        List<QuotaWindow> windows = [];
        AppendCodex(limits, windows, null);
        if (map.ValueKind == JsonValueKind.Object)
            foreach (var entry in map.EnumerateObject().OrderBy(x => x.Name)) if (entry.Name != "codex") AppendCodex(entry.Value, windows, entry.Name);
        if (!windows.Any(w => w.AccountWindow)) throw new FormatException("Nenhuma janela de conta");
        return new("codex", "Codex", now, Windows: windows, Percent: windows.First(w => w.AccountWindow).UsedPercent,
            Source: "Codex CLI · account/rateLimits/read · utilizado");
    }
    private static void AppendCodex(JsonElement limits, List<QuotaWindow> output, string? group)
    {
        foreach (string key in new[] { "primary", "secondary" })
            if (limits.ValueKind == JsonValueKind.Object && limits.TryGetProperty(key, out var row) && Percentage(row, "usedPercent") is { } used)
            {
                string name = Number(row, "windowDurationMins") == 10080 ? "Semanal" : key == "primary" ? "Principal" : "Secundária";
                output.Add(new(group is null ? key : group + "." + key, group is null ? name : group + " · " + name, used,
                    row.TryGetProperty("resetsAt", out var reset) ? Unix(reset) : null, AccountWindow: group is null));
            }
    }
    public static Reading Copilot(string json, DateTimeOffset now)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (!root.TryGetProperty("quota_snapshots", out var quotas) || quotas.ValueKind != JsonValueKind.Object) throw new FormatException("Cotas Copilot ausentes");
        List<QuotaWindow> windows = [];
        foreach (var row in quotas.EnumerateObject().OrderBy(p => p.Name == "premium_interactions" ? 0 : 1))
        {
            if (row.Value.TryGetProperty("unlimited", out var unlimited) && unlimited.ValueKind == JsonValueKind.True) continue;
            double? limit = Number(row.Value, "entitlement"), used = Number(row.Value, "used"), remaining = Number(row.Value, "remaining");
            if (limit == 0 || used < 0 || remaining < 0 || limit < 0) continue;
            used ??= limit is { } cap && remaining is { } left ? Math.Max(0, cap - left) : null;
            double? percent = limit > 0 && used is { } u ? u / limit * 100 : null;
            if (percent is null && used is null && remaining is null) continue;
            DateTimeOffset? reset = Date(row.Value, "reset_date") ?? Date(row.Value, "reset_at") ?? Date(row.Value, "resets_at") ?? Date(root, "quota_reset_date");
            string label = row.Name switch { "premium_interactions" => "Premium", "chat" => "Chat", "completions" => "Completamentos", _ => row.Name.Replace('_', ' ') };
            windows.Add(new(row.Name, label, percent, reset, used, limit, "solicitações", remaining));
        }
        if (windows.Count == 0) throw new FormatException("Copilot não informou cotas mensuráveis");
        return new("copilot", "Copilot", now, Windows: windows, Percent: windows[0].UsedPercent, Source: "GitHub CLI · copilot_internal/user · utilizado");
    }
    public static Reading Kiro(string raw, DateTimeOffset now)
    {
        string text = Ansi().Replace(raw, "");
        if (Regex.IsMatch(text, "not logged in|login required|oauth error|failed to initialize auth|kiro-cli login", RegexOptions.IgnoreCase)) throw new FormatException("Sessão Kiro indisponível");
        var percentMatch = Regex.Match(text, "[█░▒▓▰▱━─]+\\s*(\\d+(?:\\.\\d+)?)%");
        var pair = Regex.Match(text, "\\((\\d+(?:\\.\\d+)?)\\s+of\\s+(\\d+(?:\\.\\d+)?)\\s+covered");
        double? used = pair.Success ? double.Parse(pair.Groups[1].Value, CultureInfo.InvariantCulture) : null;
        double? limit = pair.Success ? double.Parse(pair.Groups[2].Value, CultureInfo.InvariantCulture) : null;
        double? percent = percentMatch.Success ? double.Parse(percentMatch.Groups[1].Value, CultureInfo.InvariantCulture) : limit > 0 ? used / limit * 100 : null;
        if (percent is null || !double.IsFinite(percent.Value) || percent < 0) throw new FormatException("Resposta Kiro sem percentual explícito");
        DateTimeOffset? reset = null;
        var stamp = Regex.Match(text, "resets on (\\d{4}-\\d{2}-\\d{2}|\\d{1,2}/\\d{1,2})", RegexOptions.IgnoreCase);
        if (stamp.Success)
        {
            string value = stamp.Groups[1].Value;
            if (value.Contains('/'))
            {
                value = now.Year + "/" + value;
                if (DateTimeOffset.TryParseExact(value, "yyyy/M/d", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var civil))
                    reset = civil < new DateTimeOffset(now.UtcDateTime.Date, TimeSpan.Zero) ? civil.AddYears(1) : civil;
            }
            else if (DateTimeOffset.TryParseExact(value, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var civil)) reset = civil;
        }
        List<QuotaWindow> windows = [new("credits", "Créditos", percent, reset, used, limit, "créditos")];
        var bonus = Regex.Match(text, @"Bonus credits:\s*(\d+(?:\.\d+)?)/(\d+(?:\.\d+)?)");
        if (bonus.Success && double.TryParse(bonus.Groups[2].Value, CultureInfo.InvariantCulture, out var bonusLimit) && bonusLimit > 0)
        {
            double bonusUsed = double.Parse(bonus.Groups[1].Value, CultureInfo.InvariantCulture);
            windows.Add(new("bonus", "Bônus", bonusUsed / bonusLimit * 100, null, bonusUsed, bonusLimit, "créditos"));
        }
        return new("kiro", "Kiro", now, Windows: windows, Percent: percent, Source: "Kiro CLI · /usage · utilizado");
    }
    private static double? Number(JsonElement root, string key) => root.ValueKind == JsonValueKind.Object && root.TryGetProperty(key, out var node) &&
        node.ValueKind == JsonValueKind.Number && node.TryGetDouble(out double value) && double.IsFinite(value) ? value : null;
    private static double? Percentage(JsonElement root, string key) => Number(root, key) is { } n && n is >= 0 and <= 100 ? n : null;
    private static int? Integer(JsonElement root, string key) => Number(root, key) is { } n && n == Math.Truncate(n) ? (int)n : null;
    private static string? Text(JsonElement root, string key) => root.ValueKind == JsonValueKind.Object && root.TryGetProperty(key, out var node) && node.ValueKind == JsonValueKind.String ? node.GetString() : null;
    private static DateTimeOffset? Unix(JsonElement node) => node.ValueKind == JsonValueKind.Number && node.TryGetDouble(out var n) && double.IsFinite(n) && n is >= 1000000000 and <= 4102444800 ? DateTimeOffset.UnixEpoch.AddSeconds(n) : null;
    private static bool ExactFields(JsonElement node, params string[] expected)
    {
        if (node.ValueKind != JsonValueKind.Object) return false;
        var keys = node.EnumerateObject().Select(p => p.Name).ToArray();
        return keys.Length == expected.Length && keys.Distinct(StringComparer.Ordinal).Count() == expected.Length &&
            expected.All(key => keys.Contains(key, StringComparer.Ordinal));
    }
    private static DateTimeOffset? Date(JsonElement root, string key)
    {
        if (!root.TryGetProperty(key, out var node)) return null;
        return node.ValueKind == JsonValueKind.Number ? Unix(node) : node.ValueKind == JsonValueKind.String &&
            DateTimeOffset.TryParse(node.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed) ? parsed : null;
    }
    [GeneratedRegex(@"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$")]
    private static partial Regex IsoStamp();
    [GeneratedRegex("\\x1B\\[[0-9;:?]*[ -/]*[@-~]|\\x1B\\][^\\x07\\x1B]*(?:\\x07|\\x1B\\\\)")]
    private static partial Regex Ansi();
}
