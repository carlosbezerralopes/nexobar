global using System.IO;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Windows;
using NexoBar.Setup.Core;

namespace NexoBar.Setup;

public static class Program
{
    [STAThread] public static int Main(string[] args)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) || System.Runtime.InteropServices.RuntimeInformation.OSArchitecture != System.Runtime.InteropServices.Architecture.X64)
        { MessageBox.Show("O instalador exige Windows 11 x64.", "NexoBar"); return 1; }
        if (args.SequenceEqual(new[] { "--trust-embedded-certificate" })) return TrustEmbeddedCertificate();
        if (args.SequenceEqual(new[] { "--verify-embedded-payload" }) || (args.Length == 2 && args[0] == "--verify-package"))
        {
            try
            {
                using var payload = new SetupPayload(); using var cert = payload.PublicCertificate();
                var result = SignatureVerifier.Verify(args.Length == 2 ? Path.GetFullPath(args[1]) : payload.Companion, payload.Manifest.CompanionName, payload.Manifest.CompanionPublisher, payload.Manifest.CompanionVersion, cert);
                Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(result)); return result.Integrity ? 0 : 2;
            }
            catch (Exception e) { Console.Error.WriteLine(e.Message); return 3; }
        }
        if (args.Length != 0) { MessageBox.Show("Argumentos não reconhecidos.", "NexoBar"); return 1; }
        var app = new Application(); app.Run(new SetupWindow()); return 0;
    }
    static int TrustEmbeddedCertificate()
    {
        // No caller-controlled path, store, subject or destination is accepted by the elevated helper.
        try
        {
            using var payload = new SetupPayload(); using var cert = payload.PublicCertificate() ?? throw new IOException("Certificado público não incorporado.");
            var status = SignatureVerifier.Verify(payload.Companion, payload.Manifest.CompanionName, payload.Manifest.CompanionPublisher, payload.Manifest.CompanionVersion, cert);
            if (!status.Integrity || status.CertificateSha256 != Convert.ToHexStringLower(SHA256.HashData(cert.RawData)) ||
                DateTime.Now < cert.NotBefore || DateTime.Now > cert.NotAfter || cert.HasPrivateKey) return 2;
            using var store = new X509Store(StoreName.TrustedPeople, StoreLocation.LocalMachine); store.Open(OpenFlags.ReadWrite);
            if (!store.Certificates.Cast<X509Certificate2>().Any(c => c.RawData.AsSpan().SequenceEqual(cert.RawData))) store.Add(cert);
            return store.Certificates.Cast<X509Certificate2>().Any(c => c.RawData.AsSpan().SequenceEqual(cert.RawData)) ? 0 : 3;
        }
        catch { return 4; }
    }
}
