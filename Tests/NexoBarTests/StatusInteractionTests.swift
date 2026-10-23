import AppKit
import XCTest
@testable import NexoBar

final class StatusInteractionTests: XCTestCase {
    func testNativeStatusButtonRoutesEveryIndicatorByWindowCoordinate() async {
        await MainActor.run {
            _ = NSApplication.shared
            let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            defer { NSStatusBar.system.removeStatusItem(status) }
            let button = status.button!
            let strip = StatusStrip(frame: NSRect(x: 0, y: 0, width: 0, height: NSStatusBar.system.thickness))
            button.addSubview(strip)
            let ids = IndicatorID.allCases.filter { !$0.isNested }
            var items = ids.map { IndicatorConfiguration(id: $0, enabled: true, label: $0.name) }
            status.length = strip.update(items: items, readings: [:], appearance: BarAppearance())
            var selected: [IndicatorID] = []
            var anchors: [NSView] = []
            strip.onSelect = { selected.append($0); anchors.append($1) }
            @MainActor func clickAll(expected: [IndicatorID]) {
                selected = []; anchors = []
                let visible = strip.subviews.sorted { $0.frame.minX < $1.frame.minX }
                for (index, cell) in visible.enumerated() {
                    let point = NSPoint(x: cell.frame.midX, y: cell.frame.midY)
                    XCTAssertNil(strip.hitTest(strip.convert(point, to: button)))
                    let event = Self.event(.leftMouseUp, at: point, in: strip)
                    XCTAssertTrue(strip.handleStatusItemEvent(event, from: button))
                    XCTAssertEqual(selected.last, expected[index])
                    XCTAssertTrue(anchors.last === cell)
                }
                XCTAssertEqual(selected, expected)
            }
            clickAll(expected: ids)
            items.reverse()
            status.length = strip.update(items: items, readings: [.cpu: .init(id: .cpu, value: "100%", detail: "", sampledAt: Date())], appearance: BarAppearance())
            clickAll(expected: Array(ids.reversed()))
            // A point outside the strip and unrelated event types never fall back to the last ID.
            let before = selected
            XCTAssertFalse(strip.handleStatusItemEvent(Self.event(.leftMouseUp, at: NSPoint(x: -1, y: 10), in: strip), from: button))
            XCTAssertFalse(strip.handleStatusItemEvent(Self.event(.mouseMoved, at: NSPoint(x: 1, y: 10), in: strip), from: button))
            XCTAssertEqual(selected, before)
        }
    }

