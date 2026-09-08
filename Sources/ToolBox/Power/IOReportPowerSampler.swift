import CoreFoundation
import Darwin
import Foundation

final class IOReportPowerSampler {
    private let functions: IOReportFunctions
    private let subscription: IOReportSubscriptionRef
    private let channels: CFMutableDictionary
    private let selectedChannels: CFMutableArray

    private var previousSample: CFDictionary?
    private var previousTimestamp: Date?

    init() throws {
        self.functions = try IOReportFunctions()

        let allChannels = try functions.copyAllChannels()
        let channelItems = IOReportPowerSampler.channelItems(from: allChannels)
        var callbacks = kCFTypeArrayCallBacks
        guard let selected = CFArrayCreateMutable(kCFAllocatorDefault, channelItems.count, &callbacks) else {
            throw IOReportPowerError.noEnergyChannels
        }

        for item in channelItems {
            let group = functions.channelGroup(item)
            let subgroup = functions.channelSubgroup(item)
            let channel = functions.channelName(item)
            let unit = functions.channelUnit(item).trimmingCharacters(in: .whitespacesAndNewlines)
            guard IOReportPowerSampler.shouldSample(group: group, subgroup: subgroup, channel: channel, unit: unit) else {
                continue
            }

            CFArrayAppendValue(selected, Unmanaged.passUnretained(item).toOpaque())
        }

        guard CFArrayGetCount(selected) > 0 else {
            throw IOReportPowerError.noEnergyChannels
        }

        guard let mutable = CFDictionaryCreateMutableCopy(
            kCFAllocatorDefault,
            CFDictionaryGetCount(allChannels),
            allChannels
        ) else {
            throw IOReportPowerError.noEnergyChannels
        }
        let key = "IOReportChannels" as CFString
        CFDictionarySetValue(
            mutable,
            Unmanaged.passUnretained(key).toOpaque(),
            Unmanaged.passUnretained(selected).toOpaque()
        )

        self.channels = mutable
        self.selectedChannels = selected
        self.subscription = try functions.createSubscription(channels: self.channels)
    }

    func sample() throws -> IOReportPowerReading? {
        let nextSample = try functions.createSamples(subscription: subscription, channels: channels)
        let now = Date()

        guard let previousSample, let previousTimestamp else {
            self.previousSample = nextSample
            self.previousTimestamp = now
            return nil
        }

        let elapsedMS = max(now.timeIntervalSince(previousTimestamp) * 1_000.0, 1.0)
        let delta = try functions.createDelta(previous: previousSample, next: nextSample)
        self.previousSample = nextSample
        self.previousTimestamp = now

        return parse(delta: delta, previous: previousSample, next: nextSample, elapsedMS: elapsedMS)
    }

    func reset() {
        previousSample = nil
        previousTimestamp = nil
    }

    private func parse(
        delta: CFDictionary,
        previous: CFDictionary,
        next: CFDictionary,
        elapsedMS: Double
    ) -> IOReportPowerReading {
        var reading = IOReportPowerReading(sampleInterval: elapsedMS / 1_000.0)
        let previousItems = Self.itemsByIdentity(from: previous)
        let nextItems = Self.itemsByIdentity(from: next)

        for item in Self.channelItems(from: delta) {
            let group = functions.channelGroup(item)
            let channel = functions.channelName(item)
            let unit = functions.channelUnit(item).trimmingCharacters(in: .whitespacesAndNewlines)
            guard group == "Energy Model" else { continue }
            let identity = Self.channelIdentity(item)
            guard let previousItem = previousItems[identity], let nextItem = nextItems[identity],
                  let interval = Self.sampleInterval(
                    previousTimestamp: Self.channelTimestamp(previousItem),
                    nextTimestamp: Self.channelTimestamp(nextItem),
                    fallback: elapsedMS / 1_000.0
                  ),
                  let watts = watts(from: item, unit: unit, elapsedMS: interval * 1_000.0) else {
                reading.invalidChannels.append(channel)
                continue
            }

            switch channel {
            case "GPU Energy":
                reading.gpuWatts += watts
                reading.gpuChannelCount += 1
            case let channel where channel.hasSuffix("CPU Energy"):
                reading.cpuWatts += watts
                reading.cpuChannelCount += 1
            case let channel where channel.hasPrefix("ANE"):
                reading.aneWatts += watts
            case let channel where channel.hasPrefix("DRAM"):
                reading.dramWatts += watts
            case let channel where channel.hasPrefix("GPU SRAM"):
                reading.gpuSRAMWatts += watts
            default:
                break
            }
        }

        reading.combinedWatts = reading.cpuWatts + reading.gpuWatts + reading.aneWatts
        return reading
    }

