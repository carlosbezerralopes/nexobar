import XCTest
@testable import WorkersTelemetry

final class WorkersTelemetryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("NexoBar/workers-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func write(_ name: String, _ json: String) throws {
        try Data(json.utf8).write(to: directory.appendingPathComponent(name))
    }

    private let gpuWorker = #"{"v":1,"host":"worker-gpu","ts":1000,"hora":"x","cpu":{"uso":12.4,"temp":49,"load1":0.16},"ram":{"usada_gb":2.3,"total_gb":31,"instalada_gb":32,"swap_gb":0.8},"ssd":{"uso":21,"livre_gb":691,"temp":35},"gpu":{"uso":0,"temp":46,"vram_mb":1500,"vram_total_mb":6144,"watts":5.23,"processos":[{"pid":9,"vram_mb":200,"nome":"python"},{"pid":8,"vram_mb":1200,"nome":"comfy"}]},"ventoinhas_rpm":[0,2100],"perfil":"balanced","top_cpu":[{"pid":1,"cpu":0.0,"ram_mb":15,"nome":"systemd","cmd":""},{"pid":7,"cpu":35.5,"ram_mb":900,"nome":"ffmpeg","cmd":"ffmpeg -i"}],"ltx":null,"claude_sessoes":2,"recebido":1004}"#
    private let cpuWorker = #"{"v":1,"host":"worker-cpu","ts":1000,"cpu":{"uso":3,"temp":null,"load1":0.5},"ram":{"usada_gb":4,"total_gb":16,"swap_gb":0},"ssd":{"uso":50,"livre_gb":100,"temp":null},"gpu":null,"gpu_intel":{"ativo":7},"ventoinhas_rpm":[],"top_cpu":[],"recebido":1002}"#

    func testLoadsReadingsAndConnectionStatesWithoutInventingZeros() throws {
        try write("worker-gpu.json", gpuWorker)
        try write("worker-gpu.estado.json", #"{"estado":"conectado","detalhe":"","desde":900}"#)
        try write("worker-cpu.json", cpuWorker)
        try write("worker-off.estado.json", #"{"estado":"desconectado","detalhe":"ssh: host down","desde":990}"#)
        try write("notas.txt", "ignorar")
        let workers = WorkersTelemetry.load(directory: directory)
        XCTAssertEqual(workers.map(\.id), ["worker-cpu", "worker-gpu", "worker-off"])
        let gpu = workers[1]
        XCTAssertEqual(gpu.displayName, "gpu")
        XCTAssertEqual(gpu.reading?.topCPU?.nome, "ffmpeg")
        XCTAssertEqual(gpu.reading?.topGPU?.nome, "comfy")
        XCTAssertEqual(gpu.reading?.topProcesses.map(\.nome), ["ffmpeg", "systemd"])
        XCTAssertEqual(gpu.reading?.ram?.displayTotal, 32, "total exibido é a RAM instalada")
        XCTAssertNil(gpu.reading?.gpu_intel)
        XCTAssertEqual(workers[0].reading?.gpu_intel?.ativo, 7)
        XCTAssertEqual(workers[0].reading?.ram?.displayTotal, 16, "sem instalada, usa o total do kernel")
        XCTAssertEqual(gpu.reading?.claude_sessoes, 2)
        XCTAssertNil(workers[0].reading?.claude_sessoes, "ausente não vira zero")
        XCTAssertEqual(gpu.connection?.estado, .conectado)
        let cpu = workers[0]
        XCTAssertNil(cpu.reading?.gpu)
        XCTAssertNil(cpu.reading?.cpu?.temp)
        XCTAssertNil(cpu.reading?.topCPU)
        XCTAssertNil(cpu.reading?.ssd?.ativo, "espaço ocupado não substitui o tempo ativo")
        XCTAssertEqual(cpu.reading?.ssd?.uso, 50)
        XCTAssertNil(cpu.connection)
        XCTAssertNil(workers[2].reading)
        XCTAssertEqual(workers[2].connection?.detalhe, "ssh: host down")
    }

    func testCorruptFileKeepsTheWorkerVisibleWithoutReading() throws {
        try write("worker-x.json", "{trunc")
        let workers = WorkersTelemetry.load(directory: directory)
        XCTAssertEqual(workers.map(\.id), ["worker-x"])
        XCTAssertNil(workers[0].reading)
        XCTAssertTrue(workers[0].isStale(at: Date(timeIntervalSince1970: 0)))
    }

    func testMissingDirectoryIsEmpty() {
        XCTAssertTrue(WorkersTelemetry.load(directory: directory.appendingPathComponent("nada")).isEmpty)
    }

    func testStaleAfterSixtySecondsFromReceptionOrWhenDisconnected() throws {
        let reading = try JSONDecoder().decode(WorkerReading.self, from: Data(gpuWorker.utf8))
        var worker = WorkerSnapshot(id: "worker-gpu", reading: reading, connection: .init(estado: .conectado, detalhe: nil, desde: 0))
        XCTAssertFalse(worker.isStale(at: Date(timeIntervalSince1970: 1064)))
        XCTAssertTrue(worker.isStale(at: Date(timeIntervalSince1970: 1065)))
        worker.connection?.estado = .desconectado
        XCTAssertTrue(worker.isStale(at: Date(timeIntervalSince1970: 1005)))
        worker.connection?.estado = .conectando
        XCTAssertTrue(worker.isStale(at: Date(timeIntervalSince1970: 1005)))
    }

    func testTimelineMarksEachFreshWorkerWhenItExpires() throws {
        let reading = try JSONDecoder().decode(WorkerReading.self, from: Data(gpuWorker.utf8))
        var other = reading; other.recebido = 1020
        let workers = [WorkerSnapshot(id: "a", reading: reading, connection: nil),
                       WorkerSnapshot(id: "b", reading: other, connection: nil),
                       WorkerSnapshot(id: "c", reading: nil, connection: .init(estado: .desconectado, detalhe: nil, desde: 0))]
        let now = Date(timeIntervalSince1970: 1010)
        XCTAssertEqual(WorkersTelemetry.transitionDates(workers, after: now).map(\.timeIntervalSince1970), [1065, 1081])
    }

    func testFormatsInPortugueseAndShowsMissingAsDash() {
        XCTAssertEqual(WorkerFormat.percent(12.6), "13%")
        XCTAssertEqual(WorkerFormat.percent(nil), "—")
        XCTAssertEqual(WorkerFormat.percent(.nan), "—")
        XCTAssertEqual(WorkerFormat.temperature(48.6), "49°")
        XCTAssertEqual(WorkerFormat.gigabytes(2.34), "2,3")
        XCTAssertEqual(WorkerFormat.gigabytes(691.4), "691")
        XCTAssertEqual(WorkerFormat.megabytesAsGB(15), "15 MB")
        XCTAssertEqual(WorkerFormat.megabytesAsGB(6144), "6 GB")
        XCTAssertEqual(WorkerFormat.megabytesAsGB(1536), "1,5 GB")
        XCTAssertEqual(WorkerFormat.watts(5.23), "5,2W")
        XCTAssertEqual(WorkerFormat.load(0.16), "0,16")
        XCTAssertEqual(WorkerFormat.rates(read: 1.2 * 1_048_576, write: 400 * 1024), "L 1,2 E 0,4 MB/s")
        XCTAssertEqual(WorkerFormat.rates(read: 2048, write: 0), "L 2 E 0 KB/s")
        XCTAssertNil(WorkerFormat.rates(read: nil, write: 10))
        XCTAssertEqual(WorkerFormat.fans([0, 2100]), "0 · 2100 rpm")
        XCTAssertEqual(WorkerFormat.fans([]), "—")
        XCTAssertEqual(WorkerFormat.count(0), "0")
        XCTAssertEqual(WorkerFormat.vram(used: 15, total: 6144), "0/6 GB")
        XCTAssertEqual(WorkerFormat.vram(used: 1229, total: 6144), "1,2/6 GB")
        XCTAssertEqual(WorkerFormat.vram(used: nil, total: 6144), "—")
        XCTAssertEqual(WorkerFormat.count(nil), "—")
        XCTAssertEqual(WorkerFormat.fans(nil), "—")
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(WorkerFormat.time(Date(timeIntervalSince1970: 3661), timeZone: utc), "01:01:01")
        XCTAssertEqual(WorkerFormat.time(nil), "—")
        let base = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(WorkerFormat.age(from: base, to: Date(timeIntervalSince1970: 75)), "há 75 s")
        XCTAssertEqual(WorkerFormat.age(from: base, to: Date(timeIntervalSince1970: 600)), "há 10 min")
        XCTAssertEqual(WorkerFormat.age(from: nil, to: base), "sem leitura")
    }

    func testHistoryPathIsPreparedPerWorkerAndDay() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let url = WorkersTelemetry.historyURL(worker: "worker-gpu", day: Date(timeIntervalSince1970: 1_794_167_016), directory: directory, calendar: calendar)
        XCTAssertEqual(url.lastPathComponent, "2026-11-08.jsonl")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "worker-gpu")
    }

    func testSignatureChangesWhenAFileIsRewritten() throws {
        try write("worker-gpu.json", gpuWorker)
        let first = WorkersTelemetry.signature(directory: directory)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 5)], ofItemAtPath: directory.appendingPathComponent("worker-gpu.json").path)
        XCTAssertNotEqual(first, WorkersTelemetry.signature(directory: directory))
    }
}

