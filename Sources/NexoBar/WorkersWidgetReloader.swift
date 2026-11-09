import AppKit
import Foundation
import SwiftUI
import WidgetKit
import WorkersTelemetry

/// Grava a leitura do Mac para o widget e pede a recarga quando ela, o coletor dos workers ou as posições mudam.
@MainActor
final class WorkersWidgetReloader {
    private var timer: Timer?
    private var lastSignature = ""
    private var writing = false
    private let mac = MacTelemetry()
    private let queue = DispatchQueue(label: "nexobar.workers-widget", qos: .utility)
    var hardware: () -> MacTelemetry.Hardware = { .init() }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func reload() {
        lastSignature = ""
        WidgetCenter.shared.reloadTimelines(ofKind: WorkersTelemetry.widgetKind)
    }

    private func tick() {
        guard !writing else { return }
        writing = true
        let snapshot = hardware()
        let mac = self.mac
        queue.async {
            try? mac.write(hardware: snapshot, now: Date())
            let signature = WorkersTelemetry.signature(directories: [WorkersTelemetry.defaultDirectory, WorkersTelemetry.appDirectory])
            Task { @MainActor in
                self.writing = false
                guard !signature.isEmpty, signature != self.lastSignature else { return }
                self.lastSignature = signature
                WidgetCenter.shared.reloadTimelines(ofKind: WorkersTelemetry.widgetKind)
            }
        }
    }
}

/// Janela aberta pelo clique num cartão do widget: qual PC fica na posição e com que apelido.
struct WorkerPositionView: View {
    let position: Int
    let options: [(id: String, name: String)]
    @State var selected: String
    @State var nickname: String
    let config: WidgetLayoutConfig
    let onSave: (WidgetLayoutConfig) -> Void
    let onCancel: () -> Void
    static let automatic = ""

    var body: some View {
        Form {
            Picker("Mostrar", selection: $selected) {
                Text("Automático").tag(Self.automatic)
                ForEach(options, id: \.id) { Text($0.name).tag($0.id) }
            }
            .onChange(of: selected) { _, id in nickname = config.apelidos[id] ?? "" }
            TextField("Apelido", text: $nickname, prompt: Text("Nome original"))
                .disabled(selected == Self.automatic)
            Text(selected == Self.automatic ? "Mostra o próximo PC que não está em outra posição." : "O apelido acompanha o PC se ele mudar de posição.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Salvar") {
                    var value = config
                    value.assign(position: position, worker: selected == Self.automatic ? nil : selected, nickname: nickname)
                    onSave(value)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
