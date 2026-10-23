using System.Text.Json;
using NexoBar.Core;

int count = 0;
void Check(bool condition, string label) { if (!condition) throw new Exception("FAIL " + label); count++; Console.WriteLine("PASS " + label); }
void Reject(Action action, string label)
{
    try { action(); } catch (Exception e) when (e is FormatException or JsonException) { Check(true, label); return; }
    throw new Exception("FAIL " + label + " accepted invalid input");
}
var now = DateTimeOffset.Parse("2026-10-23T12:00:00Z");
string Claude(string captured, string windows, int version = 1, string provider = "claude") =>
    $$"""{"schemaVersion":{{version}},"provider":"{{provider}}","capturedAt":"{{captured}}","windows":{{windows}}} """;
const string weekly = """[{"id":"weekly_all","usedPercent":0,"resetsAt":1793000000}]""";
var single = QuotaParsers.Claude(Claude("2026-10-23T11:59:00Z", weekly), now);
Check(single.Windows is { Count: 1 } && single.Windows[0].Id == "weekly_all" && single.Windows[0].UsedPercent == 0, "Claude weekly only and explicit zero");
var prefs = new Preferences { StackedQuotas = true };
Check(Presentation.QuotaLines(single, prefs, now).Count == 1, "weekly only no phantom session in stacked layout");
var dual = QuotaParsers.Claude(Claude("2026-10-23T11:59:00.123Z", """[{"id":"weekly_all","usedPercent":12.3,"resetsAt":1793000000},{"id":"session","usedPercent":38,"resetsAt":null}]"""), now);
Check(dual.Windows is { Count: 2 } && dual.Windows[0].Id == "session", "Claude session sorted before weekly");
Check(Presentation.QuotaLines(dual, prefs, now).Count == 2, "two real windows stacked");
prefs.StackedQuotas = false;
Check(Presentation.QuotaLines(dual, prefs, now).Count == 1 && Presentation.QuotaLines(dual, prefs, now)[0].Contains('|'), "two windows horizontal default");
Check(!new Preferences().StackedQuotas && !new Preferences().DetailedCountdown && new Preferences().MemoryNominal && !new Preferences().ResetAlerts, "presentation defaults");
Reject(() => QuotaParsers.Claude(Claude("2026-10-23T11:30:00Z", weekly), now), "Claude age exactly 30m refused");
Reject(() => QuotaParsers.Claude(Claude("2026-10-23T11:29:00Z", weekly), now), "Claude stale refused");
Reject(() => QuotaParsers.Claude(Claude("2026-10-23T12:00:01Z", weekly), now), "Claude future refused");
Reject(() => QuotaParsers.Claude(Claude("2026-10-23T11:59:00", weekly), now), "Claude local timestamp refused");
Reject(() => QuotaParsers.Claude(Claude("2026-10-23T11:59:00+00:00", weekly), now), "Claude UTC receipt requires Z");
Reject(() => QuotaParsers.Claude(Claude("2026-10-23T11:59:00Z", "[]"), now), "Claude empty refused");
Reject(() => QuotaParsers.Claude(Claude("2026-10-23T11:59:00Z", weekly, 2), now), "Claude unknown schema refused");
Reject(() => QuotaParsers.Claude(Claude("2026-10-23T11:59:00Z", weekly, provider: "codex"), now), "Claude wrong provider refused");
foreach (string value in new[] { "null", "-1", "101", "\"20\"", "true" })
    Reject(() => QuotaParsers.Claude(Claude("2026-10-23T11:59:00Z", "[{\"id\":\"session\",\"usedPercent\":" + value + ",\"resetsAt\":null}]"), now), "Claude invalid percent " + value);
