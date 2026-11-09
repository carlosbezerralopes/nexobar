import XCTest
@testable import NexoBar

/// Names, order and display options aligned with Windows 0.7.0 (windows/core/Models.cs).
final class DisplayParityTests: XCTestCase {
    private let ptBR = Locale(identifier: "pt_BR")
    private let thin = "\u{2009}·\u{2009}"

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nexobar/display-parity-tests/\(UUID().uuidString)")
    }

    /// The 0.3.1 file: old default order and names, no SSD and no SSD options.
    private func legacyFile(_ entries: [[String: Any]], in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: entries).write(to: directory.appendingPathComponent("indicators.json"))
    }

    func testDefaultsFollowWindowsNamesAndOrder() {
        let top = IndicatorConfiguration.defaults.filter { !$0.id.isNested }
        XCTAssertEqual(top.prefix(7).map(\.label), ["CPU", "GPU", "SSD", "RAM", "Claude", "Codex", "Kiro"])
        let ssd = IndicatorConfiguration.defaults.first { $0.id == .ssd }!
        XCTAssertTrue(ssd.enabled); XCTAssertFalse(ssd.showRates); XCTAssertFalse(ssd.showFreeSpace)
        XCTAssertEqual(IndicatorID.ssd.temperatureChild, .ssdTemperature)
    }

    func testLegacyDefaultsMigrateOnceKeepingChoices() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        try legacyFile([
            ["id": "cpu", "enabled": true, "label": "CPU"],
            ["id": "memory", "enabled": true, "label": "Memória", "showLabel": true, "memoryDisplay": "percentage"],
            ["id": "gpu", "enabled": false, "label": "GPU"],
            ["id": "cpuTemperature", "enabled": false, "label": "Temperatura CPU"],
            ["id": "claude", "enabled": true, "label": "Meu Claude"],
        ], in: folder)
        await MainActor.run {
            let store = Dashboard(directory: folder)
            XCTAssertEqual(store.items.filter { !$0.id.isNested }.prefix(5).map(\.id), [.cpu, .gpu, .ssd, .memory, .claude])
            let memory = store.items.first { $0.id == .memory }!
            XCTAssertEqual(memory.label, "RAM"); XCTAssertTrue(memory.showLabel); XCTAssertEqual(memory.memoryDisplay, .percentage)
            XCTAssertFalse(store.items.first { $0.id == .gpu }!.enabled)
            XCTAssertFalse(store.items.first { $0.id == .cpuTemperature }!.enabled)
            XCTAssertEqual(store.items.first { $0.id == .claude }!.label, "Meu Claude")
            // After the first save the file has the SSD: a later choice of RAM before GPU is never undone.
            store.move(.memory, offset: -1); store.move(.memory, offset: -1)
            let restored = Dashboard(directory: folder)
            XCTAssertEqual(restored.items.filter { !$0.id.isNested }.prefix(4).map(\.id), [.cpu, .memory, .gpu, .ssd])
        }
    }

    func testCustomizedLegacyOrderAndNamesAreKept() {
        let saved = [IndicatorConfiguration(id: .gpu, enabled: true, label: "GPU"),
                     IndicatorConfiguration(id: .cpu, enabled: true, label: "CPU"),
                     IndicatorConfiguration(id: .memory, enabled: true, label: "Mem")]
        let migrated = IndicatorConfiguration.migrated(saved)
        XCTAssertEqual(migrated.filter { !$0.id.isNested }.prefix(4).map(\.id), [.gpu, .cpu, .ssd, .memory])
        XCTAssertEqual(migrated.first { $0.id == .memory }?.label, "Mem")
    }

    func testFormatsMatchWindows() {
        XCTAssertEqual(BarText.memory(used: 12.3 * 1_073_741_824, total: 32 * 1_073_741_824, locale: ptBR), "12,3/32 GB")
        XCTAssertEqual(BarText.memory(used: 12 * 1_073_741_824, total: 32 * 1_073_741_824, locale: ptBR), "12/32 GB")
        XCTAssertNil(BarText.memory(used: 1, total: 0))
        XCTAssertEqual(BarText.rates(read: 1_200_000, write: 400_000, locale: ptBR), "L 1,2 E 0,4 MB/s")
        XCTAssertEqual(BarText.rates(read: 0, write: 70_000, locale: ptBR), "L 0 E 70 KB/s")
        XCTAssertEqual(BarText.rates(read: 25_000_000, write: 0, locale: ptBR), "L 25 E 0 MB/s")
        XCTAssertEqual(BarText.size(89e9, locale: ptBR), "89 GB")
        XCTAssertEqual(BarText.size(1.5e12, locale: ptBR), "1,5 TB")
        XCTAssertEqual(BarText.size(512e6, locale: ptBR), "512 MB")
    }

    func testSSDActivityNeedsTwoSamplesAndNeverInventsZero() {
        var snapshots = [
            DiskSnapshot(counters: .init(bytesRead: 0, bytesWritten: 0, busyNanoseconds: 0), name: "APPLE SSD", totalBytes: 1000e9, availableBytes: 89e9),
            DiskSnapshot(counters: .init(bytesRead: 3_600_000, bytesWritten: 1_200_000, busyNanoseconds: 0.75e9), name: "APPLE SSD", totalBytes: 1000e9, availableBytes: 89e9),
            DiskSnapshot(counters: .init(bytesRead: 0, bytesWritten: 0, busyNanoseconds: 0), name: "APPLE SSD", totalBytes: 1000e9, availableBytes: 89e9),
            DiskSnapshot(counters: nil, name: nil, totalBytes: nil, availableBytes: nil),
        ]
        var time: TimeInterval = 100
        let monitor = SSDMonitor(readSnapshot: { snapshots.removeFirst() }, uptime: { time }, date: { Date(timeIntervalSince1970: 0) })
        let first = monitor.sample()
        XCTAssertEqual(first.value, "—"); XCTAssertNil(first.numericValue); XCTAssertNil(first.ratesText)
        XCTAssertEqual(first.freeSpaceText, "89 GB livre"); XCTAssertEqual(first.hardwareName, "APPLE SSD")
        time += 3
        let second = monitor.sample()
        XCTAssertEqual(second.value, "25%"); XCTAssertEqual(second.readRate, 1_200_000); XCTAssertEqual(second.writeRate, 400_000)
        time += 3
        let reset = monitor.sample()
        XCTAssertEqual(reset.value, "—", "counters going backwards are a driver reset, not 0%")
        time += 3
        let missing = monitor.sample()
        XCTAssertNil(missing.sampledAt); XCTAssertEqual(missing.value, "—")
    }

    func testSSDChoosesTheInternalSolidStateDiskOverTheSDReader() {
        let reader = SSDMonitor.BlockDevice(counters: .init(bytesRead: 0, bytesWritten: 0, busyNanoseconds: 0), name: "Built In SDXC Reader", isInternal: true, solidState: false)
        let ssd = SSDMonitor.BlockDevice(counters: .init(bytesRead: 9, bytesWritten: 9, busyNanoseconds: 9), name: "APPLE SSD AP1024Z", isInternal: true, solidState: true)
        let external = SSDMonitor.BlockDevice(counters: .init(bytesRead: 99, bytesWritten: 99, busyNanoseconds: 99), name: "USB", isInternal: false, solidState: true)
        XCTAssertEqual(SSDMonitor.choose([reader, external, ssd])?.name, "APPLE SSD AP1024Z")
        XCTAssertNil(SSDMonitor.choose([external]))
    }

    func testSSDBarOrderIsActiveRatesTemperatureFreeSpace() async {
        await MainActor.run {
            _ = NSApplication.shared
            let strip = StatusStrip(frame: NSRect(x: 0, y: 0, width: 0, height: 24))
            var ssd = IndicatorConfiguration(id: .ssd, enabled: true, label: "SSD")
            ssd.showFreeSpace = true
            let temperature = IndicatorConfiguration(id: .ssdTemperature, enabled: true, label: "Temperatura SSD")
            var reading = IndicatorReading(id: .ssd, value: "25%", detail: "", sampledAt: Date(), usedBytes: 911e9, totalBytes: 1000e9, numericValue: 25)
            reading.readRate = 0; reading.writeRate = 70_000
            let celsius = IndicatorReading(id: .ssdTemperature, value: "39 °C", detail: "", sampledAt: Date())
            strip.update(items: [ssd, temperature], readings: [.ssd: reading, .ssdTemperature: celsius], appearance: BarAppearance())
            XCTAssertEqual(strip.subviews[0].accessibilityValue() as? String, "25%\(thin)39°\(thin)89 GB livre")
            ssd.showRates = true; ssd.showFreeSpace = false
            strip.update(items: [ssd, temperature], readings: [.ssd: reading, .ssdTemperature: celsius], appearance: BarAppearance())
            XCTAssertEqual(strip.subviews[0].accessibilityValue() as? String, "25%\(thin)L 0 E 70 KB/s\(thin)39°")
        }
    }

    func testQuotaResetIsOptionalAndIndependentOfNames() async {
        await MainActor.run {
            _ = NSApplication.shared
            let now = Date(timeIntervalSince1970: 10000)
            let strip = StatusStrip(frame: NSRect(x: 0, y: 0, width: 0, height: 24))
            var item = IndicatorConfiguration(id: .claude, enabled: true, label: "Claude")
            item.showLabel = true
            let reading = IndicatorReading(id: .claude, value: "42%", detail: "", sampledAt: now,
                                           windows: [QuotaWindow(name: "Sessão", usedPercent: 42, resetsAt: now.addingTimeInterval(7980), id: "five_hour")])
            var appearance = BarAppearance()
            strip.update(items: [item], readings: [.claude: reading], appearance: appearance, layout: .primary, now: now)
            XCTAssertEqual(strip.subviews[0].accessibilityValue() as? String, "Claude 42%\(thin)2h")
            appearance.showQuotaReset = false
            strip.update(items: [item], readings: [.claude: reading], appearance: appearance, layout: .primary, now: now)
            XCTAssertEqual(strip.subviews[0].accessibilityValue() as? String, "Claude 42%")
        }
    }

    func testOlderAppearanceFileShowsResetByDefault() throws {
        let decoded = try JSONDecoder().decode(BarAppearance.self, from: Data(#"{"detailedTime":true}"#.utf8))
        XCTAssertTrue(decoded.showQuotaReset); XCTAssertTrue(decoded.detailedTime)
    }

    func testRestoreAlternatesShortAndOfficialNames() async {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        await MainActor.run {
            let store = Dashboard(directory: folder)
            XCTAssertNil(store.alternateLabel(for: .claude))
            var claude = store.items.first { $0.id == .claude }!
            claude.label = "Meu"; store.update(claude)
            store.restoreLabel(.claude)
            XCTAssertEqual(store.items.first { $0.id == .claude }?.label, "Claude")
        }
    }

    func testSSDTemperatureKeysOnlyForAppleSilicon() {
        XCTAssertEqual(HardwareSensorDecoding.ssdTemperatureKeys(model: "Apple M5 Pro"), ["TH0x", "TH0a", "TH0b"])
        XCTAssertEqual(HardwareSensorDecoding.ssdTemperatureKeys(model: "Intel(R) Core(TM) i7"), [])
    }

    func testLettersStyleShowsHardwareNamesAndFitsTheNotchBudget() {
        for id in [IndicatorID.cpu, .gpu, .ssd, .memory] {
            let width = IndicatorIconStyle.letters.image(for: id)?.size.width ?? 0
            XCTAssertGreaterThan(width, 16, "\(id) shows CPU/GPU/SSD/RAM, not a single letter")
            XCTAssertLessThan(width, 26)
        }
    }

    func testClaudePlanComesOnlyFromTheHeader() {
        XCTAssertEqual(ClaudeUsageParser.plan("Claude Code v3\nOpus 5.5 · Claude Max\n❯"), "Max")
        XCTAssertEqual(ClaudeUsageParser.plan("Sonnet 5.5 · Claude Team   \n"), "Team")
        XCTAssertNil(ClaudeUsageParser.plan("Current session\n42% used"))
        XCTAssertEqual(BarText.temperature("67 °C"), "67°")
    }

    func testFullBarWithPlanFitsTheNotchBudget() async {
        await MainActor.run {
            _ = NSApplication.shared
            let strip = StatusStrip(frame: NSRect(x: 0, y: 0, width: 0, height: 24))
            var appearance = BarAppearance(); appearance.iconStyle = .letters; appearance.quotaLayout = .stacked; appearance.detailedTime = true
            let now = Date()
            var claude = IndicatorReading(id: .claude, value: "39%", detail: "", sampledAt: now,
                windows: [QuotaWindow(name: "Sessão", usedPercent: 12, resetsAt: now.addingTimeInterval(9000), id: "session"),
                          QuotaWindow(name: "Semanal", usedPercent: 39, resetsAt: now.addingTimeInterval(226000), id: "weekly_all")])
            claude.plan = "Team"
            let readings: [IndicatorID: IndicatorReading] = [
                .cpu: .init(id: .cpu, value: "45%", detail: "", sampledAt: now), .cpuTemperature: .init(id: .cpuTemperature, value: "67 °C", detail: "", sampledAt: now),
                .gpu: .init(id: .gpu, value: "45%", detail: "", sampledAt: now), .gpuTemperature: .init(id: .gpuTemperature, value: "67 °C", detail: "", sampledAt: now),
                .ssd: .init(id: .ssd, value: "45%", detail: "", sampledAt: now), .ssdTemperature: .init(id: .ssdTemperature, value: "67 °C", detail: "", sampledAt: now),
                .memory: .init(id: .memory, value: "48%", detail: "", sampledAt: now, usedBytes: 23.2 * 1_073_741_824, totalBytes: 48 * 1_073_741_824),
                .claude: claude]
            let items = IndicatorConfiguration.defaults.map { item -> IndicatorConfiguration in
                var copy = item; copy.enabled = [.cpu, .gpu, .ssd, .memory, .cpuTemperature, .gpuTemperature, .ssdTemperature, .claude].contains(item.id); return copy }
            let width = strip.update(items: items, readings: readings, appearance: appearance, layout: .stacked, now: now, detailedTime: true, maxWidth: 480)
            XCTAssertTrue(strip.hiddenIDs.isEmpty, "\(width) pt; hidden \(strip.hiddenIDs)")
            XCTAssertEqual(strip.subviews.first { $0.identifier?.rawValue == "claude" }?.accessibilityLabel(), "Claude Team")
        }
    }
}
