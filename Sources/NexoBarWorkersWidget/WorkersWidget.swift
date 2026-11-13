import SwiftUI
import WidgetKit
import WorkersTelemetry
import os

private let log = Logger(subsystem: "com.carlosbezerralopes.nexobar.preview.workers", category: "timeline")

struct WorkersEntry: TimelineEntry {
    var date: Date
    var workers: [WorkerSnapshot]
}

struct WorkersProvider: TimelineProvider {
    func placeholder(in context: Context) -> WorkersEntry { WorkersEntry(date: .now, workers: []) }

    func getSnapshot(in context: Context, completion: @escaping (WorkersEntry) -> Void) {
        completion(WorkersEntry(date: .now, workers: Self.read()))
    }

    /// O app pede recarga a cada leitura nova; as entradas futuras marcam o cartão como desatualizado mesmo sem recarga.
    func getTimeline(in context: Context, completion: @escaping (Timeline<WorkersEntry>) -> Void) {
        let now = Date()
        let workers = Self.read()
        log.info("timeline: \(workers.count) workers")
        let dates = [now] + WorkersTelemetry.transitionDates(workers, after: now).prefix(8)
        completion(Timeline(entries: dates.map { WorkersEntry(date: $0, workers: workers) }, policy: .after(now.addingTimeInterval(WorkersTelemetry.staleAfter))))
    }

    static func read() -> [WorkerSnapshot] { WorkersLayout.arrange(WorkersTelemetry.loadAll(), config: WidgetLayoutConfig.load()) }
}

/// Clique no cartão: o NexoBar abre a escolha do PC e do apelido daquela posição.
enum WorkersLink {
    static func url(position: Int) -> URL { URL(string: "nexobar://workers/posicao/\(position)")! }
}

/// Uma extensão, dois widgets: os workers e a fila de trabalho.
@main
struct NexoBarWidgets: WidgetBundle {
    var body: some Widget {
        WorkersWidget()
        QueueWidget()
    }
}

struct WorkersWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WorkersTelemetry.widgetKind, provider: WorkersProvider()) { entry in
            WorkersWidgetView(entry: entry)
        }
        .configurationDisplayName("Workers")
        .description("CPU, GPU, SSD e RAM do Mac e dos workers. Clique num cartão para escolher o PC e o apelido.")
        .supportedFamilies(Self.families)
    }

    /// O extragrande vertical só existe a partir do macOS 27.
    static var families: [WidgetFamily] {
        var list: [WidgetFamily] = [.systemMedium, .systemLarge, .systemExtraLarge]
        if #available(macOS 27, *) { list.append(.systemExtraLargePortrait) }
        return list
    }
}

