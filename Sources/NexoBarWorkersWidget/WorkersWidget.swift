import AppIntents
import SwiftUI
import WidgetKit
import WorkersTelemetry
import os

private let log = Logger(subsystem: "com.carlosbezerralopes.nexobar.preview.workers", category: "timeline")

struct WorkersEntry: TimelineEntry {
    var date: Date
    var workers: [WorkerSnapshot]
}

struct WorkersProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> WorkersEntry { WorkersEntry(date: .now, workers: []) }

    func snapshot(for configuration: WorkersWidgetIntent, in context: Context) async -> WorkersEntry {
        WorkersEntry(date: .now, workers: configuration.apply(to: WorkersTelemetry.load()))
    }

    /// O app pede recarga a cada leitura nova; as entradas futuras marcam o cartão como desatualizado mesmo sem recarga.
    func timeline(for configuration: WorkersWidgetIntent, in context: Context) async -> Timeline<WorkersEntry> {
        let now = Date()
        let workers = configuration.apply(to: WorkersTelemetry.load())
        log.info("timeline: \(workers.count) workers")
        let dates = [now] + WorkersTelemetry.transitionDates(workers, after: now).prefix(8)
        return Timeline(entries: dates.map { WorkersEntry(date: $0, workers: workers) }, policy: .after(now.addingTimeInterval(WorkersTelemetry.staleAfter)))
    }
}

@main
struct WorkersWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WorkersTelemetry.widgetKind, intent: WorkersWidgetIntent.self, provider: WorkersProvider()) { entry in
            WorkersWidgetView(entry: entry)
        }
        .configurationDisplayName("Workers")
        .description("CPU, GPU, SSD e RAM dos workers Ubuntu, com temperaturas, ventoinha e processos.")
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct WorkersWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: WorkersEntry

    private var capacity: Int { family == .systemMedium ? 2 : 4 }
    private var columns: Int { family == .systemExtraLarge ? 4 : 2 }

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
                                WorkerCard(worker: worker, now: entry.date, compact: family == .systemMedium)
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

    private var stale: Bool { worker.isStale(at: now) }
    private var reading: WorkerReading? { worker.reading }

    private var stateColor: Color {
        switch worker.connection?.estado {
        case .desconectado: return .red
        case .conectando: return .yellow
        default: return stale ? .orange : .green
        }
    }

    private var statusText: String? {
        switch worker.connection?.estado {
        case .desconectado: return "desconectado"
        case .conectando: return "conectando"
        default: return stale ? "desatualizado · \(WorkerFormat.age(from: worker.receivedAt, to: now))" : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(stateColor).frame(width: 6, height: 6)
                Text(worker.displayName).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
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
            Text(WorkerFormat.time(worker.sampledAt)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.background.opacity(0.35)))
    }

    private var detail: String? {
        worker.connection?.detalhe?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    @ViewBuilder private func metrics(_ r: WorkerReading) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 1) {
            row("CPU", [WorkerFormat.percent(r.cpu?.uso), WorkerFormat.temperature(r.cpu?.temp)] + (compact ? [] : ["load \(WorkerFormat.load(r.cpu?.load1))"]))
            if let gpu = r.gpu {
                row("GPU", [WorkerFormat.percent(gpu.uso), WorkerFormat.temperature(gpu.temp),
                            "\(WorkerFormat.megabytesAsGB(gpu.vram_mb))/\(WorkerFormat.megabytesAsGB(gpu.vram_total_mb))"] + (compact ? [] : [WorkerFormat.watts(gpu.watts)]))
            } else {
                row("GPU", ["sem GPU"], secondary: true)
            }
            row("SSD", [WorkerFormat.percent(r.ssd?.ativo), WorkerFormat.temperature(r.ssd?.temp),
                        (compact ? nil : WorkerFormat.rates(read: r.ssd?.leitura_bs, write: r.ssd?.escrita_bs)) ?? "\(WorkerFormat.gigabytes(r.ssd?.livre_gb)) GB livre"])
            row("RAM", ["\(WorkerFormat.gigabytes(r.ram?.usada_gb))/\(WorkerFormat.gigabytes(r.ram?.total_gb)) GB"] + (compact ? [] : ["swap \(WorkerFormat.gigabytes(r.ram?.swap_gb)) GB"]))
            GridRow {
                Image(systemName: "fan").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                Text(WorkerFormat.fans(r.ventoinhas_rpm)).font(.system(size: 10).monospacedDigit()).lineLimit(1)
            }
        }
        VStack(alignment: .leading, spacing: 0) {
            if let top = r.topCPU {
                process("cpu", top.nome ?? WorkerFormat.missing, WorkerFormat.percent(top.cpu))
            }
            if let gpu = r.topGPU {
                process("cube", gpu.nome ?? WorkerFormat.missing, WorkerFormat.megabytesAsGB(gpu.vram_mb))
            }
        }
        .padding(.top, 1)
    }

    private func row(_ label: String, _ values: [String], secondary: Bool = false) -> some View {
        GridRow {
            Text(label).font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            Text(values.joined(separator: "  ")).font(.system(size: 10).monospacedDigit())
                .foregroundStyle(secondary ? .secondary : .primary).lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    private func process(_ symbol: String, _ name: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8))
            Text(name).lineLimit(1).truncationMode(.middle)
            Text(value).monospacedDigit()
        }
        .font(.system(size: 9)).foregroundStyle(.secondary)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
