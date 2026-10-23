using System.Buffers.Binary;
using System.Diagnostics;
using System.IO.Pipes;
using System.Text.Json;
using NexoBar.Core;
using NexoBar.Widget;
int passed = 0;
void Check(bool value, string name) { if (!value) throw new Exception(name); Console.WriteLine("PASS " + name); passed++; }
DisplaySnapshot Fresh() => new(1, DateTimeOffset.UtcNow, true, new(), [new("cpu", "CPU", new("cpu", "CPU", DateTimeOffset.UtcNow, Percent:42, Temperature:60), true)], true, false, false);
string key = "fixture-" + Guid.NewGuid();
var current = Fresh();
using (var server = new DisplayBridgeServer(() => Volatile.Read(ref current), key))
{
    var got = await DisplayBridge.ReadAsync(isolationKey:key);
    Check(got?.Indicators.Single().Reading.Percent == 42, "actual pipe response");
    Check(server.HasClient && server.LastClientAt is not null, "observed client heartbeat");
    current = Fresh() with { WidgetEnabled=false };
    got = await DisplayBridge.ReadAsync(isolationKey:key);
    Check(got is { WidgetEnabled:false, Indicators.Count:0 }, "disabled clears all numbers");
    current = Fresh() with { CapturedAt=DateTimeOffset.UtcNow.AddSeconds(-16) };
    Check(await DisplayBridge.ReadAsync(isolationKey:key) is null, "stale frame rejected");
    current = Fresh() with { SchemaVersion=2 };
    Check(await DisplayBridge.ReadAsync(isolationKey:key) is null, "future schema rejected");
    current = Fresh() with { Indicators=[null!] };
    Check(await DisplayBridge.ReadAsync(isolationKey:key) is null, "null indicator rejected");
    current = Fresh() with { Indicators=[new("cpu",new string('x',300000), new("cpu","CPU",DateTimeOffset.UtcNow),true)] };
    Check(await DisplayBridge.ReadAsync(isolationKey:key) is null, "oversized server frame rejected");
}
Check(DisplayBridge.PipeName(key) != DisplayBridge.PipeName(), "isolated channel distinct from host");
var watch = Stopwatch.StartNew();
Check(await DisplayBridge.ReadAsync(isolationKey:key) is null && watch.Elapsed < TimeSpan.FromSeconds(2), "offline bounded timeout");
async Task Raw(byte[] payload, int? advertised = null, bool slow=false)
{
    string channel = "raw-"+Guid.NewGuid();
    using var server = new NamedPipeServerStream(DisplayBridge.PipeName(channel),PipeDirection.Out,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous|PipeOptions.CurrentUserOnly);
    var read = DisplayBridge.ReadAsync(isolationKey:channel);
    await server.WaitForConnectionAsync();
    if (slow) { Check(await read is null, "stalled connected server timeout"); return; }
    byte[] header=new byte[4]; BinaryPrimitives.WriteInt32LittleEndian(header,advertised??payload.Length);
    await server.WriteAsync(header); if(payload.Length>0) await server.WriteAsync(payload);
    Check(await read is null, advertised is > DisplayBridge.MaximumFrameBytes ? "oversized client frame rejected" : "malformed JSON rejected");
}
await Raw([],DisplayBridge.MaximumFrameBytes+1);
await Raw("invalid"u8.ToArray());
await Raw([],slow:true);
watch.Restart(); using(var server = new DisplayBridgeServer(Fresh,"dispose-"+key)) { }
Check(watch.Elapsed < TimeSpan.FromSeconds(1), "server disposal cancels listener");
Check(!DisplayBridge.IsFresh(Fresh() with { Indicators=[new("cpu","CPU",null!,true)] },DateTimeOffset.UtcNow),"null reading rejected");
var availability = new WidgetAvailabilityPolicy();
Check(availability.IsPreviewVisible, "unknown enable state allows offline explanation");
availability.Observe(false);
availability.Observe(null);
Check(!availability.IsPreviewVisible && availability.KeepAvailabilityProbe, "disabled then offline preserves hidden slot and probe");
availability.Observe(false);
Check(!availability.IsPreviewVisible, "repeated disabled frame stays hidden");
availability.Observe(true);
Check(availability.IsPreviewVisible && !availability.KeepAvailabilityProbe, "new explicit enable restores preview");
availability.Observe(null);
Check(availability.IsPreviewVisible, "enabled then offline allows unavailable state");
availability.Observe(false);
availability.Observe(null);
Check(!availability.IsPreviewVisible, "enable disable expiry never reopens disabled slot");
// M06 additive schema and bounded placement validation.
var originalWidget = Fresh();
var oldJson = JsonSerializer.Serialize(originalWidget);
var oldFrame = JsonSerializer.Deserialize<DisplaySnapshot>(oldJson)!;
Check(DisplayBridge.IsFresh(oldFrame, DateTimeOffset.UtcNow) && oldFrame.WidgetOptions.Placements is null &&
    oldFrame.WidgetOptions.Normalize().Placements!.Count == 0, "old schema one snapshot remains compatible without placements");
