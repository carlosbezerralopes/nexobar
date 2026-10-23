using System.Text.Json;
using System.Windows;
using NexoBar.Core;
using Application = System.Windows.Application;
using MessageBox = System.Windows.MessageBox;

namespace NexoBar.Windows;

internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NexoBar");
        int dataIndex = Array.IndexOf(args, "--data-directory");
        if (dataIndex >= 0)
        {
            if (dataIndex + 1 >= args.Length || !Path.IsPathFullyQualified(args[dataIndex + 1])) return 2;
            directory = args[dataIndex + 1];
        }
        if (args.Contains("--diagnose-claude"))
        {
            int output = Array.IndexOf(args, "--output");
            if (output < 0 || output + 1 >= args.Length || !Path.IsPathFullyQualified(args[output + 1])) return 2;
            var watch = System.Diagnostics.Stopwatch.StartNew();
            using var reader = new AIReader(Preferences.Load(Path.Combine(directory, "indicators.json")));
            var reading = Task.Run(() => reader.Read("claude", CancellationToken.None)).GetAwaiter().GetResult();
            File.WriteAllText(args[output + 1], JsonSerializer.Serialize(new { result = reading.Unavailable ?? "ok", durationSeconds = watch.Elapsed.TotalSeconds,
                ownedJobsAfterCompletion = reader.ActiveClaudeJobs, windows = reading.Windows?.Select(w => new { w.Id, w.UsedPercent, w.ResetsAt }),
                transport = "ConPTY; execução opt-in" }, new JsonSerializerOptions { WriteIndented = true }));
            return reading.Unavailable is null && reader.ActiveClaudeJobs == 0 ? 0 : 1;
        }
        if (args.Contains("--diagnose"))
        {
            int output = Array.IndexOf(args, "--output");
            if (output < 0 || output + 1 >= args.Length || !Path.IsPathFullyQualified(args[output + 1])) return 2;
            try
            {
                using var hardware = new HardwareReader();
                hardware.Read(); Thread.Sleep(1200);
                var readings = hardware.Read();
                File.WriteAllText(args[output + 1], JsonSerializer.Serialize(new { platform = "Windows", architecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(), sampledAt = DateTimeOffset.UtcNow, readings }, new JsonSerializerOptions { WriteIndented = true }));
                return 0;
            }
            catch (Exception) { return 1; }
        }
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.DispatcherUnhandledException += (_, e) =>
        {
            MessageBox.Show("O NexoBar encontrou um erro. Encerre e reabra o aplicativo; as preferências já salvas foram preservadas.", "NexoBar", MessageBoxButton.OK, MessageBoxImage.Error);
            e.Handled = true;
            app.Shutdown(1);
        };
        using var bar = new BarWindow(directory, dataIndex >= 0);
        app.Exit += (_, _) => bar.Dispose();
        bar.Start();
        if (args.Contains("--settings")) bar.OpenSettings();
        return app.Run();
    }
}
