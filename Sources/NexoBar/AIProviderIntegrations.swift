import Foundation
import SQLite3

enum AIProviderIntegrations {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static func read(_ id: IndicatorID, now: Date, cliDirectories: CLIWorkingDirectories = .load()) throws -> IndicatorReading {
        try read(id, now: now, locate: UsageCommand.locate,
                 run: { command, binary in
                     try UsageCommand.run(binary: binary, arguments: command.arguments, input: command.input,
                                          rpc: command.rpc, timeout: command.timeout,
                                          workingDirectory: id == .codex ? try cliDirectories.directory(for: .codex) : nil)
                 }, claudeQuery: { date in
                     guard let directory = try cliDirectories.directory(for: .claude) else { throw CLIWorkingDirectoryError.required }
                     guard let binary = UsageCommand.locate("claude") else { throw AIReadError.unavailable }
                     return try ClaudePTY.read(binary: binary, workingDirectory: directory, now: date)
                 })
    }

    // Only the client executes authenticated requests. This app never obtains its credentials.
    static func read(_ id: IndicatorID, now: Date,
                     locate: (String) -> URL?,
                     run: (AISessionPolicy.Command, URL) throws -> String,
                     claudeQuery: (Date) throws -> IndicatorReading) throws -> IndicatorReading {
        if id == .claude {
            let reading = try claudeQuery(now)
            guard !reading.isStale else { throw AIReadError.unavailable }
            return reading
        }
        guard let command = AISessionPolicy.command(for: id), let binary = locate(command.binary) else {
            throw AIReadError.unavailable
        }
        let text = try run(command, binary)
        switch id {
        case .codex: return try AIUsageParser.codex(text, now: now)
        case .kiro: return try AIUsageParser.kiro(text, now: now)
        case .antigravity: return try antigravityCLI(text, now: now)
        case .copilot:
            let data = Data(text.utf8)
            var result = try converted(id, GitHubCopilotUsage.windows(from: data), headline: "premium_interactions", now: now,
                                       source: "GitHub Copilot · consulta pela sessão GitHub CLI")
            let quotas = try object(data)["quota_snapshots"] as? [String: [String: Any]] ?? [:]
            for index in result.windows.indices {
                let key = result.windows[index].id ?? ""
                if let row = quotas[key], let cap = AIUsageParser.number(row["entitlement"]), cap > 0,
                   let used = AIUsageParser.number(row["used"]) ?? AIUsageParser.number(row["remaining"]).map({ max(0, cap - $0) }) {
                    result.windows[index].used = used; result.windows[index].limit = cap; result.windows[index].unit = "solicitações"
                }
            }
            return result
        default: throw AIReadError.unavailable
        }
    }

    static func converted(_ id: IndicatorID, _ input: [LimitWindow], headline: String, now: Date, source: String) throws -> IndicatorReading {
        let windows = input.compactMap { item -> QuotaWindow? in
            if let value = item.usedFraction, (!value.isFinite || value < 0) { return nil }
            let name = (item.group.map { $0 + " · " } ?? "") + L10n.t(item.label)
            return QuotaWindow(name: name, usedPercent: item.usedFraction.map { $0 * 100 }, resetsAt: item.resetsAt,
                               detail: item.detail ?? item.usedText ?? "", id: item.id, durationMinutes: item.duration.map { $0 / 60 },
                               used: item.used.map(Double.init))
        }
        return try AIUsageParser.reading(id, windows: windows, headline: windows.first { $0.id == headline }?.usedPercent, now: now, source: source)
    }
    static func monthlyMinutes(_ reset: Date?) -> Double? {
        guard let reset else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.day, .hour, .minute, .second], from: reset)
        guard parts.day == 1, parts.hour == 0, parts.minute == 0, parts.second == 0,
              let previous = calendar.date(byAdding: .month, value: -1, to: reset) else { return nil }
        return reset.timeIntervalSince(previous) / 60
    }
    static func bounded(_ url: URL, cap: Int = 2 * 1024 * 1024) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: cap + 1) ?? Data()
        guard data.count <= cap else { throw AIReadError.excessiveOutput }; return data
    }
    static func object(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIReadError.malformed }; return root
    }
    static func codexPaths(home: URL = home) -> [URL] {
        let root = home.appendingPathComponent(".codex")
        if let db = SQLiteStore.open(root.appendingPathComponent("state_5.sqlite")) {
            defer { sqlite3_close(db) }
            var rows = SQLiteStore.rows(in: db, sql: "SELECT rollout_path FROM threads WHERE archived=0 ORDER BY updated_at_ms DESC LIMIT 8")
            if rows.isEmpty { rows = SQLiteStore.rows(in: db, sql: "SELECT rollout_path FROM threads WHERE archived=0 ORDER BY updated_at DESC LIMIT 8") }
            if !rows.isEmpty { return rows.map { URL(fileURLWithPath: $0) }.filter { $0.path.hasPrefix(root.path + "/sessions/") } }
        }
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        return (0..<3).compactMap { calendar.date(byAdding: .day, value: -$0, to: Date()) }.flatMap { date in
            (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("sessions/" + formatter.string(from: date)), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }.filter { $0.pathExtension == "jsonl" }.sorted { modification($0) > modification($1) }.prefix(8).map { $0 }
    }
    static func modification(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
    static func tail(_ url: URL, cap: Int = 1024 * 1024) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let size = try handle.seekToEnd(); let offset = size > UInt64(cap) ? size - UInt64(cap) : 0
        try handle.seek(toOffset: offset); let data = try handle.read(upToCount: cap) ?? Data()
        return offset > 0 ? Data(data.drop { $0 != 10 }.dropFirst()) : data
    }
    static func antigravityCLI(_ text: String, now: Date) throws -> IndicatorReading {
        let clean = text.replacingOccurrences(of: "\u{001B}\\[[0-9;:?]*[ -/]*[@-~]|\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)|\u{001B}[()][0-9A-Za-z]", with: "", options: .regularExpression)
        guard clean.contains("Quota:") else { throw AIReadError.malformed }
        let windows = clean.components(separatedBy: .newlines).compactMap { line -> QuotaWindow? in
            let groups = AIUsageParser.captures(line, pattern: #"^\s*(.+?Limit) Remaining\s+(\d+(?:\.\d+)?)%\s+(.+?)\s*$"#)
            guard groups.count == 3, let remaining = Double(groups[1]), (0...100).contains(remaining) else { return nil }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.isLenient = false
            var reset = AIUsageParser.date(groups[2])
            if reset == nil {
                formatter.dateFormat = "yyyy-MM-dd HH:mm z"; reset = formatter.date(from: groups[2])
            }
            guard let reset else { return nil }
            let duration: Double? = groups[0].contains("Weekly") ? 10080 : groups[0].contains("Five Hour") ? 300 : nil
            return QuotaWindow(name: groups[0], usedPercent: 100 - remaining, resetsAt: reset, id: groups[0], durationMinutes: duration)
        }
        return try AIUsageParser.reading(.antigravity, windows: windows, headline: windows.first?.usedPercent, now: now, source: "Antigravity CLI /usage · percentual utilizado")
    }
}

