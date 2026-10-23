using System.Diagnostics;
using NexoBar.Core;
using NexoBar.Windows;

if (!OperatingSystem.IsWindows()) { Console.Error.WriteLine("SKIP: lifecycle ConPTY exige Windows nativo"); return 3; }
if (args.Length >= 3 && args[0] == "--synthetic-client")
{
    string mode = args[1], folder = args[2];
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
int initialHandles = Process.GetCurrentProcess().HandleCount;
foreach (string mode in new[] { "success", "trust", "login", "setup", "timeout", "cancel", "shutdown", "excess", "root-exit", "startup-failure" })
{
    string folder = Path.Combine(args[0], mode); Directory.CreateDirectory(folder);
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
    { Check(mode != "success", mode + " aborts safely"); }
    Check(runner.ActiveJobs == 0, mode + " owned registry empty");
    if (mode is "trust" or "login" or "setup") Check(!File.Exists(Path.Combine(folder, "unexpected-input")), mode + " receives no input");
    if (File.Exists(Path.Combine(folder, "request.txt"))) Check(File.ReadAllText(Path.Combine(folder, "request.txt")) == "/usage", mode + " only fixed usage command");
    await Gone(folder);
}
// Run IANA conversion on Windows too; unsupported timezone must not fabricate a countdown.
var reading = ClaudeNativeUsage.Parse("Current week (all models)\n0% used\nResets Oct 24 at 9am (America/Fortaleza)", DateTimeOffset.Parse("2026-10-23T12:00:00Z"));
Check(reading.Windows![0].ResetsAt == DateTimeOffset.Parse("2026-10-24T12:00:00Z"), "Windows IANA timezone mapping");
GC.Collect(); GC.WaitForPendingFinalizers();
Check(Process.GetCurrentProcess().HandleCount <= initialHandles + 20, "bounded handle count after lifecycle suite");
Console.WriteLine($"SUCCESS {checks} checks; synthetic processes only; no authenticated client launched.");
return 0;
