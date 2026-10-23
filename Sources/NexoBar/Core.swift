import Foundation

enum IndicatorID: String, Codable, CaseIterable, Identifiable {
    case cpu, memory, gpu, cpuTemperature, gpuTemperature, claude, codex, kiro
    case cursor, grok, copilot, opencode, antigravity, glm
    var id: String { rawValue }
    var name: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memória"
        case .gpu: return "GPU"
        case .cpuTemperature: return "Temperatura CPU"
        case .gpuTemperature: return "Temperatura GPU"
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .kiro: return "Kiro"
        case .cursor: return "Cursor"
        case .grok: return "Grok"
        case .copilot: return "Copilot"
        case .opencode: return "OpenCode Go"
        case .antigravity: return "Antigravity"
        case .glm: return "GLM"
        }
    }
    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .gpu: return "display"
        case .cpuTemperature, .gpuTemperature: return "thermometer.medium"
        case .claude: return "sun.max"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .kiro: return "sparkles"
        case .cursor: return "cursorarrow"
        case .grok: return "asterisk"
        case .copilot: return "person.crop.square"
        case .opencode: return "terminal"
        case .antigravity: return "a.circle"
        case .glm: return "g.circle"
        }
    }
    var isAI: Bool { ![.cpu, .memory, .gpu, .cpuTemperature, .gpuTemperature].contains(self) }
    static var ai: [Self] { allCases.filter(\.isAI) }
    var isNested: Bool { self == .cpuTemperature || self == .gpuTemperature }
    var temperatureChild: Self? { self == .cpu ? .cpuTemperature : self == .gpu ? .gpuTemperature : nil }
}

struct QuotaWindow: Equatable, Codable {
    var name: String
    var usedPercent: Double?
    var resetsAt: Date?
    var detail: String = ""
    var id: String? = nil
    var durationMinutes: Double? = nil
    var used: Double? = nil
    var limit: Double? = nil
    var unit: String? = nil
}

struct IndicatorReading: Equatable, Codable {
    var id: IndicatorID
    var value: String
    var detail: String
    var sampledAt: Date?
    var isStale: Bool = false
    var windows: [QuotaWindow] = []
    var usedBytes: Double? = nil
    var totalBytes: Double? = nil
    var activity: AIActivitySummary? = nil
    var numericValue: Double? = nil
    static func unavailable(_ id: IndicatorID, _ detail: String) -> Self {
        Self(id: id, value: "—", detail: detail, sampledAt: nil)
    }
    static func percent(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < Double(Int.max) else { return "—" }
        if value > 0 && value < 1 { return "<1%" }
        if value > 99 && value < 100 { return "99%" }
        return "\(Int(value.rounded()))%"
    }
    func aged(at now: Date) -> Self {
        guard let sampledAt else { return self }
        var result = self
        let age = now.timeIntervalSince(sampledAt)
        let maximumAge: TimeInterval = id.isAI ? (id == .claude ? 1800 : 600) : 15
        if age < 0 || age >= maximumAge { result.isStale = true }
        return result
    }
}

struct IndicatorConfiguration: Codable, Identifiable, Equatable {
    var id: IndicatorID
    var enabled: Bool
    var label: String
    var showLabel: Bool = false
    var memoryDisplay: MemoryDisplay = .usedTotal
    static var defaults: [Self] {
        IndicatorID.allCases.map { Self(id: $0, enabled: [.cpu, .memory, .gpu, .cpuTemperature, .gpuTemperature, .claude, .codex, .kiro].contains($0), label: $0.name) }
    }
    static func normalized(_ items: [Self]) -> [Self] {
        var seen = Set<IndicatorID>()
        var result = items.filter { seen.insert($0.id).inserted }
        result += defaults.filter { !seen.contains($0.id) }
        return result
    }
}

extension IndicatorConfiguration {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(IndicatorID.self, forKey: .id)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        label = try values.decode(String.self, forKey: .label)
        showLabel = try values.decodeIfPresent(Bool.self, forKey: .showLabel) ?? false
        memoryDisplay = try values.decodeIfPresent(MemoryDisplay.self, forKey: .memoryDisplay) ?? .usedTotal
    }
}
