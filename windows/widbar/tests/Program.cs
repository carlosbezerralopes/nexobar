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
Console.WriteLine($"{passed} bridge checks passed; same-user roundtrip only, cross-user ACL needs Windows native validation.");
