import Foundation

// Adapted from Codenotch windows/codenotch/src/reset_watch.rs (MIT).
struct AIQuotaResetEvent: Equatable, Identifiable {
    var provider: IndicatorID
    var windowID: String
    var windowName: String
    var previousPercent: Double
    var currentPercent: Double
    var resetsAt: Date?
    var id: String { provider.rawValue + "." + windowID }
}

final class AIQuotaResetWatcher {
    private struct WindowState {
        var used: Double
        var peak: Double
        var reset: Date?
        var alertedAt: Date? = nil
        var alertedReset: Date? = nil
    }
    private struct ProviderState {
        var sampledAt: Date = .distantPast
        var windows: [String: WindowState] = [:]
    }
    private var providers: [IndicatorID: ProviderState] = [:]
    func observe(_ reading: IndicatorReading, now: Date = Date()) -> [AIQuotaResetEvent] {
        guard reading.id.isAI, !reading.isStale, let sampled = reading.sampledAt,
              sampled.timeIntervalSince(now) <= 60, now.timeIntervalSince(sampled) <= 300 else {
            providers[reading.id] = nil; return []
        }
        var provider = providers[reading.id] ?? ProviderState()
        guard sampled > provider.sampledAt else { return [] }
        provider.sampledAt = sampled
        var events: [AIQuotaResetEvent] = [], seen = Set<String>()
        for window in reading.windows {
            guard let id = window.id, let used = window.usedPercent, used.isFinite, (0...100).contains(used),
                  // Supplemental model/review buckets never replace account quotas.
                  !(reading.id == .codex && id.contains(".")), seen.insert(id).inserted else { continue }
            guard var previous = provider.windows[id] else {
                provider.windows[id] = WindowState(used: used, peak: used, reset: window.resetsAt); continue
            }
            let elapsed = previous.reset.map { $0 <= sampled } ?? false
            let dateRolled: Bool
            if let before = previous.reset, let after = window.resetsAt {
                dateRolled = elapsed && after > sampled && after.timeIntervalSince(before) >= 60 && after > (previous.alertedReset ?? .distantPast)
            } else { dateRolled = false }
            let dropped = previous.used - used + 0.000_000_001 >= 10 && (previous.reset == nil || elapsed)
            let outsideCooldown = previous.alertedAt.map { sampled.timeIntervalSince($0) >= 900 } ?? true
            if previous.peak >= 10, outsideCooldown, dateRolled || dropped {
                events.append(AIQuotaResetEvent(provider: reading.id, windowID: id, windowName: window.name, previousPercent: previous.used,
                                               currentPercent: used, resetsAt: window.resetsAt))
                previous.peak = used; previous.alertedAt = sampled; previous.alertedReset = window.resetsAt
            } else { previous.peak = max(previous.peak, used) }
            previous.used = used; previous.reset = window.resetsAt; provider.windows[id] = previous
        }
        provider.windows = provider.windows.filter { seen.contains($0.key) }
        providers[reading.id] = provider
        return events
    }
}
