import Darwin
import Foundation

struct CPUTicks {
    var user: UInt64
    var system: UInt64
    var idle: UInt64
    var nice: UInt64

    func usage(since previous: Self) -> Double? {
        let current = [user, system, idle, nice]
        let old = [previous.user, previous.system, previous.idle, previous.nice]
        guard zip(current, old).allSatisfy({ $0 >= $1 }) else { return nil }
        let deltas = zip(current, old).map { Double($0 - $1) }
        let total = deltas.reduce(0, +)
        guard total > 0 else { return nil }
        return (deltas[0] + deltas[1] + deltas[3]) / total * 100
    }
}

struct PhysicalMemorySample {
    var activePages: UInt64
    var wiredPages: UInt64
    var compressedPages: UInt64
    var pageSize: UInt64
    var totalBytes: UInt64

    // (active + wired + resident compressor pages) × page size / physical RAM.
    // Compressor pages are counted once; inactive/file cache is excluded.
    var usedBytes: Double? {
        guard pageSize > 0, totalBytes > 0 else { return nil }
        let bytes = (Double(activePages) + Double(wiredPages) + Double(compressedPages)) * Double(pageSize)
        guard bytes.isFinite, bytes <= Double(totalBytes) else { return nil }
        return bytes
    }
    var usedPercent: Double? { usedBytes.map { $0 / Double(totalBytes) * 100 } }
}

/// Main-thread sampler. Keeps only the CPU baseline in memory; never starts a process.
final class MachineMonitor {
    private let readCPU: () -> CPUTicks?
    private let readMemory: () -> PhysicalMemorySample?
    private let uptime: () -> TimeInterval
    private let date: () -> Date
    private var baseline: (ticks: CPUTicks, time: TimeInterval)?

    init(readCPU: @escaping () -> CPUTicks? = MachineMonitor.cpuTicks,
         readMemory: @escaping () -> PhysicalMemorySample? = MachineMonitor.physicalMemory,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         date: @escaping () -> Date = Date.init) {
        self.readCPU = readCPU
        self.readMemory = readMemory
        self.uptime = uptime
        self.date = date
    }

    func sample() -> [IndicatorReading] {
        let sampledAt = date()
        let time = uptime()
        let cpu: IndicatorReading
        if let ticks = readCPU() {
            defer { baseline = (ticks, time) }
            if let previous = baseline {
                let elapsed = time - previous.time
                if elapsed <= 0 || elapsed > 15 {
                    cpu = .unavailable(.cpu, "Intervalo de coleta inválido ou maior que 15 s; aguardando nova amostra.")
                } else if let usage = ticks.usage(since: previous.ticks) {
                    cpu = IndicatorReading(id: .cpu, value: IndicatorReading.percent(usage),
                        detail: "Uso total da máquina entre as duas últimas leituras.", sampledAt: sampledAt, numericValue: usage)
                } else {
                    cpu = .unavailable(.cpu, "Contadores reiniciados ou sem avanço; aguardando nova amostra.")
                }
            } else {
                cpu = .unavailable(.cpu, "Aguardando segunda amostra para calcular o uso da CPU.")
            }
        } else {
            baseline = nil
            cpu = .unavailable(.cpu, "Falha na leitura da CPU; aguardando nova amostra.")
        }

        let memory: IndicatorReading
        if let snapshot = readMemory(), let usage = snapshot.usedPercent, let bytes = snapshot.usedBytes {
            let gib = bytes / 1_073_741_824
            let totalGiB = Double(snapshot.totalBytes) / 1_073_741_824
            memory = IndicatorReading(id: .memory, value: IndicatorReading.percent(usage),
                detail: String(format: "%.1f de %.1f GiB · memória ativa, reservada pelo sistema e comprimida; exclui cache inativo.", gib, totalGiB), sampledAt: sampledAt, usedBytes: bytes, totalBytes: Double(snapshot.totalBytes), numericValue: usage)
        } else {
            memory = .unavailable(.memory, "Falha ou contadores inválidos na leitura de memória física.")
        }
        return [cpu, memory,
            .unavailable(.gpu, "Uso da GPU indisponível: esta prévia não dispõe de um contador público e suportado de utilização global do macOS."),
            .unavailable(.cpuTemperature, "Sensor de temperatura da CPU indisponível por API pública suportada, sem privilégios; nenhum valor é estimado."),
            .unavailable(.gpuTemperature, "Sensor de temperatura da GPU indisponível por API pública suportada, sem privilégios; nenhum valor é estimado.")]
    }

    private static func cpuTicks() -> CPUTicks? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = host_cpu_load_info_data_t()
        let expectedCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var count = expectedCount
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS, count >= expectedCount else { return nil }
        return CPUTicks(user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
                        idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
    }

    private static func physicalMemory() -> PhysicalMemorySample? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        var info = vm_statistics64_data_t()
        let expectedCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var count = expectedCount
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS, count >= expectedCount else { return nil }
        return PhysicalMemorySample(activePages: UInt64(info.active_count), wiredPages: UInt64(info.wire_count),
            compressedPages: UInt64(info.compressor_page_count), pageSize: UInt64(pageSize),
            totalBytes: ProcessInfo.processInfo.physicalMemory)
    }
}
