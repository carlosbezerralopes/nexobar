import AppKit
import XCTest
@testable import NexoBar

final class StatusStripTests: XCTestCase {
    func testAccountWindowsNeverPromoteModelOrWeeklyToPrimary() {
        let weekly = QuotaWindow(name: "Semanal", usedPercent: 90, resetsAt: nil, id: "secondary", durationMinutes: 10080)
        let model = QuotaWindow(name: "Sonnet", usedPercent: 95, resetsAt: nil, id: "seven_day_sonnet", durationMinutes: 10080)
        let selected = QuotaBarPresentation(windows: [model, weekly])
        XCTAssertNil(selected.primary)
        XCTAssertEqual(selected.secondary, weekly)
        XCTAssertEqual(QuotaBarPresentation.value(for: selected.primary), "—")
        XCTAssertNil(QuotaBarPresentation(windows: [model]).secondary)
    }

    func testClaudeAccountAliasesSelectSessionAndWeeklyAllWithoutScopedFallback() {
        let session = QuotaWindow(name: "Sessão", usedPercent: 39, resetsAt: nil, id: "session", durationMinutes: 300)
        let weekly = QuotaWindow(name: "Semanal", usedPercent: 68, resetsAt: nil, id: "weekly_all", durationMinutes: 10080)
        let scoped = QuotaWindow(name: "Semanal", usedPercent: 94, resetsAt: nil, id: "weekly_scoped", durationMinutes: 10080)
        let selection = QuotaBarPresentation(windows: [scoped, weekly, session])
        XCTAssertEqual(selection.primary, session)
        XCTAssertEqual(selection.secondary, weekly)
        let scopedOnly = QuotaBarPresentation(windows: [scoped])
        XCTAssertNil(scopedOnly.primary)
        XCTAssertNil(scopedOnly.secondary)
    }

    func testCodexPrimaryWithWeeklyDurationAppearsOnlyInWeeklySlot() {
        let weekly = QuotaWindow(name: "Semanal", usedPercent: 73, resetsAt: nil, id: "primary", durationMinutes: 10080)
        let reading = IndicatorReading(id: .codex, value: "73%", detail: "", sampledAt: Date(), windows: [weekly])
        let selection = QuotaBarPresentation(windows: reading.windows)
        XCTAssertNil(selection.primary)
        XCTAssertEqual(selection.secondary, weekly)
        XCTAssertEqual(QuotaBarPresentation.value(for: selection.primary), "—")
        XCTAssertEqual(reading.value, "73%")
        XCTAssertEqual(reading.windows.first?.id, "primary")
    }

    func testLegacyNamesOnlyApplyWhenThereIsNoExplicitID() {
        let model = QuotaWindow(name: "Semanal", usedPercent: 99, resetsAt: nil, id: "seven_day_opus")
        let legacy = QuotaWindow(name: "Sessão", usedPercent: 12, resetsAt: nil)
        let selected = QuotaBarPresentation(windows: [model, legacy])
        XCTAssertEqual(selected.primary, legacy)
        XCTAssertNil(selected.secondary)
        let current = QuotaWindow(name: "Principal", usedPercent: 10, resetsAt: nil, id: "primary")
        XCTAssertEqual(QuotaBarPresentation(windows: [legacy, current]).primary, current)
    }

    func testClicksRouteOnlyToTheirCellAndAnchorsSurviveUpdates() async {
        await MainActor.run {
            _ = NSApplication.shared
            let strip = StatusStrip(frame: NSRect(x: 0, y: 0, width: 0, height: 24))
            let cpu = IndicatorConfiguration(id: .cpu, enabled: true, label: "CPU")
            let memory = IndicatorConfiguration(id: .memory, enabled: true, label: "Memória")
            var selected: [IndicatorID] = []
            var anchors: [NSView] = []
            strip.onSelect = { selected.append($0); anchors.append($1) }
            let width = strip.update(items: [cpu, memory], readings: [:], appearance: BarAppearance())
            let buttons = strip.subviews.compactMap { $0 as? NSButton }.sorted { $0.frame.minX < $1.frame.minX }
            XCTAssertEqual(buttons.count, 2)
            XCTAssertEqual(width, buttons.reduce(0) { $0 + $1.frame.width })
            buttons[0].performClick(nil)
            buttons[1].performClick(nil)
            XCTAssertEqual(selected, [.cpu, .memory])
            XCTAssertTrue(anchors[0] === buttons[0])
            strip.update(items: [memory, cpu], readings: [.cpu: .init(id: .cpu, value: "83%", detail: "CPU", sampledAt: Date())], appearance: BarAppearance())
            XCTAssertTrue(buttons.allSatisfy { $0.superview === strip })
            XCTAssertLessThan(buttons[1].frame.minX, buttons[0].frame.minX)
            XCTAssertEqual(buttons[0].toolTip, "CPU\nCPU")
            XCTAssertEqual(buttons[0].accessibilityValue() as? String, "83%")
        }
    }

