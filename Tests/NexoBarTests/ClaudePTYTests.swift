import XCTest
import Darwin
@testable import NexoBar

final class ClaudePTYTests: XCTestCase {
    private func fixture(_ body: (URL) -> String) throws -> (root: URL, binary: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NexoBar/claude-pty-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let binary = root.appendingPathComponent("fake-claude")
        try ("#!/bin/sh\n" + body(root)).write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return (root, binary)
    }

    private func quote(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func testEnvironmentIsProcessLocalAndDoesNotRedirectClientState() {
        let initial = ["HOME": "/fixture/home", "PATH": "/fixture/bin", "CI": "1", "TERM": "dumb",
                       "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "KEEP": "yes"]
        let environment = ClaudePTY.environment(initial)
        XCTAssertEqual(environment["HOME"], initial["HOME"])
        XCTAssertEqual(environment["PATH"], initial["PATH"])
        XCTAssertEqual(environment["KEEP"], "yes")
        XCTAssertNil(environment["CI"])
        XCTAssertNil(environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"])
        XCTAssertEqual(environment["TERM"], "xterm-256color")
        XCTAssertEqual(environment["DISABLE_AUTOUPDATER"], "1")
        XCTAssertEqual(environment["BROWSER"], "/usr/bin/false")
        XCTAssertNil(environment["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(ClaudePTY.arguments, ["--safe-mode", "--strict-mcp-config", "--tools", "", "--ax-screen-reader",
                                           "--settings", #"{"disableRemoteControl":true,"remoteControlAtStartup":false}"#])
    }

    func testTrustAuthenticationAndSetupAbortWithoutSubmittingAnything() throws {
        for message in ["Do you trust the files in this folder?", "Not logged in · Run /login", "Permission required", "Choose a theme"] {
            let test = try fixture { root in
                "trap 'exit 0' INT TERM\nprintf '%s\\n' \(quote(message))\nIFS= read -r command\nprintf '%s' \"$command\" > \(quote(root.appendingPathComponent("submitted").path))\n"
            }
            defer { try? FileManager.default.removeItem(at: test.root) }
            XCTAssertThrowsError(try ClaudePTY.read(binary: test.binary, workingDirectory: test.root, timeout: 2)) { error in
                XCTAssertTrue(error is ClaudePTYError || error is AIReadError)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: test.root.appendingPathComponent("submitted").path))
            XCTAssertEqual(UsageCommand.runningProcessCount, 0)
        }
    }

    func testPromptWithoutAuthenticatedBannerNeverSubmitsUsage() throws {
        let test = try fixture { root in
            "trap 'exit 0' INT TERM\nprintf '$ '\nIFS= read -r command\nprintf '%s' \"$command\" > \(quote(root.appendingPathComponent("submitted").path))\n"
        }
        defer { try? FileManager.default.removeItem(at: test.root) }
        XCTAssertThrowsError(try ClaudePTY.read(binary: test.binary, workingDirectory: test.root, timeout: 0.2)) { error in
            guard case AIReadError.timedOut = error else { return XCTFail("Expected bounded startup wait") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: test.root.appendingPathComponent("submitted").path))
        XCTAssertEqual(UsageCommand.runningProcessCount, 0)
    }

    func testUsageLoadFailureIsSanitizedAndHasNoFallback() throws {
        let test = try fixture { root in
            "trap 'exit 0' INT TERM\nprintf 'Claude Code v2.1.309\\nClaude Max\\n$ '\nIFS= read -r command\nprintf '%s' \"$command\" > \(quote(root.appendingPathComponent("submitted").path))\nprintf '\\nFailed to load usage data: private fixture text\\n'\nwhile :; do sleep 1; done\n"
        }
        defer { try? FileManager.default.removeItem(at: test.root) }
        XCTAssertThrowsError(try ClaudePTY.read(binary: test.binary, workingDirectory: test.root, timeout: 3)) { error in
            guard let known = error as? ClaudePTYError else { return XCTFail("Expected sanitized quota failure") }
            XCTAssertEqual(known.message, "Claude Code não conseguiu carregar as cotas")
            XCTAssertFalse(known.message.contains("private"))
        }
        XCTAssertEqual(try String(contentsOf: test.root.appendingPathComponent("submitted"), encoding: .utf8), "/usage")
        XCTAssertEqual(UsageCommand.runningProcessCount, 0)
    }

    func testOnlyUsageIsSubmittedAndRefreshFinishesBeforeReturning() throws {
        let test = try fixture { root in
            """
            trap 'exit 0' INT TERM
            printf '%s\\n' "$@" > \(quote(root.appendingPathComponent("arguments").path))
            pwd > \(quote(root.appendingPathComponent("cwd").path))
            stty size > \(quote(root.appendingPathComponent("dimensions").path))
            printf 'Claude Code v2.1.309\\r\\nClaude Max\\r\\n$ '
            IFS= read -r command
            printf '%s' "$command" > \(quote(root.appendingPathComponent("submitted").path))
            printf '\\033[2J\\033[HCurrent session\\r\\n39%% 39%% used\\r\\nResets 12:50pm (America/Fortaleza)\\r\\nCurrent week (all models)\\r\\n41%% 41%% used\\r\\nResets Oct 28 at 1pm (America/Fortaleza)\\r\\nRefreshing...'
            sleep 1.2
            printf '\\033[2J\\033[HCurrent session\\r\\n40%% 40%% used\\r\\nResets 12:50pm (America/Fortaleza)\\r\\nCurrent week (all models)\\r\\n42%% 42%% used\\r\\nResets Oct 28 at 1pm (America/Fortaleza)'
            IFS= read -r unexpected
            printf '%s' "$unexpected" > \(quote(root.appendingPathComponent("unexpected").path))
            """
        }
        defer { try? FileManager.default.removeItem(at: test.root) }
        let now = ISO8601DateFormatter().date(from: "2026-10-23T15:00:00Z")!
        let reading = try ClaudePTY.read(binary: test.binary, workingDirectory: test.root, now: now, timeout: 6)
        XCTAssertEqual(reading.windows.map(\.usedPercent), [40, 42])
        XCTAssertEqual(reading.sampledAt, now)
        XCTAssertEqual(try String(contentsOf: test.root.appendingPathComponent("submitted"), encoding: .utf8), "/usage")
        XCTAssertEqual(try String(contentsOf: test.root.appendingPathComponent("arguments"), encoding: .utf8), ClaudePTY.arguments.joined(separator: "\n") + "\n")
        let reportedCWD = try String(contentsOf: test.root.appendingPathComponent("cwd"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let reportedAttributes = try FileManager.default.attributesOfItem(atPath: reportedCWD)
        let expectedAttributes = try FileManager.default.attributesOfItem(atPath: test.root.path)
        XCTAssertEqual(reportedAttributes[.systemNumber] as? NSNumber, expectedAttributes[.systemNumber] as? NSNumber)
        XCTAssertEqual(reportedAttributes[.systemFileNumber] as? NSNumber, expectedAttributes[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(try String(contentsOf: test.root.appendingPathComponent("dimensions"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "80 160")
        XCTAssertFalse(FileManager.default.fileExists(atPath: test.root.appendingPathComponent("unexpected").path))
        XCTAssertEqual(UsageCommand.runningProcessCount, 0)
    }

    func testOutputIsBoundedAndOwnedGroupIsRemoved() throws {
        let test = try fixture { _ in "exec /usr/bin/yes fixture\n" }
        defer { try? FileManager.default.removeItem(at: test.root) }
        XCTAssertThrowsError(try ClaudePTY.read(binary: test.binary, workingDirectory: test.root, timeout: 5)) { error in
            guard case AIReadError.excessiveOutput = error else { return XCTFail("Expected 512 KiB cap") }
        }
        XCTAssertEqual(UsageCommand.runningProcessCount, 0)
    }

    func testTimeoutKillsChildInOwnedProcessGroup() throws {
        let test = try fixture { root in
            "sleep 30 &\nprintf '%s' \"$!\" > \(quote(root.appendingPathComponent("child-pid").path))\nwait\n"
        }
        defer { try? FileManager.default.removeItem(at: test.root) }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try ClaudePTY.read(binary: test.binary, workingDirectory: test.root, timeout: 0.2)) { error in
            guard case AIReadError.timedOut = error else { return XCTFail("Expected timeout") }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
        let child = try XCTUnwrap(Int32(String(contentsOf: test.root.appendingPathComponent("child-pid"), encoding: .utf8)))
        // A briefly unreaped orphan may still exist, but it must no longer run.
        // SIGCONT cannot restart a killed child; wait briefly for init to reap it.
        let deadline = Date().addingTimeInterval(1)
        while kill(child, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(kill(child, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(UsageCommand.runningProcessCount, 0)
    }

    func testAppShutdownAlsoStopsTemporaryTerminal() throws {
        let test = try fixture { _ in "exec /bin/sleep 30\n" }
        defer { try? FileManager.default.removeItem(at: test.root) }
        let finished = expectation(description: "temporary terminal stopped")
        DispatchQueue.global().async {
            _ = try? ClaudePTY.read(binary: test.binary, workingDirectory: test.root, timeout: 10)
            finished.fulfill()
        }
        let deadline = Date().addingTimeInterval(2)
        while UsageCommand.runningProcessCount == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertGreaterThan(UsageCommand.runningProcessCount, 0)
        UsageCommand.terminateOwnedProcesses(finalShutdown: false)
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(UsageCommand.runningProcessCount, 0)
    }

    func testMissingFolderDoesNotStartAClient() {
        XCTAssertThrowsError(try ClaudePTY.read(binary: URL(fileURLWithPath: "/bin/sh"),
            workingDirectory: URL(fileURLWithPath: "/missing/nexobar-fixture-folder"))) { error in
            guard case ClaudePTYError.folderUnavailable = error else { return XCTFail("Expected selected-folder validation") }
        }
    }
}
