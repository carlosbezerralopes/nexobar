using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using NexoBar.Setup.Core;

string baseDir = Path.GetFullPath(args.Single());
Directory.CreateDirectory(baseDir);
int checks = 0;
void Check(bool pass, string name) { if (!pass) throw new Exception(name); checks++; Console.WriteLine("PASS " + name); }
void Throws(Action action, string name) { try { action(); } catch (Exception e) when (e is IOException or InvalidDataException or OperationCanceledException) { Check(true, name); return; } throw new Exception("Expected rejection: " + name); }
async Task Reject(Func<Task> action, string name) { try { await action(); } catch (Exception e) when (e is IOException or InvalidDataException or OperationCanceledException) { Check(true, name); return; } throw new Exception("Expected rejection: " + name); }
byte[] bytes = Encoding.UTF8.GetBytes("isolated synthetic app"), msix = Encoding.UTF8.GetBytes("synthetic MSIX: never deployed");
var manifest = new InstallManifest(1, "0.6.0", "x64", "NexoBar.Widget", "CN=NexoBar", "0.6.0.0",
    [new("app/NexoBar.exe", bytes.Length, InstallManifest.Hash(bytes)), new("companion/NexoBar.Widget.msix", msix.Length, InstallManifest.Hash(msix))]);
byte[] Archive(IEnumerable<(string, byte[], int)>? entries = null)
{
    using var stream = new MemoryStream();
    using (var zip = new ZipArchive(stream, ZipArchiveMode.Create, true))
        foreach (var (name, data, attributes) in entries ?? new[] { ("app/NexoBar.exe", bytes, 0), ("companion/NexoBar.Widget.msix", msix, 0) })
        { var entry = zip.CreateEntry(name); entry.ExternalAttributes = attributes; using var target = entry.Open(); target.Write(data); }
    return stream.ToArray();
}
byte[] archive = Archive();
string manifestHash = InstallManifest.Hash(JsonSerializer.SerializeToUtf8Bytes(manifest));
(InstallTransaction, InstallEnvironment, FakeServices) Scenario(string name)
{
    string dir = Path.Combine(baseDir, name + "-" + Guid.NewGuid().ToString("N"));
    var fake = new FakeServices(); var environment = new InstallEnvironment(Path.Combine(dir, "programs"), Path.Combine(dir, "prefs", "indicators.json"),
        Path.Combine(dir, "menu", "NexoBar.lnk"), Path.Combine(dir, "startup", "NexoBar.lnk"), fake);
    return (new(environment, manifest, manifestHash), environment, fake);
}
Task<InstallResult> Run(InstallTransaction t, InstallOptions? options = null, byte[]? observed = null, CancellationToken token = default) =>
    t.ExecuteAsync(() => new MemoryStream(archive), options ?? new(), observed, token);

manifest.Validate(); Check(true, "valid manifest");
foreach (string path in new[] { "../evil", "/absolute", "C:/evil", "app/foo:stream", "app/../evil", "app\\evil", "app/NUL.txt", "app/foo.", "app/a//b" })
    Throws(() => SafePaths.ValidateRelative(path), "unsafe path " + path);
