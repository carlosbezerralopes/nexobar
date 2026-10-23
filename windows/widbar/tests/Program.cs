using System.Buffers.Binary;
using System.Diagnostics;
using System.IO.Pipes;
using System.Text.Json;
using NexoBar.Core;
using NexoBar.Widget;
int passed = 0;
void Check(bool value, string name) { if (!value) throw new Exception(name); Console.WriteLine("PASS " + name); passed++; }
DisplaySnapshot Fresh() => new(1, DateTimeOffset.UtcNow, true, new(), [new("cpu", "CPU", new("cpu", "CPU", DateTimeOffset.UtcNow, Percent:42, Temperature:60), true)], true, false, false);
var serializedFresh = JsonSerializer.Deserialize<DisplaySnapshot>(JsonSerializer.Serialize(Fresh()));
Check(serializedFresh is { ShowQuotaReset:true, WidgetOptions.RowGap:4 } && DisplayBridge.IsFresh(serializedFresh, DateTimeOffset.UtcNow),
    "additive record constructor and freshness roundtrip");
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
Check(availability.LastKnownEnabled is null && availability.KeepAvailabilityProbe,
    "unknown enable state keeps discovery polling when host preview starts hidden");
availability.Observe(null);
Check(availability.LastKnownEnabled is null && availability.IsPreviewVisible && availability.KeepAvailabilityProbe,
    "initial offline result preserves discovery until main app becomes available");
availability.Observe(true);
Check(availability.LastKnownEnabled == true && availability.IsPreviewVisible && !availability.KeepAvailabilityProbe,
    "initial offline then enabled recovers configuration and permits hidden preview to pause");
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
// P01: old schema-one wire frame omits both additive fields.
var oldWire = System.Text.Json.Nodes.JsonNode.Parse(JsonSerializer.Serialize(Fresh()))!.AsObject();
oldWire.Remove("ShowQuotaReset"); oldWire["WidgetOptions"]!.AsObject().Remove("RowGap");
var legacyFrame = JsonSerializer.Deserialize<DisplaySnapshot>(oldWire.ToJsonString())!;
Check(legacyFrame.ShowQuotaReset && legacyFrame.WidgetOptions.RowGap == 4 && legacyFrame.SchemaVersion == 1,
    "old wire frame receives true reset and gap four defaults");
string legacyKey = "legacy-" + Guid.NewGuid();
using (var legacyServer = new NamedPipeServerStream(DisplayBridge.PipeName(legacyKey), PipeDirection.Out, 1,
    PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly))
{
    var readLegacy = DisplayBridge.ReadAsync(isolationKey:legacyKey);
    await legacyServer.WaitForConnectionAsync();
    byte[] payload = System.Text.Encoding.UTF8.GetBytes(oldWire.ToJsonString());
    byte[] header = new byte[4]; BinaryPrimitives.WriteInt32LittleEndian(header,payload.Length);
    await legacyServer.WriteAsync(header); await legacyServer.WriteAsync(payload);
    var got = await readLegacy;
    Check(got is { ShowQuotaReset:true, WidgetOptions.RowGap:4 }, "old frame defaults through real same-user pipe");
}
current = Fresh() with { ShowQuotaReset = false, WidgetOptions = new(5, "customRows", Width:402, RowGap:13,
    Placements:[new("cpu",0,0),new("claude",1,0)]) };
