import AppKit
import XCTest
@testable import NexoBar

final class NativeStatusImageTests: XCTestCase {
    func testDetachedCanvasPreservesReservedWidthAppearanceAndHighlight() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let strip = StatusStrip(frame: NSRect(x: 0, y: 0, width: 0, height: 28))
            let contentWidth = strip.update(items: [.init(id: .cpu, enabled: true, label: "CPU")], readings: [:], appearance: BarAppearance())
            let originalFrame = strip.frame
            let light = NSAppearance(named: .aqua)!
            let dark = NSAppearance(named: .darkAqua)!
            let size = NSSize(width: contentWidth + 60, height: 28)
            let normal = try XCTUnwrap(strip.renderStatusImage(width: size.width, height: size.height, appearance: light, highlighted: false))
            let selected = try XCTUnwrap(strip.renderStatusImage(width: size.width, height: size.height, appearance: light, highlighted: true))
            let restored = try XCTUnwrap(strip.renderStatusImage(width: size.width, height: size.height, appearance: light, highlighted: false))
            let darkImage = try XCTUnwrap(strip.renderStatusImage(width: size.width, height: size.height, appearance: dark, highlighted: false))
            XCTAssertEqual(normal.size, size)
            XCTAssertFalse(normal.isTemplate)
            XCTAssertEqual(strip.frame, originalFrame)
            XCTAssertNil(strip.superview)
            XCTAssertNil(strip.window)
            XCTAssertEqual(Self.pixels(normal), Self.pixels(restored))
            XCTAssertNotEqual(Self.pixels(normal), Self.pixels(selected))
            XCTAssertNotEqual(Self.pixels(normal), Self.pixels(darkImage))
            XCTAssertFalse(Self.pixels(normal).allSatisfy { $0 == 0 })
        }
    }

    func testDetachedImageRoutesEveryIndicatorToNativeButtonIncludingScaledImage() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            defer { NSStatusBar.system.removeStatusItem(status) }
            let button = try XCTUnwrap(status.button)
            let strip = StatusStrip(frame: NSRect(x: 0, y: 0, width: 0, height: 28))
            let ids = IndicatorID.allCases.filter { !$0.isNested }
            let items = ids.map { IndicatorConfiguration(id: $0, enabled: true, label: $0.name) }
            let width = strip.update(items: items, readings: [:], appearance: BarAppearance())
            button.image = try XCTUnwrap(strip.renderStatusImage(width: width + 60, height: 28, appearance: NSAppearance(named: .aqua)!, highlighted: false))
            status.length = (width + 60) / 2
            button.imageScaling = .scaleProportionallyDown
            button.layoutSubtreeIfNeeded()
            var selected: [IndicatorID] = []
            var contexts: [IndicatorID?] = []
            var anchors: [NSView] = []
            strip.onSelect = { selected.append($0); anchors.append($1) }
            strip.onContext = { id, view, _ in contexts.append(id); anchors.append(view) }
            for cell in strip.subviews.sorted(by: { $0.frame.minX < $1.frame.minX }) {
                XCTAssertTrue(strip.handleStatusItemEvent(Self.event(.leftMouseUp, canvasPoint: NSPoint(x: cell.frame.midX, y: cell.frame.midY), button: button), from: button))
                XCTAssertTrue(strip.handleStatusItemEvent(Self.event(.rightMouseUp, canvasPoint: NSPoint(x: cell.frame.midX, y: cell.frame.midY), button: button), from: button))
            }
            XCTAssertEqual(selected, ids)
            XCTAssertEqual(contexts.compactMap { $0 }, ids)
            XCTAssertTrue(anchors.allSatisfy { $0 === button })
            XCTAssertFalse(strip.handleStatusItemEvent(Self.event(.leftMouseUp, canvasPoint: NSPoint(x: width + 30, y: 14), button: button), from: button))
            XCTAssertNil(strip.superview)
        }
    }

    func testDetachedOverflowEmptyAndControlClickUseNativeAnchor() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let status = NSStatusBar.system.statusItem(withLength: 160)
            defer { NSStatusBar.system.removeStatusItem(status) }
            let button = try XCTUnwrap(status.button)
            let strip = StatusStrip(frame: NSRect(x: 0, y: 0, width: 0, height: 28))
            let items = [IndicatorID.cpu, .memory, .gpu, .claude].map { IndicatorConfiguration(id: $0, enabled: true, label: $0.name) }
            var overflowAnchor: NSView?
            var contextAnchors: [NSView] = []
            var contextIDs: [IndicatorID?] = []
            var emptyCount = 0
            strip.onOverflow = { overflowAnchor = $0 }
            strip.onContext = { id, view, _ in contextIDs.append(id); contextAnchors.append(view) }
            strip.onEmpty = { emptyCount += 1 }
            strip.update(items: items, readings: [:], appearance: BarAppearance(), maxWidth: 160)
            button.image = try XCTUnwrap(strip.renderStatusImage(width: 160, height: 28, appearance: NSAppearance(named: .aqua)!, highlighted: false))
            let overflow = try XCTUnwrap(strip.subviews.first { $0.identifier?.rawValue == "overflow" })
            let point = NSPoint(x: overflow.frame.midX, y: overflow.frame.midY)
            XCTAssertTrue(strip.handleStatusItemEvent(Self.event(.leftMouseUp, canvasPoint: point, button: button), from: button))
            XCTAssertTrue(strip.handleStatusItemEvent(Self.event(.leftMouseUp, canvasPoint: point, button: button, modifiers: .control), from: button))
            XCTAssertTrue(overflowAnchor === button)
            XCTAssertNil(contextIDs.last!)
            strip.update(items: [], readings: [:], appearance: BarAppearance(), maxWidth: 160)
            button.image = try XCTUnwrap(strip.renderStatusImage(width: 160, height: 28, appearance: NSAppearance(named: .aqua)!, highlighted: false))
            let empty = try XCTUnwrap(strip.subviews.first)
            let emptyPoint = NSPoint(x: empty.frame.midX, y: empty.frame.midY)
            XCTAssertTrue(strip.handleStatusItemEvent(Self.event(.leftMouseUp, canvasPoint: emptyPoint, button: button), from: button))
            XCTAssertTrue(strip.handleStatusItemEvent(Self.event(.rightMouseDown, canvasPoint: emptyPoint, button: button), from: button))
            XCTAssertEqual(emptyCount, 1)
            XCTAssertTrue(contextAnchors.allSatisfy { $0 === button })
        }
    }

    @MainActor private static func event(_ type: NSEvent.EventType, canvasPoint: NSPoint, button: NSStatusBarButton,
                                         modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        let proposedRect = button.cell?.imageRect(forBounds: button.bounds) ?? .zero
        let rect = proposedRect.isEmpty ? button.bounds : proposedRect
        let imageSize = button.image!.size
        let x = rect.minX + canvasPoint.x / imageSize.width * rect.width
        let y = rect.minY + (button.isFlipped ? canvasPoint.y / imageSize.height : 1 - canvasPoint.y / imageSize.height) * rect.height
        return NSEvent.mouseEvent(with: type, location: button.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: modifiers,
                                 timestamp: 0, windowNumber: button.window!.windowNumber, context: nil,
                                 eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private static func pixels(_ image: NSImage) -> Data {
        let bitmap = image.representations.compactMap { $0 as? NSBitmapImageRep }.first!
        return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
}
