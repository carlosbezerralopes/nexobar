import XCTest
@testable import NexoBar
import WorkersTelemetry

final class MacTelemetryTests: XCTestCase {
    func testTopProcessesComeFromPsSortedByCPU() {
        let top = MacTelemetry.parseTop("""
              1   0,0   16384 launchd
            812  12.5  204800 Google Chrome Helper
            900   3.0   10240 claude
            901   7.0    1024 WindowServer
            lixo
            """)
        XCTAssertEqual(top.map { $0["nome"] as? String }, ["Google Chrome Helper", "WindowServer", "claude"])
        XCTAssertEqual(top.first?["ram_mb"] as? Double, 200)
    }

    func testClaudeSessionsSkipTheRemoteControlProcess() {
        let output = """
            /opt/fixture/bin/claude
            claude --resume
            /opt/fixture/bin/claude remote-control --prefix mac
            /opt/fixture/share/claude/versions/2.1.319 --print --sdk-url https://x
            /Applications/Claude.app/Contents/MacOS/Claude
            /opt/fixture/Application Support/Claude/claude-code/2.1.317/abc/claude.app/Contents/MacOS/claude --output-format stream-json
            node /tmp/claudette.js
            """
        XCTAssertEqual(MacTelemetry.countClaude(output), 4)
    }

    func testDiskActivityIsBusyTimeOverTheIntervalAndRejectsResets() {
        let a = MacTelemetry.DiskCounters(bytesRead: 0, bytesWritten: 0, busyNanoseconds: 0)
        let b = MacTelemetry.DiskCounters(bytesRead: 10_485_760, bytesWritten: 5_242_880, busyNanoseconds: 1.4e9)
        let rates = MacTelemetry.diskActivity(from: a, to: b, seconds: 5)
        XCTAssertEqual(rates?.active, 28)
        XCTAssertEqual(rates?.read, 2_097_152)
        XCTAssertEqual(rates?.write, 1_048_576)
        XCTAssertEqual(MacTelemetry.diskActivity(from: a, to: MacTelemetry.DiskCounters(bytesRead: 0, bytesWritten: 0, busyNanoseconds: 9e9), seconds: 5)?.active, 100)
        XCTAssertNil(MacTelemetry.diskActivity(from: b, to: a, seconds: 5))
        XCTAssertNil(MacTelemetry.diskActivity(from: a, to: b, seconds: 0))
    }

    func testWrittenFileDecodesAsAWorkerReadingWithoutInventedValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NexoBar/mac-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try MacTelemetry().write(hardware: .init(cpu: 12.4, cpuTemperature: nil, gpu: 3, gpuTemperature: 41.6, memoryUsedBytes: 8 * 1_073_741_824),
                                 now: Date(timeIntervalSince1970: 1000), directory: directory)
        let snapshot = try XCTUnwrap(WorkersTelemetry.load(directory: directory).first)
        XCTAssertEqual(snapshot.id, "mac")
        let reading = try XCTUnwrap(snapshot.reading)
        XCTAssertEqual(reading.cpu?.uso, 12)
        XCTAssertNil(reading.cpu?.temp)
        XCTAssertEqual(reading.gpu?.temp, 42)
        XCTAssertNotNil(reading.gpu?.vram_total_mb, "limite da GPU pelo Metal")
        XCTAssertNil(reading.gpu?.watts, "watts só a partir da segunda leitura")
        XCTAssertEqual(reading.ram?.usada_gb, 8)
        XCTAssertEqual(reading.ram?.instalada_gb, (Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        XCTAssertEqual(reading.recebido, 1000)
        XCTAssertNil(reading.ssd?.ativo, "a primeira leitura não tem intervalo para o tempo ativo")
    }
}

final class SMCNumberTests: XCTestCase {
    func testFanSpeedIsReadWithoutTheTemperatureFilter() {
        let rpm: [UInt8] = [0, 64, 169, 68]   // flt 1354, medido no F0Ac de um Mac17,8
        XCTAssertEqual(HardwareSensorDecoding.smcNumber(type: "flt ", bytes: rpm), 1354)
        XCTAssertNil(HardwareSensorDecoding.smcValue(type: "flt ", bytes: rpm), "1354 não é temperatura")
    }
}

final class GPUEnergyTests: XCTestCase {
    func testEnergyUnitsConvertToJoulesAndUnknownUnitsAreDropped() {
        XCTAssertEqual(GPUEnergy.joules(139_193_801, unit: "nJ"), 0.139193801)
        XCTAssertEqual(GPUEnergy.joules(2500, unit: "mJ"), 2.5)
        XCTAssertEqual(GPUEnergy.joules(2_000_000, unit: "uJ"), 2)
        XCTAssertNil(GPUEnergy.joules(5, unit: "W"))
    }

    func testSecondSampleGivesWattsWhenIOReportIsAvailable() {
        let energy = GPUEnergy()
        XCTAssertNil(energy.watts(uptime: 1), "primeira leitura não tem intervalo")
        Thread.sleep(forTimeInterval: 0.3)
        if let watts = energy.watts(uptime: 1.3) { XCTAssertGreaterThanOrEqual(watts, 0) }
    }
}

final class WorkerWakerTests: XCTestCase {
    func testOnlyWorkersWithTheScriptPresentCanBeWoken() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("NexoBar/waker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let script = WorkerWaker.script(home: home)
        XCTAssertFalse(WorkerWaker.canWake("worker-a", script: script), "sem o script do ~/.agents, sem a opção")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("exit 0".utf8).write(to: script)
        XCTAssertTrue(WorkerWaker.canWake("worker-a", script: script))
        XCTAssertFalse(WorkerWaker.canWake("mac", script: script), "o Mac não se acorda")
    }
}
