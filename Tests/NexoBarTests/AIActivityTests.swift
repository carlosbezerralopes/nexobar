import XCTest
import SQLite3
import Darwin
@testable import NexoBar

final class AIActivityTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_584_000)
    func testCursorRequiresLiveInstanceAndCheckpointFromItsLaunch() {
        let value = AIActivity.CursorMetadata(unfinishedAt: now.addingTimeInterval(-3600), checkpointAt: now.addingTimeInterval(-5))
        XCTAssertEqual(AIActivity.cursorState(value, launchedAt: now.addingTimeInterval(-60), now: now)?.state, "working")
        XCTAssertNil(AIActivity.cursorState(value, launchedAt: nil, now: now))
        XCTAssertNil(AIActivity.cursorState(value, launchedAt: now, now: now))
        var stale = value; stale.checkpointAt = now.addingTimeInterval(-901)
        XCTAssertNil(AIActivity.cursorState(stale, launchedAt: now.addingTimeInterval(-4000), now: now))
    }
    func testCursorExplicitWaitPersistsOnlyInCurrentInstanceAndSkipsSubagents() {
        var waiting = AIActivity.CursorMetadata(blocking: true, updatedAt: now.addingTimeInterval(-3600))
        XCTAssertEqual(AIActivity.cursorState(waiting, launchedAt: now.addingTimeInterval(-7200), now: now)?.state, "waiting")
        XCTAssertNil(AIActivity.cursorState(waiting, launchedAt: now.addingTimeInterval(-60), now: now))
        waiting.isSubagent = true
        XCTAssertNil(AIActivity.cursorState(waiting, launchedAt: now.addingTimeInterval(-7200), now: now))
        waiting.isSubagent = false; waiting.archived = true
        XCTAssertNil(AIActivity.cursorState(waiting, launchedAt: now.addingTimeInterval(-7200), now: now))
    }
    func testCursorSQLProjectsFlagsAndDoesNotExportConversationFields() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("state.vscdb")
        var writer: OpaquePointer?; XCTAssertEqual(sqlite3_open(database.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "CREATE TABLE composerHeaders(value TEXT, isSubagent INTEGER, isArchived INTEGER, recency INTEGER)", nil,nil,nil), SQLITE_OK)
        let stamp = now.timeIntervalSince1970 * 1000
        let rows: [[String: Any]] = [
            ["unfinishedRunAt":stamp-1000,"conversationCheckpointLastUpdatedAt":stamp,"name":"private-name-fixture","content":"private-prompt-fixture"],
            ["hasBlockingPendingActions":true,"lastUpdatedAt":stamp]
        ]
        for (index,row) in rows.enumerated() {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self).replacingOccurrences(of:"'",with:"''")
            XCTAssertEqual(sqlite3_exec(writer, "INSERT INTO composerHeaders VALUES('\(json)',\(index),0,\(index))",nil,nil,nil),SQLITE_OK)
        }
        let reading = AIActivity.readCursor(store: database, launchedAt: now.addingTimeInterval(-10), now: now)
        XCTAssertEqual(reading.state,"working")
        XCTAssertFalse((reading.detail ?? "").contains("private"))
    }
    func testGrokTurnCompletionWinsOverStopHooksAndUnknownIsNotBusy() {
        let ongoing = data([grok("user_message_chunk"),grok("agent_thought_chunk")])
        XCTAssertEqual(AIActivity.grokState(inTail:ongoing,modified:now,now:now,headless:false)?.state,"working")
        let completed = data([grok("agent_message_chunk"),grok("turn_completed"),grok("hook_execution")])
        XCTAssertEqual(AIActivity.grokState(inTail:completed,modified:now,now:now,headless:true)?.state,"idle")
        XCTAssertNil(AIActivity.grokState(inTail:data([grok("new_unknown_event")]),modified:now,now:now,headless:true))
        XCTAssertNil(AIActivity.grokState(inTail:data([grok("hook_execution")]),modified:now,now:now,headless:true))
    }
    func testGrokTUIExpiresWhileHeadlessNeedsNativeSessionAssociation() {
        let old = now.addingTimeInterval(-46)
        XCTAssertNil(AIActivity.grokState(inTail:data([grok("agent_message_chunk")]),modified:old,now:now,headless:false))
        XCTAssertEqual(AIActivity.grokState(inTail:data([grok("agent_message_chunk")]),modified:old,now:now,headless:true)?.state,"working")
        XCTAssertNil(AIActivity.grokState(inTail:data([grok("agent_message_chunk")]),modified:now.addingTimeInterval(100),now:now,headless:true))
    }
    func testGrokProcessIdentityRejectsRecycledPIDAndOtherSession() {
        let stamp = ISO8601DateFormatter().string(from: now)
        let entry = AIActivity.GrokRegistryEntry(sessionID:"session-1",pid:42,openedAt:stamp,cwd:nil)
        let current = AIActivity.NativeProcess(pid:42,startedAt:now,binaryPath:"fixture")
        XCTAssertTrue(AIActivity.grokProcessMatches(entry:entry,process:current))
        var reused = current; reused.startedAt = now.addingTimeInterval(600)
        XCTAssertFalse(AIActivity.grokProcessMatches(entry:entry,process:reused))
        var holdingOther = current; holdingOther.openSessions = [URL(fileURLWithPath:"/fixture/session-other")]
        XCTAssertFalse(AIActivity.grokProcessMatches(entry:entry,process:holdingOther))
        XCTAssertFalse(AIActivity.validSessionID("../other"))
        XCTAssertFalse(AIActivity.validSessionID("/absolute"))
    }
    func testGrokHeadlessReaderWorksWithoutRegistryAndExcludesSubagent() throws {
        let home = try scratch(); defer { try? FileManager.default.removeItem(at:home) }
        let session = home.appendingPathComponent(".grok/sessions/project/session-1")
        try FileManager.default.createDirectory(at:session,withIntermediateDirectories:true)
        try Data(#"{"session_kind":"headless","prompt":"private-prompt-fixture"}"#.utf8).write(to:session.appendingPathComponent("summary.json"))
        try data([grok("user_message_chunk")]).write(to:session.appendingPathComponent("updates.jsonl"))
        try FileManager.default.setAttributes([.modificationDate:now],ofItemAtPath:session.appendingPathComponent("updates.jsonl").path)
        let process = AIActivity.NativeProcess(pid:42,startedAt:now.addingTimeInterval(-1),binaryPath:"fixture",openSessions:[session])
        XCTAssertEqual(AIActivity.readGrok(home:home,processes:[process],now:now).state,"working")
        try Data(#"{"session_kind":"subagent"}"#.utf8).write(to:session.appendingPathComponent("summary.json"))
        XCTAssertEqual(AIActivity.readGrok(home:home,processes:[process],now:now).state,"unknown")
    }
    func testNativeOpenFileLookupOnlyReturnsSessionsUnderSelectedRoot() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at:root) }
        let session = root.appendingPathComponent("sessions/project/id")
        try FileManager.default.createDirectory(at:session,withIntermediateDirectories:true)
        let file = session.appendingPathComponent("events.jsonl")
        try Data().write(to:file)
        let handle = try FileHandle(forWritingTo:file); defer { try? handle.close() }
        let found = AIActivity.openGrokSessions(of:getpid(),under:root.appendingPathComponent("sessions"))
        XCTAssertEqual(found.map(\.lastPathComponent),["id"])
    }
    func testAntigravityExplicitQuestionAndPermissionWithoutPromptFields() {
        let question = agy("PLANNER_RESPONSE", extra:#", "tool_calls":[{"name":"ask_question","arguments":{"question":"private-prompt-fixture"}}]"#)
        let waiting = AIActivity.antigravityState(inTail:data([question]),modified:now,launchedAt:now.addingTimeInterval(-60),permissionStatus:nil,now:now)
        XCTAssertEqual(waiting?.state,"waiting")
        XCTAssertFalse((waiting?.detail ?? "").contains("private"))
        XCTAssertEqual(AIActivity.antigravityState(inTail:data([agy("USER_INPUT")]),modified:now,launchedAt:now.addingTimeInterval(-60),permissionStatus:2,now:now)?.state,"waiting")
    }
    func testAntigravityFinalResponseOverridesEarlierWaitAndRejectsClosedOrOldInstance() {
        let question = agy("PLANNER_RESPONSE",extra:#", "tool_calls":[{"name":"ask_question"}]"#)
        let completed = data([question,agy("PLANNER_RESPONSE",extra:#", "tool_calls":[], "text":"private-response-fixture""#)])
        XCTAssertEqual(AIActivity.antigravityState(inTail:completed,modified:now,launchedAt:now.addingTimeInterval(-60),permissionStatus:nil,now:now)?.state,"idle")
        XCTAssertNil(AIActivity.antigravityState(inTail:completed,modified:now,launchedAt:nil,permissionStatus:nil,now:now))
        XCTAssertNil(AIActivity.antigravityState(inTail:completed,modified:now,launchedAt:now.addingTimeInterval(1),permissionStatus:nil,now:now))
        let old = data([agy("USER_INPUT",at:now.addingTimeInterval(-61))])
        XCTAssertNil(AIActivity.antigravityState(inTail:old,modified:now,launchedAt:now.addingTimeInterval(-120),permissionStatus:nil,now:now))
        XCTAssertNil(AIActivity.antigravityState(inTail:data([agy("UNSUPPORTED_NEW_SCHEMA")]),modified:now,launchedAt:now.addingTimeInterval(-60),permissionStatus:nil,now:now))
    }
    func testAntigravityArtifactFeedbackAndBinaryIdentityAreSpecific() {
        let approval = agy("PLANNER_RESPONSE",extra:#", "tool_calls":[{"name":"write_to_file","arguments":{"ArtifactMetadata":{"RequestFeedback":true,"Path":"private-file-fixture"}}}]"#)
        XCTAssertEqual(AIActivity.antigravityState(inTail:data([approval]),modified:now,launchedAt:now.addingTimeInterval(-60),permissionStatus:nil,now:now)?.state,"waiting")
        XCTAssertTrue(AIActivity.trustedBinary("/Applications/Cursor.app/Contents/MacOS/Cursor",provider:.cursor))
        XCTAssertFalse(AIActivity.trustedBinary("/tmp/Cursor",provider:.cursor))
        XCTAssertTrue(AIActivity.trustedBinary("/Applications/Antigravity.app/Contents/MacOS/Antigravity",provider:.antigravity))
        XCTAssertFalse(AIActivity.trustedBinary("/tmp/agent",provider:.grok))
        XCTAssertFalse(AIActivity.trustedBinary("/Applications/Antigravity.app/Contents/Resources/language_server",provider:.antigravity))
    }

    func testElectronMainProcessUsesBundleIdentityAndExcludesHelpers() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at:root) }
        let app = root.appendingPathComponent("Renamed.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at:macOS,withIntermediateDirectories:true)
        let info:[String:Any] = ["CFBundleIdentifier":"com.google.antigravity","CFBundleExecutable":"Electron","CFBundlePackageType":"APPL"]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:app.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent("Electron")
        try Data().write(to:executable)
        XCTAssertTrue(AIActivity.trustedBinary(executable.path,provider:.antigravity))
        XCTAssertFalse(AIActivity.trustedBinary(executable.path,provider:.cursor))
        XCTAssertFalse(AIActivity.trustedBinary(app.appendingPathComponent("Contents/Resources/language_server").path,provider:.antigravity))
    }

    private func grok(_ kind:String) -> String { #"{"params":{"update":{"sessionUpdate":"\#(kind)","content":{"text":"private-prompt-fixture"}}}}"# }
    private func agy(_ type:String, extra:String = "",at:Date? = nil) -> String {
        let stamp = ISO8601DateFormatter().string(from:at ?? now)
        return #"{"type":"\#(type)","created_at":"\#(stamp)"\#(extra)}"#
    }
    private func data(_ lines:[String]) -> Data { Data(lines.joined(separator:"\n").utf8) }
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NexoBar/activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); return root
    }
}