current = Fresh() with { WidgetOptions = new(5, "customRows", Width:402, Placements:
    [new("cpu", 0, 0), new("memory", 0, 1), new("claude", 1, 0), new("codex", 1, 1), new("kiro", 1, 2)]) };
using (var server = new DisplayBridgeServer(() => Volatile.Read(ref current), key))
{
    var got = await DisplayBridge.ReadAsync(isolationKey:key);
    Check(got is { WidgetOptions.ItemsPerPage:5, WidgetOptions.Width:402, WidgetOptions.Layout:"customRows" } &&
        got.WidgetOptions.Placements!.Count == 5, "custom placements travel through actual same-user pipe schema one");
    Check(got!.Indicators is System.Collections.ObjectModel.ReadOnlyCollection<DisplayIndicator> &&
        got.WidgetOptions.Placements is System.Collections.ObjectModel.ReadOnlyCollection<WidgetPlacement>, "bridge exposes read-only indicators and placements");
    current = current with { WidgetOptions = current.WidgetOptions with { Placements = [new("cpu", 5, 80), new("cpu", 0, -99)] } };
    got = await DisplayBridge.ReadAsync(isolationKey:key);
    Check(got?.WidgetOptions.Placements is [{ Id:"cpu", Row:1, Order:0 }], "bridge normalizes row and first duplicate position");
    current = current with { WidgetOptions = current.WidgetOptions with { Placements = [new(new string('x', 257), 0, 0)] } };
    Check(await DisplayBridge.ReadAsync(isolationKey:key) is null, "bridge rejects overlong placement ID");
    current = current with { WidgetOptions = current.WidgetOptions with { Placements = [null!] } };
    Check(await DisplayBridge.ReadAsync(isolationKey:key) is null, "bridge rejects null placement");
    current = current with { WidgetOptions = current.WidgetOptions with { Placements = Enumerable.Range(0, 129).Select(i => new WidgetPlacement("id" + i, 0, i)).ToArray() } };
    Check(await DisplayBridge.ReadAsync(isolationKey:key) is null, "bridge rejects oversized placement list");
}
var inherited = WidgetInstanceSettings.Parse(null);
Check(inherited.WidthOverride is null && !inherited.ShowNames && inherited.EffectiveWidth(402) == 402,
    "instance defaults inherit real snapshot width 402 and hide names");
var firstInstance = WidgetInstanceSettings.Parse("""{"schemaVersion":1,"widthOverride":240,"showNames":true,"future":{"keep":42}}""");
var secondInstance = WidgetInstanceSettings.Parse(null);
Check(firstInstance.EffectiveWidth(402) == 240 && firstInstance.ShowNames && secondInstance.EffectiveWidth(402) == 402 && !secondInstance.ShowNames,
    "plugin instances have independent overrides and names");
var edited = firstInstance.With(550, false);
using (var json = JsonDocument.Parse(edited.ToJson()))
    Check(json.RootElement.GetProperty("future").GetProperty("keep").GetInt32() == 42 &&
        json.RootElement.GetProperty("schemaVersion").GetInt32() == 1, "instance settings preserve unknown fields when editing");
Check(WidgetInstanceSettings.Parse("""{"schemaVersion":1,"widthOverride":1}""").EffectiveWidth(402) == 120 &&
    WidgetInstanceSettings.Parse("""{"schemaVersion":1,"widthOverride":999}""").EffectiveWidth(402) == 600, "instance width clamps 120 to 600");
Check(WidgetInstanceSettings.Parse("""{"schemaVersion":1,"widthOverride":"bad","showNames":{}}""").EffectiveWidth(402) == 402 &&
    !WidgetInstanceSettings.Parse("{broken").ShowNames, "malformed instance settings fall back to inherited safe values");