Reject(() => QuotaParsers.Claude(Claude("2026-10-23T11:59:00Z", """[{"id":"session","resetsAt":null}]"""), now), "Claude missing percent");
Reject(() => QuotaParsers.Claude(Claude("2026-10-23T11:59:00Z", """[{"id":"session","usedPercent":0}]"""), now), "Claude missing resetsAt rejected");
Reject(() => QuotaParsers.Claude(Claude("2026-10-23T11:59:00Z", """[{"id":"session","usedPercent":0,"resetsAt":1793000000000}]"""), now), "Claude milliseconds rejected");
Reject(() => QuotaParsers.Claude(Claude("2026-10-23T11:59:00Z", """[{"id":"session","usedPercent":0,"resetsAt":"2026-10-24"}]"""), now), "Claude string reset rejected");
Reject(() => QuotaParsers.Claude(Claude("2026-10-23T11:59:00Z", """[{"id":"session","usedPercent":0,"resetsAt":null},{"id":"session","usedPercent":1,"resetsAt":null}]"""), now), "Claude duplicate id rejected");
Reject(() => QuotaParsers.Claude(Claude("2026-10-23T11:59:00Z", """[{"id":"model_x","usedPercent":0,"resetsAt":null}]"""), now), "Claude unknown window rejected");
Reject(() => QuotaParsers.Claude(Claude("2026-10-23T11:59:00Z", weekly).Replace("\"provider\":", "\"extra\":1,\"provider\":"), now), "Claude unknown root field rejected");
Reject(() => QuotaParsers.Claude(Claude("2026-10-23T11:59:00Z", """[{"id":"session","usedPercent":0,"resetsAt":null,"extra":1}]"""), now), "Claude unknown window field rejected");
Reject(() => QuotaParsers.Claude(Claude("2026-10-23T11:59:00Z", weekly).Replace("\"provider\":", "\"provider\":\"claude\",\"provider\":"), now), "Claude duplicate root field rejected");
Check(QuotaParsers.Claude(Claude("2026-10-23T11:59:00Z", """[{"id":"session","usedPercent":0.4,"resetsAt":1793000000.25}]"""), now).Windows![0].ResetsAt == DateTimeOffset.UnixEpoch.AddSeconds(1793000000.25), "Claude fractional Unix seconds match producer");
Reject(() => QuotaParsers.Claude(new string(' ', 16385), now), "Claude bounded payload");
Reject(() => QuotaParsers.Claude(Claude("2026-10-23T11:59:00Z", """[{"id":"session","usedPercent":20,"resetsAt":1790000000}]"""), now), "Claude expired window not reused");
Reject(() => QuotaParsers.Claude("{", now), "Claude corrupt json");
Check(QuotaParsers.Claude(Claude("2026-10-23T11:30:01Z", weekly), now).Unavailable is null, "Claude just below 30m fresh");
var codex = QuotaParsers.Codex("""{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","secondary":{"usedPercent":23,"windowDurationMins":10080,"resetsAt":1793000000}},"spark":{"primary":{"usedPercent":99,"resetsAt":1793000000}}}}} """, now);
Check(codex.Windows is { Count: 2 } && codex.Windows[0].Label == "Semanal" && !codex.Windows[1].AccountWindow, "Codex weekly and model quotas preserve roles");
Check(Presentation.QuotaLines(codex, prefs, now).Count == 1 && !Presentation.QuotaLines(codex, prefs, now)[0].Contains("spark"), "Codex model quota never substitutes account session");
Check(QuotaParsers.Codex("""{"result":{"rateLimits":{"primary":{"usedPercent":0}}}}""", now).Percent == 0, "Codex legacy bucket explicit zero");
Reject(() => QuotaParsers.Codex("""{"result":{"rateLimitsByLimitId":{"spark":{"primary":{"usedPercent":3}}}}}""", now), "Codex no account limits rejected");
Reject(() => QuotaParsers.Codex("""{"result":{"rateLimits":{"primary":{"usedPercent":null}}}}""", now), "Codex null not zero");
Reject(() => QuotaParsers.Codex("""{"error":{"code":401}}""", now), "Codex RPC error no stale fallback");
var copilot = QuotaParsers.Copilot("""{"quota_reset_date":"2026-11-01T00:00:00Z","quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":240},"chat":{"unlimited":true}}}""", now);
Check(copilot.Windows is { Count: 1 } && copilot.Percent == 20 && copilot.Windows[0].Used == 60, "Copilot explicit entitlement remaining calculation");
var remainingOnly = QuotaParsers.Copilot("""{"quota_snapshots":{"premium_interactions":{"remaining":12}}}""", now);
Check(remainingOnly.Windows![0].UsedPercent is null && Presentation.QuotaValue(remainingOnly.Windows[0]) == "12 restantes", "Copilot no invented denominator");
Reject(() => QuotaParsers.Copilot("""{"quota_snapshots":{"chat":{"unlimited":true}}}""", now), "Copilot unlimited not fake zero");
var kiro = QuotaParsers.Kiro("Credits\n████░░ 22% (11 of 50 covered)\nresets on 2026-11-01\nBonus credits: 2/10", now);
Check(kiro.Percent == 22 && kiro.Windows is { Count: 2 } && kiro.Windows[0].Limit == 50, "Kiro own usage and bonus preserved");
Check(QuotaParsers.Kiro("░░ 0% resets on 1/2", now).Windows![0].ResetsAt?.Year == 2027, "Kiro next-year reset MM/DD");
Reject(() => QuotaParsers.Kiro("login required ███ 20%", now), "Kiro auth failure rejected");
Reject(() => QuotaParsers.Kiro("some unrelated 40%", now), "Kiro arbitrary model text not quota");
Check(Presentation.Countdown(now.AddHours(2).AddMinutes(13), now, false) == "2h", "compact hours");
Check(Presentation.Countdown(now.AddHours(2).AddMinutes(13), now, true) == "2h13m", "detailed hours");
Check(Presentation.Countdown(now.AddDays(3).AddHours(4), now, true) == "3d4h", "detailed days");
Check(Presentation.Countdown(now, now, true) == "aguardando confirmação", "zero timer not renewal");
Check(Presentation.Countdown(null, now, true) == "", "absent reset no invented timer");
Check(Presentation.Percent(null) == "—" && Presentation.Percent(0) == "0%", "unknown distinct explicit zero");
Check(Presentation.Percent(0.4) == "<1%" && Presentation.Percent(0.999) == "<1%", "positive fractions never display zero");
Check(Presentation.Percent(99.9) == "99%" && Presentation.Percent(100) == "100%", "only actual 100 displays full usage");
Check(Presentation.Percent(-1) == "—", "negative percentage unavailable");
Check(Presentation.Metric(new("memory", "Memória", now, 40d/48*100, UsedBytes: 40UL*1073741824, TotalBytes:48UL*1073741824), new("memory", "Memória"), prefs) == "40/48 GiB", "nominal memory compact unit");
var gpus = new[] { new Reading("gpu:/gpu-intel/0", "Intel UHD", now, 5, 45, Vendor: GpuVendor.Intel), new Reading("gpu:/gpu-nvidia/0", "RTX 4080", now, 83, 72, Vendor: GpuVendor.Nvidia) };
Check(GpuBrand.Wordmark(gpus[0].Vendor) == "intel" && GpuBrand.Wordmark(gpus[1].Vendor) == "NVIDIA", "GPU manufacturer wordmarks from explicit vendor identity");
Check(GpuBrand.Wordmark(GpuVendor.Amd) == "AMD", "AMD wordmark");
Check(GpuBrand.Wordmark(new Reading("gpu:/unknown/0", "NVIDIA in editable label", now).Vendor) is null, "unknown GPU generic fallback never guesses vendor from name");
var sameVendor = new[] { gpus[1], new Reading("gpu:/gpu-nvidia/1", "RTX 4080 second", now, 15, 50, Vendor: GpuVendor.Nvidia) };
var sameVendorPreferences = new Preferences();
sameVendorPreferences.Discover(sameVendor);
Check(sameVendorPreferences.Indicators.Count(p => p.Id.StartsWith("gpu:", StringComparison.Ordinal)) == 2 && sameVendor.Select(g => g.Id).Distinct().Count() == 2 &&
    sameVendor.All(g => GpuBrand.Wordmark(g.Vendor) == "NVIDIA"), "two NVIDIA GPUs retain separate identities with same brand");
