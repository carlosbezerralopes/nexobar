import AppKit
import SwiftUI

enum ProviderMarks {
    static func image(for id: IndicatorID) -> NSImage? {
        let loops: [[CGPoint]]
        switch id {
        case .claude: loops = ProviderOutlines.claude
        case .codex: loops = ProviderOutlines.openai
        case .kiro: loops = ProviderOutlines.kiro
        case .cursor: loops = ProviderOutlines.cursor
        case .grok: loops = ProviderOutlines.grok
        case .copilot: loops = ProviderOutlines.copilot
        case .opencode: loops = ProviderOutlines.opencode
        case .antigravity: loops = ProviderOutlines.antigravity
        case .glm: loops = ProviderOutlines.glm
        default: return NSImage(systemSymbolName: id.symbol, accessibilityDescription: id.name)
        }
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            let path = NSBezierPath()
            path.windingRule = .evenOdd
            for loop in loops {
                guard let first = loop.first else { continue }
                path.move(to: NSPoint(x: first.x * 16, y: first.y * 16))
                for point in loop.dropFirst() { path.line(to: NSPoint(x: point.x * 16, y: point.y * 16)) }
                path.close()
            }
            NSColor.labelColor.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct IndicatorGlyph: View {
    let id: IndicatorID
    var style: IndicatorIconStyle = .outline
    var body: some View {
        if let image = style.image(for: id) {
            Image(nsImage: image).renderingMode(.template).resizable().scaledToFit().frame(width: 16, height: 16).accessibilityLabel(id.name)
        }
    }
}
