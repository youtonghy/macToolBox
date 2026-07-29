import Foundation

struct AppAudioRule: Codable, Equatable, Identifiable, Sendable {
    static let supportedVolumeRange = 0...300

    var id: String { bundleID }
    let bundleID: String
    private(set) var volumePercent: Int
    var outputDeviceUID: String?

    init(bundleID: String, volumePercent: Int = 100, outputDeviceUID: String? = nil) {
        self.bundleID = bundleID
        self.volumePercent = Self.clamp(volumePercent)
        self.outputDeviceUID = outputDeviceUID
    }

    mutating func setVolumePercent(_ value: Int) {
        volumePercent = Self.clamp(value)
    }

    private static func clamp(_ value: Int) -> Int {
        min(max(value, supportedVolumeRange.lowerBound), supportedVolumeRange.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case bundleID
        case volumePercent
        case outputDeviceUID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bundleID: try container.decode(String.self, forKey: .bundleID),
            volumePercent: try container.decodeIfPresent(Int.self, forKey: .volumePercent) ?? 100,
            outputDeviceUID: try container.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        )
    }
}

struct AudioOutputDevice: Codable, Equatable, Identifiable, Sendable {
    var id: String { uid }
    let uid: String
    var name: String
    var isAvailable: Bool
    var compatibilityIssue: AudioOutputCompatibilityIssue?
    var sampleRate: Double?

    var isRoutable: Bool {
        isAvailable && compatibilityIssue == nil
    }

    init(
        uid: String,
        name: String,
        isAvailable: Bool,
        compatibilityIssue: AudioOutputCompatibilityIssue? = nil,
        sampleRate: Double? = nil
    ) {
        self.uid = uid
        self.name = name
        self.isAvailable = isAvailable
        self.compatibilityIssue = compatibilityIssue
        self.sampleRate = sampleRate
    }
}

struct AudioProcessSnapshot: Equatable, Identifiable, Sendable {
    var id: UInt32 { objectID }
    let objectID: UInt32
    let pid: pid_t
    let bundleID: String
    let name: String
    /// `kAudioProcessPropertyIsRunning` (`pir?`) — SoundSource's primary flag.
    let isRunning: Bool
    /// `kAudioProcessPropertyIsRunningOutput` (`piro`).
    let isRunningOutput: Bool

    /// Either public HAL running bit is enough to treat the process as audio-active.
    var isHALActive: Bool { isRunning || isRunningOutput }

    init(
        objectID: UInt32,
        pid: pid_t,
        bundleID: String,
        name: String,
        isRunningOutput: Bool,
        isRunning: Bool = false
    ) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.isRunning = isRunning
        self.isRunningOutput = isRunningOutput
    }
}

/// SoundSource-style list membership: active now, recently active, or user-configured.
enum AudioAppListVisibility {
    /// Keep apps in the UI briefly after HAL/route activity drops (Spotify flag jitter).
    static let recentlyActiveWindow: TimeInterval = 12

    static func shouldShow(
        isHALActive: Bool,
        isRouteActive: Bool,
        hasSavedRule: Bool,
        lastActiveAt: Date?,
        now: Date,
        recentlyActiveWindow: TimeInterval = recentlyActiveWindow
    ) -> Bool {
        if isHALActive || isRouteActive || hasSavedRule { return true }
        guard let lastActiveAt else { return false }
        return now.timeIntervalSince(lastActiveAt) <= recentlyActiveWindow
    }

    static func isRecentlyActive(
        lastActiveAt: Date?,
        now: Date,
        window: TimeInterval = recentlyActiveWindow
    ) -> Bool {
        guard let lastActiveAt else { return false }
        return now.timeIntervalSince(lastActiveAt) <= window
    }
}

struct AudioRouteSource: Equatable, Sendable {
    let bundleID: String
    let processObjectID: UInt32
    let linearGain: Float
}

struct AudioRoutePlan: Equatable, Identifiable, Sendable {
    var id: String { outputDeviceUID }
    let outputDeviceUID: String
    let deviceConfigurationGeneration: Int
    let sources: [AudioRouteSource]

    init(
        outputDeviceUID: String,
        deviceConfigurationGeneration: Int = 0,
        sources: [AudioRouteSource]
    ) {
        self.outputDeviceUID = outputDeviceUID
        self.deviceConfigurationGeneration = deviceConfigurationGeneration
        self.sources = sources
    }

