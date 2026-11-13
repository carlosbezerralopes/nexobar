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

    private let gpuWorker = #"{"v":1,"host":"worker-gpu","ts":1000,"hora":"x","cpu":{"uso":12.4,"temp":49,"load1":0.16},"ram":{"usada_gb":2.3,"total_gb":31,"instalada_gb":32,"swap_gb":0.8},"ssd":{"uso":21,"livre_gb":691,"temp":35},"gpu":{"uso":0,"temp":46,"vram_mb":1500,"vram_total_mb":6144,"watts":5.23,"processos":[{"pid":9,"vram_mb":200,"nome":"python"},{"pid":8,"vram_mb":1200,"nome":"comfy"}]},"ventoinhas_rpm":[0,2100],"perfil":"balanced","top_cpu":[{"pid":1,"cpu":0.0,"ram_mb":15,"nome":"systemd","cmd":""},{"pid":7,"cpu":35.5,"ram_mb":900,"nome":"ffmpeg","cmd":"ffmpeg -i"}],"ltx":null,"claude_sessoes":2,"uptime_s":273600,"recebido":1004}"#
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
        XCTAssertEqual(gpu.reading?.uptime_s, 273600)
        XCTAssertNil(workers[0].reading?.uptime_s, "coletor antigo: sem uptime")
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
        XCTAssertEqual(WorkerFormat.uptime(273600), "3d 4h")
        XCTAssertEqual(WorkerFormat.uptime(18720), "5h 12min")
        XCTAssertEqual(WorkerFormat.uptime(2559), "42 min")
        XCTAssertEqual(WorkerFormat.uptime(nil), "—")
        XCTAssertEqual(WorkerFormat.uptime(-1), "—")
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