var gpuPrefs = new Preferences();
Check(gpuPrefs.Discover(gpus), "discover all GPUs");
Check(gpuPrefs.Indicators.Count(p => p.Id.StartsWith("gpu:")) == 2, "no multiGPU max collapse");
int index = gpuPrefs.Indicators.FindIndex(p => p.Id == gpus[1].Id);
gpuPrefs.Indicators[index] = gpuPrefs.Indicators[index] with { Label = "Minha RTX", Enabled = false, ShowTemperature = false };
gpuPrefs.Move(gpus[1].Id, -1);
var before = gpuPrefs.Indicators.ToArray();
Check(!gpuPrefs.Discover([gpus[0]]), "disappearance preserves settings");
Check(!gpuPrefs.Discover(gpus.Reverse()), "rediscovery stable hardware identity");
Check(gpuPrefs.Indicators.SequenceEqual(before), "GPU reorder label visibility temp survive reverse discovery");
Check(gpus.Reverse().Select(g => (g.Id, GpuBrand.Wordmark(g.Vendor))).OrderBy(g => g.Id).SequenceEqual(gpus.Select(g => (g.Id, GpuBrand.Wordmark(g.Vendor))).OrderBy(g => g.Id)), "GPU vendor survives enumeration reorder independently from preferences");
Check(!Presentation.Metric(gpus[1], gpuPrefs.Indicators.First(p => p.Id == gpus[1].Id), gpuPrefs).Contains("°C"), "temperature child disabled");
Check(Presentation.Metric(new("cpu", "CPU", now), new("cpu", "CPU"), prefs) == "—", "missing hardware reading not zero");
var history = new History();
history.Add(new("cpu", "CPU", now, 10), now);
history.Add(new("cpu", "CPU", now.AddSeconds(3), 20), now.AddSeconds(3));
Check(history.Get("cpu", now.AddMinutes(4)).Count == 2, "history RAM retains fresh values");
Check(history.Get("cpu", now.AddMinutes(5)).Count == 1, "history expires at five minutes");
Check(history.Get("cpu", now.AddMinutes(6)).Count == 0, "history expires even after sensor stalls");
history.Add(new("cpu", "CPU", now, 0, Unavailable: "error"), now);
Check(history.Get("cpu", now).Count == 0, "failed sample not charted as zero");
var watcher = new ResetWatcher();
var oldReading = new Reading("claude", "Claude", now, Windows: [new("session", "Sessão", 80, now.AddMinutes(1))]);
Check(watcher.Observe(oldReading).Count == 0, "first quota not reset alert");
Check(watcher.Observe(oldReading with { CapturedAt = now.AddMinutes(2) }).Count == 0, "clock crossing reset not alert");
Check(watcher.Observe(oldReading with { Windows = [new("session", "Sessão", 80, now.AddHours(5))] }).Count == 0, "later reset with same usage not confirmed");
Check(watcher.Observe(oldReading with { Windows = [new("session", "Sessão", 1, now.AddHours(10))] }).Count == 1, "new reset and reduced usage confirmed");
Check(watcher.Observe(oldReading with { Unavailable = "CLI error" }).Count == 0, "failed quota no alert");
string directory = args.Length > 0 ? args[0] : throw new ArgumentException("Pass isolated test directory");
Directory.CreateDirectory(directory);
string path = Path.Combine(directory, "preferences.json");
gpuPrefs.Save(path);
var loaded = Preferences.Load(path);
Check(loaded.Indicators.SequenceEqual(gpuPrefs.Indicators), "preferences atomic roundtrip GPU identity order");
Check(!File.Exists(path + ".new"), "atomic temporary moved");
File.WriteAllText(path, "{broken");
Check(Preferences.Load(path).Indicators.Count == Preferences.Defaults().Count, "invalid preferences recover safely");
Check(Preferences.SafeLabel("\nRTX\t4080", "gpu") == "RTX4080", "labels strip control characters");

