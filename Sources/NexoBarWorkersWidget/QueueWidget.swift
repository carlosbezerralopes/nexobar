import SwiftUI
import WidgetKit
import WorkersTelemetry

struct QueueEntry: TimelineEntry {
    var date: Date
    var snapshot: QueueSnapshot?
}

struct QueueProvider: TimelineProvider {
    func placeholder(in context: Context) -> QueueEntry { QueueEntry(date: .now, snapshot: nil) }

    func getSnapshot(in context: Context, completion: @escaping (QueueEntry) -> Void) {
        completion(QueueEntry(date: .now, snapshot: QueueSnapshot.load()))
    }

    /// O app pede recarga quando a fila muda; as entradas de minuto em minuto avançam as idades e esmaecem a leitura velha.
    func getTimeline(in context: Context, completion: @escaping (Timeline<QueueEntry>) -> Void) {
        let now = Date(), snapshot = QueueSnapshot.load()
        let entries = (0...10).map { QueueEntry(date: now.addingTimeInterval(Double($0) * 60), snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(600))))
    }
}

struct QueueWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: QueueSnapshot.widgetKind, provider: QueueProvider()) { entry in
            QueueWidgetView(entry: entry)
        }
        .configurationDisplayName("Fila de trabalho")
        .description("A fila distribuída de GPU: o que roda em cada máquina, as vagas, o que espera e as falhas. Clique para ler agora.")
        .supportedFamilies(Self.families)
    }

    /// O extragrande vertical só existe a partir do macOS 27.
    static var families: [WidgetFamily] {
        var list: [WidgetFamily] = [.systemLarge, .systemExtraLarge]
        if #available(macOS 27, *) { list.append(.systemExtraLargePortrait) }
        return list
    }
}

/// Estados da fila com as cores do widget dos workers: verde roda, laranja espera ou está atrasado, vermelho falhou.
private enum QueueTone {
    static let running = Color.green
    static let waiting = Color.orange
    static let failed = Color.red
    static let done = Color.secondary
}

