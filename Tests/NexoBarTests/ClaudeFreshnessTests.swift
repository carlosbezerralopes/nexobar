import XCTest
@testable import NexoBar

final class ClaudeFreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_584_000)
    private let organization = "00000000-0000-0000-0000-000000000001"

    private func fixtureHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NexoBar/claude-freshness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metadata = ["oauthAccount": ["organizationUuid": organization]]
        try JSONSerialization.data(withJSONObject: metadata).write(to: root.appendingPathComponent(".claude.json"))
        return root
    }

    private func cache(_ root: URL, name: String, json: String, observed: Date?, modified: Date,
                       endpoint: String? = nil, rawDate: String? = nil) throws {
        let directory = root.appendingPathComponent("Library/Application Support/Claude/Cache/Cache_Data")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = Data((endpoint ?? "https://claude.ai/api/organizations/\(organization)/usage").utf8)
        var header = Data(repeating: 0, count: 24)
        func store(_ value: UInt64, offset: Int, count: Int) {
            for index in 0..<count { header[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
        }
        store(0xfcfb6d1ba7725c30, offset: 0, count: 8)
        store(UInt64(key.count), offset: 12, count: 4)
        var bytes = header + key + Data(json.utf8)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"; formatter.timeZone = TimeZone(secondsFromGMT: 0)
        if let stamp = rawDate ?? observed.map({ formatter.string(from: $0) }) {
            bytes.append(Data("\0date:\(stamp)\0".utf8))
        }
        let path = directory.appendingPathComponent(name + "_0")
        try bytes.write(to: path)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path.path)
    }

    // Only the compression frame is substituted; key filtering, date extraction,
    // filesystem ordering and real quota parsing still execute against fixture files.
    private func inspect(_ root: URL, at date: Date? = nil) throws -> ClaudeUsageCache.Inspection {
        try ClaudeUsageCache.inspect(home: root, now: date ?? now) { payload in
            let json = payload.prefix { $0 != 0 }
            return (Data(json), json.count)
        }
    }

    func testHTTPObservationWinsOverFileModificationAndOldZero() throws {
        let root = try fixtureHome(); defer { try? FileManager.default.removeItem(at: root) }
        try cache(root, name: "rewritten-old-zero", json: #"{"five_hour":{"utilization":0}}"#,
                  observed: now.addingTimeInterval(-600), modified: now)
        try cache(root, name: "actual-newer-usage", json: #"{"five_hour":{"utilization":43}}"#,
                  observed: now.addingTimeInterval(-20), modified: now.addingTimeInterval(-200))
        let result = try inspect(root).reading()
        XCTAssertEqual(result.value, "43%")
        XCTAssertEqual(result.sampledAt, now.addingTimeInterval(-20))
    }

    func testMissingInvalidOrFutureHTTPDateCannotBecomeFreshFromMtime() throws {
        for (name, date, raw) in [("missing", nil as Date?, nil as String?),
                                   ("invalid", nil, "invalid"), ("future", now.addingTimeInterval(1), nil)] {
            let root = try fixtureHome(); defer { try? FileManager.default.removeItem(at: root) }
            try cache(root, name: name, json: #"{"five_hour":{"utilization":0}}"#,
                      observed: date, modified: now, rawDate: raw)
            let inspection = try inspect(root)
            XCTAssertEqual(inspection.matchingEntries, 1)
            XCTAssertEqual(inspection.decodedEntries, 1)
            XCTAssertEqual(inspection.datedEntries, 0)
            XCTAssertNil(inspection.latest)
            XCTAssertThrowsError(try inspection.reading())
        }
    }

    func testFreshZeroIsReportedOnlyWhenSourceExplicitlyHasZero() throws {
        let root = try fixtureHome(); defer { try? FileManager.default.removeItem(at: root) }
        try cache(root, name: "zero", json: #"{"five_hour":{"utilization":0},"seven_day":null}"#,
                  observed: now, modified: now)
        let result = try inspect(root).reading()
        XCTAssertEqual(result.value, "0%")
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows.first?.usedPercent, 0)
        XCTAssertEqual(result.sampledAt, now)
        for json in [#"{}"#, #"{"five_hour":null}"#, #"{"five_hour":{"utilization":null}}"#,
                     #"{"five_hour":{"utilization":false}}"#] {
            XCTAssertThrowsError(try AIUsageParser.claude(Data(json.utf8), capturedAt: now, now: now))
        }
    }

    func testOldObservationIsUnavailableEvenWithFreshMtime() throws {
        let root = try fixtureHome(); defer { try? FileManager.default.removeItem(at: root) }
        try cache(root, name: "expired", json: #"{"five_hour":{"utilization":0}}"#,
                  observed: now.addingTimeInterval(-ClaudeUsageCache.maximumAge), modified: now)
        let inspection = try inspect(root)
        XCTAssertTrue(inspection.latest?.isStale == true)
        XCTAssertThrowsError(try inspection.reading()) { error in
            guard case AIReadError.passiveCacheExpired = error else { return XCTFail("Expected cache freshness failure") }
        }
    }

    func testCacheFiltersOrganizationAndEndpointBeforeDecoding() throws {
        let root = try fixtureHome(); defer { try? FileManager.default.removeItem(at: root) }
        for endpoint in ["https://claude.ai/api/organizations/other/usage", "https://claude.ai/api/organizations/\(organization)/settings",
                         "https://example.invalid/api/organizations/\(organization)/usage"] {
            try cache(root, name: UUID().uuidString, json: #"{"five_hour":{"utilization":99}}"#,
                      observed: now, modified: now, endpoint: endpoint)
        }
        let result = try ClaudeUsageCache.inspect(home: root, now: now) { _ in
            XCTFail("Other endpoint bodies must never be decoded"); return nil
        }
        XCTAssertEqual(result.matchingEntries, 0)
        XCTAssertNil(result.latest)
    }

    func testResponseDateUsesRFC1123WithoutInventingMissingTime() {
        let stamp = "Wed, 21 Oct 2026 12:00:00 GMT"
        let expected = ISO8601DateFormatter().date(from: "2026-10-21T12:00:00Z")
        XCTAssertEqual(ClaudeUsageCache.responseDate("\0HTTP/1.1 200 OK\0Date: \(stamp)\0"), expected)
        XCTAssertNil(ClaudeUsageCache.responseDate("\0last-modified: \(stamp)\0"))
        XCTAssertNil(ClaudeUsageCache.responseDate("\0date: impossible\0"))
        let future = try? AIUsageParser.claude(Data(#"{"five_hour":{"utilization":0}}"#.utf8),
                                              capturedAt: now.addingTimeInterval(1), now: now)
        XCTAssertEqual(future?.isStale, true)
    }

    func testDiagnosticsContainOnlyQuotaAndFreshnessMetadata() throws {
        let root = try fixtureHome(); defer { try? FileManager.default.removeItem(at: root) }
        try cache(root, name: "quota", json: #"{"five_hour":{"utilization":0},"private_text":"must-never-escape"}"#,
                  observed: now.addingTimeInterval(-10), modified: now)
        let diagnostic = try inspect(root).diagnostic(now: now)
        XCTAssertTrue(diagnostic.contains("cache=recente"))
        XCTAssertTrue(diagnostic.contains("idade_s=10"))
        XCTAssertTrue(diagnostic.contains("uso_percent=0.00"))
        for value in [root.path, organization, "private_text", "must-never-escape", "date:", "claude.ai"] {
            XCTAssertFalse(diagnostic.contains(value))
        }
    }

    func testNewLocalQuotaIsReadImmediatelyAfterFailureAndPersistedBackoff() async throws {
        final class Fetcher: @unchecked Sendable {
            let lock = NSLock(); var calls = 0
            func fetch(_ id: IndicatorID, _ date: Date) throws -> IndicatorReading {
                lock.lock(); calls += 1; let current = calls; lock.unlock()
                if current == 1 { throw AIReadError.passiveCacheUnavailable }
                return try AIUsageParser.claude(Data(#"{"five_hour":{"utilization":32}}"#.utf8), capturedAt: date, now: date)
            }
        }
        let root = try fixtureHome(); defer { try? FileManager.default.removeItem(at: root) }
        let retry = now.addingTimeInterval(1800).timeIntervalSinceReferenceDate
        let saved = try JSONSerialization.data(withJSONObject: ["failures": ["claude": 8], "retryAfter": ["claude": retry]])
        try saved.write(to: root.appendingPathComponent("ai-poll-state.json"))
        let fetcher = Fetcher()
        let provider = AIProviders(fetch: { id, date in try fetcher.fetch(id, date) }, stateDirectory: root)
        let missing = await provider.refresh(id: .claude, at: now)
        XCTAssertNil(missing.sampledAt)
        XCTAssertTrue(missing.windows.isEmpty)
        XCTAssertEqual(missing.value, "—")
        let recovered = await provider.refresh(id: .claude, at: now.addingTimeInterval(1))
        XCTAssertEqual(recovered.value, "32%")
        XCTAssertEqual(fetcher.calls, 2)
    }
}
