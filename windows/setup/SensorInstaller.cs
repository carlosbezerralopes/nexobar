using System.Diagnostics;
using NexoBar.Setup.Core;

namespace NexoBar.Setup;

// Elevated helper. Accepts no caller-controlled path: it installs only the payload embedded in this signed EXE.
// Files are re-hashed after copying into Program Files (admin-only), so the user-writable extraction
// directory cannot be swapped between verification and use by the LocalSystem service.
public static class SensorInstaller
{
    public const string Argument = "--install-sensors";
    // Must match NexoBar.Core.SensorProtocol.
    const string ServiceName = "NexoBarSensors", DisplayName = "NexoBar Sensores";
    const int Ok = 0, DriverFailed = 10, Failed = 4;
    public static string Message(int code) => code switch
    {
        Ok => "Serviço NexoBar Sensores e driver PawnIO instalados: temperaturas de CPU e SSD ativas.",
        DriverFailed => "Serviço NexoBar Sensores instalado (temperatura do SSD); o driver PawnIO falhou, então a temperatura da CPU segue indisponível.",
        _ => "Serviço de sensores não instalado (código " + code + "); temperaturas de CPU e SSD indisponíveis."
    };
    public static int Run()
    {
        try
        {
            using var payload = new SetupPayload();
            string target = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "NexoBar", "Sensores");
            var files = payload.Manifest.Files.Where(f => f.Path.StartsWith("sensors/", StringComparison.Ordinal)).ToArray();
            if (!files.Any(f => f.Path == "sensors/NexoBar.Sensors.exe") || !files.Any(f => f.Path == "sensors/PawnIO_setup.exe")) return Failed;
            Sc("stop", ServiceName); WaitStopped();
            SafePaths.NoReparseParents(target); Directory.CreateDirectory(target);
            foreach (var file in files)
            {
                string destination = SafePaths.Under(target, file.Path["sensors/".Length..]);
                SafePaths.NoReparseParents(destination); Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                File.Copy(SafePaths.Under(payload.Directory, file.Path), destination, true);
                if (!string.Equals(InstallManifest.HashFile(destination), file.Sha256, StringComparison.OrdinalIgnoreCase)) return Failed;
            }
            int driver = Execute(Path.Combine(target, "PawnIO_setup.exe"), ["-install", "-silent"], TimeSpan.FromMinutes(2));
            string binary = Path.Combine(target, "NexoBar.Sensors.exe");
            if (Sc("query", ServiceName) != 0 && Sc("create", ServiceName, "binPath=", binary, "start=", "auto", "obj=", "LocalSystem", "DisplayName=", DisplayName) != 0) return Failed;
            if (Sc("config", ServiceName, "binPath=", binary, "start=", "auto") != 0) return Failed;
            Sc("description", ServiceName, "Lê temperaturas de CPU e discos para o NexoBar. Somente leitura; sem rede.");
            Sc("failure", ServiceName, "reset=", "86400", "actions=", "restart/60000/restart/60000//");
            if (Sc("start", ServiceName) is not (0 or 1056)) return Failed; // 1056: already running
            return driver == 0 ? Ok : DriverFailed;
        }
        catch (Exception) { return Failed; }
    }
    static void WaitStopped()
    {
        for (int i = 0; i < 40 && Process.GetProcessesByName("NexoBar.Sensors").Length > 0; i++) Thread.Sleep(250);
    }
    static int Sc(params string[] args) => Execute(Path.Combine(Environment.SystemDirectory, "sc.exe"), args, TimeSpan.FromSeconds(30));
    static int Execute(string file, string[] args, TimeSpan timeout)
    {
        var info = new ProcessStartInfo(file) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (string arg in args) info.ArgumentList.Add(arg);
        using var process = Process.Start(info)!;
        process.StandardOutput.ReadToEnd(); process.StandardError.ReadToEnd();
        if (!process.WaitForExit(timeout)) { process.Kill(true); return -1; }
        return process.ExitCode;
    }
}
