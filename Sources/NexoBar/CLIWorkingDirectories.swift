import Foundation

enum CLIWorkingDirectoryError: LocalizedError {
    case required, invalid, unsupported
    var errorDescription: String? {
        switch self {
        case .required: return "Escolha a pasta do Claude nas configurações do NexoBar. Use uma pasta já confiável na CLI."
        case .invalid: return "A pasta da CLI não existe ou não pode ser lida. Confira as configurações do NexoBar."
        case .unsupported: return "Este provedor não possui configuração de pasta."
        }
    }
}

struct CLIWorkingDirectories: Codable, Equatable {
    var claude: String?
    var codex: String?
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NexoBar/cli-directories.json")
    }
    static func load(from url: URL = defaultURL) -> Self {
        guard let file = try? FileHandle(forReadingFrom: url) else { return Self() }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: 16 * 1024 + 1), bytes.count <= 16 * 1024,
              let result = try? JSONDecoder().decode(Self.self, from: bytes) else { return Self() }
        return result
    }
    func path(for id: IndicatorID) -> String? { id == .claude ? claude : id == .codex ? codex : nil }
    func directory(for id: IndicatorID) throws -> URL? {
        guard id == .claude || id == .codex else { throw CLIWorkingDirectoryError.unsupported }
        guard let path = path(for: id), !path.isEmpty else {
            if id == .claude { throw CLIWorkingDirectoryError.required }
            return nil
        }
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else {
            throw CLIWorkingDirectoryError.invalid
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: path) else { throw CLIWorkingDirectoryError.invalid }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    mutating func set(_ url: URL?, for id: IndicatorID) throws {
        guard id == .claude || id == .codex else { throw CLIWorkingDirectoryError.unsupported }
        var edited = self
        if id == .claude { edited.claude = url?.path } else { edited.codex = url?.path }
        if url != nil { _ = try edited.directory(for: id) }
        self = edited
    }
    func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
