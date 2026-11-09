import Foundation

/// Leitura publicada pelo coletor `telemetria-workers` (formato v1). Todo campo é opcional: ausente nunca vira zero.
public struct WorkerReading: Codable, Equatable, Sendable {
    public struct CPU: Codable, Equatable, Sendable { public var uso: Double?; public var temp: Double?; public var load1: Double? }
    public struct RAM: Codable, Equatable, Sendable { public var usada_gb: Double?; public var total_gb: Double?; public var swap_gb: Double? }
    /// `uso` é espaço ocupado (df); o widget mostra `ativo` (% do tempo com E/S, como o Monitor de Recursos) e as taxas, quando o coletor publicar.
    public struct SSD: Codable, Equatable, Sendable {
        public var uso: Double?; public var livre_gb: Double?; public var temp: Double?
        public var ativo: Double?; public var leitura_bs: Double?; public var escrita_bs: Double?
    }
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
    /// Threads em execução no worker e sessões do Claude Code abertas nele, quando o coletor publicar.
    public var threads: Int?
    public var claude_sessoes: Int?

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
    /// Cada posição mostra o worker escolhido nela ou, vazia, o próximo worker em ordem alfabética ainda não mostrado;
    /// o apelido da posição vale para o worker que ela mostra. Worker repetido aparece só na primeira posição; worker
    /// escolhido que sumiu da pasta continua visível como sem leitura. Os que sobram vêm depois, em ordem alfabética.
    public static func arrange(_ workers: [WorkerSnapshot], slots: [(id: String?, nickname: String?)]) -> [WorkerSnapshot] {
        var remaining = workers.sorted { $0.id < $1.id }
        var result: [WorkerSnapshot] = []
        for slot in slots {
            var worker: WorkerSnapshot
            if let id = slot.id {
                guard !result.contains(where: { $0.id == id }) else { continue }
                if let index = remaining.firstIndex(where: { $0.id == id }) { worker = remaining.remove(at: index) }
                else { worker = WorkerSnapshot(id: id, reading: nil, connection: nil) }
            } else {
                guard !remaining.isEmpty else { continue }
                worker = remaining.removeFirst()
            }
            worker.nickname = slot.nickname
            result.append(worker)
        }
        return result + remaining
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
    /// Mesmo formato do disco no Windows: uma unidade para o par, "L 1,2 E 0,4 MB/s".
    public static func rates(read: Double?, write: Double?) -> String? {
        guard let read = valid(read), let write = valid(write) else { return nil }
        let mega = max(read, write) >= 1_048_576, unit: Double = mega ? 1_048_576 : 1024
        func f(_ v: Double) -> String { number(v / unit, digits: mega && v / unit < 10 ? 1 : 0) }
        return "L \(f(read)) E \(f(write)) \(mega ? "MB/s" : "KB/s")"
    }
    public static func count(_ v: Int?) -> String { v.flatMap { $0 >= 0 ? "\($0)" : nil } ?? missing }
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
