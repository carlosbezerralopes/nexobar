import Foundation
import IOKit

struct DiskCounters: Equatable {
    var bytesRead: Double
    var bytesWritten: Double
    var busyNanoseconds: Double

    /// Active time (% of the interval with I/O, like Resource Monitor's "Tempo ativo") and rates in bytes/s.
    /// nil when the interval is invalid or a counter went backwards (driver reset).
    func activity(since previous: Self, seconds: Double) -> (active: Double, read: Double, write: Double)? {
        guard seconds > 0, seconds <= 15, bytesRead >= previous.bytesRead, bytesWritten >= previous.bytesWritten,
              busyNanoseconds >= previous.busyNanoseconds else { return nil }
        let active = min(100, (busyNanoseconds - previous.busyNanoseconds) / (seconds * 1e9) * 100)
        return (active, (bytesRead - previous.bytesRead) / seconds, (bytesWritten - previous.bytesWritten) / seconds)
    }
}

struct DiskSnapshot {
    var counters: DiskCounters?
    var name: String?
    var totalBytes: Double?
    var availableBytes: Double?
}

/// Startup SSD: activity from IOBlockStorageDriver statistics, free space from the "/" volume.
/// Main-thread sampler; no process, privilege or write path.
final class SSDMonitor {
    private let readSnapshot: () -> DiskSnapshot
    private let uptime: () -> TimeInterval
    private let date: () -> Date
    private var baseline: (counters: DiskCounters, time: TimeInterval)?

    init(readSnapshot: @escaping () -> DiskSnapshot = SSDMonitor.systemSnapshot,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         date: @escaping () -> Date = Date.init) {
        self.readSnapshot = readSnapshot
        self.uptime = uptime
        self.date = date
    }

    func sample() -> IndicatorReading {
        let snapshot = readSnapshot()
        let now = date(), time = uptime()
        var reading = IndicatorReading(id: .ssd, value: "—", detail: "", sampledAt: now)
        reading.hardwareName = snapshot.name
        var notes: [String] = []
        if let counters = snapshot.counters {
            if let previous = baseline, let activity = counters.activity(since: previous.counters, seconds: time - previous.time) {
                reading.value = IndicatorReading.percent(activity.active)
                reading.numericValue = activity.active
                reading.readRate = activity.read
                reading.writeRate = activity.write
                notes.append("Tempo ativo entre as duas últimas leituras.")
                if let rates = reading.ratesText { notes.append("Leitura e escrita: \(rates).") }
            } else {
                notes.append("Aguardando segunda amostra para calcular a atividade do SSD.")
            }
            baseline = (counters, time)
        } else {
            baseline = nil
            notes.append("Contadores do disco interno indisponíveis.")
        }
        if let total = snapshot.totalBytes, let available = snapshot.availableBytes, total > 0, available >= 0, available <= total {
            reading.totalBytes = total
            reading.usedBytes = total - available
            if let free = reading.freeSpaceText, let size = BarText.size(total) { notes.append("\(free) de \(size) no volume de inicialização.") }
        }
        if reading.numericValue == nil && reading.totalBytes == nil { return .unavailable(.ssd, notes.joined(separator: " ")) }
        reading.detail = ([snapshot.name].compactMap { $0 } + notes).joined(separator: " · ")
        return reading
    }

    static func systemSnapshot() -> DiskSnapshot {
        let disk = internalDisk()
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return DiskSnapshot(counters: disk?.counters, name: disk?.name,
                            totalBytes: values?.volumeTotalCapacity.map(Double.init),
                            availableBytes: values?.volumeAvailableCapacityForImportantUsage.map(Double.init))
    }

    struct BlockDevice { var counters: DiskCounters; var name: String?; var isInternal: Bool; var solidState: Bool }

    /// Internal solid-state device first; the built-in SD reader is also "Internal", so the medium type decides.
    static func choose(_ devices: [BlockDevice]) -> BlockDevice? {
        devices.first { $0.isInternal && $0.solidState }
            ?? devices.filter(\.isInternal).max { $0.counters.bytesRead + $0.counters.bytesWritten < $1.counters.bytesRead + $1.counters.bytesWritten }
    }

    private static func internalDisk() -> (counters: DiskCounters, name: String?)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var devices: [BlockDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { continue }
            func value(_ key: String) -> Double { (stats[key] as? NSNumber)?.doubleValue ?? 0 }
            let counters = DiskCounters(bytesRead: value("Bytes (Read)"), bytesWritten: value("Bytes (Write)"),
                                        busyNanoseconds: value("Total Time (Read)") + value("Total Time (Write)"))
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(parent) }
            func dictionary(_ key: String) -> [String: Any]? {
                IORegistryEntryCreateCFProperty(parent, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
            }
            let protocolInfo = dictionary("Protocol Characteristics"), device = dictionary("Device Characteristics")
            let name = (device?["Product Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            devices.append(BlockDevice(counters: counters, name: name?.isEmpty == false ? name : nil,
                                       isInternal: protocolInfo?["Physical Interconnect Location"] as? String == "Internal",
                                       solidState: device?["Medium Type"] as? String == "Solid State"))
        }
        return choose(devices).map { ($0.counters, $0.name) }
    }
}
