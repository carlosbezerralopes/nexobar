import Foundation

/// Saída de `fila.ps1 painel` (formato `fila-painel@1`), a fila distribuída de trabalho de GPU do `~/.agents`. Os
/// tempos vêm em epoch, para a idade ser calculada na hora de mostrar. Todo campo é opcional: ausente nunca vira zero.
public struct QueuePanel: Codable, Equatable, Sendable {
    public struct Machine: Codable, Equatable, Sendable {
        public var nome: String
        /// Epoch do último batimento do consumidor; nil = nunca bateu.
        public var batimento: Double?
        public var gpu_livre: Double?
        public var cpu_livre: Double?
        public var ram_livre_gb: Double?
        public var sistema: String?
        public var vram_gb: Double?
        public init(nome: String, batimento: Double? = nil, gpu_livre: Double? = nil, cpu_livre: Double? = nil, ram_livre_gb: Double? = nil) {
            self.nome = nome; self.batimento = batimento; self.gpu_livre = gpu_livre; self.cpu_livre = cpu_livre; self.ram_livre_gb = ram_livre_gb
        }
    }
    public struct Item: Codable, Equatable, Sendable {
        public var estado: String
        public var id: String
        /// Só em andamento: a máquina que roda o item.
        public var maquina: String?
        /// Em andamento, a última batida; nos outros estados, a entrada no estado.
        public var t: Double?
        public var buscado: Bool?
        public init(estado: String, id: String, maquina: String? = nil, t: Double? = nil, buscado: Bool? = nil) {
            self.estado = estado; self.id = id; self.maquina = maquina; self.t = t; self.buscado = buscado
        }
    }
    public var formato: String?
    public var mestre: String?
    public var gerado: Double?
    public var vivo_s: Double?
    public var orfao_min: Double?
    public var maquinas: [Machine]?
    public var itens: [Item]?

    public init(mestre: String? = nil, gerado: Double? = nil, vivo_s: Double? = nil, orfao_min: Double? = nil, maquinas: [Machine]? = nil, itens: [Item]? = nil) {
        formato = "fila-painel@1"; self.mestre = mestre; self.gerado = gerado; self.vivo_s = vivo_s
        self.orfao_min = orfao_min; self.maquinas = maquinas; self.itens = itens
    }

    public static let vagasTotal: Double = 1000
    public var liveWindow: TimeInterval { vivo_s ?? 120 }
    public var orphanAfter: TimeInterval { (orfao_min ?? 15) * 60 }

    public func items(_ estado: String) -> [Item] { (itens ?? []).filter { $0.estado == estado } }
    /// Em andamento por máquina, da batida mais antiga para a mais nova.
    public func running(on machine: String) -> [Item] {
        items("andamento").filter { $0.maquina == machine }.sorted { ($0.t ?? 0) < ($1.t ?? 0) }
    }
    /// Livre e chegando, na ordem em que entraram (a fila pega o primeiro elegível).
    public var waiting: [Item] { (items("chegando") + items("livre")).sorted { ($0.t ?? 0) < ($1.t ?? 0) } }
    /// Falhas, da mais recente para a mais antiga.
    public var failures: [Item] { items("falha").sorted { ($0.t ?? 0) > ($1.t ?? 0) } }
    public var doneCount: Int { items("feito").count }
    public var doneToFetch: Int { items("feito").filter { $0.buscado != true }.count }
    /// Em andamento numa máquina fora da lista (consumidor removido do fila.json, por exemplo): não pode sumir.
    public var runningElsewhere: [Item] {
        let known = Set((maquinas ?? []).map(\.nome))
        return items("andamento").filter { !known.contains($0.maquina ?? "") }
    }

    /// Itens mostrados por máquina para caber em `budget` linhas, contando a linha "+N" de quem passa do limite: o maior
    /// de 1…`maximum` que cabe; nunca menos de 1.
    public func runningLimit(budget: Int, maximum: Int) -> Int {
        let counts = (maquinas ?? []).map { running(on: $0.nome).count }
        func lines(_ p: Int) -> Int { counts.reduce(0) { $0 + min($1, p) + ($1 > p ? 1 : 0) } }
        return (1...max(1, maximum)).last { lines($0) <= budget } ?? 1
    }
    /// Linhas usadas pelos itens em andamento com esse limite por máquina.
    public func runningLines(limit: Int) -> Int {
        (maquinas ?? []).map { running(on: $0.nome).count }.reduce(0) { $0 + min($1, limit) + ($1 > limit ? 1 : 0) }
    }

