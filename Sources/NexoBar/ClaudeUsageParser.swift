import Foundation

/// The current terminal frame only: erased or scrolled-out quotas cannot survive a redraw.
struct ClaudeTerminalScreen {
    private enum EscapeState { case text, escape, csi, string, stringEscape, charset }
    private let columns: Int
    private let rows: Int
    private var cells: [[String]]
    private var x = 0
    private var y = 0
    private var saved = (x: 0, y: 0)
    private var state: EscapeState = .text
    private var parameters = ""
    private var utf8: [UInt8] = []
    private var utf8Length = 0

    init(columns: Int = 160, rows: Int = 80) {
        self.columns = min(512, max(1, columns))
        self.rows = min(256, max(1, rows))
        cells = Array(repeating: Array(repeating: " ", count: self.columns), count: self.rows)
    }

    var text: String {
        cells.map { $0.joined().replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
            .joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    mutating func feed(_ data: Data) {
        for byte in data { consume(byte) }
    }

    private mutating func consume(_ byte: UInt8) {
        switch state {
        case .string:
            if byte == 7 { state = .text }
            else if byte == 27 { state = .stringEscape }
            return
        case .stringEscape:
            state = byte == 92 ? .text : byte == 27 ? .stringEscape : .string
            return
        case .charset:
            state = .text
            return
        case .escape:
            state = .text
            switch byte {
            case 91: state = .csi; parameters = ""
            case 93, 80, 94, 95: state = .string
            case 40, 41, 42, 43: state = .charset
            case 55: saved = (x, y)
            case 56: x = saved.x; y = saved.y
            case 68: lineFeed()
            case 69: x = 0; lineFeed()
            case 99: clear(); x = 0; y = 0
            default: break
            }
            return
        case .csi:
            if (0x40...0x7e).contains(byte) {
                executeCSI(byte); parameters = ""; state = .text
            } else if byte == 27 { state = .escape; parameters = "" }
            else if parameters.utf8.count < 64, (0x20...0x3f).contains(byte) {
                parameters.append(Character(UnicodeScalar(byte)))
            } else { parameters = "?" }
            return
        case .text: break
        }

        if !utf8.isEmpty {
            if (0x80...0xbf).contains(byte) {
                utf8.append(byte)
                if utf8.count == utf8Length { write(String(decoding: utf8, as: UTF8.self)); utf8.removeAll(keepingCapacity: true) }
                return
            }
            write("�"); utf8.removeAll(keepingCapacity: true)
        }
        switch byte {
        case 27: state = .escape
        case 13: x = 0
        case 10: lineFeed()
        case 8: x = max(0, x - 1)
        case 9: x = min(columns - 1, ((x / 8) + 1) * 8)
        case 0...31, 127: break
        case 0xc2...0xdf: utf8 = [byte]; utf8Length = 2
        case 0xe0...0xef: utf8 = [byte]; utf8Length = 3
        case 0xf0...0xf4: utf8 = [byte]; utf8Length = 4
        case 0x80...0xff: write("�")
        default: write(String(UnicodeScalar(byte)))
        }
    }

    private mutating func write(_ value: String) {
        if x >= columns { x = 0; lineFeed() }
        cells[y][x] = value
        x += 1
    }

    private mutating func lineFeed() {
        if y < rows - 1 { y += 1 }
        else { cells.removeFirst(); cells.append(Array(repeating: " ", count: columns)) }
    }

    private mutating func clear() {
        cells = Array(repeating: Array(repeating: " ", count: columns), count: rows)
    }

    private mutating func executeCSI(_ final: UInt8) {
        guard parameters.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ";") }) else { return }
        let args = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        let amount = max(1, min(4096, args.first ?? 1))
        let mode = args.first ?? 0
        switch final {
        case 65: y = max(0, y - amount)
        case 66: y = min(rows - 1, y + amount)
        case 67: x = min(columns - 1, x + amount)
        case 68: x = max(0, x - amount)
        case 71: x = min(columns - 1, amount - 1)
        case 72, 102:
            y = min(rows - 1, amount - 1)
            x = min(columns - 1, max(1, args.count > 1 ? args[1] : 1) - 1)
        case 75:
            let cursor = min(columns - 1, x)
            let range = mode == 1 ? 0...cursor : mode == 2 ? 0...(columns - 1) : cursor...(columns - 1)
            for column in range { cells[y][column] = " " }
        case 74:
            if mode == 2 || mode == 3 { clear() }
            else if mode == 1 {
                if y > 0 { for row in 0..<y { cells[row] = Array(repeating: " ", count: columns) } }
                for column in 0...min(columns - 1, x) { cells[y][column] = " " }
            } else {
                for column in min(columns - 1, x)..<columns { cells[y][column] = " " }
                if y + 1 < rows { for row in (y + 1)..<rows { cells[row] = Array(repeating: " ", count: columns) } }
            }
        case 115: saved = (x, y)
        case 117: x = saved.x; y = saved.y
        default: break
        }
    }
}

