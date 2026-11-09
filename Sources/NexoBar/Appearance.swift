import AppKit
import SwiftUI

enum IndicatorIconStyle: String, CaseIterable, Codable, Identifiable {
    case outline, solid, letters, system, instruments
    var id: String { rawValue }
    var title: String {
        switch self {
        case .outline: return "Contorno"
        case .solid: return "Preenchido"
        case .letters: return "Siglas"
        case .system: return "Sistema"
        case .instruments: return "Instrumentos"
        }
    }
    var usesTemplateStatusImage: Bool { self == .system || self == .instruments }
    var subtitle: String {
        switch self {
        case .system: return "Medidor, memória e tela"
        case .instruments: return "Pulso, camadas e gráficos"
        default: return "Estilo anterior"
        }
    }
    static let nativeStyles: [Self] = [.system, .instruments]
    static let legacyStyles: [Self] = [.outline, .solid, .letters]

    func symbolCandidates(for id: IndicatorID) -> [String] {
        guard usesTemplateStatusImage, !id.isAI else { return [] }
        switch id {
        case .cpu: return self == .system ? ["gauge.medium", "speedometer", "cpu"] : ["waveform.path.ecg", "chart.bar.xaxis", "waveform"]
        case .memory: return self == .system ? ["memorychip", "rectangle.stack"] : ["square.stack.3d.up", "rectangle.stack"]
        case .gpu: return self == .system ? ["display", "rectangle"] : ["rectangle.3.group", "square.grid.3x1", "display"]
        case .ssd: return self == .system ? ["internaldrive", "externaldrive"] : ["internaldrive", "externaldrive"]
        case .cpuTemperature, .gpuTemperature, .ssdTemperature: return ["thermometer.medium", "thermometer"]
        default: return [id.symbol, "circle"]
        }
    }
    func image(for id: IndicatorID) -> NSImage? {
        if id.isAI { return ProviderMarks.image(for: id) }
        if usesTemplateStatusImage {
            for name in symbolCandidates(for: id) {
                if let image = NSImage(systemSymbolName: name, accessibilityDescription: id.name)?
                    .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) {
                    image.isTemplate = true
                    return image
                }
            }
            return nil
        }
        if self == .letters {
            let title: String
            // Short hardware names, as on Windows: CPU, GPU, SSD, RAM.
            switch id { case .cpu: title = "CPU"; case .memory: title = "RAM"; case .gpu: title = "GPU"; case .ssd: title = "SSD"; case .cpuTemperature: title = "C°"; case .gpuTemperature: title = "G°"; case .ssdTemperature: title = "S°"; default: title = "?" }
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.labelColor]
            let width = max(16, ceil((title as NSString).size(withAttributes: attrs).width) + 1)
            let image = NSImage(size: NSSize(width: width, height: 16), flipped: false) { _ in
                let size = (title as NSString).size(withAttributes: attrs)
                (title as NSString).draw(at: NSPoint(x: (width-size.width)/2, y: (16-size.height)/2), withAttributes: attrs)
                return true
            }
            image.isTemplate = true
            return image
        }
        let symbol: String
        switch id {
        case .cpu: symbol = self == .solid ? "cpu.fill" : "cpu"
        case .memory: symbol = self == .solid ? "memorychip.fill" : "memorychip"
        case .gpu: symbol = self == .solid ? "square.stack.3d.up.fill" : "square.stack.3d.up"
        case .ssd: symbol = self == .solid ? "internaldrive.fill" : "internaldrive"
        case .cpuTemperature, .gpuTemperature, .ssdTemperature: symbol = self == .solid ? "thermometer.high" : "thermometer.medium"
        default: symbol = id.symbol
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: id.name) ?? ProviderMarks.image(for: id)
    }
}

