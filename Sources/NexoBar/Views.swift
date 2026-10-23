import SwiftUI
import Charts

struct IndicatorDetailView: View {
    @ObservedObject var model: Dashboard
    let id: IndicatorID
    var customize: () -> Void
    @State private var showActivity = false
    private var item: IndicatorConfiguration { model.items.first(where: { $0.id == id }) ?? .init(id: id, enabled: true, label: id.name) }
    private var reading: IndicatorReading? { model.readings[id] }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                IndicatorGlyph(id: id, style: model.appearance.iconStyle).foregroundStyle(.teal)
                Text(item.label.isEmpty ? id.name : item.label).font(.title2.bold())
                Spacer()
                Text(reading?.displayValue(memory: item.memoryDisplay) ?? "—").font(.system(.title2, design: .monospaced).weight(.semibold))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(reading?.detail ?? "Aguardando primeira leitura").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if id == .memory, let reading, let used = reading.usedBytes, let total = reading.totalBytes {
                        HStack {
                            memoryValue("Em uso", bytes: used); Spacer(); memoryValue("Total", bytes: total); Spacer()
                            VStack(alignment: .leading) { Text("Uso").font(.caption).foregroundStyle(.secondary); Text(reading.value).font(.title3.monospacedDigit()) }
                        }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if reading?.isStale == true { Label("Leitura antiga · aguardando atualização", systemImage: "clock.badge.exclamationmark").font(.caption).foregroundStyle(.orange) }
                    if let sampledAt = reading?.sampledAt { Text("Leitura: \(sampledAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
                    if let child = id.temperatureChild, let temperature = model.readings[child] {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text("Temperatura").fontWeight(.semibold); Spacer(); Text(temperature.value).monospacedDigit() }
                            Text(temperature.detail).font(.caption).foregroundStyle(.secondary)
                            Toggle("Mostrar temperatura junto da \(id.name)", isOn: Binding(get: { model.items.first(where: { $0.id == child })?.enabled ?? false }, set: { enabled in model.setTemperature(id, enabled: enabled) })).font(.caption)
                        }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let points = model.history[id], points.count > 1 {
                        Chart(points) { point in LineMark(x: .value("Hora", point.time), y: .value("Leitura", point.value)).foregroundStyle(.teal) }
                            .chartYScale(domain: 0...((id == .cpuTemperature || id == .gpuTemperature) ? 120.0 : 100.0))
                            .chartYAxisLabel(id == .cpuTemperature || id == .gpuTemperature ? "°C" : "%").frame(height: 120)
                        Text("Últimos 5 minutos · somente nesta execução").font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(Array((reading?.windows ?? []).enumerated()), id: \.offset) { _, window in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text(window.name).fontWeight(.semibold); Spacer(); Text(window.usedPercent.map(IndicatorReading.percent) ?? "—").monospacedDigit() }
                            if let percent = window.usedPercent, percent.isFinite { ProgressView(value: min(max(percent, 0), 100), total: 100).tint(percent >= 95 ? .red : percent >= 80 ? .orange : .teal) }
                            if let used = window.used, let limit = window.limit { Text("\(used.formatted(.number.precision(.fractionLength(0...2)))) / \(limit.formatted(.number.precision(.fractionLength(0...2)))) \(window.unit ?? "")").monospacedDigit() }
                            if let date = window.resetsAt { Text("Renovação prevista: \(date.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary) }
                            if !window.detail.isEmpty { Text(window.detail).foregroundStyle(.secondary) }
                        }.font(.caption).padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let activity = reading?.activity {
                        Label(activity.summary, systemImage: activity.state == "working" ? "ellipsis.circle" : activity.state == "waiting" ? "hand.raised" : "circle.dotted").font(.caption)
                        if let detail = activity.detail { DisclosureGroup("Detalhes da atividade", isExpanded: $showActivity) { Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 430)
            if id.isAI { Text("Percentuais utilizados. A renovação é confirmada por uma nova leitura.").font(.caption2).foregroundStyle(.secondary) }
            Divider()
            HStack {
                Button("Personalizar barra…", action: customize); Spacer()
                if id.isAI { Button(model.isRefreshing(id) ? "Consultando…" : "Atualizar \(id.name)") { model.refreshAI(id: id) }.disabled(model.isRefreshing(id)) }
            }
        }.padding(18).frame(width: 420).background(Color(nsColor: .windowBackgroundColor))
    }
    private func memoryValue(_ label: String, bytes: Double) -> some View {
        VStack(alignment: .leading) { Text(label).font(.caption).foregroundStyle(.secondary); Text(String(format: "%.1f GiB", bytes / 1_073_741_824)).font(.title3.monospacedDigit()) }
    }
}

struct MenuBarPreview: NSViewRepresentable {
    @ObservedObject var model: Dashboard
    func makeNSView(context: Context) -> StatusStripPreviewView {
        let view = StatusStripPreviewView(frame: .zero)
        update(view)
        return view
    }
    func updateNSView(_ view: StatusStripPreviewView, context: Context) { update(view) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: StatusStripPreviewView, context: Context) -> CGSize? { nsView.intrinsicContentSize }
    private func update(_ view: StatusStripPreviewView) {
        view.configure(items: model.items, readings: model.readings, appearance: model.appearance)
    }
}

@MainActor
final class StatusStripPreviewView: NSImageView {
    private let strip = StatusStrip(frame: NSRect(x: 0, y: 0, width: 0, height: 26))
    private var previewSize = NSSize(width: 0, height: 26)
    override var intrinsicContentSize: NSSize { previewSize }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageScaling = .scaleNone
        imageAlignment = .alignLeft
        contentTintColor = .labelColor
        isEditable = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(items: [IndicatorConfiguration], readings: [IndicatorID: IndicatorReading], appearance: BarAppearance) {
        let width = strip.update(items: items, readings: readings, appearance: appearance,
                                 layout: appearance.quotaLayout, detailedTime: appearance.detailedTime)
        previewSize = NSSize(width: width, height: 26)
        frame.size = previewSize
        invalidateIntrinsicContentSize()
        renderImage()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        renderImage()
    }

    private func renderImage() {
        // Keep the drawing canvas detached: NSImageView supplies the settings window's template tint.
        image = strip.renderStatusImage(width: previewSize.width, height: previewSize.height,
                                        appearance: effectiveAppearance, highlighted: false)
        needsDisplay = true
    }
}

struct SettingsView: View {
    @ObservedObject var model: Dashboard
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IdentityMark(identity: model.appearance.identity).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NexoBar").font(.title.bold())
                    Text("Clique em um indicador para detalhes. Botão direito para opções.").font(.callout).foregroundStyle(.secondary)
                }
            }
            ScrollView(.horizontal) { MenuBarPreview(model: model) }.frame(height: 42).padding(.horizontal, 10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            appearanceOptions
            HStack(spacing: 18) {
                Picker("Limites de IA", selection: Binding(get: { model.appearance.quotaLayout }, set: { layout in var value = model.appearance; value.quotaLayout = layout; model.updateAppearance(value) })) {
                    Text("Horizontal").tag(QuotaBarLayout.inline); Text("Duas linhas").tag(QuotaBarLayout.stacked)
                }.pickerStyle(.segmented).frame(width: 320)
                Toggle("Detalhar tempo restante", isOn: Binding(get: { model.appearance.detailedTime }, set: { detailed in var value = model.appearance; value.detailedTime = detailed; model.updateAppearance(value) })).font(.caption)
                Spacer()
            }
            Text("Só aparecem os limites informados pelo plano. Um único limite ocupa uma linha. Tempo compacto: 2h · 3d; detalhado: 2h13m · 3d4h.").font(.caption2).foregroundStyle(.secondary)
            Toggle("Avisar quando a cota renovar", isOn: Binding(get: { model.appearance.notifyResets }, set: { enabled in var value = model.appearance; value.notifyResets = enabled; model.updateAppearance(value) })).font(.caption)
            HStack {
                Picker("Interação", selection: Binding(get: { model.appearance.interactionDisplay }, set: { display in var value = model.appearance; value.interactionDisplay = display; model.updateAppearance(value) })) {
                    ForEach(StatusInteractionDisplay.allCases) { display in Text(display.title).tag(display) }
                }.frame(width: 340)
                Spacer()
            }
            Text("O macOS pode repetir o ícone nos monitores; esta opção limita os cliques. Principal é o monitor definido nos Ajustes de Telas. Reabra o NexoBar para acessar as configurações.").font(.caption2).foregroundStyle(.secondary)
            cliFolders
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(topLevelItems.enumerated()), id: \.element.id) { index, item in
                        indicatorRow(item, index: index).padding(.vertical, 7)
                        if index < topLevelItems.count - 1 { Divider() }
                    }
                }.padding(.trailing, 8)
            }
            if let error = model.saveError { Text(error).font(.caption).foregroundStyle(.red) }
            else { Text("Preferências salvas ao editar. Escolha poucos indicadores para caberem na barra.").font(.caption).foregroundStyle(.secondary) }
        }.padding(20).frame(width: 760, height: 740).background(Color(nsColor: .windowBackgroundColor))
    }
    private var appearanceOptions: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Marca NexoBar").font(.caption.bold()).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(NexoIdentity.allCases) { identity in
                        Button { var value = model.appearance; value.identity = identity; model.updateAppearance(value) } label: {
                            VStack(spacing: 4) { IdentityMark(identity: identity, size: 24); Text(identity.title).font(.caption); Text(identity.subtitle).font(.system(size: 9)).foregroundStyle(.secondary) }
                                .frame(width: 83, height: 64).background(model.appearance.identity == identity ? Color.teal.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Ícones da barra").font(.caption.bold()).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(IndicatorIconStyle.nativeStyles) { style in
                        Button { var value = model.appearance; value.iconStyle = style; model.updateAppearance(value) } label: {
                            VStack(spacing: 8) {
                                HStack(spacing: 6) { ForEach([IndicatorID.cpu, .memory, .gpu], id: \.self) { IndicatorGlyph(id: $0, style: style) } }
                                Text(style.title).font(.caption)
                                Text(style.subtitle).font(.system(size: 9)).foregroundStyle(.secondary)
                            }.frame(width: 104, height: 64).background(model.appearance.iconStyle == style ? Color.teal.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                    Menu {
                        ForEach(IndicatorIconStyle.legacyStyles) { style in
                            Button {
                                var value = model.appearance; value.iconStyle = style; model.updateAppearance(value)
                            } label: {
                                if model.appearance.iconStyle == style { Label(style.title, systemImage: "checkmark") }
                                else { Text(style.title) }
                            }
                        }
                    } label: {
                        VStack(spacing: 6) {
                            HStack(spacing: 6) { ForEach([IndicatorID.cpu, .memory, .gpu], id: \.self) { IndicatorGlyph(id: $0, style: model.appearance.iconStyle.usesTemplateStatusImage ? .letters : model.appearance.iconStyle) } }
                            Text(model.appearance.iconStyle.usesTemplateStatusImage ? "Anteriores" : model.appearance.iconStyle.title).font(.caption)
                        }.frame(width: 88, height: 56)
                    }.menuStyle(.borderlessButton).frame(width: 104)
                }
                Text("Sistema e Instrumentos seguem a cor da barra do macOS.").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
    private var cliFolders: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Pastas das CLIs").font(.caption.bold())
            ForEach([IndicatorID.claude, .codex], id: \.self) { id in
                HStack(spacing: 8) {
                    Text(id == .claude ? "Claude · obrigatória" : "Codex · opcional").frame(width: 125, alignment: .leading)
                    Text(model.cliDirectories.path(for: id) ?? (id == .claude ? "Escolha uma pasta já confiável na CLI" : "Automático — app-server não exige pasta confiável"))
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                        .help(model.cliDirectories.path(for: id) ?? "")
                    Button("Escolher…") { chooseFolder(for: id) }
                    Button("Limpar") { model.setCLIDirectory(nil, for: id) }.disabled(model.cliDirectories.path(for: id) == nil)
                }.font(.caption)
            }
            Text("A escolha não concede confiança à CLI. Pedidos de autorização ou login interrompem a consulta; nenhum será aceito automaticamente.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func chooseFolder(for id: IndicatorID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Usar pasta"
        panel.message = id == .claude ? "Escolha uma pasta já confiável no Claude Code." : "Pasta opcional para iniciar o Codex app-server."
        if let path = model.cliDirectories.path(for: id) { panel.directoryURL = URL(fileURLWithPath: path) }
        if panel.runModal() == .OK, let url = panel.url { model.setCLIDirectory(url, for: id) }
    }
    private func indicatorRow(_ item: IndicatorConfiguration, index: Int) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { current(item).enabled }, set: { enabled in var edit = current(item); edit.enabled = enabled; model.update(edit) })).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel("Mostrar \(item.id.name)")
            IndicatorGlyph(id: item.id, style: model.appearance.iconStyle).frame(width: 20).foregroundStyle(item.id.isAI ? .purple : .teal)
            TextField(item.id.name, text: Binding(get: { current(item).label }, set: { label in var edit = current(item); edit.label = label; model.update(edit) })).textFieldStyle(.roundedBorder).frame(width: 150)
            Toggle("Nome", isOn: Binding(get: { current(item).showLabel }, set: { show in var edit = current(item); edit.showLabel = show; model.update(edit) })).font(.caption).frame(width: 65)
            if let child = item.id.temperatureChild {
                Menu(item.id.name) {
                    Toggle("Mostrar temperatura", isOn: Binding(get: { model.items.first(where: { $0.id == child })?.enabled ?? false }, set: { enabled in model.setTemperature(item.id, enabled: enabled) }))
                }.frame(width: 75)
            }
            if item.id == .memory {
                Picker("Formato", selection: Binding(get: { current(item).memoryDisplay }, set: { format in var edit = current(item); edit.memoryDisplay = format; model.update(edit) })) {
                    ForEach(MemoryDisplay.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 130)
            }
            Spacer(minLength: 4)
            Text(model.readings[item.id]?.displayValue(memory: item.memoryDisplay) ?? "—").font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            Button { model.move(item.id, offset: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).accessibilityLabel("Mover \(item.id.name) antes")
            Button { model.move(item.id, offset: 1) } label: { Image(systemName: "arrow.down") }.disabled(index == topLevelItems.count - 1).accessibilityLabel("Mover \(item.id.name) depois")
        }
    }
    private func current(_ item: IndicatorConfiguration) -> IndicatorConfiguration { model.items.first(where: { $0.id == item.id }) ?? item }
    private var topLevelItems: [IndicatorConfiguration] { model.items.filter { !$0.id.isNested } }
}