    func hasSameTopology(as other: AudioRoutePlan) -> Bool {
        outputDeviceUID == other.outputDeviceUID
            && deviceConfigurationGeneration == other.deviceConfigurationGeneration
            && sources.map(\.processObjectID) == other.sources.map(\.processObjectID)
    }
}

struct AudioRouteCompilation: Equatable, Sendable {
    let plans: [AudioRoutePlan]
    let resolutions: [AudioRuleResolution]
}

struct AudioRouteCompilationPolicy: Equatable, Sendable {
    static let `default` = AudioRouteCompilationPolicy()

    let maximumSourcesPerRoute: Int
    let excludedBundleIDs: Set<String>
    let excludedProcessObjectIDs: Set<UInt32>
    let unsupportedOutputDeviceReasons: [String: String]

    init(
        maximumSourcesPerRoute: Int = 32,
        excludedBundleIDs: Set<String> = ["com.youtonghy.toolbox"],
        excludedProcessObjectIDs: Set<UInt32> = [],
        unsupportedOutputDeviceReasons: [String: String] = [:]
    ) {
        self.maximumSourcesPerRoute = maximumSourcesPerRoute
        self.excludedBundleIDs = excludedBundleIDs
        self.excludedProcessObjectIDs = excludedProcessObjectIDs
        self.unsupportedOutputDeviceReasons = unsupportedOutputDeviceReasons
    }
}

struct AudioRuleResolution: Equatable, Sendable {
    let bundleID: String
    let state: AudioRuleResolutionState
}

enum AudioRuleResolutionState: Equatable, Sendable {
    case planned(routeID: String?)
    case waiting(AudioRouteWaitingReason)
    case degraded(AudioRouteRejectionReason)
    case rejected(AudioRouteRejectionReason)
}

enum AudioRouteWaitingReason: Equatable, Sendable {
    case processNotRunning
}

enum AudioRouteRejectionReason: Equatable, Sendable {
    case missingDefaultOutputDevice
    case outputDeviceUnavailable(uid: String)
    case unsupportedOutputDevice(uid: String, reason: String)
    case sourceCapacityExceeded(limit: Int, requested: Int)
    case excludedProcess(objectID: UInt32)
}

struct AudioRouteRuntimeParameters: Equatable, Sendable {
    let generation: UInt64
    let routeID: String
    let processObjectID: UInt32
    let targetGain: Float
}

struct AudioRouteNativeRuntimeParameters: Equatable, Sendable {
    let routeID: String
    let sourceIndex: Int
    let targetGain: Float
}

struct AudioRouteDiagnosticsSnapshot: Equatable, Sendable {
    let routeID: String
    let generation: UInt64
    let captureCallbackCount: UInt64
    let captureFrameCount: UInt64
    let outputCallbackCount: UInt64
    let outputFrameCount: UInt64
    let lastCaptureHostTime: UInt64
    let lastOutputHostTime: UInt64
    let ringOccupancyFrames: UInt64
    let ringHighWaterFrames: UInt64
    let warmupFrameCount: UInt64
    let underrunFrameCount: UInt64
    let overrunFrameCount: UInt64
    let forcedResyncCount: UInt64
    let formatMismatchCount: UInt64
    let nonFiniteSampleCount: UInt64
    let clippedSampleCount: UInt64
    let callbacksInFlight: UInt64
    let fatalCallbackMismatch: Bool