    private func watts(from item: CFDictionary, unit: String, elapsedMS: Double) -> Double? {
        let value = functions.simpleIntegerValue(item)
        guard value >= 0 else { return nil }
        let raw = Double(value)
        let valuePerSecond = raw / (elapsedMS / 1_000.0)

        switch unit {
        case "mJ":
            return valuePerSecond / 1_000.0
        case "uJ":
            return valuePerSecond / 1_000_000.0
        case "nJ":
            return valuePerSecond / 1_000_000_000.0
        default:
            return nil
        }
    }

    // IOReportElement.timestamp is mach_absolute_time(), at byte 24 of the
    // 64-byte element defined in Apple's IOReportTypes.h. An unchanged driver
    // timestamp is a stale sample, even when subtracting its counters yields 0.
    static func channelTimestamp(_ item: CFDictionary) -> UInt64? {
        guard let data = (item as NSDictionary)["RawElements"] as? Data,
              data.count >= 64 else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt64.self) }
    }

    static func sampleInterval(
        previousTimestamp: UInt64?, nextTimestamp: UInt64?, fallback: TimeInterval
    ) -> TimeInterval? {
        guard let previousTimestamp, let nextTimestamp else { return fallback }
        guard previousTimestamp > 0, nextTimestamp > previousTimestamp else { return nil }
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else { return nil }
        return Double(nextTimestamp - previousTimestamp)
            * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000.0
    }

    private static func channelIdentity(_ item: CFDictionary) -> String {
        let dictionary = item as NSDictionary
        let legend = dictionary["LegendChannel"] as? NSArray
        return "\(dictionary["DriverID"] ?? ""):\(legend?.firstObject ?? "")"
    }

    private static func itemsByIdentity(from dictionary: CFDictionary) -> [String: CFDictionary] {
        var items: [String: CFDictionary] = [:]
        for item in channelItems(from: dictionary) { items[channelIdentity(item)] = item }
        return items
    }

    private static func channelItems(from dictionary: CFDictionary) -> [CFDictionary] {
        guard let array = (dictionary as NSDictionary)["IOReportChannels"] as? NSArray else {
            return []
        }

        return array.compactMap { item in
            if let dict = item as? NSDictionary {
                return dict as CFDictionary
            }
            return nil
        }
    }

    private static func shouldSample(group: String, subgroup: String, channel: String, unit: String) -> Bool {
        guard group == "Energy Model" else {
            return false
        }

        return channel == "GPU Energy"
            || channel.hasSuffix("CPU Energy")
            || channel.hasPrefix("ANE")
            || channel.hasPrefix("DRAM")
            || channel.hasPrefix("GPU SRAM")
    }
}

struct IOReportPowerReading: Equatable {
    var cpuWatts: Double = 0
    var gpuWatts: Double = 0
    var aneWatts: Double = 0
    var combinedWatts: Double = 0
    var dramWatts: Double = 0
    var gpuSRAMWatts: Double = 0
    var sampleInterval: TimeInterval

    // A zero value is valid only when a matching channel was actually sampled.
    var cpuChannelCount: Int = 0
    var gpuChannelCount: Int = 0
    var invalidChannels: [String] = []
}

enum IOReportPowerError: Error, LocalizedError {
    case libraryUnavailable
    case symbolUnavailable(String)
    case noEnergyChannels
    case subscriptionFailed
    case sampleFailed
    case deltaFailed

    var errorDescription: String? {
        switch self {
        case .libraryUnavailable:
            return "libIOReport.dylib is unavailable."
        case let .symbolUnavailable(symbol):
            return "IOReport symbol is unavailable: \(symbol)."
        case .noEnergyChannels:
            return "No Apple Energy Model channels were found."
        case .subscriptionFailed:
            return "Failed to create IOReport subscription."
        case .sampleFailed:
            return "Failed to create IOReport sample."
        case .deltaFailed:
            return "Failed to create IOReport delta sample."
        }
    }
}

private typealias IOReportSubscriptionRef = UnsafeRawPointer

