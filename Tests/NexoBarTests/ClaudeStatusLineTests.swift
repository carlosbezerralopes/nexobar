import XCTest
@testable import NexoBar

final class ClaudeStatusLineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_584_000)

    private func fixture(captured: Date? = nil, windows: [[String: Any]]) throws -> Data {
        let formatter = ISO8601DateFormatter()
        return try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "provider": "claude",
            "capturedAt": formatter.string(from: captured ?? now), "windows": windows])
    }

    private func window(_ id: String = "session", used: Any = 23.5, reset: Any = NSNull()) -> [String: Any] {
        ["id": id, "usedPercent": used, "resetsAt": reset]
    }

    func testOnlyWeeklyUsesSingleWindowAndItsExplicitZero() throws {
        let reading = try ClaudeStatusLine.parse(fixture(windows: [window("weekly_all", used: 0)]), now: now)
        XCTAssertEqual(reading.value, "0%")
        XCTAssertEqual(reading.windows.count, 1)
        XCTAssertEqual(reading.windows.first?.id, "weekly_all")
        XCTAssertNil(reading.windows.first?.resetsAt)
        XCTAssertEqual(reading.sampledAt, now)
        XCTAssertTrue(reading.detail.contains("data de entrega local"))
    }

    func testSessionIsHeadlineAndResetExpiryRemovesItWithoutInventingRenewal() throws {
        let expired = window(used: 80, reset: now.timeIntervalSince1970)
        let week = window("weekly_all", used: 12, reset: now.addingTimeInterval(86400).timeIntervalSince1970)
        let receipt = try fixture(windows: [week, window(used: 9)])
        let sorted = try ClaudeStatusLine.parse(receipt, now: now)
        XCTAssertEqual(sorted.windows.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(sorted.value, "9%")
        let afterReset = try ClaudeStatusLine.parse(fixture(windows: [expired, week]), now: now)
        XCTAssertEqual(afterReset.value, "12%")
        XCTAssertEqual(afterReset.windows.count, 1)
        XCTAssertThrowsError(try ClaudeStatusLine.parse(fixture(windows: [expired]), now: now))
    }

    func testReceiptAgeDoesNotUseFilesystemModificationAndRejectsFuture() throws {
        for age in [-1.0, 1800, 1801] {
            XCTAssertThrowsError(try ClaudeStatusLine.parse(fixture(captured: now.addingTimeInterval(-age),
                windows: [window()]), now: now))
        }
        XCTAssertNoThrow(try ClaudeStatusLine.parse(fixture(captured: now.addingTimeInterval(-1799),
            windows: [window()]), now: now))
    }

    func testMalformedMissingDuplicateAndUnboundedValuesAreUnavailable() throws {
        for used in [true, NSNull(), "0", -1, 101] as [Any] {
            XCTAssertThrowsError(try ClaudeStatusLine.parse(fixture(windows: [window(used: used)]), now: now))
        }
        for reset in [true, "tomorrow", 1, 1_792_584_000_000] as [Any] {
            XCTAssertThrowsError(try ClaudeStatusLine.parse(fixture(windows: [window(reset: reset)]), now: now))
        }
        for windows in [[], [window("other")], [window(), window()], [["id": "session", "usedPercent": 0]]] {
            XCTAssertThrowsError(try ClaudeStatusLine.parse(fixture(windows: windows), now: now))
        }
        XCTAssertThrowsError(try ClaudeStatusLine.parse(Data("{".utf8), now: now))
        XCTAssertThrowsError(try ClaudeStatusLine.parse(Data(repeating: 32, count: 16385), now: now))
        var root = try JSONSerialization.jsonObject(with: fixture(windows: [window()])) as! [String: Any]
        for change in [("schemaVersion", 2), ("schemaVersion", true), ("provider", "other"), ("session_id", "private")] as [(String, Any)] {
            var changed = root; changed[change.0] = change.1
            XCTAssertThrowsError(try ClaudeStatusLine.parse(JSONSerialization.data(withJSONObject: changed), now: now))
        }
        root["capturedAt"] = "2026-10-21T12:00:00+00:00"
        XCTAssertThrowsError(try ClaudeStatusLine.parse(JSONSerialization.data(withJSONObject: root), now: now))
    }

    func testMissingFileAndSymlinkNeverFallBackToAnotherSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NexoBar/statusline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("receipt.json")
        XCTAssertThrowsError(try ClaudeStatusLine.read(url: file, now: now))
        try fixture(windows: [window()]).write(to: file)
        XCTAssertEqual(try ClaudeStatusLine.read(url: file, now: now).value, "24%")
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try ClaudeStatusLine.read(url: link, now: now))
    }
}
