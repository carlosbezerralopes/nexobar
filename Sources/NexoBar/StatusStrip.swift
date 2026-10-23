import AppKit

enum QuotaBarLayout: String, Codable, CaseIterable, Identifiable {
    case stacked, inline, primary
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stacked: return "Duas linhas"
        case .inline: return "Na mesma linha"
        case .primary: return "Somente principal"
        }
    }
}

/// Account windows only: model-specific windows must never become account limits.
struct QuotaBarPresentation {
    let primary: QuotaWindow?
    let secondary: QuotaWindow?
    var availableWindows: [QuotaWindow] { [primary, secondary].compactMap { $0 } }

    init(windows: [QuotaWindow]) {
        let accountPrimary = windows.first { ["primary", "five_hour", "session"].contains($0.id ?? "") }
            ?? windows.first { $0.id == nil && ["principal", "sessão", "session"].contains($0.name.lowercased()) }
        let accountSecondary = windows.first { ["secondary", "seven_day", "weekly_all"].contains($0.id ?? "") }
            ?? windows.first { $0.id == nil && ["secundária", "semanal", "weekly"].contains($0.name.lowercased()) }
        if accountPrimary?.id == "primary", accountPrimary?.durationMinutes == 10080, accountSecondary == nil {
            primary = nil
            secondary = accountPrimary
        } else {
            primary = accountPrimary
            secondary = accountSecondary
        }
    }

    static func value(for window: QuotaWindow?) -> String {
        window?.usedPercent.map(IndicatorReading.percent) ?? "—"
    }

    static func remainingTime(reset: Date?, now: Date, detailedTime: Bool = false) -> String {
        guard let reset else { return "—" }
        let seconds = reset.timeIntervalSince(now)
        guard seconds.isFinite, seconds < Double(Int.max) else { return "—" }
        if seconds <= 0 { return "0m" }
        if seconds < 60 { return "<1m" }
        let minutes = Int(seconds / 60)
        if minutes >= 1440 { return "\(minutes / 1440)d" + (detailedTime ? "\((minutes % 1440) / 60)h" : "") }
        if minutes >= 60 { return "\(minutes / 60)h" + (detailedTime ? "\(minutes % 60)m" : "") }
        return "\(minutes)m"
    }
}

@MainActor
final class StatusStrip: NSView {
    var onSelect: ((IndicatorID, NSView) -> Void)?
    var onContext: ((IndicatorID?, NSView, NSEvent) -> Void)?
    var onEmpty: (() -> Void)?
    var onOverflow: ((NSView) -> Void)?
    private(set) var hiddenIDs: [IndicatorID] = []
    private var cells: [IndicatorID: StatusIndicatorButton] = [:]
    private var emptyCell: StatusIndicatorButton?
    private var overflowCell: StatusIndicatorButton?
    private var statusItemHighlighted = false
    private(set) var usesTemplateStatusImage = false
    override var isFlipped: Bool { true }

