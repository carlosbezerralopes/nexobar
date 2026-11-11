import Darwin
import Foundation
import IOKit
import Metal

/// Energia da GPU pelo IOReport (grupo "Energy Model", canal "GPU Energy"), sem root. É interface privada da Apple, a mesma
/// usada por ferramentas como o macmon: se um macOS novo a mudar, os watts ficam ausentes em vez de errados.
final class GPUEnergy {
    private typealias CopyGroup = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias IntegerValue = @convention(c) (CFDictionary, UnsafeMutablePointer<Int32>?) -> Int64
    private typealias StringValue = @convention(c) (CFDictionary) -> Unmanaged<CFString>?

    private struct API {
        let samples: CreateSamples, delta: CreateDelta, integer: IntegerValue, name: StringValue, unit: StringValue
        let subscription: OpaquePointer, channels: CFMutableDictionary
    }
    private let api: API?
    private var previous: (sample: CFDictionary, uptime: TimeInterval)?

    init() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { api = nil; return }
        func symbol<T>(_ name: String, _: T.Type) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
        guard let copy = symbol("IOReportCopyChannelsInGroup", CopyGroup.self),
              let subscribe = symbol("IOReportCreateSubscription", CreateSubscription.self),
              let samples = symbol("IOReportCreateSamples", CreateSamples.self),
              let delta = symbol("IOReportCreateSamplesDelta", CreateDelta.self),
              let integer = symbol("IOReportSimpleGetIntegerValue", IntegerValue.self),
              let name = symbol("IOReportChannelGetChannelName", StringValue.self),
              let unit = symbol("IOReportChannelGetUnitLabel", StringValue.self),
              let group = copy("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              let channels = CFDictionaryCreateMutableCopy(nil, 0, group) else { api = nil; return }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = subscribe(nil, channels, &subscribed, 0, nil), let subscribedChannels = subscribed?.takeRetainedValue() else { api = nil; return }
        api = API(samples: samples, delta: delta, integer: integer, name: name, unit: unit, subscription: subscription, channels: subscribedChannels)
    }

    /// Watts médios da GPU desde a chamada anterior; nil na primeira chamada ou sem IOReport.
    func watts(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double? {
        guard let api, let sample = api.samples(api.subscription, api.channels, nil)?.takeRetainedValue() else { return nil }
        defer { previous = (sample, uptime) }
        guard let previous, uptime > previous.uptime,
              let delta = api.delta(previous.sample, sample, nil)?.takeRetainedValue() as NSDictionary?,
              let items = delta["IOReportChannels"] as? [NSDictionary] else { return nil }
        let joules = items.compactMap { item -> Double? in
            let channel = item as CFDictionary
            guard api.name(channel)?.takeUnretainedValue() as String? == "GPU Energy" else { return nil }
            return Self.joules(Double(api.integer(channel, nil)), unit: api.unit(channel)?.takeUnretainedValue() as String? ?? "")
        }
        guard !joules.isEmpty else { return nil }
        return joules.reduce(0, +) / (uptime - previous.uptime)
    }

    /// Converte a energia do canal pela unidade informada; unidade desconhecida não vira número.
    static func joules(_ value: Double, unit: String) -> Double? {
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "J": return value
        case "mJ": return value / 1e3
        case "uJ", "µJ": return value / 1e6
        case "nJ": return value / 1e9
        default: return nil
        }
    }

    /// Memória que a GPU está usando (IOAccelerator "In use system memory") e o limite que o macOS lhe permite
    /// (`recommendedMaxWorkingSetSize`, parte da RAM unificada), em MB.
    static func memory() -> (usedMB: Double?, limitMB: Double?) {
        let limit = MTLCreateSystemDefaultDevice().map { Double($0.recommendedMaxWorkingSetSize) / 1_048_576 }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return (nil, limit) }
        defer { IOObjectRelease(iterator) }
        var used: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
            if let bytes = (stats?["In use system memory"] as? NSNumber)?.doubleValue { used = (used ?? 0) + bytes / 1_048_576 }
        }
        return (used, limit)
    }
}