// Native /usage fixtures: no client installation, session, credential, or Windows API needed.
string nativeWeekly = "Current week (all models)\r\n0% used\r\nResets Oct 24 at 9am (America/Fortaleza)";
var native = ClaudeNativeUsage.Parse(nativeWeekly, now);
Check(native.Windows is { Count: 1 } && native.Percent == 0 && native.Windows[0].Id == "weekly_all", "native weekly only explicit zero");
Check(native.Windows![0].ResetsAt == DateTimeOffset.Parse("2026-10-24T12:00:00Z"), "native IANA Fortaleza reset");
var nativeDual = ClaudeNativeUsage.Parse("Current session\n13% used\nResets 11am (America/Fortaleza)\n" + nativeWeekly + "\nCurrent week (Sonnet)\n22% used", now);
Check(nativeDual.Windows is { Count: 3 } && nativeDual.Percent == 13 && !nativeDual.Windows[2].AccountWindow, "native model limits preserve account slots");
Check(nativeDual.Windows![0].ResetsAt == now.AddHours(2), "native session clock local timezone");
Reject(() => ClaudeNativeUsage.Parse("Current session\n" + nativeWeekly, now), "native partial section refused");
foreach (string token in new[] { "-1", "+2", "1e2", "101", "NaN", ".5", "1.2.3", "−1", "1/2" })
    Reject(() => ClaudeNativeUsage.Parse("Current session\n" + token + "% used", now), "native malformed percent " + token);
Reject(() => ClaudeNativeUsage.Parse("Current session\n12% 13% used", now), "native conflicting percent refused");
Check(ClaudeNativeUsage.Parse("Current session\n12% 12% used", now).Percent == 12, "native duplicated screen-reader percent accepted only when equal");
Reject(() => ClaudeNativeUsage.Parse(nativeWeekly + "\n" + nativeWeekly, now), "native duplicate section refused");
foreach (string blocked in new[] { "Refreshing...", "Loading usage data", "Failed to load usage", "Error loading usage", "please log in", "run /login", "do you trust this folder", "choose a theme", "let’s get started" })
    Reject(() => ClaudeNativeUsage.Parse(nativeWeekly + "\n" + blocked, now), "native blocked screen " + blocked);