using (var server = new DisplayBridgeServer(() => Volatile.Read(ref current), key))
{
    var got = await DisplayBridge.ReadAsync(isolationKey:key);
    Check(got is { ShowQuotaReset:false, WidgetOptions.RowGap:12, WidgetOptions.Width:402 } &&
        got.WidgetOptions.Placements!.SequenceEqual(current.WidgetOptions.Placements!), "new fields cross pipe with bounded gap and width placements preserved");
    current = current with { ShowQuotaReset = true, WidgetOptions = current.WidgetOptions with { RowGap = -1 } };
    got = await DisplayBridge.ReadAsync(isolationKey:key);
    Check(got is { ShowQuotaReset:true, WidgetOptions.RowGap:0 }, "pipe reset true and negative gap normalized");
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
var twoWindows = weeklyOnly with { Windows = [new("session", "Sessão", 12, previewNow.AddHours(3)),
    new("week", "Semana", 38, previewNow.AddDays(2)), new("model", "Modelo", 99, previewNow.AddDays(1), AccountWindow:false)] };
foreach (bool names in new[] {false, true})
foreach (bool reset in new[] {false, true})
foreach (bool stacked in new[] {false, true})
{
    var instance = inherited.With(null, names);
    string[] expected = ["12%" + (reset ? " · 3h0m" : ""), "38%" + (reset ? " · 2d0h" : "")];
    Check(instance.PreviewQuotaLines(twoWindows, previewNow, true, stacked, reset)
        .SequenceEqual(stacked ? expected : [string.Join("  |  ", expected)]),
        $"preview matrix names={names} reset={reset} stacked={stacked}");
    Check(instance.PreviewQuotaLines(weeklyOnly, previewNow, true, stacked, reset)
        .SequenceEqual(new[] {"38%" + (reset ? " · 2d0h" : "")}), "weekly-only preview has one real line " + names + reset + stacked);
}
Check(inherited.PreviewQuotaValues(twoWindows, previewNow, true).SequenceEqual(firstInstance.PreviewQuotaValues(twoWindows, previewNow, true)),
    "legacy adapter reset is independent of names");
Check(inherited.PreviewQuotaLines(twoWindows with { Windows = [new("unknown", "Sem percentual", null, null)] }, previewNow, true, true, true)
    .SequenceEqual(new[] { "—" }), "missing percentage and reset remain unknown");
Check(inherited.PreviewQuotaLines(twoWindows with { Unavailable = "sem fonte" }, previewNow, true, true, true).SequenceEqual(new[] { "—" }),
    "failed quota remains unavailable");
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
// P02: demonstration semantics and geometry only; no host/collector access.
var demoPrefs = new Preferences { StackedQuotas = true, ShowQuotaReset = true };
var demoClaude = PresentationDemo.Reading("claude", "Claude");
var demoCodex = PresentationDemo.Reading("codex", "Codex");
Check(demoClaude.Windows is { Count: 2 } && demoClaude.Windows.All(window => window.AccountWindow), "demo Claude contains exactly two real account windows");
Check(demoCodex.Windows is [{ Id: "weekly" }] && PresentationDemo.Lines(new("codex", "Codex"), demoPrefs).Count == 1, "demo Codex is weekly only even when stacked");
Check(PresentationDemo.Lines(new("claude", "Claude"), demoPrefs).Count == 2, "demo Claude stacked has two lines");
foreach (string id in new[] { "cpu", "gpu:fixture-a", "gpu:fixture-b" })
{
    var on = PresentationDemo.Lines(new(id, id, true, true), demoPrefs).Single();
    var off = PresentationDemo.Lines(new(id, id, true, false), demoPrefs).Single();
    Check(on.Contains(id == "cpu" ? "60°C" : "65°C") && !off.Contains("°C"), "demo temperature follows preference " + id);
}
Check(PresentationDemo.Lines(new("memory", "Memória"), demoPrefs).Single() == "12/32 GiB", "demo nominal memory fixture");
demoPrefs.MemoryNominal = false;
Check(PresentationDemo.Lines(new("memory", "Memória"), demoPrefs).Single() == Presentation.Percent(37.5), "demo memory percentage follows option");
demoPrefs.ShowQuotaReset = false;
Check(PresentationDemo.Lines(new("claude", "Claude"), demoPrefs).SequenceEqual(new[] { "12%", "38%" }), "demo reset hidden keeps both actual quota windows");
demoPrefs.StackedQuotas = false;
Check(PresentationDemo.Lines(new("claude", "Claude"), demoPrefs).Count == 1, "demo horizontal is one text line");
IReadOnlyList<IReadOnlyList<int>> presetShape = new IReadOnlyList<int>[] { new[] { 1, 1 }, new[] { 2, 1, 1 } };
double Required(IReadOnlyList<IReadOnlyList<int>> rows, double gap) => PreviewLayoutMeasurement.Required(rows, 16, 12, 0, 0, gap);
Check(Required(presetShape, 4) == 44 && Required(presetShape, 0) == 40 && Required(presetShape, 12) == 52, "2+3 geometry gap zero four twelve");
Check(Required(new IReadOnlyList<int>[] { new[] { 2 }, new[] { 2 } }, 4) == 52, "two quota-heavy outer rows need fifty-two pixels");
Check(Required(new IReadOnlyList<int>[] { Array.Empty<int>(), new[] { 2 } }, 12) == 24, "one nonempty row never reserves outer gap");
PreviewLayoutMeasurement Measure(double height = 44, double width = 402, double top = 0, double bottom = 44,
    bool compressed = false, int revision = 1, int currentRevision = 1, bool loaded = true, bool visible = true) =>
    PreviewLayoutMeasurement.Measure(1, revision, currentRevision, loaded, visible, width, height, 44, 44, 2, 2, 4, top, bottom, compressed);
foreach (double invalid in new[] { 0d, double.NaN, double.PositiveInfinity, double.NegativeInfinity })
    Check(Measure(height: invalid).State == PreviewLayoutState.NotMeasured && Measure(width: invalid).State == PreviewLayoutState.NotMeasured, "invalid root dimension cannot pass " + invalid);
Check(Measure(43).State == PreviewLayoutState.InsufficientHeight && Measure(43).MissingHeight == 1, "height forty-three reports one missing pixel");
Check(Measure(44).State == PreviewLayoutState.FitsMeasuredRoot && Measure(48).State == PreviewLayoutState.FitsMeasuredRoot, "height forty-four and forty-eight fit measured root");
Check(Measure(48, bottom: 49).State == PreviewLayoutState.InsufficientHeight && Measure(48, top: -1).State == PreviewLayoutState.InsufficientHeight, "own bounds overflow alerts even when requirement fits");
Check(Measure(48, compressed: true).State == PreviewLayoutState.InsufficientHeight, "compressed text alerts even with nominal free height");
Check(Measure(revision: 1, currentRevision: 2).State == PreviewLayoutState.NotMeasured, "old revision cannot validate new draft");
Check(Measure(loaded: false).State == PreviewLayoutState.NotMeasured && Measure(visible: false).State == PreviewLayoutState.NotMeasured, "unloaded hidden root cannot pass");
var priorMeasurement = Measure().Invalidate();
Check(priorMeasurement.WasValidWhenMeasured && priorMeasurement.State == PreviewLayoutState.NotMeasured && priorMeasurement.Caption(false).StartsWith("Última altura medida:"), "invalidation retains previous geometric sample with explicit historical caption");
Check(priorMeasurement.Caption(false).Contains("conteúdo: 44 px") && priorMeasurement.Caption(false).Contains("cabia") &&
    priorMeasurement.Caption(false).Contains(priorMeasurement.MeasuredAt.ToLocalTime().ToString("HH:mm:ss")) &&
    priorMeasurement.Caption(false).Contains("Aguardando medir este ajuste"), "previous measurement caption retains requirement result time and pending draft");
Check(Measure(43).Invalidate().Caption(false).Contains("insuficiente na medição"), "previous insufficient measurement retains classification");
Console.WriteLine($"{passed} bridge checks passed; same-user roundtrip only, cross-user ACL needs Windows native validation.");
