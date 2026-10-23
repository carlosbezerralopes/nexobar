import XCTest
@testable import NexoBar

final class AISessionPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_584_000)

    func testOnlyExistingClientQueriesAreAllowed() {
        XCTAssertEqual(AISessionPolicy.command(for: .kiro)?.arguments, ["chat", "--no-interactive", "/usage"])
        XCTAssertEqual(AISessionPolicy.command(for: .antigravity)?.arguments, ["--print", "/usage"])
        XCTAssertEqual(AISessionPolicy.command(for: .codex)?.arguments, ["app-server"])
        XCTAssertEqual(AISessionPolicy.command(for: .codex)?.rpc, true)
        let copilot = AISessionPolicy.command(for: .copilot)!
        XCTAssertEqual(copilot.arguments.prefix(4), ["api", "--hostname", "github.com", "copilot_internal/user"])
        for id in [IndicatorID.claude, .cursor, .grok, .opencode, .glm] {
            XCTAssertNil(AISessionPolicy.command(for: id))
        }
    }

    func testUnavailableProvidersNeverInspectClientsOrCredentials() {
        for id in [IndicatorID.cursor, .grok, .opencode, .glm] {
            XCTAssertThrowsError(try AIProviderIntegrations.read(id, now: now,
                locate: { _ in XCTFail("No client query supported"); return nil },
                run: { _, _ in XCTFail("No fallback may run"); return "" },
                claudeQuery: { _ in XCTFail("Wrong provider cache"); throw AIReadError.unavailable }))
        }
    }

    func testClientFailureHasNoSnapshotTokenOrBridgeFallback() {
        for id in [IndicatorID.codex, .kiro, .copilot, .antigravity] {
            var calls = 0
            XCTAssertThrowsError(try AIProviderIntegrations.read(id, now: now,
                locate: { URL(fileURLWithPath: "/fixture/" + $0) },
                run: { _, _ in calls += 1; throw AIReadError.authentication },
                claudeQuery: { _ in XCTFail("No cache fallback"); throw AIReadError.unavailable }))
            XCTAssertEqual(calls, 1)
        }
    }

    func testClaudeQueryReturnsFreshResultWithoutFallback() throws {
        let fresh = IndicatorReading(id: .claude, value: "12%", detail: "native usage fixture", sampledAt: now)
        let reading = try AIProviderIntegrations.read(.claude, now: now,
            locate: { _ in XCTFail("Injected query owns native command"); return nil },
            run: { _, _ in XCTFail("No extra query outside native usage adapter"); return "" },
            claudeQuery: { _ in fresh })
        XCTAssertEqual(reading, fresh)
        var stale = fresh; stale.isStale = true
        XCTAssertThrowsError(try AIProviderIntegrations.read(.claude, now: now,
            locate: { _ in XCTFail("No fallback"); return nil },
            run: { _, _ in XCTFail("No fallback"); return "" }, claudeQuery: { _ in stale }))
    }

    func testCopilotUsesPayloadWithoutExportingAuthentication() throws {
        let result = try AIProviderIntegrations.read(.copilot, now: now,
            locate: { _ in URL(fileURLWithPath: "/fixture/gh") },
            run: { command, _ in
                XCTAssertEqual(command.binary, "gh")
                XCTAssertFalse(command.arguments.contains("auth"))
                return #"{"quota_snapshots":{"premium_interactions":{"entitlement":100,"remaining":63}}}"#
            }, claudeQuery: { _ in throw AIReadError.unavailable })
        XCTAssertEqual(result.value, "37%")
        XCTAssertEqual(result.windows.first?.used, 37)
        XCTAssertEqual(result.windows.first?.limit, 100)
    }

    func testNoninteractiveEnvironmentDisablesPromptsAndBrowser() {
        let env = AISessionPolicy.nonInteractiveEnvironment(["PATH": "/fixture", "EXISTING": "kept"])
        XCTAssertEqual(env["GH_PROMPT_DISABLED"], "1")
        XCTAssertEqual(env["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(env["BROWSER"], "/usr/bin/false")
        XCTAssertEqual(env["GH_BROWSER"], "/usr/bin/false")
        XCTAssertEqual(env["EXISTING"], "kept")
    }

    func testLegacyQuotaIsNeverRestoredAfterFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NexoBar/legacy-poll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = IndicatorReading(id: .codex, value: "99%", detail: "removed direct source", sampledAt: now,
            windows: [QuotaWindow(name: "Principal", usedPercent: 99)])
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old))
        let state = try JSONSerialization.data(withJSONObject: ["last": [encoded], "failures": [:], "retryAfter": [:]])
        try state.write(to: root.appendingPathComponent("ai-poll-state.json"))
        let providers = AIProviders(fetch: { _, _ in throw AIReadError.authentication }, stateDirectory: root)
        let result = await providers.refresh(id: .codex, at: now)
        XCTAssertEqual(result.value, "—")
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertNil(result.sampledAt)
        let saved = try Data(contentsOf: root.appendingPathComponent("ai-poll-state.json"))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("removed direct source"))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("99%"))
    }

    func testRuntimeHasNoDirectCredentialLoaders() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = project.appendingPathComponent("Sources/NexoBar")
        let prohibited = ["SecItemCopyMatching", "Claude Code-credentials", "cursorAuth/accessToken", "auth_kv",
                          "gh/hosts.yml", ".grok/auth.json", "GLMCredentials", "OpenCodeCredentials", "HTTPUsage"]
        for name in ["AIProviderIntegrations.swift", "AIProviders.swift", "AIProviderParsers.swift", "AISessionPolicy.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            for marker in prohibited { XCTAssertFalse(text.contains(marker), "\(name): \(marker)") }
        }
        let integrations = try String(contentsOf: sources.appendingPathComponent("AIProviderIntegrations.swift"), encoding: .utf8)
        XCTAssertFalse(integrations.contains("AIAntigravityBridge.read"))
        XCTAssertFalse(integrations.contains("codexSnapshot"))
    }
}
