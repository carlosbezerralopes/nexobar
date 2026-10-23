namespace NexoBar.Core;

public static class CLIWorkingDirectories
{
    public static string Require(string? folder, string client)
    {
        if (string.IsNullOrWhiteSpace(folder) || folder.Any(char.IsControl) || !Path.IsPathFullyQualified(folder) || !Directory.Exists(folder))
            throw new IOException($"Escolha uma pasta existente, já confiável no {client}");
        return Path.GetFullPath(folder);
    }
    public static string? Validate(string? folder, bool required, string client)
    {
        if (!required && string.IsNullOrWhiteSpace(folder)) return null;
        try { _ = Require(folder, client); return null; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return $"{client}: escolha uma pasta absoluta existente. A confiança deve ser concedida pelo próprio cliente."; }
    }
}