    func testContextAndEmptyRecoveryDoNotActivateOtherIndicators() async {
        await MainActor.run {
            _ = NSApplication.shared
            let strip = StatusStrip(frame: NSRect(x: 0, y: 0, width: 0, height: 24))
            var selections = 0
            var contexts: [IndicatorID?] = []
            var empties = 0
            strip.onSelect = { _, _ in selections += 1 }
            strip.onContext = { id, _, _ in contexts.append(id) }
            strip.onEmpty = { empties += 1 }
            let cpu = IndicatorConfiguration(id: .cpu, enabled: true, label: "CPU")
            strip.update(items: [cpu], readings: [:], appearance: BarAppearance())
            let cell = strip.subviews[0]
            let right = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let control = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            cell.rightMouseDown(with: right)
            cell.mouseDown(with: control)
            XCTAssertEqual(contexts.compactMap { $0 }, [.cpu, .cpu])
            XCTAssertEqual(selections, 0)
            strip.update(items: [], readings: [:], appearance: BarAppearance())
            let empty = strip.subviews[0] as! NSButton
            empty.performClick(nil)
            empty.rightMouseDown(with: right)
            XCTAssertEqual(empties, 1)
            XCTAssertEqual(contexts.count, 3)
            XCTAssertNil(contexts.last!)
            strip.update(items: [cpu], readings: [:], appearance: BarAppearance())
            XCTAssertTrue(strip.subviews[0] === cell)
        }
    }

    func testSingleReportedWindowNeverReservesAMissingSessionRow() async {
        await MainActor.run {
            _ = NSApplication.shared
            let strip = StatusStrip(frame: NSRect(x: 0, y: 0, width: 0, height: 24))
            let item = IndicatorConfiguration(id: .codex, enabled: true, label: "Codex")
            let reading = IndicatorReading(id: .codex, value: "—", detail: "Conta", sampledAt: Date(), isStale: true,
                                           windows: [.init(name: "Semanal", usedPercent: 96, resetsAt: Date().addingTimeInterval(432000), id: "secondary", durationMinutes: 10080)])
            var widths: [QuotaBarLayout: CGFloat] = [:]
            for layout in QuotaBarLayout.allCases {
                widths[layout] = strip.update(items: [item], readings: [.codex: reading], appearance: BarAppearance(), layout: layout)
                let cell = strip.subviews[0]
                let value = cell.accessibilityValue() as? String ?? ""
                XCTAssertFalse(value.contains("—"))
                XCTAssertFalse(value.contains("Principal"))
                XCTAssertFalse(value.contains("Sessão"))
                XCTAssertTrue(value.contains("96%"))
                XCTAssertTrue(value.contains("leitura antiga"))
                if layout != .primary { XCTAssertTrue(value.contains("Semanal: 96%")) }
            }
            XCTAssertEqual(widths[.inline]!, widths[.stacked]!)
            let memory = IndicatorConfiguration(id: .memory, enabled: true, label: "Memória", memoryDisplay: .usedTotal)
            let bytes = IndicatorReading(id: .memory, value: "50%", detail: "", sampledAt: Date(), usedBytes: 8 * 1_073_741_824, totalBytes: 16 * 1_073_741_824)
            strip.update(items: [memory], readings: [.memory: bytes], appearance: BarAppearance())
            XCTAssertEqual(strip.subviews[0].accessibilityValue() as? String, "8/16 GiB")
        }
    }

