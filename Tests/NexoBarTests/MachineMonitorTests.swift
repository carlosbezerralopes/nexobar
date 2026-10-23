import XCTest
@testable import NexoBar

final class MachineMonitorTests: XCTestCase {
    func testCPUUsesDeltasAndIncludesNice() {
        let previous = CPUTicks(user: 100, system: 50, idle: 800, nice: 50)
        let current = CPUTicks(user: 110, system: 70, idle: 860, nice: 60)
        XCTAssertEqual(current.usage(since: previous)!, 40, accuracy: 0.001)
        XCTAssertNil(previous.usage(since: previous))
        XCTAssertNil(previous.usage(since: current))
    }

    func testFirstSampleFailureAndRecoveryDoNotInventCPUZero() {
        var ticks: CPUTicks? = CPUTicks(user: 1, system: 1, idle: 2, nice: 0)
        var time = 1.0
        let monitor = MachineMonitor(readCPU: { ticks }, readMemory: { nil }, uptime: { time })
        XCTAssertEqual(monitor.sample()[0].value, "—")
        time += 3
        ticks = CPUTicks(user: 3, system: 3, idle: 8, nice: 0)
        XCTAssertEqual(monitor.sample()[0].value, "40%")
        ticks = nil
        time += 3
        let failure = monitor.sample()[0]
        XCTAssertEqual(failure.value, "—")
        XCTAssertNil(failure.sampledAt)
        ticks = CPUTicks(user: 10, system: 10, idle: 20, nice: 0)
        time += 3
        XCTAssertEqual(monitor.sample()[0].value, "—")
        ticks = CPUTicks(user: 10, system: 10, idle: 30, nice: 0)
        time += 3
        XCTAssertEqual(monitor.sample()[0].value, "0%")
    }

    func testResetAndSuspensionRequireFreshDelta() {
        var ticks = CPUTicks(user: 100, system: 100, idle: 100, nice: 0)
        var time = 1.0
        let monitor = MachineMonitor(readCPU: { ticks }, readMemory: { nil }, uptime: { time })
        _ = monitor.sample()
        ticks = CPUTicks(user: 1, system: 1, idle: 1, nice: 0)
        time += 3
        XCTAssertEqual(monitor.sample()[0].value, "—")
        ticks = CPUTicks(user: 2, system: 2, idle: 3, nice: 0)
        time += 3
        XCTAssertEqual(monitor.sample()[0].value, "50%")
        time += 60
        ticks = CPUTicks(user: 3, system: 3, idle: 5, nice: 0)
        XCTAssertEqual(monitor.sample()[0].value, "—")
        time += 3
        ticks = CPUTicks(user: 4, system: 4, idle: 7, nice: 0)
        XCTAssertEqual(monitor.sample()[0].value, "50%")
    }

    func testMemoryFormulaAndInvalidValues() {
        let memory = PhysicalMemorySample(activePages: 100, wiredPages: 50, compressedPages: 25, pageSize: 4096, totalBytes: 4096 * 1000)
        XCTAssertEqual(memory.usedBytes, 4096 * 175)
        XCTAssertEqual(memory.usedPercent!, 17.5, accuracy: 0.001)
        XCTAssertNil(PhysicalMemorySample(activePages: 100, wiredPages: 0, compressedPages: 0, pageSize: 0, totalBytes: 1).usedPercent)
        XCTAssertNil(PhysicalMemorySample(activePages: 100, wiredPages: 0, compressedPages: 0, pageSize: 4096, totalBytes: 0).usedPercent)
        XCTAssertNil(PhysicalMemorySample(activePages: UInt64.max, wiredPages: UInt64.max, compressedPages: 1, pageSize: 4096, totalBytes: 1).usedPercent)
    }

    func testUnavailableSensorsAreExplicitAndMemoryHasTimestamp() {
        let date = Date(timeIntervalSince1970: 42)
        let monitor = MachineMonitor(readCPU: { nil }, readMemory: {
            PhysicalMemorySample(activePages: 1, wiredPages: 1, compressedPages: 1, pageSize: 4096, totalBytes: 40960)
        }, date: { date })
        let readings = monitor.sample()
        XCTAssertEqual(readings.map(\.id), [.cpu, .memory, .gpu, .cpuTemperature, .gpuTemperature])
        XCTAssertEqual(readings[1].value, "30%")
        XCTAssertEqual(readings[1].sampledAt, date)
        XCTAssertTrue(readings[1].detail.contains("exclui cache inativo"))
        for reading in readings.suffix(3) {
            XCTAssertEqual(reading.value, "—")
            XCTAssertNil(reading.sampledAt)
            XCTAssertTrue(reading.detail.contains("indisponível"))
        }
    }
}
