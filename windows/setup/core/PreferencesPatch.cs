using System.Text.Json;
using System.Text.Json.Nodes;

namespace NexoBar.Setup.Core;

public sealed record PreparedPreferences(byte[]? Before, byte[]? After, string? Warning);
public static class PreferencesPatch
{
    public static PreparedPreferences Prepare(byte[]? before, InstallOptions options)
    {
        if (before is not null && options.BarEnabled is null && options.TrayEnabled is null && options.WidgetEnabled is null)
            return new(before, null, null);
        JsonObject root;
        try
        {
            if (before is { Length: > 131072 }) throw new JsonException();
            root = before is null ? Fresh() : JsonNode.Parse(before) as JsonObject ?? throw new JsonException();
            if (root["SchemaVersion"]?.GetValue<int>() != 1 || root["Indicators"] is not JsonArray ||
                (root["Displays"] is not null && root["Displays"] is not JsonObject)) throw new JsonException();
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or FormatException)
        { return new(before, null, "Preferências desconhecidas/corrompidas preservadas. Configure os modos no aplicativo."); }
        var displays = root["Displays"] as JsonObject;
        if (displays is null) { displays = new JsonObject(); root["Displays"] = displays; }
        if (options.BarEnabled is { } bar) displays["BarEnabled"] = bar;
        if (options.TrayEnabled is { } tray) displays["TrayEnabled"] = tray;
        if (options.WidgetEnabled is { } widget) displays["WidgetEnabled"] = widget;
        return new(before, JsonSerializer.SerializeToUtf8Bytes(root, new JsonSerializerOptions { WriteIndented = true }), null);
    }
    static JsonObject Fresh()
    {
        var indicators = new JsonArray();
        foreach (var (id, label) in new[] { ("cpu", "CPU"), ("memory", "Memória"), ("claude", "Claude"), ("codex", "Codex"), ("kiro", "Kiro"), ("copilot", "Copilot"), ("antigravity", "Antigravity"), ("cursor", "Cursor"), ("grok", "Grok"), ("opencode", "OpenCode Go"), ("glm", "GLM") })
            indicators.Add(new JsonObject { ["Id"] = id, ["Label"] = label, ["Enabled"] = id is "cpu" or "memory", ["ShowTemperature"] = true });
        return new() { ["SchemaVersion"] = 1, ["Indicators"] = indicators,
            ["Displays"] = new JsonObject { ["BarEnabled"] = true, ["TrayEnabled"] = false, ["WidgetEnabled"] = false } };
    }
    public static bool Matches(string path, byte[]? expected)
    {
        if (expected is null) return !File.Exists(path);
        return File.Exists(path) && InstallManifest.HashFile(path) == InstallManifest.Hash(expected);
    }
    public static bool Write(string path, PreparedPreferences prepared)
    {
        if (prepared.After is null) return false;
        if (!Matches(path, prepared.Before)) throw new IOException("As preferências mudaram. Verifique novamente antes de instalar.");
        AtomicFiles.Write(path, prepared.After, prepared.Before); return true;
    }
}

public static class AtomicFiles
{
    public static void Write(string path, byte[] content, byte[]? expected)
    {
        SafePaths.NoReparseParents(path); Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string temp = path + ".nexobar-" + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var f = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { f.Write(content); f.Flush(true); }
            if (!PreferencesPatch.Matches(path, expected)) throw new IOException("O arquivo mudou durante a instalação: " + path);
            if (expected is null) File.Move(temp, path, false); else File.Replace(temp, path, null);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
}
