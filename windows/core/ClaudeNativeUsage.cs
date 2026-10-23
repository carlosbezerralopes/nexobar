using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace NexoBar.Core;

// A bounded current frame. Erased/scrolled quotas never survive a redraw.
public sealed class ClaudeTerminalScreen(int columns = 160, int rows = 80)
{
    private readonly int width = Math.Clamp(columns, 1, 512), height = Math.Clamp(rows, 1, 256);
    private string[,]? cells;
    private int x, y, savedX, savedY, state;
    private string parameters = "";
    private readonly Decoder decoder = new UTF8Encoding(false, false).GetDecoder();
    public string Text
    {
        get
        {
            Ensure(); var lines = new string[height];
            for (int row = 0; row < height; row++) { var line = new StringBuilder(); for (int col = 0; col < width; col++) line.Append(cells![row, col]); lines[row] = line.ToString().TrimEnd(); }
            return string.Join('\n', lines).Trim('\n');
        }
    }
    private void Ensure() { if (cells is null) { cells = new string[height, width]; Clear(); } }
    private void Clear() { for (int row = 0; row < height; row++) for (int col = 0; col < width; col++) cells![row, col] = " "; }
    public void EraseContents() { Ensure(); Clear(); }
    public void Feed(ReadOnlySpan<byte> bytes)
    {
        Ensure(); char[] chars = new char[bytes.Length + 2]; int count = decoder.GetChars(bytes, chars, false);
        foreach (var rune in chars.AsSpan(0, count).EnumerateRunes()) Consume(rune);
    }
    private void Consume(Rune rune)
    {
        int value = rune.Value;
        if (state == 3) { if (value == 7) state = 0; else if (value == 27) state = 4; return; }
        if (state == 4) { state = value == 92 ? 0 : value == 27 ? 4 : 3; return; }
        if (state == 5) { state = 0; return; }
        if (state == 1)
        {
            state = 0;
            switch (value)
            {
                case 91: state = 2; parameters = ""; break;
                case 93: case 80: case 94: case 95: state = 3; break;
                case 40: case 41: case 42: case 43: state = 5; break;
                case 55: savedX = x; savedY = y; break;
                case 56: x = savedX; y = savedY; break;
                case 68: LineFeed(); break;
                case 69: x = 0; LineFeed(); break;
                case 99: Clear(); x = y = 0; break;
            }
            return;
        }
        if (state == 2)
        {
            if (value is >= 0x40 and <= 0x7e) { Csi(value); parameters = ""; state = 0; }
            else if (value == 27) { state = 1; parameters = ""; }
            else parameters = parameters.Length < 64 && value is >= 0x20 and <= 0x3f ? parameters + (char)value : "?";
            return;
        }
        switch (value)
        {
            case 27: state = 1; return;
            case 13: x = 0; return;
            case 10: LineFeed(); return;
            case 8: x = Math.Max(0, x - 1); return;
            case 9: x = Math.Min(width - 1, (x / 8 + 1) * 8); return;
        }
        if (value < 32 || value == 127) return;
        if (x >= width) { x = 0; LineFeed(); }
        cells![y, x++] = rune.ToString();
    }
    private void LineFeed()
    {
        if (y < height - 1) { y++; return; }
        for (int row = 1; row < height; row++) for (int col = 0; col < width; col++) cells![row - 1, col] = cells[row, col];
        for (int col = 0; col < width; col++) cells![height - 1, col] = " ";
    }
    private void Csi(int final)
    {
        if (parameters.Any(c => !char.IsAsciiDigit(c) && c != ';')) return;
        var args = parameters.Split(';').Select(s => int.TryParse(s, out int n) ? Math.Min(n, 4096) : 0).ToArray();
        int amount = Math.Max(1, args[0]), mode = args[0];
        switch (final)
        {
            case 65: y = Math.Max(0, y - amount); break;
            case 66: y = Math.Min(height - 1, y + amount); break;
            case 67: x = Math.Min(width - 1, x + amount); break;
            case 68: x = Math.Max(0, x - amount); break;
            case 71: x = Math.Min(width - 1, amount - 1); break;
            case 72: case 102: y = Math.Min(height - 1, amount - 1); x = Math.Min(width - 1, Math.Max(1, args.Length > 1 ? args[1] : 1) - 1); break;
            case 75:
                int cursor = Math.Min(width - 1, x);
                for (int col = mode is 1 or 2 ? 0 : cursor; col <= (mode is 1 ? cursor : width - 1); col++) cells![y, col] = " ";
                break;
            case 74:
                if (mode is 2 or 3) Clear();
                else for (int row = 0; row < height; row++) for (int col = 0; col < width; col++)
                    if (mode == 1 ? row < y || row == y && col <= x : row > y || row == y && col >= x) cells![row, col] = " ";
                break;
            case 115: savedX = x; savedY = y; break;
            case 117: x = savedX; y = savedY; break;
        }
    }
}

