import Foundation
import Darwin
import CoreFoundation

// Usage parsing and Claude cache layout adapted from Codenotch (MIT); see THIRD_PARTY_NOTICES.md.
enum AIReadError: Error {
    case unavailable, malformed, timedOut, excessiveOutput, rateLimited, authentication, passiveCacheUnavailable, passiveCacheExpired
    case claudeStatusLineUnavailable, claudeStatusLineExpired
    var message: String {
        switch self {
        case .unavailable: return "Fonte local indisponível"
        case .malformed: return "Fonte sem cotas reconhecidas"
        case .timedOut: return "Tempo limite da consulta excedido"
        case .excessiveOutput: return "Consulta excedeu o limite de saída"
        case .rateLimited: return "Provedor limitou consultas; aguardando"
        case .authentication: return "Sessão da CLI indisponível"
        case .passiveCacheUnavailable: return "Cache passivo Claude sem cota recente verificável; a atualização depende do cliente Claude"
        case .passiveCacheExpired: return "Cache passivo Claude antigo; a atualização depende do cliente Claude"
        case .claudeStatusLineUnavailable: return "Status line Claude sem cotas; aguarde uma entrega do Claude Code"
        case .claudeStatusLineExpired: return "Entrega da status line Claude antiga ou com data futura"
        }
    }
}

