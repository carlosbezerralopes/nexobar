import XCTest
@testable import NexoBar

final class CoreTests: XCTestCase {
    func testMissingAndFractionalUsageAreNeverDisplayedAsZero() {
        XCTAssertEqual(IndicatorReading.percent(.nan), "—")
        XCTAssertEqual(IndicatorReading.percent(.greatestFiniteMagnitude), "—")
        XCTAssertEqual(IndicatorReading.percent(-1), "—")
        XCTAssertEqual(IndicatorReading.percent(0), "0%")
        XCTAssertEqual(IndicatorReading.percent(0.2), "<1%")
        XCTAssertEqual(IndicatorReading.percent(99.7), "99%")
        XCTAssertEqual(IndicatorReading.percent(100), "100%")
    }
    func testConfigurationKeepsCustomOrderAndRestoresNewIndicators() throws {
        let item = IndicatorConfiguration(id: .kiro, enabled: false, label: "Minha IA")
        let config = IndicatorConfiguration.normalized([item, item])
        XCTAssertEqual(config.first, item)
        XCTAssertEqual(Set(config.map(\.id)).count, IndicatorID.allCases.count)
        XCTAssertEqual(try JSONDecoder().decode([IndicatorConfiguration].self, from: JSONEncoder().encode(config)), config)
    }
    func testOldPreferencesKeepIdentityAndSelection() throws {
        let json = Data(#"{"id":"kiro","enabled":false,"label":"Minha IA"}"#.utf8)
        let value = try JSONDecoder().decode(IndicatorConfiguration.self, from: json)
        XCTAssertEqual(value.label, "Minha IA")
        XCTAssertFalse(value.enabled)
        XCTAssertFalse(value.showLabel)
    }
    func testQuotaBecomesStaleAfterSuspensionWithoutWaitingForNetwork() {
        let now = Date(timeIntervalSince1970: 10000)
        let reading = IndicatorReading(id: .codex, value: "20%", detail: "", sampledAt: now)
        XCTAssertFalse(reading.aged(at: now.addingTimeInterval(300)).isStale)
        XCTAssertTrue(reading.aged(at: now.addingTimeInterval(3600)).isStale)
        XCTAssertTrue(reading.aged(at: now.addingTimeInterval(-30)).isStale)
    }
    func testHungHardwareCannotLookLikeCurrentReading() {
        let now = Date(timeIntervalSince1970: 10000)
        let reading = IndicatorReading(id: .gpuTemperature, value: "65°C", detail: "", sampledAt: now)
        XCTAssertFalse(reading.aged(at: now.addingTimeInterval(3)).isStale)
        XCTAssertTrue(reading.aged(at: now.addingTimeInterval(16)).isStale)
    }
}