struct WorkersWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: WorkersEntry

    private var portrait: Bool { if #available(macOS 27, *) { return family == .systemExtraLargePortrait } else { return false } }
    private var capacity: Int { family == .systemMedium ? 2 : 4 }
    private var columns: Int { family == .systemExtraLarge ? 4 : portrait ? 1 : 2 }

    var body: some View {
        let workers = Array(entry.workers.prefix(capacity))
        Group {
            if workers.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "server.rack").font(.title2).foregroundStyle(.secondary)
                    Text("Sem telemetria dos workers").font(.caption.weight(.semibold))
                    Text("Aguardando ~/Library/Application Support/workers-telemetria").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            } else {
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    ForEach(Array(stride(from: 0, to: workers.count, by: columns)), id: \.self) { start in
                        GridRow {
                            ForEach(workers[start..<min(start + columns, workers.count)]) { worker in
                                let card = WorkerCard(worker: worker, now: entry.date, compact: family == .systemMedium, tall: family == .systemExtraLarge)
                                if let position = worker.position { Link(destination: WorkersLink.url(position: position)) { card } } else { card }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct WorkerCard: View {
    var worker: WorkerSnapshot
    var now: Date
    var compact: Bool
    /// Cartão de altura inteira (extragrande): sobra espaço para o bloco da fila sem tirar processos.
    var tall = false

    private var stale: Bool { worker.isStale(at: now) }
    private var reading: WorkerReading? { worker.reading }

    private var stateColor: Color {
        if worker.waking && stale { return .orange }
        switch worker.connection?.estado {
        case .desconectado: return .red
        case .conectando: return .yellow
        default: return stale ? .orange : .green
        }
    }

    private var statusText: String? {
        if worker.waking && stale { return "acordando" }
        switch worker.connection?.estado {
        case .desconectado: return "desconectado"
        case .conectando: return "conectando"
        default: return stale ? "desatualizado · \(WorkerFormat.age(from: worker.receivedAt, to: now))" : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Extragrande: o desligamento sobe para o cabeçalho e não trunca. Se não couber com o apelido inteiro, tenta a forma curta
            // ("até 03:00", "às 16:51"), depois só o horário ("03:00"; o ícone power já diz o que é) e, por último, o apelido trunca
            // no meio. Nas próximas 24 h o horário não leva dd/MM.
            let headerOff = tall ? WorkerFormat.shutdown(id: worker.id, fila: reading?.fila, now: now, next24h: true) : nil
            let headerShort = tall ? WorkerFormat.shutdown(id: worker.id, fila: reading?.fila, now: now, short: true, next24h: true) : nil
            let headerBare = headerShort.map { $0.split(separator: " ", maxSplits: 1).dropFirst().joined() }
            ViewThatFits(in: .horizontal) {
                header(off: headerOff, fixedName: true)
                header(off: headerShort, fixedName: true)
                header(off: headerBare, fixedName: true)
                header(off: headerBare, fixedName: false)
            }
            if let statusText {
                Text(statusText).font(.system(size: 9, weight: .medium)).foregroundStyle(stateColor).lineLimit(1)
            }
            if let reading {
                metrics(reading).opacity(stale ? 0.45 : 1)
            } else {
                Text(detail ?? "sem leitura").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.background.opacity(0.35)))
        .overlay { if let highlight { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(highlight, lineWidth: 1) } }
    }

    // Roxo e azul: laranja, amarelo e vermelho já são do status. Cartão desatualizado não mostra atividade.
    static let gpuColor = Color.purple
    static let cpuColor = Color.blue
    private var gpuActive: Bool { !stale && WorkerActivity.gpuActive(reading) }
    private var cpuActive: Bool { !stale && WorkerActivity.cpuActive(reading) }
    private var highlight: AnyShapeStyle? {
        switch (gpuActive, cpuActive) {
        case (true, true): AnyShapeStyle(LinearGradient(colors: [Self.gpuColor, Self.cpuColor], startPoint: .topLeading, endPoint: .bottomTrailing))
        case (true, false): AnyShapeStyle(Self.gpuColor)
        case (false, true): AnyShapeStyle(Self.cpuColor)
        default: nil
        }
    }

    private func header(off: String?, fixedName: Bool) -> some View {
        HStack(spacing: 3) {
            Circle().fill(stateColor).frame(width: 6, height: 6)
            Group {
                if fixedName { nameText.fixedSize() } else { nameText }
            }
            Spacer(minLength: 2)
            if let off {
                HStack(spacing: 1) {
                    Image(systemName: "power").font(.system(size: 8))
                    Text(off).lineLimit(1).fixedSize()
                }
                .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if gpuActive { Image(systemName: "cube.fill").font(.system(size: 9)).foregroundStyle(Self.gpuColor) }
            if cpuActive { Image(systemName: "cpu.fill").font(.system(size: 9)).foregroundStyle(Self.cpuColor) }
        }
    }
    private var nameText: some View {
        Text(worker.displayName).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
    }

    /// Processos, fila, hora da leitura e, à direita da hora, as sessões do Claude (Mac) ou o tempo ligado (workers). No médio, só o
    /// maior processo, que cede o lugar à linha do desligamento. A fila (item e desligamento) só vem de worker; com ela, o grande
    /// perde processos (processos + fila ≤ 3 linhas, o que o rodapé já tinha; o extragrande, de altura inteira, mantém 3), para não cortar a linha da hora.
    @ViewBuilder private var footer: some View {
        let gpu = reading?.topGPU
        let item = compact ? nil : WorkerFormat.queueItem(id: worker.id, fila: reading?.fila, now: now)
        // No extragrande o desligamento fica no cabeçalho.
        let off = tall ? nil : WorkerFormat.shutdown(id: worker.id, fila: reading?.fila, now: now)
        let queueLines = (item == nil ? 0 : 1) + (off == nil ? 0 : 1)
        // Com algo rodando (item da fila, GPU ou CPU ativa), o grande mostra só o maior processo.
        let running = WorkerFormat.queueItem(id: worker.id, fila: reading?.fila, now: now) != nil || gpuActive || cpuActive
        let budget = tall ? 3 : (running ? min(1, 3 - queueLines) : 3 - queueLines)
        let processes = Array((reading?.topProcesses ?? []).prefix(max(0, min(3, budget))))
        let timeLine = HStack(spacing: 4) {
            Text(WorkerFormat.time(worker.sampledAt)).monospacedDigit()
            Spacer(minLength: 2)
            // As sessões do Claude Desktop nos workers rodam presas ao Mac: só o Mac mostra a contagem; os workers, o tempo ligado.
            if let reading {
                Text(worker.id == WorkersTelemetry.macID ? "Claude \(WorkerFormat.count(reading.claude_sessoes))"
                                                         : "ligado \(WorkerFormat.uptime(reading.uptime_s))").monospacedDigit()
            }
        }
        .font(.system(size: 9)).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 0) {
            if compact {
                if let off { process("power", off, nil) }
                else if let top = (reading?.topProcesses ?? []).first { process("cpu", top.nome ?? WorkerFormat.missing, WorkerFormat.percent(top.cpu)) }
            } else {
                ForEach(Array(processes.enumerated()), id: \.offset) { _, p in
                    process("cpu", p.nome ?? WorkerFormat.missing, WorkerFormat.percent(p.cpu))
                }
                if let gpu { process("cube", gpu.nome ?? WorkerFormat.missing, WorkerFormat.megabytesAsGB(gpu.vram_mb)) }
                if let item { process("tray", item, nil) }
                if let off { process("power", off, nil) }
            }
            timeLine.padding(.top, compact ? 0 : 2)
        }
    }

    private var detail: String? {
        worker.connection?.detalhe?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    @ViewBuilder private func metrics(_ r: WorkerReading) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 1) {
            row("CPU", [WorkerFormat.percent(r.cpu?.uso), WorkerFormat.temperature(r.cpu?.temp)] + (compact ? [] : ["load \(WorkerFormat.load(r.cpu?.load1))"]))
            if let gpu = r.gpu {
                // Igual para NVIDIA e Mac: uso, temperatura e watts; a memória na linha de baixo (no Mac, sobre o limite que o
                // macOS dá à GPU). Fonte sem watts nem memória omite os dois em vez de mostrar "—".
                let reportsPower = gpu.watts != nil || gpu.vram_total_mb != nil
                row("GPU", [WorkerFormat.percent(gpu.uso), WorkerFormat.temperature(gpu.temp)] + (reportsPower ? [WorkerFormat.watts(gpu.watts)] : []))
                if !compact, gpu.vram_total_mb != nil {
                    row("VRAM", [WorkerFormat.vram(used: gpu.vram_mb, total: gpu.vram_total_mb)])
                }
            } else {
                row("GPU", ["sem GPU"], secondary: true)
            }
            let ssd = [WorkerFormat.percent(r.ssd?.ativo), WorkerFormat.temperature(r.ssd?.temp), "\(WorkerFormat.gigabytes(r.ssd?.livre_gb)) GB livre"]
            row("SSD", ssd + [WorkerFormat.rates(read: r.ssd?.leitura_bs, write: r.ssd?.escrita_bs)].compactMap { $0 }, fallback: ssd)
            row("RAM", ["\(WorkerFormat.gigabytes(r.ram?.usada_gb))/\(WorkerFormat.gigabytes(r.ram?.displayTotal)) GB"] + (compact ? [] : ["swap \(WorkerFormat.gigabytes(r.ram?.swap_gb)) GB"]))
            GridRow {
                Image(systemName: "fan").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                Text(WorkerFormat.fans(r.ventoinhas_rpm)).font(.system(size: 10).monospacedDigit()).lineLimit(1)
            }
        }
    }

    /// Sem largura, primeiro aproxima os valores; só então `fallback` tira o que é menos importante.
    private func row(_ label: String, _ values: [String], fallback: [String]? = nil, secondary: Bool = false) -> some View {
        func text(_ items: [String], _ separator: String = "  ") -> some View {
            Text(items.joined(separator: separator)).font(.system(size: 10).monospacedDigit())
                .foregroundStyle(secondary ? .secondary : .primary).lineLimit(1)
        }
        return GridRow {
            // Coluna da largura de "CPU": "VRAM" encolhe um pouco em vez de alargar a coluna e apertar os valores.
            Text(label).font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7).frame(width: 20, alignment: .leading)
            ViewThatFits(in: .horizontal) {
                text(values).fixedSize()
                text(values, " ").fixedSize()
                if let fallback {
                    text(fallback).fixedSize()
                    text(fallback, " ").fixedSize()
                }
                text(fallback ?? values, " ").minimumScaleFactor(0.8)
            }
        }
    }

    private func process(_ symbol: String, _ name: String, _ value: String?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8))
            Text(name).lineLimit(1).truncationMode(.middle)
            if let value { Text(value).monospacedDigit().fixedSize() }
        }
        .font(.system(size: 9)).foregroundStyle(.secondary)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
