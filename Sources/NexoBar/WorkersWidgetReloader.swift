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

/// Acorda um worker desconectado pelo script do `~/.agents` (Wake-on-LAN e espera do SSH, até 4 min). O NexoBar não
/// sabe acordar ninguém sozinho: sem o script, a opção não aparece. Continua rodando se a janela fechar.
@MainActor
final class WorkerWaker: ObservableObject {
    static let shared = WorkerWaker()
    @Published private(set) var running: Set<String> = []
    @Published private(set) var lastLine: [String: String] = [:]
    var onFinish: (() -> Void)?

    nonisolated static func script(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        home.appendingPathComponent(".agents/scripts/worker/acordar.sh")
    }

    /// Só workers (o Mac não se acorda) e só com o script presente.
    nonisolated static func canWake(_ id: String, script: URL = script()) -> Bool {
        id.hasPrefix("worker-") && FileManager.default.isReadableFile(atPath: script.path)
    }

    func wake(_ id: String) {
        guard Self.canWake(id), !running.contains(id) else { return }
        running.insert(id); lastLine[id] = "Enviando o pedido para acordar…"
        try? WakeMarks.set(id, waking: true)
        onFinish?()
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.script().path, id]
        var environment = ProcessInfo.processInfo.environment
        // App aberto pelo Finder não herda o PATH do terminal; o script usa jq, ssh e python3.
        environment["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.standardOutput = pipe; process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            let line = text.split(whereSeparator: \.isNewline).last.map(String.init)?.trimmingCharacters(in: .whitespaces)
            guard let line, !line.isEmpty else { return }
            Task { @MainActor in self?.lastLine[id] = line }
        }
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            let ok = finished.terminationStatus == 0
            try? WakeMarks.set(id, waking: false)
            Task { @MainActor in
                self?.running.remove(id)
                if ok, self?.lastLine[id]?.isEmpty != false { self?.lastLine[id] = "Ligado." }
                self?.onFinish?()
            }
        }
        do { try process.run() } catch {
            running.remove(id); lastLine[id] = "Não foi possível rodar o script de acordar."
            try? WakeMarks.set(id, waking: false); onFinish?()
        }
    }
}

/// Janela aberta pelo clique num cartão do widget: qual PC fica na posição e com que apelido; se o PC mostrado ali
/// estiver desconectado, oferece acordá-lo.
struct WorkerPositionView: View {
    let position: Int
    /// Worker mostrado na posição, quando desconectado e acordável.
    let sleeping: (id: String, name: String)?
    @ObservedObject var waker: WorkerWaker = .shared
    let options: [(id: String, name: String)]
    @State var selected: String
    @State var nickname: String
    let config: WidgetLayoutConfig
    let onSave: (WidgetLayoutConfig) -> Void
    let onCancel: () -> Void
    static let automatic = ""

    var body: some View {
        Form {
            if let sleeping {
                HStack {
                    Image(systemName: "moon.zzz").foregroundStyle(.orange)
                    Text("\(sleeping.name) está desconectado.")
                    Spacer()
                    Button(waker.running.contains(sleeping.id) ? "Acordando…" : "Acordar") { waker.wake(sleeping.id) }
                        .disabled(waker.running.contains(sleeping.id))
                }
                if let line = waker.lastLine[sleeping.id] {
                    Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                Divider()
            }
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
