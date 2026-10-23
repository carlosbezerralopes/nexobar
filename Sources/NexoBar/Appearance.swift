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
        case .cpuTemperature, .gpuTemperature: return ["thermometer.medium", "thermometer"]
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
            switch id { case .cpu: title = "C"; case .memory: title = "M"; case .gpu: title = "G"; case .cpuTemperature: title = "C°"; case .gpuTemperature: title = "G°"; default: title = "?" }
            let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.labelColor]
                let size = (title as NSString).size(withAttributes: attrs)
                (title as NSString).draw(at: NSPoint(x: (18-size.width)/2, y: (16-size.height)/2), withAttributes: attrs)
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
        case .cpuTemperature, .gpuTemperature: symbol = self == .solid ? "thermometer.high" : "thermometer.medium"
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
    var title: String { self == .usedTotal ? "Em uso / total" : "Percentual" }
}

extension IndicatorReading {
    func displayValue(memory: MemoryDisplay) -> String {
        guard id == .memory, memory == .usedTotal, let usedBytes, let totalBytes,
              usedBytes.isFinite, totalBytes.isFinite, usedBytes >= 0, totalBytes > 0 else { return value }
        return String(format: "%.0f/%.0f GiB", usedBytes / 1_073_741_824, totalBytes / 1_073_741_824)
    }
}