struct QueueWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: QueueEntry

    private var wide: Bool { family == .systemExtraLarge }
    private var portrait: Bool { if #available(macOS 27, *) { return family == .systemExtraLargePortrait } else { return false } }

    var body: some View {
        Group {
            if let snapshot = entry.snapshot, let panel = snapshot.painel {
                content(snapshot, panel)
            } else {
                empty(entry.snapshot?.erro)
            }
        }
        .widgetURL(URL(string: "nexobar://fila")!)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func empty(_ error: String?) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "tray.full").font(.title2).foregroundStyle(.secondary)
            Text("Sem leitura da fila").font(.caption.weight(.semibold))
            Text(error ?? "O NexoBar lê ~/.agents/scripts/worker/fila.ps1 painel a cada minuto.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func content(_ snapshot: QueueSnapshot, _ panel: QueuePanel) -> some View {
        let stale = snapshot.isStale(at: entry.date)
        VStack(alignment: .leading, spacing: 8) {
            header(snapshot, panel, stale: stale)
            counters(panel)
            if portrait {
                // Vertical (~713 pt): uma coluna. Cada máquina leva até 4 itens rodando, as falhas até 3 e a espera ocupa o resto das
                // linhas de itens (a conta desconta a altura de cada cartão de máquina).
                let lines = Self.portraitItemLines - Self.portraitMachineCost * (panel.maquinas ?? []).count
                let perMachine = panel.runningLimit(budget: Self.portraitRunningBudget, maximum: 4)
                let used = panel.runningLines(limit: perMachine)
                let failed = min(panel.failures.count, 3) + (panel.failures.count > 3 ? 1 : 0)
                machines(panel)
                waiting(panel, limit: max(1, lines - used - failed))
                failures(panel, limit: 3)
            } else if wide {
                HStack(alignment: .top, spacing: 12) {
                    machines(panel).frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 8) {
                        // Coluna da direita: até 10 linhas de itens, as falhas primeiro na conta.
                        let failed = min(panel.failures.count, 3)
                        waiting(panel, limit: max(1, 10 - failed - (panel.failures.count > 3 ? 1 : 0)))
                        failures(panel, limit: 3)
                    }
                    .frame(width: 260, alignment: .topLeading)
                }
            } else {
                // No grande, até 7 linhas de itens no total: o que roda (até 4), as falhas (até 2) e a espera no resto.
                let used = panel.runningLines(limit: panel.runningLimit(budget: 4, maximum: 2))
                let failed = min(panel.failures.count, 2) + (panel.failures.count > 2 ? 1 : 0)
                machines(panel)
                waiting(panel, limit: max(1, 7 - used - failed))
                failures(panel, limit: 2)
            }
            Spacer(minLength: 0)
        }
        .opacity(stale ? 0.5 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Cabeçalho e contadores

    private func header(_ snapshot: QueueSnapshot, _ panel: QueuePanel, stale: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "tray.full.fill").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Fila").font(.system(size: 13, weight: .semibold))
            Circle().fill(snapshot.erro == nil ? (stale ? Color.orange : Color.green) : Color.red).frame(width: 6, height: 6)
            Text(snapshot.erro ?? "mestre \(WorkerSnapshot.defaultName(id: panel.mestre ?? WorkerFormat.missing, host: nil))")
                .font(.system(size: 10)).foregroundStyle(snapshot.erro == nil ? Color.secondary : Color.red).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Text(WorkerFormat.time(snapshot.panelDate).dropLast(3)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    /// Vertical: linhas de itens que cabem em ~713 pt (menos o custo de cada cartão de máquina) e o teto de linhas para o que roda.
    static let portraitItemLines = 32
    static let portraitMachineCost = 2
    static let portraitRunningBudget = 10

    @ViewBuilder private func counters(_ panel: QueuePanel) -> some View {
        let running = panel.items("andamento").count, waiting = panel.waiting.count, failed = panel.items("falha").count
        let fetch = panel.doneToFetch
        let cells: [AnyView] = [
            AnyView(counter(running, "rodando", tone: running > 0 ? QueueTone.running : .secondary)),
            AnyView(counter(waiting, "na fila", tone: waiting > 0 ? QueueTone.waiting : .secondary)),
            AnyView(counter(failed, failed == 1 ? "falha" : "falhas", tone: failed > 0 ? QueueTone.failed : .secondary)),
            AnyView(counter(panel.doneCount, panel.doneCount == 1 ? "feito" : "feitos", tone: QueueTone.done, note: fetch > 0 ? "\(fetch) a buscar" : nil)),
        ]
        if portrait {
            VStack(spacing: 6) {
                HStack(spacing: 6) { cells[0]; cells[1] }
                HStack(spacing: 6) { cells[2]; cells[3] }
            }
        } else {
            HStack(spacing: 6) { ForEach(0..<cells.count, id: \.self) { cells[$0] } }
        }
    }

    private func counter(_ value: Int, _ label: String, tone: Color, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value)").font(.system(size: wide || portrait ? 22 : 18, weight: .semibold).monospacedDigit()).foregroundStyle(value > 0 ? tone : .secondary)
                if let note { Text(note).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7) }
            }
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background.opacity(0.35)))
    }

    // MARK: Máquinas, cada uma com as vagas e o que roda nela

    private func machines(_ panel: QueuePanel) -> some View {
        let list = panel.maquinas ?? []
        // Grande: até 4 linhas para o que roda; extragrande, até 8.
        let perMachine = portrait ? panel.runningLimit(budget: Self.portraitRunningBudget, maximum: 4)
            : wide ? panel.runningLimit(budget: 8, maximum: 4) : panel.runningLimit(budget: 4, maximum: 2)
        return VStack(alignment: .leading, spacing: 5) {
            Text("MÁQUINAS · VAGAS LIVRES").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            ForEach(list, id: \.nome) { machine in
                MachineRow(machine: machine, items: panel.running(on: machine.nome), alive: panel.isAlive(machine, at: entry.date),
                           orphanAfter: panel.orphanAfter, now: entry.date, limit: perMachine, wide: wide || portrait)
            }
            let elsewhere = panel.runningElsewhere
            if !elsewhere.isEmpty {
                ForEach(elsewhere.prefix(2), id: \.id) { item in
                    ItemLine(symbol: "play.fill", tone: QueueTone.running, id: item.id, trailing: "\(item.maquina ?? WorkerFormat.missing) · \(QueueFormat.age(since: item.t, to: entry.date))")
                }
            }
        }
    }

    // MARK: Espera e falhas

    @ViewBuilder private func waiting(_ panel: QueuePanel, limit: Int) -> some View {
        let items = panel.waiting
        section("Na fila", count: items.count) {
            if items.isEmpty {
                Text("vazia").font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                ForEach(items.prefix(limit), id: \.id) { item in
                    ItemLine(symbol: item.estado == "chegando" ? "arrow.down.circle" : "clock", tone: QueueTone.waiting, id: item.id,
                             trailing: QueueFormat.age(since: item.t, to: entry.date))
                }
                more(items.count - limit)
            }
        }
    }

    @ViewBuilder private func failures(_ panel: QueuePanel, limit: Int) -> some View {
        let items = panel.failures
        if !items.isEmpty {
            section("Falhas", count: items.count) {
                ForEach(items.prefix(limit), id: \.id) { item in
                    ItemLine(symbol: "xmark.octagon.fill", tone: QueueTone.failed, id: item.id, trailing: QueueFormat.age(since: item.t, to: entry.date))
                }
                more(items.count - limit)
            }
        }
    }

    private func section<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder private func more(_ hidden: Int) -> some View {
        if hidden > 0 { Text("+\(hidden)").font(.system(size: 9)).foregroundStyle(.secondary) }
    }
}

