import XCTest
@testable import NexoBar

final class AISessionPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_584_000)

    func testOnlyExistingClientQueriesAreAllowed() {
        let kiro = AISessionPolicy.command(for: .kiro)!
        XCTAssertEqual(kiro.arguments, ["acp", "--agent-engine", "v3"])
        XCTAssertTrue(kiro.rpc)
        XCTAssertTrue(kiro.input.contains(#""method":"initialize""#))
        XCTAssertTrue(kiro.rpcFollowUp.contains(#""id":2,"method":"_kiro/account/getUsage""#))
        for text in [kiro.input, kiro.rpcFollowUp] {
            XCTAssertFalse(text.contains("session/"), "No session or prompt may be opened")
            XCTAssertTrue(text.hasSuffix("\n"))
        }
        XCTAssertEqual(AISessionPolicy.fallbackCommand(for: .kiro)?.arguments, ["chat", "--agent-engine", "v2", "--no-interactive", "/usage"])
        XCTAssertEqual(AISessionPolicy.fallbackCommand(for: .kiro)?.rpc, false)
        XCTAssertEqual(AISessionPolicy.command(for: .codex)?.rpcFollowUp,
                       "{\"method\":\"initialized\"}\n{\"id\":2,\"method\":\"account/rateLimits/read\",\"params\":null}\n")
        for id in [IndicatorID.codex, .copilot, .antigravity, .claude] { XCTAssertNil(AISessionPolicy.fallbackCommand(for: id)) }
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

    func testKiroV3FailureFallsBackToV2Only() throws {
        for failure in [AIReadError.unavailable, .malformed] {
            var ran: [[String]] = []
            let reading = try AIProviderIntegrations.read(.kiro, now: now,
                locate: { URL(fileURLWithPath: "/fixture/" + $0) },
                run: { command, _ in
                    ran.append(command.arguments)
                    if command.rpc { throw failure }
                    return "Credits (3191.50 of 5000 covered in plan), 63.8%"
                }, claudeQuery: { _ in throw AIReadError.unavailable })
            XCTAssertEqual(ran, [["acp", "--agent-engine", "v3"], ["chat", "--agent-engine", "v2", "--no-interactive", "/usage"]])
            XCTAssertEqual(reading.detail, "Kiro CLI /usage · créditos utilizados")
        }
        // Parse-level failure (no data) also falls back.
        var calls = 0
        _ = try AIProviderIntegrations.read(.kiro, now: now, locate: { URL(fileURLWithPath: "/fixture/" + $0) },
            run: { command, _ in
                calls += 1
                return command.rpc ? #"{"id":2,"result":{"success":true,"message":"Your plan is managed by admin"}}"# : "██ 40%"
            }, claudeQuery: { _ in throw AIReadError.unavailable })
        XCTAssertEqual(calls, 2)
    }

    func testKiroV3SuccessAndBlockingFailuresSkipV2() throws {
        let reading = try AIProviderIntegrations.read(.kiro, now: now, locate: { URL(fileURLWithPath: "/fixture/" + $0) },
            run: { command, _ in
                XCTAssertTrue(command.rpc, "v2 must not run after v3 success")
                return AIProvidersTests.kiroACPFixture
            }, claudeQuery: { _ in throw AIReadError.unavailable })
        XCTAssertTrue(reading.detail.hasPrefix("Kiro CLI v3"))
        for failure in [AIReadError.authentication, .rateLimited, .timedOut, .excessiveOutput] {
            var calls = 0
            XCTAssertThrowsError(try AIProviderIntegrations.read(.kiro, now: now, locate: { URL(fileURLWithPath: "/fixture/" + $0) },
                run: { _, _ in calls += 1; throw failure }, claudeQuery: { _ in throw AIReadError.unavailable })) {
                XCTAssertEqual($0 as? AIReadError, failure)
            }
            XCTAssertEqual(calls, 1)
        }
        var calls = 0
        XCTAssertThrowsError(try AIProviderIntegrations.read(.kiro, now: now, locate: { URL(fileURLWithPath: "/fixture/" + $0) },
            run: { _, _ in calls += 1; return #"{"id":2,"result":{"success":false,"message":"not logged in"}}"# },
            claudeQuery: { _ in throw AIReadError.unavailable })) { XCTAssertEqual($0 as? AIReadError, .authentication) }
        XCTAssertEqual(calls, 1)
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