    // NSStatusBarButton owns mouse tracking; nested buttons must not start a second tracking loop.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if enclosingStatusButton != nil { return nil }
        return super.hitTest(point)
    }

    @discardableResult
    func handleStatusItemEvent(_ event: NSEvent, from button: NSStatusBarButton) -> Bool {
        guard [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(event.type),
              event.windowNumber == button.window?.windowNumber else { return false }
        let hosted = enclosingStatusButton != nil
        let point: NSPoint
        if hosted {
            guard button === enclosingStatusButton else { return false }
            point = convert(event.locationInWindow, from: nil)
        } else {
            guard superview == nil, let image = button.image else { return false }
            let location = button.convert(event.locationInWindow, from: nil)
            let proposedRect = button.cell?.imageRect(forBounds: button.bounds) ?? .zero
            let imageRect = proposedRect.isEmpty ? button.bounds : proposedRect
            guard button.bounds.contains(location), imageRect.contains(location),
                  image.size.width > 0, image.size.height > 0 else { return false }
            let y = (location.y - imageRect.minY) / imageRect.height
            point = NSPoint(x: (location.x - imageRect.minX) / imageRect.width * image.size.width,
                            y: (button.isFlipped ? y : 1 - y) * image.size.height)
        }
        guard point.x.isFinite, point.y.isFinite, bounds.contains(point),
              let cell = subviews.compactMap({ $0 as? StatusIndicatorButton })
                .first(where: { !$0.isHidden && $0.frame.contains(point) }) else { return false }
        let context = [.rightMouseDown, .rightMouseUp].contains(event.type) || event.modifierFlags.contains(.control)
        if !hosted {
            let id = cell.identifier.flatMap { IndicatorID(rawValue: $0.rawValue) }
            if context { onContext?(id, button, event) }
            else if cell === overflowCell { onOverflow?(button) }
            else if cell === emptyCell { onEmpty?() }
            else if let id { onSelect?(id, button) }
            else { return false }
        } else if context {
            cell.onContext?(event)
        } else {
            cell.onActivate?()
        }
        return true
    }

    func renderStatusImage(width: CGFloat, height: CGFloat, appearance: NSAppearance, highlighted: Bool) -> NSImage? {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let previousFrame = frame
        let previousAppearance = self.appearance
        let previousHighlight = statusItemHighlighted
        defer {
            frame = previousFrame
            self.appearance = previousAppearance
            setStatusItemHighlighted(previousHighlight)
        }
        frame.size = NSSize(width: width, height: height)
        self.appearance = appearance
        setStatusItemHighlighted(highlighted)
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        appearance.performAsCurrentDrawingAppearance { cacheDisplay(in: bounds, to: bitmap) }
        bitmap.size = NSSize(width: width, height: height)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        image.isTemplate = usesTemplateStatusImage
        return image
    }

    func setStatusItemHighlighted(_ highlighted: Bool) {
        guard statusItemHighlighted != highlighted else { return }
        statusItemHighlighted = highlighted
        for cell in subviews.compactMap({ $0 as? StatusIndicatorButton }) {
            cell.statusItemHighlighted = highlighted
        }
    }

    private var enclosingStatusButton: NSStatusBarButton? {
        var ancestor = superview
        while let view = ancestor {
            if let button = view as? NSStatusBarButton { return button }
            ancestor = view.superview
        }
        return nil
    }

    @discardableResult
    func update(items: [IndicatorConfiguration], readings: [IndicatorID: IndicatorReading],
                appearance: BarAppearance, layout: QuotaBarLayout = .inline, now: Date = Date(), detailedTime: Bool = false,
                maxWidth: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        let budget = maxWidth.isNaN ? CGFloat(80) : max(0, maxWidth)
        usesTemplateStatusImage = appearance.iconStyle.usesTemplateStatusImage
        var seen = Set<IndicatorID>()
        var ordered: [(IndicatorID, StatusIndicatorButton)] = []
        var x: CGFloat = 0
        let height = max(22, bounds.height)
        for item in items where item.enabled && !item.id.isNested && seen.insert(item.id).inserted {
            let cell: StatusIndicatorButton
            if let existing = cells[item.id] { cell = existing }
            else {
                cell = StatusIndicatorButton()
                cells[item.id] = cell
                cell.identifier = NSUserInterfaceItemIdentifier(item.id.rawValue)
                cell.onActivate = { [weak self, weak cell] in
                    guard let cell else { return }
                    self?.onSelect?(item.id, cell)
                }
                cell.onContext = { [weak self, weak cell] event in
                    guard let cell else { return }
                    self?.onContext?(item.id, cell, event)
                }
            }
            let reading = readings[item.id] ?? .unavailable(item.id, "Dados indisponíveis")
            let childReading: IndicatorReading?
            if let child = item.id.temperatureChild, items.first(where: { $0.id == child })?.enabled == true {
                childReading = readings[child] ?? .unavailable(child, "Temperatura indisponível")
            } else { childReading = nil }
            cell.configure(item: item, reading: reading, childReading: childReading, appearance: appearance, layout: layout, now: now, detailedTime: detailedTime)
            ordered.append((item.id, cell))
        }
        let totalWidth = ordered.reduce(CGFloat.zero) { $0 + $1.1.contentWidth }
        var visibleCount = ordered.count
        if totalWidth > budget {
            let overflow = overflowCell ?? StatusIndicatorButton()
            overflowCell = overflow
            overflow.configureOverflow(count: ordered.count, template: usesTemplateStatusImage)
            let available = max(0, budget - max(45, overflow.contentWidth))
            var prefixWidth: CGFloat = 0
            visibleCount = 0
            for (_, cell) in ordered {
                guard prefixWidth + cell.contentWidth <= available else { break }
                prefixWidth += cell.contentWidth
                visibleCount += 1
            }
        }
        let visible = Set(ordered.prefix(visibleCount).map { $0.0 })
        hiddenIDs = ordered.dropFirst(visibleCount).map { $0.0 }
        for (_, cell) in ordered.prefix(visibleCount) {
            let cellFrame = NSRect(x: x, y: 0, width: cell.contentWidth, height: height)
            if cell.frame != cellFrame { cell.frame = cellFrame }
            cell.statusItemHighlighted = statusItemHighlighted
            if cell.superview == nil { addSubview(cell) }
            x += cell.contentWidth
        }
        for (id, cell) in cells where !visible.contains(id) { cell.removeFromSuperview() }
        if ordered.isEmpty {
            let cell = emptyCell ?? StatusIndicatorButton()
            emptyCell = cell
            cell.identifier = NSUserInterfaceItemIdentifier("nexobar")
            cell.onActivate = { [weak self] in self?.onEmpty?() }
            cell.onContext = { [weak self, weak cell] event in
                guard let cell else { return }
                self?.onContext?(nil, cell, event)
            }
            cell.configureEmpty(identity: appearance.identity, template: usesTemplateStatusImage)
            if cell.contentWidth > budget { cell.configureEmpty(identity: appearance.identity, compact: true, template: usesTemplateStatusImage) }
            let cellFrame = NSRect(x: 0, y: 0, width: min(budget, cell.contentWidth), height: height)
            if cell.frame != cellFrame { cell.frame = cellFrame }
            cell.statusItemHighlighted = statusItemHighlighted
            if cell.superview == nil { addSubview(cell) }
            x = cell.frame.width
        } else { emptyCell?.removeFromSuperview() }
        if !hiddenIDs.isEmpty, let cell = overflowCell {
            cell.identifier = NSUserInterfaceItemIdentifier("overflow")
            cell.configureOverflow(count: hiddenIDs.count, template: usesTemplateStatusImage)
            cell.onActivate = { [weak self, weak cell] in
                guard let cell else { return }
                self?.onOverflow?(cell)
            }
            cell.onContext = { [weak self, weak cell] event in
                guard let cell else { return }
                self?.onContext?(nil, cell, event)
            }
            let cellFrame = NSRect(x: x, y: 0, width: min(max(45, cell.contentWidth), budget - x), height: height)
            if cell.frame != cellFrame { cell.frame = cellFrame }
            cell.statusItemHighlighted = statusItemHighlighted
            if cell.superview == nil { addSubview(cell) }
            x += cell.frame.width
        } else { overflowCell?.removeFromSuperview() }
        let size = NSSize(width: x, height: height)
        if frame.size != size { frame.size = size }
        return x
    }
}

