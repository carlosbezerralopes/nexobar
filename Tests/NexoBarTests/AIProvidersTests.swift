import XCTest
@testable import NexoBar

final class AIProvidersTests: XCTestCase {
    func testClosingAppStopsOwnedQueriesWithoutWaitingForTimeout() {
        let finished = expectation(description: "owned query terminated")
        DispatchQueue.global().async {
            _ = try? UsageCommand.run(binary: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 20)
            finished.fulfill()
        }
        let deadline = Date().addingTimeInterval(2)
        while UsageCommand.runningProcessCount == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertGreaterThan(UsageCommand.runningProcessCount, 0)
        UsageCommand.terminateOwnedProcesses(finalShutdown: false)
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(UsageCommand.runningProcessCount, 0)
    }
    let now = Date(timeIntervalSince1970: 1_792_584_000)

    func testCodexUsedWindowsAndResetAreNotInverted() throws {
        let reading = try AIUsageParser.codex(#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":23,"windowDurationMins":300,"resetsAt":1792585000},"secondary":{"usedPercent":0,"windowDurationMins":10080}}}}"#, now: now)
        XCTAssertEqual(reading.value, "23%")
        XCTAssertEqual(reading.windows.map(\.usedPercent), [23, 0])
        XCTAssertEqual(reading.windows[0].resetsAt, Date(timeIntervalSince1970: 1_792_585_000))
        XCTAssertNil(reading.windows[1].resetsAt)
    }
    func testCodexRejectsMissingBooleanAndNegativeUsage() {
        for used in ["null", "true", "-1"] {
            XCTAssertThrowsError(try AIUsageParser.codex("{\"id\":2,\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":\(used)}}}}", now: now))
        }
        XCTAssertThrowsError(try AIUsageParser.codex(#"{"id":2,"result":{"rateLimitsByLimitId":{"spark":{"primary":{"usedPercent":90}}}}}"#, now: now))
    }
    func testCodexUsesAccountBucketAndDoesNotPromoteSecondary() throws {
        let text = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","secondary":{"usedPercent":17,"windowDurationMins":10080}}}}}"#
        let result = try AIUsageParser.codex(text, now: now)
        XCTAssertEqual(result.value, "—")
        XCTAssertEqual(result.windows[0].usedPercent, 17)
        XCTAssertEqual(result.windows[0].name, "Semanal")
        XCTAssertThrowsError(try AIUsageParser.codex(#"{"id":2,"result":{"rateLimits":{"limitId":"spark","primary":{"usedPercent":99}}}}"#, now: now))
    }
    func testClaudeDoesNotPromoteModelOrWeeklyToSession() throws {
        let result = try AIUsageParser.claude(Data(#"{"seven_day_sonnet":{"utilization":42}}"#.utf8), capturedAt: now, now: now)
        XCTAssertEqual(result.value, "—")
        XCTAssertEqual(result.windows[0].usedPercent, 42)
    }
    func testKiroExplicitZeroEmptyBar() throws {
        XCTAssertEqual(try AIUsageParser.kiro("Monthly credits ░░░░ 0%", now: now).value, "0%")
    }
    func testCodexErrorDoesNotLeakProviderText() {
        XCTAssertThrowsError(try AIUsageParser.codex(#"{"id":2,"error":{"code":429,"message":"rate limit private data"}}"#, now: now)) {
            XCTAssertEqual(($0 as? AIReadError)?.message, "Provedor limitou consultas; aguardando")
        }
    }
    func testClaudeStaleTimestampAndNullWindow() throws {
        let input = Data(#"{"five_hour":{"utilization":14,"resets_at":"2026-10-21T20:00:00.000Z"},"seven_day":null,"seven_day_sonnet":{"utilization":120}}"#.utf8)
        let old = now.addingTimeInterval(-3600)
        let result = try AIUsageParser.claude(input, capturedAt: old, now: now)
        XCTAssertEqual(result.value, "14%")
        XCTAssertEqual(result.sampledAt, old)
        XCTAssertTrue(result.isStale)
        XCTAssertEqual(result.windows.count, 2)
        XCTAssertEqual(result.windows[1].usedPercent, 120)
        XCTAssertNotNil(result.windows[0].resetsAt)
    }
    func testKiroPercentWinsAndBonusKeepsIndependentUnits() throws {
        let result = try AIUsageParser.kiro("\u{001b}[32mEstimated Usage | KIRO PRO\nMonthly credits ███ 61% (60.5 of 100 covered in plan) resets on 2026-11-01\nBonus credits: 2/20 expires in 3 days", now: now)
        XCTAssertEqual(result.value, "61%")
        XCTAssertEqual(result.windows[0].usedPercent, 61)
        XCTAssertEqual(result.windows[1].usedPercent, 10)
        XCTAssertNotNil(result.windows[0].resetsAt)
        XCTAssertNotNil(result.windows[1].resetsAt)
        XCTAssertTrue(result.windows[0].detail.contains("60.5"))
    }
    func testKiroCreditsFallbackUnknownAndInvalidDate() throws {
        let result = try AIUsageParser.kiro("Estimated Usage (150 of 100 covered) resets on 2026-02-31", now: now)
        XCTAssertEqual(result.value, "150%")
        XCTAssertNil(result.windows[0].resetsAt)
        XCTAssertThrowsError(try AIUsageParser.kiro("Plan: KIRO PRO", now: now))
        XCTAssertThrowsError(try AIUsageParser.kiro("login required", now: now))
    }
    func testKiroMonthDayResetRollsYear() throws {
        let format = ISO8601DateFormatter()
        let december = format.date(from: "2026-12-20T12:00:00Z")!
        let result = try AIUsageParser.kiro("██ 50% resets on 01/01", now: december)
        XCTAssertEqual({ var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c.component(.year, from: result.windows[0].resetsAt!) }(), 2027)
    }
    func testRefreshFailureDiscardsQuotaAndHonorsBackoff() async {
        final class Fake: @unchecked Sendable {
            let lock = NSLock(); var calls = 0
            func fetch(_ id: IndicatorID, _ now: Date) throws -> IndicatorReading {
                lock.lock(); calls += 1; let number = calls; lock.unlock()
                if number <= 3 { return IndicatorReading(id: id, value: "42%", detail: "fixture", sampledAt: now) }
                throw AIReadError.rateLimited
            }
        }
        let fake = Fake()
        let provider = AIProviders(fetch: { id, date in try fake.fetch(id, date) })
        _ = await provider.refresh(ids: [.claude, .codex, .kiro], at: now)
        let result = await provider.refresh(ids: [.claude, .codex, .kiro], at: now.addingTimeInterval(300))
        XCTAssertEqual(result.map(\.value), ["—", "—", "—"])
        XCTAssertTrue(result.allSatisfy { $0.windows.isEmpty })
        XCTAssertTrue(result.allSatisfy { $0.sampledAt == nil })
        _ = await provider.refresh(ids: [.claude, .codex, .kiro], at: now.addingTimeInterval(301))
        XCTAssertEqual(fake.calls, 7) // Claude rereads local cache; Codex/Kiro retain network backoff.
    }
    func testKiroThreeFailuresPauseThirtyMinutes() async {
        final class Counter: @unchecked Sendable {
            let lock = NSLock(); var kiro = 0
            func fetch(_ id: IndicatorID, _ now: Date) throws -> IndicatorReading {
                if id == .kiro { lock.lock(); kiro += 1; lock.unlock() }
                throw AIReadError.unavailable
            }
        }
        let counter = Counter(); let provider = AIProviders(fetch: { id, date in try counter.fetch(id, date) })
        for offset in [0.0, 61, 182, 500, 1500] { _ = await provider.refresh(at: now.addingTimeInterval(offset)) }
        XCTAssertEqual(counter.kiro, 3)
        _ = await provider.refresh(at: now.addingTimeInterval(1983))
        XCTAssertEqual(counter.kiro, 4)
    }

    // Subprocess tests use only OS tools as fixtures; never execute authenticated CLIs.
    func testSubprocessBothStreamsAndOutputBound() throws {
        let result = try UsageCommand.run(binary: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo fixture; echo diagnostic >&2"])
        XCTAssertTrue(result.contains("fixture")); XCTAssertTrue(result.contains("diagnostic"))
        XCTAssertThrowsError(try UsageCommand.run(binary: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], timeout: 2)) {
            guard case AIReadError.excessiveOutput = $0 else { return XCTFail("Expected bounded output") }
        }
    }
    func testSubprocessTimeoutTerminatesGroup() {
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try UsageCommand.run(binary: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30 & wait"], timeout: 0.1)) {
            guard case AIReadError.timedOut = $0 else { return XCTFail("Expected timeout") }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }
}
