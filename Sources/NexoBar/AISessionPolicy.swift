import Foundation

/// Queries may use only the client's existing session. There is no authentication fallback.
enum AISessionPolicy {
    struct Command: Equatable {
        let binary: String
        let arguments: [String]
        var input = ""
        var rpc = false
        var timeout: TimeInterval = 20
    }

    static func command(for id: IndicatorID) -> Command? {
        switch id {
        case .codex:
            return Command(binary: "codex", arguments: ["app-server"],
                           input: "{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"nexobar\",\"version\":\"0.2\"}}}\n", rpc: true)
        case .kiro:
            return Command(binary: "kiro-cli", arguments: ["chat", "--no-interactive", "/usage"])
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
