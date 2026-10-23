import XCTest
@testable import NexoBar

final class HardwareSensorsTests: XCTestCase {
    func testSMCABI() {
        XCTAssertEqual(MemoryLayout<SMCMessage>.stride, 80)
        XCTAssertEqual(MemoryLayout<SMCMessage>.offset(of: \.keyInfo), 28)
        XCTAssertEqual(MemoryLayout<SMCMessage>.offset(of: \.result), 40)
        XCTAssertEqual(MemoryLayout<SMCMessage>.offset(of: \.command), 42)
        XCTAssertEqual(MemoryLayout<SMCMessage>.offset(of: \.bytes), 48)
    }

    func testSMCFloatingPointAndSignedFixedPoint() {
        XCTAssertEqual(HardwareSensorDecoding.smcValue(type: "flt ", bytes: [0, 0, 0x50, 0x42]), 52)
        XCTAssertEqual(HardwareSensorDecoding.smcValue(type: "sp78", bytes: [0x2a, 0x80]), 42.5)
        XCTAssertNil(HardwareSensorDecoding.smcValue(type: "sp78", bytes: [0xff, 0x80]))
    }

    func testRejectsMissingUnsupportedMalformedAndSentinelValues() {
        for bytes: [UInt8] in [[], [0], [0, 0], [0, 0, 0], [0, 0, 0, 0, 0]] {
            XCTAssertNil(HardwareSensorDecoding.smcValue(type: "flt ", bytes: bytes))
        }
        XCTAssertNil(HardwareSensorDecoding.smcValue(type: "flt ", bytes: [0, 0, 0, 0]))
        XCTAssertNil(HardwareSensorDecoding.smcValue(type: "flt ", bytes: [0, 0, 0, 0x43])) // 128
        XCTAssertNil(HardwareSensorDecoding.smcValue(type: "flt ", bytes: [0, 0, 0x80, 0x7f])) // inf
        XCTAssertNil(HardwareSensorDecoding.smcValue(type: "flt ", bytes: [0, 0, 0xc0, 0x7f])) // NaN
        XCTAssertNil(HardwareSensorDecoding.smcValue(type: "sp78", bytes: [0x80, 0]))
        XCTAssertNil(HardwareSensorDecoding.smcValue(type: "ui32", bytes: [0, 0, 0, 52]))
    }

    func testGPUOnlyUsesActualPercentageCounters() {
        XCTAssertEqual(HardwareSensorDecoding.gpuUsage(["Device Utilization %": 0]), 0)
        XCTAssertEqual(HardwareSensorDecoding.gpuUsage(["Device Utilization %": 51.5, "GPU Activity(%)": 22]), 51.5)
        XCTAssertEqual(HardwareSensorDecoding.gpuUsage(["GPU Activity(%)": 100]), 100)
        XCTAssertNil(HardwareSensorDecoding.gpuUsage(["Renderer Utilization %": 60]))
        XCTAssertNil(HardwareSensorDecoding.gpuUsage(["Device Utilization %": true]))
        XCTAssertNil(HardwareSensorDecoding.gpuUsage(["Device Utilization %": "20"]))
        for value in [-1.0, 100.1, Double.nan, Double.infinity] {
            XCTAssertNil(HardwareSensorDecoding.gpuUsage(["Device Utilization %": value]))
        }
    }

    func testMapsKnownGenerationsWithoutGuessingUnknown() throws {
        let m5 = try XCTUnwrap(HardwareSensorDecoding.temperatureKeys(model: "Apple M5 Pro"))
        XCTAssertTrue(m5.cpu.contains("Tp00"))
        XCTAssertTrue(m5.gpu.contains("Tg0U"))
        XCTAssertFalse(m5.cpu.contains("Tp01"))
        XCTAssertNil(HardwareSensorDecoding.temperatureKeys(model: "Unknown Apple chip"))
        XCTAssertNil(HardwareSensorDecoding.temperatureKeys(model: "Apple M10 Pro"))
        let m3 = try XCTUnwrap(HardwareSensorDecoding.temperatureKeys(model: "Apple M3 Max"))
        XCTAssertTrue(m3.cpu.contains("Tf04"))
        XCTAssertTrue(m3.gpu.contains("Tf14"))
        XCTAssertFalse(m3.cpu.contains("Tf14"))
        let m4 = try XCTUnwrap(HardwareSensorDecoding.temperatureKeys(model: "Apple M4"))
        let m4Pro = try XCTUnwrap(HardwareSensorDecoding.temperatureKeys(model: "Apple M4 Pro"))
        XCTAssertTrue(m4.gpu.contains("Tg0G"))
        XCTAssertFalse(m4Pro.gpu.contains("Tg0G"))
        XCTAssertTrue(m4Pro.gpu.contains("Tg1U"))
    }

    func testMaximumAndAverageAreExplicitAndFailuresNeverBecomeZero() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var snapshot = HardwareSnapshot(gpuPercent: 12, gpuDetail: "driver fixture",
            cpuTemperatures: [.init(key: "A", celsius: 40), .init(key: "B", celsius: 60), .init(key: "sentinel", celsius: 128)],
            gpuTemperatures: [], temperatureDetail: "fixture sem hardware")
        let collector = HardwareSensors(readSnapshot: { snapshot }, date: { now })
        let first = collector.sample()
        XCTAssertEqual(first.map(\.id), [.gpu, .cpuTemperature, .gpuTemperature])
        XCTAssertEqual(first[0].value, "12%")
        XCTAssertEqual(first[1].value, "60 °C")
        XCTAssertTrue(first[1].detail.contains("2 sensores"))
        XCTAssertEqual(first[1].numericValue, 60)
        XCTAssertTrue(first[1].detail.contains("média 50.0 °C"))
        XCTAssertEqual(first[1].sampledAt, now)
        XCTAssertEqual(first[2].value, "—")
        XCTAssertNil(first[2].sampledAt)
        snapshot.gpuPercent = nil
        snapshot.cpuTemperatures = []
        XCTAssertTrue(collector.sample().allSatisfy { $0.value == "—" && $0.sampledAt == nil })
    }
}
