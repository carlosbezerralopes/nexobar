import XCTest
@testable import NexoBar

final class AppearanceTests: XCTestCase {
    func testHistoryAgesOutEvenWhenSensorKeepsFailing() {
        let now = Date(timeIntervalSince1970: 10000)
        let previous = [MetricPoint(time: now.addingTimeInterval(-301), value: 50), MetricPoint(time: now.addingTimeInterval(-10), value: 40)]
        let failed = IndicatorReading.unavailable(.gpu, "indisponível")
        XCTAssertEqual(MetricHistory.updated(previous, reading: failed, now: now).map(\.value), [40])
        XCTAssertTrue(MetricHistory.updated(previous, reading: failed, now: now.addingTimeInterval(400)).isEmpty)
    }
    func testHorizontalCompactTimeDefaultsAndOldSettingsMigration() throws {
        let value = try JSONDecoder().decode(BarAppearance.self, from: Data(#"{"iconStyle":"solid","identity":"orbit"}"#.utf8))
        XCTAssertEqual(value.quotaLayout, .inline)
        XCTAssertFalse(value.detailedTime)
        XCTAssertEqual(value.iconStyle, .solid)
        XCTAssertEqual(value.identity, .orbit)
    }
    func testNominalMemoryAndMissingTotals() {
        var reading = IndicatorReading(id: .memory, value: "83%", detail: "", sampledAt: Date(), usedBytes: 40 * 1_073_741_824, totalBytes: 48 * 1_073_741_824)
        XCTAssertEqual(reading.displayValue(memory: .usedTotal), "40/48 GiB")
        XCTAssertEqual(reading.displayValue(memory: .percentage), "83%")
        reading.totalBytes = nil
        XCTAssertEqual(reading.displayValue(memory: .usedTotal), "83%")
    }
    func testGroupedTemperatureOptionsAndLayoutSurviveRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nexobar/appearance-tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        await MainActor.run {
            let store = Dashboard(directory: directory)
            store.toggleTemperature(.cpu)
            store.move(.gpu, offset: -1)
            var appearance = store.appearance
            appearance.quotaLayout = .stacked; appearance.detailedTime = true; appearance.identity = .pulse
            store.updateAppearance(appearance)
            let restored = Dashboard(directory: directory)
            XCTAssertEqual(restored.appearance, appearance)
            XCTAssertEqual(restored.items, store.items)
            XCTAssertFalse(restored.items.first(where: { $0.id == .cpuTemperature })!.enabled)
            XCTAssertEqual(restored.items.filter { !$0.id.isNested }.prefix(3).map(\.id), [.cpu, .gpu, .memory])
        }
    }
}
