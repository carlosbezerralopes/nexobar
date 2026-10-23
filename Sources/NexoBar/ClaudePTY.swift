import Foundation
import Darwin

enum ClaudePTYError: Error {
    case folderUnavailable, setupRequired, usageFailed

    var message: String {
        switch self {
        case .folderUnavailable: return "Escolha uma pasta já confiável no Claude Code"
        case .setupRequired: return "Claude Code exige configuração ou confiança na pasta; abra o cliente"
        case .usageFailed: return "Claude Code não conseguiu carregar as cotas"
        }
    }
}

// A temporary terminal, using only the client's existing session. Call from a
// background executor. Output stays in the bounded terminal model and is never logged.
enum ClaudePTY {
    static let maximumOutput = 512 * 1024
    static let arguments = ["--safe-mode", "--strict-mcp-config", "--tools", "", "--ax-screen-reader",
                            "--settings", #"{"disableRemoteControl":true,"remoteControlAtStartup":false}"#]

    static func environment(_ inherited: [String: String]) -> [String: String] {
        var result = inherited
        result.removeValue(forKey: "CI")
        // This flag prevented the native quota request in the measured client.
        result.removeValue(forKey: "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC")
        result["TERM"] = "xterm-256color"
        result["DISABLE_AUTOUPDATER"] = "1"
        result["BROWSER"] = "/usr/bin/false"
        return result
    }

    static func read(binary: URL, workingDirectory: URL, now: Date = Date(),
                     timeout: TimeInterval = 45) throws -> IndicatorReading {
        var isDirectory: ObjCBool = false
        guard workingDirectory.isFileURL,
              FileManager.default.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw ClaudePTYError.folderUnavailable }
        guard binary.isFileURL, FileManager.default.isExecutableFile(atPath: binary.path) else { throw AIReadError.unavailable }
        guard timeout.isFinite, timeout > 0 else { throw AIReadError.timedOut }

        var master: Int32 = -1, slave: Int32 = -1
        var dimensions = winsize(ws_row: 80, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &dimensions) == 0 else { throw AIReadError.unavailable }
        defer { if master >= 0 { close(master) }; if slave >= 0 { close(slave) } }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw AIReadError.unavailable }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw AIReadError.unavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        for destination in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            guard posix_spawn_file_actions_adddup2(&actions, slave, destination) == 0 else { throw AIReadError.unavailable }
        }
        guard posix_spawn_file_actions_addclose(&actions, master) == 0,
              posix_spawn_file_actions_addclose(&actions, slave) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw AIReadError.unavailable }

        let argv = ([binary.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment(ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { a in envp.withUnsafeBufferPointer { e in
            posix_spawn(&pid, binary.path, &actions, &attributes, a.baseAddress!, e.baseAddress!)
        } }
        guard result == 0 else { throw AIReadError.unavailable }
        close(slave); slave = -1
        var reaped = false
        // Installed before registration: shutdown racing with spawn still owns cleanup.
        defer {
            cleanup(pid: pid, master: master, reaped: &reaped)
            UsageCommand.unregister(pid)
        }
        guard UsageCommand.register(pid) else { throw AIReadError.unavailable }

        var screen = ClaudeTerminalScreen(columns: 160, rows: 80)
        var totalOutput = 0
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let started = ProcessInfo.processInfo.systemUptime
        var requestSentAt: TimeInterval?
        var lastText = "", changedAt = started
        while ProcessInfo.processInfo.systemUptime - started < min(timeout, 45) {
            while true {
                let count = Darwin.read(master, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                totalOutput += count
                guard totalOutput <= maximumOutput else { throw AIReadError.excessiveOutput }
                screen.feed(Data(buffer.prefix(count)))
                try rejectBlockedScreen(screen.text)
            }
            let text = screen.text
            let tick = ProcessInfo.processInfo.systemUptime
            if text != lastText { lastText = text; changedAt = tick }
            if requestSentAt == nil, isInitialPrompt(text) {
                // The only submitted command. Never answer trust/setup/login prompts.
                try send("/usage\r", master: master)
                requestSentAt = tick
                changedAt = tick
            } else if let sent = requestSentAt,
                      tick - sent >= 1, tick - changedAt >= 1,
                      !isLoading(text), text.contains("Current session") || text.contains("Current week") {
                // Parsing may remain incomplete while the screen is being composed.
                // Failed-load/auth/trust screens already aborted above; no fallback.
                if let reading = try? ClaudeUsageParser.parse(text, now: now) { return reading }
            }
            var status: Int32 = 0
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { reaped = true; throw AIReadError.unavailable }
            if waited < 0 && errno != EINTR { throw AIReadError.unavailable }
            usleep(20_000)
        }
        throw AIReadError.timedOut
    }

    private static func isInitialPrompt(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.contains("claude code"), lower.contains("max") || lower.contains("pro") || lower.contains("claude.ai") else { return false }
        return text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let prompt = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return ["❯", "›", "$", ">"].contains(prompt)
        }
    }

    private static func isLoading(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("refreshing") || lower.contains("loading usage") || lower.contains("fetching usage")
    }

    private static func rejectBlockedScreen(_ text: String) throws {
        let lower = text.lowercased()
        if ["not logged in", "please log in", "run /login", "login required", "sign in to", "authentication required"].contains(where: lower.contains) {
            throw AIReadError.authentication
        }
        if ["do you trust", "trust this", "trust the files", "trust folder", "trust this folder", "permission required",
            "choose the text style", "choose a theme", "select a theme", "let’s get started", "let's get started"].contains(where: lower.contains) {
            throw ClaudePTYError.setupRequired
        }
        if lower.contains("failed to load"), lower.contains("usage") { throw ClaudePTYError.usageFailed }
        if lower.contains("error loading usage") || lower.contains("unable to load usage") { throw ClaudePTYError.usageFailed }
    }

    private static func send(_ text: String, master: Int32) throws {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw AIReadError.unavailable }
            offset += count
        }
    }

    private static func cleanup(pid: pid_t, master: Int32, reaped: inout Bool) {
        // Escape dismisses the panel, Ctrl-C interrupts interactive input; the
        // owned process group then receives bounded graceful and forced shutdown.
        try? send("\u{1b}\u{3}", master: master)
        kill(-pid, SIGINT)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if !reaped {
                var status: Int32 = 0
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid || (result < 0 && errno == ECHILD) { reaped = true }
            }
            if kill(-pid, 0) < 0 && errno == ESRCH { break }
            usleep(20_000)
        }
        kill(-pid, SIGTERM)
        kill(-pid, SIGKILL)
        if !reaped {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            reaped = true
        }
    }
}
