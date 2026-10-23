import XCTest
@testable import NexoBar

final class ClaudeUsageParserTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var now: Date { date("2026-10-23T15:00:00Z") }
    private let panel = """
    Current session
    40% 40% used
    Resets 12:50pm (America/Fortaleza)
    Current week (all models)
    42% 42% used
    Resets Oct 28 at 1pm (America/Fortaleza)
    Current week (Fable)
    0% 0% used
    Resets Oct 28 at 1pm (America/Fortaleza)
    What's contributing to your limits usage?
    Context 99% used
    Tokens 5000
    """

    func testNativeSectionsAndExplicitZeroExcludeContextStatistics() throws {
        let reading = try ClaudeUsageParser.parse(panel, now: now)
        XCTAssertEqual(reading.value, "40%")
        XCTAssertEqual(reading.windows.map(\.id), ["session", "weekly_all", "weekly_model_fable"])
        XCTAssertEqual(reading.windows.map(\.usedPercent), [40, 42, 0])
        XCTAssertEqual(reading.windows[0].resetsAt, date("2026-10-23T15:50:00Z"))
        XCTAssertEqual(reading.windows[1].resetsAt, date("2026-10-28T16:00:00Z"))
        XCTAssertTrue(reading.windows.allSatisfy { $0.durationMinutes == nil })
        XCTAssertEqual(reading.sampledAt, now)
    }

    func testWeeklyOnlyHasOneRealWindowAndHeadline() throws {
        let reading = try ClaudeUsageParser.parse("Current week (all models)\n0% used", now: now)
        XCTAssertEqual(reading.windows.count, 1)
        XCTAssertEqual(reading.windows[0].id, "weekly_all")
        XCTAssertEqual(reading.value, "0%")
    }

    func testModelOnlyNeverBecomesAccountHeadline() throws {
        let reading = try ClaudeUsageParser.parse("Current week (Opus)\n12.5% used", now: now)
        XCTAssertEqual(reading.value, "—")
        XCTAssertEqual(reading.windows[0].usedPercent, 12.5)
        XCTAssertEqual(reading.windows[0].id, "weekly_model_opus")
        XCTAssertEqual(reading.windows[0].name, "Semanal · Opus")
    }

    func testMissingPercentDoesNotFabricateZeroOrSession() throws {
        let reading = try ClaudeUsageParser.parse("Current session\nResets 12:50pm (America/Fortaleza)\nCurrent week (all models)\n20% used", now: now)
        XCTAssertEqual(reading.windows.map(\.id), ["weekly_all"])
        XCTAssertEqual(reading.value, "20%")
        XCTAssertThrowsError(try ClaudeUsageParser.parse("Current session\nResets 12:50pm (America/Fortaleza)", now: now))
    }

    func testFractionsBarsAndDuplicatePercent() throws {
        for line in ["0.25% used", "██░░ 0.25% 0.25% used", "[██░░] 0.25% used"] {
            let reading = try ClaudeUsageParser.parse("Current session\n" + line, now: now)
            XCTAssertEqual(reading.windows[0].usedPercent, 0.25)
        }
        for line in ["-1% used", "101% used", "1e2% used", "NaN% used", "12,5% used", "1% 2% used", "40%% used", "1% 1% 1% used", ".5% used"] {
            XCTAssertThrowsError(try ClaudeUsageParser.parse("Current session\n" + line, now: now), line)
        }
    }

    func testUnstableErrorsAuthenticationAndTrustCannotReuseOldQuotas() {
        for status in ["Loading usage data…", "Refreshing…", "Error fetching usage", "Please sign in", "/login", "Do you trust this folder?"] {
            XCTAssertThrowsError(try ClaudeUsageParser.parse(panel + "\n" + status, now: now), status)
        }
    }

    func testLabelsAreExclusiveAndModelsBounded() {
        for heading in ["Session", "Current week", "Usage this week", "Current session (5h)", "Current week (" + String(repeating: "A", count: 65) + ")"] {
            XCTAssertThrowsError(try ClaudeUsageParser.parse(heading + "\n10% used", now: now), heading)
        }
        XCTAssertThrowsError(try ClaudeUsageParser.parse("Extra usage\n50% used\nContext\n40% used", now: now))
        XCTAssertThrowsError(try ClaudeUsageParser.parse("Current session\n10% used\nCurrent session\n20% used", now: now))
    }

    func testUnknownAndImplausibleDatesPreservePercentWithoutInventingReset() throws {
        for reset in ["soon", "12:50pm (Unknown/Zone)", "12:50pm", "25:50 (America/Fortaleza)", "11pm (America/Fortaleza)"] {
            let reading = try ClaudeUsageParser.parse("Current session\n40% used\nResets " + reset, now: now)
            XCTAssertEqual(reading.windows[0].usedPercent, 40)
            XCTAssertNil(reading.windows[0].resetsAt, reset)
        }
        for reset in ["Nov 20 at 1pm (America/Fortaleza)", "Feb 31 at 1pm (America/Fortaleza)", "Oct 28 2025 at 1pm (America/Fortaleza)"] {
            let reading = try ClaudeUsageParser.parse("Current week (all models)\n40% used\nResets " + reset, now: now)
            XCTAssertNil(reading.windows[0].resetsAt, reset)
        }
    }

    func testSessionMidnightRolloverInExplicitTimezoneAnd24HourClock() throws {
        let beforeMidnight = date("2026-10-24T02:40:00Z")
        for clock in ["12:15am", "00:15", "tomorrow at 12:15 am"] {
            let reading = try ClaudeUsageParser.parse("Current session\n40% used\nResets \(clock) (America/Fortaleza)", now: beforeMidnight)
            XCTAssertEqual(reading.windows[0].resetsAt, date("2026-10-24T03:15:00Z"), clock)
        }
        let noon = try ClaudeUsageParser.parse("Current session\n40% used\nResets 12pm (America/Fortaleza)", now: date("2026-10-23T14:00:00Z"))
        XCTAssertEqual(noon.windows[0].resetsAt, date("2026-10-23T15:00:00Z"))
        let staleToday = try ClaudeUsageParser.parse("Current session\n40% used\nResets today at 00:15 (America/Fortaleza)", now: beforeMidnight)
        XCTAssertNil(staleToday.windows[0].resetsAt)
    }

    func testWeeklyDecemberJanuaryRolloverAndExplicitYear() throws {
        let endOfYear = date("2026-12-30T15:00:00Z")
        for reset in ["Jan 2 at 13:00", "January 2, 2027 at 1pm", "Jan 2 2027 at 1 pm"] {
            let reading = try ClaudeUsageParser.parse("Current week (all models)\n42% used\nResets \(reset) (America/Fortaleza)", now: endOfYear)
            XCTAssertEqual(reading.windows[0].resetsAt, date("2027-01-02T16:00:00Z"), reset)
        }
    }

    func testTimezonesUseTheRenderedZoneInsteadOfMachineZone() throws {
        let text = "Current session\n40% used\nResets 12:30pm (America/New_York)"
        let reading = try ClaudeUsageParser.parse(text, now: now)
        XCTAssertEqual(reading.windows[0].resetsAt, date("2026-10-23T16:30:00Z"))
    }

    func testANSIFrameRedrawReplacesOldValuesAndRefreshing() throws {
        var screen = ClaudeTerminalScreen()
        let old = panel.replacingOccurrences(of: "40%", with: "39%")
            .replacingOccurrences(of: "42%", with: "41%") + "\nRefreshing…"
        screen.feed(Data(old.replacingOccurrences(of: "\n", with: "\r\n").utf8))
        XCTAssertThrowsError(try ClaudeUsageParser.parse(screen.text, now: now))
        screen.feed(Data("\u{1b}[H\u{1b}[J".utf8))
        screen.feed(Data(panel.replacingOccurrences(of: "\n", with: "\r\n").utf8))
        let reading = try ClaudeUsageParser.parse(screen.text, now: now)
        XCTAssertEqual(reading.windows.map(\.usedPercent), [40, 42, 0])
        XCTAssertFalse(screen.text.contains("39%"))
        XCTAssertFalse(screen.text.contains("Refreshing"))
    }

    func testCursorUpEraseAndCarriageReturnDoNotConcatenateFrames() {
        var screen = ClaudeTerminalScreen(columns: 40, rows: 4)
        screen.feed(Data("Current session\r\n39% used\r\nRefreshing".utf8))
        screen.feed(Data("\u{1b}[2A\r\u{1b}[KCurrent session\r\n\u{1b}[2K40% used\r\n\u{1b}[K".utf8))
        XCTAssertEqual(screen.text, "Current session\n40% used")
        screen.feed(Data("\rhello\u{8}!\tX".utf8))
        XCTAssertTrue(screen.text.contains("hell!   X"))
    }

    func testAllByteChunkBoundariesPreserveUTF8AndEscapes() throws {
        let bytes = Array(("\u{1b}]0;discard this title\u{7}\u{1b}[31m" + panel.replacingOccurrences(of: "\n", with: "\r\n") + "\u{1b}[0m").utf8)
        var screen = ClaudeTerminalScreen()
        for byte in bytes { screen.feed(Data([byte])) }
        XCTAssertEqual(try ClaudeUsageParser.parse(screen.text, now: now).windows.map(\.usedPercent), [40, 42, 0])
        XCTAssertTrue(screen.text.contains("What's contributing"))
        XCTAssertFalse(screen.text.contains("discard this title"))
        var unicode = ClaudeTerminalScreen(columns: 40, rows: 2)
        for byte in "Semanal · █░ ação".utf8 { unicode.feed(Data([byte])) }
        XCTAssertEqual(unicode.text, "Semanal · █░ ação")
    }

    func testCursorMovesSaveRestoreAndClearModes() {
        var screen = ClaudeTerminalScreen(columns: 12, rows: 4)
        screen.feed(Data("abc\u{1b}[s\u{1b}[3;5HX\u{1b}[uD\u{1b}[2B\u{1b}[1GY\u{1b}[2CZ\u{1b}[1D!".utf8))
        XCTAssertEqual(screen.text, "abcD\n\nY  !X")
        screen.feed(Data("\u{1b}[1;2H\u{1b}[1J".utf8))
        XCTAssertTrue(screen.text.hasPrefix("  cD"))
        screen.feed(Data("\u{1b}[2J".utf8))
        XCTAssertEqual(screen.text, "")
        screen.feed(Data("\u{1b}[1;1Habc\u{1b}[2G\u{1b}[1K".utf8))
        XCTAssertEqual(screen.text, "  c")
    }

    func testStringsDiscardedAndScreenRemainsBounded() {
        var screen = ClaudeTerminalScreen(columns: 20, rows: 3)
        screen.feed(Data("\u{1b}Pignored\u{1b}\\\u{1b}]ignored\u{1b}\\visible".utf8))
        XCTAssertEqual(screen.text, "visible")
        screen.feed(Data(String(repeating: "\r\nxxxxxxxxxx", count: 10000).utf8))
        XCTAssertLessThanOrEqual(screen.text.utf8.count, 62)
        XCTAssertFalse(screen.text.contains("visible"))
        screen.feed(Data("\u{1b}[9999999999999999999999999999999999999999999999999999999999999999999999999H".utf8))
        XCTAssertLessThanOrEqual(screen.text.utf8.count, 62)
    }
}
