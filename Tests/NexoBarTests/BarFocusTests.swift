import AppKit
import XCTest
@testable import NexoBar

final class BarFocusTests: XCTestCase {
    func testOldAppearanceDefaultsToPrimaryInteractionAndPreservesChoices() throws {
        let appearance = try JSONDecoder().decode(BarAppearance.self, from: Data(#"{"iconStyle":"solid","identity":"orbit","notifyResets":false,"quotaLayout":"stacked","detailedTime":true}"#.utf8))
        XCTAssertEqual(appearance.interactionDisplay, .main)
        XCTAssertEqual(appearance.iconStyle, .solid)
        XCTAssertEqual(appearance.identity, .orbit)
        XCTAssertFalse(appearance.notifyResets)
        XCTAssertTrue(appearance.detailedTime)
        XCTAssertEqual(appearance.quotaLayout, .stacked)
        XCTAssertEqual(try JSONDecoder().decode(BarAppearance.self, from: JSONEncoder().encode(appearance)), appearance)
    }

    func testAnyDisplayPreferenceSurvivesRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nexobar/bar-focus-tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        await MainActor.run {
            let dashboard = Dashboard(directory: directory)
            var appearance = dashboard.appearance
            appearance.interactionDisplay = .any
            dashboard.updateAppearance(appearance)
            XCTAssertEqual(Dashboard(directory: directory).appearance.interactionDisplay, .any)
        }
    }

    func testPrimaryGateUsesScreenCoordinatesIncludingLeftAndAboveDisplays() {
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertTrue(StatusInteractionDisplay.main.allows(point: NSPoint(x: 1200, y: 890), primaryFrame: primary))
        XCTAssertFalse(StatusInteractionDisplay.main.allows(point: NSPoint(x: -50, y: 890), primaryFrame: primary))
        XCTAssertFalse(StatusInteractionDisplay.main.allows(point: NSPoint(x: 1200, y: 1790), primaryFrame: primary))
        XCTAssertFalse(StatusInteractionDisplay.main.allows(point: NSPoint(x: 1440, y: 890), primaryFrame: primary))
        XCTAssertFalse(StatusInteractionDisplay.main.allows(point: .zero, primaryFrame: nil))
        XCTAssertTrue(StatusInteractionDisplay.any.allows(point: NSPoint(x: -50, y: 1790), primaryFrame: nil))
    }

    func testPrimaryGateRejectsNonfiniteCoordinates() {
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertFalse(StatusInteractionDisplay.main.allows(point: NSPoint(x: CGFloat.nan, y: 890), primaryFrame: primary))
        XCTAssertFalse(StatusInteractionDisplay.main.allows(point: NSPoint(x: 1200, y: CGFloat.infinity), primaryFrame: primary))
    }

    func testPollingDoesNotShrinkReservedWidthAndSettingsCanReclaimSpace() {
        var reservation = StatusBarWidthReservation()
        let items = IndicatorConfiguration.defaults
        var appearance = BarAppearance()
        XCTAssertEqual(reservation.reserve(contentWidth: 200, maxWidth: 480, items: items, appearance: appearance), 200)
        XCTAssertEqual(reservation.reserve(contentWidth: 220, maxWidth: 480, items: items, appearance: appearance), 220)
        XCTAssertEqual(reservation.reserve(contentWidth: 200, maxWidth: 480, items: items, appearance: appearance), 220)
        appearance.quotaLayout = .stacked
        XCTAssertEqual(reservation.reserve(contentWidth: 180, maxWidth: 480, items: items, appearance: appearance), 180)
        XCTAssertEqual(reservation.reserve(contentWidth: 160, maxWidth: 240, items: items, appearance: appearance), 160)
        XCTAssertEqual(reservation.reserve(contentWidth: 300, maxWidth: 240, items: items, appearance: appearance), 240)
        XCTAssertEqual(reservation.reserve(contentWidth: 50, maxWidth: 240, items: [], appearance: appearance), 50)
    }
}
