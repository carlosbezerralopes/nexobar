import Foundation
import WidgetKit
import WorkersTelemetry

/// Lê a fila distribuída do `~/.agents` (`fila.ps1 painel`) a cada minuto e a grava para o widget da fila. Só lê com o
/// widget na mesa e o script presente; `WORKER_NAO_ACORDAR` impede que a consulta acorde o mestre desligado.
@MainActor
final class QueueWidgetReloader {
    private var timer: Timer?
    private var running = false
    private var lastSignature = ""
    private let queue = DispatchQueue(label: "nexobar.queue-widget", qos: .utility)

    nonisolated static func script(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        home.appendingPathComponent(".agents/scripts/worker/fila.ps1")
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: QueueSnapshot.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    /// Clique no widget: lê agora.
    func refresh() { lastSignature = ""; tick(force: true) }

    private func tick(force: Bool = false) {
        guard !running, FileManager.default.isReadableFile(atPath: Self.script().path) else { return }
        running = true
        WidgetCenter.shared.getCurrentConfigurations { [weak self] result in
            let installed = (try? result.get())?.contains { $0.kind == QueueSnapshot.widgetKind } ?? false
            Task { @MainActor in
                guard let self else { return }
                guard installed || force else { self.running = false; return }
                self.read()
            }
        }
    }

    private func read() {
        queue.async {
            let (output, error) = Self.runPanel()
            let next = (QueueSnapshot.load() ?? QueueSnapshot()).updated(output: output, error: error, now: Date())
            try? next.save()
            Task { @MainActor in
                self.running = false
                guard next.signature != self.lastSignature else { return }
                self.lastSignature = next.signature
                WidgetCenter.shared.reloadTimelines(ofKind: QueueSnapshot.widgetKind)
            }
        }
    }

    /// Saída do `painel` quando o script termina com 0; senão, a última linha de erro, sem o prefixo "fila: ". O SSH
    /// tem ConnectTimeout de 8 s; o limite de 45 s cobre um mestre que aceita a conexão e não responde.
    nonisolated private static func runPanel() -> (Data?, String?) {
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["pwsh", "-NoProfile", "-File", script().path, "painel"]
        var environment = ProcessInfo.processInfo.environment
        // App aberto pelo Finder não herda o PATH do terminal; o script usa pwsh, ssh e rsync.
        environment["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["WORKER_NAO_ACORDAR"] = "1"
        process.environment = environment
        process.standardOutput = out; process.standardError = err
        do { try process.run() } catch { return (nil, "pwsh não encontrado") }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit(); killer.cancel()
        if process.terminationStatus == 0 { return (data, nil) }
        let line = errorText.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let reason = line.hasPrefix("fila: ") ? String(line.dropFirst(6)) : line
        return (nil, reason.isEmpty ? (process.terminationReason == .uncaughtSignal ? "sem resposta em 45 s" : "fila.ps1 saiu com \(process.terminationStatus)") : reason)
    }
}