struct MachineRow: View {
    var machine: QueuePanel.Machine
    var items: [QueuePanel.Item]
    var alive: Bool
    var orphanAfter: TimeInterval
    var now: Date
    var limit: Int
    var wide: Bool

    private var name: String { WorkerSnapshot.defaultName(id: machine.nome, host: nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(alive ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                Text(name).font(.system(size: 11, weight: .semibold)).lineLimit(1).frame(width: wide ? 92 : 70, alignment: .leading)
                if alive {
                    gauge("GPU", machine.gpu_livre)
                    gauge("CPU", machine.cpu_livre)
                    Text("\(WorkerFormat.gigabytes(machine.ram_livre_gb, digits: 0)) GB").font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary).lineLimit(1).fixedSize()
                } else {
                    Text(machine.batimento == nil ? "sem batimento" : "desligado · \(QueueFormat.age(since: machine.batimento, to: now))")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            ForEach(items.prefix(limit), id: \.id) { item in
                let late = (item.t.map { now.timeIntervalSince1970 - $0 } ?? .infinity)
                let tone = late >= orphanAfter ? QueueTone.failed : (late >= 180 ? QueueTone.waiting : QueueTone.running)
                ItemLine(symbol: "play.fill", tone: tone, id: item.id, trailing: "batida \(QueueFormat.age(since: item.t, to: now))")
                    .padding(.leading, 12)
            }
            if items.count > limit {
                Text("+\(items.count - limit) rodando").font(.system(size: 9)).foregroundStyle(.secondary).padding(.leading, 12)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background.opacity(0.35)))
    }

    /// Vaga livre da fila (não é o uso do hardware): barra cheia = tudo livre; sem vaga, a barra fica laranja vazia.
    private func gauge(_ label: String, _ value: Double?) -> some View {
        let fraction = QueueFormat.freeFraction(value)
        return HStack(spacing: 3) {
            Text(label).font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill((fraction == 0 ? Color.orange : Color.secondary).opacity(0.25))
                    if let fraction, fraction > 0 { Capsule().fill(Color.green.opacity(0.85)).frame(width: geo.size.width * fraction) }
                }
            }
            .frame(height: 5)
            Text(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? WorkerFormat.missing)
                .font(.system(size: 9).monospacedDigit()).foregroundStyle(fraction == 0 ? Color.orange : Color.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }
}

struct ItemLine: View {
    var symbol: String
    var tone: Color
    var id: String
    var trailing: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 7)).foregroundStyle(tone)
            Text(id).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(trailing).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
    }
}
