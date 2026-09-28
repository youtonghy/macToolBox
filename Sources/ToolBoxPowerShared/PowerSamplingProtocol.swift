import Foundation

enum PowerSamplingService {
    static let name = "com.youtonghy.toolbox.power-sampling"
    static let plistName = name + ".plist"
    static let helperRelativePath = "Contents/Library/LaunchServices/ToolBoxPowerHelper"
    static let enabledKey = "authorizedPowerSamplingEnabled"
    static let maximumSampleAge: TimeInterval = 3
    /// With no client connected the helper exits after this delay, so launchd
    /// starts a fresh process on the next connection.
    static let helperIdleExitDelay: TimeInterval = 15
}

// The service exposes no executable paths, arguments, file operations, or shell commands.
@objc protocol PowerSamplingXPCProtocol {
    func poll(withReply reply: @escaping (Data) -> Void)
    func stop(withReply reply: @escaping () -> Void)
}

struct AuthorizedPowerReading: Codable, Equatable, Sendable {
    let timestamp: Date
    let interval: TimeInterval
    let cpuWatts: Double
    let gpuWatts: Double?
    let aneWatts: Double?
    let combinedWatts: Double?

    func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return age >= 0 && age <= PowerSamplingService.maximumSampleAge
    }
}

enum PowerSamplingFailure: String, Codable, Sendable {
    case authorizationRequired, connectionFailed, samplingFailed, stopped
}

struct PowerSamplingResponse: Codable, Sendable {
    var reading: AuthorizedPowerReading?
    var failure: PowerSamplingFailure?
}