    func testResetCountdownUsesActualResetAndNeverChangesConsumption() {
        let now = Date(timeIntervalSince1970: 10000)
        XCTAssertEqual(QuotaBarPresentation.remainingTime(reset: nil, now: now), "—")
        for (seconds, expected) in [(0.0, "0m"), (-30, "0m"), (30, "<1m"), (720, "12m"), (7980, "2h13m"), (273600, "3d4h")] {
            XCTAssertEqual(QuotaBarPresentation.remainingTime(reset: now.addingTimeInterval(seconds), now: now, detailedTime: true), expected)
        }
        XCTAssertEqual(QuotaBarPresentation.remainingTime(reset: now.addingTimeInterval(7980), now: now), "2h")
        XCTAssertEqual(QuotaBarPresentation.remainingTime(reset: now.addingTimeInterval(273600), now: now), "3d")
        XCTAssertEqual(QuotaBarPresentation.remainingTime(reset: now.addingTimeInterval(720), now: now), "12m")
        let expired = QuotaWindow(name: "Principal", usedPercent: 97, resetsAt: now.addingTimeInterval(-30), id: "primary")
        XCTAssertEqual(QuotaBarPresentation.value(for: expired), "97%")
    }

    func testDetailedCountdownChangesVisibleWidthWithoutReorderingAccountWindows() async {
        await MainActor.run {
            _ = NSApplication.shared
            let now = Date(timeIntervalSince1970: 10000)
            let strip = StatusStrip(frame: NSRect(x: 0, y: 0, width: 0, height: 24))
            let item = IndicatorConfiguration(id: .claude, enabled: true, label: "Claude")
            let primary = QuotaWindow(name: "Sessão", usedPercent: 42, resetsAt: now.addingTimeInterval(7980), id: "five_hour")
            let weekly = QuotaWindow(name: "Semanal", usedPercent: 68, resetsAt: now.addingTimeInterval(273600), id: "seven_day")
            let reading = IndicatorReading(id: .claude, value: "42%", detail: "", sampledAt: now, windows: [weekly, primary])
            let compact = strip.update(items: [item], readings: [.claude: reading], appearance: BarAppearance(), now: now)
            let detailed = strip.update(items: [item], readings: [.claude: reading], appearance: BarAppearance(), now: now, detailedTime: true)
            XCTAssertGreaterThan(detailed, compact)
            let accessibility = strip.subviews[0].accessibilityValue() as? String ?? ""
            XCTAssertTrue(accessibility.hasPrefix("Sessão: 42%"))
            XCTAssertTrue(accessibility.contains("2h13m"))
            XCTAssertTrue(accessibility.contains("Semanal: 68%"))
            XCTAssertTrue(accessibility.contains("3d4h"))
            let stacked = strip.update(items: [item], readings: [.claude: reading], appearance: BarAppearance(), layout: .stacked, now: now)
            XCTAssertGreaterThan(compact, stacked)
            var weeklyOnly = reading
            weeklyOnly.windows = [weekly]
            let singleInline = strip.update(items: [item], readings: [.claude: weeklyOnly], appearance: BarAppearance(), layout: .inline, now: now)
            let singleStacked = strip.update(items: [item], readings: [.claude: weeklyOnly], appearance: BarAppearance(), layout: .stacked, now: now)
            XCTAssertEqual(singleInline, singleStacked)
            XCTAssertFalse((strip.subviews[0].accessibilityValue() as? String ?? "").contains("Sessão"))
        }
    }

