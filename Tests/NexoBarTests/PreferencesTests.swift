import XCTest
@testable import NexoBar

final class PreferencesTests: XCTestCase {
    func testOrderVisibilityAndLabelsSurviveRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nexobar/preferences-tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await MainActor.run {
            let store = Dashboard(directory: directory)
            var item = try XCTUnwrap(store.items.first(where: { $0.id == .kiro }))
            item.enabled = false
            item.label = "Minha cota"
            item.showLabel = true
            store.update(item)
            store.move(.kiro, offset: -1)
            let restored = Dashboard(directory: directory)
            XCTAssertEqual(restored.items, store.items)
            XCTAssertEqual(restored.items.first(where: { $0.id == .kiro })?.enabled, false)
            XCTAssertNil(store.saveError)
        }
    }
}
