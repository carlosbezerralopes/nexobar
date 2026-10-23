import Foundation

/// Quota-only receipt emitted locally by Claude Code's official statusLine.
/// capturedAt dates CLI delivery; it does not assert a remote observation time.
enum ClaudeStatusLine {
    static let maximumAge: TimeInterval = 1800
    static let maximumBytes = 16 * 1024
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NexoBar/claude-statusline.json")
    }

    static func read(now: Date) throws -> IndicatorReading { try read(url: defaultURL, now: now) }

    static func read(url: URL, now: Date) throws -> IndicatorReading {
        guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              info.isRegularFile == true, info.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: url) else {
            throw AIReadError.claudeStatusLineUnavailable
        }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        return try parse(data, now: now)
    }

    static func parse(_ data: Data, now: Date) throws -> IndicatorReading {
        guard data.count <= maximumBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["schemaVersion", "provider", "capturedAt", "windows"],
              AIUsageParser.number(root["schemaVersion"]) == 1,
              root["provider"] as? String == "claude",
              let stamp = root["capturedAt"] as? String, stamp.hasSuffix("Z"),
              let captured = AIUsageParser.date(stamp),
              let rows = root["windows"] as? [[String: Any]], rows.count <= 2 else {
            throw AIReadError.malformed
        }
        let age = now.timeIntervalSince(captured)
        guard age >= 0, age < maximumAge else { throw AIReadError.claudeStatusLineExpired }
        var seen = Set<String>()
        var windows: [QuotaWindow] = []
        for row in rows {
            guard Set(row.keys) == ["id", "usedPercent", "resetsAt"],
                  let id = row["id"] as? String, ["session", "weekly_all"].contains(id),
                  seen.insert(id).inserted,
                  let used = AIUsageParser.number(row["usedPercent"]), used <= 100 else {
                throw AIReadError.malformed
            }
            var reset: Date?
            if !(row["resetsAt"] is NSNull) {
                guard let seconds = AIUsageParser.number(row["resetsAt"]),
                      (1_000_000_000...4_102_444_800).contains(seconds) else { throw AIReadError.malformed }
                reset = Date(timeIntervalSince1970: seconds)
            }
            if let reset, reset <= now { continue }
            windows.append(QuotaWindow(name: id == "session" ? "Sessão" : "Semanal", usedPercent: used,
                                       resetsAt: reset, id: id, durationMinutes: id == "session" ? 300 : 10080))
        }
        guard !windows.isEmpty else { throw AIReadError.claudeStatusLineUnavailable }
        windows.sort { ($0.id == "session" ? 0 : 1) < ($1.id == "session" ? 0 : 1) }
        return try AIUsageParser.reading(.claude, windows: windows, headline: windows.first?.usedPercent,
            now: captured, source: "Claude Code · status line · data de entrega local, sem confirmação de nova consulta remota")
    }

    static func diagnose(now: Date) -> String {
        guard let reading = try? read(now: now), let captured = reading.sampledAt else {
            return "claude: statusline=indisponível"
        }
        let age = String(format: "%.0f", now.timeIntervalSince(captured))
        return "claude: statusline=recente | entrega_idade_s=\(age) | janelas=\(reading.windows.count)"
    }
}