Check(!ClaudeNativeUsage.InitialPrompt("Claude Code Max\nordinary model output"), "native command requires empty prompt");
Check(!ClaudeNativeUsage.InitialPrompt("❯"), "native empty prompt requires client identity");
var protocol = new ClaudeUsageProtocol();
Check(!protocol.Observe("Claude Code", TimeSpan.Zero), "native waits for initial reliable prompt");
Check(protocol.Observe("Claude Code Max\n❯", TimeSpan.FromSeconds(1)), "native submits usage once");
Check(!protocol.Observe("Claude Code Max\n❯", TimeSpan.FromSeconds(4)) && !protocol.Ready(TimeSpan.FromSeconds(4)), "native stale initial frame cannot complete");
Check(!protocol.Observe(nativeWeekly + "\nRefreshing...", TimeSpan.FromSeconds(5)) && !protocol.Ready(TimeSpan.FromSeconds(7)), "native waits until refresh disappears");
Check(!protocol.Observe(nativeWeekly, TimeSpan.FromSeconds(8)) && !protocol.Ready(TimeSpan.FromSeconds(8.9)), "native waits stable frame");
Check(protocol.Ready(TimeSpan.FromSeconds(9)) && !protocol.Observe(nativeWeekly, TimeSpan.FromSeconds(10)), "native completed stable refresh no second command");
var terminal = new ClaudeTerminalScreen();
byte[] terminalBytes = System.Text.Encoding.UTF8.GetBytes("\u001b[2J\u001b[H" + nativeWeekly + "\r\n❯");
foreach (byte b in terminalBytes) terminal.Feed([b]);
Check(terminal.Text.Contains("❯") && ClaudeNativeUsage.Parse(terminal.Text, now).Percent == 0, "native incremental VT and split UTF8");
terminal.Feed(System.Text.Encoding.UTF8.GetBytes("\u001b[2J\u001b[HRefreshing..."));
Check(!terminal.Text.Contains("Current week"), "native redraw clears previous quotas");
terminal.Feed(System.Text.Encoding.UTF8.GetBytes("\r\u001b[2Kdone\u001b]0;secret-title\u0007"));
Check(terminal.Text == "done", "native line erase and OSC excluded");
terminal.Feed(System.Text.Encoding.UTF8.GetBytes("\u001b[2J\u001b[H123\u001b[1;2HX"));
Check(terminal.Text == "1X3", "native cursor repaint");
Check(ClaudeNativeUsage.Parse(nativeWeekly.Replace("America/Fortaleza", "Unknown/Zone"), now).Windows![0].ResetsAt is null, "native unknown timezone no invented reset");
Check(ClaudeNativeUsage.Parse(nativeWeekly.Replace("Oct 24", "Feb 30"), now).Windows![0].ResetsAt is null, "native invalid calendar no invented reset");
Check(ClaudeNativeUsage.Parse("Current session\n5% used\nResets today at 1am (UTC)", now).Windows![0].ResetsAt is null, "native expired today not tomorrow");
Check(ClaudeNativeUsage.Parse("Current session\n5% used\nResets 11pm (UTC)", DateTimeOffset.Parse("2026-10-23T22:00:00Z")).Windows![0].ResetsAt == DateTimeOffset.Parse("2026-10-23T23:00:00Z"), "native 12h clock");
Check(ClaudeNativeUsage.Parse("Current session\n5% used\nResets 1am (UTC)", DateTimeOffset.Parse("2026-10-23T23:00:00Z")).Windows![0].ResetsAt == DateTimeOffset.Parse("2026-10-24T01:00:00Z"), "native midnight rollover");
Check(ClaudeNativeUsage.Parse("Current week (all models)\n5% used\nResets Jan 1 at 1am (UTC)", DateTimeOffset.Parse("2026-12-31T23:00:00Z")).Windows![0].ResetsAt == DateTimeOffset.Parse("2027-01-01T01:00:00Z"), "native year rollover");
Check(ClaudeNativeUsage.Parse("Current session\n5% used\nResets 2:30am (America/New_York)", DateTimeOffset.Parse("2026-03-08T06:00:00Z")).Windows![0].ResetsAt is null, "native skipped DST reset unknown");
Check(ClaudeNativeUsage.Parse("Current session\n5% used\nResets 1:30am (America/New_York)", DateTimeOffset.Parse("2026-11-01T04:00:00Z")).Windows![0].ResetsAt is null, "native ambiguous DST reset unknown");
Check(CLIWorkingDirectories.Validate(null, true, "Claude") is not null && CLIWorkingDirectories.Validate(null, false, "Codex") is null, "native no automatic personal folder");
Check(CLIWorkingDirectories.Validate("relative/path", true, "Claude") is not null, "native relative folder refused");
Check(CLIWorkingDirectories.Validate(directory, true, "Claude") is null, "native explicit existing folder accepted");
var nativePreferences = new Preferences { ClaudeWorkingDirectory = directory, CodexWorkingDirectory = directory };
nativePreferences.Save(path);
Check(Preferences.Load(path).ClaudeWorkingDirectory == directory && Preferences.Load(path).CodexWorkingDirectory == directory, "native folders persist in isolated preferences only");
// Display preferences migrate in place and do not reset unrelated choices.
File.WriteAllText(path, """{"SchemaVersion":1,"MonitorId":"DISPLAY2","MemoryNominal":false,"StackedQuotas":true,"ClaudeWorkingDirectory":"trusted-folder","Indicators":[{"Id":"cpu","Label":"Meu processador","Enabled":false,"ShowTemperature":false}]}""");
var legacyDisplays = Preferences.Load(path);
Check(legacyDisplays.Displays.BarEnabled && !legacyDisplays.Displays.BarReserveSpace && legacyDisplays.Displays.BarOpacity == .75 &&
    !legacyDisplays.Displays.TrayEnabled && !legacyDisplays.Displays.WidgetEnabled, "legacy preferences migrate to independent default displays");
