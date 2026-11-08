import Foundation

/// Leitura publicada pelo coletor `telemetria-workers` (formato v1). Todo campo é opcional: ausente nunca vira zero.
public struct WorkerReading: Codable, Equatable, Sendable {
    public struct CPU: Codable, Equatable, Sendable { public var uso: Double?; public var temp: Double?; public var load1: Double? }
    public struct RAM: Codable, Equatable, Sendable { public var usada_gb: Double?; public var total_gb: Double?; public var swap_gb: Double? }
    public struct SSD: Codable, Equatable, Sendable { public var uso: Double?; public var livre_gb: Double?; public var temp: Double? }
    public struct GPUProcess: Codable, Equatable, Sendable { public var pid: Int?; public var vram_mb: Double?; public var nome: String? }
    public struct GPU: Codable, Equatable, Sendable {
        public var uso: Double?; public var temp: Double?; public var vram_mb: Double?; public var vram_total_mb: Double?
        public var watts: Double?; public var processos: [GPUProcess]?
    }
    public struct Process: Codable, Equatable, Sendable { public var pid: Int?; public var cpu: Double?; public var ram_mb: Double?; public var nome: String?; public var cmd: String? }
    public var v: Int?
    public var host: String?
    public var ts: Double?
    public var hora: String?
    public var recebido: Double?
    public var cpu: CPU?
    public var ram: RAM?
    public var ssd: SSD?
    public var gpu: GPU?
    public var ventoinhas_rpm: [Double]?
    public var perfil: String?
    public var top_cpu: [Process]?

    public var topCPU: Process? { top_cpu?.max { ($0.cpu ?? -1) < ($1.cpu ?? -1) } }
    public var topGPU: GPUProcess? { gpu?.processos?.max { ($0.vram_mb ?? -1) < ($1.vram_mb ?? -1) } }
}

public struct WorkerConnection: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case conectando, conectado, desconectado }
    public var estado: State?
    public var detalhe: String?
    public var desde: Double?
}

public struct WorkerSnapshot: Equatable, Sendable, Identifiable {
    public var id: String
    public var reading: WorkerReading?
    public var connection: WorkerConnection?
    /// Apelido escolhido no editor do widget.
    public var nickname: String?

    public init(id: String, reading: WorkerReading?, connection: WorkerConnection?, nickname: String? = nil) {
        self.id = id; self.reading = reading; self.connection = connection; self.nickname = nickname
    }

    public var displayName: String {
        if let nickname = nickname?.trimmingCharacters(in: .whitespacesAndNewlines), !nickname.isEmpty { return nickname }
        return id.hasPrefix("worker-") ? String(id.dropFirst(7)) : id
    }
    /// Momento em que o Mac recebeu a leitura; sem ele, a hora do worker.
    public var receivedAt: Date? { (reading?.recebido ?? reading?.ts).map { Date(timeIntervalSince1970: $0) } }
    public var sampledAt: Date? { (reading?.ts ?? reading?.recebido).map { Date(timeIntervalSince1970: $0) } }
    public var staleAt: Date? { receivedAt?.addingTimeInterval(WorkersTelemetry.staleAfter) }

    public func isStale(at now: Date) -> Bool {
        if connection?.estado != nil && connection?.estado != .conectado { return true }
        guard let staleAt else { return true }
        return now > staleAt
    }
}

public enum WorkersTelemetry {
    public static let staleAfter: TimeInterval = 60
    public static let widgetKind = "workers-telemetria"
    public static let folderName = "workers-telemetria"

