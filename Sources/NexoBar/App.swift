import AppKit
import SwiftUI
import Darwin

private actor HardwareSampler {
    private lazy var source = HardwareSensors()
    func sample() -> [IndicatorReading] { source.sample() }
}

private actor ActivitySampler {
    func sample(_ ids: [IndicatorID]) -> [IndicatorID: AIActivitySummary] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, AIActivity.read($0, now: Date())) })
    }
}

struct MetricPoint: Identifiable {
    var time: Date
    var value: Double
    var id: Date { time }
}

enum MetricHistory {
    static func updated(_ previous: [MetricPoint], reading: IndicatorReading? = nil, now: Date) -> [MetricPoint] {
        var samples = previous.filter { now.timeIntervalSince($0.time) >= 0 && now.timeIntervalSince($0.time) <= 300 }
        if let reading, let value = reading.numericValue, value.isFinite, let time = reading.sampledAt,
           now.timeIntervalSince(time) >= 0, now.timeIntervalSince(time) <= 300 {
            samples.append(MetricPoint(time: time, value: value))
        }
        return Array(samples.suffix(100))
    }
}

struct StatusBarWidthReservation {
    private var items: [IndicatorConfiguration] = []
    private var appearance: BarAppearance?
    private var budget: CGFloat = 0
    private var width: CGFloat = 0

    mutating func reserve(contentWidth: CGFloat, maxWidth: CGFloat, items: [IndicatorConfiguration], appearance: BarAppearance) -> CGFloat {
        if self.items != items || self.appearance != appearance || budget != maxWidth {
            width = 0
            self.items = items; self.appearance = appearance; budget = maxWidth
        }
        width = min(maxWidth, max(width, contentWidth))
        return width
    }
}

@MainActor
final class Dashboard: ObservableObject {
    @Published var items: [IndicatorConfiguration]
    @Published var readings: [IndicatorID: IndicatorReading] = [:]
    @Published var refreshing = false
    @Published var saveError: String?
    @Published var appearance: BarAppearance
    @Published var history: [IndicatorID: [MetricPoint]] = [:]
    @Published var cliDirectories: CLIWorkingDirectories
    var onChange: (() -> Void)?
    var onQuotaReset: ((AIQuotaResetEvent) -> Void)?
    private let resetWatcher = AIQuotaResetWatcher()
    private let monitor = MachineMonitor()
    private let providers: AIProviders
    private let hardware = HardwareSampler()
    private let activity = ActivitySampler()
    private var hardwareBusy = false
    private var activityBusy = false
    private var refreshingIDs: Set<IndicatorID> = []
    private var timer: Timer?
    private var quotaTimer: Timer?
    private var activityTimer: Timer?
    private let settingsURL: URL
    private let appearanceURL: URL
    private let cliDirectoriesURL: URL

    init(directory: URL) {
        settingsURL = directory.appendingPathComponent("indicators.json")
        let cliURL = directory.appendingPathComponent("cli-directories.json")
        cliDirectoriesURL = cliURL
        cliDirectories = CLIWorkingDirectories.load(from: cliURL)
        providers = AIProviders(fetch: { id, now in
            var result = try AIProviderIntegrations.read(id, now: now, cliDirectories: CLIWorkingDirectories.load(from: cliURL))
            result.activity = AIActivity.read(id, now: now)
            return result
        }, stateDirectory: directory)
        appearanceURL = directory.appendingPathComponent("appearance.json")
        appearance = (try? JSONDecoder().decode(BarAppearance.self, from: Data(contentsOf: appearanceURL))) ?? BarAppearance()
        if let data = try? Data(contentsOf: settingsURL),
           let saved = try? JSONDecoder().decode([IndicatorConfiguration].self, from: data) {
            items = IndicatorConfiguration.normalized(saved)
        } else {
            items = IndicatorConfiguration.defaults
        }
        for id in IndicatorID.allCases { readings[id] = .unavailable(id, "Aguardando primeira leitura") }
    }