Check(legacyDisplays.MonitorId == "DISPLAY2" && !legacyDisplays.MemoryNominal && legacyDisplays.StackedQuotas && legacyDisplays.ClaudeWorkingDirectory == "trusted-folder" &&
    legacyDisplays.Indicators.First(p => p.Id == "cpu") is { Enabled: false, ShowTemperature: false, Label: "Meu processador" }, "display migration preserves existing preferences");
File.WriteAllText(path, """{"Displays":null}""");
Check(Preferences.Load(path).Displays.BarEnabled, "null display options recover to defaults");
var clampedDisplays = new DisplayOptions { BarOpacity = double.NaN, WidgetItemsPerPage = 99, WidgetLayout = "unknown", WidgetRotationSeconds = 0, WidgetWidth = 900 };
clampedDisplays.Normalize();
Check(clampedDisplays.BarOpacity == .75 && clampedDisplays.WidgetItemsPerPage == 8 && clampedDisplays.WidgetLayout == "horizontal" &&
    clampedDisplays.WidgetRotationSeconds == 2 && clampedDisplays.WidgetWidth == 600, "display options normalize corrupt values");
clampedDisplays.BarOpacity = -1; clampedDisplays.WidgetItemsPerPage = -1; clampedDisplays.WidgetWidth = 1; clampedDisplays.WidgetRotationSeconds = 90;
clampedDisplays.WidgetLayout = "twoRows"; clampedDisplays.Normalize();
Check(clampedDisplays.BarOpacity == .1 && clampedDisplays.WidgetItemsPerPage == 1 && clampedDisplays.WidgetWidth == 120 &&
    clampedDisplays.WidgetRotationSeconds == 60 && clampedDisplays.WidgetLayout == "twoRows", "display minimum and maximum bounds preserve valid layout");
for (int mask = 0; mask < 8; mask++)
{
    legacyDisplays.Displays.BarEnabled = (mask & 1) != 0; legacyDisplays.Displays.TrayEnabled = (mask & 2) != 0;
    legacyDisplays.Displays.WidgetEnabled = (mask & 4) != 0; legacyDisplays.Displays.BarOpacity = 1.5;
    legacyDisplays.Save(path);
    var roundTrip = Preferences.Load(path);
    Check(roundTrip.Displays.BarEnabled == ((mask & 1) != 0) && roundTrip.Displays.TrayEnabled == ((mask & 2) != 0) &&
        roundTrip.Displays.WidgetEnabled == ((mask & 4) != 0) && roundTrip.Displays.BarOpacity == 1, "three independent display switches roundtrip " + mask);
}
Check(WidgetPaging.PageCount(0, 2) == 0 && WidgetPaging.PageCount(5, 2) == 3, "widget page count includes partial final page");
Check(WidgetPaging.Page(new[] { 0, 1, 2, 3, 4 }, 2, 2).SequenceEqual(new[] { 4 }) &&
    WidgetPaging.Page(new[] { 0, 1, 2, 3, 4 }, 3, 2).SequenceEqual(new[] { 0, 1 }), "widget pages rotate and final page has no duplicated slots");
Check(WidgetPaging.Page(new[] { 0, 1, 2 }, -1, 2).SequenceEqual(new[] { 2 }) && WidgetPaging.Page(Array.Empty<int>(), 9, 2).Count == 0, "widget negative and empty page handled");
Check(WidgetPaging.Cell(0, 4, "twoRows") == (0, 0) && WidgetPaging.Cell(1, 4, "twoRows") == (1, 0) &&
    WidgetPaging.Cell(2, 4, "twoRows") == (0, 1) && WidgetPaging.Cell(3, 4, "horizontal") == (0, 3), "widget layouts use horizontal or two-row cells");