    public func isAlive(_ machine: Machine, at now: Date) -> Bool {
        guard let beat = machine.batimento else { return false }
        return now.timeIntervalSince1970 - beat <= liveWindow
    }
}

/// O que o NexoBar grava para o widget (`widget-fila/fila.json`): o último painel lido, quando tentou ler e, se a
/// última tentativa falhou, o motivo. Falha mantém o painel anterior, que o widget mostra esmaecido.
public struct QueueSnapshot: Codable, Equatable, Sendable {
    public var painel: QueuePanel?
    public var lido: Double?
    public var erro: String?

    public init(painel: QueuePanel? = nil, lido: Double? = nil, erro: String? = nil) { self.painel = painel; self.lido = lido; self.erro = erro }

    public static let widgetKind = "fila-trabalho"
    public static let fileName = "fila.json"
    /// O NexoBar lê a fila a cada minuto; sem leitura nova em 3 min, o widget esmaece.
    public static let interval: TimeInterval = 60
    public static let staleAfter: TimeInterval = 180

    public static var directory: URL {
        WorkersTelemetry.defaultDirectory.deletingLastPathComponent().appendingPathComponent("NexoBar/widget-fila", isDirectory: true)
    }

    public static func load(directory: URL = directory) -> QueueSnapshot? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    public func save(directory: URL = Self.directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Leitura nova de `fila.ps1 painel`: sucesso troca o painel; falha guarda o motivo e conserva o painel anterior.
    public func updated(output: Data?, error: String?, now: Date) -> QueueSnapshot {
        if let output, let panel = try? JSONDecoder().decode(QueuePanel.self, from: output), panel.formato == "fila-painel@1" {
            return QueueSnapshot(painel: panel, lido: now.timeIntervalSince1970, erro: nil)
        }
        let reason = error?.trimmingCharacters(in: .whitespacesAndNewlines)
        return QueueSnapshot(painel: painel, lido: now.timeIntervalSince1970, erro: (reason?.isEmpty == false ? reason : nil) ?? "painel da fila ilegível")
    }

    /// Data do painel mostrado; sem ela, a da tentativa.
    public var panelDate: Date? { (painel?.gerado ?? lido).map { Date(timeIntervalSince1970: $0) } }
    public func isStale(at now: Date) -> Bool {
        guard erro == nil, let date = panelDate else { return true }
        return now.timeIntervalSince(date) > Self.staleAfter
    }

    /// O que o widget mostra, sem a hora da leitura: o app só pede recarga quando muda. A batida entra por minuto, que
    /// é o que o widget mostra dela.
    public var signature: String {
        let p = painel
        let machines = (p?.maquinas ?? []).map { m in
            "\(m.nome):\(m.gpu_livre.map { "\($0)" } ?? "-"):\(m.cpu_livre.map { "\($0)" } ?? "-"):\(m.ram_livre_gb.map { "\($0)" } ?? "-"):\(m.batimento.map { Int($0) / 60 } ?? -1)"
        }
        let items = (p?.itens ?? []).map { "\($0.estado):\($0.id):\($0.maquina ?? ""):\($0.buscado == true):\(($0.t.map { Int($0) } ?? -1) / 60)" }
        return ([p?.mestre ?? "", erro ?? ""] + machines + items).joined(separator: "|")
    }
}

public enum QueueFormat {
    /// "agora", "há 3 min", "há 2 h", "há 4 d".
    public static func age(since epoch: Double?, to now: Date) -> String {
        guard let epoch else { return WorkerFormat.missing }
        let s = max(0, Int(now.timeIntervalSince1970 - epoch))
        if s < 60 { return "agora" }
        if s < 3600 { return "há \(s / 60) min" }
        if s < 172800 { return "há \(s / 3600) h" }
        return "há \(s / 86400) d"
    }
    /// Fração livre de uma vaga (0…1); ausente fica nil.
    public static func freeFraction(_ v: Double?) -> Double? {
        v.flatMap { $0.isFinite && $0 >= 0 ? min(1, $0 / QueuePanel.vagasTotal) : nil }
    }
}
