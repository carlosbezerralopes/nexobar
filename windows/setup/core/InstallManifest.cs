using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;

namespace NexoBar.Setup.Core;

public sealed record PayloadFile(string Path, long Bytes, string Sha256);
public sealed record InstallManifest(int SchemaVersion, string Version, string Architecture,
    string CompanionName, string CompanionPublisher, string CompanionVersion, List<PayloadFile> Files)
{
    public const string AppVersion = "0.5.0";
    public static InstallManifest Read(Stream stream)
    {
        var manifest = JsonSerializer.Deserialize<InstallManifest>(stream) ?? throw new InvalidDataException("Manifesto ausente.");
        manifest.Validate(); return manifest;
    }
    public void Validate()
    {
        if (SchemaVersion != 1 || Version != AppVersion || Architecture != "x64" ||
            CompanionName != "NexoBar.Widget" || CompanionPublisher != "CN=NexoBar" || CompanionVersion != "0.5.0.0" ||
            Files is null || Files.Count == 0 || Files.Count > 20000)
            throw new InvalidDataException("Manifesto incompatível.");
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var f in Files)
        {
            SafePaths.ValidateRelative(f.Path);
            if (!seen.Add(f.Path) || f.Bytes < 0 || f.Bytes > 1024L * 1024 * 1024 || f.Sha256.Length != 64 || !f.Sha256.All(Uri.IsHexDigit))
                throw new InvalidDataException("Entrada inválida ou duplicada no manifesto.");
        }
        if (!Files.Any(f => f.Path == "app/NexoBar.exe") || !Files.Any(f => f.Path == "companion/NexoBar.Widget.msix"))
            throw new InvalidDataException("Componentes obrigatórios ausentes.");
    }
    public static string Hash(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
    public static string HashFile(string path) { using var f = File.OpenRead(path); return Convert.ToHexStringLower(SHA256.HashData(f)); }
    public void ExtractVerified(Stream source, string target, CancellationToken cancellationToken)
    {
        Validate(); SafePaths.NoReparseParents(target);
        using var zip = new ZipArchive(source, ZipArchiveMode.Read, leaveOpen: true);
        var expected = Files.ToDictionary(f => f.Path, StringComparer.OrdinalIgnoreCase);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in zip.Entries)
        {
            cancellationToken.ThrowIfCancellationRequested();
            SafePaths.ValidateRelative(entry.FullName);
            int type = (entry.ExternalAttributes >> 16) & 0xF000;
            if (type is 0xA000 || (entry.ExternalAttributes & (int)FileAttributes.ReparsePoint) != 0 ||
                !seen.Add(entry.FullName) || !expected.TryGetValue(entry.FullName, out var file) || entry.Length != file.Bytes)
                throw new InvalidDataException("ZIP contém entrada desconhecida, link, tamanho ou duplicata inválidos.");
            string path = SafePaths.Under(target, file.Path);
            SafePaths.NoReparseParents(path);
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
            using (var input = entry.Open()) using (var output = new FileStream(path, FileMode.CreateNew))
            {
                byte[] buffer = new byte[81920]; long count = 0; int read;
                while ((read = input.Read(buffer)) != 0)
                { cancellationToken.ThrowIfCancellationRequested(); count += read; if (count > file.Bytes) throw new InvalidDataException("Tamanho excedido."); output.Write(buffer, 0, read); }
                if (count != file.Bytes) throw new InvalidDataException("Tamanho incompleto.");
            }
            if (!string.Equals(HashFile(path), file.Sha256, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Integridade SHA256 inválida: " + file.Path);
        }
        if (seen.Count != Files.Count) throw new InvalidDataException("ZIP incompleto.");
    }
    public bool VerifyInstalled(string target) => Files.Where(f => f.Path.StartsWith("app/", StringComparison.Ordinal)).All(f => {
        string p = SafePaths.Under(target, f.Path[4..]); SafePaths.NoReparseParents(p);
        return File.Exists(p) && new FileInfo(p).Length == f.Bytes && HashFile(p).Equals(f.Sha256, StringComparison.OrdinalIgnoreCase);
    });
}

public static class SafePaths
{
    public static void ValidateRelative(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || path.Contains('\\') || path.StartsWith('/') || path.Contains(':') || path.Contains('\0') ||
            path.Split('/').Any(p => p is "" or "." or ".." || p.EndsWith('.') || p.EndsWith(' ') || p.Any(c => c < 32 || "<>\"|?*".Contains(c)) ||
                new[] { "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" }.Contains(p.Split('.')[0], StringComparer.OrdinalIgnoreCase)))
            throw new InvalidDataException("Caminho inseguro no payload.");
    }
    public static string Under(string root, string relative)
    {
        ValidateRelative(relative); string prefix = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        string result = Path.GetFullPath(Path.Combine(prefix, relative));
        if (!result.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Caminho fora do destino.");
        return result;
    }
    public static void NoReparseParents(string path)
    {
        for (string? p = Path.GetFullPath(path); p is not null; p = Path.GetDirectoryName(p))
            if ((File.Exists(p) || Directory.Exists(p)) && (File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Link/reparse point recusado: " + p);
    }
}