final class WorkersLayoutTests: XCTestCase {
    private func worker(_ id: String, fresh: Bool) -> WorkerSnapshot {
        var reading = WorkerReading(); reading.recebido = fresh ? 1000 : 0
        return WorkerSnapshot(id: id, reading: reading, connection: nil)
    }

    func testNicknameWithoutWorkerIsIgnoredAndOrderIsAlphabetical() {
        let all = [worker("worker-c", fresh: true), worker("worker-a", fresh: false), worker("worker-b", fresh: true)]
        let result = WorkersLayout.arrange(all, slots: [(nil, "Note"), (nil, nil)])
        XCTAssertEqual(result.map(\.id), ["worker-a", "worker-b", "worker-c"])
        XCTAssertEqual(result.map(\.displayName), ["a", "b", "c"])
    }

    func testChosenWorkersComeFirstWithTheirNicknamesAndTheRestFollowWithOwnNames() {
        let all = [worker("worker-a", fresh: true), worker("worker-b", fresh: true), worker("worker-c", fresh: true)]
        let result = WorkersLayout.arrange(all, slots: [("worker-c", " GPU "), (nil, "ignorado"), ("worker-c", "dup"), ("worker-b", "")])
        XCTAssertEqual(result.map(\.id), ["worker-c", "worker-b", "worker-a"])
        XCTAssertEqual(result.map(\.displayName), ["GPU", "b", "a"])
    }

    func testChosenWorkerMissingFromFolderStaysVisibleWithoutReading() {
        let result = WorkersLayout.arrange([], slots: [("worker-z", "Desk"), (nil, "nada")])
        XCTAssertEqual(result.map(\.displayName), ["Desk"])
        XCTAssertNil(result[0].reading)
        XCTAssertTrue(result[0].isStale(at: Date(timeIntervalSince1970: 0)))
    }
}