Throws(() => (manifest with { Files = [.. manifest.Files, manifest.Files[0] with { Path = "app/nexobar.exe" }] }).Validate(), "manifest duplicate case");
Throws(() => (manifest with { SchemaVersion = 9 }).Validate(), "future manifest");
Throws(() => (manifest with { Version = "0.5.0", CompanionVersion = "0.5.0.0" }).Validate(), "previous release payload rejected");
Throws(() => (manifest with { CompanionVersion = "0.5.0.0" }).Validate(), "previous companion payload rejected");
foreach (var (label, entries) in new[] {
    ("hash", new[] { ("app/NexoBar.exe", new byte[bytes.Length], 0), ("companion/NexoBar.Widget.msix", msix, 0) }),
    ("zip slip", new[] { ("../evil", bytes, 0) }),
    ("ADS", new[] { ("app/a:ads", bytes, 0) }),
    ("symlink", new[] { ("app/NexoBar.exe", bytes, 0xA000 << 16) }),
    ("reparse", new[] { ("app/NexoBar.exe", bytes, (int)FileAttributes.ReparsePoint) }),
    ("duplicate", new[] { ("app/NexoBar.exe", bytes, 0), ("app/nexobar.exe", bytes, 0) }),
    ("missing", new[] { ("app/NexoBar.exe", bytes, 0) }),
    ("unlisted", new[] { ("other", bytes, 0) }) })
    Throws(() => { string dir = Path.Combine(baseDir, "extract-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(dir); using var input = new MemoryStream(Archive(entries)); manifest.ExtractVerified(input, dir, default); }, "ZIP " + label);

var (fresh, env, fake) = Scenario("fresh");
Check(fresh.Plan().Kind == InstallKind.New, "new plan");
var first = await Run(fresh);
Check(first.AppInstalled && first.Complete && File.Exists(first.Executable), "fresh transaction");
Check(!Directory.Exists(Path.GetDirectoryName(env.StartupShortcut)), "autostart untouched zero writes");
var prefs = JsonNode.Parse(File.ReadAllBytes(env.Preferences))!;
Check(prefs["Indicators"]!.AsArray().Where(i => i!["Id"]!.GetValue<string>() is not ("cpu" or "memory")).All(i => !i!["Enabled"]!.GetValue<bool>()), "fresh all AI off");
Check(prefs["Displays"]!["BarEnabled"]!.GetValue<bool>() && !prefs["Displays"]!["TrayEnabled"]!.GetValue<bool>() && !prefs["Displays"]!["WidgetEnabled"]!.GetValue<bool>(), "fresh hardware presentation defaults");
Check(fresh.Plan().Kind == InstallKind.Reuse, "same version reuse");
byte[] stateBefore = File.ReadAllBytes(env.StatePath), menuBefore = File.ReadAllBytes(env.StartMenuShortcut);
string hashBefore = InstallManifest.HashFile(first.Executable); DateTime modified = File.GetLastWriteTimeUtc(first.Executable);
await Run(fresh, observed: File.ReadAllBytes(env.Preferences));
Check(InstallManifest.HashFile(first.Executable) == hashBefore && File.GetLastWriteTimeUtc(first.Executable) == modified, "idempotent no app copy");
Check(File.ReadAllBytes(env.StatePath).SequenceEqual(stateBefore) && File.ReadAllBytes(env.StartMenuShortcut).SequenceEqual(menuBefore), "idempotent shortcut and receipt bytes");
File.WriteAllBytes(first.Executable, "corrupt"u8.ToArray());
Check(fresh.Plan().Kind == InstallKind.Repair, "modified same version refuses unapproved repair");
await Reject(() => Run(fresh, observed: File.ReadAllBytes(env.Preferences)), "corrupt target preserved");

var (newer, newerEnv, _) = Scenario("newer"); Directory.CreateDirectory(newerEnv.Root);
File.WriteAllText(newerEnv.StatePath, JsonSerializer.Serialize(new InstallState("NexoBar", "0.7.0", "unused", "unused")));
Check(newer.Plan().Kind == InstallKind.RefuseDowngrade, "newer installed no downgrade");
await Reject(() => Run(newer), "downgrade transaction rejected");
var (upgrade, upgradeEnv, _) = Scenario("upgrade"); Directory.CreateDirectory(Path.Combine(upgradeEnv.Root, "versions", "0.5.0"));
File.WriteAllText(Path.Combine(upgradeEnv.Root, "versions", "0.5.0", "previous.txt"), "keep");
File.WriteAllText(upgradeEnv.StatePath, JsonSerializer.Serialize(new InstallState("NexoBar", "0.5.0", "unused", "unused")));
Check(upgrade.Plan().Kind == InstallKind.Upgrade, "upgrade plan"); await Run(upgrade);
Check(File.ReadAllText(Path.Combine(upgradeEnv.Root, "versions", "0.5.0", "previous.txt")) == "keep", "old version preserved");
Check(File.Exists(Path.Combine(upgradeEnv.Root, "versions", "0.6.0", "NexoBar.exe")) &&
    JsonSerializer.Deserialize<InstallState>(File.ReadAllBytes(upgradeEnv.StatePath))!.Version == "0.6.0", "upgrade 0.5 to 0.6 writes new receipt and target");
var (collision, collisionEnv, _) = Scenario("collision"); Directory.CreateDirectory(Path.Combine(collisionEnv.Root, "versions", "0.6.0"));
Check(collision.Plan().Kind == InstallKind.UnknownCollision, "unknown target collision");
File.WriteAllText(collisionEnv.StatePath, JsonSerializer.Serialize(new InstallState("NexoBar", "0.5.0", "unused", "old-manifest")));
Check(collision.Plan().Kind == InstallKind.UnknownCollision, "previous receipt does not claim existing 0.6 target");
var (active, _, activeFake) = Scenario("active"); activeFake.Running = true; await Reject(() => Run(active), "running app no kill");
var (cancel, cancelEnv, _) = Scenario("cancel"); using var cts = new CancellationTokenSource(); cts.Cancel();
await Reject(() => Run(cancel, token: cts.Token), "cancel before commit"); Check(!File.Exists(cancelEnv.StatePath), "cancel leaves no receipt");

byte[] original = Encoding.UTF8.GetBytes("{\"SchemaVersion\":1,\"Indicators\":[{\"Id\":\"claude\",\"Label\":\"Mine\",\"Enabled\":true}],\"ClaudeWorkingDirectory\":\"C:/kept\",\"Unknown\":{\"keep\":42},\"Displays\":{\"WidgetWidth\":579,\"Unknown\":\"keep\",\"WidgetPlacements\":[{\"Id\":\"cpu\",\"Row\":1,\"Order\":2}]}}");
var patched = PreferencesPatch.Prepare(original, new(TrayEnabled: true)); var node = JsonNode.Parse(patched.After!)!;
Check(node["Unknown"]!["keep"]!.GetValue<int>() == 42 && node["Displays"]!["WidgetWidth"]!.GetValue<int>() == 579 && node["ClaudeWorkingDirectory"]!.GetValue<string>() == "C:/kept" && node["Indicators"]![0]!["Label"]!.GetValue<string>() == "Mine", "unknown prefs and folders preserved");
Check(node["Displays"]!["WidgetPlacements"]!.ToJsonString() == JsonNode.Parse(original)!["Displays"]!["WidgetPlacements"]!.ToJsonString(), "placements preserved");
foreach (var invalid in new[] { "{oops", "{\"SchemaVersion\":2,\"Indicators\":[]}", "{\"SchemaVersion\":1,\"Indicators\":[],\"Displays\":9}" })
{ var input = Encoding.UTF8.GetBytes(invalid); var p = PreferencesPatch.Prepare(input, new(true)); Check(p.After is null && p.Before!.SequenceEqual(input) && p.Warning is not null, "corrupt/future preferences untouched"); }
var (race, raceEnv, _) = Scenario("race"); Directory.CreateDirectory(Path.GetDirectoryName(raceEnv.Preferences)!); File.WriteAllBytes(raceEnv.Preferences, original);
File.AppendAllText(raceEnv.Preferences, " "); await Reject(() => Run(race, new(true), original), "preferences race rejected");
Check(!File.Exists(raceEnv.StatePath), "race before app commit");
Throws(() => PreferencesPatch.Write(raceEnv.Preferences, patched), "atomic preference patch race rejected");
Check(File.ReadAllBytes(raceEnv.Preferences).SequenceEqual([.. original, (byte)' ']), "concurrent preferences bytes preserved");

foreach (var (name, outcome) in new[] { ("Store missing", new ComponentResult(false, "Store absent")), ("Store failed", new ComponentResult(false, "Store error")),
    ("certificate no consent", new ComponentResult(false, "trust declined")), ("certificate untrusted", new ComponentResult(false, "untrusted")),
    ("companion in use", new ComponentResult(false, "close host")), ("Store present companion equal", new ComponentResult(true, "reuse")),
    ("companion upgrade", new ComponentResult(true, "updated")), ("certificate trusted", new ComponentResult(true, "trusted")) })
{
    var (t, e, f) = Scenario(name); f.Result = outcome; var result = await Run(t, new(WidgetEnabled: true));
    Check(result.AppInstalled && result.Complete == outcome.Success && f.WidgetCalls == 1 && File.Exists(e.StatePath), "simulated " + name);
    Check(File.Exists(result.Executable), "partial preserves app " + name);
}
var (partial, partialEnv, partialFake) = Scenario("cancel-component"); partialFake.ThrowWidget = true;
var partialResult = await Run(partial, new(WidgetEnabled: true)); Check(partialResult.AppInstalled && !partialResult.Complete, "cancel after app commit partial");
partialFake.ThrowWidget = false; await Run(partial, new(WidgetEnabled: true), File.ReadAllBytes(partialEnv.Preferences));
Check(partial.Plan().Kind == InstallKind.Reuse, "partial resume reuses app");

var (badShortcut, badShortcutEnv, _) = Scenario("shortcut-collision"); Directory.CreateDirectory(Path.GetDirectoryName(badShortcutEnv.StartMenuShortcut)!);
File.WriteAllText(badShortcutEnv.StartMenuShortcut, "foreign shortcut"); await Reject(() => Run(badShortcut), "foreign shortcut preserved");
Check(File.ReadAllText(badShortcutEnv.StartMenuShortcut) == "foreign shortcut" && !File.Exists(badShortcutEnv.StatePath), "collision no overwrite or receipt");
var (rollback, rollbackEnv, _) = Scenario("rollback"); Directory.CreateDirectory(rollbackEnv.StatePath);
await Reject(() => Run(rollback), "receipt write failure rollback");
Check(!File.Exists(rollbackEnv.StartMenuShortcut) && !Directory.Exists(Path.Combine(rollbackEnv.Root, "versions", "0.6.0")), "shortcut rollback and owned target cleanup");
var (rollbackOld, rollbackOldEnv, rollbackOldFake) = Scenario("rollback-old");
string oldExe = Path.Combine(rollbackOldEnv.Root, "versions", "0.5.0", "NexoBar.exe"); Directory.CreateDirectory(Path.GetDirectoryName(oldExe)!); File.WriteAllText(oldExe, "old version intact");
File.WriteAllText(rollbackOldEnv.StatePath, JsonSerializer.Serialize(new InstallState("NexoBar", "0.5.0", oldExe, "old")));
Directory.CreateDirectory(Path.GetDirectoryName(rollbackOldEnv.StartMenuShortcut)!); byte[] oldLink = Encoding.UTF8.GetBytes("NEXOBAR:" + oldExe); File.WriteAllBytes(rollbackOldEnv.StartMenuShortcut, oldLink);
rollbackOldFake.OnShortcut = () => { File.Delete(rollbackOldEnv.StatePath); Directory.CreateDirectory(rollbackOldEnv.StatePath); };
await Reject(() => Run(rollbackOld), "receipt failure during upgrade");
Check(File.ReadAllBytes(rollbackOldEnv.StartMenuShortcut).SequenceEqual(oldLink) && File.ReadAllText(oldExe) == "old version intact", "upgrade rollback keeps previous shortcut and version");
var (untouchedAuto, untouchedAutoEnv, _) = Scenario("startup-preserve"); Directory.CreateDirectory(Path.GetDirectoryName(untouchedAutoEnv.StartupShortcut)!);
File.WriteAllText(untouchedAutoEnv.StartupShortcut, "foreign startup remains"); var autoModified = File.GetLastWriteTimeUtc(untouchedAutoEnv.StartupShortcut);
await Run(untouchedAuto);
Check(File.ReadAllText(untouchedAutoEnv.StartupShortcut) == "foreign startup remains" && File.GetLastWriteTimeUtc(untouchedAutoEnv.StartupShortcut) == autoModified, "unchanged autostart preserves foreign shortcut zero writes");
var (auto, autoEnv, _) = Scenario("autostart"); await Run(auto, new(AutoStart: true)); Check(File.Exists(autoEnv.StartupShortcut), "autostart explicit optin");
await Run(auto, new(AutoStart: false), File.ReadAllBytes(autoEnv.Preferences)); Check(!File.Exists(autoEnv.StartupShortcut), "autostart explicit optout own shortcut");
foreach (var version in new[] { new Version(0, 6, 0, 0), new Version(0, 7, 0, 0) })
{
    var platform = new FakeWidgetPlatform { Host = new(1, 2, 8, 0), Companion = version };
    Check((await WidgetCoordinator.Ensure(platform, "synthetic", true, default, null)).Success && platform.HostCalls == 0 && platform.CompanionCalls == 0, "platform equal/newer companion no deployment " + version);
}
var declined = new FakeWidgetPlatform();
Check(!(await WidgetCoordinator.Ensure(declined, "synthetic", false, default, null)).Success && declined.HostCalls == 0 && declined.CompanionCalls == 0, "declined trust no Store or MSIX writes");
var liar = new FakeWidgetPlatform { ConfirmHost = false };
Check(!(await WidgetCoordinator.Ensure(liar, "synthetic", true, default, null)).Success && liar.HostCalls == 1 && liar.CompanionCalls == 0, "Store exit success not package proof");
var missingCompanion = new FakeWidgetPlatform { Host = new(1, 2, 8, 0), ConfirmCompanion = false };
Check(!(await WidgetCoordinator.Ensure(missingCompanion, "synthetic", true, default, null)).Success, "MSIX result success not package proof");
var oldCompanion = new FakeWidgetPlatform { Host = new(1, 2, 8, 0), Companion = new(0, 5, 0, 0) };
Check((await WidgetCoordinator.Ensure(oldCompanion, "synthetic", true, default, null)).Success && oldCompanion.HostCalls == 0 && oldCompanion.CompanionCalls == 1, "platform upgrades old companion only");
var freshPlatform = new FakeWidgetPlatform();
Check((await WidgetCoordinator.Ensure(freshPlatform, "synthetic", true, default, null)).Success && freshPlatform.HostCalls == 1 && freshPlatform.CompanionCalls == 1, "platform fresh verified after each request");
Console.WriteLine($"PASS {checks} checks. File transactions isolated; Store/MSIX/certificate services SIMULATED, no real deployment/trust/shortcuts.");

sealed class FakeServices : IInstallServices
{
    public bool Running, ThrowWidget; public int WidgetCalls; public Action? OnShortcut; public ComponentResult Result = new(true, "simulated");
    public bool IsAppRunning() => Running;
    public byte[] CreateShortcut(string executable) { OnShortcut?.Invoke(); return Encoding.UTF8.GetBytes("NEXOBAR:" + executable); }
    public bool OwnsShortcut(byte[] content, string root) => Encoding.UTF8.GetString(content).StartsWith("NEXOBAR:" + root, StringComparison.Ordinal);
    public Task<ComponentResult> EnsureWidgetAsync(string package, CancellationToken cancellationToken, IProgress<string>? progress)
    { WidgetCalls++; if (ThrowWidget) throw new OperationCanceledException(); return Task.FromResult(Result); }
}

sealed class FakeWidgetPlatform : IWidgetPlatform
{
    public Version? Host, Companion; public int HostCalls, CompanionCalls; public bool ConfirmHost = true, ConfirmCompanion = true;
    public Version? HostVersion() => Host;
    public Version? CompanionVersion() => Companion;
    public Task<ComponentResult> EnsureHost(CancellationToken token, IProgress<string>? progress)
    { HostCalls++; if (ConfirmHost) Host = new(1, 2, 8, 0); return Task.FromResult(new ComponentResult(true, "simulated request exit0")); }
    public Task<ComponentResult> EnsureCompanion(string package, CancellationToken token, IProgress<string>? progress)
    { CompanionCalls++; if (ConfirmCompanion) Companion = new(0, 6, 0, 0); return Task.FromResult(new ComponentResult(true, "simulated request exit0")); }
}
