import XCTest
@testable import NexoBar

final class CLIWorkingDirectoriesTests: XCTestCase {
    func testClaudeRequiresSelectionWhileCodexCanUseAutomaticDirectory() throws {
        let config = CLIWorkingDirectories()
        XCTAssertThrowsError(try config.directory(for: .claude))
        XCTAssertNil(try config.directory(for: .codex))
        XCTAssertThrowsError(try config.directory(for: .kiro))
    }
    func testSeparateFoldersPersistAndClearingOnePreservesOther() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NexoBar/folder-tests/\(UUID().uuidString)")
        let other = root.appendingPathComponent("Codex folder")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = CLIWorkingDirectories()
        try config.set(root, for: .claude)
        try config.set(other, for: .codex)
        let path = root.appendingPathComponent("cli-directories.json")
        try config.save(to: path)
        XCTAssertEqual(CLIWorkingDirectories.load(from: path), config)
        XCTAssertEqual(try config.directory(for: .codex)?.path, other.path)
        try config.set(nil, for: .claude)
        XCTAssertThrowsError(try config.directory(for: .claude))
        XCTAssertEqual(try config.directory(for: .codex)?.path, other.path)
    }
    func testInvalidSelectionDoesNotReplaceValidPathAndNeverCreatesFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NexoBar/folder-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = CLIWorkingDirectories(claude: root.path)
        let absent = root.appendingPathComponent("not-created")
        XCTAssertThrowsError(try config.set(absent, for: .claude))
        XCTAssertEqual(config.claude, root.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
        XCTAssertThrowsError(try CLIWorkingDirectories(claude: "relative/path").directory(for: .claude))
        XCTAssertThrowsError(try CLIWorkingDirectories(claude: root.path + "\n").directory(for: .claude))
        let file = root.appendingPathComponent("a-file")
        try Data().write(to: file)
        XCTAssertThrowsError(try config.set(file, for: .claude))
    }
    func testCodexRunnerUsesSelectedDirectoryWithoutShellInterpolation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NexoBar/folder-tests/a folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try UsageCommand.run(binary: URL(fileURLWithPath: "/bin/pwd"), arguments: [], workingDirectory: root)
        XCTAssertEqual(URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
    }
}
