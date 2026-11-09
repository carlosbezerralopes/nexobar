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
    private let cpuWorker = #"{"v":1,"host":"worker-cpu","ts":1000,"cpu":{"uso":3,"temp":null,"load1":0.5},"ram":{"usada_gb":4,"total_gb":16,"swap_gb":0},"ssd":{"uso":50,"livre_gb":100,"temp":null},"gpu":null,"ventoinhas_rpm":[],"top_cpu":[],"recebido":1002}"#

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
        XCTAssertEqual(gpu.reading?.topProcesses.map(\.nome), ["ffmpeg"], "0% depois de arredondar não aparece")
        var reading = gpu.reading!
        reading.top_cpu = [.init(pid: 1, cpu: 0.4, ram_mb: nil, nome: "a", cmd: nil), .init(pid: 2, cpu: 0.5, ram_mb: nil, nome: "b", cmd: nil),
                           .init(pid: 3, cpu: 3, ram_mb: nil, nome: "c", cmd: nil), .init(pid: 4, cpu: 2, ram_mb: nil, nome: "d", cmd: nil),
                           .init(pid: 5, cpu: 1, ram_mb: nil, nome: "e", cmd: nil)]
        XCTAssertEqual(reading.topProcesses.map(\.nome), ["c", "d", "e"])
        XCTAssertEqual(gpu.reading?.ram?.displayTotal, 32, "total exibido é a RAM instalada")
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
    private func worker(_ id: String, fresh: Bool = true) -> WorkerSnapshot {
        var reading = WorkerReading(); reading.recebido = fresh ? 1000 : 0; reading.host = id == "mac" ? "MacBook Pro" : id
        return WorkerSnapshot(id: id, reading: reading, connection: nil)
    }
    private let all = ["worker-c", "mac", "worker-a", "worker-b"]

    func testAutomaticOrderPutsTheMacFirstThenWorkersAlphabetically() {
        let result = WorkersLayout.arrange(all.map { worker($0) }, config: WidgetLayoutConfig())
        XCTAssertEqual(result.map(\.id), ["mac", "worker-a", "worker-b", "worker-c"])
        XCTAssertEqual(result.map(\.position), [0, 1, 2, 3])
        XCTAssertEqual(result.map(\.displayName), ["MacBook Pro", "a", "b", "c"])
    }

    func testChosenPositionsAndNicknamesFollowThePC() {
        var config = WidgetLayoutConfig()
        config.assign(position: 0, worker: "worker-c", nickname: " GPU ")
        config.assign(position: 2, worker: "mac", nickname: "")
        let result = WorkersLayout.arrange(all.map { worker($0) }, config: config)
        XCTAssertEqual(result.map(\.id), ["worker-c", "worker-a", "mac", "worker-b"])
        XCTAssertEqual(result.map(\.displayName), ["GPU", "a", "MacBook Pro", "b"])
        config.assign(position: 3, worker: "worker-c", nickname: "GPU")
        XCTAssertEqual(config.ordem, [nil, nil, "mac", "worker-c"], "escolher um PC já posicionado troca as posições")
        XCTAssertEqual(WorkersLayout.arrange(all.map { worker($0) }, config: config).last?.displayName, "GPU")
    }

    func testChosenPCMissingFromFolderStaysVisibleWithoutReading() {
        var config = WidgetLayoutConfig(); config.assign(position: 1, worker: "worker-z", nickname: "Desk")
        let result = WorkersLayout.arrange([worker("mac")], config: config)
        XCTAssertEqual(result.map(\.displayName), ["MacBook Pro", "Desk"])
        XCTAssertEqual(result.map(\.position), [0, 1])
        XCTAssertNil(result[1].reading)
    }

    func testConfigRoundTripsAndLoadAllAddsTheMacFromTheAppFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NexoBar/layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workers = root.appendingPathComponent("workers"), app = root.appendingPathComponent("app")
        var config = WidgetLayoutConfig(); config.assign(position: 1, worker: "mac", nickname: "Mac")
        try config.save(directory: app)
        XCTAssertEqual(WidgetLayoutConfig.load(directory: app), config)
        XCTAssertEqual(WidgetLayoutConfig.load(directory: workers), WidgetLayoutConfig(), "sem arquivo, tudo automático")
        try FileManager.default.createDirectory(at: workers, withIntermediateDirectories: true)
        try Data(#"{"v":1,"recebido":1}"#.utf8).write(to: workers.appendingPathComponent("worker-a.json"))
        try Data(#"{"v":1,"host":"Mac","recebido":1}"#.utf8).write(to: app.appendingPathComponent("mac.json"))
        XCTAssertEqual(WorkersTelemetry.loadAll(workers: workers, app: app).map(\.id), ["worker-a", "mac"], "posicoes.json não vira cartão")
    }
}

final class WakeMarksTests: XCTestCase {
    func testMarkShowsWakingUntilClearedOrExpiredAndIsNotACard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NexoBar/wake-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workers = root.appendingPathComponent("workers"), app = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: workers, withIntermediateDirectories: true)
        try Data(#"{"v":1,"recebido":1}"#.utf8).write(to: workers.appendingPathComponent("worker-a.json"))
        let start = Date(timeIntervalSince1970: 10_000)
        try WakeMarks.set("worker-a", waking: true, directory: app, now: start)
        XCTAssertEqual(WorkersTelemetry.loadAll(workers: workers, app: app, now: start.addingTimeInterval(60)).map(\.waking), [true])
        XCTAssertEqual(WorkersTelemetry.loadAll(workers: workers, app: app, now: start.addingTimeInterval(301)).map(\.waking), [false], "marca vencida")
        try WakeMarks.set("worker-a", waking: false, directory: app, now: start)
        XCTAssertTrue(WakeMarks.load(directory: app, now: start).isEmpty)
        XCTAssertEqual(WorkersTelemetry.loadAll(workers: workers, app: app, now: start).map(\.id), ["worker-a"], "acordando.json não vira cartão")
    }
}
