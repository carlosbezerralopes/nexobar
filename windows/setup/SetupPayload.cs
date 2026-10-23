using System.Reflection;
using System.Security.Cryptography.X509Certificates;
using NexoBar.Setup.Core;

namespace NexoBar.Setup;

public sealed class SetupPayload : IDisposable
{
    public InstallManifest Manifest { get; }
    public string ManifestHash { get; }
    public string Directory { get; }
    public string Companion => Path.Combine(Directory, "companion", "NexoBar.Widget.msix");
    public string CertificatePath => Path.Combine(Directory, "companion", "publisher.cer");
    static Stream Resource(string name) => Assembly.GetExecutingAssembly().GetManifestResourceStream(name) ??
        throw new InvalidDataException("Build de desenvolvimento sem payload. Gere o instalador com build.ps1 e um companion assinado.");
    public static Stream OpenArchive() => Resource("NexoBar.Setup.Payload.zip");
    public SetupPayload(CancellationToken cancellationToken = default)
    {
        using var raw = Resource("NexoBar.Setup.Manifest.json"); using var bytes = new MemoryStream(); raw.CopyTo(bytes);
        ManifestHash = InstallManifest.Hash(bytes.ToArray()); bytes.Position = 0; Manifest = InstallManifest.Read(bytes);
        Directory = Path.Combine(Path.GetTempPath(), "NexoBar", "setup", Guid.NewGuid().ToString("N"));
        SafePaths.NoReparseParents(Directory); System.IO.Directory.CreateDirectory(Directory);
        try { using var zip = OpenArchive(); Manifest.ExtractVerified(zip, Directory, cancellationToken); }
        catch { Dispose(); throw; }
    }
    public X509Certificate2? PublicCertificate()
    {
        if (!File.Exists(CertificatePath)) return null;
        byte[] bytes = File.ReadAllBytes(CertificatePath);
        if (X509Certificate2.GetCertContentType(bytes) != X509ContentType.Cert) throw new InvalidDataException("Somente certificado público DER é permitido.");
        var cert = X509CertificateLoader.LoadCertificate(bytes);
        if (cert.HasPrivateKey || cert.Subject != Manifest.CompanionPublisher) { cert.Dispose(); throw new InvalidDataException("Certificado inesperado."); }
        return cert;
    }
    public void Dispose()
    {
        if (string.IsNullOrEmpty(Directory) || !System.IO.Directory.Exists(Directory)) return;
        SafePaths.NoReparseParents(Directory);
        foreach (string path in System.IO.Directory.EnumerateFileSystemEntries(Directory, "*", SearchOption.AllDirectories)) SafePaths.NoReparseParents(path);
        System.IO.Directory.Delete(Directory, true);
    }
}