var monitorBounds = new OverlayRectangle(0, 0, 1920, 1080);
var workingBounds = new OverlayRectangle(0, 0, 1920, 1040);
var ordinaryBounds = new OverlayRectangle(100, 100, 1200, 900);
Check(!OverlayPolicy.ShouldDefer(2, false, true, true, monitorBounds, monitorBounds), "overlay BUSY own maximized settings remains topmost");
Check(!OverlayPolicy.ShouldDefer(2, true, true, true, monitorBounds, monitorBounds), "overlay maximized external window is not fullscreen even with auto-hide taskbar");
Check(!OverlayPolicy.ShouldDefer(2, true, true, false, ordinaryBounds, monitorBounds), "overlay ordinary restored window remains topmost");
Check(!OverlayPolicy.ShouldDefer(2, true, true, false, workingBounds, monitorBounds), "overlay working area alone does not cover monitor");
foreach (int? state in new int?[] { 1, 2, 5, 6, 7, null, 99 })
{
    Check(OverlayPolicy.ShouldDefer(state, true, true, false, monitorBounds, monitorBounds), "overlay full monitor restored external window defers state " + state);
    Check(!OverlayPolicy.ShouldDefer(state, false, true, false, monitorBounds, monitorBounds), "overlay rejects ineligible foreground state " + state);
    Check(!OverlayPolicy.ShouldDefer(state, true, false, false, monitorBounds, monitorBounds), "overlay rejects other monitor state " + state);
    Check(!OverlayPolicy.ShouldDefer(state, true, true, false, null, monitorBounds), "overlay missing geometry is not fullscreen state " + state);
    Check(!OverlayPolicy.ShouldDefer(state, true, true, true, monitorBounds, monitorBounds), "overlay excludes maximized geometry state " + state);
}
Check(OverlayPolicy.ShouldDefer(3, true, true, true, null, monitorBounds), "overlay D3D eligible same monitor requires no geometry");
Check(!OverlayPolicy.ShouldDefer(3, true, false, false, monitorBounds, monitorBounds), "overlay D3D other monitor remains topmost");
Check(!OverlayPolicy.ShouldDefer(3, false, true, false, monitorBounds, monitorBounds), "overlay D3D ineligible foreground remains topmost");
Check(OverlayPolicy.ShouldDefer(4, false, false, false, null, monitorBounds), "overlay presentation mode defers globally without foreground");
var negativeMonitor = new OverlayRectangle(-1920, -1080, 0, 0);
Check(OverlayPolicy.ShouldDefer(2, true, true, false, negativeMonitor, negativeMonitor), "overlay exact negative monitor coordinates cover");
Check(OverlayPolicy.ShouldDefer(null, true, true, false, new(-1921, -1081, 1, 1), negativeMonitor), "overlay enclosing bounds cover negative monitor");
foreach (var shortBounds in new[] { new OverlayRectangle(1, 0, 1920, 1080), new(0, 1, 1920, 1080), new(0, 0, 1919, 1080), new(0, 0, 1920, 1079) })
    Check(!OverlayPolicy.ShouldDefer(2, true, true, false, shortBounds, monitorBounds), "overlay missing one pixel at any edge is not fullscreen " + shortBounds);
foreach (var invalidBounds in new[] { new OverlayRectangle(0, 0, 0, 1080), new(0, 0, 1920, 0), new(1920, 0, 0, 1080), new(0, 1080, 1920, 0) })
{
    Check(!OverlayPolicy.ShouldDefer(2, true, true, false, invalidBounds, monitorBounds), "overlay empty or inverted foreground rejected " + invalidBounds);
    Check(!OverlayPolicy.ShouldDefer(2, true, true, false, monitorBounds, invalidBounds), "overlay empty or inverted monitor rejected " + invalidBounds);
}
// M06: custom rows are an additive preference; physical identity remains stable.
string[] customIds = ["cpu", "memory", "claude", "codex", "kiro"];
var custom = new DisplayOptions { WidgetWidth = 402, BarEnabled = false, TrayEnabled = true, WidgetEnabled = true };
custom.UseHardwareAgentsPreset();
var customCells = WidgetPaging.LayoutPage(customIds, x => x, 0, custom.WidgetItemsPerPage, custom.WidgetLayout, custom.WidgetPlacements);
Check(customCells.Count(x => x.Row == 0) == 2 && customCells.Count(x => x.Row == 1) == 3 &&
    customCells.Select(x => x.Item).SequenceEqual(customIds), "custom preset retains all five IDs in independent 2+3 rows");
Check(custom.WidgetWidth == 402 && !custom.BarEnabled && custom.TrayEnabled && custom.WidgetEnabled,
    "custom preset preserves width and presentation switches");
Check(custom.WidgetItemsPerPage == 5 && custom.WidgetLayout == "customRows", "custom preset sets five slots and custom layout");
foreach (int size in new[] { 0, 1, 5, 8, 9 })
{
    var ids = Enumerable.Range(0, size).Select(i => "item:" + i).ToArray();
    var positions = ids.Select((id, i) => new WidgetPlacement(id, i % 2, i / 2)).ToArray();
    var pages = Enumerable.Range(0, WidgetPaging.PageCount(size, 8)).SelectMany(p =>
        WidgetPaging.LayoutPage(ids, x => x, p, 8, "customRows", positions)).ToArray();
    Check(pages.Length == size && pages.Select(x => x.Item).Distinct().Count() == size, "custom pages cover once size " + size);
}
var secondPage = WidgetPaging.LayoutPage(Enumerable.Range(0, 9).Select(i => "id" + i).ToArray(), x => x, 1, 8, "customRows");
Check(secondPage is [{ Item: "id8", Row: 0, Column: 0 }], "custom final page partial without duplicate slot");
var bottomOnly = WidgetPaging.LayoutPage(new[] { "claude", "codex" }, x => x, 0, 8, "customRows", custom.WidgetPlacements);
Check(bottomOnly.All(x => x.Row == 1) && bottomOnly.Select(x => x.Row).Distinct().Count() == 1 &&
    bottomOnly.Select(x => x.Column).SequenceEqual(new[] { 0, 1 }), "empty top row has no cells or reserved column");
