import AppKit
import XCTest
@testable import NexoBar

final class NativeSymbolStyleTests: XCTestCase {
    func testAllSavedStylesRoundTripWithoutChangingLegacySelection() throws {
        for style in IndicatorIconStyle.allCases {
            let decoded = try JSONDecoder().decode(BarAppearance.self, from: Data("{\"iconStyle\":\"\(style.rawValue)\"}".utf8))
            XCTAssertEqual(decoded.iconStyle, style)
            XCTAssertEqual(try JSONDecoder().decode(BarAppearance.self, from: JSONEncoder().encode(decoded)), decoded)
        }
        XCTAssertEqual(try JSONDecoder().decode(BarAppearance.self, from: Data(#"{"iconStyle":"letters"}"#.utf8)).iconStyle, .letters)
        XCTAssertEqual(BarAppearance().iconStyle, .outline)
    }

    func testNativeFamiliesUseAvailableDistinctSystemSymbols() async throws {
        try await MainActor.run {
            let sensors: [IndicatorID] = [.cpu, .memory, .gpu, .cpuTemperature, .gpuTemperature]
            for style in IndicatorIconStyle.nativeStyles {
                for id in sensors {
                    let names = style.symbolCandidates(for: id)
                    XCTAssertNotNil(NSImage(systemSymbolName: try XCTUnwrap(names.first), accessibilityDescription: nil), "\(style) \(id)")
                    XCTAssertTrue(try XCTUnwrap(style.image(for: id)).isTemplate)
                    XCTAssertTrue(names.contains { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil })
                }
            }
            for id in [IndicatorID.cpu, .memory, .gpu] {
                XCTAssertNotEqual(IndicatorIconStyle.system.symbolCandidates(for: id).first,
                                  IndicatorIconStyle.instruments.symbolCandidates(for: id).first)
            }
        }
    }

    func testTemplateStripIsAnAppearanceIndependentMaskWithoutBakedSelection() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            for style in IndicatorIconStyle.nativeStyles {
                let strip = StatusStrip(frame: NSRect(x: 0, y: 0, width: 0, height: 24))
                let width = strip.update(items: Self.items + [.init(id: .claude, enabled: true, label: "Claude")],
                                         readings: Self.readings, appearance: BarAppearance(iconStyle: style))
                let light = try XCTUnwrap(strip.renderStatusImage(width: width + 40, height: 24, appearance: NSAppearance(named: .aqua)!, highlighted: false))
                let dark = try XCTUnwrap(strip.renderStatusImage(width: width + 40, height: 24, appearance: NSAppearance(named: .darkAqua)!, highlighted: false))
                let selected = try XCTUnwrap(strip.renderStatusImage(width: width + 40, height: 24, appearance: NSAppearance(named: .aqua)!, highlighted: true))
                XCTAssertTrue(light.isTemplate)
                XCTAssertTrue(dark.isTemplate)
                XCTAssertTrue(selected.isTemplate)
                XCTAssertEqual(Self.pixels(light), Self.pixels(dark))
                XCTAssertEqual(Self.pixels(light), Self.pixels(selected))
                let bitmap = try XCTUnwrap(light.representations.first as? NSBitmapImageRep)
                var ink = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        if color.alphaComponent > 0.05 {
                            ink += 1
                            XCTAssertLessThanOrEqual(max(color.redComponent, color.greenComponent, color.blueComponent), 0.02)
                        }
                        if CGFloat(x) / CGFloat(bitmap.pixelsWide) * light.size.width > width + 2 {
                            XCTAssertEqual(color.alphaComponent, 0)
                        }
                    }
                }
                XCTAssertGreaterThan(ink, 30)
                XCTAssertNil(strip.superview)
                XCTAssertNil(strip.window)
            }
        }
    }

    func testTemplateModeSurvivesEmptyOverflowAndSwitchBackToLegacy() async throws {
        try await MainActor.run {
            let strip = StatusStrip(frame: NSRect(x: 0, y: 0, width: 0, height: 24))
            for items in [Self.items, []] {
                strip.update(items: items, readings: Self.readings, appearance: BarAppearance(iconStyle: .system), maxWidth: 60)
                XCTAssertTrue(try XCTUnwrap(strip.renderStatusImage(width: 60, height: 24, appearance: NSAppearance(named: .aqua)!, highlighted: true)).isTemplate)
            }
            for style in IndicatorIconStyle.legacyStyles {
                strip.update(items: Self.items, readings: Self.readings, appearance: BarAppearance(iconStyle: style))
                XCTAssertFalse(try XCTUnwrap(strip.renderStatusImage(width: strip.frame.width, height: 24, appearance: NSAppearance(named: .aqua)!, highlighted: false)).isTemplate)
            }
        }
    }

    func testSettingsPreviewNativelyTintsTemplateInLightAndDarkWithoutAttachingCanvas() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            for style in IndicatorIconStyle.nativeStyles {
                let preview = StatusStripPreviewView(frame: .zero)
                var capturedSize: NSSize?
                for (name, expectBright) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
                    let appearance = NSAppearance(named: name)!
                    preview.appearance = appearance
                    preview.configure(items: Self.items, readings: Self.readings, appearance: BarAppearance(iconStyle: style))
                    XCTAssertTrue(try XCTUnwrap(preview.image).isTemplate)
                    var descendants = preview.subviews
                    while let child = descendants.popLast() {
                        XCTAssertFalse(child is StatusStrip)
                        descendants.append(contentsOf: child.subviews)
                    }
                    XCTAssertEqual(preview.frame.size, preview.intrinsicContentSize)
                    XCTAssertEqual(preview.image?.size, preview.intrinsicContentSize)
                    if let capturedSize { XCTAssertEqual(preview.frame.size, capturedSize) }
                    capturedSize = preview.frame.size
                    let bitmap = try XCTUnwrap(preview.bitmapImageRepForCachingDisplay(in: preview.bounds))
                    appearance.performAsCurrentDrawingAppearance { preview.cacheDisplay(in: preview.bounds, to: bitmap) }
                    var solidPixels = 0
                    var brightness: CGFloat = 0
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<bitmap.pixelsWide {
                            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else { continue }
                            solidPixels += 1
                            brightness += (color.redComponent + color.greenComponent + color.blueComponent) / 3
                        }
                    }
                    XCTAssertGreaterThan(solidPixels, 30)
                    let average = brightness / CGFloat(max(1, solidPixels))
                    if expectBright { XCTAssertGreaterThan(average, 0.65, "Prévia escura precisa de tinta clara do NSImageView") }
                    else { XCTAssertLessThan(average, 0.25, "Prévia clara precisa de tinta escura do NSImageView") }
                }
            }
        }
    }

    // Opt-in output; no preferences or user readings are consulted.
    func testExportNativeComparisonWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["NEXOBAR_ICON_PREVIEW_DIR"] else { return }
        try await MainActor.run {
            _ = NSApplication.shared
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let contexts: [(title: String, foreground: NSColor, background: NSColor)] = [
                ("Claro", .black, NSColor(calibratedWhite: 0.89, alpha: 1)),
                ("Escuro", .white, NSColor(calibratedWhite: 0.16, alpha: 1)),
                ("Selecionado", .white, NSColor(srgbRed: 0.05, green: 0.32, blue: 0.72, alpha: 1))
            ]
            var samples: [(String, [NSImage])] = []
            for style in IndicatorIconStyle.nativeStyles + IndicatorIconStyle.legacyStyles {
                let strip = StatusStrip(frame: NSRect(x: 0, y: 0, width: 0, height: 24))
                let width = strip.update(items: Self.items, readings: Self.readings, appearance: BarAppearance(iconStyle: style))
                var images: [NSImage] = []
                // Preview compares the real alpha masks. It does not impersonate an active menu-bar screenshot.
                let mask = try XCTUnwrap(strip.renderStatusImage(width: width, height: 24, appearance: NSAppearance(named: .aqua)!, highlighted: false))
                let raw = try XCTUnwrap(mask.copy() as? NSImage)
                raw.isTemplate = false
                for context in contexts {
                    let snapshot = NSImage(size: raw.size, flipped: false) { rect in
                        raw.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                        context.foreground.setFill()
                        rect.fill(using: .sourceIn)
                        return true
                    }
                    let cg = try XCTUnwrap(snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil))
                    let bitmap = NSBitmapImageRep(cgImage: cg)
                    var solidPixels = 0
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<bitmap.pixelsWide {
                            guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), pixel.alphaComponent > 0.95 else { continue }
                            solidPixels += 1
                            XCTAssertGreaterThan(Self.contrastRatio(pixel, context.background), 4.5,
                                                 "Prévia \(style.title), \(context.title) sem contraste")
                        }
                    }
                    XCTAssertGreaterThan(solidPixels, 30)
                    images.append(snapshot)
                }
                samples.append((style.title, images))
            }
            let image = NSImage(size: NSSize(width: 1150, height: 430), flipped: true) { rect in
                NSColor(calibratedWhite: 0.95, alpha: 1).setFill(); rect.fill()
                func label(_ string: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat = 13, _ bold: Bool = false) {
                    (string as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: NSColor.black])
                }
                label("NexoBar · propostas de ícones", 24, 18, 22, true)
                label("CPU · Memória · GPU   |   mesmas leituras em todos os exemplos", 24, 52)
                for (column, context) in contexts.enumerated() { label(context.title, CGFloat(190 + column * 310), 86, 13, true) }
                for (row, sample) in samples.enumerated() {
                    let y = CGFloat(116 + row * 52)
                    label(sample.0, 24, y + 8, 14, true)
                    for (column, snapshot) in sample.1.enumerated() {
                        let band = NSRect(x: CGFloat(174 + column * 310), y: y, width: 294, height: 36)
                        contexts[column].background.setFill()
                        NSBezierPath(roundedRect: band, xRadius: 5, yRadius: 5).fill()
                        snapshot.draw(in: NSRect(x: band.minX + 8, y: y + 6, width: snapshot.size.width, height: 24), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    }
                }
                label("Prévia das formas; cores ilustrativas. No uso real, macOS aplica contraste.", 24, 396, 11)
                return true
            }
            let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 10000)
            try png.write(to: directory.appendingPathComponent("icones-macos-comparacao.png"), options: .atomic)
        }
    }

    private static var items: [IndicatorConfiguration] {
        [IndicatorID.cpu, .memory, .gpu].map { .init(id: $0, enabled: true, label: $0.name) }
    }
    private static var readings: [IndicatorID: IndicatorReading] {
        [.cpu: .init(id: .cpu, value: "37%", detail: "", sampledAt: nil),
         .memory: .init(id: .memory, value: "83%", detail: "", sampledAt: nil, usedBytes: 40 * 1_073_741_824, totalBytes: 48 * 1_073_741_824),
         .gpu: .init(id: .gpu, value: "12%", detail: "", sampledAt: nil)]
    }
    private static func pixels(_ image: NSImage) -> Data {
        let bitmap = image.representations.compactMap { $0 as? NSBitmapImageRep }.first!
        return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
    private static func contrastRatio(_ first: NSColor, _ second: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            let rgb = color.usingColorSpace(.sRGB)!
            func linear(_ channel: CGFloat) -> CGFloat {
                channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