enum ClaudeUsageParser {
    private struct Section {
        var id: String
        var name: String
        var weekly: Bool
        var lines: [String] = []
    }

    static func parse(_ screen: String, now: Date) throws -> IndicatorReading {
        guard screen.utf8.count <= 256 * 1024 else { throw AIReadError.excessiveOutput }
        let lower = screen.lowercased()
        let authentication = ["sign in", "log in", "/login", "authentication", "unauthorized", "trust this folder", "do you trust", "trust the files"]
        guard !authentication.contains(where: lower.contains) else { throw AIReadError.authentication }
        guard !["loading usage data", "refreshing", "failed to load", "error fetching", "error loading"].contains(where: lower.contains),
              !matches(#"\berror\b"#, lower) else { throw AIReadError.unavailable }

        var sections: [Section] = []
        var active: Section?
        for raw in screen.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "│┃║"))
                .trimmingCharacters(in: .whitespaces)
            if let section = heading(line) {
                if let active { sections.append(active) }
                active = section
            } else if line.lowercased().hasPrefix("what's contributing") || line == "Extra usage" || line == "Current week" {
                if let active { sections.append(active) }
                active = nil
            } else { active?.lines.append(line) }
        }
        if let active { sections.append(active) }
        var seen = Set<String>()
        var windows: [QuotaWindow] = []
        for section in sections {
            guard seen.insert(section.id).inserted else { throw AIReadError.malformed }
            let candidates = section.lines.filter { $0.lowercased().hasSuffix("used") && $0.contains("%") }
            guard candidates.count <= 1 else { throw AIReadError.malformed }
            guard let line = candidates.first else { continue }
            guard let used = percent(line) else { throw AIReadError.malformed }
            let resets = section.lines.filter { $0.hasPrefix("Resets ") }
            let reset = resets.count == 1 ? resetDate(resets[0], weekly: section.weekly, now: now) : nil
            windows.append(QuotaWindow(name: section.name, usedPercent: used, resetsAt: reset,
                                       id: section.id))
        }
        windows.sort { rank($0.id) < rank($1.id) }
        let headline = windows.first(where: { $0.id == "session" })?.usedPercent
            ?? windows.first(where: { $0.id == "weekly_all" })?.usedPercent
        return try AIUsageParser.reading(.claude, windows: windows, headline: headline, now: now,
                                         source: "Claude Code · /usage · consulta pela sessão existente")
    }

    private static func heading(_ line: String) -> Section? {
        if line == "Current session" { return Section(id: "session", name: "Sessão", weekly: false) }
        guard let scope = capture(#"^Current week \(([^\r\n()]+)\)$"#, line)?.first,
              scope.count <= 64 else { return nil }
        if scope == "all models" { return Section(id: "weekly_all", name: "Semanal", weekly: true) }
        guard scope.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || " ._+-/".unicodeScalars.contains($0) }) else { return nil }
        let slug = scope.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        guard !slug.isEmpty else { return nil }
        return Section(id: "weekly_model_" + slug, name: "Semanal · " + scope, weekly: true)
    }

    private static func rank(_ id: String?) -> Int { id == "session" ? 0 : id == "weekly_all" ? 1 : 2 }

    private static func percent(_ line: String) -> Double? {
        let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        let found = regex.matches(in: line, range: range)
        guard (1...2).contains(found.count) else { return nil }
        let numbers = found.compactMap { match -> Double? in
            guard let range = Range(match.range(at: 1), in: line), let value = Double(line[range]),
                  value.isFinite, (0...100).contains(value) else { return nil }
            return value
        }
        guard numbers.count == found.count, let first = numbers.first, numbers.allSatisfy({ $0 == first }) else { return nil }
        let remainder = regex.stringByReplacingMatches(in: line, range: range, withTemplate: "")
            .replacingOccurrences(of: #"(?i)used$"#, with: "", options: .regularExpression)
        let bars = CharacterSet(charactersIn: " ▏▎▍▌▋▊▉█░▒▓━─▕[]|\t")
        guard remainder.unicodeScalars.allSatisfy({ bars.contains($0) }) else { return nil }
        return first
    }

    private static func resetDate(_ line: String, weekly: Bool, now: Date) -> Date? {
        guard let parts = capture(#"^Resets (.+) \(([^()]+)\)$"#, line), parts.count == 2,
              TimeZone.knownTimeZoneIdentifiers.contains(parts[1]) || parts[1] == "UTC",
              let timezone = TimeZone(identifier: parts[1]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        var dateParts = calendar.dateComponents([.year, .month, .day], from: now)
        var timeText = parts[0]
        if weekly {
            guard let date = capture(#"^([A-Za-z]+) ([0-9]{1,2})(?:,? ([0-9]{4}))? at (.+)$"#, timeText),
                  let month = monthNumber(date[0]), let day = Int(date[1]) else { return nil }
            timeText = date[3]
            dateParts.month = month; dateParts.day = day
            if !date[2].isEmpty { dateParts.year = Int(date[2]) }
            guard let clock = clock(timeText) else { return nil }
            dateParts.hour = clock.hour; dateParts.minute = clock.minute; dateParts.second = 0
            for yearOffset in 0...1 {
                var candidate = dateParts
                if date[2].isEmpty { candidate.year = (dateParts.year ?? 0) + yearOffset }
                if let result = validDate(candidate, calendar: calendar), result > now, result.timeIntervalSince(now) <= 8 * 86400 { return result }
            }
            return nil
        }
        let tomorrow = timeText.lowercased().hasPrefix("tomorrow ")
        let today = timeText.lowercased().hasPrefix("today ")
        timeText = timeText.replacingOccurrences(of: #"(?i)^(today|tomorrow) (?:at )?"#, with: "", options: .regularExpression)
        guard let clock = clock(timeText) else { return nil }
        dateParts.hour = clock.hour; dateParts.minute = clock.minute; dateParts.second = 0
        guard var result = validDate(dateParts, calendar: calendar) else { return nil }
        if tomorrow || (!today && result <= now) {
            guard let next = calendar.date(byAdding: .day, value: 1, to: result) else { return nil }
            result = next
        }
        return result > now && result.timeIntervalSince(now) <= 6 * 3600 ? result : nil
    }

    private static func clock(_ value: String) -> (hour: Int, minute: Int)? {
        guard let parts = capture(#"(?i)^([0-9]{1,2})(?::([0-9]{2}))?\s*(am|pm)?$"#, value),
              var hour = Int(parts[0]), let minute = Int(parts[1].isEmpty ? "0" : parts[1]), (0...59).contains(minute) else { return nil }
        if parts[2].isEmpty { guard (0...23).contains(hour) else { return nil } }
        else {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (parts[2].lowercased() == "pm" ? 12 : 0)
        }
        return (hour, minute)
    }

    private static func validDate(_ parts: DateComponents, calendar: Calendar) -> Date? {
        guard let date = calendar.date(from: parts) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard actual.year == parts.year, actual.month == parts.month, actual.day == parts.day,
              actual.hour == parts.hour, actual.minute == parts.minute else { return nil }
        return date
    }

    private static func monthNumber(_ name: String) -> Int? {
        let names = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        return names.firstIndex(where: { $0 == name.lowercased() || String($0.prefix(3)) == name.lowercased() }).map { $0 + 1 }
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool { capture(pattern, text) != nil }

    private static func capture(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