Check(WidgetPaging.LayoutPage(Array.Empty<string>(), x => x, -9, 8, "customRows").Count == 0, "empty custom layout safe");
var malformedPositions = new List<WidgetPlacement> { new("cpu", 9, 10), new("cpu", 0, -100), new(" ", 0, 0),
    new(new string('x', 257), 0, 0), new("control\n", 0, 0), new("memory", -7, int.MaxValue), null! };
var normalizedPositions = WidgetPaging.NormalizePlacements(malformedPositions);
Check(normalizedPositions.Count == 2 && normalizedPositions.Single(x => x.Id == "cpu").Row == 1 &&
    normalizedPositions.Single(x => x.Id == "memory").Row == 0 && normalizedPositions.All(x => x.Order == 0),
    "placement normalization first duplicate wins and clamps row with per-row reindex");
Check(WidgetPaging.NormalizePlacements(Enumerable.Range(0, 150).Select(i => new WidgetPlacement("id" + i, 0, i))).Count == 128,
    "placement count bounded at 128");
Check(WidgetPaging.NormalizePlacements([new("b", 0, 0), new("a", 0, 0)]).Select(x => x.Id).SequenceEqual(new[] { "a", "b" }),
    "placement ties use ordinal ID");
custom.MoveWidget("codex", -1, customIds);
Check(custom.WidgetPlacements.Where(x => x.Row == 1).Select(x => x.Id).SequenceEqual(new[] { "codex", "claude", "kiro" }),
    "custom arrow moves within row");
custom.MoveWidget("codex", -1, customIds);
Check(custom.WidgetPlacements.First(x => x.Row == 1).Id == "codex", "custom row boundary does not wrap");
custom.ChangeWidgetRow("cpu", customIds);
Check(custom.WidgetPlacements.Single(x => x.Id == "cpu") is { Row: 1, Order: 3 }, "custom change row appends and keeps ID");
custom.WidgetPlacements.Add(new("gpu:physical-1", 1, 4)); custom.Normalize();
var hiddenPositions = custom.WidgetPlacements.ToArray();
var disconnected = WidgetPaging.LayoutPage(customIds, x => x, 0, 8, "customRows", custom.WidgetPlacements);
var reconnected = WidgetPaging.LayoutPage(customIds.Append("gpu:physical-1").ToArray(), x => x, 0, 8, "customRows", custom.WidgetPlacements);
Check(disconnected.Count == 5 && reconnected.Single(x => x.Item == "gpu:physical-1").Row == 1 &&
    custom.WidgetPlacements.SequenceEqual(hiddenPositions), "GPU disappearance and return preserve placement identity");
var appended = WidgetPaging.LayoutPage(new[] { "fresh", "kiro", "cpu", "unknown" }, x => x, 0, 8, "customRows", [new("cpu", 0, 0), new("kiro", 1, 0)]);
Check(appended.Select(x => x.Item).SequenceEqual(new[] { "cpu", "fresh", "unknown", "kiro" }), "missing placements append row zero in snapshot order");
var migratedLayout = new DisplayOptions { WidgetLayout = "twoRows", WidgetItemsPerPage = 4, WidgetWidth = 402 };
migratedLayout.UseCustomLayout(customIds);
Check(migratedLayout.WidgetPlacements.Single(x => x.Id == "cpu").Row == 0 && migratedLayout.WidgetPlacements.Single(x => x.Id == "memory").Row == 1 &&
    migratedLayout.WidgetPlacements.Single(x => x.Id == "codex").Row == 1 && migratedLayout.WidgetWidth == 402, "first custom selection converts legacy column-first layout");
var persistedCustom = new Preferences { Displays = custom }; persistedCustom.Save(path);
var loadedCustom = Preferences.Load(path);
Check(loadedCustom.Displays.WidgetPlacements.SequenceEqual(custom.WidgetPlacements) && loadedCustom.Displays.WidgetLayout == "customRows" &&
    loadedCustom.Displays.WidgetItemsPerPage == 5 && loadedCustom.Displays.WidgetWidth == 402, "custom placement preferences roundtrip without migration loss");
Console.WriteLine($"SUCCESS {count} checks; no authenticated CLI or native Windows calls executed.");
