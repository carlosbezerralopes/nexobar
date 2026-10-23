// AppleSMC ABI and sensor names adapted from Stats (MIT); see docs/HARDWARE-NOTICES.md.
import Foundation
import IOKit

struct HardwareTemperature: Equatable {
    var key: String
    var celsius: Double
}

struct HardwareSnapshot {
    var gpuPercent: Double?
    var gpuDetail: String
    var cpuTemperatures: [HardwareTemperature]
    var gpuTemperatures: [HardwareTemperature]
    var temperatureDetail: String
}

/// Read-only collector. Serialize calls on a utility queue; it has no process, network or login path.
final class HardwareSensors {
    private let readSnapshot: () -> HardwareSnapshot
    private let date: () -> Date

    init(readSnapshot: (() -> HardwareSnapshot)? = nil, date: @escaping () -> Date = Date.init) {
        if let readSnapshot {
            self.readSnapshot = readSnapshot
        } else {
            let system = HardwareSensorSystem()
            self.readSnapshot = { system.snapshot() }
        }
        self.date = date
    }

    func sample() -> [IndicatorReading] {
        let snapshot = readSnapshot()
        let now = date()
        let gpu: IndicatorReading
        if let value = snapshot.gpuPercent, value.isFinite, (0...100).contains(value) {
            gpu = IndicatorReading(id: .gpu, value: IndicatorReading.percent(value),
                                   detail: snapshot.gpuDetail, sampledAt: now, numericValue: value)
        } else {
            gpu = .unavailable(.gpu, snapshot.gpuDetail)
        }
        return [gpu,
                temperature(.cpuTemperature, samples: snapshot.cpuTemperatures, detail: snapshot.temperatureDetail, now: now),
                temperature(.gpuTemperature, samples: snapshot.gpuTemperatures, detail: snapshot.temperatureDetail, now: now)]
    }

    private func temperature(_ id: IndicatorID, samples: [HardwareTemperature], detail: String, now: Date) -> IndicatorReading {
        let valid = samples.filter { HardwareSensorDecoding.validTemperature($0.celsius) }
        guard let maximum = valid.max(by: { $0.celsius < $1.celsius }) else {
            return .unavailable(id, "Sem leitura válida de temperatura. \(detail)")
        }
        let average = valid.reduce(0) { $0 + $1.celsius } / Double(valid.count)
        return IndicatorReading(id: id, value: String(format: "%.0f °C", maximum.celsius),
            detail: String(format: "Maior temperatura entre %d sensores; média %.1f °C. %@",
                           valid.count, average, detail), sampledAt: now, numericValue: maximum.celsius)
    }
}

enum HardwareSensorDecoding {
    static func validTemperature(_ value: Double) -> Bool {
        // 0 and 128 are common unavailable/sentinel readings, never display them as temperatures.
        value.isFinite && value > 0 && value < 128
    }

    static func smcValue(type: String, bytes: [UInt8]) -> Double? {
        let value: Double
        switch type {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            value = Double(Float(bitPattern: bits))
        case "sp78":
            guard bytes.count == 2 else { return nil }
            value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default: return nil
        }
        return validTemperature(value) ? value : nil
    }

    static func gpuUsage(_ statistics: [String: Any]) -> Double? {
        for key in ["Device Utilization %", "GPU Activity(%)"] {
            guard let number = statistics[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
            let value = number.doubleValue
            if value.isFinite, (0...100).contains(value) { return value }
        }
        return nil
    }

    /// No prefix guessing: a key can identify different hardware in a different chip generation.
    static func temperatureKeys(model: String) -> (cpu: [String], gpu: [String])? {
        let words = model.split(separator: " ")
        let family = words.first == "Apple" ? words.dropFirst().first.map(String.init) : nil
        if family == "M5" {
            return (["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"],
                    ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"])
        }
        if family == "M4" {
            let gpu = model.contains("Pro") || model.contains("Max") ? ["Tg1U", "Tg1k"] : ["Tg0G", "Tg0H"]
            return (["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"],
                    gpu + ["Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"])
        }
        if family == "M3" {
            return (["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"],
                    ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"])
        }
        if family == "M2" {
            return (["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"], ["Tg0f", "Tg0j"])
        }
        if family == "M1" {
            return (["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"], ["Tg05", "Tg0D", "Tg0L", "Tg0T"])
        }
        if model.contains("Intel") {
            return (["TC0D", "TCAD", "TCAC", "TCBC"] + Array("0123456789ABCDEF").flatMap { ["TC\($0)c", "TC\($0)C"] }, ["TCGC", "TG0D", "TGDD"])
        }
        return nil
    }
}

final class HardwareSensorSystem {
    private let smc = ReadOnlySMC()

    func snapshot() -> HardwareSnapshot {
        let deadline = ProcessInfo.processInfo.systemUptime + 2.5
        let accelerators = readAccelerators()
        let models = accelerators.compactMap { $0.model }
        let model = Self.cpuBrand() ?? models.first(where: { $0.contains("Apple M") }) ?? "hardware desconhecido"
        let utilizations = accelerators.compactMap { HardwareSensorDecoding.gpuUsage($0.statistics) }
        let gpuDetail = utilizations.isEmpty
            ? "IOAccelerator não forneceu um contador de utilização válido nesta coleta."
            : "\(models.joined(separator: ", ")) · utilização informada pelo driver\(utilizations.count > 1 ? "; maior valor entre \(utilizations.count) GPUs" : "")."

        guard let keys = HardwareSensorDecoding.temperatureKeys(model: model) else {
            return HardwareSnapshot(gpuPercent: utilizations.max(), gpuDetail: gpuDetail,
                cpuTemperatures: [], gpuTemperatures: [], temperatureDetail: "Mapa AppleSMC ainda não validado para \(model).")
        }
        guard smc.open() else {
            return HardwareSnapshot(gpuPercent: utilizations.max(), gpuDetail: gpuDetail,
                cpuTemperatures: [], gpuTemperatures: [], temperatureDetail: smc.lastError)
        }
        func temperatures(_ keys: [String]) -> [HardwareTemperature] {
            keys.compactMap { key in
                guard ProcessInfo.processInfo.systemUptime < deadline, let value = smc.temperature(key) else { return nil }
                return HardwareTemperature(key: key, celsius: value)
            }
        }
        let cpu = temperatures(keys.cpu)
        let gpu = temperatures(keys.gpu)
        let timedOut = ProcessInfo.processInfo.systemUptime >= deadline
        // Partial sweeps would silently change which maximum is represented. Discard a timed-out sweep.
        return HardwareSnapshot(gpuPercent: utilizations.max(), gpuDetail: gpuDetail,
            cpuTemperatures: timedOut ? [] : cpu, gpuTemperatures: timedOut ? [] : gpu,
            temperatureDetail: timedOut ? "Coleta excedeu 2,5 s; amostra descartada." : "\(model).")
    }

    private func readAccelerators() -> [(model: String?, statistics: [String: Any])] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [(String?, [String: Any])] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            let rawModel = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            let model = (rawModel as? String) ?? (rawModel as? Data).flatMap { String(data: $0, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) }
            let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] ?? [:]
            result.append((model, stats))
        }
        return result
    }

