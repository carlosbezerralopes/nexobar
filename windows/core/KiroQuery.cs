using System.Text.Json;

namespace NexoBar.Core;

/// Authentication or rate limit reported by the client. Never triggers another query.
public sealed class QuotaRefusedException(string message) : FormatException(message);

/// Bounded CLI output was exceeded. Never triggers another query.
public sealed class QuotaOutputLimitException(string message) : IOException(message);

/// Fixed JSON-RPC lines for a quota client. Each line is written with WriteLine; the query ends at the id 2 response.
public sealed record RpcExchange(string Initialize, IReadOnlyList<string> FollowUp, bool ErrorReachesParser)
{
    public static RpcExchange Codex { get; } = new(
        "{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"nexobar\",\"version\":\"0.3.1\"},\"capabilities\":{\"experimentalApi\":true}}}",
        ["{\"method\":\"initialized\",\"params\":{}}", "{\"id\":2,\"method\":\"account/rateLimits/read\",\"params\":{}}"], false);

    /// ACP without a session: only initialize and _kiro/account/getUsage. Never send session/new or session/prompt.
    public static RpcExchange KiroAcp(string version) => new(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1,\"clientCapabilities\":{\"fs\":{\"readTextFile\":false,\"writeTextFile\":false},\"terminal\":false},\"clientInfo\":{\"name\":\"nexobar\",\"version\":" +
        JsonSerializer.Serialize(version) + "}}}",
        ["{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"_kiro/account/getUsage\",\"params\":{}}"], true);

    /// Bidirectional peers send notifications and requests; only objects without method and with result or error are responses.
    public static bool TryResponse(JsonElement root, out int id, out bool error)
    {
        id = 0; error = false;
        if (root.ValueKind != JsonValueKind.Object || root.TryGetProperty("method", out _)) return false;
        bool hasResult = root.TryGetProperty("result", out _);
        error = root.TryGetProperty("error", out _);
        return (hasResult || error) && root.TryGetProperty("id", out var node) && node.ValueKind == JsonValueKind.Number && node.TryGetInt32(out id);
    }
}

public static class KiroQuery
{
    public static readonly string[] AcpArguments = ["acp", "--agent-engine", "v3"];
    // The non-interactive v2 prints /usage locally. Never replace it with `chat --agent-engine v3 /usage`: v3 sends /usage to the model.
    public static readonly string[] FallbackArguments = ["chat", "--agent-engine", "v2", "--no-interactive", "/usage"];

    /// Only an unavailable or malformed primary answer runs the v2 query; refusals, limits and cancellation do not.
    public static bool AllowsFallback(Exception e) => e switch
    {
        QuotaRefusedException or QuotaOutputLimitException => false,
        FormatException or IOException => true,
        _ => false
    };

    public static async Task<Reading> Read(Func<Task<string>> acp, Func<Task<string>> fallback, DateTimeOffset now)
    {
        try { return QuotaParsers.KiroAcp(await acp(), now); }
        catch (Exception e) when (AllowsFallback(e)) { return QuotaParsers.Kiro(await fallback(), now); }
    }
}