    init(
        routeID: String,
        generation: UInt64,
        captureCallbackCount: UInt64 = 0,
        captureFrameCount: UInt64 = 0,
        outputCallbackCount: UInt64 = 0,
        outputFrameCount: UInt64 = 0,
        lastCaptureHostTime: UInt64 = 0,
        lastOutputHostTime: UInt64 = 0,
        ringOccupancyFrames: UInt64 = 0,
        ringHighWaterFrames: UInt64 = 0,
        warmupFrameCount: UInt64 = 0,
        underrunFrameCount: UInt64 = 0,
        overrunFrameCount: UInt64 = 0,
        forcedResyncCount: UInt64 = 0,
        formatMismatchCount: UInt64 = 0,
        nonFiniteSampleCount: UInt64 = 0,
        clippedSampleCount: UInt64 = 0,
        callbacksInFlight: UInt64 = 0,
        fatalCallbackMismatch: Bool = false
    ) {
        self.routeID = routeID
        self.generation = generation
        self.captureCallbackCount = captureCallbackCount
        self.captureFrameCount = captureFrameCount
        self.outputCallbackCount = outputCallbackCount
        self.outputFrameCount = outputFrameCount
        self.lastCaptureHostTime = lastCaptureHostTime
        self.lastOutputHostTime = lastOutputHostTime
        self.ringOccupancyFrames = ringOccupancyFrames
        self.ringHighWaterFrames = ringHighWaterFrames
        self.warmupFrameCount = warmupFrameCount
        self.underrunFrameCount = underrunFrameCount
        self.overrunFrameCount = overrunFrameCount
        self.forcedResyncCount = forcedResyncCount
        self.formatMismatchCount = formatMismatchCount
        self.nonFiniteSampleCount = nonFiniteSampleCount
        self.clippedSampleCount = clippedSampleCount
        self.callbacksInFlight = callbacksInFlight
        self.fatalCallbackMismatch = fatalCallbackMismatch
    }
}

enum AudioRouteDiagnosticsFatalReason: Equatable, Sendable {
    case callbackFormatMismatch
}

enum AudioRouteDiagnosticsHealth: Equatable, Sendable {
    case starting
    case awaitingAudio
    case active
    case stalled
    case fatal(AudioRouteDiagnosticsFatalReason)
}

enum AudioRouteDiagnosticsEvaluator {
    static let startupGracePollCount = 8
    static let stallPollCount = 8

    /// - Parameter sourceIsProducingOutput: HAL reports at least one source of this route
    ///   as currently producing output (`piro`). A quiet capture path only means the tap
    ///   is broken while that holds; otherwise the app is simply paused or idle.
    static func evaluate(
        snapshot: AudioRouteDiagnosticsSnapshot?,
        previous: AudioRouteDiagnosticsSnapshot?,
        startupPollCount: Int,
        consecutiveStalledPollCount: Int,
        sourceIsProducingOutput: Bool = true
    ) -> AudioRouteDiagnosticsHealth {
        guard let snapshot else {
            return startupPollCount >= startupGracePollCount ? .awaitingAudio : .starting
        }
        // Only the output path can mark a route fatal. Per-source capture mismatches
        // are expected when one of several apps on a shared route is unreadable
        // (e.g. iOS-on-Mac shells); those sources simply contribute silence.
        if snapshot.fatalCallbackMismatch {
            return .fatal(.callbackFormatMismatch)
        }

        let hasCapture = snapshot.captureFrameCount > 0
        let hasOutput = snapshot.outputFrameCount > 0
        guard hasCapture && hasOutput else {
            return startupPollCount >= startupGracePollCount ? .awaitingAudio : .starting
        }

        if let previous {
            let captureAdvanced = snapshot.captureFrameCount != previous.captureFrameCount
            let outputAdvanced = snapshot.outputFrameCount != previous.outputFrameCount
            // A dead output IOProc is always fatal for the route: nothing can be heard
            // through it again, so release it and let the original path resume.
            if !outputAdvanced, consecutiveStalledPollCount >= stallPollCount {
                return .stalled
            }
            // A quiet capture path is only a failure while HAL still reports the source
            // as producing output. Pausing playback stops capture frames for as long as
            // the user likes, and tearing the route down there would silently drop the
            // saved per-app gain until the slider is touched again.
            if !captureAdvanced {
                guard sourceIsProducingOutput else { return .awaitingAudio }
                if consecutiveStalledPollCount >= stallPollCount { return .stalled }
            }
        }
        return .active
    }
}

enum AudioRouteApplyStatus: Equatable, Sendable {
    case applied
    case unchanged
    case stale
    case failed(String)
    case cleanupBlocked(String)
}

struct AudioRouteApplyReport: Equatable, Sendable {
    let generation: UInt64
    let status: AudioRouteApplyStatus
    let plans: [AudioRoutePlan]
}

enum AudioRouteStopReason: Equatable, Sendable {
    case serviceStopped
    case reconcileFailure
    case audioServerRestarted
    case fatalDiagnostics
}

struct AudioRouteStopReport: Equatable, Sendable {
    let succeeded: Bool
    let errorMessage: String?
}

enum AudioRouteState: Equatable, Sendable {
    case inactive
    case waitingForProcess
    case starting
    case awaitingAudio(String)
    case active
    case degraded(String)
    case failed(String)
}