    func testWidthBudgetKeepsAnOrderedPrefixAndStableOverflowAnchor() async {
        await MainActor.run {
            _ = NSApplication.shared
            let strip = StatusStrip(frame: NSRect(x: 0, y: 0, width: 0, height: 24))
            let items = IndicatorID.allCases.filter { !$0.isNested }.prefix(5).map { IndicatorConfiguration(id: $0, enabled: true, label: $0.name) }
            strip.update(items: items, readings: [:], appearance: BarAppearance(), layout: .primary)
            let initial = strip.subviews.sorted { $0.frame.minX < $1.frame.minX }
            let budget = initial.prefix(2).reduce(CGFloat.zero) { $0 + $1.frame.width } + 45
            let width = strip.update(items: items, readings: [:], appearance: BarAppearance(), layout: .primary, maxWidth: budget)
            XCTAssertLessThanOrEqual(width, budget)
            XCTAssertEqual(strip.hiddenIDs, Array(items.dropFirst(2).map(\.id)))
            let visible = strip.subviews.sorted { $0.frame.minX < $1.frame.minX }
            XCTAssertEqual(visible.map { $0.identifier?.rawValue }, [items[0].id.rawValue, items[1].id.rawValue, "overflow"])
            let overflow = visible.last as! NSButton
            var clicked: NSView?
            strip.onOverflow = { clicked = $0 }
            overflow.performClick(nil)
            XCTAssertTrue(clicked === overflow)
            strip.update(items: items, readings: [:], appearance: BarAppearance(), layout: .primary)
            XCTAssertTrue(strip.hiddenIDs.isEmpty)
            XCTAssertNil(overflow.superview)
            let reordered = Array(items.reversed())
            strip.update(items: reordered, readings: [:], appearance: BarAppearance(), layout: .primary, maxWidth: budget)
            XCTAssertEqual(strip.hiddenIDs, Array(reordered.dropFirst(2).map(\.id)))
            XCTAssertTrue(overflow.superview === strip)
            XCTAssertTrue(initial[0] === strip.subviews.first { $0.identifier?.rawValue == items[0].id.rawValue } || initial[0].superview == nil)
            XCTAssertLessThanOrEqual(strip.frame.width, budget)
            XCTAssertTrue(strip.subviews.allSatisfy { $0.frame.maxX <= budget })
        }
    }

    func testOversizedFirstCellMovesEntirePrefixToOverflowWithoutTruncatingValues() async {
        await MainActor.run {
            _ = NSApplication.shared
            let strip = StatusStrip(frame: NSRect(x: 0, y: 0, width: 0, height: 24))
            let items = [IndicatorConfiguration(id: .cpu, enabled: true, label: String(repeating: "Nome longo ", count: 30), showLabel: true),
                         IndicatorConfiguration(id: .memory, enabled: true, label: "Memória")]
            let width = strip.update(items: items, readings: [:], appearance: BarAppearance(), maxWidth: 80)
            XCTAssertLessThanOrEqual(width, 80)
            XCTAssertEqual(strip.hiddenIDs, [.cpu, .memory])
            XCTAssertEqual(strip.subviews.count, 1)
            let overflow = strip.subviews[0] as! NSButton
            XCTAssertEqual(overflow.identifier?.rawValue, "overflow")
            XCTAssertEqual(overflow.accessibilityValue() as? String, "2 indicadores fora da barra")
            var receivedContext = false
            var receivedID: IndicatorID? = .cpu
            var anchor: NSView?
            strip.onContext = { id, view, _ in receivedContext = true; receivedID = id; anchor = view }
            let right = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            overflow.rightMouseDown(with: right)
            XCTAssertTrue(receivedContext)
            XCTAssertNil(receivedID)
            XCTAssertTrue(anchor === overflow)
            strip.update(items: [], readings: [:], appearance: BarAppearance(), maxWidth: 80)
            XCTAssertTrue(strip.hiddenIDs.isEmpty)
            XCTAssertEqual(strip.subviews[0].identifier?.rawValue, "nexobar")
            XCTAssertLessThanOrEqual(strip.frame.width, 80)
        }
    }

    func testActivitySummaryUpdatesWithoutReplacingItsButton() async {
        await MainActor.run {
            _ = NSApplication.shared
            let strip = StatusStrip(frame: NSRect(x: 0, y: 0, width: 0, height: 24))
            let item = IndicatorConfiguration(id: .claude, enabled: true, label: "Claude")
            var reading = IndicatorReading(id: .claude, value: "—", detail: "", sampledAt: nil)
            for state in ["working", "waiting", "idle", "unknown"] {
                reading.activity = AIActivitySummary(state: state, summary: "Estado \(state)")
                let previous = strip.subviews.first
                strip.update(items: [item], readings: [.claude: reading], appearance: BarAppearance())
                let button = strip.subviews[0]
                if let previous { XCTAssertTrue(previous === button) }
                XCTAssertTrue(button.toolTip?.contains("Atividade: Estado \(state)") == true)
                XCTAssertTrue((button.accessibilityValue() as? String)?.contains("Atividade: Estado \(state)") == true)
            }
        }
    }