    /// Home real do usuário; no sandbox, `homeDirectoryForCurrentUser` aponta para o contêiner.
    public static var defaultDirectory: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Library/Application Support/\(folderName)", isDirectory: true)
    }

    /// Histórico de 30 s por dia (`<worker>/AAAA-MM-DD.jsonl`), ainda não exibido.
    public static func historyURL(worker: String, day: Date, directory: URL = defaultDirectory, calendar: Calendar = .current) -> URL {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        let name = String(format: "%04d-%02d-%02d.jsonl", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return directory.appendingPathComponent(worker, isDirectory: true).appendingPathComponent(name)
    }

    public static func load(directory: URL = defaultDirectory) -> [WorkerSnapshot] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var ids = Set<String>()
        for file in files where file.hasSuffix(".json") {
            ids.insert(file.hasSuffix(".estado.json") ? String(file.dropLast(12)) : String(file.dropLast(5)))
        }
        let decoder = JSONDecoder()
        func read<T: Decodable>(_ name: String) -> T? {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
            return try? decoder.decode(T.self, from: data)
        }
        return ids.sorted().map { WorkerSnapshot(id: $0, reading: read("\($0).json"), connection: read("\($0).estado.json")) }
    }

    /// Conectados primeiro, depois por nome, para os tamanhos que não cabem todos.
    public static func prioritized(_ workers: [WorkerSnapshot], now: Date) -> [WorkerSnapshot] {
        workers.enumerated().sorted { a, b in
            let sa = a.element.isStale(at: now), sb = b.element.isStale(at: now)
            return sa == sb ? a.offset < b.offset : !sa
        }.map(\.element)
    }

    /// Datas em que algum cartão muda de fresco para desatualizado, para a timeline marcar sem depender de recarga.
    public static func transitionDates(_ workers: [WorkerSnapshot], after now: Date) -> [Date] {
        Array(Set(workers.compactMap { w in w.isStale(at: now) ? nil : w.staleAt?.addingTimeInterval(1) })).filter { $0 > now }.sorted()
    }

    /// Assinatura do que o widget mostra, para o app só pedir recarga quando algo mudou.
    public static func signature(directory: URL = defaultDirectory) -> String {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        return files.map { name -> String in
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(name)@\(date)"
        }.joined(separator: "|")
    }
}

/// Ordem e apelidos escolhidos no editor do widget.
public enum WorkersLayout {
    /// Posições vazias são ignoradas; um worker repetido aparece só na primeira posição; worker escolhido que sumiu da pasta
    /// continua visível como sem leitura. Sem nenhuma posição escolhida, todos aparecem, conectados primeiro.
    public static func arrange(_ workers: [WorkerSnapshot], slots: [(id: String?, nickname: String?)], now: Date) -> [WorkerSnapshot] {
        let chosen = slots.compactMap { slot in slot.id.map { ($0, slot.nickname) } }
        guard !chosen.isEmpty else { return WorkersTelemetry.prioritized(workers, now: now) }
        var seen = Set<String>()
        return chosen.compactMap { id, nickname in
            guard seen.insert(id).inserted else { return nil }
            var worker = workers.first { $0.id == id } ?? WorkerSnapshot(id: id, reading: nil, connection: nil)
            worker.nickname = nickname
            return worker
        }
    }
}

/// Textos em pt-BR; leitura ausente vira "—".
public enum WorkerFormat {
    public static let missing = "—"
    private static func number(_ value: Double, digits: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "pt_BR"); f.numberStyle = .decimal
        f.minimumFractionDigits = 0; f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: value)) ?? missing
    }
    private static func valid(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
    public static func percent(_ v: Double?) -> String { valid(v).map { "\(Int($0.rounded()))%" } ?? missing }
    public static func temperature(_ v: Double?) -> String { valid(v).map { "\(Int($0.rounded()))°" } ?? missing }
    public static func gigabytes(_ v: Double?, digits: Int = 1) -> String { valid(v).map { number($0, digits: $0 >= 100 ? 0 : digits) } ?? missing }
    public static func megabytesAsGB(_ v: Double?) -> String { valid(v).map { $0 < 1024 ? "\(Int($0.rounded()))M" : number($0 / 1024, digits: 1) + "G" } ?? missing }
    public static func watts(_ v: Double?) -> String { valid(v).map { number($0, digits: $0 >= 10 ? 0 : 1) + "W" } ?? missing }
    public static func load(_ v: Double?) -> String { valid(v).map { number($0, digits: 2) } ?? missing }
    public static func fans(_ rpm: [Double]?) -> String {
        let values = (rpm ?? []).compactMap(valid)
        return values.isEmpty ? missing : values.map { "\(Int($0.rounded()))" }.joined(separator: " · ") + " rpm"
    }
    public static func time(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return missing }
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.timeZone = timeZone; f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
    /// Tempo desde a leitura, para o cartão desatualizado.
    public static func age(from date: Date?, to now: Date) -> String {
        guard let date else { return "sem leitura" }
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 120 { return "há \(s) s" }
        if s < 7200 { return "há \(s / 60) min" }
        if s < 172800 { return "há \(s / 3600) h" }
        return "há \(s / 86400) d"
    }
}
