import Foundation
import Darwin
import SQLite3

struct AIActivitySummary: Codable, Equatable {
    var state: String
    var summary: String
    var detail: String? = nil
    var observedAt: Date? = nil
}

// Passive provider metadata adapted from Codenotch's Cursor/Grok/Antigravity
// activity monitors (MIT; THIRD_PARTY_NOTICES.md). No text/content fields are decoded.
extension AIActivity {
    struct CursorMetadata {
        var unfinishedAt: Date? = nil
        var blocking: Bool = false
        var pendingPlan: Bool = false
        var checkpointAt: Date? = nil
        var updatedAt: Date? = nil
        var createdAt: Date? = nil
        var isSubagent: Bool = false
        var archived: Bool = false
    }
    struct NativeProcess {
        var pid: Int32
        var startedAt: Date
        var binaryPath: String
        var openSessions: [URL] = []
    }
    struct GrokRegistryEntry: Decodable {
        var sessionID: String
        var pid: Int32?
        var openedAt: String?
        var cwd: String?
        enum CodingKeys: String, CodingKey { case sessionID = "session_id", pid, openedAt = "opened_at", cwd }
    }
    private struct GrokEvent: Decodable {
        struct Parameters: Decodable {
            struct Update: Decodable { var sessionUpdate: String? }
            var update: Update?
        }
        var params: Parameters?
    }
    private struct GrokSessionMetadata: Decodable { var session_kind: String? }
    private struct AntigravityEvent: Decodable {
        struct ToolCall: Decodable {
            struct Arguments: Decodable {
                struct Artifact: Decodable { var RequestFeedback: Bool? }
                var ArtifactMetadata: Artifact?
            }
            var name: String?
            var arguments: Arguments?
            enum CodingKeys: CodingKey { case name, arguments }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                name = try values.decodeIfPresent(String.self, forKey: .name)
                arguments = try? values.decodeIfPresent(Arguments.self, forKey: .arguments)
            }
        }
        var type: String?
        var created_at: String?
        var tool_calls: [ToolCall]?
    }

    static func readAdditional(_ id: IndicatorID, now: Date) -> AIActivitySummary {
        let processes = nativeProcesses(id)
        guard !processes.isEmpty else { return AIActivitySummary(state: "unknown", summary: "Sem cliente ativo", detail: "Nenhum processo nativo deste cliente foi confirmado.") }
        switch id {
        case .cursor:
            let database = AIProviderIntegrations.home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            return readCursor(store: database, launchedAt: processes.map(\.startedAt).min(), now: now)
        case .grok:
            return readGrok(processes: processes, now: now)
        case .antigravity:
            return readAntigravity(processes: processes, now: now)
        default: return unsupported("Cliente sem monitor de atividade")
        }
    }

    static func readCursor(store: URL, launchedAt: Date?, now: Date) -> AIActivitySummary {
        guard let launch = launchedAt, let db = SQLiteStore.open(store) else { return unsupported("Metadados do Cursor indisponíveis") }
        defer { sqlite3_close(db) }
        let columns = Set(SQLiteStore.rows(in: db, sql: "SELECT name FROM pragma_table_info('composerHeaders')"))
        guard columns.contains("value") else { return unsupported("Este esquema Cursor não possui composerHeaders") }
        let rootFilter = columns.contains("isSubagent") ? "AND COALESCE(isSubagent,0)=0" : ""
        let archiveFilter = columns.contains("isArchived") ? "AND COALESCE(isArchived,0)=0" : ""
        let order = columns.contains("recency") ? "ORDER BY recency DESC" : ""
        let rows = SQLiteStore.rows(in: db, sql: """
            SELECT json_extract(value,'$.unfinishedRunAt'), json_extract(value,'$.hasBlockingPendingActions'),
                   json_extract(value,'$.hasPendingPlan'), json_extract(value,'$.conversationCheckpointLastUpdatedAt'),
                   json_extract(value,'$.lastUpdatedAt'), json_extract(value,'$.createdAt')
            FROM composerHeaders WHERE json_valid(value)=1
              AND COALESCE(json_extract(value,'$.isSubagent'),0)=0
              AND COALESCE(json_extract(value,'$.isArchived'),0)=0
              \(rootFilter) \(archiveFilter) \(order) LIMIT 40
            """, columns: 6)
        let readings = rows.compactMap { row -> AIActivitySummary? in
            guard row.count == 6 else { return nil }
            let metadata = CursorMetadata(unfinishedAt: milliseconds(row[0]), blocking: row[1] == "1", pendingPlan: row[2] == "1",
                                          checkpointAt: milliseconds(row[3]), updatedAt: milliseconds(row[4]), createdAt: milliseconds(row[5]))
            return cursorState(metadata, launchedAt: launch, now: now)
    }
        return aggregate(readings) ?? unsupported("Nenhuma execução ou espera confirmada nos metadados Cursor")
    }

    static func cursorState(_ value: CursorMetadata, launchedAt: Date?, now: Date) -> AIActivitySummary? {
        guard !value.archived, !value.isSubagent, let launch = launchedAt,
              let touched = value.checkpointAt ?? value.updatedAt ?? value.unfinishedAt ?? value.createdAt,
              touched >= launch, touched <= now.addingTimeInterval(1) else { return nil }
        if value.blocking || value.pendingPlan {
            return summary("waiting", stamp: touched, detail: "Cursor · flag explícita de aprovação/plano da instância atual")
        }
        // Upstream: 33,484 within-run gaps, longest826s (p99=38.1s, p99.9=239.3s).
        // Preserve its 900s window; the process/launch gate handles killed editors.
        if value.unfinishedAt != nil, now.timeIntervalSince(touched) <= 900 {
            return summary("working", stamp: touched, detail: "Cursor · execução não encerrada, checkpoint recente e editor vivo")
        }
        return nil
    }

    static func readGrok(home: URL = AIProviderIntegrations.home, processes: [NativeProcess], now: Date) -> AIActivitySummary {
        let root = home.appendingPathComponent(".grok/sessions")
        let registry = home.appendingPathComponent(".grok/active_sessions.json")
        let rows = (try? AIProviderIntegrations.bounded(registry)).flatMap { try? JSONDecoder().decode([GrokRegistryEntry].self, from: $0) } ?? []
        var candidates: [AIActivitySummary] = [], seen = Set<String>()
        for entry in rows {
            guard validSessionID(entry.sessionID), let pid = entry.pid,
                  let process = processes.first(where: { $0.pid == pid }) else { continue }
            let held = process.openSessions.first { $0.lastPathComponent == entry.sessionID }
            guard grokProcessMatches(entry: entry, process: process),
                  let directory = held ?? grokDirectory(id: entry.sessionID, cwd: entry.cwd, root: root),
                  let data = try? AIProviderIntegrations.tail(directory.appendingPathComponent("updates.jsonl"), cap: 64 * 1024) else { continue }
            let modified = AIProviderIntegrations.modification(directory.appendingPathComponent("updates.jsonl"))
            guard modified >= process.startedAt else { continue }
            if let state = grokState(inTail: data, modified: modified, now: now, headless: false) {
                candidates.append(state); seen.insert(directory.path)
            }
        }
        for process in processes {
            for directory in process.openSessions where !seen.contains(directory.path) {
                guard let bytes = try? AIProviderIntegrations.bounded(directory.appendingPathComponent("summary.json"), cap: 64 * 1024),
                      let metadata = try? JSONDecoder().decode(GrokSessionMetadata.self, from: bytes), metadata.session_kind == "headless",
                      let data = try? AIProviderIntegrations.tail(directory.appendingPathComponent("updates.jsonl"), cap: 64 * 1024) else { continue }
                let modified = AIProviderIntegrations.modification(directory.appendingPathComponent("updates.jsonl"))
                guard modified >= process.startedAt else { continue }
                if let state = grokState(inTail: data, modified: modified, now: now, headless: true) { candidates.append(state) }
            }
        }
        return aggregate(candidates) ?? unsupported("Grok ativo, sem turno atual confirmável por evento e processo")
    }

    static func grokProcessMatches(entry: GrokRegistryEntry, process: NativeProcess) -> Bool {
        guard validSessionID(entry.sessionID), entry.pid == process.pid else { return false }
        let held = process.openSessions.contains { $0.lastPathComponent == entry.sessionID }
        if !process.openSessions.isEmpty, !held { return false }
        let opened = entry.openedAt.flatMap(AIUsageParser.date)
        return held || opened.map { abs($0.timeIntervalSince(process.startedAt)) < 300 } == true
    }

    static func grokState(inTail data: Data, modified: Date, now: Date, headless: Bool) -> AIActivitySummary? {
        guard modified <= now.addingTimeInterval(1), headless || now.timeIntervalSince(modified) <= 45 else { return nil }
        for line in data.split(separator: 10).reversed() {
            guard let event = try? JSONDecoder().decode(GrokEvent.self, from: Data(line)),
                  let kind = event.params?.update?.sessionUpdate else { continue }
            if kind == "hook_execution" { continue }
            if kind == "turn_completed" { return AIActivitySummary(state: "idle", summary: "Último turno concluído", detail: "Grok · término explícito; hooks posteriores ignorados", observedAt: modified) }
            if ["user_message_chunk", "agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update", "turn_started", "plan"].contains(kind) {
                return summary("working", stamp: modified, detail: headless ? "Grok headless · processo vivo, sessão aberta por ele e evento de turno" : "Grok CLI · PID, registro e evento recente associados")
            }
            return nil
        }
        return nil
    }

    static func validSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted) == nil
    }
    private static func grokDirectory(id: String, cwd: String?, root: URL) -> URL? {
        guard validSessionID(id) else { return nil }
        if let cwd {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let candidate = root.appendingPathComponent(cwd.addingPercentEncoding(withAllowedCharacters: allowed) ?? "").appendingPathComponent(id)
            if FileManager.default.fileExists(atPath: candidate.path), contains(candidate, under: root) { return candidate }
        }
        let projects = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return projects.prefix(1000).map { $0.appendingPathComponent(id) }.first { FileManager.default.fileExists(atPath: $0.path) && contains($0, under: root) }
    }

    private static func readAntigravity(processes: [NativeProcess], now: Date) -> AIActivitySummary {
        let gemini = AIProviderIntegrations.home.appendingPathComponent(".gemini")
        let installs = ((try? FileManager.default.contentsOfDirectory(at: gemini, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("antigravity") }.prefix(20)
        guard let launched = processes.map(\.startedAt).min() else { return unsupported("Instância Antigravity não confirmada") }
        var files: [URL] = []
        for install in installs {
            let brain = install.appendingPathComponent("brain")
            let trajectories = (try? FileManager.default.contentsOfDirectory(at: brain, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for trajectory in trajectories.prefix(2000) {
                let transcript = trajectory.appendingPathComponent(".system_generated/logs/transcript.jsonl")
                let modified = AIProviderIntegrations.modification(transcript)
                if modified >= launched, modified <= now.addingTimeInterval(1), contains(transcript, under: brain) { files.append(transcript) }
            }
        }
        var readings: [AIActivitySummary] = []
        for file in files.sorted(by: { AIProviderIntegrations.modification($0) > AIProviderIntegrations.modification($1) }).prefix(8) {
            guard let data = try? AIProviderIntegrations.tail(file, cap: 64 * 1024) else { continue }
            let trajectory = file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let database = trajectory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("conversations/" + trajectory.lastPathComponent + ".db")
            var status: Int?
            if let db = SQLiteStore.open(database) {
                status = SQLiteStore.rows(in: db, sql: "SELECT status FROM steps ORDER BY idx DESC LIMIT 1").first.flatMap(Int.init)
                sqlite3_close(db)
            }
            if let state = antigravityState(inTail: data, modified: AIProviderIntegrations.modification(file), launchedAt: launched,
                                           permissionStatus: status, now: now) { readings.append(state) }
        }
        return aggregate(readings) ?? unsupported("Antigravity ativo; formato ou estado de evento atual não confirmado")
    }

    static func antigravityState(inTail data: Data, modified: Date, launchedAt: Date?, permissionStatus: Int?, now: Date) -> AIActivitySummary? {
        guard let launch = launchedAt, modified >= launch, modified <= now.addingTimeInterval(1) else { return nil }
        for line in data.split(separator: 10).reversed() {
            guard let event = try? JSONDecoder().decode(AntigravityEvent.self, from: Data(line)), let type = event.type else { continue }
            if ["EPHEMERAL_MESSAGE", "CONVERSATION_HISTORY", "KNOWLEDGE_ARTIFACTS", "CHECKPOINT"].contains(type) { continue }
            guard let timestamp = event.created_at.flatMap(AIUsageParser.date), timestamp >= launch, timestamp <= now.addingTimeInterval(1) else { return nil }
            if type == "PLANNER_RESPONSE" {
                if let calls = event.tool_calls, !calls.isEmpty {
                    for call in calls {
                        let name = call.name?.lowercased() ?? ""
                        let asks = name.contains("ask_question") || name == "askquestion"
                        let artifact = ["multi_replace_file_content", "write_to_file", "replace_file_content"].contains(where: name.contains)
                        if asks || (artifact && call.arguments?.ArtifactMetadata?.RequestFeedback == true) {
                            return summary("waiting", stamp: timestamp, detail: "Antigravity · pergunta/aprovação explícita da instância atual")
                        }
                    }
                } else {
                    guard now.timeIntervalSince(timestamp) <= 15 else { return nil }
                    return AIActivitySummary(state: "idle", summary: "Último turno concluído", detail: "Antigravity · resposta final explícita", observedAt: timestamp)
                }
            } else if !["USER_INPUT", "TOOL_CALL", "TOOL_RESPONSE", "TOOL_RESULT"].contains(type) { return nil }
            guard now.timeIntervalSince(timestamp) <= 60 else { return nil }
            if permissionStatus == 2 { return summary("waiting", stamp: timestamp, detail: "Antigravity · permissão pendente no último passo nativo") }
            return summary("working", stamp: timestamp, detail: "Antigravity · evento de turno recente e processo nativo vivo; estado pode mudar entre leituras")
        }
        return nil
    }

    static func nativeProcesses(_ id: IndicatorID) -> [NativeProcess] {
        guard [.cursor, .grok, .antigravity].contains(id) else { return [] }
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: min(8192, Int(needed) / MemoryLayout<pid_t>.stride + 32))
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard bytes > 0 else { return [] }
        let installedAGY = id == .antigravity ? UsageCommand.locate("agy")?.resolvingSymlinksInPath().path : nil
        let sessionsRoot = AIProviderIntegrations.home.appendingPathComponent(".grok/sessions")
        return pids.prefix(min(pids.count, Int(bytes) / MemoryLayout<pid_t>.stride)).compactMap { pid in
            guard pid > 0 else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid() else { return nil }
            let name = withUnsafePointer(to: &info.pbi_comm) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) } }
            let match = id == .cursor ? (name.lowercased().contains("cursor") || name == "Electron") : id == .grok ? (name.hasPrefix("grok") || name == "agent") : (name.lowercased().contains("antigrav") || name == "agy" || name == "Electron")
            guard match else { return nil }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
            let executable = String(cString: path)
            guard trustedBinary(executable, provider: id, installedAGY: installedAGY) else { return nil }
            let start = Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
            return NativeProcess(pid: pid, startedAt: start, binaryPath: executable,
                                 openSessions: id == .grok ? openGrokSessions(of: pid, under: sessionsRoot) : [])
        }
    }
    static func trustedBinary(_ path: String, provider: IndicatorID, installedAGY: String? = nil) -> Bool {
        switch provider {
        case .cursor: return appMainBinary(path, bundleID: "com.todesktop.230313mzl4w4u92") || path.hasSuffix("/Cursor.app/Contents/MacOS/Cursor")
        case .grok: return path.hasPrefix(AIProviderIntegrations.home.path + "/.grok/downloads/grok-")
        case .antigravity: return appMainBinary(path, bundleID: "com.google.antigravity") || path.hasSuffix("/Antigravity.app/Contents/MacOS/Antigravity") || (installedAGY != nil && path == installedAGY)
        default: return false
        }
    }
    private static func appMainBinary(_ path: String, bundleID: String) -> Bool {
        guard let marker = path.range(of: "/Contents/MacOS/", options: .backwards) else { return false }
        let appURL = URL(fileURLWithPath: String(path[..<marker.lowerBound]))
        guard let bundle = Bundle(url: appURL), bundle.bundleIdentifier == bundleID,
              let executable = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String else { return false }
        return appURL.appendingPathComponent("Contents/MacOS/" + executable).standardizedFileURL.path == path
    }

    static func openGrokSessions(of pid: Int32, under root: URL) -> [URL] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: min(4096, Int(size) / MemoryLayout<proc_fdinfo>.stride + 8))
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
        guard bytes > 0 else { return [] }
        return fds.prefix(min(fds.count, Int(bytes) / MemoryLayout<proc_fdinfo>.stride)).compactMap { fd in
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return nil }
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
            let path = withUnsafePointer(to: &info.pvip.vip_path) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
            let url = URL(fileURLWithPath: path)
            guard path.hasSuffix("/events.jsonl"), contains(url, under: root) else { return nil }
            return url.deletingLastPathComponent()
        }
    }
    private static func contains(_ url: URL, under root: URL) -> Bool {
        func canonical(_ value: URL) -> String {
            guard let path = realpath(value.path, nil) else { return value.standardizedFileURL.path }
            defer { free(path) }; return String(cString: path)
        }
        let base = canonical(root)
        return canonical(url).hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }
    private static func milliseconds(_ text: String) -> Date? {
        guard let value = Double(text), value.isFinite, (1_000_000_000_000...4_102_444_800_000).contains(value) else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }
    private static func aggregate(_ values: [AIActivitySummary]) -> AIActivitySummary? {
        values.sorted { rank($0.state) == rank($1.state) ? ($0.observedAt ?? .distantPast) > ($1.observedAt ?? .distantPast) : rank($0.state) < rank($1.state) }.first
    }
    private static func unsupported(_ detail: String) -> AIActivitySummary {
        AIActivitySummary(state: "unknown", summary: "Atividade não confirmada", detail: detail)
    }
}

