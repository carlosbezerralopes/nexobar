using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;
using System.Security.Cryptography.X509Certificates;
using System.Xml.Linq;

namespace NexoBar.Setup;

public sealed record SignatureStatus(bool Integrity, bool Trusted, string Detail, string? CertificateSha256);
public static class SignatureVerifier
{
    // WINTRUST_DATA.WTD_HASH_ONLY_FLAG verifies the SIP digest separately from chain policy.
    // https://learn.microsoft.com/windows/win32/api/wintrust/ns-wintrust-wintrust_data
    public static SignatureStatus Verify(string package, string name, string publisher, string version, X509Certificate2? expected)
    {
        try
        {
            using var zip = ZipFile.OpenRead(package);
            using var xml = zip.GetEntry("AppxManifest.xml")?.Open() ?? throw new InvalidDataException("MSIX sem manifesto.");
            var identity = XDocument.Load(xml).Descendants().First(e => e.Name.LocalName == "Identity");
            if ((string?)identity.Attribute("Name") != name || (string?)identity.Attribute("Publisher") != publisher ||
                (string?)identity.Attribute("Version") != version || (string?)identity.Attribute("ProcessorArchitecture") != "x64")
                throw new InvalidDataException("Identidade MSIX incompatível.");
            using var signature = zip.GetEntry("AppxSignature.p7x")?.Open() ?? throw new InvalidDataException("MSIX não assinado.");
            using var data = new MemoryStream(); signature.CopyTo(data); var blob = data.ToArray();
            if (blob.Length < 5 || !blob.AsSpan(0, 4).SequenceEqual("PKCX"u8)) throw new InvalidDataException("Assinatura MSIX inválida.");
            var cms = new SignedCms(); cms.Decode(blob[4..]); cms.CheckSignature(verifySignatureOnly: true);
            if (cms.SignerInfos.Count != 1 || cms.SignerInfos[0].Certificate is not { } signer) throw new InvalidDataException("Signatário inválido.");
            string fingerprint = Convert.ToHexStringLower(SHA256.HashData(signer.RawData));
            if (signer.Subject != publisher || (expected is not null && !signer.RawData.AsSpan().SequenceEqual(expected.RawData)))
                throw new InvalidDataException("Certificado não corresponde ao publisher incorporado.");
            int digest = VerifyFile(package, hashOnly: true);
            if (digest != 0) return new(false, false, $"SIP não comprovou integridade (0x{digest:X8}).", fingerprint);
            int trust = VerifyFile(package, hashOnly: false);
            return new(true, trust == 0, trust == 0 ? "Assinatura íntegra e confiável." : $"Integridade confirmada; confiança pendente (0x{trust:X8}).", fingerprint);
        }
        catch (Exception e) when (e is CryptographicException or IOException or InvalidDataException or InvalidOperationException or System.Xml.XmlException)
        { return new(false, false, e.Message, null); }
    }
    public static int VerifyFile(string file, bool hashOnly)
    {
        var info = new FileInfoNative { Size = (uint)Marshal.SizeOf<FileInfoNative>(), Path = file };
        IntPtr ptr = Marshal.AllocHGlobal(Marshal.SizeOf<FileInfoNative>());
        Marshal.StructureToPtr(info, ptr, false);
        var data = new TrustData { Size = (uint)Marshal.SizeOf<TrustData>(), UI = 2, Choice = 1, File = ptr,
            StateAction = 1, Flags = 0x1000u | 0x2000u | (hashOnly ? 0x200u : 0u), Context = 1 };
        Guid action = new("00AAC56B-CD44-11D0-8CC2-00C04FC295EE");
        try { return WinVerifyTrust(new IntPtr(-1), ref action, ref data); }
        finally { data.StateAction = 2; WinVerifyTrust(new IntPtr(-1), ref action, ref data); Marshal.DestroyStructure<FileInfoNative>(ptr); Marshal.FreeHGlobal(ptr); }
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct FileInfoNative
    { public uint Size; [MarshalAs(UnmanagedType.LPWStr)] public string Path; public IntPtr Handle; public IntPtr Subject; }
    [StructLayout(LayoutKind.Sequential)] struct TrustData
    {
        public uint Size; public IntPtr Policy; public IntPtr Sip; public uint UI; public uint Revocation;
        public uint Choice; public IntPtr File; public uint StateAction; public IntPtr State; public IntPtr Url;
        public uint Flags; public uint Context; public IntPtr SignatureSettings;
    }
    [DllImport("wintrust.dll", ExactSpelling = true)] static extern int WinVerifyTrust(IntPtr hwnd, ref Guid action, ref TrustData data);
}