foreach (string schema in new[] { "2", "\"1\"", "null", "-1", "1.5", "{}" })
{
    var futureSettings = WidgetInstanceSettings.Parse("{\"schemaVersion\":" + schema + ",\"widthOverride\":240,\"showNames\":true}");
    Check(futureSettings.EffectiveWidth(402) == 402 && !futureSettings.ShowNames, "unknown or invalid settings schema inherits safely " + schema);
}
Check(WidgetInstanceSettings.Parse("""{"schemaVersion":1,"schemaVersion":2,"widthOverride":240}""").EffectiveWidth(402) == 402,
    "duplicate settings keys fall back safely");
Check(edited.With(null, false).EffectiveWidth(402) == 402, "restore inherited width clears instance override");
var previewNow = DateTimeOffset.Parse("2026-10-23T12:00:00Z");
var weeklyOnly = new Reading("claude", "Claude", previewNow, Windows:
    [new("week", "Semana", 38, previewNow.AddDays(2))]);
Check(inherited.PreviewQuotaValues(weeklyOnly, previewNow, true).SequenceEqual(new[] { "38%" }),
    "compact weekly preview shows only the real value without invented session or countdown");
var twoWindows = weeklyOnly with { Windows = [new("session", "Sessão", 12, previewNow.AddHours(3)), new("week", "Semana", 38, previewNow.AddDays(2))] };
Check(inherited.PreviewQuotaValues(twoWindows, previewNow, true).SequenceEqual(new[] { "12%", "38%" }),
    "compact preview preserves both real quota values and omits only countdowns");
Check(firstInstance.PreviewQuotaValues(twoWindows, previewNow, true).SequenceEqual(new[] { "12% · 3h0m", "38% · 2d0h" }),
    "named preview can retain complete quota countdown presentation");
Check(inherited.PreviewQuotaValues(twoWindows with { Windows = [new("unknown", "Sem percentual", null, previewNow.AddHours(1))] }, previewNow, true)
    .SequenceEqual(new[] { "—" }), "compact missing quota remains unknown rather than zero");
Check(inherited.PreviewQuotaValues(twoWindows with { Unavailable = "sem fonte" }, previewNow, true).SequenceEqual(new[] { "indisponível" }),
    "compact failed quota remains unavailable");
string committedJson = firstInstance.ToJson();
var activeDraft = WidgetInstanceSettings.Parse(edited.ToJson());
Check(activeDraft.EffectiveWidth(402) == 550 && !activeDraft.ShowNames && firstInstance.EffectiveWidth(402) == 240,
    "live draft reparse does not mutate original settings");
activeDraft = WidgetInstanceSettings.Parse(committedJson);
Check(activeDraft.EffectiveWidth(402) == 240 && activeDraft.ShowNames, "cancel reparse restores original width and names");
Check(ProviderIconPaths.All.Count == 9 && ProviderIconPaths.All.Keys.Order().SequenceEqual(Preferences.Providers.Order()),
    "all nine provider IDs have vector outlines");
Check(ProviderIconPaths.All.Values.All(loops => loops.Length > 0 && loops.All(loop => loop.Length >= 3 &&
    loop.All(p => double.IsFinite(p.X) && double.IsFinite(p.Y)))), "generated loops contain only finite points");
Check(ProviderIconPaths.All["codex"].SelectMany(x => x).Any(p => p.X < 0 || p.Y < 0) &&
    ProviderIconPaths.All["claude"].SelectMany(x => x).Any(p => p.X > 1 || p.Y > 1), "generator preserves original negative and above-one coordinates");
Check(ProviderIconPaths.All.Values.Any(loops => loops.Length > 1), "generator preserves separate loops for even-odd holes");
foreach (var (id, loops) in ProviderIconPaths.All)
{
    double minX = loops.SelectMany(x => x).Min(p => p.X), minY = loops.SelectMany(x => x).Min(p => p.Y);
    double width = loops.SelectMany(x => x).Max(p => p.X) - minX, height = loops.SelectMany(x => x).Max(p => p.Y) - minY;
    double scale = 16 / Math.Max(width, height);
    Check(loops.SelectMany(x => x).All(p => (p.X - minX) * scale + (16 - width * scale) / 2 is >= -0.000001 and <= 16.000001 &&
        (p.Y - minY) * scale + (16 - height * scale) / 2 is >= -0.000001 and <= 16.000001), "complete vector bounding box fits sixteen pixels " + id);
}
Console.WriteLine($"{passed} bridge checks passed; same-user roundtrip only, cross-user ACL needs Windows native validation.");