@MainActor
private final class StatusIndicatorButton: NSButton {
    var onActivate: (() -> Void)?
    var onContext: ((NSEvent) -> Void)?
    private var mark: NSImage?
    private var activityColor: NSColor?
    private var rows: [NSAttributedString] = []
    private var stacked = false
    private var templateRendering = false
    var statusItemHighlighted = false {
        didSet { if oldValue != statusItemHighlighted { needsDisplay = true } }
    }
    private(set) var contentWidth: CGFloat = 0
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(activate)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func activate() { onActivate?() }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onContext?(event) }
        else { super.mouseDown(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) { onContext?(event) }

    func configureEmpty(identity: NexoIdentity, compact: Bool = false, template: Bool = false) {
        templateRendering = template
        activityColor = nil
        mark = compact ? nil : identity.image(size: 16)
        stacked = false
        rows = [text("NexoBar", percent: nil, stale: false, size: 11)]
        toolTip = "NexoBar · Personalizar indicadores"
        setAccessibilityLabel(toolTip)
        setAccessibilityValue("Todos os indicadores ocultos")
        measure()
    }

    func configureOverflow(count: Int, template: Bool = false) {
        templateRendering = template
        activityColor = nil
        mark = nil
        stacked = false
        rows = [text("+\(count)", percent: nil, stale: false, size: 11)]
        toolTip = "Mais \(count) indicadores · abrir detalhes"
        setAccessibilityLabel("Mais indicadores")
        setAccessibilityValue("\(count) indicadores fora da barra")
        measure()
    }

    func configure(item: IndicatorConfiguration, reading: IndicatorReading, childReading: IndicatorReading?,
                   appearance: BarAppearance, layout: QuotaBarLayout, now: Date, detailedTime: Bool) {
        templateRendering = appearance.iconStyle.usesTemplateStatusImage
        mark = appearance.iconStyle.image(for: item.id)
        switch reading.activity?.state {
        case "working": activityColor = .systemBlue
        case "waiting": activityColor = .systemOrange
        default: activityColor = nil
        }
        let quota = QuotaBarPresentation(windows: reading.windows)
        let hasAccountWindows = quota.primary != nil || quota.secondary != nil
            || [.claude, .codex].contains(item.id)
        let displayedWindows = layout == .primary ? Array(quota.availableWindows.prefix(1)) : quota.availableWindows
        stacked = item.id.isAI && displayedWindows.count > 1 && layout == .stacked
        let prefix = item.showLabel ? item.label + " " : ""
        let stale = reading.isStale
        if item.id.isAI && hasAccountWindows {
            if displayedWindows.isEmpty {
                rows = [text(prefix + "—", percent: nil, stale: stale, size: 11)]
            } else {
                let parts = displayedWindows.enumerated().map { index, window in
                    let remaining = window.resetsAt.map { "·" + QuotaBarPresentation.remainingTime(reset: $0, now: now, detailedTime: detailedTime) } ?? ""
                    return text((index == 0 ? prefix : "") + QuotaBarPresentation.value(for: window) + remaining,
                                percent: window.usedPercent, stale: stale, size: stacked ? 9 : 11)
                }
                if stacked { rows = parts }
                else {
                    let joined = NSMutableAttributedString()
                    for (index, part) in parts.enumerated() {
                        if index > 0 { joined.append(text(" | ", percent: nil, stale: stale, size: 11)) }
                        joined.append(part)
                    }
                    rows = [joined]
                }
            }
        } else {
            let value = reading.displayValue(memory: item.memoryDisplay)
            let percent = Double(reading.value.replacingOccurrences(of: "%", with: ""))
            rows = [text(prefix + value, percent: percent, stale: stale, size: 11)]
        }
        if let childReading {
            let grouped = NSMutableAttributedString(attributedString: rows[0])
            grouped.append(text(" · " + childReading.value.replacingOccurrences(of: " ", with: ""), percent: nil,
                                stale: childReading.isStale, size: 11))
            rows[0] = grouped
        }
        func quotaDescription(_ window: QuotaWindow?, name: String) -> String {
            "\(name): \(QuotaBarPresentation.value(for: window)) · renova em \(QuotaBarPresentation.remainingTime(reset: window?.resetsAt, now: now, detailedTime: true))"
        }
        let secondaryName = quota.secondary?.durationMinutes == 10080 || ["seven_day", "weekly_all"].contains(quota.secondary?.id ?? "") ? "Semanal" : "Secundária"
        let accountDescriptions = displayedWindows.map { window in
            quotaDescription(window, name: window == quota.secondary ? secondaryName : window.name)
        }
        let values = hasAccountWindows ? accountDescriptions : reading.windows.map { quotaDescription($0, name: $0.name) }
        let activity = reading.activity.map { "Atividade: \($0.summary)" }
        toolTip = ([item.label, reading.detail] + values + (stale ? ["Leitura antiga"] : []) + (activity.map { [$0] } ?? [])).filter { !$0.isEmpty }.joined(separator: "\n")
        if let childReading {
            toolTip = (toolTip ?? "") + "\n\(childReading.id.name): \(childReading.value) · \(childReading.detail)" + (childReading.isStale ? " · leitura antiga" : "")
        }
        setAccessibilityLabel(item.label)
        let accessibleValues: String
        if item.id.isAI && hasAccountWindows && layout != .primary {
            accessibleValues = accountDescriptions.joined(separator: ", ")
        } else { accessibleValues = rows.map(\.string).joined(separator: ", ") }
        setAccessibilityValue(accessibleValues + (stale ? ", leitura antiga" : "") + (activity.map { ", " + $0 } ?? ""))
        measure()
    }

    private func text(_ string: String, percent: Double?, stale: Bool, size: CGFloat) -> NSAttributedString {
        let color: NSColor
        if templateRendering { color = stale ? NSColor.black.withAlphaComponent(0.55) : .black }
        else if stale { color = .secondaryLabelColor }
        else if let percent, percent.isFinite, percent >= 95 { color = .systemRed }
        else if let percent, percent.isFinite, percent >= 80 { color = .systemOrange }
        else { color = .labelColor }
        return NSAttributedString(string: string, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium), .foregroundColor: color])
    }

    private func measure() {
        contentWidth = ceil(8 + (mark == nil ? 0 : 21) + (rows.map { $0.size().width }.max() ?? 0) + 8)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let selected = !templateRendering && (statusItemHighlighted || isHighlighted || (superview?.superview as? NSStatusBarButton)?.isHighlighted == true)
        // AppKit selects and tints a template strip, including its text, as one native status image.
        if !templateRendering && (statusItemHighlighted || isHighlighted) {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        if let mark {
            let foreground: NSColor = templateRendering ? .black : (selected ? .selectedMenuItemTextColor : .labelColor)
            // Template images drawn directly into a custom view do not receive NSButton's tint.
            let renderedMark: NSImage
            if templateRendering || mark.isTemplate {
                renderedMark = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                    mark.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                    foreground.setFill()
                    rect.fill(using: .sourceIn)
                    return true
                }
            } else { renderedMark = mark }
            renderedMark.draw(in: NSRect(x: 8, y: (bounds.height - 16) / 2, width: 16, height: 16),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            if let activityColor {
                (templateRendering ? NSColor.black : activityColor).setFill()
                NSBezierPath(ovalIn: NSRect(x: 20, y: (bounds.height - 16) / 2, width: 4, height: 4)).fill()
            }
        }
        let x: CGFloat = mark == nil ? 8 : 29
        let total = rows.reduce(CGFloat.zero) { $0 + $1.size().height }
        var y = (bounds.height - total) / 2
        for row in rows {
            if selected {
                let highlighted = NSMutableAttributedString(attributedString: row)
                highlighted.addAttribute(.foregroundColor, value: NSColor.selectedMenuItemTextColor,
                                         range: NSRange(location: 0, length: highlighted.length))
                highlighted.draw(at: NSPoint(x: x, y: y))
            } else { row.draw(at: NSPoint(x: x, y: y)) }
            y += row.size().height
        }
    }
}
