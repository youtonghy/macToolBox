import Dispatch
import Foundation

struct AudioRouteMonotonicTime: Comparable, Sendable {
    let uptimeNanoseconds: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.uptimeNanoseconds < rhs.uptimeNanoseconds
    }
}

protocol AudioRouteClock: AnyObject {
    var now: AudioRouteMonotonicTime { get }
}

final class SystemAudioRouteClock: AudioRouteClock {
    var now: AudioRouteMonotonicTime {
        AudioRouteMonotonicTime(
            uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
    }
}

enum AudioRouteRecoveryResetCause: Equatable, Sendable {
    case userIntent
    case halFingerprint
    case audioServerGeneration
}

enum AudioRouteRecoveryAction: Equatable, Sendable {
    case retry(after: Duration)
    case failClosed
}

struct AudioRouteRecoveryPolicy: Sendable {
    static let retryDelays: [Duration] = [
        .milliseconds(250),
        .seconds(1),
        .seconds(4)
    ]
    static let retryWindow: Duration = .seconds(30)

    private struct RouteState: Sendable {
        var attemptIndex: Int
        var windowStart: AudioRouteMonotonicTime
        var isExhausted: Bool
    }

    private static let retryWindowNanoseconds: UInt64 = 30_000_000_000
    private var statesByRouteID: [String: RouteState] = [:]

    mutating func action(
        for routeID: String,
        reason: AudioRouteHealthReason,
        now: AudioRouteMonotonicTime
    ) -> AudioRouteRecoveryAction {
        var state = statesByRouteID[routeID] ?? RouteState(
            attemptIndex: 0,
            windowStart: now,
            isExhausted: false
        )

        guard !state.isExhausted else {
            return .failClosed
        }

        let elapsed = now.uptimeNanoseconds &- state.windowStart.uptimeNanoseconds
        if elapsed >= Self.retryWindowNanoseconds {
            state.attemptIndex = 0
            state.windowStart = now
        }

        guard state.attemptIndex < Self.retryDelays.count else {
            state.isExhausted = true
            statesByRouteID[routeID] = state
            return .failClosed
        }

        let delay = Self.retryDelays[state.attemptIndex]
        state.attemptIndex += 1
        statesByRouteID[routeID] = state
        return .retry(after: delay)
    }

    mutating func reset(
        routeID: String,
        cause: AudioRouteRecoveryResetCause
    ) {
        statesByRouteID.removeValue(forKey: routeID)
    }
}