actor AIProviders {
    typealias Fetch = @Sendable (IndicatorID, Date) throws -> IndicatorReading
    private let fetch: Fetch
    private var failures: [IndicatorID: Int] = [:]
    private var retryAfter: [IndicatorID: Date] = [:]
    private var refreshing: Set<IndicatorID> = []
    private let stateURL: URL?
    private struct PollState: Codable {
        var failures: [String: Int]
        var retryAfter: [String: Date]
    }

    init(fetch: Fetch? = nil, stateDirectory: URL? = nil) {
        self.fetch = fetch ?? { id, now in try AISources.fetch(id, now) }
        let directory = stateDirectory ?? (fetch == nil ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("NexoBar") : nil)
        stateURL = directory?.appendingPathComponent("ai-poll-state.json")
        if let stateURL, let bytes = try? AIProviderIntegrations.bounded(stateURL), let saved = try? JSONDecoder().decode(PollState.self, from: bytes) {
            for (key, count) in saved.failures { if let id = IndicatorID(rawValue: key) { failures[id] = count } }
            for (key, until) in saved.retryAfter { if let id = IndicatorID(rawValue: key) { retryAfter[id] = until } }
        }
    }
    func refresh() async -> [IndicatorReading] { await refresh(ids: IndicatorID.ai) }
    func refresh(ids: [IndicatorID]) async -> [IndicatorReading] { await refresh(ids: ids, at: Date()) }
    func refresh(at now: Date) async -> [IndicatorReading] { await refresh(ids: IndicatorID.ai, at: now) }
    func refresh(ids: [IndicatorID], at now: Date) async -> [IndicatorReading] {
        await withTaskGroup(of: (Int, IndicatorReading).self) { group in
            for (index, id) in ids.enumerated() { group.addTask { (index, await self.refresh(id: id, at: now)) } }
            var result: [(Int, IndicatorReading)] = []
            for await item in group { result.append(item) }
            return result.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
    func refresh(id: IndicatorID) async -> IndicatorReading { await refresh(id: id, at: Date()) }
    func refresh(id: IndicatorID, at now: Date) async -> IndicatorReading {
        guard id.isAI else { return .unavailable(id, "Indicador não é um provedor") }
        guard !refreshing.contains(id) else { return .unavailable(id, "Consulta em andamento") }
        // Claude has a five-minute polling cadence and explicit manual retries.
        // Do not let an old receipt-era pause mask a corrected folder/session.
        if id != .claude, let until = retryAfter[id], until > now {
            return failed(id, message: "Consultas em pausa até \(until.formatted(date: .omitted, time: .shortened))")
        }
        refreshing.insert(id)
        defer { refreshing.remove(id) }
        do {
            let operation = fetch
            let reading = try await Task.detached(priority: .utility) { try operation(id, now) }.value
            failures[id] = 0; retryAfter[id] = nil
            save()
            return reading
        } catch {
            if let known = error as? CLIWorkingDirectoryError { return failed(id, message: known.localizedDescription) }
            if let known = error as? ClaudePTYError { return failed(id, message: known.message) }
            let resolved: AIReadError
            switch error {
            case let known as AIReadError: resolved = known
            case UsageProviderError.needsAuth, UsageProviderError.credentialExpired: resolved = .authentication
            case UsageProviderError.rateLimited: resolved = .rateLimited
            default: resolved = .unavailable
            }
            if id == .claude {
                failures[id] = nil; retryAfter[id] = nil
                save()
                return failed(id, message: resolved.message)
            }
            let count = min((failures[id] ?? 0) + 1, 10)
            failures[id] = count
            let delay: TimeInterval = id == .kiro && count >= 3 ? 1800 :
                resolved == .rateLimited ? 900 : min(1800, 60 * pow(2, Double(count - 1)))
            retryAfter[id] = now.addingTimeInterval(delay)
            save()
            return failed(id, message: resolved.message)
        }
    }
    private func failed(_ id: IndicatorID, message: String) -> IndicatorReading {
        .unavailable(id, message)
    }

    private func save() {
        guard let stateURL else { return }
        let state = PollState(failures: Dictionary(uniqueKeysWithValues: failures.map { ($0.key.rawValue, $0.value) }),
                              retryAfter: Dictionary(uniqueKeysWithValues: retryAfter.map { ($0.key.rawValue, $0.value) }))
        guard let bytes = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? bytes.write(to: stateURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
}

enum AISources {
    static func fetch(_ id: IndicatorID, _ now: Date) throws -> IndicatorReading {
        var result = try AIProviderIntegrations.read(id, now: now)
        result.activity = AIActivity.read(id, now: now)
        return result
    }
}

enum AIUsageParser {
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let result = n.doubleValue
        return result.isFinite && result >= 0 ? result : nil
    }
    static func date(_ value: Any?) -> Date? {
        if let seconds = number(value), (1_000_000_000...4_102_444_800).contains(seconds) {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = value as? String else { return nil }
        let iso = ISO8601DateFormatter()
        if let value = iso.date(from: text) { return value }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: text)
    }
    static func reading(_ id: IndicatorID, windows: [QuotaWindow], headline: Double?, now: Date, source: String) throws -> IndicatorReading {
        guard !windows.isEmpty else { throw AIReadError.malformed }
        return IndicatorReading(id: id, value: headline.map(IndicatorReading.percent) ?? "—", detail: source,
                                sampledAt: now, windows: windows)
    }
    static func codex(_ text: String, now: Date) throws -> IndicatorReading {
        let lines = text.split(separator: "\n")
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (obj["id"] as? Int) == 2 else { continue }
            if let error = obj["error"] as? [String: Any] {
                let code = error["code"] as? Int
                let message = (error["message"] as? String ?? "").lowercased()
                if code == 429 || message.contains("rate limit") || message.contains("too many") { throw AIReadError.rateLimited }
                if message.contains("auth") || message.contains("login") || code == 401 { throw AIReadError.authentication }
                throw AIReadError.malformed
            }
            guard let result = obj["result"] as? [String: Any] else { throw AIReadError.malformed }
            var windows: [QuotaWindow] = []
            // Use the account's main limits, never concatenate model-specific Spark quotas.
            let map = result["rateLimitsByLimitId"] as? [String: Any]
            let limits = (map?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any])
            guard limits != nil else { throw AIReadError.malformed }
            if let limitID = limits?["limitId"] as? String, limitID != "codex" { throw AIReadError.malformed }
            for (key, name) in [("primary", "Principal"), ("secondary", "Secundária")] {
                guard let entry = limits?[key] as? [String: Any], let used = number(entry["usedPercent"]) else { continue }
                let duration = number(entry["windowDurationMins"])
                windows.append(QuotaWindow(name: duration == 10080 ? "Semanal" : name, usedPercent: used, resetsAt: date(entry["resetsAt"]),
                                           detail: duration.map { "Janela de \(String(format: "%.0f", $0)) minutos" } ?? "", id: key, durationMinutes: duration))
            }
            for bucket in (map?.keys.sorted() ?? []) where bucket != "codex" {
                guard let entry = map?[bucket] as? [String: Any] else { continue }
                for key in ["primary", "secondary"] {
                    guard let row = entry[key] as? [String: Any], let used = number(row["usedPercent"]) else { continue }
                    windows.append(QuotaWindow(name: "\(bucket) · \(key == "primary" ? "Principal" : "Secundária")", usedPercent: used,
                                               resetsAt: date(row["resetsAt"]), id: "\(bucket).\(key)", durationMinutes: number(row["windowDurationMins"])))
                }
            }
            return try reading(.codex, windows: windows, headline: number((limits?["primary"] as? [String: Any])?["usedPercent"]), now: now, source: "Codex CLI · limite utilizado da conta")
        }
        throw AIReadError.malformed
    }
    static func claude(_ data: Data, capturedAt: Date, now: Date) throws -> IndicatorReading {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIReadError.malformed }
        func canonical(_ kind: String) -> String {
            switch kind { case "five_hour", "session": return "session"; case "seven_day", "weekly_all", "weekly": return "weekly_all"; case "seven_day_opus", "weekly_opus": return "weekly_opus"; default: return kind }
        }
        func label(_ kind: String) -> String {
            switch canonical(kind) { case "session": return "Sessão"; case "weekly_all": return "Semanal"; case "weekly_opus": return "Opus"; case "seven_day_sonnet", "weekly_sonnet": return "Sonnet"; case "weekly_scoped": return "Semanal por modelo"; default: return kind.replacingOccurrences(of: "_", with: " ").capitalized }
        }
        func duration(_ kind: String) -> Double? {
            switch canonical(kind) { case "session": return 300; case "weekly_all", "weekly_opus", "weekly_scoped", "seven_day_sonnet", "weekly_sonnet": return 10080; default: return nil }
        }
        var windows: [QuotaWindow] = []
        var seen = Set<String>()
        for entry in obj["limits"] as? [[String: Any]] ?? [] {
            guard let kind = entry["kind"] as? String, !kind.isEmpty, kind.count <= 100,
                  let used = number(entry["percent"]), seen.insert(canonical(kind)).inserted else { continue }
            windows.append(QuotaWindow(name: label(kind), usedPercent: used, resetsAt: date(entry["resets_at"]), id: kind, durationMinutes: duration(kind)))
        }
        let legacy = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"] + obj.keys.filter { $0.hasPrefix("seven_day_") && !["seven_day_sonnet", "seven_day_opus"].contains($0) }.sorted()
        for key in legacy {
            guard let window = obj[key] as? [String: Any], let used = number(window["utilization"]), seen.insert(canonical(key)).inserted else { continue }
            windows.append(QuotaWindow(name: label(key), usedPercent: used, resetsAt: date(window["resets_at"]), id: key, durationMinutes: duration(key)))
        }
        windows.sort { ($0.id.map(canonical) == "session" ? 0 : 1) < ($1.id.map(canonical) == "session" ? 0 : 1) }
        let headline = windows.first { $0.id.map(canonical) == "session" }?.usedPercent
        var reading = try reading(.claude, windows: windows, headline: headline, now: capturedAt, source: "Cache passivo Claude Desktop · atualização depende do cliente Claude")
        let age = now.timeIntervalSince(capturedAt)
        reading.isStale = age < 0 || age >= ClaudeUsageCache.maximumAge
        if reading.isStale { reading.detail += " · leitura antiga" }
        return reading
    }
    static func kiro(_ raw: String, now: Date) throws -> IndicatorReading {
        let text = raw.replacingOccurrences(of: "\u{001B}\\[[0-9;:?]*[ -/]*[@-~]|\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)", with: "", options: .regularExpression)
        let lower = text.lowercased(with: Locale(identifier: "en_US_POSIX"))
        if ["not logged in", "login required", "oauth error", "kiro-cli login", "failed to initialize auth"].contains(where: lower.contains) { throw AIReadError.authentication }
        if lower.contains("rate limit") || lower.contains("too many requests") { throw AIReadError.rateLimited }
        let percent = captures(text, pattern: #"[█░▒▓▰▱━─]+\s*(\d+(?:\.\d+)?)%"#).first.flatMap(Double.init)
        let pair = captures(text, pattern: #"\((\d+(?:\.\d+)?)\s+of\s+(\d+(?:\.\d+)?)\s+covered"#).compactMap(Double.init)
        let used = percent ?? (pair.count == 2 && pair[1] > 0 ? pair[0] / pair[1] * 100 : nil)
        guard let used, used.isFinite, used >= 0 else { throw AIReadError.malformed }
        let stamp = captures(text, pattern: #"(?i)resets on (\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2})"#).first
        var reset: Date?
        if let stamp {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let parts = stamp.split(separator: stamp.contains("-") ? "-" : "/").compactMap { Int($0) }
            let year = calendar.component(.year, from: now)
            if parts.count == 3 { reset = civilDate(year: parts[0], month: parts[1], day: parts[2], calendar: calendar) }
            if parts.count == 2 {
                reset = civilDate(year: year, month: parts[0], day: parts[1], calendar: calendar)
                if let date = reset, date < calendar.startOfDay(for: now) { reset = civilDate(year: year + 1, month: parts[0], day: parts[1], calendar: calendar) }
            }
        }
        var windows = [QuotaWindow(name: "Créditos", usedPercent: used, resetsAt: reset,
                                   detail: pair.count == 2 ? "\(pair[0]) de \(pair[1]) créditos utilizados" : "Percentual informado pela CLI",
                                   id: "credits", durationMinutes: AIProviderIntegrations.monthlyMinutes(reset), used: pair.count == 2 && pair[1] > 0 ? pair[0] : nil, limit: pair.count == 2 && pair[1] > 0 ? pair[1] : nil, unit: "créditos")]
        let bonus = captures(text, pattern: #"Bonus credits:\s*(\d+(?:\.\d+)?)/(\d+(?:\.\d+)?)"#).compactMap(Double.init)
        if bonus.count == 2, bonus[1] > 0 {
            let days = captures(text, pattern: #"expires in (\d+) days?"#).first.flatMap(Int.init)
            windows.append(QuotaWindow(name: "Bônus", usedPercent: bonus[0] / bonus[1] * 100,
                                       resetsAt: days.flatMap { calendarDate($0, now: now) }, detail: "\(bonus[0]) de \(bonus[1]) créditos utilizados", id: "bonus", used: bonus[0], limit: bonus[1], unit: "créditos"))
        }
        return try reading(.kiro, windows: windows, headline: used, now: now, source: "Kiro CLI /usage · créditos utilizados")
    }
    private static func calendarDate(_ days: Int, now: Date) -> Date? { Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: now) }
    private static func civilDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard let result = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.month, from: result) == month, calendar.component(.day, from: result) == day else { return nil }
        return result
    }
    static func captures(_ text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [] }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}

// Spawn into an owned process group atomically, so timeouts also reap CLI children.
// Stdout/stderr are drained nonblocking and bounded; no CLI output is logged or persisted.
enum UsageCommand {
    static let maximumOutput = 512 * 1024
    private static let processLock = NSLock()
    private static var groups: Set<pid_t> = []
    private static var shuttingDown = false
    static var runningProcessCount: Int { processLock.lock(); defer { processLock.unlock() }; return groups.count }
    static func terminateOwnedProcesses(finalShutdown: Bool = true) {
        processLock.lock(); defer { processLock.unlock() }
        if finalShutdown { shuttingDown = true }
        for pid in groups { kill(-pid, SIGKILL) }
    }
    static func register(_ pid: pid_t) -> Bool {
        processLock.lock(); defer { processLock.unlock() }
        guard !shuttingDown else { return false }
        groups.insert(pid); return true
    }
    static func unregister(_ pid: pid_t) {
        processLock.lock(); defer { processLock.unlock() }
        groups.remove(pid)
    }
    static func locate(_ name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/Applications/Codex.app/Contents/Resources"] +
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in dirs where directory.hasPrefix("/") {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
    static func run(binary: URL, arguments: [String], input: String = "", rpc: Bool = false,
                    timeout: TimeInterval = 20, workingDirectory: URL? = nil) throws -> String {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("NexoBar/usage", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var out: [Int32] = [0, 0], err: [Int32] = [0, 0], stdin: [Int32] = [0, 0]
        guard pipe(&out) == 0 else { throw AIReadError.unavailable }
        guard pipe(&err) == 0 else { close(out[0]); close(out[1]); throw AIReadError.unavailable }
        guard pipe(&stdin) == 0 else { out.forEach { close($0) }; err.forEach { close($0) }; throw AIReadError.unavailable }
        defer { (out + err + stdin).forEach { close($0) } }
        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attr)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr) }
        for (source, destination) in [(stdin[0], STDIN_FILENO), (out[1], STDOUT_FILENO), (err[1], STDERR_FILENO)] {
            posix_spawn_file_actions_adddup2(&actions, source, destination)
        }
        for fd in out + err + stdin { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawn_file_actions_addchdir_np(&actions, (workingDirectory ?? scratch).path)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)
        var env = ProcessInfo.processInfo.environment
        env = AISessionPolicy.nonInteractiveEnvironment(env)
        let argv = ([binary.path] + arguments).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { a in envp.withUnsafeBufferPointer { e in
            posix_spawn(&pid, binary.path, &actions, &attr, a.baseAddress!, e.baseAddress!)
        } }
        guard result == 0 else { throw AIReadError.unavailable }
        close(out[1]); out[1] = -1; close(err[1]); err[1] = -1; close(stdin[0]); stdin[0] = -1
        for fd in [out[0], err[0]] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        var reaped = false
        defer {
            kill(-pid, SIGKILL)
            if !reaped { kill(pid, SIGKILL); var status: Int32 = 0; while waitpid(pid, &status, 0) == -1 && errno == EINTR {} }
            unregister(pid)
        }
        guard register(pid) else { throw AIReadError.unavailable }
        func send(_ text: String) throws {
            let data = Array(text.utf8)
            // macOS prevents SIGPIPE from terminating the GUI if the CLI closes stdin.
            _ = fcntl(stdin[1], F_SETNOSIGPIPE, 1)
            let count = data.withUnsafeBytes { Darwin.write(stdin[1], $0.baseAddress, $0.count) }
            guard count == data.count else { throw AIReadError.unavailable }
        }
        if !input.isEmpty { try send(input) }
        if !rpc { close(stdin[1]); stdin[1] = -1 }
        let started = ProcessInfo.processInfo.systemUptime
        var stdout = Data(), stderr = Data(), sentRequest = false, status: Int32 = 0
        var buffer = [UInt8](repeating: 0, count: 16384)
        while ProcessInfo.processInfo.systemUptime - started < timeout {
            for (fd, stream) in [(out[0], 0), (err[0], 1)] {
                while true {
                    let count = Darwin.read(fd, &buffer, buffer.count)
                    if count <= 0 { break }
                    guard stdout.count + stderr.count + count <= maximumOutput else { throw AIReadError.excessiveOutput }
                    if stream == 0 { stdout.append(contentsOf: buffer.prefix(count)) } else { stderr.append(contentsOf: buffer.prefix(count)) }
                }
            }
            if rpc {
                let lines = String(decoding: stdout, as: UTF8.self).split(separator: "\n")
                for line in lines {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                    if (object["id"] as? Int) == 1, !sentRequest {
                        guard object["error"] == nil else { throw AIReadError.malformed }
                        try send("{\"method\":\"initialized\"}\n{\"id\":2,\"method\":\"account/rateLimits/read\",\"params\":null}\n")
                        sentRequest = true
                    }
                    if (object["id"] as? Int) == 2 { return String(decoding: stdout, as: UTF8.self) }
                }
            }
            let exit = waitpid(pid, &status, WNOHANG)
            if exit == pid {
                // The next drain sees any final bytes written immediately before exit.
                reaped = true
                for (fd, stream) in [(out[0], 0), (err[0], 1)] {
                    while true {
                        let count = Darwin.read(fd, &buffer, buffer.count)
                        if count <= 0 { break }
                        guard stdout.count + stderr.count + count <= maximumOutput else { throw AIReadError.excessiveOutput }
                        if stream == 0 { stdout.append(contentsOf: buffer.prefix(count)) } else { stderr.append(contentsOf: buffer.prefix(count)) }
                    }
                }
                let combined = String(decoding: stdout, as: UTF8.self) + "\n" + String(decoding: stderr, as: UTF8.self)
                if status != 0 {
                    let lower = combined.lowercased()
                    if lower.contains("rate limit") || lower.contains("too many requests") { throw AIReadError.rateLimited }
                    if lower.contains("auth") || lower.contains("login") { throw AIReadError.authentication }
                    throw AIReadError.unavailable
                }
                return combined
            }
            if exit < 0 && errno != EINTR { throw AIReadError.unavailable }
            usleep(20_000)
        }
        throw AIReadError.timedOut
    }
}

enum ClaudeUsageCache {
    static let maximumAge: TimeInterval = 1800
    typealias Decoder = (Data) -> (data: Data, frameLength: Int)?

    struct Inspection {
        var matchingEntries = 0
        var decodedEntries = 0
        var datedEntries = 0
        var latest: IndicatorReading?

        func reading() throws -> IndicatorReading {
            guard let latest else { throw AIReadError.passiveCacheUnavailable }
            guard !latest.isStale else { throw AIReadError.passiveCacheExpired }
            return latest
        }

        func diagnostic(now: Date) -> String {
            let state = latest.map { $0.isStale ? "antigo" : "recente" } ?? "indisponível"
            let age = latest?.sampledAt.map { String(format: "%.0f", now.timeIntervalSince($0)) } ?? "ausente"
            let stamp = latest?.sampledAt.map { String(format: "%.0f", $0.timeIntervalSince1970) } ?? "ausente"
            let percentages = latest?.windows.map { window in
                window.usedPercent.map { String(format: "%.2f", $0) } ?? "ausente"
            }.joined(separator: ",") ?? "ausente"
            return "claude: cache=\(state) | entradas=\(matchingEntries) | decodificadas=\(decodedEntries) | datadas=\(datedEntries) | idade_s=\(age) | sampledAt_epoch=\(stamp) | janelas=\(latest?.windows.count ?? 0) | uso_percent=\(percentages)"
        }
    }

    static func read(now: Date) throws -> IndicatorReading {
        try inspect(now: now).reading()
    }

    // Output is deliberately restricted to quota numbers and freshness metadata.
    // No paths, account IDs, headers, raw cache bytes or arbitrary provider text escape.
    static func diagnose(now: Date) -> String {
        (try? inspect(now: now))?.diagnostic(now: now) ?? Inspection().diagnostic(now: now)
    }

    static func inspect(now: Date) throws -> Inspection {
        try inspect(home: FileManager.default.homeDirectoryForCurrentUser, now: now, decode: decompress)
    }

    static func inspect(home: URL, now: Date, decode: Decoder) throws -> Inspection {
        let config = home.appendingPathComponent(".claude.json")
        guard let data = boundedRead(config, cap: 2 * 1024 * 1024),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["oauthAccount"] as? [String: Any], let organization = account["organizationUuid"] as? String,
              UUID(uuidString: organization) != nil else { throw AIReadError.passiveCacheUnavailable }
        let directory = home.appendingPathComponent("Library/Application Support/Claude/Cache/Cache_Data")
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        let candidates = entries.compactMap { url -> (URL, Date)? in
            guard url.lastPathComponent.hasSuffix("_0"), let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, let size = values.fileSize, size <= 512 * 1024,
                  let date = values.contentModificationDate else { return nil }
            return (url, date)
        }.sorted { $0.1 > $1.1 }.prefix(400)
        var inspection = Inspection()
        for (url, _) in candidates {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let prefix = try? handle.read(upToCount: 8216), let key = cacheKey(prefix),
                  let start = key.range(of: "https://"), let endpoint = URL(string: String(key[start.lowerBound...])),
                  endpoint.host == "claude.ai", endpoint.path == "/api/organizations/\(organization)/usage" else { continue }
            inspection.matchingEntries += 1
            try? handle.seek(toOffset: 0)
            guard let bytes = try? handle.read(upToCount: 512 * 1024 + 1), bytes.count <= 512 * 1024,
                  cacheKey(bytes) == key, bytes.count > 24 + key.utf8.count else { continue }
            let payload = Data(bytes.dropFirst(24 + key.utf8.count))
            guard let decoded = decode(payload), decoded.frameLength > 0, decoded.frameLength <= payload.count else { continue }
            inspection.decodedEntries += 1
            let trailer = String(decoding: payload.dropFirst(decoded.frameLength), as: UTF8.self)
            // Cache mtime changes on local writes/revalidation and cannot date the quota.
            guard let captured = responseDate(trailer), captured <= now else { continue }
            inspection.datedEntries += 1
            guard let reading = try? AIUsageParser.claude(decoded.data, capturedAt: captured, now: now) else { continue }
            if inspection.latest?.sampledAt.map({ captured > $0 }) ?? true { inspection.latest = reading }
        }
        return inspection
    }

    static func responseDate(_ trailer: String) -> Date? {
        guard let stamp = AIUsageParser.captures(trailer, pattern: "(?i)\u{0000}date:([^\u{0000}]+)").first else { return nil }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"; format.timeZone = TimeZone(secondsFromGMT: 0)
        format.isLenient = false
        return format.date(from: stamp.trimmingCharacters(in: .whitespaces))
    }
    private static func boundedRead(_ url: URL, cap: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: cap + 1), data.count <= cap else { return nil }
        return data
    }
    static func cacheKey(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count > 24 else { return nil }
        func uint(_ offset: Int, _ count: Int) -> UInt64 { (0..<count).reduce(0) { $0 | UInt64(bytes[offset + $1]) << (8 * $1) } }
        guard uint(0, 8) == 0xfcfb6d1ba7725c30 else { return nil }
        let length = Int(uint(12, 4))
        guard length > 0, length <= 8192, bytes.count >= 24 + length else { return nil }
        return String(bytes: bytes[24..<24 + length], encoding: .utf8)
    }
    private static func decompress(_ data: Data) -> (data: Data, frameLength: Int)? {
        // No library is downloaded or copied from another app; absent zstd is unavailable data.
        let paths = ["/opt/homebrew/opt/zstd/lib/libzstd.dylib", "/usr/local/opt/zstd/lib/libzstd.dylib"]
        guard let library = paths.lazy.compactMap({ dlopen($0, RTLD_LOCAL | RTLD_NOW) }).first else { return nil }
        defer { dlclose(library) }
        typealias FrameSize = @convention(c) (UnsafeRawPointer?, Int) -> Int
        typealias Decode = @convention(c) (UnsafeMutableRawPointer?, Int, UnsafeRawPointer?, Int) -> Int
        typealias IsError = @convention(c) (Int) -> UInt32
        guard let f = dlsym(library, "ZSTD_findFrameCompressedSize"), let d = dlsym(library, "ZSTD_decompress"), let e = dlsym(library, "ZSTD_isError") else { return nil }
        let size = unsafeBitCast(f, to: FrameSize.self), decode = unsafeBitCast(d, to: Decode.self), isError = unsafeBitCast(e, to: IsError.self)
        return data.withUnsafeBytes { input in
            let frame = size(input.baseAddress, input.count)
            guard isError(frame) == 0, frame > 0, frame <= input.count else { return nil }
            var output = Data(count: 256 * 1024)
            let written = output.withUnsafeMutableBytes { decode($0.baseAddress, $0.count, input.baseAddress, frame) }
            guard isError(written) == 0, written > 0, written <= output.count else { return nil }
            output.count = written
            return (output, frame)
        }
    }
}
