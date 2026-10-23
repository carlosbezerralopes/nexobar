import Foundation
import SQLite3

// Narrow compatibility boundary for unmodified upstream provider parsers.
struct LimitWindow {
    var id: String
    var group: String? = nil
    var label: String
    var usedFraction: Double? = nil
    var remaining: Int? = nil
    var used: Int? = nil
    var usedText: String? = nil
    var detail: String? = nil
    var resetsAt: Date? = nil
    var duration: TimeInterval? = nil
}
enum UsageProviderError: Error {
    case badResponse(status: Int), needsAuth, credentialExpired, rateLimited(retryAfter: TimeInterval), nothingMetered(String)
}
extension String {
    var nonEmptyPlan: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
enum L10n {
    static func t(_ text: String) -> String {
        ["Auto usage":"Uso Auto", "API usage":"Uso API", "On demand":"Sob demanda", "Team on demand":"Equipe sob demanda", "Included usage":"Uso incluído", "5h limit":"Limite 5h", "Weekly limit":"Semanal", "Weekly Limit":"Semanal", "Monthly limit":"Mensal", "Weekly":"Semanal", "Current session":"Sessão", "Usage":"Uso", "MCP (1 month)":"MCP mensal"][text] ?? text
    }
}
enum AntigravityCredentials {
    static func parse(_ text: String) -> Date? { AIUsageParser.date(text) }
}
enum SQLiteStore {
    static func open(_ url: URL) -> OpaquePointer? {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        // URI encoding prevents #/? in user-controlled paths from overriding mode.
        var components = URLComponents(); components.scheme = "file"; components.path = url.path
        guard let encoded = components.string else { return nil }
        let wal = url.path + "-wal"
        let queries = FileManager.default.fileExists(atPath: wal) ? ["mode=ro"] : ["mode=ro", "immutable=1"]
        for query in queries {
            var db: OpaquePointer?
            if sqlite3_open_v2(encoded + "?" + query, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db {
                guard sqlite3_db_readonly(db, nil) == 1 else { sqlite3_close(db); continue }
                sqlite3_busy_timeout(db, 50)
                sqlite3_exec(db, "PRAGMA query_only=ON", nil, nil, nil)
                return db
            }
            sqlite3_close(db)
        }
        return nil
    }
    static func rows(in db: OpaquePointer?, sql: String, columns: Int) -> [[String]] { query(db, sql, nil, columns) }
    static func rows(in db: OpaquePointer?, sql: String, bind: String? = nil) -> [String] { query(db, sql, bind, 1).compactMap(\.first) }
    private static func query(_ db: OpaquePointer?, _ sql: String, _ bind: String?, _ columns: Int) -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        if let bind { sqlite3_bind_text(statement, 1, bind, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        var result: [[String]] = []
        var bytes = 0
        while result.count < 500, sqlite3_step(statement) == SQLITE_ROW {
            bytes += (0..<Int32(columns)).reduce(0) { $0 + Int(sqlite3_column_bytes(statement, $1)) }
            guard bytes <= 2 * 1024 * 1024 else { return [] }
            result.append((0..<Int32(columns)).map { index in sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "" })
        }
        return result
    }
}
