import Foundation
import WidgetKit
import WorkersTelemetry

/// Pede ao WidgetKit que recarregue o widget dos workers quando o coletor grava uma leitura nova.
@MainActor
final class WorkersWidgetReloader {
    private var timer: Timer?
    private var lastSignature = ""
    private let directory: URL

    init(directory: URL = WorkersTelemetry.defaultDirectory) { self.directory = directory }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        check()
    }

    private func check() {
        let signature = WorkersTelemetry.signature(directory: directory)
        guard !signature.isEmpty, signature != lastSignature else { return }
        lastSignature = signature
        WidgetCenter.shared.reloadTimelines(ofKind: WorkersTelemetry.widgetKind)
    }
}
