import Foundation

/// Leitura publicada pelo coletor `telemetria-workers` (formato v1). Todo campo é opcional: ausente nunca vira zero.
public struct WorkerReading: Codable, Equatable, Sendable {
    public struct CPU: Codable, Equatable, Sendable { public var uso: Double?; public var temp: Double?; public var load1: Double? }
    /// `instalada_gb` é a soma dos pentes; `total_gb`, o que o kernel pode usar (sem a reserva do firmware).
    public struct RAM: Codable, Equatable, Sendable {
        public var usada_gb: Double?; public var total_gb: Double?; public var instalada_gb: Double?; public var swap_gb: Double?
        public var displayTotal: Double? { instalada_gb ?? total_gb }
    }

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
    /// Sessões do Claude Code abertas no worker, quando o coletor publicar.
    public var claude_sessoes: Int?
    /// Segundos desde o boot, no momento da leitura, quando o coletor publicar.
    public var uptime_s: Double?

    public var topCPU: Process? { topProcesses.first }
    /// Até três processos com mais CPU, do maior para o menor; só os que arredondam para 1% ou mais.
    public var topProcesses: [Process] {
        Array((top_cpu ?? []).filter { ($0.cpu ?? 0).rounded() >= 1 }.sorted { ($0.cpu ?? -1) > ($1.cpu ?? -1) }.prefix(3))
    }
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
    /// Apelido escolhido ao clicar no cartão.
    public var nickname: String?
    /// Posição do widget que o cartão ocupa (o clique edita essa posição); nil fora das quatro posições.
    public var position: Int?
    /// O NexoBar está tentando acordar este worker (ver `WakeMarks`).
    public var waking = false

    public init(id: String, reading: WorkerReading?, connection: WorkerConnection?, nickname: String? = nil) {
        self.id = id; self.reading = reading; self.connection = connection; self.nickname = nickname
    }

