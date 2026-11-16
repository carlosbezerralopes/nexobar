import Foundation

/// Queries may use only the client's existing session. There is no authentication fallback.
enum AISessionPolicy {
    struct Command: Equatable {
        let binary: String
        let arguments: [String]
        var input = ""
        var rpc = false
        /// Sent after the id 1 response; the query ends at the id 2 response.
        var rpcFollowUp = ""
        var timeout: TimeInterval = 20
    }

    static func command(for id: IndicatorID) -> Command? {
        switch id {
        case .codex:
            return Command(binary: "codex", arguments: ["app-server"],
                           input: "{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"nexobar\",\"version\":\"0.2\"}}}\n", rpc: true,
                           rpcFollowUp: "{\"method\":\"initialized\"}\n{\"id\":2,\"method\":\"account/rateLimits/read\",\"params\":null}\n")
        case .kiro:
            // ACP v3 sem sessão: só initialize e _kiro/account/getUsage. Nunca envie session/new nem session/prompt.
            // Não troque por `chat --agent-engine v3 /usage`: o v3 envia /usage ao modelo como prompt.
            return Command(binary: "kiro-cli", arguments: ["acp", "--agent-engine", "v3"],
                           input: "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1,\"clientCapabilities\":{\"fs\":{\"readTextFile\":false,\"writeTextFile\":false},\"terminal\":false},\"clientInfo\":{\"name\":\"nexobar\",\"version\":\"0.2\"}}}\n",
                           rpc: true, rpcFollowUp: "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"_kiro/account/getUsage\",\"params\":{}}\n")
        case .antigravity:
            return Command(binary: "agy", arguments: ["--print", "/usage"], timeout: 70)
        case .copilot:
            return Command(binary: "gh", arguments: ["api", "--hostname", "github.com", "copilot_internal/user",
                "--header", "Editor-Version: vscode/1.99.0", "--header", "Editor-Plugin-Version: copilot/1.300.0",
                "--header", "Accept: application/json"])
        default:
            return nil
        }
    }

    /// Tried only when the primary command is unavailable or malformed, never after authentication or rate limits.
    static func fallbackCommand(for id: IndicatorID) -> Command? {
        switch id {
        case .kiro:
            // O v2 não interativo imprime o /usage localmente.
            return Command(binary: "kiro-cli", arguments: ["chat", "--agent-engine", "v2", "--no-interactive", "/usage"])
        default:
            return nil
        }
    }

    static func nonInteractiveEnvironment(_ inherited: [String: String]) -> [String: String] {
        var result = inherited
        result["TERM"] = "dumb"
        result["KIRO_CHAT_UI"] = "classic"
        result["CI"] = "1"
        result["GH_PROMPT_DISABLED"] = "1"
        result["GIT_TERMINAL_PROMPT"] = "0"
        result["BROWSER"] = "/usr/bin/false"
        result["GH_BROWSER"] = "/usr/bin/false"
        return result
    }
}
