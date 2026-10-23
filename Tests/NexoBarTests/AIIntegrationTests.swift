import XCTest
import SQLite3
@testable import NexoBar

final class AIIntegrationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_584_000)
    func testProviderCatalogMatchesWindowsBaseline() {
        XCTAssertEqual(Set(IndicatorID.ai.map(\.rawValue)), Set(["claude","codex","kiro","cursor","grok","copilot","opencode","antigravity","glm"]))
    }
    func testCursorAutoAndAPIStaySeparate() throws {
        let data = #"{"individualUsage":{"plan":{"autoPercentUsed":0,"apiPercentUsed":71,"totalPercentUsed":30}}}"#
        let windows = try CursorUsage.windows(fromJSON: data)
        let reading = try AIProviderIntegrations.converted(.cursor, windows, headline: CursorUsage.headlineID(in: windows), now: now, source: "fixture")
        XCTAssertEqual(reading.value, "0%")
        XCTAssertEqual(reading.windows.map(\.usedPercent), [0,71])
        XCTAssertThrowsError(try CursorUsage.windows(fromJSON: #"{"individualUsage":{"plan":{"autoPercentUsed":true}}}"#))
    }
    func testGrokProductAndFreshWeeklyReset() throws {
        let reading = try GrokUsage.windows(creditsJSON: #"{"config":{"creditUsagePercent":12.5,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-10-20T00:00:00Z","end":"2026-10-27T00:00:00Z"}}}"#)
        XCTAssertEqual(reading.first?.usedFraction, 0.125)
        XCTAssertEqual(reading.first?.duration, 604800)
        XCTAssertEqual(try GrokUsage.windows(creditsJSON: #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-10-27T00:00:00Z"}}}"#).first?.usedFraction, 0)
    }
    func testCopilotEntitlementIsNotUnreportedZero() throws {
        XCTAssertThrowsError(try GitHubCopilotUsage.windows(from: Data(#"{"quota_snapshots":{"premium_interactions":{"entitlement":100}}}"#.utf8)))
        let windows = try GitHubCopilotUsage.windows(from: Data(#"{"quota_snapshots":{"premium_interactions":{"entitlement":100,"remaining":63},"completions":{"unlimited":true}}}"#.utf8))
        XCTAssertEqual(windows.count,1)
        XCTAssertEqual(windows[0].usedFraction,0.37)
    }
    func testOpenCodeThreeWindows() throws {
        let windows = try OpenCodeUsage.windows(fromJSON: #"{"usage":{"rolling":{"percent":21},"weekly":{"percent":22},"monthly":{"percent":23}}}"#)
        XCTAssertEqual(windows.map(\.id), ["rolling","weekly","monthly"])
        XCTAssertEqual(windows.map(\.usedFraction), [0.21,0.22,0.23])
        XCTAssertThrowsError(try OpenCodeUsage.windows(fromJSON: #"{"usage":{"rolling":{"percent":true}}}"#))
    }
    func testGLMEnvelopeAndWindowIdentity() throws {
        let data = Data(#"{"code":200,"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":42},{"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":18}]}}"#.utf8)
        XCTAssertEqual(try GLMUsage.parse(data).windows.map(\.id), ["session","weekly"])
        XCTAssertThrowsError(try GLMUsage.parse(Data(#"{"code":401,"success":false}"#.utf8)))
    }
    func testKiroCreditsPreserveOfficialPercentAndUTC() throws {
        let result = try AIUsageParser.kiro("Monthly credits ███ 61% (60.5 of 100 covered in plan) resets on 2026-11-01", now: now)
        XCTAssertEqual(result.windows[0].usedPercent,61)
        XCTAssertEqual(result.windows[0].used,60.5)
        XCTAssertEqual(result.windows[0].limit,100)
        XCTAssertEqual(result.windows[0].resetsAt, ISO8601DateFormatter().date(from:"2026-11-01T00:00:00Z"))
        XCTAssertEqual(result.windows[0].durationMinutes,44640)
    }
    func testKiroOfflineOverageIsNotDoubleCounted() throws {
        let data = Data(#"{"usageBreakdownList":[{"resourceType":"CREDIT","currentUsageWithPrecision":135.5,"usageLimit":100,"currentOveragesWithPrecision":35.5,"overageCap":60}],"overageConfiguration":{"overageStatus":"ENABLED"}}"#.utf8)
        let limits = try KiroLimits.parse(data)
        XCTAssertEqual(limits.planUsed,100)
        XCTAssertEqual(limits.overageUsed,35.5)
    }
    func testAntigravityRemainingBecomesUsedOnlyOnce() throws {
        let text = "Quota:\n Gemini Models Five Hour Limit Remaining 80% 2026-11-01T00:00:00Z\n Claude and GPT models Weekly Limit Remaining 0% 2026-11-02T00:00:00Z"
        let reading = try AIProviderIntegrations.antigravityCLI(text, now:now)
        XCTAssertEqual(reading.windows.map(\.usedPercent),[20,100])
        XCTAssertThrowsError(try AIProviderIntegrations.antigravityCLI("Quota:\n Gemini Models Five Hour Limit Remaining 101% 2026-11-01T00:00:00Z",now:now))
    }
    func testCodexSupplementalBucketDoesNotChangeHeadline() throws {
        let text = #"{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":11}},"spark":{"primary":{"usedPercent":88}}}}}"#
        let reading = try AIUsageParser.codex(text, now:now)
        XCTAssertEqual(reading.value,"11%")
        XCTAssertEqual(reading.windows.map(\.usedPercent),[11,88])
    }
    func testSQLiteReadsLiveWALAndEncodesQuestionMark() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NexoBar/ai-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("state?#.sqlite")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path,&writer),SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer,"PRAGMA journal_mode=WAL; CREATE TABLE fixture(value TEXT); INSERT INTO fixture VALUES('newest');",nil,nil,nil),SQLITE_OK)
        guard let reader = SQLiteStore.open(url) else { return XCTFail("Read-only WAL unavailable") }
        defer { sqlite3_close(reader) }
        XCTAssertEqual(sqlite3_db_readonly(reader,nil),1)
        XCTAssertEqual(SQLiteStore.rows(in:reader,sql:"SELECT value FROM fixture"),["newest"])
        XCTAssertNotEqual(sqlite3_exec(reader,"INSERT INTO fixture VALUES('forbidden')",nil,nil,nil),SQLITE_OK)
    }
    func testRefreshDifferentProvidersCompletesIndependently() async {
        let gate = DispatchSemaphore(value:0)
        let provider = AIProviders(fetch:{ id,date in
            if id == .kiro { _ = gate.wait(timeout:.now()+2) }
            return IndicatorReading(id:id,value:"12%",detail:"fixture",sampledAt:date)
        })
        let slow = Task { await provider.refresh(id:.kiro) }
        try? await Task.sleep(nanoseconds:30_000_000)
        let start = ProcessInfo.processInfo.systemUptime
        let fast = await provider.refresh(id:.codex)
        XCTAssertEqual(fast.id,.codex)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start,0.5)
        gate.signal(); _ = await slow.value
    }
    func testBackoffSurvivesRestartWithoutCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NexoBar/poll-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:root) }
        let provider = AIProviders(fetch:{ _,_ in throw AIReadError.rateLimited },stateDirectory:root)
        _ = await provider.refresh(id:.kiro,at:now)
        let restarted = AIProviders(fetch:{ _,_ in XCTFail("Backoff must prevent this read"); throw AIReadError.unavailable },stateDirectory:root)
        let reading = await restarted.refresh(id:.kiro,at:now.addingTimeInterval(100))
        XCTAssertTrue(reading.detail.contains("pausa"))
        let bytes = try Data(contentsOf:root.appendingPathComponent("ai-poll-state.json"))
        XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains("accessToken"))
    }
    func testResetWatcherEachWindowOnceAndNoStartupAlert() {
        let watcher = AIQuotaResetWatcher()
        func reading(_ at: Date, _ used: Double, _ reset: Date, stale: Bool = false) -> IndicatorReading {
            IndicatorReading(id:.codex,value:"fixture",detail:"fixture",sampledAt:at,isStale:stale,windows:[
                QuotaWindow(name:"Principal",usedPercent:used,resetsAt:reset,id:"primary"),
                QuotaWindow(name:"Semanal",usedPercent:used,resetsAt:reset,id:"secondary"),
                QuotaWindow(name:"Spark",usedPercent:used,resetsAt:reset,id:"spark.primary")])
        }
        let before = reading(now.addingTimeInterval(-2),60,now.addingTimeInterval(-1))
        let after = reading(now,0,now.addingTimeInterval(3600))
        XCTAssertTrue(watcher.observe(before,now:now).isEmpty)
        XCTAssertEqual(watcher.observe(after,now:now).map(\.windowID),["primary","secondary"])
        XCTAssertTrue(watcher.observe(after,now:now).isEmpty)
        XCTAssertTrue(watcher.observe(reading(now.addingTimeInterval(1),50,now.addingTimeInterval(3600)),now:now.addingTimeInterval(1)).isEmpty)
        let restarted = AIQuotaResetWatcher()
        XCTAssertTrue(restarted.observe(reading(now.addingTimeInterval(-2),80,now.addingTimeInterval(-1),stale:true),now:now).isEmpty)
        XCTAssertTrue(restarted.observe(after,now:now).isEmpty)
    }
    func testResetWatcherNoCorrectionBeforeDeadlineOrTinyUse() {
        let watcher = AIQuotaResetWatcher()
        let before = IndicatorReading(id:.kiro,value:"60%",detail:"fixture",sampledAt:now,windows:[QuotaWindow(name:"Créditos",usedPercent:60,resetsAt:now.addingTimeInterval(300),id:"credits")])
        var after = before; after.sampledAt = now.addingTimeInterval(1); after.windows[0].usedPercent = 0
        XCTAssertTrue(watcher.observe(before,now:now).isEmpty)
        XCTAssertTrue(watcher.observe(after,now:now.addingTimeInterval(1)).isEmpty)
    }

    func testPollStorageOmitsActivityDetailsAndRestrictsPermissions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NexoBar/privacy-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:root) }
        let provider = AIProviders(fetch:{ id,date in
            var reading = IndicatorReading(id:id,value:"12%",detail:"fixture",sampledAt:date)
            reading.activity = AIActivitySummary(state:"working",summary:"fixture",detail:"private-project-fixture")
            return reading
        },stateDirectory:root)
        _ = await provider.refresh(id:.claude,at:now)
        let url = root.appendingPathComponent("ai-poll-state.json")
        XCTAssertFalse(String(decoding:try Data(contentsOf:url),as:UTF8.self).contains("private-project-fixture"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
    }

    func testClaudeForwardCompatibleLimitsMergeOnlyKnownAliases() throws {
        let data = Data(#"{"limits":[{"kind":"session","percent":0},{"kind":"weekly_scoped","percent":27},{"kind":"unknown_weekly_offer","percent":27}],"five_hour":{"utilization":98},"seven_day":{"utilization":27}}"#.utf8)
        let reading = try AIUsageParser.claude(data,capturedAt:now,now:now)
        XCTAssertEqual(reading.value,"0%")
        XCTAssertEqual(reading.windows.count,4)
        XCTAssertNil(reading.windows.first { $0.id == "unknown_weekly_offer" }?.durationMinutes)
        XCTAssertEqual(reading.windows.first { $0.id == "weekly_scoped" }?.durationMinutes,10080)
        XCTAssertNotNil(reading.windows.first { $0.id == "seven_day" })
    }

}