    public var displayName: String {
        if let nickname = nickname?.trimmingCharacters(in: .whitespacesAndNewlines), !nickname.isEmpty { return nickname }
        return Self.defaultName(id: id, host: reading?.host)
    }
    /// Nome sem apelido: worker sem o prefixo "worker-"; o Mac, pelo nome do computador.
    public static func defaultName(id: String, host: String?) -> String {
        if id.hasPrefix("worker-") { return String(id.dropFirst(7)) }
        return host ?? id
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

    /// Pasta do NexoBar lida pelo widget: leitura do próprio Mac (`mac.json`) e a escolha de posições e apelidos.
    public static var appDirectory: URL {
        defaultDirectory.deletingLastPathComponent().appendingPathComponent("NexoBar/widget-workers", isDirectory: true)
    }
    public static let macID = "mac"

    /// Workers do coletor e o Mac, gravado pelo NexoBar no mesmo formato.
    public static func loadAll(workers: URL = defaultDirectory, app: URL = appDirectory, now: Date = Date()) -> [WorkerSnapshot] {
        let waking = WakeMarks.load(directory: app, now: now)
        return (load(directory: workers).filter { $0.id != macID } + load(directory: app).filter { $0.id == macID })
            .map { var w = $0; w.waking = waking.contains(w.id); return w }
    }

    public static func load(directory: URL = defaultDirectory) -> [WorkerSnapshot] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var ids = Set<String>()
        for file in files where file.hasSuffix(".json") && file != WidgetLayoutConfig.fileName && file != WakeMarks.fileName {
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
    public static func signature(directories: [URL]) -> String { directories.map { signature(directory: $0) }.joined(separator: "#") }
    public static func signature(directory: URL = defaultDirectory) -> String {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        return files.map { name -> String in
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(name)@\(date)"
        }.joined(separator: "|")
    }
}

/// Workers que o NexoBar está acordando (`acordando.json`: id → início). Uma marca vale no máximo `limit`, o tempo
/// que o acordar.sh espera, para um app encerrado no meio não deixar o cartão "acordando" para sempre.
public enum WakeMarks {
    public static let fileName = "acordando.json"
    public static let limit: TimeInterval = 5 * 60

    public static func load(directory: URL = WorkersTelemetry.appDirectory, now: Date = Date()) -> Set<String> {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
              let marks = try? JSONDecoder().decode([String: Double].self, from: data) else { return [] }
        return Set(marks.filter { now.timeIntervalSince1970 - $0.value < limit && $0.value <= now.timeIntervalSince1970 + 5 }.keys)
    }

    public static func set(_ id: String, waking: Bool, directory: URL = WorkersTelemetry.appDirectory, now: Date = Date()) throws {
        let url = directory.appendingPathComponent(fileName)
        var marks = (try? JSONDecoder().decode([String: Double].self, from: Data(contentsOf: url))) ?? [:]
        marks[id] = waking ? now.timeIntervalSince1970 : nil
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(marks).write(to: url, options: .atomic)
    }
}

/// Escolhas feitas ao clicar num cartão do widget: o PC de cada posição e o apelido de cada PC.
public struct WidgetLayoutConfig: Codable, Equatable, Sendable {
    public static let fileName = "posicoes.json"
    public static let positions = 4
    /// PC escolhido em cada posição; nil deixa a posição no automático.
    public var ordem: [String?]
    /// Apelido por PC, não por posição: acompanha o PC se ele mudar de lugar.
    public var apelidos: [String: String]

    public init(ordem: [String?] = Array(repeating: nil, count: positions), apelidos: [String: String] = [:]) {
        self.ordem = Array((ordem + Array(repeating: nil, count: Self.positions)).prefix(Self.positions)); self.apelidos = apelidos
    }

    public static func load(directory: URL = WorkersTelemetry.appDirectory) -> WidgetLayoutConfig {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return Self(ordem: value.ordem, apelidos: value.apelidos)
    }

    public func save(directory: URL = WorkersTelemetry.appDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Põe `worker` na posição; se ele já estava em outra, as duas trocam. Apelido vazio volta ao nome original.
    public mutating func assign(position: Int, worker: String?, nickname: String?) {
        guard ordem.indices.contains(position) else { return }
        if let worker, let other = ordem.firstIndex(of: worker), other != position { ordem[other] = ordem[position] }
        ordem[position] = worker
        if let worker {
            let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            apelidos[worker] = trimmed.isEmpty ? nil : trimmed
        }
    }
}

/// Monta os cartões na ordem das posições.
public enum WorkersLayout {
    /// Cada posição mostra o PC escolhido nela ou, no automático, o próximo ainda não mostrado: o Mac primeiro, depois os
    /// workers em ordem alfabética. Cada cartão leva a posição que o clique edita. PC escolhido que sumiu continua
    /// visível como sem leitura; os apelidos valem para o PC onde ele estiver.
    public static func arrange(_ workers: [WorkerSnapshot], config: WidgetLayoutConfig) -> [WorkerSnapshot] {
        func rank(_ w: WorkerSnapshot) -> (Int, String) { (w.id == WorkersTelemetry.macID ? 0 : 1, w.id) }
        var remaining = workers.sorted { rank($0) < rank($1) }
        let chosen = Set(config.ordem.compactMap { $0 })
        var result: [WorkerSnapshot] = []
        for (position, slot) in config.ordem.enumerated() {
            var worker: WorkerSnapshot
            if let id = slot, !result.contains(where: { $0.id == id }) {
                worker = remaining.firstIndex { $0.id == id }.map { remaining.remove(at: $0) } ?? WorkerSnapshot(id: id, reading: nil, connection: nil)
            } else if let index = remaining.firstIndex(where: { !chosen.contains($0.id) }) {
                worker = remaining.remove(at: index)
            } else { continue }
            worker.position = position
            result.append(worker)
        }
        return (result + remaining).map { var w = $0; w.nickname = config.apelidos[w.id]; return w }
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
    public static func megabytesAsGB(_ v: Double?) -> String { valid(v).map { $0 < 1024 ? "\(Int($0.rounded())) MB" : number($0 / 1024, digits: 1) + " GB" } ?? missing }
    public static func watts(_ v: Double?) -> String { valid(v).map { number($0, digits: $0 >= 10 ? 0 : 1) + "W" } ?? missing }
    /// Mesmo formato do disco no Windows: uma unidade para o par, "L 1,2 E 0,4 MB/s".
    public static func rates(read: Double?, write: Double?) -> String? {
        guard let read = valid(read), let write = valid(write) else { return nil }
        let mega = max(read, write) >= 1_048_576, unit: Double = mega ? 1_048_576 : 1024
        func f(_ v: Double) -> String { number(v / unit, digits: mega && v / unit < 10 ? 1 : 0) }
        return "L \(f(read)) E \(f(write)) \(mega ? "MB/s" : "KB/s")"
    }
    /// Tempo ligado, do maior para o menor par de unidades: "42 min", "5h 12min", "3d 4h".
    public static func uptime(_ v: Double?) -> String {
        guard let s = valid(v).map({ Int($0) }) else { return missing }
        let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)min" }
        return "\(m) min"
    }
    public static func count(_ v: Int?) -> String { v.flatMap { $0 >= 0 ? "\($0)" : nil } ?? missing }
    /// VRAM em GB com uma casa, para caber junto dos watts: "1,2/6 GB".
    public static func vram(used: Double?, total: Double?) -> String {
        guard let used = valid(used), let total = valid(total) else { return missing }
        return number(used / 1024, digits: 1) + "/" + number((total / 1024).rounded(), digits: 0) + " GB"
    }
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
