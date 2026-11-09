import Foundation

enum IndicatorID: String, Codable, CaseIterable, Identifiable {
    // Case order is the default bar order: CPU · GPU · SSD · RAM, then the agents.
    case cpu, gpu, ssd, memory, cpuTemperature, gpuTemperature, ssdTemperature, claude, codex, kiro
    case cursor, grok, copilot, opencode, antigravity, glm
    var id: String { rawValue }
    var name: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "RAM"
        case .gpu: return "GPU"
        case .ssd: return "SSD"
        case .cpuTemperature: return "Temperatura CPU"
        case .gpuTemperature: return "Temperatura GPU"
        case .ssdTemperature: return "Temperatura SSD"
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
        case .ssd: return "internaldrive"
        case .cpuTemperature, .gpuTemperature, .ssdTemperature: return "thermometer.medium"
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
    var isAI: Bool { ![.cpu, .memory, .gpu, .ssd, .cpuTemperature, .gpuTemperature, .ssdTemperature].contains(self) }
    static var ai: [Self] { allCases.filter(\.isAI) }
    var isNested: Bool { [.cpuTemperature, .gpuTemperature, .ssdTemperature].contains(self) }
    var temperatureChild: Self? {
        switch self { case .cpu: return .cpuTemperature; case .gpu: return .gpuTemperature; case .ssd: return .ssdTemperature; default: return nil }
    }
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
    /// Model reported by the hardware (CPU brand, GPU, SSD); offered as an alternative to the short name.
    var hardwareName: String? = nil
    /// SSD read/write in bytes per second; nil until two counter samples exist.
    var readRate: Double? = nil
    var writeRate: Double? = nil
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
    /// SSD only: read/write rates start off, free space starts on (as on Windows).
    var showRates: Bool = false
    var showFreeSpace: Bool = true
    static let maximumLabelLength = 40
    static var defaults: [Self] {
        IndicatorID.allCases.map { Self(id: $0, enabled: [.cpu, .gpu, .ssd, .memory, .cpuTemperature, .gpuTemperature, .ssdTemperature, .claude, .codex, .kiro].contains($0), label: $0.name) }
    }
    static func normalized(_ items: [Self]) -> [Self] {
        var seen = Set<IndicatorID>()
        var result = items.filter { seen.insert($0.id).inserted }
        for item in defaults where !seen.contains(item.id) {
            // New hardware joins right before RAM; anything else goes to the end.
            if !item.id.isAI, !item.id.isNested, let memory = result.firstIndex(where: { $0.id == .memory }) { result.insert(item, at: memory) }
            else { result.append(item) }
        }
        return result
    }
    /// Preferences saved before the SSD existed (0.3.x): untouched default names and the old default
    /// order CPU · Memória · GPU move to CPU · GPU · SSD · RAM. Customized names and orders are kept.
    /// Runs once: the saved file then contains the SSD and is never migrated again.
    static func migrated(_ saved: [Self]) -> [Self] {
        guard !saved.contains(where: { $0.id == .ssd }) else { return normalized(saved) }
        var items = saved
        if let index = items.firstIndex(where: { $0.id == .memory }), items[index].label == "Memória" { items[index].label = IndicatorID.memory.name }
        let hardware = items.filter { [.cpu, .memory, .gpu].contains($0.id) }.map(\.id)
        if hardware == [.cpu, .memory, .gpu], let memory = items.firstIndex(where: { $0.id == .memory }),
           let gpu = items.firstIndex(where: { $0.id == .gpu }) {
            let item = items.remove(at: memory)
            items.insert(item, at: gpu)
        }
        return normalized(items)
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
        showRates = try values.decodeIfPresent(Bool.self, forKey: .showRates) ?? false
        showFreeSpace = try values.decodeIfPresent(Bool.self, forKey: .showFreeSpace) ?? true
    }
}

/// Bar text pieces shared with Windows (`Presentation` in windows/core/Models.cs).
enum BarText {
    /// Thin spaces (U+2009) keep CPU · GPU · SSD · RAM narrow.
    static let separator = "\u{2009}·\u{2009}"

    /// One decimal, dropped when zero: 12,3 · 12 (locale decimal mark).
    static func decimal(_ value: Double, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale; formatter.minimumFractionDigits = 0; formatter.maximumFractionDigits = 1
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

    /// RAM in binary GB, as macOS reports installed memory: "12,3/32 GB".
    static func memory(used: Double, total: Double, locale: Locale = .current) -> String? {
        guard used.isFinite, total.isFinite, used >= 0, total > 0 else { return nil }
        return "\(decimal(used / 1_073_741_824, locale: locale))/\(Int((total / 1_073_741_824).rounded())) GB"
    }

    /// Disk sizes in decimal units, as Finder shows them; whole unit names (MB/GB/TB).
    static func size(_ bytes: Double, locale: Locale = .current) -> String? {
        guard bytes.isFinite, bytes >= 0 else { return nil }
        if bytes >= 1e12 { return "\(decimal(bytes / 1e12, locale: locale)) TB" }
        if bytes >= 1e9 { return "\(Int((bytes / 1e9).rounded())) GB" }
        return "\(Int((bytes / 1e6).rounded())) MB"
    }

    /// One shared unit keeps the pair short: "L 1,2 E 0,4 MB/s".
    static func rates(read: Double, write: Double, locale: Locale = .current) -> String? {
        guard read.isFinite, write.isFinite, read >= 0, write >= 0 else { return nil }
        let mega = max(read, write) >= 1e6, unit = mega ? 1e6 : 1e3
        func format(_ value: Double) -> String {
            let scaled = value / unit
            return mega && scaled < 10 ? decimal(scaled, locale: locale) : String(Int(scaled.rounded()))
        }
        return "L \(format(read)) E \(format(write)) \(mega ? "MB/s" : "KB/s")"
    }
}