private final class IOReportFunctions {
    private typealias CopyAllChannels = @convention(c) (UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias CreateSubscription = @convention(c) (
        UnsafeRawPointer?,
        CFMutableDictionary,
        UnsafeMutablePointer<CFMutableDictionary?>?,
        UInt64,
        UnsafeRawPointer?
    ) -> IOReportSubscriptionRef?
    private typealias CreateSamples = @convention(c) (
        IOReportSubscriptionRef,
        CFMutableDictionary,
        UnsafeRawPointer?
    ) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c) (
        CFDictionary,
        CFDictionary,
        UnsafeRawPointer?
    ) -> Unmanaged<CFDictionary>?
    private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias SimpleIntegerValue = @convention(c) (CFDictionary, Int32) -> Int64

    private let handle: UnsafeMutableRawPointer
    private let copyAllChannelsFn: CopyAllChannels
    private let createSubscriptionFn: CreateSubscription
    private let createSamplesFn: CreateSamples
    private let createSamplesDeltaFn: CreateSamplesDelta
    private let channelGetGroupFn: ChannelString
    private let channelGetSubGroupFn: ChannelString
    private let channelGetNameFn: ChannelString
    private let channelGetUnitFn: ChannelString
    private let simpleIntegerValueFn: SimpleIntegerValue

    init() throws {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else {
            throw IOReportPowerError.libraryUnavailable
        }

        self.handle = handle
        self.copyAllChannelsFn = try Self.load("IOReportCopyAllChannels", from: handle)
        self.createSubscriptionFn = try Self.load("IOReportCreateSubscription", from: handle)
        self.createSamplesFn = try Self.load("IOReportCreateSamples", from: handle)
        self.createSamplesDeltaFn = try Self.load("IOReportCreateSamplesDelta", from: handle)
        self.channelGetGroupFn = try Self.load("IOReportChannelGetGroup", from: handle)
        self.channelGetSubGroupFn = try Self.load("IOReportChannelGetSubGroup", from: handle)
        self.channelGetNameFn = try Self.load("IOReportChannelGetChannelName", from: handle)
        self.channelGetUnitFn = try Self.load("IOReportChannelGetUnitLabel", from: handle)
        self.simpleIntegerValueFn = try Self.load("IOReportSimpleGetIntegerValue", from: handle)
    }

    deinit {
        dlclose(handle)
    }

    func copyAllChannels() throws -> CFDictionary {
        guard let dictionary = copyAllChannelsFn(0, 0) else {
            throw IOReportPowerError.noEnergyChannels
        }
        return dictionary.takeRetainedValue()
    }

    func createSubscription(channels: CFMutableDictionary) throws -> IOReportSubscriptionRef {
        if let subscription = createSubscriptionFn(nil, channels, nil, 0, nil) {
            return subscription
        }

        var output: CFMutableDictionary?
        guard let subscription = createSubscriptionFn(nil, channels, &output, 0, nil) else {
            throw IOReportPowerError.subscriptionFailed
        }
        return subscription
    }

    func createSamples(subscription: IOReportSubscriptionRef, channels: CFMutableDictionary) throws -> CFDictionary {
        guard let sample = createSamplesFn(subscription, channels, nil) else {
            throw IOReportPowerError.sampleFailed
        }
        return sample.takeRetainedValue()
    }

    func createDelta(previous: CFDictionary, next: CFDictionary) throws -> CFDictionary {
        guard let delta = createSamplesDeltaFn(previous, next, nil) else {
            throw IOReportPowerError.deltaFailed
        }
        return delta.takeRetainedValue()
    }

    func channelGroup(_ item: CFDictionary) -> String {
        string(channelGetGroupFn, item)
    }

    func channelSubgroup(_ item: CFDictionary) -> String {
        string(channelGetSubGroupFn, item)
    }

    func channelName(_ item: CFDictionary) -> String {
        string(channelGetNameFn, item)
    }

    func channelUnit(_ item: CFDictionary) -> String {
        string(channelGetUnitFn, item)
    }

    func simpleIntegerValue(_ item: CFDictionary) -> Int64 {
        simpleIntegerValueFn(item, 0)
    }

    private func string(_ function: ChannelString, _ item: CFDictionary) -> String {
        guard let value = function(item) else {
            return ""
        }
        return value.takeUnretainedValue() as String
    }

    private static func load<T>(_ name: String, from handle: UnsafeMutableRawPointer) throws -> T {
        guard let symbol = dlsym(handle, name) else {
            throw IOReportPowerError.symbolUnavailable(name)
        }
        return unsafeBitCast(symbol, to: T.self)
    }
}