    func start() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        quotaTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAI() }
        }
        activityTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleActivity() }
        }
        refreshAI()
    }

    private func sampleActivity() {
        guard !activityBusy else { return }
        let ids = items.filter { $0.enabled && $0.id.isAI }.map(\.id)
        guard !ids.isEmpty else { return }
        activityBusy = true
        Task {
            let summaries = await activity.sample(ids)
            for (id, summary) in summaries { readings[id]?.activity = summary }
            activityBusy = false
            onChange?()
        }
    }

    private func sample() {
        let now = Date()
        for id in IndicatorID.allCases {
            readings[id] = readings[id]?.aged(at: now)
            if let previous = history[id] { history[id] = MetricHistory.updated(previous, now: now) }
        }
        for reading in monitor.sample() where reading.id == .cpu || reading.id == .memory { applyMetric(reading) }
        onChange?()
        guard !hardwareBusy else { return }
        hardwareBusy = true
        Task {
            let fresh = await hardware.sample()
            for reading in fresh { applyMetric(reading) }
            hardwareBusy = false
            onChange?()
        }
    }

    private func applyMetric(_ reading: IndicatorReading) {
        readings[reading.id] = reading
        history[reading.id] = MetricHistory.updated(history[reading.id] ?? [], reading: reading, now: Date())
    }

    func refreshAI(id: IndicatorID? = nil) {
        let ids = id.map { [$0] } ?? items.filter { $0.enabled && $0.id.isAI }.map(\.id)
        for providerID in ids where !refreshingIDs.contains(providerID) {
            refreshingIDs.insert(providerID)
            refreshing = true
            Task {
                let reading = await providers.refresh(id: providerID)
                let resets = resetWatcher.observe(reading)
                readings[reading.id] = reading
                refreshingIDs.remove(providerID)
                refreshing = !refreshingIDs.isEmpty
                onChange?()
                if appearance.notifyResets { for event in resets { onQuotaReset?(event) } }
            }
        }
    }

    func isRefreshing(_ id: IndicatorID) -> Bool { refreshingIDs.contains(id) }

    func setCLIDirectory(_ url: URL?, for id: IndicatorID) {
        do {
            var value = cliDirectories
            try value.set(url, for: id)
            try value.save(to: cliDirectoriesURL)
            cliDirectories = value
            saveError = nil
            readings[id] = .unavailable(id, "Pasta alterada; use Atualizar para testar a sessão existente")
            onChange?()
        } catch { saveError = error.localizedDescription }
    }

    func updateAppearance(_ value: BarAppearance) {
        appearance = value
        do {
            try FileManager.default.createDirectory(at: appearanceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: appearanceURL, options: .atomic)
            saveError = nil
        } catch { saveError = "Não foi possível salvar a aparência." }
        onChange?()
    }

    func update(_ item: IndicatorConfiguration) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let becameVisible = item.enabled && !items[index].enabled
        var replacement = item
        replacement.label = String(replacement.label.prefix(24))
        items[index] = replacement
        save()
        if becameVisible && item.id.isAI { refreshAI(id: item.id) }
    }

    func move(_ id: IndicatorID, offset: Int) {
        let visibleOrder = items.enumerated().filter { !$0.element.id.isNested }
        guard let index = visibleOrder.firstIndex(where: { $0.element.id == id }), visibleOrder.indices.contains(index + offset) else { return }
        items.swapAt(visibleOrder[index].offset, visibleOrder[index + offset].offset)
        save()
    }

    func toggleTemperature(_ owner: IndicatorID) {
        guard let child = owner.temperatureChild, let item = items.first(where: { $0.id == child }) else { return }
        setTemperature(owner, enabled: !item.enabled)
    }
    func setTemperature(_ owner: IndicatorID, enabled: Bool) {
        guard let child = owner.temperatureChild, var item = items.first(where: { $0.id == child }) else { return }
        item.enabled = enabled; update(item)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: settingsURL, options: .atomic)
            saveError = nil
        } catch { saveError = "Não foi possível salvar as preferências. As alterações valem apenas nesta execução." }
        onChange?()
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var status: NSStatusItem?
    private var dashboard: Dashboard!
    private var popover = NSPopover()
    private var settingsWindow: NSWindow?
    private let strip = StatusStrip(frame: .zero)
    private var selectedID: IndicatorID?
    private var contextID: IndicatorID?
    private var resetPanel: NSPanel?
    private var pendingResets: [AIQuotaResetEvent] = []
    private var terminationSignal: DispatchSourceSignal?
    private var presentingContextMenu = false
    private var workspaceObserver: NSObjectProtocol?
    private var diagnosePresentation = false
    private var renderedSnapshotCount = 0
    private var widthReservation = StatusBarWidthReservation()

    func applicationWillTerminate(_ notification: Notification) { UsageCommand.terminateOwnedProcesses() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openSettings() }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume(); terminationSignal = source
        NSApp.setActivationPolicy(.accessory)
        let arguments = CommandLine.arguments
        diagnosePresentation = arguments.contains("--diagnose-presentation")
        let directory: URL
        if let i = arguments.firstIndex(of: "--data-directory"), arguments.indices.contains(i + 1) {
            directory = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NexoBar")
        }
        dashboard = Dashboard(directory: directory)
        strip.onSelect = { [weak self] id, view in self?.showDetail(id: id, anchor: view) }
        strip.onContext = { [weak self] id, view, event in self?.showContext(id: id, view: view, event: event) }
        strip.onEmpty = { [weak self] in self?.openSettings() }
        strip.onOverflow = { [weak self] view in self?.showContext(id: nil, view: view, event: nil) }
        popover.behavior = .transient
        popover.delegate = self
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.dismissExpandedInterface()
                self?.resetPanel?.close()
                self?.resetPanel = nil
                self?.pendingResets.removeAll()
            }
        }
        dashboard.onChange = { [weak self] in self?.renderBar() }
        dashboard.onQuotaReset = { [weak self] event in self?.enqueueReset(event) }
        dashboard.start()
        renderBar()
        if arguments.contains("--settings") { openSettings() }
        if let index = arguments.firstIndex(of: "--capture-window"), arguments.indices.contains(index + 1) {
            let destination = URL(fileURLWithPath: arguments[index + 1])
            let detailID = arguments.firstIndex(of: "--capture-detail").flatMap { i in arguments.indices.contains(i + 1) ? IndicatorID(rawValue: arguments[i + 1]) : nil }
            let delay = arguments.firstIndex(of: "--capture-delay").flatMap { i in arguments.indices.contains(i + 1) ? Double(arguments[i + 1]) : nil } ?? 4
            if let detailID, let anchor = status?.button {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak anchor] in
                    if let anchor { self?.showDetail(id: detailID, anchor: anchor) }
                }
            }
            else { openSettings() }
            DispatchQueue.main.asyncAfter(deadline: .now() + min(max(delay, 1), 60)) { [weak self] in
                guard let view = detailID == nil ? self?.settingsWindow?.contentView : self?.popover.contentViewController?.view else { print("Capture failed: view unavailable"); return }
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { print("Capture failed: empty bitmap bounds \(view.bounds)"); return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    do {
                        try png.write(to: destination)
                        print("Capture OK: \(detailID?.rawValue ?? "settings"), \(Int(view.bounds.width))x\(Int(view.bounds.height)), popover=\(self?.popover.isShown ?? false)")
                    } catch { print("Capture failed: could not write PNG") }
                }
            }
        }
    }

    private func ensureStatusItem() {
        guard status == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status = item
        item.button?.title = ""
        // Keep the live layout offscreen. AppKit owns the status button's image and mouse tracking.
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleNone
        item.button?.toolTip = "NexoBar · clique para detalhes; botão direito para opções"
        if #available(macOS 27, *) {
            item.expandedInterfaceDelegate = self
        } else {
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func logPresentation(reason: String, options: NSApplication.PresentationOptions) {
        guard diagnosePresentation else { return }
        let activeSpace = (status?.button?.window).map { String($0.isOnActiveSpace) } ?? "none"
        let session: Bool
        if #available(macOS 27, *) { session = status?.expandedInterfaceSession != nil }
        else { session = false }
        print("presentation time=\(Date().timeIntervalSince1970) reason=\(reason) raw=\(options.rawValue) rendered=\(renderedSnapshotCount) status=\(status != nil) activeSpace=\(activeSpace) popover=\(popover.isShown) menu=\(presentingContextMenu) session=\(session)")
        fflush(stdout)
    }

    private func renderBar(reason: String = "snapshot") {
        let options = NSApp.currentSystemPresentationOptions
        guard !presentingContextMenu else { return }
        ensureStatusItem()
        guard let status else { return }
        let screen = NSScreen.screens.first
        let available = screen?.auxiliaryTopRightArea?.width ?? (screen?.frame.width ?? 1440) / 2
        let widthBudget = max(240, min(480, available - 220))
        let contentWidth = strip.update(items: dashboard.items, readings: dashboard.readings, appearance: dashboard.appearance, layout: dashboard.appearance.quotaLayout, detailedTime: dashboard.appearance.detailedTime, maxWidth: widthBudget)
        let width = widthReservation.reserve(contentWidth: contentWidth, maxWidth: widthBudget, items: dashboard.items, appearance: dashboard.appearance)
        if status.length != width { status.length = width }
        let frame = NSRect(x: 0, y: 0, width: contentWidth, height: NSStatusBar.system.thickness)
        if strip.frame != frame { strip.frame = frame }
        if let button = status.button {
            button.image = strip.renderStatusImage(width: width, height: frame.height,
                                                   appearance: button.effectiveAppearance, highlighted: false)
            button.alternateImage = strip.renderStatusImage(width: width, height: frame.height,
                                                            appearance: button.effectiveAppearance, highlighted: true)
        }
        if let selectedID, !dashboard.items.contains(where: { $0.id == selectedID && $0.enabled }) { popover.performClose(nil) }
        renderedSnapshotCount += 1
        logPresentation(reason: reason, options: options)
    }

    private func showDetail(id: IndicatorID, anchor: NSView) {
        if popover.isShown && selectedID == id { popover.performClose(nil); return }
        selectedID = id
        let controller = NSHostingController(rootView: IndicatorDetailView(model: dashboard, id: id, customize: { [weak self] in self?.openSettings() }))
        let detailSize = NSSize(width: 420, height: id.isAI ? 560 : 430)
        controller.view.frame = NSRect(origin: .zero, size: detailSize)
        popover.contentViewController = controller
        popover.contentSize = detailSize
        strip.setStatusItemHighlighted(true)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        if !popover.isShown {
            selectedID = nil
            strip.setStatusItemHighlighted(false)
            cancelExpandedSession()
        }
    }

    @objc private func statusItemClicked(_ button: NSStatusBarButton) {
        guard let event = NSApp.currentEvent, acceptsInteraction(event) else { cancelExpandedSession(); return }
        _ = strip.handleStatusItemEvent(event, from: button)
    }

    private func acceptsInteraction(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return dashboard.appearance.interactionDisplay == .any }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        return dashboard.appearance.interactionDisplay.allows(point: point, primaryFrame: NSScreen.screens.first?.frame)
    }

    func popoverDidClose(_ notification: Notification) {
        // An old animated close must not clear a replacement or a context menu.
        guard !popover.isShown, !presentingContextMenu else { return }
        selectedID = nil
        strip.setStatusItemHighlighted(false)
        cancelExpandedSession()
    }

    private func cancelExpandedSession() {
        if #available(macOS 27, *) { status?.expandedInterfaceSession?.cancel() }
    }

    private func dismissExpandedInterface() {
        popover.performClose(nil)
        selectedID = nil
        strip.setStatusItemHighlighted(false)
        cancelExpandedSession()
    }

    private func showContext(id: IndicatorID?, view: NSView, event: NSEvent?) {
        presentingContextMenu = true
        popover.performClose(nil)
        selectedID = nil
        strip.setStatusItemHighlighted(true)
        defer {
            presentingContextMenu = false
            if !popover.isShown {
                strip.setStatusItemHighlighted(false)
                cancelExpandedSession()
            }
            renderBar()
        }
        contextID = id
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item); return item
        }
        if !strip.hiddenIDs.isEmpty {
            for hiddenID in strip.hiddenIDs {
                let config = dashboard.items.first(where: { $0.id == hiddenID })
                let value = dashboard.readings[hiddenID]?.displayValue(memory: config?.memoryDisplay ?? .usedTotal) ?? "—"
                let item = add("\(config?.label ?? hiddenID.name) · \(value)", #selector(openOverflowDetail(_:)))
                item.representedObject = hiddenID.rawValue
            }
            menu.addItem(.separator())
        }
        _ = add("Personalizar barra…", #selector(contextSettings))
        for owner in [IndicatorID.cpu, .gpu] {
            let parent = NSMenuItem(title: owner.name, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let temperature = NSMenuItem(title: "Mostrar temperatura", action: #selector(toggleTemperature(_:)), keyEquivalent: "")
            temperature.target = self; temperature.representedObject = owner.rawValue
            temperature.state = dashboard.items.first(where: { $0.id == owner.temperatureChild })?.enabled == true ? .on : .off
            submenu.addItem(temperature); parent.submenu = submenu; menu.addItem(parent)
        }
        let horizontal = add("Limites de IA: horizontal", #selector(useHorizontal))
        horizontal.state = dashboard.appearance.quotaLayout == .inline ? .on : .off
        let stacked = add("Limites de IA: duas linhas", #selector(useStacked))
        stacked.state = dashboard.appearance.quotaLayout == .stacked ? .on : .off
        let detail = add("Detalhar tempo restante", #selector(toggleDetailedTime))
        detail.state = dashboard.appearance.detailedTime ? .on : .off
        let notify = add("Avisar quando a cota renovar", #selector(toggleResetNotices))
        notify.state = dashboard.appearance.notifyResets ? .on : .off
        menu.addItem(.separator())
        if let id {
            if id.isAI { _ = add("Atualizar \(id.name)", #selector(refreshContext)) }
            _ = add("Ocultar \(id.name)", #selector(hideContext))
        }
        _ = add("Atualizar todas as cotas", #selector(refreshAll))
        menu.addItem(.separator())
        _ = add("Sair do NexoBar", #selector(quit))
        if let event { NSMenu.popUpContextMenu(menu, with: event, for: view) }
        else { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY), in: view) }
    }

    @objc private func openOverflowDetail(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = IndicatorID(rawValue: raw), let anchor = status?.button else { return }
        showDetail(id: id, anchor: anchor)
    }

    @objc private func contextSettings() { openSettings() }
    @objc private func toggleTemperature(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let owner = IndicatorID(rawValue: raw) { dashboard.toggleTemperature(owner) }
    }
    @objc private func useHorizontal() { var value = dashboard.appearance; value.quotaLayout = .inline; dashboard.updateAppearance(value) }
    @objc private func useStacked() { var value = dashboard.appearance; value.quotaLayout = .stacked; dashboard.updateAppearance(value) }
    @objc private func toggleDetailedTime() { var value = dashboard.appearance; value.detailedTime.toggle(); dashboard.updateAppearance(value) }
    @objc private func toggleResetNotices() { var value = dashboard.appearance; value.notifyResets.toggle(); dashboard.updateAppearance(value) }
    @objc private func refreshContext() { if let contextID { dashboard.refreshAI(id: contextID) } }
    @objc private func refreshAll() { dashboard.refreshAI() }
    @objc private func hideContext() {
        if var item = dashboard.items.first(where: { $0.id == contextID }) { item.enabled = false; dashboard.update(item) }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func enqueueReset(_ event: AIQuotaResetEvent) {
        pendingResets.append(event)
        if resetPanel == nil { showNextReset() }
    }
    private func showNextReset() {
        guard !pendingResets.isEmpty else { return }
        let event = pendingResets.removeFirst()
        // Public presentation state is only a best-effort signal for other apps' fullscreen modes.
        guard !NSApp.currentSystemPresentationOptions.contains(.fullScreen) else { pendingResets.removeAll(); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 100), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.hidesOnDeactivate = true
        panel.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 8) {
            Label("\(event.provider.name) · cota renovada", systemImage: "arrow.clockwise.circle.fill").font(.headline).foregroundStyle(.teal)
            Text("\(event.windowName): \(IndicatorReading.percent(event.currentPercent)) utilizado").font(.callout)
            Text("Confirmação recebida do provedor").font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(width: 340, height: 100).background(Color(nsColor: .windowBackgroundColor)))
        if let screen = status?.button?.window?.screen ?? NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 356, y: screen.visibleFrame.maxY - 116))
        }
        resetPanel = panel; panel.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak panel] in
            guard let self, let panel, self.resetPanel === panel else { return }
            panel.close(); self.resetPanel = nil; self.showNextReset()
        }
    }

    private func openSettings() {
        dismissExpandedInterface()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 740), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Personalizar NexoBar"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: dashboard))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@available(macOS 27, *)
extension ApplicationDelegate: @preconcurrency NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin expandedInterfaceSession: NSStatusItemExpandedInterfaceSession) {
        guard let button = statusItem.button else { expandedInterfaceSession.cancel(); return }
        if let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(event.type) {
            guard acceptsInteraction(event), strip.handleStatusItemEvent(event, from: button) else {
                expandedInterfaceSession.cancel()
                return
            }
        } else {
            // Keyboard navigation has no monitor-local mouse location.
            showContext(id: nil, view: button, event: nil)
        }
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        popover.performClose(nil)
        selectedID = nil
        strip.setStatusItemHighlighted(false)
    }
}

@main
enum NexoBarMain {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--diagnose-claude") {
            let start = Date()
            var result: [String: Any]
            do {
                let reading = try AIProviderIntegrations.read(.claude, now: start)
                let windows: [[String: Any]] = reading.windows.map { window in
                    ["id": window.id ?? "", "usedPercent": window.usedPercent.map { $0 as Any } ?? NSNull(),
                     "resetsAt": window.resetsAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull()]
                }
                result = ["status": "ok", "value": reading.value, "windows": windows]
            } catch {
                let reason: String
                if let error = error as? ClaudePTYError { reason = error.message }
                else if let error = error as? CLIWorkingDirectoryError { reason = error.localizedDescription }
                else if let error = error as? AIReadError { reason = error.message }
                else { reason = "Consulta indisponível" }
                result = ["status": "unavailable", "reason": reason]
            }
            result["elapsedSeconds"] = Date().timeIntervalSince(start)
            result["ownedProcessesAfter"] = UsageCommand.runningProcessCount
            if let bytes = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), let text = String(data: bytes, encoding: .utf8) { print(text) }
            return
        }
        if CommandLine.arguments.contains("--diagnose") {
            let monitor = MachineMonitor()
            let hardware = HardwareSensors()
            _ = monitor.sample()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            for reading in monitor.sample().filter({ $0.id == .cpu || $0.id == .memory }) + hardware.sample() {
                print("\(reading.id.rawValue): \(reading.value) | \(reading.detail)")
            }
            return
        }
        if CommandLine.arguments.contains("--diagnose-ai") {
            for reading in await AIProviders().refresh() {
                let reason = reading.sampledAt == nil ? " | \(reading.detail)" : ""
                print("\(reading.id.rawValue): \(reading.sampledAt == nil ? "indisponível" : "leitura recebida") | janelas=\(reading.windows.count) | antiga=\(reading.isStale)\(reason)")
            }
            return
        }
        let app = NSApplication.shared
        let delegate = ApplicationDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