enum AIActivity {
    static func read(_ id: IndicatorID, now: Date) -> AIActivitySummary {
        if id == .claude {
            let root = AIProviderIntegrations.home.appendingPathComponent(".claude/sessions")
            let paths = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let candidates = paths.filter { $0.pathExtension == "json" }.sorted { AIProviderIntegrations.modification($0) > AIProviderIntegrations.modification($1) }.prefix(100)
            var states: [(Date, String, String?)] = []
            for path in candidates {
                guard let data = try? AIProviderIntegrations.bounded(path, cap: 64 * 1024), let object = try? AIProviderIntegrations.object(data),
                      let pid = AIUsageParser.number(object["pid"]), pid <= Double(Int32.max), kill(Int32(pid), 0) == 0,
                      let cwd = object["cwd"] as? String, !cwd.contains("NexoBar/usage") else { continue }
                let raw = object["tempo"] as? String ?? object["status"] as? String ?? ""
                guard let state = ["blocked":"waiting", "waiting":"waiting", "active":"working", "busy":"working", "idle":"idle"][raw] else { continue }
                let stamp = AIUsageParser.number(object["statusUpdatedAt"] ?? object["updatedAt"]).map { Date(timeIntervalSince1970: $0 / 1000) } ?? AIProviderIntegrations.modification(path)
                // A live pid is required; a reused or remote pid is not enough evidence.
                if let domain = object["pidDomain"] as? String, domain != "darwin" { continue }
                var info = proc_bsdinfo()
                guard proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size),
                      let start = AIUsageParser.number(object["startedAt"]),
                      abs(start / 1000 - Double(info.pbi_start_tvsec) - Double(info.pbi_start_tvusec) / 1_000_000) < 3 else { continue }
                states.append((stamp, state, URL(fileURLWithPath: cwd).lastPathComponent))
            }
            if let selected = states.sorted(by: { rank($0.1) == rank($1.1) ? $0.0 > $1.0 : rank($0.1) < rank($1.1) }).first {
                return summary(selected.1, stamp: selected.0, detail: selected.2.map { "Pasta: " + $0 })
            }
        }
        if id == .kiro {
            let root = AIProviderIntegrations.home.appendingPathComponent(".kiro/sessions")
            let projects = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            var candidates: [URL] = []
            for project in projects.prefix(100) {
                let sessions = (try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                candidates += sessions.prefix(200).map { $0.appendingPathComponent("session.json") }
            }
            for path in candidates.sorted(by: { AIProviderIntegrations.modification($0) > AIProviderIntegrations.modification($1) }).prefix(20) {
                guard let data = try? AIProviderIntegrations.bounded(path, cap: 128 * 1024), let object = try? AIProviderIntegrations.object(data),
                      (object["_meta"] as? [String: Any])?["sincronizarConversas"] == nil,
                      let raw = object["status"] as? String,
                      let state = ["idle":"idle", "waiting_on_user":"waiting", "working":"working", "running":"working"][raw] else { continue }
                let stamp = AIUsageParser.date(object["lastModifiedAt"]) ?? AIProviderIntegrations.modification(path)
                guard now.timeIntervalSince(stamp) >= 0, now.timeIntervalSince(stamp) < 120 else { continue }
                return summary(state, stamp: stamp, detail: "Estado explícito de sessão Kiro atualizada há menos de 2min; sem confirmação do processo.")
            }
        }
        if id == .codex {
            let paths = AIProviderIntegrations.codexPaths()
            var latest: (Date, String)?
            for path in paths {
                guard let data = try? AIProviderIntegrations.tail(path) else { continue }
                for line in data.split(separator: 10).reversed() {
                    guard let object = try? AIProviderIntegrations.object(Data(line)), object["type"] as? String == "event_msg",
                          let payload = object["payload"] as? [String: Any], let type = payload["type"] as? String,
                          ["task_started", "task_complete", "turn_aborted"].contains(type),
                          let stamp = AIUsageParser.date(object["timestamp"]) else { continue }
                    if stamp > latest?.0 ?? .distantPast { latest = (stamp, type) }; break
                }
            }
            if let (stamp, type) = latest {
                if type == "task_complete" { return AIActivitySummary(state: "idle", summary: "Última atividade concluída", observedAt: stamp) }
                if type == "task_started", now.timeIntervalSince(stamp) < 600 {
                    return AIActivitySummary(state: "working", summary: "Turno iniciado", detail: "Evento local Codex; pode haver outras sessões. Não confirma estado de processos após o último evento.", observedAt: stamp)
                }
                return AIActivitySummary(state: "unknown", summary: "Estado atual não confirmado", observedAt: stamp)
            }
        }
        if [.cursor, .grok, .antigravity].contains(id) { return readAdditional(id, now: now) }
        if [.copilot, .opencode, .glm].contains(id) { return AIActivitySummary(state: "unknown", summary: "Atividade não publicada", detail: "A fonte de cotas deste cliente não fornece estado de execução; o fork Windows também não possui monitor de atividade para este provedor.") }
        // Fresh writes alone are not proof that an assistant is working or waiting.
        return AIActivitySummary(state: "unknown", summary: "Atividade não confirmada pela fonte")
    }
    private static func rank(_ state: String) -> Int { state == "waiting" ? 0 : state == "working" ? 1 : 2 }
    private static func summary(_ state: String, stamp: Date, detail: String?) -> AIActivitySummary {
        AIActivitySummary(state: state, summary: state == "waiting" ? "Aguardando você" : state == "working" ? "Trabalhando" : "Ocioso", detail: detail, observedAt: stamp)
    }
}