final class QueueTelemetryTests: XCTestCase {
    private let panelJSON = #"""
    {"formato":"fila-painel@1","mestre":"worker-aurora-note","gerado":10000,"vivo_s":120,"orfao_min":15,
     "maquinas":[{"nome":"worker-aurora-desk","batimento":9990,"viva":true,"gpu_livre":0.0,"cpu_livre":850.0,"ram_livre_gb":8.0,"sistema":"linux","vram_gb":11.9},
                 {"nome":"mac-carlos","batimento":null,"viva":false,"gpu_livre":null,"cpu_livre":null,"ram_livre_gb":null,"sistema":null,"vram_gb":null}],
     "itens":[{"estado":"andamento","id":"sdxl","maquina":"worker-aurora-desk","t":9970,"buscado":false},
              {"estado":"andamento","id":"orfao","maquina":"worker-velho","t":9000,"buscado":false},
              {"estado":"livre","id":"b","maquina":null,"t":9500,"buscado":false},
              {"estado":"chegando","id":"a","maquina":null,"t":9400,"buscado":false},
              {"estado":"falha","id":"f1","maquina":null,"t":8000,"buscado":false},
              {"estado":"falha","id":"f2","maquina":null,"t":9000,"buscado":false},
              {"estado":"feito","id":"d1","maquina":null,"t":5000,"buscado":true},
              {"estado":"feito","id":"d2","maquina":null,"t":6000,"buscado":false}]}
    """#

    func testPanelGroupsRunningWaitingFailuresAndCountsDone() throws {
        let panel = try JSONDecoder().decode(QueuePanel.self, from: Data(panelJSON.utf8))
        XCTAssertEqual(panel.running(on: "worker-aurora-desk").map(\.id), ["sdxl"])
        XCTAssertEqual(panel.runningElsewhere.map(\.id), ["orfao"], "máquina fora da lista não some")
        XCTAssertEqual(panel.waiting.map(\.id), ["a", "b"], "ordem de entrada")
        XCTAssertEqual(panel.failures.map(\.id), ["f2", "f1"], "mais recente primeiro")
        XCTAssertEqual(panel.doneCount, 2); XCTAssertEqual(panel.doneToFetch, 1)
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(panel.isAlive(panel.maquinas![0], at: now))
        XCTAssertFalse(panel.isAlive(panel.maquinas![0], at: now.addingTimeInterval(200)), "batimento velho vira desligado na hora de mostrar")
        XCTAssertFalse(panel.isAlive(panel.maquinas![1], at: now), "sem batimento não é viva")
        XCTAssertNil(QueueFormat.freeFraction(panel.maquinas![1].gpu_livre), "ausente não é zero")
        XCTAssertEqual(QueueFormat.freeFraction(850), 0.85)
        XCTAssertEqual(QueueFormat.age(since: 9970, to: now), "agora")
        XCTAssertEqual(QueueFormat.age(since: 9000, to: now), "há 16 min")
        var busy = panel
        busy.itens = (0..<5).map { .init(estado: "andamento", id: "d\($0)", maquina: "worker-aurora-desk", t: 9_990) }
            + (0..<2).map { .init(estado: "andamento", id: "m\($0)", maquina: "mac-carlos", t: 9_990) }
        XCTAssertEqual(busy.runningLimit(budget: 4, maximum: 2), 1, "2 por máquina daria 3+2 linhas; 1 dá 2+2")
        XCTAssertEqual(busy.runningLines(limit: 1), 4)
        XCTAssertEqual(busy.runningLimit(budget: 8, maximum: 4), 4, "4+1 do desk e 2 do mac")
        XCTAssertEqual(panel.runningLimit(budget: 4, maximum: 2), 2)
    }

    func testFailedReadKeepsThePreviousPanelAndTheReason() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NexoBar/fila-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = QueueSnapshot().updated(output: Data(panelJSON.utf8), error: nil, now: Date(timeIntervalSince1970: 10_010))
        XCTAssertNil(first.erro); XCTAssertEqual(first.painel?.mestre, "worker-aurora-note")
        XCTAssertFalse(first.isStale(at: Date(timeIntervalSince1970: 10_100)))
        XCTAssertTrue(first.isStale(at: Date(timeIntervalSince1970: 10_200)), "painel com mais de 3 min")
        try first.save(directory: dir)
        let failed = try XCTUnwrap(QueueSnapshot.load(directory: dir)).updated(output: nil, error: "mestre worker-aurora-note não responde\n", now: Date(timeIntervalSince1970: 10_070))
        XCTAssertEqual(failed.erro, "mestre worker-aurora-note não responde")
        XCTAssertEqual(failed.painel, first.painel, "falha conserva o painel anterior")
        XCTAssertTrue(failed.isStale(at: Date(timeIntervalSince1970: 10_070)))
        XCTAssertNotEqual(failed.signature, first.signature)
        let junk = first.updated(output: Data("[]".utf8), error: nil, now: Date())
        XCTAssertEqual(junk.erro, "painel da fila ilegível")
    }

    func testSignatureIgnoresReadTimeButNotQueueChanges() throws {
        let panel = try JSONDecoder().decode(QueuePanel.self, from: Data(panelJSON.utf8))
        let a = QueueSnapshot(painel: panel, lido: 1), b = QueueSnapshot(painel: panel, lido: 2)
        XCTAssertEqual(a.signature, b.signature)
        var moved = panel; moved.itens?[2].estado = "andamento"; moved.itens?[2].maquina = "mac-carlos"
        XCTAssertNotEqual(QueueSnapshot(painel: moved, lido: 1).signature, a.signature)
    }

    // MARK: bloco fila

    private func reading(fila: String?, extra: String = "") throws -> WorkerReading {
        let f = fila.map { #","fila":\#($0)"# } ?? ""
        return try JSONDecoder().decode(WorkerReading.self, from: Data(#"{"v":1,"host":"worker-x","cpu":{"uso":7,"temp":40}\#(f)\#(extra)}"#.utf8))
    }

    func testReadingWithoutOrWithNullQueueBlockKeepsEverythingElse() throws {
        XCTAssertNil(try reading(fila: nil).fila)
        let r = try reading(fila: "null")
        XCTAssertNil(r.fila)
        XCTAssertEqual(r.cpu?.uso, 7)
    }

    func testFullQueueBlockDecodes() throws {
        let r = try reading(fila: #"{"item_atual":"abc123","itens_rodando":["abc123"],"ultimo_item":{"id":"abc123","estado":"rodando","inicio_ts":1794596000,"fim_ts":null,"fim":null},"ocupado":true,"ultimo_ocupado_ts":1794596568,"ocioso_min":30,"manter_ate":null,"desliga_em":1794598368}"#)
        let f = try XCTUnwrap(r.fila)
        XCTAssertEqual(f.item_atual, "abc123")
        XCTAssertEqual(f.itens_rodando, ["abc123"])
        XCTAssertEqual(f.ultimo_item?.estado, "rodando")
        XCTAssertEqual(f.ultimo_item?.inicio_ts, 1794596000)
        XCTAssertNil(f.ultimo_item?.fim_ts)
        XCTAssertEqual(f.ocupado, true)
        XCTAssertEqual(f.ocioso_min, 30)
        XCTAssertNil(f.manter_ate)
        XCTAssertEqual(f.desliga_em, 1794598368)
    }

    func testWrongTypesInsideQueueBlockNeverDropTheReading() throws {
        let r = try reading(fila: #"{"item_atual":"a","desliga_em":"x","ocupado":"sim","itens_rodando":"a","ultimo_item":{"id":7,"estado":"ok","fim_ts":"y","inicio_ts":5}}"#)
        XCTAssertEqual(r.cpu?.uso, 7, "o resto da leitura sobrevive")
        let f = try XCTUnwrap(r.fila)
        XCTAssertEqual(f.item_atual, "a")
        XCTAssertNil(f.desliga_em)
        XCTAssertNil(f.ocupado)
        XCTAssertNil(f.itens_rodando)
        XCTAssertNil(f.ultimo_item?.id)
        XCTAssertEqual(f.ultimo_item?.estado, "ok")
        XCTAssertNil(f.ultimo_item?.fim_ts)
        XCTAssertEqual(f.ultimo_item?.inicio_ts, 5)
        // contêiner que não é objeto
        for bad in [#""x""#, "5", "[1]", #"{"ultimo_item":"x"}"#] {
            let r = try reading(fila: bad)
            XCTAssertEqual(r.cpu?.uso, 7, bad)
            XCTAssertEqual(r.fila?.item_atual, nil, bad)
            XCTAssertNil(r.fila?.ultimo_item?.id, bad)
        }
    }

    private static let zone = TimeZone(identifier: "America/Sao_Paulo")!
    /// 2026-11-13 16:00:00 -03:00
    private static let now = Date(timeIntervalSince1970: 1794596400)
    private func at(_ hour: Int, _ minute: Int, dayOffset: Int = 0) -> Double {
        var c = Calendar(identifier: .gregorian); c.timeZone = Self.zone
        return c.date(from: DateComponents(year: 2026, month: 11, day: 13 + dayOffset, hour: hour, minute: minute))!.timeIntervalSince1970
    }
    private func item(_ f: WorkerReading.Fila?, id: String = "worker-x") -> String? { WorkerFormat.queueItem(id: id, fila: f, now: Self.now) }
    private func off(_ f: WorkerReading.Fila?, id: String = "worker-x") -> String? { WorkerFormat.shutdown(id: id, fila: f, now: Self.now, timeZone: Self.zone) }

    func testQueueItemLine() {
        let end = Self.now.timeIntervalSince1970 - 12 * 60
        XCTAssertEqual(item(.init(item_atual: "abc", ultimo_item: .init(id: "abc", estado: "rodando", inicio_ts: 1))), "rodando abc",
                       "com item rodando, o último é o mesmo e não aparece")
        XCTAssertEqual(item(.init(ultimo_item: .init(id: "abc", estado: "entregue", fim_ts: end))), "abc · há 12 min")
        XCTAssertEqual(item(.init(ultimo_item: .init(id: "abc", estado: "erro", fim_ts: nil))), "abc · erro")
        XCTAssertEqual(item(.init(ultimo_item: .init(id: "abc"))), "abc")
        XCTAssertNil(item(.init(ultimo_item: .init(estado: "erro"))))
        XCTAssertNil(item(.init()))
        XCTAssertNil(item(nil))
        XCTAssertNil(item(.init(item_atual: "abc"), id: WorkersTelemetry.macID), "o Mac não tem bloco")
    }

    func testShutdownLine() {
        let now = Self.now.timeIntervalSince1970
        XCTAssertEqual(off(.init(manter_ate: at(18, 7), desliga_em: at(16, 30))), "mantido até 18:07")
        XCTAssertEqual(off(.init(manter_ate: now - 60, desliga_em: at(16, 7))), "desliga às 16:07", "manter vencido cai no desliga")
        XCTAssertEqual(off(.init(desliga_em: at(16, 7))), "desliga às 16:07")
        XCTAssertNil(off(.init(ocioso_min: nil)), "sem ocioso_min, nada")
        XCTAssertNil(off(nil))
        XCTAssertNil(off(.init(desliga_em: at(16, 7)), id: WorkersTelemetry.macID))
        XCTAssertEqual(off(.init(manter_ate: at(3, 0, dayOffset: 1))), "mantido até 14/11 03:00")
        XCTAssertEqual(off(.init(desliga_em: at(3, 5, dayOffset: 1))), "desliga em 14/11 03:05")
    }
}