    func testNativeContextOverflowEmptyAndDownEventsUseTheirOwnAnchors() async {
        await MainActor.run {
            _ = NSApplication.shared
            let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            defer { NSStatusBar.system.removeStatusItem(status) }
            let button = status.button!
            let strip = StatusStrip(frame: NSRect(x: 0, y: 0, width: 0, height: NSStatusBar.system.thickness))
            button.addSubview(strip)
            let items = [IndicatorID.cpu, .memory, .gpu, .claude].map { IndicatorConfiguration(id: $0, enabled: true, label: $0.name) }
            status.length = strip.update(items: items, readings: [:], appearance: BarAppearance())
            let initial = strip.subviews.sorted { $0.frame.minX < $1.frame.minX }
            let budget = initial.prefix(2).reduce(CGFloat.zero) { $0 + $1.frame.width } + 45
            status.length = strip.update(items: items, readings: [:], appearance: BarAppearance(), maxWidth: budget)
            XCTAssertEqual(strip.hiddenIDs, [.gpu, .claude])
            var selected: [IndicatorID] = []
            var contexts: [IndicatorID?] = []
            var contextAnchors: [NSView] = []
            var overflow: NSView?
            var emptyCount = 0
            strip.onSelect = { id, _ in selected.append(id) }
            strip.onContext = { id, view, _ in contexts.append(id); contextAnchors.append(view) }
            strip.onOverflow = { overflow = $0 }
            strip.onEmpty = { emptyCount += 1 }
            let cpu = strip.subviews.first { $0.identifier?.rawValue == "cpu" }!
            let overflowCell = strip.subviews.first { $0.identifier?.rawValue == "overflow" }!
            let cpuPoint = NSPoint(x: cpu.frame.midX, y: cpu.frame.midY)
            for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                XCTAssertTrue(strip.handleStatusItemEvent(Self.event(type, at: cpuPoint, in: strip), from: button))
            }
            XCTAssertTrue(strip.handleStatusItemEvent(Self.event(.leftMouseDown, at: cpuPoint, in: strip, modifiers: .control), from: button))
            XCTAssertEqual(contexts.compactMap { $0 }, [.cpu, .cpu, .cpu])
            XCTAssertTrue(contextAnchors.allSatisfy { $0 === cpu })
            XCTAssertTrue(selected.isEmpty)
            XCTAssertTrue(strip.handleStatusItemEvent(Self.event(.leftMouseDown, at: cpuPoint, in: strip), from: button))
            XCTAssertEqual(selected, [.cpu])
            let overflowPoint = NSPoint(x: overflowCell.frame.midX, y: overflowCell.frame.midY)
            XCTAssertTrue(strip.handleStatusItemEvent(Self.event(.leftMouseUp, at: overflowPoint, in: strip), from: button))
            XCTAssertTrue(overflow === overflowCell)
            XCTAssertTrue(strip.handleStatusItemEvent(Self.event(.rightMouseUp, at: overflowPoint, in: strip), from: button))
            XCTAssertNil(contexts.last!)
            XCTAssertTrue(contextAnchors.last === overflowCell)
            status.length = strip.update(items: [], readings: [:], appearance: BarAppearance())
            let empty = strip.subviews[0]
            let emptyPoint = NSPoint(x: empty.frame.midX, y: empty.frame.midY)
            XCTAssertTrue(strip.handleStatusItemEvent(Self.event(.leftMouseUp, at: emptyPoint, in: strip), from: button))
            XCTAssertEqual(emptyCount, 1)
            XCTAssertTrue(strip.handleStatusItemEvent(Self.event(.rightMouseUp, at: emptyPoint, in: strip), from: button))
            XCTAssertNil(contexts.last!)
            XCTAssertEqual(selected, [.cpu])
        }
    }

    func testRenderedTemplateAndTextHaveContrastInLightDarkAndSelectedStates() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let output = ProcessInfo.processInfo.environment["NEXOBAR_QA_OUTPUT_DIRECTORY"].map(URL.init(fileURLWithPath:))
                ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("../../work/nexobar/v4/clicks").standardizedFileURL
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            var metrics: [[String: Any]] = []
            for name: NSAppearance.Name in [.aqua, .darkAqua] {
                for selected in [false, true] {
                    let appearance = NSAppearance(named: name)!
                    let dark = name == .darkAqua
                    let background = dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)
                    let host = InteractionRenderBackground(frame: NSRect(x: 0, y: 0, width: 600, height: 28), color: background)
                    host.appearance = appearance
                    let strip = StatusStrip(frame: host.bounds)
                    host.addSubview(strip)
                    let ids: [IndicatorID] = [.cpu, .memory, .gpu, .claude, .codex]
                    let items = ids.map { IndicatorConfiguration(id: $0, enabled: true, label: $0.name) }
                    let readings = Dictionary(uniqueKeysWithValues: ids.map { ($0, IndicatorReading(id: $0, value: "42%", detail: "Fixture", sampledAt: Date())) })
                    let width = strip.update(items: items, readings: readings, appearance: BarAppearance())
                    host.frame.size.width = width
                    strip.setStatusItemHighlighted(selected)
                    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                    appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
                    let state = (dark ? "dark" : "light") + (selected ? "-selected" : "-normal")
                    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("status-\(state).png"))
                    var backgroundLuminance = 0.0
                    appearance.performAsCurrentDrawingAppearance {
                        backgroundLuminance = Self.luminance(selected ? .selectedContentBackgroundColor : background)
                    }
                    let cpu = strip.subviews.first { $0.identifier?.rawValue == "cpu" }!
                    for (kind, rect) in [("icon", NSRect(x: 8, y: 6, width: 16, height: 16)),
                                         ("text", NSRect(x: 29, y: 3, width: cpu.frame.width - 37, height: 22))] {
                        let ratio = Self.maximumContrast(in: rect, bitmap: bitmap, viewSize: host.bounds.size, background: backgroundLuminance)
                        XCTAssertGreaterThanOrEqual(ratio, kind == "text" ? 4.5 : 3, "\(state) \(kind): \(ratio)")
                        metrics.append(["state": state, "region": kind, "maximumContrast": ratio, "backgroundLuminance": backgroundLuminance])
                    }
                    // Selection survives polling and freshly rebuilt rows.
                    strip.update(items: Array(items.reversed()), readings: readings, appearance: BarAppearance())
                    strip.setStatusItemHighlighted(false)
                }
            }
            try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("status-render-metrics.json"))
        }
    }

    @MainActor private static func event(_ type: NSEvent.EventType, at point: NSPoint, in strip: NSView,
                                         modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: strip.convert(point, to: nil), modifierFlags: modifiers,
                          timestamp: 0, windowNumber: strip.window!.windowNumber, context: nil,
                          eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private static func luminance(_ color: NSColor) -> Double {
        let rgb = color.usingColorSpace(.deviceRGB)!
        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }

    private static func maximumContrast(in rect: NSRect, bitmap: NSBitmapImageRep, viewSize: NSSize, background: Double) -> Double {
        let scaleX = CGFloat(bitmap.pixelsWide) / viewSize.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / viewSize.height
        var maximum = 1.0
        for x in Int(rect.minX * scaleX)..<Int(rect.maxX * scaleX) {
            for y in Int(rect.minY * scaleY)..<Int(rect.maxY * scaleY) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                let value = luminance(color)
                maximum = max(maximum, (max(value, background) + 0.05) / (min(value, background) + 0.05))
            }
        }
        return maximum
    }
}

@MainActor private final class InteractionRenderBackground: NSView {
    let color: NSColor
    override var isFlipped: Bool { true }
    init(frame: NSRect, color: NSColor) { self.color = color; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
}
