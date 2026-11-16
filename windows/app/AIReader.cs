using NexoBar.Core;

namespace NexoBar.Windows;

internal sealed class AIReader(Preferences preferences) : IDisposable
{
    private readonly OwnedCommand command = new();
    private readonly ClaudeConPty claude = new();
    internal int ActiveClaudeJobs => claude.ActiveJobs;
    internal async Task<Reading> Read(string id, CancellationToken cancellation)
    {
        var now = DateTimeOffset.UtcNow;
        try
        {
            return id switch
            {
                "claude" => await claude.Read(preferences.ClaudeWorkingDirectory, cancellation),
                "codex" => QuotaParsers.Codex(await command.Run("codex", ["app-server"], RpcExchange.Codex, cancellation, preferences.CodexWorkingDirectory), now),
                "kiro" => await KiroQuery.Read(() => command.Run("kiro-cli", KiroQuery.AcpArguments, RpcExchange.KiroAcp(Version), cancellation),
                    () => command.Run("kiro-cli", KiroQuery.FallbackArguments, null, cancellation), now),
                "copilot" => QuotaParsers.Copilot(await command.Run("gh", ["api", "--hostname", "github.com", "copilot_internal/user"], null, cancellation), now),
                _ => Unavailable(id, now, "Interface de sessão segura não validada no Windows")
            };
        }
        catch (OperationCanceledException) { return Unavailable(id, now, id == "claude" ? "Consulta cancelada ou timeout (45s)" : "Consulta cancelada ou timeout (20s)"); }
        catch (QuotaRefusedException e) { return Unavailable(id, now, e.Message + "; sem login/fallback"); }
        catch (FormatException e) { return Unavailable(id, now, id == "claude" ? e.Message : "Resposta inválida; sem fallback"); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException or System.Text.Json.JsonException or System.ComponentModel.Win32Exception)
        { return Unavailable(id, now, id == "claude" && string.IsNullOrWhiteSpace(preferences.ClaudeWorkingDirectory) ? "Escolha uma pasta já confiável no Claude Code em Personalizar barra" : "Fonte indisponível, CLI nativa ausente ou resposta inválida; sem login/fallback"); }
    }
    private static readonly string Version = typeof(AIReader).Assembly.GetName().Version?.ToString(3) ?? "0";
    internal static Reading Unavailable(string id, DateTimeOffset now, string reason) =>
        new(id, Preferences.Defaults().FirstOrDefault(p => p.Id == id)?.Label ?? id, now, Unavailable: reason,
            Source: id == "claude" ? "Claude Code · /usage · ConPTY temporário" : "Somente cliente existente, sem leitura de credenciais");
    public void Dispose() { claude.Dispose(); command.Dispose(); }
}