    private static func cpuBrand() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0, size < 1024 else { return nil }
        var data = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &data, &size, nil, 0) == 0 else { return nil }
        return String(cString: data)
    }
}

/// Private AppleSMC user-client ABI. Contains no write command or fan control operation.
final class ReadOnlySMC {
    private var connection: io_connect_t = 0
    private var metadata: [UInt32: SMCMessage.KeyInfo] = [:]
    private(set) var lastError = "AppleSMC somente leitura; chaves ausentes/inválidas são omitidas."

    deinit { if connection != 0 { IOServiceClose(connection) } }

    func open() -> Bool {
        lastError = "AppleSMC somente leitura; chaves ausentes/inválidas são omitidas."
        guard connection == 0 else { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { lastError = "Serviço AppleSMC ausente ou inacessível."; return false }
        defer { IOObjectRelease(service) }
        let code = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard code == KERN_SUCCESS else {
            connection = 0
            lastError = "AppleSMC IOServiceOpen recusado: \(Self.errorCode(code))."
            return false
        }
        return true
    }

    func temperature(_ key: String) -> Double? {
        guard key.utf8.count == 4, connection != 0 else { return nil }
        let code = key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        var input = SMCMessage()
        input.key = code
        let info: SMCMessage.KeyInfo
        if let cached = metadata[code] { info = cached }
        else {
            input.command = 9
            guard let output = call(input), output.result == 0,
                  (1...32).contains(output.keyInfo.size), output.keyInfo.type != 0 else { return nil }
            info = output.keyInfo
        }
        input.command = 5
        input.keyInfo.size = info.size
        guard let output = call(input), output.result == 0 else { metadata.removeValue(forKey: code); return nil }
        metadata[code] = info
        let type = String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: info.type >> $0) }, encoding: .ascii) ?? ""
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.size))) }
        return HardwareSensorDecoding.smcValue(type: type, bytes: bytes)
    }

    private func call(_ message: SMCMessage) -> SMCMessage? {
        var input = message
        var output = SMCMessage()
        let size = MemoryLayout<SMCMessage>.stride
        guard size == 80 else { lastError = "Layout AppleSMC incompatível (\(size) bytes)."; return nil }
        var outputSize = size
        let code = IOConnectCallStructMethod(connection, 2, &input, size, &output, &outputSize)
        guard code == KERN_SUCCESS, outputSize == size else {
            lastError = "Falha na leitura AppleSMC: \(Self.errorCode(code)), resposta \(outputSize) bytes."
            metadata.removeAll()
            IOServiceClose(connection)
            connection = 0
            return nil
        }
        if output.result != 0 && output.result != 0x84 {
            lastError = "AppleSMC recusou leitura (firmware \(output.result))."
        }
        return output
    }

    private static func errorCode(_ code: kern_return_t) -> String { String(format: "0x%08x", UInt32(bitPattern: code)) }
}

// The nested Swift structs deliberately follow the 80-byte AppleSMC C ABI, including its padding.
struct SMCMessage {
    struct Version {
        var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0
        var release: UInt16 = 0
    }
    struct Limits {
        var version: UInt16 = 0; var length: UInt16 = 0
        var cpu: UInt32 = 0; var gpu: UInt32 = 0; var memory: UInt32 = 0
    }
    struct KeyInfo { var size: UInt32 = 0; var type: UInt32 = 0; var attributes: UInt8 = 0 }
    var key: UInt32 = 0
    var version = Version()
    var limits = Limits()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    var index: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
               (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}
