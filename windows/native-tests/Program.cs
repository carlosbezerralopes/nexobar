using System.Diagnostics;
using NexoBar.Core;
using NexoBar.Windows;

if (!OperatingSystem.IsWindows()) { Console.Error.WriteLine("SKIP: lifecycle ConPTY exige Windows nativo"); return 3; }
if (args.Length >= 3 && args[0] == "--synthetic-client")
{
    string mode = args[1], folder = args[2];
    Console.InputEncoding = new System.Text.UTF8Encoding(false);
    Console.OutputEncoding = new System.Text.UTF8Encoding(false);
    File.WriteAllText(Path.Combine(folder, "console.json"), System.Text.Json.JsonSerializer.Serialize(new { Console.IsInputRedirected, Console.IsOutputRedirected, Console.IsErrorRedirected }));
    File.WriteAllText(Path.Combine(folder, "root.pid"), Environment.ProcessId.ToString());
    var child = Process.Start(new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, ArgumentList = { "--synthetic-descendant", folder } })!;
    File.WriteAllText(Path.Combine(folder, "child.pid"), child.Id.ToString());
    if (mode == "root-exit") return 0;
    if (mode is "trust" or "login" or "setup")
    {
        Console.Write(mode == "trust" ? "Do you trust this folder?" : mode == "login" ? "Please log in" : "Choose a theme");
        // Any submitted input is a failure of the parent protocol; never expect approval.
        string? input = Console.ReadLine(); File.WriteAllText(Path.Combine(folder, "unexpected-input"), input ?? "EOF");
        Thread.Sleep(60000); return 0;
    }
    Console.Write("Claude Code Max\r\n❯\r\n");
    string? request = Console.ReadLine();
    File.WriteAllText(Path.Combine(folder, "request.txt"), request ?? "EOF");
    if (request != "/usage") return 2;
    if (mode == "excess") { for (int n = 0; n < 1024; n++) Console.Write(new string('x', 1024)); }
    else if (mode == "success")
    {
        Console.Write("\u001b[2J\u001b[HCurrent week (all models)\r\n14% used\r\nRefreshing...");
        Thread.Sleep(1600);
        Console.Write("\u001b[2J\u001b[HCurrent week (all models)\r\n17% used\r\nResets Oct 24 at 9am (America/Fortaleza)");
    }
    Thread.Sleep(60000); return 0;
}
if (args.Length >= 2 && args[0] == "--synthetic-descendant") { Thread.Sleep(60000); return 0; }
if (args.Length != 1 || !Path.IsPathFullyQualified(args[0])) { Console.Error.WriteLine("Informe pasta absoluta isolada para evidências."); return 2; }
Directory.CreateDirectory(args[0]);
int checks = 0;
void Check(bool condition, string label) { if (!condition) throw new Exception("FAIL " + label); Console.WriteLine("PASS " + label); checks++; }
void DiscoveryCases()
{
    string fixtures = Path.Combine(args[0], "discovery-" + Guid.NewGuid().ToString("N"));
    string home = Path.Combine(fixtures, "home"), appData = Path.Combine(fixtures, "roaming data"), first = Path.Combine(fixtures, "first prefix"), second = Path.Combine(fixtures, "second prefix");
    string Touch(string path, string content = "synthetic fixture; never execute") { Directory.CreateDirectory(Path.GetDirectoryName(path)!); File.WriteAllText(path, content); return Path.GetFullPath(path); }
    string Package(string prefix, string manifest = "{\"name\":\"@anthropic-ai/claude-code\",\"bin\":{\"claude\":\"bin/claude.exe\"}}")
    {
        string package = Path.Combine(prefix, "node_modules", "@anthropic-ai", "claude-code");
        Touch(Path.Combine(package, "package.json"), manifest);
        return Touch(Path.Combine(package, "bin", "claude.exe"));
    }
    string search = first + Path.PathSeparator + second;
    string? Locate(string? path = null) => OwnedCommand.LocateClaudeNative(home, path ?? search, appData);
    Check(Locate() is null, "missing Claude is unavailable");
    string shimMarker = Path.Combine(fixtures, "shim-executed");
    Touch(Path.Combine(first, "claude.cmd"), "@echo off\r\necho executed>\"" + shimMarker + "\"\r\n");
    Touch(Path.Combine(first, "claude.ps1"), "throw 'shim must never execute'");
    Check(Locate() is null, "shim-only installation is unavailable");
    string npm = Package(second);
    Check(Locate() == npm, "known npm native package found through PATH with spaces");
    string firstNpm = Package(first);
    Check(Locate() == firstNpm, "npm prefixes retain PATH order");
    string canonical = Package(Path.Combine(appData, "npm"));
    Check(Locate("") == canonical, "canonical APPDATA npm fallback");
    Check(Locate("\"" + second + "\"") == npm, "quoted npm PATH prefix");
    string pathNative = Touch(Path.Combine(second, "claude.exe"));
    Check(Locate() == pathNative, "PATH native executable precedes npm package");
    string earlierNative = Touch(Path.Combine(first, "claude.exe"));
    Check(Locate() == earlierNative, "native PATH order preserved");
    string cargo = Touch(Path.Combine(home, ".cargo", "bin", "claude.exe"));
    Check(Locate() == cargo, "cargo native precedence preserved");
    string local = Touch(Path.Combine(home, ".local", "bin", "claude.exe"));
    Check(Locate() == local, "local native executable has first precedence");
    foreach (var invalid in new[] {
        "{\"name\":\"another-package\",\"bin\":{\"claude\":\"bin/claude.exe\"}}",
        "{\"name\":\"@anthropic-ai/claude-code\",\"bin\":{\"claude\":\"../claude.exe\"}}",
        "{\"name\":\"@anthropic-ai/claude-code\",\"bin\":{\"claude\":\"bin/../bin/claude.exe\"}}",
        "{\"name\":\"@anthropic-ai/claude-code\",\"bin\":{\"claude\":\"C:/outside/claude.exe\"}}",
        "{\"name\":\"@anthropic-ai/claude-code\",\"bin\":\"bin/claude.exe\"}",
        "{\"name\":null,\"bin\":{\"claude\":true}}", "[]", "{invalid" })
    {
        string isolated = Path.Combine(fixtures, "invalid-" + Guid.NewGuid().ToString("N"));
        Package(isolated, invalid);
        Check(OwnedCommand.LocateClaudeNative(Path.Combine(isolated, "home"), isolated, Path.Combine(isolated, "roaming")) is null,
            "invalid npm identity or entry rejected");
    }
    string missing = Path.Combine(fixtures, "missing-native");
    string absent = Package(missing); File.Delete(absent);
    Check(OwnedCommand.LocateClaudeNative(Path.Combine(missing, "home"), missing, Path.Combine(missing, "roaming")) is null, "npm manifest without native entry rejected");
    Check(!File.Exists(shimMarker), "discovery never executes npm shims");
}
DiscoveryCases();
async Task Gone(string folder)
{
    foreach (string file in new[] { "root.pid", "child.pid" })
    {
        string path = Path.Combine(folder, file);
        if (!File.Exists(path)) continue;
        int pid = int.Parse(File.ReadAllText(path), System.Globalization.CultureInfo.InvariantCulture);
        try { using var process = Process.GetProcessById(pid); Check(await Task.Run(() => process.WaitForExit(3000)), "owned process exited " + file); }
        catch (ArgumentException) { Check(true, "owned process already reaped " + file); }
    }
}
async Task RunCase(string mode, string name)
{
    string folder = Path.Combine(args[0], name); Directory.CreateDirectory(folder);
    foreach (string stale in Directory.GetFiles(folder)) File.Delete(stale);
    using var runner = new ClaudeConPty(); using var cancellation = new CancellationTokenSource();
    if (mode == "cancel") cancellation.CancelAfter(2000);
    var task = Task.Run(() => runner.Run(mode == "startup-failure" ? Path.Combine(folder, "absent.exe") : Environment.ProcessPath!,
        ["--synthetic-client", mode, folder], folder, cancellation.Token, TimeSpan.FromSeconds(mode == "timeout" ? 3 : 12)));
    if (mode == "shutdown") { await Task.Delay(2000); runner.Dispose(); }
    try
    {
        var result = await task.WaitAsync(TimeSpan.FromSeconds(20));
        Check(mode == "success" && result.Percent == 17, "completed refresh returns final17%, not initial14%");
    }
    catch (Exception e) when (e is FormatException or IOException or OperationCanceledException or System.ComponentModel.Win32Exception)
    {
        bool expected = mode switch
        {
            "trust" or "login" or "setup" => e is FormatException,
            "timeout" or "cancel" or "shutdown" => e is OperationCanceledException,
            "excess" or "root-exit" => e is IOException,
            "startup-failure" => e is System.ComponentModel.Win32Exception { NativeErrorCode: 2 },
            _ => false
        };
        if (!expected) throw new Exception(mode + " failed unexpectedly", e);
        Check(true, mode + " aborts safely (" + e.GetType().Name + ")");
    }
    Check(runner.ActiveJobs == 0, mode + " owned registry empty");
    if (mode != "startup-failure")
    {
        using var console = System.Text.Json.JsonDocument.Parse(File.ReadAllText(Path.Combine(folder, "console.json")));
        Check(console.RootElement.EnumerateObject().All(p => p.Value.ValueKind == System.Text.Json.JsonValueKind.False), mode + " standard streams attached to ConPTY");
    }
    if (mode is "trust" or "login" or "setup") Check(!File.Exists(Path.Combine(folder, "unexpected-input")), mode + " receives no input");
    if (File.Exists(Path.Combine(folder, "request.txt"))) Check(File.ReadAllText(Path.Combine(folder, "request.txt")) == "/usage", mode + " only fixed usage command");
    await Gone(folder);
}
// Run IANA conversion on Windows too; unsupported timezone must not fabricate a countdown.
var reading = ClaudeNativeUsage.Parse("Current week (all models)\n0% used\nResets Oct 24 at 9am (America/Fortaleza)", DateTimeOffset.Parse("2026-10-23T12:00:00Z"));
Check(reading.Windows![0].ResetsAt == DateTimeOffset.Parse("2026-10-24T12:00:00Z"), "Windows IANA timezone mapping");
int Handles()
{
    GC.Collect(); GC.WaitForPendingFinalizers();
    using var current = Process.GetCurrentProcess();
    return current.HandleCount;
}
// Warm runtime assemblies, thread-pool and console parsing before measuring native resource growth.
await RunCase("success", "warmup-success");
int initialHandles = Handles();
foreach (string mode in new[] { "success", "trust", "login", "setup", "timeout", "cancel", "shutdown", "excess", "root-exit", "startup-failure" })
    await RunCase(mode, mode);
int finalHandles = Handles();
Console.WriteLine($"Handles after warmup: {initialHandles}; after lifecycle suite: {finalHandles}");
Check(finalHandles <= initialHandles + 20, "bounded handle count after lifecycle suite");
Console.WriteLine($"SUCCESS {checks} checks; synthetic processes only; no authenticated client launched.");
return 0;
