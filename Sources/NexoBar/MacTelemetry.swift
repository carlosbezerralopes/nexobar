import Darwin
import Foundation
import IOKit
import SystemConfiguration
import WorkersTelemetry

/// Leitura do próprio Mac no formato do coletor dos workers (`mac.json`), para o widget mostrar o Mac como mais um cartão.
/// CPU, memória, GPU e temperaturas vêm do coletor do NexoBar; o resto é lido aqui, sem root. Watts e VRAM da GPU
/// não têm fonte sem privilégios e ficam ausentes. Usada só pela fila serial do WorkersWidgetReloader.
final class MacTelemetry: @unchecked Sendable {
    struct Hardware { var cpu: Double?; var cpuTemperature: Double?; var gpu: Double?; var gpuTemperature: Double?; var memoryUsedBytes: Double? }
    struct DiskCounters: Equatable { var bytesRead: Double; var bytesWritten: Double; var busyNanoseconds: Double }

    private var previousDisk: (counters: DiskCounters, uptime: TimeInterval)?
    private let smc = ReadOnlySMC()
    private lazy var smcOpen = smc.open()

    func json(hardware: Hardware, now: Date) -> [String: Any] {
        let uptime = ProcessInfo.processInfo.systemUptime
        var ssd: [String: Any] = [:]
        if let counters = Self.diskCounters() {
            if let previous = previousDisk, let rates = Self.diskActivity(from: previous.counters, to: counters, seconds: uptime - previous.uptime) {
                ssd["ativo"] = rates.active; ssd["leitura_bs"] = rates.read; ssd["escrita_bs"] = rates.write
            }
            previousDisk = (counters, uptime)
        }
        if let free = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            ssd["livre_gb"] = (Double(free) / 1_073_741_824).rounded()
        }
        let installed = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        var ram: [String: Any] = ["total_gb": installed.rounded(), "instalada_gb": installed.rounded()]
        if let used = hardware.memoryUsedBytes { ram["usada_gb"] = (used / 1_073_741_824 * 10).rounded() / 10 }
        if let swap = Self.swapUsedBytes() { ram["swap_gb"] = (swap / 1_073_741_824 * 10).rounded() / 10 }
        var cpu: [String: Any] = [:]
        cpu["uso"] = hardware.cpu.map { $0.rounded() }
        cpu["temp"] = hardware.cpuTemperature.map { $0.rounded() }
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 { cpu["load1"] = (load[0] * 100).rounded() / 100 }
        var gpu: [String: Any] = [:]
        gpu["uso"] = hardware.gpu.map { $0.rounded() }
        gpu["temp"] = hardware.gpuTemperature.map { $0.rounded() }
        let processes = Self.processes()
        var result: [String: Any] = [
            "v": 1, "host": Self.computerName(), "ts": Int(now.timeIntervalSince1970), "recebido": Int(now.timeIntervalSince1970),
            "hora": ISO8601DateFormatter().string(from: now), "cpu": cpu, "ram": ram, "ssd": ssd, "gpu": gpu,
            "ventoinhas_rpm": fans(), "top_cpu": processes.top,
        ]
        result["claude_sessoes"] = processes.claude
        return result
    }

    func write(hardware: Hardware, now: Date, directory: URL = WorkersTelemetry.appDirectory) throws {
        let data = try JSONSerialization.data(withJSONObject: json(hardware: hardware, now: now), options: [.sortedKeys])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(WorkersTelemetry.macID).json"), options: .atomic)
    }

    /// % do tempo com E/S e taxas, como o "Tempo ativo" do Monitor de Recursos; nil se o intervalo ou os contadores não servem.
    static func diskActivity(from a: DiskCounters, to b: DiskCounters, seconds: Double) -> (active: Double, read: Double, write: Double)? {
        guard seconds > 0, b.bytesRead >= a.bytesRead, b.bytesWritten >= a.bytesWritten, b.busyNanoseconds >= a.busyNanoseconds else { return nil }
        let active = min(100, (b.busyNanoseconds - a.busyNanoseconds) / (seconds * 1e9) * 100)
        return (active.rounded(), ((b.bytesRead - a.bytesRead) / seconds).rounded(), ((b.bytesWritten - a.bytesWritten) / seconds).rounded())
    }

    /// Contadores do disco interno (IOBlockStorageDriver cujo dispositivo é interno); sem essa marca, soma todos.
    static func diskCounters() -> DiskCounters? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var internalDisk: DiskCounters?, all = DiskCounters(bytesRead: 0, bytesWritten: 0, busyNanoseconds: 0), found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { continue }
            func value(_ key: String) -> Double { (stats[key] as? NSNumber)?.doubleValue ?? 0 }
            let counters = DiskCounters(bytesRead: value("Bytes (Read)"), bytesWritten: value("Bytes (Write)"),
                                        busyNanoseconds: value("Total Time (Read)") + value("Total Time (Write)"))
            found = true
            all.bytesRead += counters.bytesRead; all.bytesWritten += counters.bytesWritten; all.busyNanoseconds += counters.busyNanoseconds
            var parent: io_registry_entry_t = 0
            if internalDisk == nil, IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
                defer { IOObjectRelease(parent) }
                let characteristics = IORegistryEntryCreateCFProperty(parent, "Protocol Characteristics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
                if characteristics?["Physical Interconnect Location"] as? String == "Internal" { internalDisk = counters }
            }
        }
        return internalDisk ?? (found ? all : nil)
    }

    static func swapUsedBytes() -> Double? {
        var usage = xsw_usage(); var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return Double(usage.xsu_used)
    }

    /// Ventoinhas pelo AppleSMC (F0Ac…), só leitura; Mac sem ventoinha devolve lista vazia.
    private func fans() -> [Double] {
        guard smcOpen else { return [] }
        return (0..<4).compactMap { smc.value("F\($0)Ac") }.filter { $0.isFinite && $0 >= 0 && $0 < 20000 }.map { $0.rounded() }
    }

    private static func computerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
    }

    /// Três processos com mais CPU (% do `ps`, em que 100% é um núcleo) e sessões do Claude Code, como no coletor dos workers.
    static func processes() -> (top: [[String: Any]], claude: Int?) {
        let top = run(["-Aceo", "pid=,pcpu=,rss=,comm="]).map(parseTop) ?? []
        let claude = run(["-Ao", "args="]).map(countClaude)
        return (top, claude)
    }

    static func parseTop(_ output: String) -> [[String: Any]] {
        output.split(separator: "\n").compactMap { line -> (Int, Double, Double, String)? in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int(parts[0]), let cpu = Double(parts[1].replacingOccurrences(of: ",", with: ".")), let rss = Double(parts[2]) else { return nil }
            return (pid, cpu, rss, String(parts[3]))
        }
        .sorted { $0.1 > $1.1 }.prefix(3)
        .map { ["pid": $0.0, "cpu": $0.1, "ram_mb": ($0.2 / 1024).rounded(), "nome": $0.3] }
    }

    /// Interativas e as abertas pelo remote-control; o processo remote-control em si não conta.
    /// Inclui as sessões do app Claude (claude.app/Contents/MacOS/claude, num caminho com espaços).
    static func countClaude(_ output: String) -> Int {
        output.split(separator: "\n").filter { line in
            let isClaude = line.range(of: #"^(\S*/)?claude( |$)"#, options: .regularExpression) != nil
                || line.contains("/claude/versions/") || line.contains("/claude.app/Contents/MacOS/claude")
            return isClaude && !line.contains(" remote-control")
        }.count
    }

    private static func run(_ arguments: [String]) -> String? {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps"); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}