public static class ClaudeNativeUsage
{
    public static void RejectBlocked(string text)
    {
        string lower = text.ToLowerInvariant();
        if (new[] { "not logged in", "please log in", "run /login", "login required", "sign in", "authentication", "unauthorized" }.Any(lower.Contains))
            throw new FormatException("Claude Code exige login; abra o cliente");
        if (new[] { "do you trust", "trust this", "trust the files", "trust folder", "permission required", "choose the text style", "choose a theme", "select a theme", "let’s get started", "let's get started" }.Any(lower.Contains))
            throw new FormatException("Claude Code exige configuração ou confiança na pasta; abra o cliente");
        if (new[] { "failed to load", "error loading usage", "unable to load usage", "error fetching" }.Any(lower.Contains))
            throw new FormatException("Claude Code não conseguiu carregar as cotas");
    }
    public static bool InitialPrompt(string text)
    {
        RejectBlocked(text); string lower = text.ToLowerInvariant();
        return lower.Contains("claude code") && new[] { "max", "pro", "claude.ai" }.Any(lower.Contains) &&
            text.Split('\n').Any(line => line.Trim() is "❯" or "›" or "$" or ">");
    }
    public static bool Loading(string text) => new[] { "refreshing", "loading usage", "fetching usage" }.Any(text.ToLowerInvariant().Contains);
    public static Reading Parse(string screen, DateTimeOffset now)
    {
        if (Encoding.UTF8.GetByteCount(screen) > 256 * 1024) throw new FormatException("Frame excessivo");
        RejectBlocked(screen);
        if (Loading(screen) || Regex.IsMatch(screen, @"\berror\b", RegexOptions.IgnoreCase)) throw new FormatException("Cotas ainda não carregadas");
        List<(string Id, string Label, bool Weekly, List<string> Lines)> sections = [];
        foreach (string raw in screen.Split('\n'))
        {
            string line = raw.Trim().Trim('│', '┃', '║').Trim();
            var heading = Regex.Match(line, @"^Current week \(([^\r\n()]{1,64})\)$");
            if (line == "Current session") sections.Add(("session", "Sessão", false, []));
            else if (heading.Success)
            {
                string scope = heading.Groups[1].Value;
                if (!Regex.IsMatch(scope, @"^[\p{L}\p{N} ._+\-/]+$")) throw new FormatException("Modelo inválido");
                string slug = Regex.Replace(scope.ToLowerInvariant(), "[^a-z0-9]+", "_").Trim('_');
                if (slug.Length == 0) throw new FormatException("Modelo inválido");
                sections.Add((scope == "all models" ? "weekly_all" : "weekly_model_" + slug, scope == "all models" ? "Semanal" : "Semanal · " + scope, true, []));
            }
            else if (line.StartsWith("What's contributing", StringComparison.OrdinalIgnoreCase) || line is "Extra usage" or "Current week") sections.Add(("ignored", "", false, []));
            else if (sections.Count > 0) sections[^1].Lines.Add(line);
        }
        List<QuotaWindow> windows = []; HashSet<string> seen = [];
        foreach (var section in sections.Where(s => s.Id != "ignored"))
        {
            if (!seen.Add(section.Id)) throw new FormatException("Janela duplicada");
            var candidates = section.Lines.Where(line => line.EndsWith("used", StringComparison.OrdinalIgnoreCase) && line.Contains('%')).ToArray();
            if (candidates.Length > 1) throw new FormatException("Percentuais duplicados");
            if (candidates.Length == 0) throw new FormatException("Janela ainda incompleta");
            var percents = Regex.Matches(candidates[0], @"(?<!\S)([0-9]+(?:\.[0-9]+)?)\s*%");
            if (percents.Count != candidates[0].Count(c => c == '%')) throw new FormatException("Token percentual inválido");
            if (percents.Count is < 1 or > 2) throw new FormatException("Percentual inválido");
            double used = double.Parse(percents[^1].Groups[1].Value, CultureInfo.InvariantCulture);
            if (!double.IsFinite(used) || used is < 0 or > 100 || percents.Any(m => double.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture) != used)) throw new FormatException("Percentual inválido");
            var resets = section.Lines.Where(line => line.StartsWith("Resets ", StringComparison.Ordinal)).ToArray();
            windows.Add(new(section.Id, section.Label, used, resets.Length == 1 ? Reset(resets[0], section.Weekly, now) : null, AccountWindow: section.Id is "session" or "weekly_all"));
        }
        windows = windows.OrderBy(w => w.Id == "session" ? 0 : w.Id == "weekly_all" ? 1 : 2).ToList();
        var headline = windows.FirstOrDefault(w => w.AccountWindow);
        if (headline is null) throw new FormatException("Nenhuma janela de conta informada");
        return new("claude", "Claude", now, Windows: windows, Percent: headline.UsedPercent, Source: "Claude Code · /usage · sessão existente em ConPTY temporário");
    }
    private static DateTimeOffset? Reset(string line, bool weekly, DateTimeOffset now)
    {
        var reset = Regex.Match(line, @"^Resets (.+) \(([^()]+)\)$");
        if (!reset.Success) return null;
        TimeZoneInfo zone;
        try { zone = TimeZoneInfo.FindSystemTimeZoneById(reset.Groups[2].Value); }
        catch (Exception e) when (e is TimeZoneNotFoundException or InvalidTimeZoneException) { return null; }
        DateTime local = TimeZoneInfo.ConvertTime(now, zone).Date;
        string text = reset.Groups[1].Value;
        bool tomorrow = text.StartsWith("tomorrow ", StringComparison.OrdinalIgnoreCase), today = text.StartsWith("today ", StringComparison.OrdinalIgnoreCase);
        bool explicitYear = false;
        if (weekly)
        {
            var date = Regex.Match(text, @"^([A-Za-z]+) ([0-9]{1,2})(?:,? ([0-9]{4}))? at (.+)$");
            if (!date.Success) return null;
            string[] months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"];
            int month = Array.FindIndex(months, m => m == date.Groups[1].Value.ToLowerInvariant() || m[..3] == date.Groups[1].Value.ToLowerInvariant()) + 1;
            explicitYear = date.Groups[3].Success;
            try { local = new DateTime(explicitYear ? int.Parse(date.Groups[3].Value, CultureInfo.InvariantCulture) : local.Year, month, int.Parse(date.Groups[2].Value, CultureInfo.InvariantCulture)); }
            catch (ArgumentOutOfRangeException) { return null; }
            text = date.Groups[4].Value;
        }
        else text = Regex.Replace(text, @"^(today|tomorrow) (?:at )?", "", RegexOptions.IgnoreCase);
        var clock = Regex.Match(text, @"^([0-9]{1,2})(?::([0-9]{2}))?\s*(am|pm)?$", RegexOptions.IgnoreCase);
        if (!clock.Success) return null;
        int hour = int.Parse(clock.Groups[1].Value, CultureInfo.InvariantCulture), minute = clock.Groups[2].Success ? int.Parse(clock.Groups[2].Value, CultureInfo.InvariantCulture) : 0;
        if (minute > 59 || (clock.Groups[3].Success ? hour is < 1 or > 12 : hour > 23)) return null;
        if (clock.Groups[3].Success) hour = hour % 12 + (clock.Groups[3].Value.Equals("pm", StringComparison.OrdinalIgnoreCase) ? 12 : 0);
        local = DateTime.SpecifyKind(local.AddHours(hour).AddMinutes(minute), DateTimeKind.Unspecified);
        if (tomorrow) local = local.AddDays(1);
        for (int attempt = 0; attempt < 2; attempt++)
        {
            // Ambiguous or skipped DST instants cannot safely provide a countdown.
            if (zone.IsInvalidTime(local) || zone.IsAmbiguousTime(local)) return null;
            var candidate = new DateTimeOffset(local, zone.GetUtcOffset(local));
            if (candidate > now && candidate - now <= (weekly ? TimeSpan.FromDays(8) : TimeSpan.FromHours(6))) return candidate;
            if (weekly && !explicitYear) { try { local = local.AddYears(1); } catch (ArgumentOutOfRangeException) { return null; } }
            else if (!weekly && !today && !tomorrow) local = local.AddDays(1);
            else break;
        }
        return null;
    }
}

public sealed class ClaudeUsageProtocol
{
    private string last = "";
    private TimeSpan changed, sent;
    private bool changedAfterSend;
    public bool RequestSent { get; private set; }
    public bool Observe(string frame, TimeSpan elapsed)
    {
        ClaudeNativeUsage.RejectBlocked(frame);
        if (frame != last) { last = frame; changed = elapsed; if (RequestSent) changedAfterSend = true; }
        if (!RequestSent && ClaudeNativeUsage.InitialPrompt(frame)) { RequestSent = true; sent = changed = elapsed; return true; }
        return false;
    }
    public bool Ready(TimeSpan elapsed) => RequestSent && changedAfterSend && elapsed - sent >= TimeSpan.FromSeconds(1) && elapsed - changed >= TimeSpan.FromSeconds(1) && !ClaudeNativeUsage.Loading(last);
}