    func testHostButtonHitTestingReachesEachIndicatorAndOverflow() async {
        await MainActor.run {
            _ = NSApplication.shared
            let host = NSButton(frame: NSRect(x: 0, y: 0, width: 480, height: 24))
            host.title = ""
            let strip = StatusStrip(frame: host.bounds)
            host.addSubview(strip)
            let items = IndicatorID.allCases.map {
                IndicatorConfiguration(id: $0, enabled: true, label: $0.name + " indicador longo", showLabel: true)
            }
            let width = strip.update(items: items, readings: [:], appearance: BarAppearance(), maxWidth: 480)
            XCTAssertLessThanOrEqual(width, 480)
            XCTAssertFalse(strip.subviews.isEmpty)
            XCTAssertFalse(strip.hiddenIDs.isEmpty)
            let visible = strip.subviews.sorted { $0.frame.minX < $1.frame.minX }
            let visibleIDs = visible.compactMap { $0.identifier.flatMap { IndicatorID(rawValue: $0.rawValue) } }
            XCTAssertEqual(strip.hiddenIDs, Array(items.filter { !$0.id.isNested }.dropFirst(visibleIDs.count).map(\.id)))
            XCTAssertEqual(visible.last?.identifier?.rawValue, "overflow")
            for cell in visible {
                XCTAssertLessThanOrEqual(cell.frame.maxX, 480)
                let point = cell.convert(NSPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: host)
                XCTAssertTrue(host.hitTest(point) === cell)
            }
        }
    }

    func testTemperaturesStayInsideTheirParentsRegardlessOfConfigurationOrder() async {
        await MainActor.run {
            _ = NSApplication.shared
            let strip = StatusStrip(frame: NSRect(x: 0, y: 0, width: 0, height: 24))
            let cpu = IndicatorConfiguration(id: .cpu, enabled: true, label: "CPU")
            let gpu = IndicatorConfiguration(id: .gpu, enabled: true, label: "GPU")
            let cpuTemp = IndicatorConfiguration(id: .cpuTemperature, enabled: true, label: "Temperatura CPU")
            let gpuTemp = IndicatorConfiguration(id: .gpuTemperature, enabled: true, label: "Temperatura GPU")
            let memory = IndicatorConfiguration(id: .memory, enabled: true, label: "Memória")
            let items = [gpuTemp, cpu, memory, cpuTemp, gpu]
            let readings: [IndicatorID: IndicatorReading] = [
                .cpu: .init(id: .cpu, value: "42%", detail: "", sampledAt: Date()),
                .gpu: .init(id: .gpu, value: "18%", detail: "", sampledAt: Date()),
                .cpuTemperature: .init(id: .cpuTemperature, value: "65 °C", detail: "Sensor CPU", sampledAt: Date()),
                .gpuTemperature: .unavailable(.gpuTemperature, "Sensor GPU indisponível")
            ]
            strip.update(items: items, readings: readings, appearance: BarAppearance())
            let buttons = strip.subviews.sorted { $0.frame.minX < $1.frame.minX }
            XCTAssertEqual(buttons.map { $0.identifier?.rawValue }, ["cpu", "memory", "gpu"])
            XCTAssertEqual(buttons[0].accessibilityValue() as? String, "42% · 65°C")
            XCTAssertEqual(buttons[2].accessibilityValue() as? String, "18% · —")
            XCTAssertTrue(buttons[2].toolTip?.contains("Sensor GPU indisponível") == true)
            var clicked: IndicatorID?
            strip.onSelect = { id, _ in clicked = id }
            (buttons[0] as! NSButton).performClick(nil)
            XCTAssertEqual(clicked, .cpu)
            let withTemperature = buttons[0].frame.width
            var disabled = cpuTemp
            disabled.enabled = false
            strip.update(items: [gpuTemp, cpu, memory, disabled, gpu], readings: readings, appearance: BarAppearance())
            XCTAssertEqual(buttons[0].accessibilityValue() as? String, "42%")
            XCTAssertLessThan(buttons[0].frame.width, withTemperature)
            XCTAssertTrue(cpuTemp.enabled)
            strip.update(items: items, readings: readings, appearance: BarAppearance(), maxWidth: 80)
            XCTAssertEqual(strip.hiddenIDs, [.cpu, .memory, .gpu])
            XCTAssertFalse(strip.hiddenIDs.contains(where: \.isNested))
        }
    }
}