enum NexoIdentity: String, CaseIterable, Codable, Identifiable {
    case connection, pulse, orbit
    var id: String { rawValue }
    var title: String {
        switch self { case .connection: return "Nexo"; case .pulse: return "Pulso"; case .orbit: return "Órbita" }
    }
    var subtitle: String {
        switch self { case .connection: return "N geométrico"; case .pulse: return "Sinal contínuo"; case .orbit: return "Máquina + IA" }
    }
    func image(size: CGFloat = 32) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let p = NSBezierPath()
            p.lineWidth = size * 0.11; p.lineCapStyle = .round; p.lineJoinStyle = .round
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * size, y: y * size) }
            switch self {
            case .connection:
                p.move(to: point(0.22,0.78)); p.line(to: point(0.22,0.22)); p.line(to: point(0.78,0.78)); p.line(to: point(0.78,0.22))
            case .pulse:
                p.move(to: point(0.10,0.56)); p.line(to: point(0.29,0.56)); p.line(to: point(0.43,0.20)); p.line(to: point(0.59,0.80)); p.line(to: point(0.72,0.44)); p.line(to: point(0.90,0.44))
            case .orbit:
                p.appendOval(in: NSRect(x: size*0.16,y:size*0.16,width:size*0.68,height:size*0.68))
                p.move(to: point(0.18,0.74)); p.line(to: point(0.82,0.26))
            }
            NSColor.labelColor.setStroke(); p.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

enum StatusInteractionDisplay: String, Codable, CaseIterable, Identifiable {
    case main, any
    var id: String { rawValue }
    var title: String { self == .main ? "Somente monitor principal" : "Qualquer monitor" }

    func allows(point: NSPoint, primaryFrame: NSRect?) -> Bool {
        if self == .any { return true }
        guard let primaryFrame, point.x.isFinite, point.y.isFinite else { return false }
        return primaryFrame.contains(point)
    }
}

struct BarAppearance: Codable, Equatable {
    var iconStyle: IndicatorIconStyle = .outline
    var identity: NexoIdentity = .connection
    var quotaLayout: QuotaBarLayout = .inline
    var detailedTime: Bool = false
    var notifyResets: Bool = true
    /// Time until the quota renews, independent of the indicator names.
    var showQuotaReset: Bool = true
    var interactionDisplay: StatusInteractionDisplay = .main
}

extension BarAppearance {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        iconStyle = try values.decodeIfPresent(IndicatorIconStyle.self, forKey: .iconStyle) ?? .outline
        identity = try values.decodeIfPresent(NexoIdentity.self, forKey: .identity) ?? .connection
        quotaLayout = try values.decodeIfPresent(QuotaBarLayout.self, forKey: .quotaLayout) ?? .inline
        detailedTime = try values.decodeIfPresent(Bool.self, forKey: .detailedTime) ?? false
        notifyResets = try values.decodeIfPresent(Bool.self, forKey: .notifyResets) ?? true
        interactionDisplay = try values.decodeIfPresent(StatusInteractionDisplay.self, forKey: .interactionDisplay) ?? .main
        showQuotaReset = try values.decodeIfPresent(Bool.self, forKey: .showQuotaReset) ?? true
    }
}

struct IdentityMark: View {
    var identity: NexoIdentity
    var size: CGFloat = 32
    var body: some View { Image(nsImage: identity.image(size: size)).renderingMode(.template).resizable().frame(width: size, height: size) }
}

enum MemoryDisplay: String, Codable, CaseIterable, Identifiable {
    case usedTotal, percentage
    var id: String { rawValue }
    var title: String { self == .usedTotal ? "GB (em uso/total)" : "Percentual" }
}

extension IndicatorReading {
    func displayValue(memory: MemoryDisplay) -> String {
        guard id == .memory, memory == .usedTotal, let usedBytes, let totalBytes,
              let text = BarText.memory(used: usedBytes, total: totalBytes) else { return value }
        return text
    }

    /// SSD read/write pair; nil until two counter samples exist.
    var ratesText: String? {
        guard id == .ssd, let readRate, let writeRate else { return nil }
        return BarText.rates(read: readRate, write: writeRate)
    }

    /// SSD free space ("512 GB livre"); usedBytes/totalBytes describe the startup volume.
    var freeSpaceText: String? {
        guard id == .ssd, let usedBytes, let totalBytes, totalBytes >= usedBytes,
              let size = BarText.size(totalBytes - usedBytes) else { return nil }
        return "\(size) livre"
    }

    /// Bar text for a hardware indicator: SSD active time · rates (optional) · temperature · free space (optional).
    func barValue(item: IndicatorConfiguration, temperature: IndicatorReading?) -> String {
        var parts = [displayValue(memory: item.memoryDisplay)]
        if item.showRates, let ratesText { parts.append(ratesText) }
        if let temperature { parts.append(temperature.value.replacingOccurrences(of: " ", with: "")) }
        if item.showFreeSpace, let freeSpaceText { parts.append(freeSpaceText) }
        return parts.joined(separator: BarText.separator)
    }
}
